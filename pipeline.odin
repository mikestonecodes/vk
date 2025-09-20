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

PipelineState :: struct {
	pipeline:          vk.Pipeline,
	layout:            vk.PipelineLayout,
	descriptor_layout: vk.DescriptorSetLayout,
	descriptor_set:    vk.DescriptorSet,
	push_stage:        vk.ShaderStageFlags,
}

MAX_DESCRIPTOR_BINDINGS :: u32(4)

PipelineKind :: enum {
	Compute,
	Post,
}
PushConstantInfo :: struct {
	label: string,
	stage: vk.ShaderStageFlags,
	size:  u32,
}

DescriptorBindingInfo :: struct {
	label:          string,
	binding:        u32,
	descriptorType: vk.DescriptorType,
	stage:          vk.ShaderStageFlags,
	buffer:         ^BufferResource,
	texture:        ^TextureResource,
	sampler:        ^vk.Sampler,
}

PipelineSpec :: struct {
	name:             string,
	push:             union {
		PushConstantInfo,
		typeid,
	},
	descriptors:      union {
		[MAX_DESCRIPTOR_BINDINGS]DescriptorBindingInfo,
		[]^BufferResource,
		[]^TextureResource,
		[]ResourceBinding,
	},
	descriptor_count: u32,
	compute_module:   string,
	vertex_module:    string,
	fragment_module:  string,
}

ResourceBinding :: union {
	^BufferResource,
	^TextureResource,
}

ComputePipelineConfig :: struct {
	name:   string,
	shader: string,
	push:   PushConstantInfo,
}

GraphicsPipelineConfig :: struct {
	name:     string,
	vertex:   string,
	fragment: string,
	push:     PushConstantInfo,
}

last_frame_time: f32

descriptor_pool: vk.DescriptorPool

pipelines_ready: bool


render_pipeline_specs: [PIPELINE_COUNT]PipelineSpec
render_pipeline_states: [PIPELINE_COUNT]PipelineState


//tiny wrapper proc --- would like to avoid this

begin_render_pass :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {
	vk.CmdBeginRenderPass(
		frame.cmd,
		&vk.RenderPassBeginInfo {
			sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
			renderPass = render_pass,
			framebuffer = framebuffer,
			renderArea = {{0, 0}, {width, height}},
			clearValueCount = 1,
			pClearValues = &vk.ClearValue{color = {float32 = {0, 0, 0, 1}}},
		},
		.INLINE,
	)
}
make_compute_pipeline_spec :: proc(config: ComputePipelineConfig) -> PipelineSpec {
	return PipelineSpec{name = config.name, push = config.push, compute_module = config.shader}
}

make_graphics_pipeline_spec :: proc(config: GraphicsPipelineConfig) -> PipelineSpec {
	return PipelineSpec {
		name = config.name,
		push = config.push,
		vertex_module = config.vertex,
		fragment_module = config.fragment,
	}
}
make_stage :: proc(
	stage: vk.ShaderStageFlag,
	module: vk.ShaderModule,
	name: cstring,
) -> vk.PipelineShaderStageCreateInfo {
	return vk.PipelineShaderStageCreateInfo {
		sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
		stage = {stage},
		module = module,
		pName = name,
	}
}
push_constant_info :: proc(
	label: string,
	stage: vk.ShaderStageFlags,
	size: u32,
) -> PushConstantInfo {
	return PushConstantInfo{label = label, stage = stage, size = size}
}


storage_buffer_binding :: proc(
	label: string,
	stage: vk.ShaderStageFlags,
	binding: u32 = 0,
	resource: ^BufferResource = nil,
) -> DescriptorBindingInfo {
	return DescriptorBindingInfo {
		label = label,
		binding = binding,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		stage = stage,
		buffer = resource,
	}
}

sampled_image_binding :: proc(
	label: string,
	stage: vk.ShaderStageFlags,
	binding: u32 = 0,
	texture: ^TextureResource = nil,
) -> DescriptorBindingInfo {
	return DescriptorBindingInfo {
		label = label,
		binding = binding,
		descriptorType = vk.DescriptorType.SAMPLED_IMAGE,
		stage = stage,
		texture = texture,
	}
}

