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
	vk.CmdBindDescriptorSets(frame.cmd, bind_point, state.layout, 0, 1, &global_desc_set, 0, nil)
	vk.CmdPushConstants(frame.cmd, state.layout, state.push_stage, 0, push_size, push_constants)
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

update_bindless_texture :: proc(slot: u32, tex: ^TextureResource) -> bool {
    img_info := vk.DescriptorImageInfo{
        imageView   = tex.view,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }
    samp_info := vk.DescriptorImageInfo{
        sampler     = tex.sampler,
        imageLayout = .SHADER_READ_ONLY_OPTIMAL,
    }

    writes := [2]vk.WriteDescriptorSet{
        {
            sType            = .WRITE_DESCRIPTOR_SET,
            dstSet           = global_desc_set,
            dstBinding       = 1,           // sampled image array
            dstArrayElement  = slot,        // slot index in textures[]
            descriptorCount  = 1,
            descriptorType   = .SAMPLED_IMAGE,
            pImageInfo       = &img_info,
        },
        {
            sType            = .WRITE_DESCRIPTOR_SET,
            dstSet           = global_desc_set,
            dstBinding       = 2,           // sampler array
            dstArrayElement  = slot,        // slot index in samplers[]
            descriptorCount  = 1,
            descriptorType   = .SAMPLER,
            pImageInfo       = &samp_info,
        },
    }

    vk.UpdateDescriptorSets(device, u32(len(writes)), &writes[0], 0, nil)
    return true
}

//BUILD PIPEZ

// ========================================================
// PIPELINE HELPERS
// ========================================================

// Global bindless set
global_desc_layout: vk.DescriptorSetLayout
global_desc_set: vk.DescriptorSet

update_global_descriptors :: proc() -> bool {
	buf_info := vk.DescriptorBufferInfo {
		buffer = accumulation_buffer.buffer,
		offset = 0,
		range  = accumulation_buffer.size,
	}

	img_info := vk.DescriptorImageInfo {
		imageView   = sprite_texture.view,
		imageLayout = .SHADER_READ_ONLY_OPTIMAL,
	}

	samp_info := vk.DescriptorImageInfo {
		sampler = sprite_texture.sampler,
	}

	writes := [3]vk.WriteDescriptorSet {
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = global_desc_set,
			dstBinding      = 0, // STORAGE_BUFFER[]
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .STORAGE_BUFFER,
			pBufferInfo     = &buf_info,
		},
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = global_desc_set,
			dstBinding      = 1, // SAMPLED_IMAGE[]
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .SAMPLED_IMAGE,
			pImageInfo      = &img_info,
		},
		{
			sType           = .WRITE_DESCRIPTOR_SET,
			dstSet          = global_desc_set,
			dstBinding      = 2, // SAMPLER[]
			dstArrayElement = 0,
			descriptorCount = 1,
			descriptorType  = .SAMPLER,
			pImageInfo      = &samp_info,
		},
	}

	vk.UpdateDescriptorSets(device, u32(len(writes)), &writes[0], 0, nil)
	return true
}


init_global_descriptors :: proc() -> bool {
	bindings := [3]vk.DescriptorSetLayoutBinding {
		{
			binding = 0,
			descriptorType = .STORAGE_BUFFER,
			descriptorCount = 1024,
			stageFlags = {vk.ShaderStageFlag.COMPUTE, vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = .SAMPLED_IMAGE,
			descriptorCount = 1024,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding = 2,
			descriptorType = .SAMPLER,
			descriptorCount = 64,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
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

	pool_sizes := [3]vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = 1024},
		{type = .SAMPLED_IMAGE, descriptorCount = 1024},
		{type = .SAMPLER, descriptorCount = 64},
	}
	global_desc_pool := vkw(
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
	pool_sizes := []vk.DescriptorPoolSize {
		{type = .STORAGE_BUFFER, descriptorCount = 1},
		{type = .SAMPLED_IMAGE, descriptorCount = 1},
		{type = .SAMPLER, descriptorCount = 1},
	}
	create_descriptor_pool(pool_sizes, len(specs)) or_return
	for idx in 0 ..< len(specs) {
		if !build_pipeline(&specs[idx], &states[idx]) {
			fmt.println("Failed to build pipeline at index", idx, "name =", specs[idx].name)
			return false
		}
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
