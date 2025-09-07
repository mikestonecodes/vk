package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"
import vk "vendor:vulkan"

// Global variables for compute pipeline
particle_buffer: vk.Buffer
particle_buffer_memory: vk.DeviceMemory
descriptor_set_layout: vk.DescriptorSetLayout
descriptor_pool: vk.DescriptorPool
descriptor_set: vk.DescriptorSet
compute_pipeline: vk.Pipeline
compute_pipeline_layout: vk.PipelineLayout

// Post-processing variables
offscreen_image: vk.Image
offscreen_image_memory: vk.DeviceMemory
offscreen_image_view: vk.ImageView
offscreen_framebuffer: vk.Framebuffer
offscreen_render_pass: vk.RenderPass
post_process_pipeline: vk.Pipeline
post_process_pipeline_layout: vk.PipelineLayout
post_process_descriptor_set_layout: vk.DescriptorSetLayout
post_process_descriptor_set: vk.DescriptorSet
texture_sampler: vk.Sampler

PostProcessPushConstants :: struct {
    time: f32,
    intensity: f32,
}

PARTICLE_COUNT :: 1000000

ComputePushConstants :: struct {
	time: f32,
	particle_count: u32,
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	// Begin command buffer
	begin_info := vk.CommandBufferBeginInfo{
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}
	vk.ResetCommandBuffer(element.commandBuffer, {})
	vk.BeginCommandBuffer(element.commandBuffer, &begin_info)

	// Dispatch compute shader to update particles
	vk.CmdBindPipeline(element.commandBuffer, vk.PipelineBindPoint.COMPUTE, compute_pipeline)
	vk.CmdBindDescriptorSets(element.commandBuffer, vk.PipelineBindPoint.COMPUTE, compute_pipeline_layout, 0, 1, &descriptor_set, 0, nil)
	
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
	compute_push_constants := ComputePushConstants{time = elapsed_time, particle_count = PARTICLE_COUNT}
	vk.CmdPushConstants(element.commandBuffer, compute_pipeline_layout, {vk.ShaderStageFlag.COMPUTE}, 0, size_of(ComputePushConstants), &compute_push_constants)
	
	// Dispatch compute shader (64 threads per workgroup)
	workgroup_count := u32((PARTICLE_COUNT + 63) / 64)
	vk.CmdDispatch(element.commandBuffer, workgroup_count, 1, 1)

	// Memory barrier to ensure compute shader writes are visible to vertex shader
	memory_barrier := vk.MemoryBarrier{
		sType = vk.StructureType.MEMORY_BARRIER,
		srcAccessMask = {vk.AccessFlag.SHADER_WRITE},
		dstAccessMask = {vk.AccessFlag.VERTEX_ATTRIBUTE_READ},
	}
	vk.CmdPipelineBarrier(
		element.commandBuffer,
		{vk.PipelineStageFlag.COMPUTE_SHADER},
		{vk.PipelineStageFlag.VERTEX_INPUT},
		{},
		1, &memory_barrier,
		0, nil,
		0, nil,
	)

	// FIRST PASS: Render particles to offscreen buffer
	clear_value := vk.ClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}}
	offscreen_render_pass_begin := vk.RenderPassBeginInfo{
		sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass = offscreen_render_pass,
		framebuffer = offscreen_framebuffer,
		renderArea = {offset = {0, 0}, extent = {width, height}},
		clearValueCount = 1, pClearValues = &clear_value,
	}

	vk.CmdBeginRenderPass(element.commandBuffer, &offscreen_render_pass_begin, vk.SubpassContents.INLINE)

	// Bind graphics pipeline and descriptor set
	vk.CmdBindPipeline(element.commandBuffer, vk.PipelineBindPoint.GRAPHICS, graphics_pipeline)
	vk.CmdBindDescriptorSets(element.commandBuffer, vk.PipelineBindPoint.GRAPHICS, pipeline_layout, 0, 1, &descriptor_set, 0, nil)

	// Draw particles (6 vertices per quad, many instances)
	vk.CmdDraw(element.commandBuffer, 6, PARTICLE_COUNT, 0, 0)

	// End offscreen render pass
	vk.CmdEndRenderPass(element.commandBuffer)

	// Image layout transition for post-processing
	barrier := vk.ImageMemoryBarrier{
		sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
		srcAccessMask = {vk.AccessFlag.COLOR_ATTACHMENT_WRITE},
		dstAccessMask = {vk.AccessFlag.SHADER_READ},
		oldLayout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
		newLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = offscreen_image,
		subresourceRange = {
			aspectMask = {vk.ImageAspectFlag.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	
	vk.CmdPipelineBarrier(
		element.commandBuffer,
		{vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
		{vk.PipelineStageFlag.FRAGMENT_SHADER},
		{},
		0, nil,
		0, nil,
		1, &barrier,
	)

	// SECOND PASS: Post-processing to swapchain
	final_render_pass_begin := vk.RenderPassBeginInfo{
		sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass = render_pass,
		framebuffer = element.framebuffer,
		renderArea = {offset = {0, 0}, extent = {width, height}},
		clearValueCount = 1, pClearValues = &clear_value,
	}

	vk.CmdBeginRenderPass(element.commandBuffer, &final_render_pass_begin, vk.SubpassContents.INLINE)

	// Bind post-processing pipeline
	vk.CmdBindPipeline(element.commandBuffer, vk.PipelineBindPoint.GRAPHICS, post_process_pipeline)
	vk.CmdBindDescriptorSets(element.commandBuffer, vk.PipelineBindPoint.GRAPHICS, post_process_pipeline_layout, 0, 1, &post_process_descriptor_set, 0, nil)

	// Push constants for post-processing
	post_push_constants := PostProcessPushConstants{time = elapsed_time, intensity = 1.0}
	vk.CmdPushConstants(element.commandBuffer, post_process_pipeline_layout, {vk.ShaderStageFlag.FRAGMENT}, 0, size_of(PostProcessPushConstants), &post_push_constants)

	// Draw fullscreen triangle
	vk.CmdDraw(element.commandBuffer, 3, 1, 0, 0)

	// End render pass and command buffer
	vk.CmdEndRenderPass(element.commandBuffer)
	vk.EndCommandBuffer(element.commandBuffer)
}


create_graphics_pipeline :: proc() -> bool {
	// Create storage buffer for particles first
	if !create_particle_buffer() {
		return false
	}

	// Create descriptor set layout
	if !create_descriptor_set_layout() {
		return false
	}

	// Create descriptor pool and sets
	if !create_descriptor_sets() {
		return false
	}

	// Create compute pipeline
	if !create_compute_pipeline() {
		return false
	}

	// Create post-processing resources
	if !create_post_process_resources() {
		return false
	}

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

	// Pipeline layout - no push constants for graphics pipeline, just descriptor sets
	pipeline_layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1, pSetLayouts = &descriptor_set_layout,
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

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(phys_device, &mem_properties)
	
	for i in 0..<mem_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 && (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i
		}
	}
	return 0
}

create_particle_buffer :: proc() -> bool {
	Particle :: struct {
		position: [2]f32,
		color: [3]f32,
		_padding: f32,
	}
	
	buffer_size := vk.DeviceSize(PARTICLE_COUNT * size_of(Particle))
	
	buffer_info := vk.BufferCreateInfo{
		sType = vk.StructureType.BUFFER_CREATE_INFO,
		size = buffer_size,
		usage = {vk.BufferUsageFlag.STORAGE_BUFFER},
		sharingMode = vk.SharingMode.EXCLUSIVE,
	}
	
	if vk.CreateBuffer(device, &buffer_info, nil, &particle_buffer) != vk.Result.SUCCESS {
		fmt.println("Failed to create particle buffer")
		return false
	}
	
	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, particle_buffer, &mem_requirements)
	
	alloc_info := vk.MemoryAllocateInfo{
		sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, {vk.MemoryPropertyFlag.DEVICE_LOCAL}),
	}
	
	if vk.AllocateMemory(device, &alloc_info, nil, &particle_buffer_memory) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate particle buffer memory")
		return false
	}
	
	vk.BindBufferMemory(device, particle_buffer, particle_buffer_memory, 0)
	return true
}

