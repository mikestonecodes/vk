package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

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

last_frame_time: f32
shaders_ready: bool
render_shader_states: [PIPELINE_COUNT]ShaderProgram
render_shader_configs: [PIPELINE_COUNT]ShaderProgramConfig

begin_frame_commands :: proc(
	element: ^SwapchainElement,
	start_time: time.Time,
) -> (
	encoder: CommandEncoder,
	frame: FrameInputs,
) {
	runtime.assert(
		accumulation_buffer.buffer != {},
		"accumulation buffer missing before recording commands",
	)
	runtime.assert(accumulation_buffer.size > 0, "accumulation buffer size must be positive")

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
			null_stages := [3]vk.ShaderStageFlags{
				{vk.ShaderStageFlag.TESSELLATION_CONTROL},
				{vk.ShaderStageFlag.TESSELLATION_EVALUATION},
				{vk.ShaderStageFlag.GEOMETRY},
			}
			vk.CmdBindShadersEXT(frame.cmd, u32(len(null_stages)), &null_stages[0], &null_shaders[0])
		}
		vk.CmdBindShadersEXT(frame.cmd, state.stage_count, &state.stages[0], &state.shaders[0])
	}
	vk.CmdBindDescriptorSets(frame.cmd, bind_point, state.layout, 0, 1, &global_desc_set, 0, nil)
	if push_size > 0 && state.push_stage != {} {
		vk.CmdPushConstants(frame.cmd, state.layout, state.push_stage, 0, push_size, push_constants)
	}
}


//BUILD PIPEZ

// ========================================================
// PIPELINE HELPERS
// ========================================================

// Global bindless set
global_desc_layout: vk.DescriptorSetLayout
global_desc_set: vk.DescriptorSet


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
global_desc_pool: vk.DescriptorPool

init_global_descriptors :: proc() -> bool {
	bindings := [4]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 4,
			stageFlags = {vk.ShaderStageFlag.COMPUTE, vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 2,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .SAMPLER,
			descriptorCount = 2,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding         = 3,
			descriptorType  = .STORAGE_BUFFER,
			descriptorCount = 1, // global state (camera, etc.)
			stageFlags      = {vk.ShaderStageFlag.COMPUTE},
		},
	}

	global_desc_layout = vkw(
		vk.CreateDescriptorSetLayout,
		device,
		&vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = u32(len(bindings)),
			pBindings = &bindings[0],
		},
		"global descriptor set layout",
		vk.DescriptorSetLayout,
	) or_return

	pool_sizes := [4]vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = 4},
		{type = .SAMPLED_IMAGE, descriptorCount = 2},
		{type = .SAMPLER, descriptorCount = 2},
		{type = .STORAGE_BUFFER, descriptorCount = 1},
	}
	global_desc_pool = vkw(
		vk.CreateDescriptorPool,
		device,
		&vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			maxSets = 1,
			poolSizeCount = u32(len(pool_sizes)),
			pPoolSizes = &pool_sizes[0],
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
			sType                 = .PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount        = 1,
			pSetLayouts           = &layouts[0],
			pushConstantRangeCount = count,
			pPushConstantRanges   = count > 0 ? &ranges[0] : nil,
		},
		"shader layout",
		vk.PipelineLayout,
	)
}

shader_stage_enabled :: proc(flags: vk.ShaderStageFlags, stage: vk.ShaderStageFlag) -> bool {
	return (flags & {stage}) != {}
}

create_shader_object :: proc(
	path: string,
	stage: vk.ShaderStageFlag,
	next_stage: vk.ShaderStageFlags,
	entry: cstring,
	layouts: []vk.DescriptorSetLayout,
	push_range: ^vk.PushConstantRange,
	push_range_count: u32,
) -> (shader: vk.ShaderEXT, ok: bool) {
	code := load_shader_code_words(path) or_return

	info := vk.ShaderCreateInfoEXT {
		sType               = vk.StructureType.SHADER_CREATE_INFO_EXT,
		flags               = {},
		stage               = {stage},
		nextStage           = next_stage,
		codeType            = vk.ShaderCodeTypeEXT.SPIRV,
		codeSize            = len(code) * size_of(u32),
		pCode               = raw_data(code),
		pName               = entry,
		setLayoutCount      = u32(len(layouts)),
		pSetLayouts         = len(layouts) > 0 ? &layouts[0] : nil,
		pushConstantRangeCount = push_range_count,
		pPushConstantRanges = push_range_count > 0 ? push_range : nil,
		pSpecializationInfo = nil,
	}

	result := vk.CreateShadersEXT(device, 1, &info, nil, &shader)
	if result != .SUCCESS {
		fmt.printf("Failed to create shader object for %s (err=%d)\n", path, result)
		return {}, false
	}
	return shader, true
}