sampler_binding :: proc(
	label: string,
	stage: vk.ShaderStageFlags,
	binding: u32 = 0,
	sampl: ^vk.Sampler = nil,
) -> DescriptorBindingInfo {
	return DescriptorBindingInfo {
		label = label,
		binding = binding,
		descriptorType = vk.DescriptorType.SAMPLER,
		stage = stage,
		sampler = sampl,
	}
}

finish_encoding :: proc(encoder: ^CommandEncoder) {
	vk.EndCommandBuffer(encoder.command_buffer)
}


//

transition_image_layout :: proc(
	cmd: vk.CommandBuffer,
	image: vk.Image,
	old_layout, new_layout: vk.ImageLayout,
) -> bool {
	barrier := vk.ImageMemoryBarrier {
		sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = image,
		subresourceRange = {
			aspectMask = {vk.ImageAspectFlag.COLOR},
			levelCount = 1,
			layerCount = 1,
		},
	}

	src_stage: vk.PipelineStageFlags
	dst_stage: vk.PipelineStageFlags

	if old_layout == vk.ImageLayout.UNDEFINED &&
	   new_layout == vk.ImageLayout.TRANSFER_DST_OPTIMAL {
		barrier.srcAccessMask = {}
		barrier.dstAccessMask = {vk.AccessFlag.TRANSFER_WRITE}
		src_stage = {vk.PipelineStageFlag.TOP_OF_PIPE}
		dst_stage = {vk.PipelineStageFlag.TRANSFER}
	} else if old_layout == vk.ImageLayout.TRANSFER_DST_OPTIMAL &&
	   new_layout == vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL {
		barrier.srcAccessMask = {vk.AccessFlag.TRANSFER_WRITE}
		barrier.dstAccessMask = {vk.AccessFlag.SHADER_READ}
		src_stage = {vk.PipelineStageFlag.TRANSFER}
		dst_stage = {vk.PipelineStageFlag.FRAGMENT_SHADER, vk.PipelineStageFlag.COMPUTE_SHADER}
	} else if old_layout == vk.ImageLayout.PREINITIALIZED && new_layout == vk.ImageLayout.GENERAL {
		barrier.srcAccessMask = {vk.AccessFlag.HOST_WRITE}
		barrier.dstAccessMask = {vk.AccessFlag.SHADER_READ}
		src_stage = {vk.PipelineStageFlag.HOST}
		dst_stage = {vk.PipelineStageFlag.FRAGMENT_SHADER, vk.PipelineStageFlag.COMPUTE_SHADER}
	} else {
		fmt.println("Unsupported image layout transition")
		return false
	}

	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)
	return true
}

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
	state: ^PipelineState,
	bind_point: vk.PipelineBindPoint,
	push_constants: ^$T,
) {
	push_size := u32(size_of(T))
	vk.CmdBindPipeline(frame.cmd, bind_point, state.pipeline)
	vk.CmdBindDescriptorSets(
		frame.cmd,
		bind_point,
		state.layout,
		0,
		1,
		&state.descriptor_set,
		0,
		nil,
	)
	vk.CmdPushConstants(frame.cmd, state.layout, state.push_stage, 0, push_size, push_constants)
}


load_shader_module :: proc(path: string) -> (shader: vk.ShaderModule, ok: bool) {
	code := load_shader_spirv(path) or_return
	defer delete(code)
	return vkw(
		vk.CreateShaderModule,
		device,
		&vk.ShaderModuleCreateInfo {
			sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
			codeSize = len(code) * size_of(u32),
			pCode = raw_data(code),
		},
		"Failed to create shader module",
		vk.ShaderModule,
	)
}

allocate_descriptor_set :: proc(
	layout: vk.DescriptorSetLayout,
	fail_msg: string,
) -> (
	descriptor_set: vk.DescriptorSet,
	ok: bool,
) {
	layouts := [1]vk.DescriptorSetLayout{layout}
	vkw(
		vk.AllocateDescriptorSets,
		device,
		&vk.DescriptorSetAllocateInfo {
			sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = raw_data(layouts[:]),
		},
		&descriptor_set,
		fail_msg,
	) or_return
	ok = true
	return
}