create_descriptor_set_layout :: proc() -> bool {
	binding := vk.DescriptorSetLayoutBinding{
		binding = 0,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
		stageFlags = {vk.ShaderStageFlag.VERTEX, vk.ShaderStageFlag.COMPUTE},
	}
	
	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings = &binding,
	}
	
	if vk.CreateDescriptorSetLayout(device, &layout_info, nil, &descriptor_set_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create descriptor set layout")
		return false
	}
	
	return true
}

create_descriptor_sets :: proc() -> bool {
	pool_size := vk.DescriptorPoolSize{
		type = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
	}
	
	pool_info := vk.DescriptorPoolCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = 1,
		pPoolSizes = &pool_size,
		maxSets = 1,
	}
	
	if vk.CreateDescriptorPool(device, &pool_info, nil, &descriptor_pool) != vk.Result.SUCCESS {
		fmt.println("Failed to create descriptor pool")
		return false
	}
	
	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts = &descriptor_set_layout,
	}
	
	if vk.AllocateDescriptorSets(device, &alloc_info, &descriptor_set) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate descriptor sets")
		return false
	}
	
	buffer_info := vk.DescriptorBufferInfo{
		buffer = particle_buffer,
		offset = 0,
		range = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	
	descriptor_write := vk.WriteDescriptorSet{
		sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
		dstSet = descriptor_set,
		dstBinding = 0,
		dstArrayElement = 0,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
		pBufferInfo = &buffer_info,
	}
	
	vk.UpdateDescriptorSets(device, 1, &descriptor_write, 0, nil)
	return true
}

