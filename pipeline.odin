// ============================================================================
// Package & Imports
// ============================================================================
package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"


// ============================================================================
// Type Aliases
// ============================================================================
DeviceSize :: vk.DeviceSize

BufferUsageFlags :: vk.BufferUsageFlags
ShaderStageFlags :: vk.ShaderStageFlags
DescriptorType :: vk.DescriptorType


// ============================================================================
// Structs
// ============================================================================
CommandEncoder :: struct {
	command_buffer: vk.CommandBuffer,
}

FrameInputs :: struct {
	cmd:        vk.CommandBuffer,
	time:       f32,
	delta_time: f32,
}

ShaderProgram :: struct {
	layout:      vk.PipelineLayout,
	push_stage:  vk.ShaderStageFlags,
	stage_count: u32,
	stages:      [3]vk.ShaderStageFlags,
	shaders:     [3]vk.ShaderEXT,
}

PushConstantInfo :: struct {
	label: string,
	stage: vk.ShaderStageFlags,
	size:  u32,
}

ShaderProgramConfig :: struct {
	compute_module:  string,
	vertex_module:   string,
	fragment_module: string,
	push:            PushConstantInfo,
}


// ============================================================================
// Global State
// ============================================================================
buffers: Array(32, BufferResource)
last_frame_time: f32
shaders_ready: bool

render_shader_states: [PIPELINE_COUNT]ShaderProgram

// Global bindless set
global_desc_layout: vk.DescriptorSetLayout
global_desc_set: vk.DescriptorSet
global_desc_pool: vk.DescriptorPool

global_descriptor_specs: Array(32, DescriptorBindingSpec)

render_resources_initialized: bool


MAX_SPIRV_BYTES :: 1 << 20
spirv_words := Array(MAX_SPIRV_BYTES / 4, u32){}


// ============================================================================
// Command Encoding & Frame Setup
// ============================================================================
begin_frame_commands :: proc(
	element: ^SwapchainElement,
	start_time: time.Time,
) -> (
	encoder: CommandEncoder,
	frame: FrameInputs,
) {

	encoder = begin_encoding(element)
	current_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
	delta := current_time - last_frame_time
	if last_frame_time == 0.0 || delta < 0.0 {
		delta = 0.0
	}
	last_frame_time = current_time

	frame = FrameInputs {
		cmd        = encoder.command_buffer,
		time       = current_time,
		delta_time = delta,
	}
	return
}

begin_encoding :: proc(element: ^SwapchainElement) -> CommandEncoder {
	encoder := CommandEncoder {
		command_buffer = element.commandBuffer,
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {.ONE_TIME_SUBMIT},
	}

	vk.BeginCommandBuffer(encoder.command_buffer, &begin_info)
	return encoder
}


// ============================================================================
// Binding Helpers (Shader Objects, Descriptor Sets, Push Constants)
// ============================================================================
bind :: proc(
	frame: FrameInputs,
	state: ^ShaderProgram,
	bind_point: vk.PipelineBindPoint,
	push_constants: ^$T,
) {
	push_size := u32(size_of(T))

	if state.stage_count > 0 {
		if bind_point == vk.PipelineBindPoint.GRAPHICS {
			null_shaders := [3]vk.ShaderEXT{{}, {}, {}}
			null_stages := [3]vk.ShaderStageFlags {
				{vk.ShaderStageFlag.TESSELLATION_CONTROL},
				{vk.ShaderStageFlag.TESSELLATION_EVALUATION},
				{vk.ShaderStageFlag.GEOMETRY},
			}
			vk.CmdBindShadersEXT(
				frame.cmd,
				u32(len(null_stages)),
				&null_stages[0],
				&null_shaders[0],
			)
		}
		vk.CmdBindShadersEXT(frame.cmd, state.stage_count, &state.stages[0], &state.shaders[0])
	}
	vk.CmdBindDescriptorSets(frame.cmd, bind_point, state.layout, 0, 1, &global_desc_set, 0, nil)
	if push_size > 0 && state.push_stage != {} {
		vk.CmdPushConstants(
			frame.cmd,
			state.layout,
			state.push_stage,
			0,
			push_size,
			push_constants,
		)
	}
}

