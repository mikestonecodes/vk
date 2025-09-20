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
	name:            string,
	push:            union {
		PushConstantInfo,
		typeid,
	},
	descriptors:     union {
		[MAX_DESCRIPTOR_BINDINGS]DescriptorBindingInfo,
		[]^BufferResource,
		[]^TextureResource,
		[]ResourceBinding,
	},
	descriptor_count: u32,
	compute_module:  string,
	vertex_module:   string,
	fragment_module: string,
}

ResourceBinding :: union {
	^BufferResource,
	^TextureResource,
}

ComputePipelineConfig :: struct {
	name:       string,
	shader:     string,
	push:       PushConstantInfo,
}

GraphicsPipelineConfig :: struct {
	name:       string,
	vertex:     string,
	fragment:   string,
	push:       PushConstantInfo,
}

last_frame_time: f32

descriptor_pool: vk.DescriptorPool

pipelines_ready: bool


render_pipeline_specs: [PIPELINE_COUNT]PipelineSpec
render_pipeline_states: [PIPELINE_COUNT]PipelineState

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
	return PipelineSpec {
		name = config.name,
		push = config.push,
		compute_module = config.shader,
	}
}

make_graphics_pipeline_spec :: proc(config: GraphicsPipelineConfig) -> PipelineSpec {
	return PipelineSpec {
		name = config.name,
		push = config.push,
		vertex_module = config.vertex,
		fragment_module = config.fragment,
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
	} else {
		fmt.println("Unsupported image layout transition")
		return false
	}

	vk.CmdPipelineBarrier(cmd, src_stage, dst_stage, {}, 0, nil, 0, nil, 1, &barrier)
	return true
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

	for spec in specs {
		if spec.compute_module != "" {
			shader_name := strings.trim_suffix(spec.compute_module, ".spv")
			shader_file := fmt.aprintf("%s.hlsl", shader_name)
			defer delete(shader_file)
			compile_shader(shader_file)
		}
		if spec.vertex_module != "" {
			shader_name := strings.trim_suffix(spec.vertex_module, "_vs.spv")
			shader_file := fmt.aprintf("%s.hlsl", shader_name)
			defer delete(shader_file)
			compile_shader(shader_file)
		}
		if spec.fragment_module != "" {
			shader_name := strings.trim_suffix(spec.fragment_module, "_fs.spv")
			shader_file := fmt.aprintf("%s.hlsl", shader_name)
			defer delete(shader_file)
			compile_shader(shader_file)
		}
	}

	return true
}

create_descriptor_pool :: proc(pool_sizes: []vk.DescriptorPoolSize, set_count: int) -> bool {
	if len(pool_sizes) == 0 {
		fmt.println("Descriptor pool requires at least one size entry")
		return false
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {vk.DescriptorPoolCreateFlag.FREE_DESCRIPTOR_SET},
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = &pool_sizes[0],
		maxSets       = u32(set_count),
	}

	descriptor_pool = vkw(
		vk.CreateDescriptorPool,
		device,
		&pool_info,
		"descriptor pool",
		vk.DescriptorPool,
	) or_return
	return true
}