create_compute_pipeline :: proc() -> bool {
	compute_shader_code, compute_ok := load_shader_spirv("compute.spv")
	if !compute_ok {
		fmt.println("Failed to load compute shader")
		return false
	}
	defer delete(compute_shader_code)
	
	compute_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(compute_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(compute_shader_code),
	}
	compute_shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &compute_shader_create_info, nil, &compute_shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create compute shader module")
		return false
	}
	defer vk.DestroyShaderModule(device, compute_shader_module, nil)
	
	push_constant_range := vk.PushConstantRange{
		stageFlags = {vk.ShaderStageFlag.COMPUTE},
		offset = 0,
		size = size_of(ComputePushConstants),
	}
	
	compute_pipeline_layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}
	
	if vk.CreatePipelineLayout(device, &compute_pipeline_layout_info, nil, &compute_pipeline_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create compute pipeline layout")
		return false
	}
	
	compute_pipeline_info := vk.ComputePipelineCreateInfo{
		sType = vk.StructureType.COMPUTE_PIPELINE_CREATE_INFO,
		stage = {
			sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {vk.ShaderStageFlag.COMPUTE},
			module = compute_shader_module,
			pName = "main",
		},
		layout = compute_pipeline_layout,
	}
	
	if vk.CreateComputePipelines(device, {}, 1, &compute_pipeline_info, nil, &compute_pipeline) != vk.Result.SUCCESS {
		fmt.println("Failed to create compute pipeline")
		return false
	}
	
	return true
}

create_post_process_resources :: proc() -> bool {
	// Create offscreen image
	if !create_offscreen_image() {
		return false
	}
	
	// Create offscreen render pass
	if !create_offscreen_render_pass() {
		return false
	}
	
	// Create offscreen framebuffer
	if !create_offscreen_framebuffer() {
		return false
	}
	
	// Create texture sampler
	if !create_texture_sampler() {
		return false
	}
	
	// Create post-process descriptor set layout
	if !create_post_process_descriptor_set_layout() {
		return false
	}
	
	// Update descriptor pool to include post-processing descriptors
	if !create_post_process_descriptor_sets() {
		return false
	}
	
	// Create post-processing pipeline
	if !create_post_process_pipeline() {
		return false
	}
	
	return true
}

