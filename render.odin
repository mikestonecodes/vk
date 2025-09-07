package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

PARTICLE_COUNT :: 1000000

// Simple variables
particleBuffer: vk.Buffer
particleBufferMemory: vk.DeviceMemory

offscreenImage: vk.Image
offscreenImageMemory: vk.DeviceMemory
offscreenImageView: vk.ImageView

init :: proc() {
	// Nothing to do here
}

init_render_resources :: proc() {
	Particle :: struct {
		position: [2]f32,
		color: [3]f32,
		_padding: f32,
	}
	
	// Create resources only - no descriptors needed
	particleBuffer, particleBufferMemory = createBuffer(PARTICLE_COUNT * size_of(Particle), {vk.BufferUsageFlag.STORAGE_BUFFER})
	offscreenImage, offscreenImageMemory, offscreenImageView = createImage(width, height, format, {vk.ImageUsageFlag.COLOR_ATTACHMENT, vk.ImageUsageFlag.SAMPLED})
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	compute_push := ComputePushConstants {
		time = elapsed_time,
		particle_count = PARTICLE_COUNT,
	}
	vertex_push := VertexPushConstants {
		screen_width = f32(width),
		screen_height = f32(height),
	}
	post_push := PostProcessPushConstants {
		time = elapsed_time,
		intensity = 1.0,
	}
	clear_value := vk.ClearValue {
		color = {float32 = {0.0, 0.0, 0.0, 1.0}},
	}

	passes := []Pass {
		compute_pass(
			"compute.wgsl",
			{u32((PARTICLE_COUNT + 63) / 64), 1, 1},
			{particleBuffer},
			&compute_push,
			size_of(ComputePushConstants),
		),
		graphics_pass(
			"vertex.wgsl",
			"fragment.wgsl",
			offscreen_render_pass,
			offscreen_framebuffer,
			6,
			PARTICLE_COUNT,
			{particleBuffer},
			&vertex_push,
			size_of(VertexPushConstants),
			nil,
			0,
			{clear_value},
		),
		graphics_pass(
			"post_process.wgsl",
			"post_process.wgsl",
			render_pass,
			element.framebuffer,
			3,
			1,
			{struct{ image_view: vk.ImageView, sampler: vk.Sampler }{image_view = offscreenImageView, sampler = texture_sampler}},
			nil,
			0,
			&post_push,
			size_of(PostProcessPushConstants),
			{clear_value},
		),
	}

	execute_passes(&encoder, passes)
	finish_encoding(&encoder)
}

// Generic buffer creation
createBuffer :: proc(size_bytes: int, usage: vk.BufferUsageFlags) -> (vk.Buffer, vk.DeviceMemory) {
	buffer_info := vk.BufferCreateInfo{
		sType = vk.StructureType.BUFFER_CREATE_INFO,
		size = vk.DeviceSize(size_bytes),
		usage = usage,
		sharingMode = vk.SharingMode.EXCLUSIVE,
	}

	buffer: vk.Buffer
	if vk.CreateBuffer(device, &buffer_info, nil, &buffer) != vk.Result.SUCCESS {
		fmt.println("Failed to create buffer")
		return {}, {}
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo{
		sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, {vk.MemoryPropertyFlag.DEVICE_LOCAL}),
	}

	buffer_memory: vk.DeviceMemory
	if vk.AllocateMemory(device, &alloc_info, nil, &buffer_memory) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate buffer memory")
		vk.DestroyBuffer(device, buffer, nil)
		return {}, {}
	}

	vk.BindBufferMemory(device, buffer, buffer_memory, 0)
	return buffer, buffer_memory
}

// Generic image creation
createImage :: proc(w: u32, h: u32, img_format: vk.Format, usage: vk.ImageUsageFlags) -> (vk.Image, vk.DeviceMemory, vk.ImageView) {
	image_info := vk.ImageCreateInfo{
		sType = vk.StructureType.IMAGE_CREATE_INFO,
		imageType = vk.ImageType.D2,
		extent = {width = w, height = h, depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		format = img_format,
		tiling = vk.ImageTiling.OPTIMAL,
		initialLayout = vk.ImageLayout.UNDEFINED,
		usage = usage,
		samples = {vk.SampleCountFlag._1},
		sharingMode = vk.SharingMode.EXCLUSIVE,
	}

	image: vk.Image
	if vk.CreateImage(device, &image_info, nil, &image) != vk.Result.SUCCESS {
		fmt.println("Failed to create image")
		return {}, {}, {}
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, image, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo{
		sType = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, {vk.MemoryPropertyFlag.DEVICE_LOCAL}),
	}

	image_memory: vk.DeviceMemory
	if vk.AllocateMemory(device, &alloc_info, nil, &image_memory) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate image memory")
		vk.DestroyImage(device, image, nil)
		return {}, {}, {}
	}

	vk.BindImageMemory(device, image, image_memory, 0)

	// Create image view
	view_info := vk.ImageViewCreateInfo{
		sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
		image = image,
		viewType = vk.ImageViewType.D2,
		format = img_format,
		subresourceRange = {
			aspectMask = {vk.ImageAspectFlag.COLOR},
			baseMipLevel = 0,
			levelCount = 1,
			baseArrayLayer = 0,
			layerCount = 1,
		},
	}

	image_view: vk.ImageView
	if vk.CreateImageView(device, &view_info, nil, &image_view) != vk.Result.SUCCESS {
		fmt.println("Failed to create image view")
		vk.DestroyImage(device, image, nil)
		vk.FreeMemory(device, image_memory, nil)
		return {}, {}, {}
	}

	return image, image_memory, image_view
}