create_shader_program :: proc(config: ^ShaderProgramConfig, state: ^ShaderProgram) -> bool {
	layout := make_shader_layout(&config.push) or_return

	layouts := [1]vk.DescriptorSetLayout{global_desc_layout}

	stage_count: u32 = 0
	shaders: [3]vk.ShaderEXT
	stages: [3]vk.ShaderStageFlags
	push_stage: vk.ShaderStageFlags

	range := vk.PushConstantRange {
		offset     = 0,
		size       = 0,
		stageFlags = {},
	}

	if config.push.size > 0 {
		range.stageFlags = config.push.stage
		range.size = config.push.size
		push_stage = config.push.stage
	}

	shader_handles := [3]vk.ShaderEXT{}
	created: int = 0
	success := false
	defer if !success {
		for i in 0 ..< created {
			if shader_handles[i] != {} {
				vk.DestroyShaderEXT(device, shader_handles[i], nil)
			}
		}
		if layout != {} {
			vk.DestroyPipelineLayout(device, layout, nil)
		}
	}

	if config.compute_module != "" {
		range_ptr: ^vk.PushConstantRange = nil
		range_count: u32 = 0
		if range.size > 0 && shader_stage_enabled(range.stageFlags, vk.ShaderStageFlag.COMPUTE) {
			range_ptr = &range
			range_count = 1
		}

		shader := create_shader_object(
			config.compute_module,
			vk.ShaderStageFlag.COMPUTE,
			vk.ShaderStageFlags{},
			cstring("main"),
			layouts[:],
			range_ptr,
			range_count,
		) or_return

		shader_handles[created] = shader
		created += 1

		stage_count = 1
		stages[0] = {vk.ShaderStageFlag.COMPUTE}
		shaders[0] = shader
	} else {
		gfx_range_ptr: ^vk.PushConstantRange = nil
		gfx_range_count: u32 = 0
		if range.size > 0 {
			gfx_range_ptr = &range
			gfx_range_count = 1
		}

		next_stage := vk.ShaderStageFlags{}
		if config.fragment_module != "" {
			next_stage = vk.ShaderStageFlags{vk.ShaderStageFlag.FRAGMENT}
		}

		vertex_shader := create_shader_object(
			config.vertex_module,
			vk.ShaderStageFlag.VERTEX,
			next_stage,
			cstring("vs_main"),
			layouts[:],
			gfx_range_ptr,
			gfx_range_count,
		) or_return

		shader_handles[created] = vertex_shader
		created += 1

		stages[0] = {vk.ShaderStageFlag.VERTEX}
		shaders[0] = vertex_shader
		stage_count = 1

		fragment_shader := create_shader_object(
			config.fragment_module,
			vk.ShaderStageFlag.FRAGMENT,
			vk.ShaderStageFlags{},
			cstring("fs_main"),
			layouts[:],
			gfx_range_ptr,
			gfx_range_count,
		) or_return

		shader_handles[created] = fragment_shader
		created += 1

		stages[1] = {vk.ShaderStageFlag.FRAGMENT}
		shaders[1] = fragment_shader
		stage_count = 2
	}

	success = true
	state^ = ShaderProgram {
		layout      = layout,
		push_stage  = push_stage,
		stage_count = stage_count,
		stages      = stages,
		shaders     = shaders,
	}
	return true
}

build_shader_programs :: proc(configs: []ShaderProgramConfig, states: []ShaderProgram) -> bool {
	assert(len(configs) == len(states), "shader config/state length mismatch")
	if len(configs) == 0 {
		shaders_ready = true
		return true
	}

	for idx in 0 ..< len(states) {
		reset_shader_program(&states[idx])
	}

	for idx in 0 ..< len(configs) {
		if !create_shader_program(&configs[idx], &states[idx]) {
			for j in 0 ..< len(states) {
				reset_shader_program(&states[j])
			}
			shaders_ready = false
			return false
		}
	}

	shaders_ready = true
	return true
}

reset_shader_program :: proc(state: ^ShaderProgram) {
	for idx in 0 ..< int(state.stage_count) {
		if state.shaders[idx] != {} {
			vk.DestroyShaderEXT(device, state.shaders[idx], nil)
		}
		state.shaders[idx] = {}
		state.stages[idx] = {}
	}
	state.stage_count = 0
	if state.layout != {} {
		vk.DestroyPipelineLayout(device, state.layout, nil)
		state.layout = {}
	}
	state.push_stage = {}
}

destroy_render_shader_state :: proc(states: []ShaderProgram) {
	for idx in 0 ..< len(states) {
		reset_shader_program(&states[idx])
	}
	shaders_ready = false
}
begin_encoding :: proc(element: ^SwapchainElement) -> CommandEncoder {
	encoder := CommandEncoder {
		command_buffer = element.commandBuffer,
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}

	vk.BeginCommandBuffer(encoder.command_buffer, &begin_info)
	return encoder
}