init_render_pipeline_state :: proc(specs: []PipelineSpec, states: []PipelineState) -> bool {
	compile_spec_shader :: proc(module_path, suffix: string) {
		if module_path != "" {
			shader_name := strings.trim_suffix(module_path, suffix)
			shader_file := fmt.aprintf("%s.hlsl", shader_name)
			defer delete(shader_file)
			compile_shader(shader_file)
		}
	}

	for spec in specs {
		compile_spec_shader(spec.compute_module, ".spv")
		compile_spec_shader(spec.vertex_module, "_vs.spv")
		compile_spec_shader(spec.fragment_module, "_fs.spv")
	}

	return true
}

create_descriptor_pool :: proc(pool_sizes: []vk.DescriptorPoolSize, set_count: int) -> bool {
	if len(pool_sizes) == 0 do return false
	descriptor_pool = vkw(
		vk.CreateDescriptorPool,
		device,
		&vk.DescriptorPoolCreateInfo {
			sType = .DESCRIPTOR_POOL_CREATE_INFO,
			flags = {.FREE_DESCRIPTOR_SET},
			poolSizeCount = u32(len(pool_sizes)),
			pPoolSizes = &pool_sizes[0],
			maxSets = u32(set_count),
		},
		"descriptor pool",
		vk.DescriptorPool,
	) or_return
	return true
}


//BUILD PIPEZ

// ========================================================
// PIPELINE HELPERS
// ========================================================

build_pipelines :: proc(specs: []PipelineSpec, states: []PipelineState) -> bool {
	assert(len(specs) == len(states), "pipeline spec/state length mismatch")
	if len(specs) == 0 do return true
	pool_sizes := []vk.DescriptorPoolSize{
		{type = .STORAGE_BUFFER, descriptorCount = 1},
		{type = .SAMPLED_IMAGE, descriptorCount = 1},
		{type = .SAMPLER, descriptorCount = 1},
	}
	create_descriptor_pool(pool_sizes, len(specs)) or_return
	for idx in 0 ..< len(specs) {
		if !build_pipeline(&specs[idx], &states[idx]) do return false
	}
	return true
}