build_pipelines :: proc(specs: []PipelineSpec, states: []PipelineState) -> bool {
	runtime.assert(len(specs) == len(states), "pipeline spec/state length mismatch")
	if len(specs) == 0 do return true
	pool_size_entries := [8]vk.DescriptorPoolSize{}
	pool_size_len := 0
	for spec in specs {
		for idx in 0 ..< int(spec.descriptor_count) {
			desc_type := spec.descriptors[idx].descriptorType
			found := false
			for bi in 0 ..< pool_size_len {
				if pool_size_entries[bi].type == desc_type {
					pool_size_entries[bi].descriptorCount += 1
					found = true
					break
				}
			}
			if !found {
				runtime.assert(pool_size_len < len(pool_size_entries), "Descriptor pool size array exhausted")
				pool_size_entries[pool_size_len] = vk.DescriptorPoolSize {
					type = desc_type,
					descriptorCount = 1,
				}
				pool_size_len += 1
			}
		}
	}
	if pool_size_len == 0 {
		pool_size_entries[0] = vk.DescriptorPoolSize {
			type = vk.DescriptorType.STORAGE_BUFFER,
			descriptorCount = 1,
		}
		pool_size_len = 1
	}
	pool_sizes := pool_size_entries[:pool_size_len]
	create_descriptor_pool(pool_sizes, len(specs)) or_return
	for idx in 0 ..< len(specs) {
		if !build_pipeline(&specs[idx], &states[idx]) do return false
	}
	return true
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

build_pipeline :: proc(spec: ^PipelineSpec, state: ^PipelineState) -> bool {
	binding_count := int(spec.descriptor_count)
	bindings_storage: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorSetLayoutBinding
	bindings := bindings_storage[:binding_count]
	for idx in 0 ..< binding_count {
		info := spec.descriptors[idx]
		fmt.printf("[pipeline] descriptor binding %v type %v stage %v\n", info.binding, info.descriptorType, info.stage)
		bindings[idx] = vk.DescriptorSetLayoutBinding {
			binding = info.binding,
			descriptorType = info.descriptorType,
			descriptorCount = 1,
			stageFlags = info.stage,
		}
	}

	// Create descriptor set layout
	desc_layout := vkw(
		vk.CreateDescriptorSetLayout,
		device,
		&vk.DescriptorSetLayoutCreateInfo {
			sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
			bindingCount = u32(len(bindings)),
			pBindings = len(bindings) > 0 ? &bindings[0] : nil,
		},
		"descriptor set layout",
		vk.DescriptorSetLayout,
	) or_return
	defer vk.DestroyDescriptorSetLayout(device, desc_layout, nil)

	push_ranges: []vk.PushConstantRange
	if spec.push.size > 0 {
		push_ranges = []vk.PushConstantRange{{stageFlags = spec.push.stage, size = spec.push.size}}
	}
	layouts := []vk.DescriptorSetLayout{desc_layout}

	// Create pipeline layout
	pipe_layout := vkw(
		vk.CreatePipelineLayout,
		device,
		&vk.PipelineLayoutCreateInfo {
			sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
			setLayoutCount = u32(len(layouts)),
			pSetLayouts = len(layouts) > 0 ? &layouts[0] : nil,
			pushConstantRangeCount = u32(len(push_ranges)),
			pPushConstantRanges = len(push_ranges) > 0 ? &push_ranges[0] : nil,
		},
		"pipeline layout",
		vk.PipelineLayout,
	) or_return
	defer vk.DestroyPipelineLayout(device, pipe_layout, nil)

	pipe: vk.Pipeline
	if spec.compute_module != "" {
		module := load_shader_module(spec.compute_module) or_return
		if vk.CreateComputePipelines(
			   device,
			   vk.PipelineCache{},
			   1,
			   &vk.ComputePipelineCreateInfo {
				   sType = vk.StructureType.COMPUTE_PIPELINE_CREATE_INFO,
				   stage = make_stage(vk.ShaderStageFlag.COMPUTE, module, "main"),
				   layout = pipe_layout,
			   },
			   nil,
			   &pipe,
		   ) !=
		   vk.Result.SUCCESS {
			fmt.println("Failed to create compute pipeline")
			return false
		}
	} else {
		vert := load_shader_module(spec.vertex_module) or_return
		frag := load_shader_module(spec.fragment_module) or_return
		defer {vk.DestroyShaderModule(device, vert, nil);vk.DestroyShaderModule(device, frag, nil)}

		viewport := vk.Viewport {
			x        = 0,
			y        = 0,
			width    = f32(width),
			height   = f32(height),
			minDepth = 0,
			maxDepth = 1,
		}

		scissor := vk.Rect2D {
			offset = {x = 0, y = 0},
			extent = {width = u32(width), height = u32(height)},
		}

		stages := [2]vk.PipelineShaderStageCreateInfo {
			make_stage(vk.ShaderStageFlag.VERTEX, vert, "vs_main"),
			make_stage(vk.ShaderStageFlag.FRAGMENT, frag, "fs_main"),
		}

		if vk.CreateGraphicsPipelines(
			   device,
			   vk.PipelineCache{},
			   1,
			   &vk.GraphicsPipelineCreateInfo {
				   sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
				   stageCount = 2,
				   pStages = raw_data(stages[:]),
				   pVertexInputState = &vk.PipelineVertexInputStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
				   },
				   pInputAssemblyState = &vk.PipelineInputAssemblyStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
					   topology = vk.PrimitiveTopology.TRIANGLE_LIST,
				   },
				   pViewportState = &vk.PipelineViewportStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
					   viewportCount = 1,
					   pViewports = &viewport,
					   scissorCount = 1,
					   pScissors = &scissor,
				   },
				   pRasterizationState = &vk.PipelineRasterizationStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
					   polygonMode = vk.PolygonMode.FILL,
					   frontFace = vk.FrontFace.CLOCKWISE,
					   lineWidth = 1,
				   },
				   pMultisampleState = &vk.PipelineMultisampleStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
					   rasterizationSamples = {vk.SampleCountFlag._1},
				   },
				   pColorBlendState = &vk.PipelineColorBlendStateCreateInfo {
					   sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
					   attachmentCount = 1,
					   pAttachments = &vk.PipelineColorBlendAttachmentState {
						   colorWriteMask = {
							   vk.ColorComponentFlag.R,
							   vk.ColorComponentFlag.G,
							   vk.ColorComponentFlag.B,
							   vk.ColorComponentFlag.A,
						   },
					   },
				   },
				   layout = pipe_layout,
				   renderPass = render_pass,
			   },
			   nil,
			   &pipe,
		   ) !=
		   vk.Result.SUCCESS {
			fmt.println("Failed to create graphics pipeline")
			return false
		}
	}
	defer vk.DestroyPipeline(device, pipe, nil)

	// Allocate descriptor set
	desc_set: vk.DescriptorSet
	vkw(
		vk.AllocateDescriptorSets,
		device,
		&vk.DescriptorSetAllocateInfo {
			sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
			descriptorPool = descriptor_pool,
			descriptorSetCount = 1,
			pSetLayouts = &desc_layout,
		},
		&desc_set,
		"descriptor set",
	) or_return
	defer vk.FreeDescriptorSets(device, descriptor_pool, 1, &desc_set)

	if binding_count > 0 {
		buffer_infos_storage: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorBufferInfo
		image_infos_storage: [MAX_DESCRIPTOR_BINDINGS]vk.DescriptorImageInfo
		writes_storage: [MAX_DESCRIPTOR_BINDINGS]vk.WriteDescriptorSet
		buffer_infos := buffer_infos_storage[:binding_count]
		image_infos := image_infos_storage[:binding_count]
		writes := writes_storage[:binding_count]
		for idx in 0 ..< binding_count {
			info := spec.descriptors[idx]
			write := &writes[idx]
			write.sType = vk.StructureType.WRITE_DESCRIPTOR_SET
			write.dstSet = desc_set
			write.dstBinding = info.binding
			write.descriptorType = info.descriptorType
			write.descriptorCount = 1
			write.pBufferInfo = nil
			write.pImageInfo = nil

			#partial switch info.descriptorType {
			case vk.DescriptorType.STORAGE_BUFFER, vk.DescriptorType.UNIFORM_BUFFER, vk.DescriptorType.STORAGE_BUFFER_DYNAMIC, vk.DescriptorType.UNIFORM_BUFFER_DYNAMIC:
				if info.buffer == nil || info.buffer.buffer == {} {
					fmt.println("Descriptor binding missing buffer resource")
					return false
				}
				buffer_infos[idx] = vk.DescriptorBufferInfo {
					buffer = info.buffer.buffer,
					range = vk.DeviceSize(vk.WHOLE_SIZE),
				}
				write.pBufferInfo = &buffer_infos[idx]
			case vk.DescriptorType.SAMPLED_IMAGE, vk.DescriptorType.STORAGE_IMAGE:
				if info.texture == nil || info.texture.view == {} {
					fmt.println("Descriptor binding missing texture resource")
					return false
				}
				layout := info.texture.layout
				if layout == {} {
					layout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL
				}
				image_infos[idx] = vk.DescriptorImageInfo {
					sampler = vk.Sampler{},
					imageView = info.texture.view,
					imageLayout = layout,
				}
				write.pImageInfo = &image_infos[idx]
			case vk.DescriptorType.COMBINED_IMAGE_SAMPLER:
				if info.texture == nil || info.texture.view == {} || info.texture.sampler == {} {
					fmt.println("Combined image sampler missing texture or sampler")
					return false
				}
				layout := info.texture.layout
				if layout == {} {
					layout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL
				}
				image_infos[idx] = vk.DescriptorImageInfo {
					sampler = info.texture.sampler,
					imageView = info.texture.view,
					imageLayout = layout,
				}
				write.pImageInfo = &image_infos[idx]
			case vk.DescriptorType.SAMPLER:
				if info.sampler == nil || info.sampler^ == {} {
					fmt.println("Sampler descriptor missing sampler resource")
					return false
				}
				image_infos[idx] = vk.DescriptorImageInfo {
					sampler = info.sampler^,
					imageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
				}
				write.pImageInfo = &image_infos[idx]
			case:
				fmt.printf("Unsupported descriptor type: %v\n", info.descriptorType)
				return false
			}
		}

		vk.UpdateDescriptorSets(
			device,
			u32(len(writes)),
			&writes[0],
			0,
			nil,
		)
	}

	state^ = PipelineState {
		pipeline          = pipe,
		layout            = pipe_layout,
		descriptor_layout = desc_layout,
		descriptor_set    = desc_set,
		push_stage        = spec.push.stage,
	}

	// transfer ownership to state
	pipe, pipe_layout, desc_layout, desc_set = {}, {}, {}, {}
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

finish_encoding :: proc(encoder: ^CommandEncoder) {
	vk.EndCommandBuffer(encoder.command_buffer)
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