create_offscreen_image :: proc() -> bool {
	image_info := vk.ImageCreateInfo{
		sType = vk.StructureType.IMAGE_CREATE_INFO,
		imageType = vk.ImageType.D2,
		extent = {width = width, height = height, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		format = format,
		tiling = vk.ImageTiling.OPTIMAL,
		initialLayout = vk.ImageLayout.UNDEFINED,
		usage = {vk.ImageUsageFlag.COLOR_ATTACHMENT, vk.ImageUsageFlag.SAMPLED},
		samples = {vk.SampleCountFlag._1},
		sharingMode = vk.SharingMode.EXCLUSIVE,
	}
	
	if vk.CreateImage(device, &image_info, nil, &offscreen_image) != vk.Result.SUCCESS {
		fmt.println("Failed to create offscreen image")
		return false
	}
	
	mem_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, offscreen_image, &mem_requirements)
	
	alloc_info := vk.MemoryAllocateInfo{
		sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, {vk.MemoryPropertyFlag.DEVICE_LOCAL}),
	}
	
	if vk.AllocateMemory(device, &alloc_info, nil, &offscreen_image_memory) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate offscreen image memory")
		return false
	}
	
	vk.BindImageMemory(device, offscreen_image, offscreen_image_memory, 0)
	
	// Create image view
	view_info := vk.ImageViewCreateInfo{
		sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
		image = offscreen_image,
		viewType = vk.ImageViewType.D2,
		format = format,
		subresourceRange = {
			aspectMask = {vk.ImageAspectFlag.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}
	
	if vk.CreateImageView(device, &view_info, nil, &offscreen_image_view) != vk.Result.SUCCESS {
		fmt.println("Failed to create offscreen image view")
		return false
	}
	
	return true
}

create_offscreen_render_pass :: proc() -> bool {
	attachment := vk.AttachmentDescription{
		format = format,
		samples = {vk.SampleCountFlag._1},
		loadOp = vk.AttachmentLoadOp.CLEAR,
		storeOp = vk.AttachmentStoreOp.STORE,
		stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE,
		stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE,
		initialLayout = vk.ImageLayout.UNDEFINED,
		finalLayout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
	}
	
	attachment_ref := vk.AttachmentReference{
		attachment = 0,
		layout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
	}
	
	subpass := vk.SubpassDescription{
		pipelineBindPoint = vk.PipelineBindPoint.GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments = &attachment_ref,
	}
	
	render_pass_info := vk.RenderPassCreateInfo{
		sType = vk.StructureType.RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments = &attachment,
		subpassCount = 1,
		pSubpasses = &subpass,
	}
	
	if vk.CreateRenderPass(device, &render_pass_info, nil, &offscreen_render_pass) != vk.Result.SUCCESS {
		fmt.println("Failed to create offscreen render pass")
		return false
	}
	
	return true
}

create_offscreen_framebuffer :: proc() -> bool {
	fb_info := vk.FramebufferCreateInfo{
		sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
		renderPass = offscreen_render_pass,
		attachmentCount = 1,
		pAttachments = &offscreen_image_view,
		width = width,
		height = height,
		layers = 1,
	}
	
	if vk.CreateFramebuffer(device, &fb_info, nil, &offscreen_framebuffer) != vk.Result.SUCCESS {
		fmt.println("Failed to create offscreen framebuffer")
		return false
	}
	
	return true
}

create_texture_sampler :: proc() -> bool {
	sampler_info := vk.SamplerCreateInfo{
		sType = vk.StructureType.SAMPLER_CREATE_INFO,
		magFilter = vk.Filter.LINEAR,
		minFilter = vk.Filter.LINEAR,
		addressModeU = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		addressModeV = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		addressModeW = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		anisotropyEnable = false,
		maxAnisotropy = 1.0,
		borderColor = vk.BorderColor.INT_OPAQUE_BLACK,
		unnormalizedCoordinates = false,
		compareEnable = false,
		compareOp = vk.CompareOp.ALWAYS,
		mipmapMode = vk.SamplerMipmapMode.LINEAR,
		mipLodBias = 0.0,
		minLod = 0.0,
		maxLod = 0.0,
	}
	
	if vk.CreateSampler(device, &sampler_info, nil, &texture_sampler) != vk.Result.SUCCESS {
		fmt.println("Failed to create texture sampler")
		return false
	}
	
	return true
}

create_post_process_descriptor_set_layout :: proc() -> bool {
	bindings := [2]vk.DescriptorSetLayoutBinding{
		{
			binding = 0,
			descriptorType = vk.DescriptorType.SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		},
		{
			binding = 1,
			descriptorType = vk.DescriptorType.SAMPLER,
			descriptorCount = 1,
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		},
	}
	
	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings = raw_data(bindings[:]),
	}
	
	if vk.CreateDescriptorSetLayout(device, &layout_info, nil, &post_process_descriptor_set_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create post-process descriptor set layout")
		return false
	}
	
	return true
}