make_descriptor_layout :: proc(spec: ^PipelineSpec) -> (layout: vk.DescriptorSetLayout, ok: bool) {
	bindings: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorSetLayoutBinding

	for idx in 0 ..< int(spec.descriptor_count) {
		if infos, ok2 := spec.descriptors.([MAX_DESCRIPTOR_BINDINGS]DescriptorBindingInfo); ok2 {
			info := infos[idx]
			bindings[idx] = {
				binding         = info.binding,
				descriptorType  = info.descriptorType,
				descriptorCount = 1,
				stageFlags      = info.stage,
			}
		}
	}

	return vkw(
		vk.CreateDescriptorSetLayout,
		device,
		&vk.DescriptorSetLayoutCreateInfo {
			sType = .DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = spec.descriptor_count,
			pBindings = spec.descriptor_count > 0 ? &bindings[0] : nil,
		},
		"descriptor set layout",
		vk.DescriptorSetLayout,
	)
}
make_pipeline_layout :: proc(
	desc_layout: vk.DescriptorSetLayout,
	spec: ^PipelineSpec,
) -> (
	layout: vk.PipelineLayout,
	ok: bool,
) {
	ranges: [1]vk.PushConstantRange
	count: u32 = 0
	if push, ok2 := spec.push.(PushConstantInfo); ok2 && push.size > 0 {
		ranges[0] = {stageFlags = push.stage, size = push.size}
		count = 1
	}

	layouts := [1]vk.DescriptorSetLayout{desc_layout}
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
		"pipeline layout",
		vk.PipelineLayout,
	)
}
make_compute_pipeline :: proc(
	path: string,
	layout: vk.PipelineLayout,
) -> (
	pipe: vk.Pipeline,
	ok: bool,
) {
	sh, loaded := load_shader_module(path)
	if !loaded do return {}, false
	defer vk.DestroyShaderModule(device, sh, nil)

	result := vk.CreateComputePipelines(
		device,
		vk.PipelineCache{},
		1,
		&vk.ComputePipelineCreateInfo {
			sType = .COMPUTE_PIPELINE_CREATE_INFO,
			stage = make_stage(.COMPUTE, sh, "main"),
			layout = layout,
		},
		nil,
		&pipe,
	)
	ok = (result == .SUCCESS)
	return
}
make_graphics_pipeline :: proc(
	vert_path, frag_path: string,
	layout: vk.PipelineLayout,
) -> (
	pipe: vk.Pipeline,
	ok: bool,
) {
	vsh := load_shader_module(vert_path) or_return
	fsh := load_shader_module(frag_path) or_return
	defer vk.DestroyShaderModule(device, vsh, nil)
	defer vk.DestroyShaderModule(device, fsh, nil)


	result := vk.CreateGraphicsPipelines(
		device,
		vk.PipelineCache{},
		1,
		&vk.GraphicsPipelineCreateInfo {
			sType = .GRAPHICS_PIPELINE_CREATE_INFO,
			stageCount = 2,
			pStages = raw_data([]vk.PipelineShaderStageCreateInfo{
				{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.VERTEX}, module = vsh, pName = "vs_main"},
				{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {.FRAGMENT}, module = fsh, pName = "fs_main"},
			}),
			pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
				sType = .PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
			},
			pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
				sType = .PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
				topology = .TRIANGLE_LIST,
			},
			pViewportState = &vk.PipelineViewportStateCreateInfo {
				sType = .PIPELINE_VIEWPORT_STATE_CREATE_INFO,
				viewportCount = 1,
				pViewports = &vk.Viewport{x = 0, y = 0, width = f32(window_width), height = f32(window_height), minDepth = 0, maxDepth = 1},
				scissorCount = 1,
				pScissors = &vk.Rect2D{offset = {0, 0}, extent = {u32(window_width), u32(window_height)}},
			},
			pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
				sType = .PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
				polygonMode = .FILL,
				frontFace = .CLOCKWISE,
				lineWidth = 1,
			},
			pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
				sType = .PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
				rasterizationSamples = {._1},
			},
			pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
				sType = .PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
				attachmentCount = 1,
				pAttachments = &vk.PipelineColorBlendAttachmentState {
					colorWriteMask = {.R, .G, .B, .A},
				},
			},
			layout = layout,
			renderPass = render_pass,
		},
		nil,
		&pipe,
	)
	ok = (result == .SUCCESS)
	return
}

update_descriptors :: proc(spec: ^PipelineSpec, set: vk.DescriptorSet) -> bool {
	binding_count := int(spec.descriptor_count)
	if binding_count == 0 do return true

	buf_infos: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorBufferInfo
	img_infos: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorImageInfo
	writes: [MAX_DESCRIPTOR_BINDINGS]vk.WriteDescriptorSet

	for idx in 0 ..< binding_count {
		if infos, ok := spec.descriptors.([MAX_DESCRIPTOR_BINDINGS]DescriptorBindingInfo); ok {
			info := infos[idx]
			write := &writes[idx]
			write^ = {sType = .WRITE_DESCRIPTOR_SET, dstSet = set, dstBinding = info.binding, descriptorType = info.descriptorType, descriptorCount = 1}

			#partial switch info.descriptorType {
			case .STORAGE_BUFFER, .UNIFORM_BUFFER, .STORAGE_BUFFER_DYNAMIC, .UNIFORM_BUFFER_DYNAMIC:
				if info.buffer == nil || info.buffer.buffer == {} {
					fmt.println("Descriptor binding missing buffer resource")
					return false
				}
				buf_infos[idx] = {buffer = info.buffer.buffer, range = vk.DeviceSize(vk.WHOLE_SIZE)}
				write.pBufferInfo = &buf_infos[idx]

			case .SAMPLED_IMAGE, .STORAGE_IMAGE:
				if info.texture == nil || info.texture.view == {} {
					fmt.println("Descriptor binding missing texture resource")
					return false
				}
				layout := info.texture.layout if info.texture.layout != {} else .SHADER_READ_ONLY_OPTIMAL
				img_infos[idx] = {imageView = info.texture.view, imageLayout = layout}
				write.pImageInfo = &img_infos[idx]

			case .COMBINED_IMAGE_SAMPLER:
				if info.texture == nil || info.texture.view == {} || info.texture.sampler == {} {
					fmt.println("Combined image sampler missing texture or sampler")
					return false
				}
				layout := info.texture.layout if info.texture.layout != {} else .SHADER_READ_ONLY_OPTIMAL
				img_infos[idx] = {sampler = info.texture.sampler, imageView = info.texture.view, imageLayout = layout}
				write.pImageInfo = &img_infos[idx]

			case .SAMPLER:
				if info.sampler == nil || info.sampler^ == {} {
					fmt.println("Sampler descriptor missing sampler resource")
					return false
				}
				img_infos[idx] = {sampler = info.sampler^, imageLayout = .SHADER_READ_ONLY_OPTIMAL}
				write.pImageInfo = &img_infos[idx]

			case:
				fmt.printf("Unsupported descriptor type: %v\n", info.descriptorType)
				return false
			}
		}
	}

	vk.UpdateDescriptorSets(device, u32(binding_count), &writes[0], 0, nil)
	return true
}

