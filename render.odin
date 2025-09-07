package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"
import vk "vendor:vulkan"

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	// Begin command buffer
	begin_info := vk.CommandBufferBeginInfo{
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}
	vk.ResetCommandBuffer(element.commandBuffer, {})
	vk.BeginCommandBuffer(element.commandBuffer, &begin_info)

	// Begin render pass (clears screen to black)
	clear_value := vk.ClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}}
	render_pass_begin := vk.RenderPassBeginInfo{
		sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = element.framebuffer,
		renderArea = {offset = {0, 0}, extent = {width, height}},
		clearValueCount = 1, pClearValues = &clear_value,
	}

	vk.CmdBeginRenderPass(element.commandBuffer, &render_pass_begin, vk.SubpassContents.INLINE)

	// Bind pipeline
	vk.CmdBindPipeline(element.commandBuffer, vk.PipelineBindPoint.GRAPHICS, graphics_pipeline)

	// Push time constant for rotation
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
	vk.CmdPushConstants(element.commandBuffer, pipeline_layout, {vk.ShaderStageFlag.VERTEX}, 0, size_of(f32), &elapsed_time)

	// Draw particles (6 vertices per quad, 100 instances)
	vk.CmdDraw(element.commandBuffer, 6, 1000000, 0, 0)

	// End render pass and command buffer
	vk.CmdEndRenderPass(element.commandBuffer)
	vk.EndCommandBuffer(element.commandBuffer)
}


create_graphics_pipeline :: proc() -> bool {
	// Load compiled shaders
	vertex_shader_code, vert_ok := load_shader_spirv("vertex.spv")
	if !vert_ok {
		fmt.println("Failed to load vertex shader")
		return false
	}
	defer delete(vertex_shader_code)

	fragment_shader_code, frag_ok := load_shader_spirv("fragment.spv")
	if !frag_ok {
		fmt.println("Failed to load fragment shader")
		return false
	}
	defer delete(fragment_shader_code)

	// Create shader modules
	vert_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(vertex_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(vertex_shader_code),
	}
	vert_shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &vert_shader_create_info, nil, &vert_shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create vertex shader module")
		return false
	}
	defer vk.DestroyShaderModule(device, vert_shader_module, nil)

	frag_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(fragment_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(fragment_shader_code),
	}
	frag_shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &frag_shader_create_info, nil, &frag_shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create fragment shader module")
		return false
	}
	defer vk.DestroyShaderModule(device, frag_shader_module, nil)

	// Pipeline stages - vertex and fragment shaders
	shader_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.VERTEX}, module = vert_shader_module, pName = "vs_main"},
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.FRAGMENT}, module = frag_shader_module, pName = "fs_main"},
	}

	// Vertex input - no vertex buffers, using hardcoded quad vertices in shader
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo{sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}

	// Input assembly - drawing triangles
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = vk.PrimitiveTopology.TRIANGLE_LIST,
		primitiveRestartEnable = false,
	}

	// Viewport and scissor
	viewport := vk.Viewport{x = 0.0, y = 0.0, width = f32(width), height = f32(height), minDepth = 0.0, maxDepth = 1.0}
	scissor := vk.Rect2D{offset = {0, 0}, extent = {width, height}}
	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1, pViewports = &viewport,
		scissorCount = 1, pScissors = &scissor,
	}

	// Rasterizer - fill triangles
	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = false, rasterizerDiscardEnable = false,
		polygonMode = vk.PolygonMode.FILL, lineWidth = 1.0,
		cullMode = {}, frontFace = vk.FrontFace.CLOCKWISE, depthBiasEnable = false,
	}

	// Multisampling - disabled
	multisampling := vk.PipelineMultisampleStateCreateInfo{
		sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable = false, rasterizationSamples = {vk.SampleCountFlag._1},
	}

	// Color blending - no blending, just write colors
	color_blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable = false,
		colorWriteMask = {vk.ColorComponentFlag.R, vk.ColorComponentFlag.G, vk.ColorComponentFlag.B, vk.ColorComponentFlag.A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo{
		sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false, attachmentCount = 1, pAttachments = &color_blend_attachment,
	}

	// Pipeline layout - for push constants (time)
	push_constant_range := vk.PushConstantRange{stageFlags = {vk.ShaderStageFlag.VERTEX}, offset = 0, size = size_of(f32)}
	pipeline_layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1, pPushConstantRanges = &push_constant_range,
	}
	if vk.CreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create pipeline layout")
		return false
	}

	// Create the graphics pipeline
	pipeline_info := vk.GraphicsPipelineCreateInfo{
		sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = raw_data(shader_stages[:]),
		pVertexInputState = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState = &multisampling,
		pColorBlendState = &color_blending,
		layout = pipeline_layout,
		renderPass = render_pass,
		subpass = 0,
		basePipelineHandle = {}, basePipelineIndex = -1,
	}

	if vk.CreateGraphicsPipelines(device, {}, 1, &pipeline_info, nil, &graphics_pipeline) != vk.Result.SUCCESS {
		fmt.println("Failed to create graphics pipeline")
		return false
	}

	return true
}



