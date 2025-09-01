package main
import "core:c"
import "core:time"

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

	// Push time constant for animation
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
	vkCmdPushConstants(element.commandBuffer, pipeline_layout, VK_SHADER_STAGE_TASK_BIT_NV | VK_SHADER_STAGE_MESH_BIT_NV, 0, size_of(f32), &elapsed_time)

	// Dispatch single mesh task for 16x16 grid
	vkCmdDrawMeshTasksNV(element.commandBuffer, 1, 0)

	// End render pass and command buffer
	vkCmdEndRenderPass(element.commandBuffer)
	vkEndCommandBuffer(element.commandBuffer)
}


create_graphics_pipeline :: proc() -> bool {
	// Load compiled shaders
	task_shader_code, task_ok := load_shader_spirv("task.spv")
	if !task_ok {
		return false
	}
	defer delete(task_shader_code)

	mesh_shader_code, mesh_ok := load_shader_spirv("mesh.spv")
	if !mesh_ok {
		return false
	}
	defer delete(mesh_shader_code)

	fragment_shader_code, frag_ok := load_shader_spirv("fragment.spv")
	if !frag_ok {
		return false
	}
	defer delete(fragment_shader_code)

	// Create shader modules
	task_shader_create_info := VkShaderModuleCreateInfo{
		sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		codeSize = len(task_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(task_shader_code),
	}
	task_shader_module: VkShaderModule
	if vkCreateShaderModule(device, &task_shader_create_info, nil, &task_shader_module) != VK_SUCCESS {
		return false
	}
	defer vkDestroyShaderModule(device, task_shader_module, nil)

	mesh_shader_create_info := VkShaderModuleCreateInfo{
		sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		codeSize = len(mesh_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(mesh_shader_code),
	}
	mesh_shader_module: VkShaderModule
	if vkCreateShaderModule(device, &mesh_shader_create_info, nil, &mesh_shader_module) != VK_SUCCESS {
		return false
	}
	defer vkDestroyShaderModule(device, mesh_shader_module, nil)

	frag_shader_create_info := VkShaderModuleCreateInfo{
		sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
		codeSize = len(fragment_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(fragment_shader_code),
	}
	frag_shader_module: VkShaderModule
	if vkCreateShaderModule(device, &frag_shader_create_info, nil, &frag_shader_module) != VK_SUCCESS {
		return false
	}
	defer vkDestroyShaderModule(device, frag_shader_module, nil)

	// Pipeline stages - task, mesh and fragment shaders
	shader_stages := [3]VkPipelineShaderStageCreateInfo{
		{sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, stage = VK_SHADER_STAGE_TASK_BIT_NV, module = task_shader_module, pName = "task_main"},
		{sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, stage = VK_SHADER_STAGE_MESH_BIT_NV, module = mesh_shader_module, pName = "mesh_main"},
		{sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, stage = VK_SHADER_STAGE_FRAGMENT_BIT, module = frag_shader_module, pName = "fs_main"},
	}

	// Mesh shaders don't use vertex input or input assembly

	// Viewport and scissor - maintain aspect ratio
	aspect_ratio := f32(width) / f32(height)
	viewport_width, viewport_height: f32
	viewport_x, viewport_y: f32

	if aspect_ratio > 1.0 {
		// Window is wider than tall
		viewport_height = f32(height)
		viewport_width = viewport_height
		viewport_x = (f32(width) - viewport_width) / 2.0
		viewport_y = 0.0
	} else {
		// Window is taller than wide
		viewport_width = f32(width)
		viewport_height = viewport_width
		viewport_x = 0.0
		viewport_y = (f32(height) - viewport_height) / 2.0
	}

	viewport := VkViewport{x = viewport_x, y = viewport_y, width = viewport_width, height = viewport_height, minDepth = 0.0, maxDepth = 1.0}
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
	push_constant_range := VkPushConstantRange{stageFlags = VK_SHADER_STAGE_TASK_BIT_NV | VK_SHADER_STAGE_MESH_BIT_NV, offset = 0, size = size_of(f32)}
	pipeline_layout_info := VkPipelineLayoutCreateInfo{
		sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
		pushConstantRangeCount = 1, pPushConstantRanges = &push_constant_range,
	}
	if vkCreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout) != VK_SUCCESS {
		return false
	}

	// Create the graphics pipeline
	pipeline_info := VkGraphicsPipelineCreateInfo{
		sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 3, pStages = raw_data(shader_stages[:]),
		pVertexInputState = nil,  // Mesh shaders don't use vertex input
		pInputAssemblyState = nil,  // Mesh shaders don't use input assembly
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
		return false
	}

	return true
}



