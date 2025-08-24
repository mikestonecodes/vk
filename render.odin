package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"

render_frame :: proc(start_time: time.Time) {
	// 1. Get next swapchain image
	current_element := &elements[current_frame]
	if !acquire_next_image(current_element.startSemaphore) do return

	// 2. Wait for previous frame, reset fence
	element := &elements[image_index]
	prepare_frame(element)

	// 3. Record draw commands
	record_commands(element, start_time)

	// 4. Submit to GPU and present
	submit_commands(element, current_element.startSemaphore)
	present_frame()

	current_frame = (current_frame + 1) % image_count
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
	vert_shader_create_info := VkShaderModuleCreateInfo{
		sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		codeSize = len(vertex_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(vertex_shader_code),
	}
	vert_shader_module: VkShaderModule
	if vkCreateShaderModule(device, &vert_shader_create_info, nil, &vert_shader_module) != VK_SUCCESS {
		fmt.println("Failed to create vertex shader module")
		return false
	}
	defer vkDestroyShaderModule(device, vert_shader_module, nil)

	frag_shader_create_info := VkShaderModuleCreateInfo{
		sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		codeSize = len(fragment_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(fragment_shader_code),
	}
	frag_shader_module: VkShaderModule
	if vkCreateShaderModule(device, &frag_shader_create_info, nil, &frag_shader_module) != VK_SUCCESS {
		fmt.println("Failed to create fragment shader module")
		return false
	}
	defer vkDestroyShaderModule(device, frag_shader_module, nil)

	// Pipeline stages - vertex and fragment shaders
	shader_stages := [2]VkPipelineShaderStageCreateInfo{
		{sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, stage = VK_SHADER_STAGE_VERTEX_BIT, module = vert_shader_module, pName = "vs_main"},
		{sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, stage = VK_SHADER_STAGE_FRAGMENT_BIT, module = frag_shader_module, pName = "fs_main"},
	}

	// Vertex input - no vertices, using hardcoded triangle in shader
	vertex_input_info := VkPipelineVertexInputStateCreateInfo{sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}

	// Input assembly - drawing triangles
	input_assembly := VkPipelineInputAssemblyStateCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
		primitiveRestartEnable = VK_FALSE,
	}

	// Viewport and scissor
	viewport := VkViewport{x = 0.0, y = 0.0, width = f32(width), height = f32(height), minDepth = 0.0, maxDepth = 1.0}
	scissor := VkRect2D{offset = {0, 0}, extent = {width, height}}
	viewport_state := VkPipelineViewportStateCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1, pViewports = &viewport,
		scissorCount = 1, pScissors = &scissor,
	}

	// Rasterizer - fill triangles
	rasterizer := VkPipelineRasterizationStateCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = VK_FALSE, rasterizerDiscardEnable = VK_FALSE,
		polygonMode = VK_POLYGON_MODE_FILL, lineWidth = 1.0,
		cullMode = 0, frontFace = VK_FRONT_FACE_CLOCKWISE, depthBiasEnable = VK_FALSE,
	}

	// Multisampling - disabled
	multisampling := VkPipelineMultisampleStateCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable = VK_FALSE, rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
	}

	// Color blending - no blending, just write colors
	color_blend_attachment := VkPipelineColorBlendAttachmentState{
		blendEnable = 0,
		colorWriteMask = c.uint32_t(VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT),
	}
	color_blending := VkPipelineColorBlendStateCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = VK_FALSE, attachmentCount = 1, pAttachments = &color_blend_attachment,
	}

	// Pipeline layout - for push constants (time)
	push_constant_range := VkPushConstantRange{stageFlags = VK_SHADER_STAGE_VERTEX_BIT, offset = 0, size = size_of(f32)}
	pipeline_layout_info := VkPipelineLayoutCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1, pPushConstantRanges = &push_constant_range,
	}
	if vkCreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout) != VK_SUCCESS {
		fmt.println("Failed to create pipeline layout")
		return false
	}

	// Create the graphics pipeline
	pipeline_info := VkGraphicsPipelineCreateInfo{
		sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
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
		basePipelineHandle = VK_NULL_HANDLE, basePipelineIndex = -1,
	}

	if vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, nil, &graphics_pipeline) != VK_SUCCESS {
		fmt.println("Failed to create graphics pipeline")
		return false
	}

	return true
}


record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	// Begin command buffer
	begin_info := VkCommandBufferBeginInfo{
		sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
		flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
	}
	vkResetCommandBuffer(element.commandBuffer, 0)
	vkBeginCommandBuffer(element.commandBuffer, &begin_info)

	// Begin render pass (clears screen to black)
	clear_value := VkClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}}
	render_pass_begin := VkRenderPassBeginInfo{
		sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = element.framebuffer,
		renderArea = {offset = {0, 0}, extent = {width, height}},
		clearValueCount = 1, pClearValues = &clear_value,
	}

	vkCmdBeginRenderPass(element.commandBuffer, &render_pass_begin, VK_SUBPASS_CONTENTS_INLINE)

	// Bind pipeline
	vkCmdBindPipeline(element.commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, graphics_pipeline)

	// Push time constant for rotation
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
	vkCmdPushConstants(element.commandBuffer, pipeline_layout, VK_SHADER_STAGE_VERTEX_BIT, 0, size_of(f32), &elapsed_time)

	// Draw triangle (3 vertices, 1 instance)
	vkCmdDraw(element.commandBuffer, 3, 1, 0, 0)

	// End render pass and command buffer
	vkCmdEndRenderPass(element.commandBuffer)
	vkEndCommandBuffer(element.commandBuffer)
}

