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
}

PipelineSpec :: struct {
	name:            string,
	push:            PushConstantInfo,
	descriptor:      DescriptorBindingInfo,
	compute_module:  string,
	vertex_module:   string,
	fragment_module: string,
}

ComputePipelineConfig :: struct {
	name:       string,
	shader:     string,
	push:       PushConstantInfo,
	descriptor: DescriptorBindingInfo,
}

GraphicsPipelineConfig :: struct {
	name:       string,
	vertex:     string,
	fragment:   string,
	push:       PushConstantInfo,
	descriptor: DescriptorBindingInfo,
}

accumulation_barriers: BufferBarriers
last_frame_time: f32

descriptor_pool: vk.DescriptorPool

pipelines_ready: bool


render_pipeline_specs: [PIPELINE_COUNT]PipelineSpec
render_pipeline_states: [PIPELINE_COUNT]PipelineState

make_compute_pipeline_spec :: proc(config: ComputePipelineConfig) -> PipelineSpec {
	return PipelineSpec {
		name = config.name,
		push = config.push,
		descriptor = config.descriptor,
		compute_module = config.shader,
	}
}

make_graphics_pipeline_spec :: proc(config: GraphicsPipelineConfig) -> PipelineSpec {
	return PipelineSpec {
		name = config.name,
		push = config.push,
		descriptor = config.descriptor,
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
) -> DescriptorBindingInfo {
	return DescriptorBindingInfo {
		label = label,
		binding = binding,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		stage = stage,
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
	/*
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
*/
	return true
}

create_descriptor_pool :: proc(count: int) -> bool {
	pool_sizes := [1]vk.DescriptorPoolSize{{type = .STORAGE_BUFFER, descriptorCount = u32(count)}}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {vk.DescriptorPoolCreateFlag.FREE_DESCRIPTOR_SET},
		poolSizeCount = u32(len(pool_sizes)),
		pPoolSizes    = raw_data(pool_sizes[:]),
		maxSets       = u32(count),
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
	create_descriptor_pool(len(specs)) or_return
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
	bindings := []vk.DescriptorSetLayoutBinding {
		{
			binding = spec.descriptor.binding,
			descriptorType = spec.descriptor.descriptorType,
			descriptorCount = 1,
			stageFlags = spec.descriptor.stage,
		},
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

	vk.UpdateDescriptorSets(
		device,
		1,
		&vk.WriteDescriptorSet {
			sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet = desc_set,
			dstBinding = spec.descriptor.binding,
			descriptorType = spec.descriptor.descriptorType,
			descriptorCount = 1,
			pBufferInfo = &vk.DescriptorBufferInfo {
				buffer = accumulation_buffer.buffer,
				range = vk.DeviceSize(vk.WHOLE_SIZE),
			},
		},
		0,
		nil,
	)

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