create_post_process_descriptor_sets :: proc() -> bool {
	// We need to recreate the descriptor pool to include post-processing descriptors
	vk.DestroyDescriptorPool(device, descriptor_pool, nil)
	
	pool_sizes := [3]vk.DescriptorPoolSize{
		{type = vk.DescriptorType.STORAGE_BUFFER, descriptorCount = 1},
		{type = vk.DescriptorType.SAMPLED_IMAGE, descriptorCount = 1},
		{type = vk.DescriptorType.SAMPLER, descriptorCount = 1},
	}
	
	pool_info := vk.DescriptorPoolCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = len(pool_sizes),
		pPoolSizes = raw_data(pool_sizes[:]),
		maxSets = 2,
	}
	
	if vk.CreateDescriptorPool(device, &pool_info, nil, &descriptor_pool) != vk.Result.SUCCESS {
		fmt.println("Failed to recreate descriptor pool")
		return false
	}
	
	// Reallocate the original descriptor set
	layouts := [2]vk.DescriptorSetLayout{descriptor_set_layout, post_process_descriptor_set_layout}
	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = descriptor_pool,
		descriptorSetCount = 2,
		pSetLayouts = raw_data(layouts[:]),
	}
	
	descriptor_sets := [2]vk.DescriptorSet{}
	if vk.AllocateDescriptorSets(device, &alloc_info, raw_data(descriptor_sets[:])) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate descriptor sets")
		return false
	}
	
	descriptor_set = descriptor_sets[0]
	post_process_descriptor_set = descriptor_sets[1]
	
	// Update particle buffer descriptor
	buffer_info := vk.DescriptorBufferInfo{
		buffer = particle_buffer,
		offset = 0,
		range = vk.DeviceSize(vk.WHOLE_SIZE),
	}
	
	particle_descriptor_write := vk.WriteDescriptorSet{
		sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
		dstSet = descriptor_set,
		dstBinding = 0,
		dstArrayElement = 0,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
		pBufferInfo = &buffer_info,
	}
	
	// Update post-processing descriptors
	image_info := vk.DescriptorImageInfo{
		imageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
		imageView = offscreen_image_view,
	}
	
	sampler_info := vk.DescriptorImageInfo{
		sampler = texture_sampler,
	}
	
	post_process_writes := [3]vk.WriteDescriptorSet{
		particle_descriptor_write,
		{
			sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet = post_process_descriptor_set,
			dstBinding = 0,
			dstArrayElement = 0,
			descriptorType = vk.DescriptorType.SAMPLED_IMAGE,
			descriptorCount = 1,
			pImageInfo = &image_info,
		},
		{
			sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet = post_process_descriptor_set,
			dstBinding = 1,
			dstArrayElement = 0,
			descriptorType = vk.DescriptorType.SAMPLER,
			descriptorCount = 1,
			pImageInfo = &sampler_info,
		},
	}
	
	vk.UpdateDescriptorSets(device, len(post_process_writes), raw_data(post_process_writes[:]), 0, nil)
	return true
}