// Generic storage buffer descriptor
createStorageDescriptor :: proc(buffer: vk.Buffer) -> vk.DescriptorSet {
	binding := vk.DescriptorSetLayoutBinding{
		binding = 0,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
		stageFlags = {vk.ShaderStageFlag.VERTEX, vk.ShaderStageFlag.FRAGMENT, vk.ShaderStageFlag.COMPUTE},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = 1,
		pBindings = &binding,
	}

	layout: vk.DescriptorSetLayout
	vk.CreateDescriptorSetLayout(device, &layout_info, nil, &layout)

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

	pool: vk.DescriptorPool
	vk.CreateDescriptorPool(device, &pool_info, nil, &pool)

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = pool,
		descriptorSetCount = 1,
		pSetLayouts = &layout,
	}

	set: vk.DescriptorSet
	vk.AllocateDescriptorSets(device, &alloc_info, &set)

	buffer_info := vk.DescriptorBufferInfo{
		buffer = buffer,
		offset = 0,
		range = vk.DeviceSize(vk.WHOLE_SIZE),
	}

	write := vk.WriteDescriptorSet{
		sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
		dstSet = set,
		dstBinding = 0,
		descriptorType = vk.DescriptorType.STORAGE_BUFFER,
		descriptorCount = 1,
		pBufferInfo = &buffer_info,
	}

	vk.UpdateDescriptorSets(device, 1, &write, 0, nil)
	return set
}

// Generic texture descriptor
createTextureDescriptor :: proc(imageView: vk.ImageView, sampler: vk.Sampler) -> vk.DescriptorSet {
	bindings := [2]vk.DescriptorSetLayoutBinding{
		{binding = 0, descriptorType = vk.DescriptorType.SAMPLED_IMAGE, descriptorCount = 1, stageFlags = {vk.ShaderStageFlag.FRAGMENT}},
		{binding = 1, descriptorType = vk.DescriptorType.SAMPLER, descriptorCount = 1, stageFlags = {vk.ShaderStageFlag.FRAGMENT}},
	}

	layout_info := vk.DescriptorSetLayoutCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings = raw_data(bindings[:]),
	}

	layout: vk.DescriptorSetLayout
	vk.CreateDescriptorSetLayout(device, &layout_info, nil, &layout)

	pool_sizes := [2]vk.DescriptorPoolSize{
		{type = vk.DescriptorType.SAMPLED_IMAGE, descriptorCount = 1},
		{type = vk.DescriptorType.SAMPLER, descriptorCount = 1},
	}

	pool_info := vk.DescriptorPoolCreateInfo{
		sType = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		poolSizeCount = len(pool_sizes),
		pPoolSizes = raw_data(pool_sizes[:]),
		maxSets = 1,
	}

	pool: vk.DescriptorPool
	vk.CreateDescriptorPool(device, &pool_info, nil, &pool)

	alloc_info := vk.DescriptorSetAllocateInfo{
		sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool = pool,
		descriptorSetCount = 1,
		pSetLayouts = &layout,
	}

	set: vk.DescriptorSet
	vk.AllocateDescriptorSets(device, &alloc_info, &set)

	image_info := vk.DescriptorImageInfo{
		imageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
		imageView = imageView,
	}

	sampler_info := vk.DescriptorImageInfo{
		sampler = sampler,
	}

	writes := [2]vk.WriteDescriptorSet{
		{
			sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet = set,
			dstBinding = 0,
			descriptorType = vk.DescriptorType.SAMPLED_IMAGE,
			descriptorCount = 1,
			pImageInfo = &image_info,
		},
		{
			sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet = set,
			dstBinding = 1,
			descriptorType = vk.DescriptorType.SAMPLER,
			descriptorCount = 1,
			pImageInfo = &sampler_info,
		},
	}

	vk.UpdateDescriptorSets(device, len(writes), raw_data(writes[:]), 0, nil)
	return set
}

getOffscreenImageView :: proc() -> vk.ImageView {
	return offscreenImageView
}

cleanup_render_resources :: proc() {
	if particleBuffer != {} {
		vk.DestroyBuffer(device, particleBuffer, nil)
		vk.FreeMemory(device, particleBufferMemory, nil)
	}
	
	if offscreenImage != {} {
		vk.DestroyImageView(device, offscreenImageView, nil)
		vk.DestroyImage(device, offscreenImage, nil)
		vk.FreeMemory(device, offscreenImageMemory, nil)
	}
}