bind_resource :: proc(slot: u32, resource: $T, dstBinding := u32(max(u32))) {
	w := vk.WriteDescriptorSet {
		sType           = .WRITE_DESCRIPTOR_SET,
		dstSet          = global_desc_set,
		dstArrayElement = slot,
		descriptorCount = 1,
	}

	when T == ^BufferResource {
		w.dstBinding = dstBinding if dstBinding != max(u32) else 0
		w.descriptorType = .STORAGE_BUFFER
		w.pBufferInfo = &vk.DescriptorBufferInfo{buffer = resource.buffer, range = resource.size}
	}
	when T == ^TextureResource {
		w.dstBinding = dstBinding if dstBinding != max(u32) else 1
		w.descriptorType = .SAMPLED_IMAGE
		w.pImageInfo =
		&vk.DescriptorImageInfo{imageView = resource.view, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
	}
	when T == ^vk.Sampler {
		w.dstBinding = dstBinding if dstBinding != max(u32) else 2
		w.descriptorType = .SAMPLER
		w.pImageInfo = &vk.DescriptorImageInfo{sampler = resource^}
	}

	vk.UpdateDescriptorSets(device, 1, &w, 0, nil)
}


// ============================================================================
// Descriptor Layout/Pool Init
// ============================================================================
get_global_descriptor_specs :: proc() -> []DescriptorBindingSpec {
	specs := &global_descriptor_specs
	specs.len = 0
	for buffer_spec in buffer_specs {
		descriptor := DescriptorBindingSpec {
			binding          = buffer_spec.binding,
			descriptor_type  = .STORAGE_BUFFER,
			descriptor_count = 1,
			stage_flags      = buffer_spec.stage_flags,
		}
		array_push(specs, descriptor)
	}
	for extra in global_descriptor_extras {
		array_push(specs, extra)
	}
	return array_slice(specs)
}

init_global_descriptors :: proc() -> bool {
	specs := get_global_descriptor_specs()
	bindings_storage: Array(32, vk.DescriptorSetLayoutBinding)
	for spec in specs {
		binding := vk.DescriptorSetLayoutBinding {
			binding            = spec.binding,
			descriptorType     = spec.descriptor_type,
			descriptorCount    = spec.descriptor_count,
			stageFlags         = spec.stage_flags,
			pImmutableSamplers = nil,
		}
		array_push(&bindings_storage, binding)
	}
	bindings_slice := array_slice(&bindings_storage)
	binding_count := len(bindings_slice)
	bindings_ptr := cast(^vk.DescriptorSetLayoutBinding)nil
	if binding_count > 0 {
		bindings_ptr = &bindings_slice[0]
	}

	global_desc_layout = vkw(
		vk.CreateDescriptorSetLayout,
		device,
		&vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = u32(binding_count),
			pBindings = bindings_ptr,
		},
		"global descriptor set layout",
		vk.DescriptorSetLayout,
	) or_return

	storage_count: u32 = 0
	sampled_image_count: u32 = 0
	sampler_count: u32 = 0
	for spec in specs {
		#partial switch spec.descriptor_type {
		case .STORAGE_BUFFER:
			storage_count += spec.descriptor_count
		case .SAMPLED_IMAGE:
			sampled_image_count += spec.descriptor_count
		case .SAMPLER:
			sampler_count += spec.descriptor_count
		}
	}

	pool_sizes: [3]vk.DescriptorPoolSize
	pool_count: u32 = 0
	if storage_count > 0 {
		pool_sizes[pool_count] = {
			type            = .STORAGE_BUFFER,
			descriptorCount = storage_count,
		}
		pool_count += 1
	}
	if sampled_image_count > 0 {
		pool_sizes[pool_count] = {
			type            = .SAMPLED_IMAGE,
			descriptorCount = sampled_image_count,
		}
		pool_count += 1
	}
	if sampler_count > 0 {
		pool_sizes[pool_count] = {
			type            = .SAMPLER,
			descriptorCount = sampler_count,
		}
		pool_count += 1
	}

	pool_sizes_ptr := cast(^vk.DescriptorPoolSize)nil
	if pool_count > 0 {
		pool_sizes_ptr = &pool_sizes[0]
	}
	global_desc_pool = vkw(
		vk.CreateDescriptorPool,
		device,
		&vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets = 1,
			poolSizeCount = pool_count,
			pPoolSizes = pool_sizes_ptr,
		},
		"global descriptor pool",
		vk.DescriptorPool,
	) or_return

	vkw(
		vk.AllocateDescriptorSets,
		device,
		&vk.DescriptorSetAllocateInfo {
			sType = .DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = global_desc_pool,
			descriptorSetCount = 1,
			pSetLayouts = &global_desc_layout,
		},
		&global_desc_set,
		"global descriptor set",
	) or_return

	return true
}


