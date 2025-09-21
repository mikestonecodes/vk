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
	pipeline:   vk.Pipeline,
	layout:     vk.PipelineLayout,
	push_stage: vk.ShaderStageFlags,
}


PushConstantInfo :: struct {
	label: string,
	stage: vk.ShaderStageFlags,
	size:  u32,
}


PipelineSpec :: struct {
	name:            string,
	push:            union {
		PushConstantInfo,
		typeid,
	},
	compute_module:  string,
	vertex_module:   string,
	fragment_module: string,
}

last_frame_time: f32
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
	vk.CmdBindDescriptorSets(frame.cmd, bind_point, state.layout, 0, 1, &global_desc_set, 0, nil)
	vk.CmdPushConstants(frame.cmd, state.layout, state.push_stage, 0, push_size, push_constants)
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
			stageFlags      = {vk.ShaderStageFlag.COMPUTE, vk.ShaderStageFlag.FRAGMENT},
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

build_pipelines :: proc(specs: []PipelineSpec, states: []PipelineState) -> bool {
	assert(len(specs) == len(states), "pipeline spec/state length mismatch")
	if len(specs) == 0 do return true
	for idx in 0 ..< len(specs) {
		build_pipeline(&specs[idx], &states[idx]) or_return
	}
	return true
}

make_pipeline_layout :: proc(
	_: vk.DescriptorSetLayout,
	spec: ^PipelineSpec,
) -> (
	layout: vk.PipelineLayout,
	ok: bool,
) {
	ranges: [1]vk.PushConstantRange
	count: u32 = 0
	if push, ok2 := spec.push.(PushConstantInfo); ok2 && push.size > 0 {
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
			pStages = raw_data(
				[]vk.PipelineShaderStageCreateInfo {
					{
						sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
						stage = {.VERTEX},
						module = vsh,
						pName = "vs_main",
					},
					{
						sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
						stage = {.FRAGMENT},
						module = fsh,
						pName = "fs_main",
					},
				},
			),
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
				pViewports = &vk.Viewport {
					x = 0,
					y = 0,
					width = f32(window_width),
					height = f32(window_height),
					minDepth = 0,
					maxDepth = 1,
				},
				scissorCount = 1,
				pScissors = &vk.Rect2D {
					offset = {0, 0},
					extent = {u32(window_width), u32(window_height)},
				},
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


// ========================================================
// MAIN PIPELINE BUILDER
// ========================================================

build_pipeline :: proc(spec: ^PipelineSpec, state: ^PipelineState) -> bool {
	// Layout uses global_desc_layout internally (see make_pipeline_layout)
	pipe_layout := make_pipeline_layout({}, spec) or_return

	pipe: vk.Pipeline
	if spec.compute_module != "" {
		pipe = make_compute_pipeline(spec.compute_module, pipe_layout) or_return
	} else {
		pipe = make_graphics_pipeline(
			spec.vertex_module,
			spec.fragment_module,
			pipe_layout,
		) or_return
	}

	push_stage: vk.ShaderStageFlags

	if push, ok := spec.push.(PushConstantInfo); ok {
		push_stage = push.stage
	}

	state^ = PipelineState {
		pipeline   = pipe,
		layout     = pipe_layout,
		push_stage = push_stage,
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
	state.push_stage = {}
}

destroy_render_pipeline_state :: proc(states: []PipelineState) {
	pipelines_ready = false
	for idx in 0 ..< len(states) {
		reset_pipeline_state(&states[idx])
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