create_post_process_pipeline :: proc() -> bool {
	post_shader_code, post_ok := load_shader_spirv("post_process.spv")
	if !post_ok {
		fmt.println("Failed to load post-process shader")
		return false
	}
	defer delete(post_shader_code)
	
	// Create shader modules (both vertex and fragment use same WGSL file)
	post_vert_shader_create_info := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(post_shader_code) * size_of(c.uint32_t),
		pCode = raw_data(post_shader_code),
	}
	post_vert_shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &post_vert_shader_create_info, nil, &post_vert_shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create post-process vertex shader module")
		return false
	}
	defer vk.DestroyShaderModule(device, post_vert_shader_module, nil)
	
	post_frag_shader_module: vk.ShaderModule
	if vk.CreateShaderModule(device, &post_vert_shader_create_info, nil, &post_frag_shader_module) != vk.Result.SUCCESS {
		fmt.println("Failed to create post-process fragment shader module")
		return false
	}
	defer vk.DestroyShaderModule(device, post_frag_shader_module, nil)
	
	// Pipeline stages
	post_shader_stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.VERTEX}, module = post_vert_shader_module, pName = "vs_main"},
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.FRAGMENT}, module = post_frag_shader_module, pName = "fs_main"},
	}
	
	// Vertex input - no vertex buffers
	vertex_input_info := vk.PipelineVertexInputStateCreateInfo{sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	
	// Input assembly
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
	
	// Rasterizer
	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		depthClampEnable = false, rasterizerDiscardEnable = false,
		polygonMode = vk.PolygonMode.FILL, lineWidth = 1.0,
		cullMode = {}, frontFace = vk.FrontFace.CLOCKWISE, depthBiasEnable = false,
	}
	
	// Multisampling
	multisampling := vk.PipelineMultisampleStateCreateInfo{
		sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		sampleShadingEnable = false, rasterizationSamples = {vk.SampleCountFlag._1},
	}
	
	// Color blending
	color_blend_attachment := vk.PipelineColorBlendAttachmentState{
		blendEnable = false,
		colorWriteMask = {vk.ColorComponentFlag.R, vk.ColorComponentFlag.G, vk.ColorComponentFlag.B, vk.ColorComponentFlag.A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo{
		sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		logicOpEnable = false, attachmentCount = 1, pAttachments = &color_blend_attachment,
	}
	
	// Pipeline layout with push constants
	push_constant_range := vk.PushConstantRange{
		stageFlags = {vk.ShaderStageFlag.FRAGMENT},
		offset = 0,
		size = size_of(PostProcessPushConstants),
	}
	
	post_pipeline_layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &post_process_descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_constant_range,
	}
	
	if vk.CreatePipelineLayout(device, &post_pipeline_layout_info, nil, &post_process_pipeline_layout) != vk.Result.SUCCESS {
		fmt.println("Failed to create post-process pipeline layout")
		return false
	}
	
	// Create the post-processing pipeline
	post_pipeline_info := vk.GraphicsPipelineCreateInfo{
		sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = raw_data(post_shader_stages[:]),
		pVertexInputState = &vertex_input_info,
		pInputAssemblyState = &input_assembly,
		pViewportState = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState = &multisampling,
		pColorBlendState = &color_blending,
		layout = post_process_pipeline_layout,
		renderPass = render_pass,
		subpass = 0,
		basePipelineHandle = {}, basePipelineIndex = -1,
	}
	
	if vk.CreateGraphicsPipelines(device, {}, 1, &post_pipeline_info, nil, &post_process_pipeline) != vk.Result.SUCCESS {
		fmt.println("Failed to create post-process pipeline")
		return false
	}
	
	return true
}