// ============================================================================
// Shader System
// ============================================================================
ShaderStageInfo :: struct {
	profile: cstring,
	entry:   cstring,
	suffix:  string,
}

get_stage_info :: proc(stage: string) -> ShaderStageInfo {
	switch stage {
	case "compute":
		return {"cs_6_0", "main", ".spv"}
	case "vertex":
		return {"vs_6_0", "vs_main", "_vs.spv"}
	case "fragment":
		return {"ps_6_0", "fs_main", "_fs.spv"}
	}
	return {}
}

make_shader_layout :: proc(push: ^PushConstantInfo) -> (layout: vk.PipelineLayout, ok: bool) {
	ranges: [1]vk.PushConstantRange
	count: u32 = 0
	if push != nil && push.size > 0 {
		ranges[0] = {
			stageFlags = push.stage,
			size       = push.size,
		}
		count = 1
	}
	layouts := [1]vk.DescriptorSetLayout{global_desc_layout}
	return vkw(
		vk.CreatePipelineLayout,
		device,
		&vk.PipelineLayoutCreateInfo {
			sType = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = 1,
			pSetLayouts = &layouts[0],
			pushConstantRangeCount = count,
			pPushConstantRanges = count > 0 ? &ranges[0] : nil,
		},
		"shader layout",
		vk.PipelineLayout,
	)
}

load_shader :: proc(spv_path, stage_name: string) -> ([]u32, bool) {
	info := get_stage_info(stage_name)
	hlsl := fmt.aprintf("%s.hlsl", strings.trim_suffix(spv_path, info.suffix))

	if os.exists(hlsl) {
		cmd := fmt.aprintf(
			"dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T %s -E %s -Fo %s %s",
			info.profile,
			info.entry,
			spv_path,
			hlsl,
		)
		system(strings.clone_to_cstring(cmd, context.temp_allocator))
	}

	data, ok := os.read_entire_file(spv_path)
	if !ok || len(data) % 4 != 0 || len(data) > MAX_SPIRV_BYTES do return nil, false
	defer delete(data)

	spirv_words.len = 0
	for i in 0 ..< len(data) / 4 {
		spirv_words.data[i] =
			u32(data[i * 4]) |
			(u32(data[i * 4 + 1]) << 8) |
			(u32(data[i * 4 + 2]) << 16) |
			(u32(data[i * 4 + 3]) << 24)
	}
	spirv_words.len = i32(len(data) / 4)
	return array_slice(&spirv_words), true
}

create_shader_object :: proc(
	path, stage_name: string,
	stage: vk.ShaderStageFlag,
	next_stage: vk.ShaderStageFlags,
	layouts: []vk.DescriptorSetLayout,
	push_range: ^vk.PushConstantRange,
	push_range_count: u32,
) -> (
	shader: vk.ShaderEXT,
	ok: bool,
) {
	code := load_shader(path, stage_name) or_return
	info := get_stage_info(stage_name)

	shader_info := vk.ShaderCreateInfoEXT {
		sType                  = .SHADER_CREATE_INFO_EXT,
		stage                  = {stage},
		nextStage              = next_stage,
		codeType               = .SPIRV,
		codeSize               = len(code) * size_of(u32),
		pCode                  = raw_data(code),
		pName                  = info.entry,
		setLayoutCount         = u32(len(layouts)),
		pSetLayouts            = len(layouts) > 0 ? &layouts[0] : nil,
		pushConstantRangeCount = push_range_count,
		pPushConstantRanges    = push_range_count > 0 ? push_range : nil,
	}

	if vk.CreateShadersEXT(device, 1, &shader_info, nil, &shader) != .SUCCESS do return {}, false
	return shader, true
}