// ========================================================
// MAIN PIPELINE BUILDER
// ========================================================

build_pipeline :: proc(spec: ^PipelineSpec, state: ^PipelineState) -> bool {
	desc_layout := make_descriptor_layout(spec) or_return
	pipe_layout := make_pipeline_layout(desc_layout, spec) or_return

	pipe: vk.Pipeline
	if spec.compute_module != "" {
		pipe = make_compute_pipeline(spec.compute_module, pipe_layout) or_return
	} else {
		pipe = make_graphics_pipeline(spec.vertex_module, spec.fragment_module, pipe_layout) or_return
	}

	desc_set := allocate_descriptor_set(desc_layout, "descriptor set") or_return
	update_descriptors(spec, desc_set) or_return

	push_stage: vk.ShaderStageFlags
	if push, ok := spec.push.(PushConstantInfo); ok {
		push_stage = push.stage
	}

	state^ = PipelineState {
		pipeline          = pipe,
		layout            = pipe_layout,
		descriptor_layout = desc_layout,
		descriptor_set    = desc_set,
		push_stage        = push_stage,
	}

	return true
}
reset_pipeline_state :: proc(state: ^PipelineState) {
	if state.pipeline != {} {
		vk.DestroyPipeline(device, state.pipeline, nil)
		state.pipeline = {}
	}
	if state.layout != {} {
		vk.DestroyPipelineLayout(device, state.layout, nil)
		state.layout = {}
	}
	if state.descriptor_layout != {} {
		vk.DestroyDescriptorSetLayout(device, state.descriptor_layout, nil)
		state.descriptor_layout = {}
	}
	state.descriptor_set = {}
	state.push_stage = {}
}

destroy_render_pipeline_state :: proc(states: []PipelineState) {
	pipelines_ready = false
	for idx in 0 ..< len(states) {
		reset_pipeline_state(&states[idx])
	}
	if descriptor_pool != {} {
		vk.DestroyDescriptorPool(device, descriptor_pool, nil)
		descriptor_pool = {}
	}
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

compile_hlsl :: proc(shader_file, profile, entry, output: string) -> bool {
	cmd := fmt.aprintf(
		"dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T %s -E %s -Fo %s %s",
		profile,
		entry,
		output,
		shader_file,
	)
	defer delete(cmd)
	c_cmd := strings.clone_to_cstring(cmd, context.temp_allocator)
	return system(c_cmd) == 0
}

compile_shader :: proc(shader_file: string) -> bool {
	base, _ := strings.replace(shader_file, ".hlsl", "", 1)
	defer delete(base)

	if strings.contains(shader_file, "compute") {
		return compile_hlsl(shader_file, "cs_6_0", "main", fmt.aprintf("%s.spv", base))
	}

	vs_ok := compile_hlsl(shader_file, "vs_6_0", "vs_main", fmt.aprintf("%s_vs.spv", base))
	fs_ok := compile_hlsl(shader_file, "ps_6_0", "fs_main", fmt.aprintf("%s_fs.spv", base))
	return vs_ok && fs_ok
}