init_shaders :: proc() -> bool {
	if global_desc_set == {} && !init_global_descriptors() do return false
	if !render_resources_initialized {
		if !init_render_resources() do return false
		render_resources_initialized = true
	}

	layouts := [1]vk.DescriptorSetLayout{global_desc_layout}

	for &cfg, i in render_shader_configs {
		state := &render_shader_states[i]
		state.layout = make_shader_layout(&cfg.push) or_return

		range := vk.PushConstantRange {
			stageFlags = cfg.push.stage,
			size       = cfg.push.size,
		}
		range_ptr := range.size > 0 ? &range : nil
		range_count := range.size > 0 ? u32(1) : u32(0)

		if cfg.compute_module != "" {
			state.shaders[0] = create_shader_object(
				cfg.compute_module,
				"compute",
				.COMPUTE,
				{},
				layouts[:],
				range_ptr,
				range_count,
			) or_return
			state.stages[0] = {.COMPUTE}
			state.stage_count = 1
		} else {
			next := cfg.fragment_module != "" ? vk.ShaderStageFlags{.FRAGMENT} : {}
			state.shaders[0] = create_shader_object(
				cfg.vertex_module,
				"vertex",
				.VERTEX,
				next,
				layouts[:],
				range_ptr,
				range_count,
			) or_return
			state.stages[0] = {.VERTEX}
			state.stage_count = 1

			if cfg.fragment_module != "" {
				state.shaders[1] = create_shader_object(
					cfg.fragment_module,
					"fragment",
					.FRAGMENT,
					{},
					layouts[:],
					range_ptr,
					range_count,
				) or_return
				state.stages[1] = {.FRAGMENT}
				state.stage_count = 2
			}
		}
		state.push_stage = range.stageFlags
	}

	shaders_ready = true
	return true
}

cleanup_shaders :: proc() {
	for &state in render_shader_states {
		for i in 0 ..< int(state.stage_count) {
			if state.shaders[i] != {} do vk.DestroyShaderEXT(device, state.shaders[i], nil)
		}
		if state.layout != {} do vk.DestroyPipelineLayout(device, state.layout, nil)
		state = {}
	}
	shaders_ready = false
}

// ============================================================================
// Shader Hot Reload (Compact)
// ============================================================================
shader_sizes := map[string]i64{}

check_shader_reload :: proc() {
	reload := false
	stages := []string{"compute", "vertex", "fragment"}

	for cfg in render_shader_configs {
		for stage_name in stages {
			spv: string
			if stage_name == "compute" {
				spv = cfg.compute_module
			} else if stage_name == "vertex" {
				spv = cfg.vertex_module
			} else if stage_name == "fragment" {
				spv = cfg.fragment_module
			}
			if spv == "" || !os.exists(spv) {
				continue
			}

			info := get_stage_info(stage_name)
			hlsl := fmt.aprintf("%s.hlsl", strings.trim_suffix(spv, info.suffix))
			paths := []string{hlsl, spv}

			for path in paths {
				if !os.exists(path) {
					continue
				}
				file_info, err := os.stat(path)
				if err != os.ERROR_NONE {
					continue
				}
				s := file_info.size
				prev_size, exists := shader_sizes[path]
				if !exists || prev_size != s {
					shader_sizes[path] = s
					reload = true
				}
			}
		}
	}

	if reload {
		fmt.println("↻ Shader changed, reloading...")
		cleanup_shaders()
		init_shaders()
	}
}


// ============================================================================
// Compute Dispatch & Barriers
// ============================================================================
compute_barrier :: proc(cmd: vk.CommandBuffer) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {vk.PipelineStageFlag2.COMPUTE_SHADER},
		srcAccessMask = {vk.AccessFlag2.SHADER_READ, vk.AccessFlag2.SHADER_WRITE},
		dstStageMask  = {vk.PipelineStageFlag2.COMPUTE_SHADER},
		dstAccessMask = {vk.AccessFlag2.SHADER_READ, vk.AccessFlag2.SHADER_WRITE},
	}
	dependency := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency)
}

apply_compute_to_fragment_barrier :: proc(cmd: vk.CommandBuffer, buf: ^BufferResource) {
	runtime.assert(buf.buffer != {}, "compute barrier requested before initialization")

	barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_READ},
		buffer        = buf.buffer,
		offset        = 0,
		size          = buf.size,
	}
	dep := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

// Generic helper that respects solver_iteration etc.
dispatch_compute :: proc(frame: FrameInputs, task: DispatchMode, count: u32) {
	compute_push_constants.dispatch_mode = u32(task)
	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, count, 1, 1)
	compute_barrier(frame.cmd)
}


// ============================================================================
// Rendering (Dynamic Rendering + Dynamic States)
// ============================================================================
begin_rendering :: proc(frame: FrameInputs, element: ^SwapchainElement) {


	vk.CmdBeginRendering(
		frame.cmd,
		&vk.RenderingInfo {
			sType = .RENDERING_INFO,
			renderArea = {{0, 0}, {width, height}},
			layerCount = 1,
			colorAttachmentCount = 1,
			pColorAttachments = &vk.RenderingAttachmentInfo {
				sType = .RENDERING_ATTACHMENT_INFO,
				imageView = element.imageView,
				imageLayout = .ATTACHMENT_OPTIMAL,
				loadOp = .CLEAR,
				storeOp = .STORE,
				clearValue = vk.ClearValue{color = {float32 = {0, 0, 0, 1}}},
			},
		},
	)

	vk.CmdSetViewportWithCount(
		frame.cmd,
		1,
		&vk.Viewport {
			x = 0,
			y = 0,
			width = f32(window_width),
			height = f32(window_height),
			minDepth = 0,
			maxDepth = 1,
		},
	)
	vk.CmdSetScissorWithCount(
		frame.cmd,
		1,
		&vk.Rect2D{offset = {0, 0}, extent = {u32(window_width), u32(window_height)}},
	)
	vk.CmdSetPrimitiveTopology(frame.cmd, vk.PrimitiveTopology.TRIANGLE_LIST)
	vk.CmdSetFrontFace(frame.cmd, vk.FrontFace.CLOCKWISE)
	vk.CmdSetPolygonModeEXT(frame.cmd, vk.PolygonMode.FILL)
	vk.CmdSetRasterizerDiscardEnable(frame.cmd, b32(false))
	vk.CmdSetCullMode(frame.cmd, vk.CullModeFlags_NONE)
	vk.CmdSetDepthClampEnableEXT(frame.cmd, b32(false))
	vk.CmdSetDepthBiasEnable(frame.cmd, b32(false))
	vk.CmdSetDepthTestEnable(frame.cmd, b32(false))
	vk.CmdSetDepthWriteEnable(frame.cmd, b32(false))
	vk.CmdSetDepthBoundsTestEnable(frame.cmd, b32(false))
	vk.CmdSetStencilTestEnable(frame.cmd, b32(false))
	vk.CmdSetPrimitiveRestartEnable(frame.cmd, b32(false))
	vk.CmdSetAlphaToCoverageEnableEXT(frame.cmd, b32(false))
	vk.CmdSetAlphaToOneEnableEXT(frame.cmd, b32(false))
	vk.CmdSetLogicOpEnableEXT(frame.cmd, b32(false))
	color_blend_enable := b32(false)
	sample_mask := vk.SampleMask(0xffffffff)
	sample_flags := vk.SampleCountFlags{vk.SampleCountFlag._1}
	vk.CmdSetRasterizationSamplesEXT(frame.cmd, sample_flags)
	vk.CmdSetSampleMaskEXT(frame.cmd, sample_flags, &sample_mask)

	vk.CmdSetDepthBounds(frame.cmd, 0.0, 1.0)
	vk.CmdSetColorBlendEnableEXT(frame.cmd, 0, 1, &color_blend_enable)
	vk.CmdSetColorBlendEquationEXT(
		frame.cmd,
		0,
		1,
		&vk.ColorBlendEquationEXT {
			srcColorBlendFactor = vk.BlendFactor.ONE,
			dstColorBlendFactor = vk.BlendFactor.ZERO,
			colorBlendOp = vk.BlendOp.ADD,
			srcAlphaBlendFactor = vk.BlendFactor.ONE,
			dstAlphaBlendFactor = vk.BlendFactor.ZERO,
			alphaBlendOp = vk.BlendOp.ADD,
		},
	)
	vk.CmdSetColorWriteMaskEXT(
		frame.cmd,
		0,
		1,
		&vk.ColorComponentFlags {
			vk.ColorComponentFlag.R,
			vk.ColorComponentFlag.G,
			vk.ColorComponentFlag.B,
			vk.ColorComponentFlag.A,
		},
	)
	vk.CmdSetVertexInputEXT(frame.cmd, 0, nil, 0, nil)
}

draw :: proc(
	frame: FrameInputs,
	vertex_count: u32,
	instance_count: u32 = 1,
	first_vertex: u32 = 0,
	first_instance: u32 = 0,
) {
	vk.CmdDraw(frame.cmd, vertex_count, instance_count, first_vertex, first_instance)
}

end_rendering :: proc(frame: FrameInputs) {
	vk.CmdEndRendering(frame.cmd)
}


// ============================================================================
// Render Resources (Init/Cleanup)
// ============================================================================
init_render_resources :: proc() -> bool {
	for spec, i in buffer_specs {
		create_buffer(&buffers.data[i], spec.size, spec.flags)
		bind_resource(0, &buffers.data[i], spec.binding)
	}
	return true
}

cleanup_render_resources :: proc() {
	for &buffer in buffers.data {
		destroy_buffer(&buffer)
	}
}


// ============================================================================
// Foreign Declarations
// ============================================================================
foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
