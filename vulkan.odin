package main
import "base:runtime"
import "core:fmt"
import "core:time"
import vk "vendor:vulkan"

ENABLE_VALIDATION := true
MAX_FRAMES_IN_FLIGHT :: 2
MAX_SWAPCHAIN_IMAGES :: 3

//───────────────────────────
// TYPE MAPPINGS (for vulkan package files)
//───────────────────────────
DeviceSize :: vk.DeviceSize
BufferUsageFlags :: vk.BufferUsageFlags
ShaderStageFlags :: vk.ShaderStageFlags
DescriptorType :: vk.DescriptorType

BufferResource :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

TextureResource :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
}

CommandEncoder :: struct {
	command_buffer: vk.CommandBuffer,
}

FrameInputs :: struct {
	cmd:        vk.CommandBuffer,
	time:       f32,
	delta_time: f32,
}

SwapchainElement :: struct {
	commandBuffer: vk.CommandBuffer,
	image:         vk.Image,
	imageView:     vk.ImageView,
	layout:        vk.ImageLayout,
}

PushConstantInfo :: struct {
	label: string,
	stage: vk.ShaderStageFlags,
	size:  u32,
}

ShaderProgramConfig :: struct {
	compute_module:  string,
	vertex_module:   string,
	fragment_module: string,
	push:            PushConstantInfo,
}

DescriptorBindingSpec :: struct {
	binding:          u32,
	descriptor_type:  vk.DescriptorType,
	descriptor_count: u32,
	stage_flags:      vk.ShaderStageFlags,
}

//───────────────────────────
// GLOBALS
//───────────────────────────
instance: vk.Instance
vulkan_surface: vk.SurfaceKHR
phys_device: vk.PhysicalDevice
device: vk.Device
queue_family_index: u32
queue: vk.Queue
command_pool: vk.CommandPool
swapchain: vk.SwapchainKHR
format: vk.Format
image_index, image_count: u32
debug_messenger: vk.DebugUtilsMessengerEXT


image_available_semaphores: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
in_flight_fences: [MAX_FRAMES_IN_FLIGHT]vk.Fence

current_frame: u32 = 0

render_finished_semaphores: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore
elements: [MAX_SWAPCHAIN_IMAGES]SwapchainElement

//───────────────────────────
// SYNC + FRAME
//───────────────────────────
init_sync_objects :: proc() -> bool {
	sem_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {vk.FenceCreateFlag.SIGNALED}, // don't stall on first frame
	}

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		vk.CreateSemaphore(device, &sem_info, nil, &image_available_semaphores[i])
		vk.CreateFence(device, &fence_info, nil, &in_flight_fences[i])
	}
	for i in 0 ..< MAX_SWAPCHAIN_IMAGES {
		vk.CreateSemaphore(device, &sem_info, nil, &render_finished_semaphores[i])
	}
	return true
}


render_frame :: proc(start_time: time.Time) -> bool {
	// Wait until this frame's fence signals (GPU done with this slot)
	vk.WaitForFences(device, 1, &in_flight_fences[current_frame], true, max(u64))
	vk.ResetFences(device, 1, &in_flight_fences[current_frame])

	// Acquire next image for this frame
	result := vk.AcquireNextImageKHR(
		device,
		swapchain,
		max(u64),
		image_available_semaphores[current_frame],
		{},
		&image_index,
	)


	e := &elements[image_index]

	// Record work
	enc, f := begin_frame_commands(e, start_time)
	record_commands(e, f)
	transition_to_present(f.cmd, e)

	vk.EndCommandBuffer(enc.command_buffer)

	stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}

	// Submit this frame
	wait_sem := image_available_semaphores[current_frame]
	signal_sem := render_finished_semaphores[image_index]
	submit_info := vk.SubmitInfo {
		sType                = .SUBMIT_INFO,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &wait_sem,
		pWaitDstStageMask    = &stage,
		commandBufferCount   = 1,
		pCommandBuffers      = &e.commandBuffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &signal_sem,
	}
	vk.QueueSubmit(queue, 1, &submit_info, in_flight_fences[current_frame])

	// Present
	present_info := vk.PresentInfoKHR {
		sType              = .PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &signal_sem,
		swapchainCount     = 1,
		pSwapchains        = &swapchain,
		pImageIndices      = &image_index,
	}
	result = vk.QueuePresentKHR(queue, &present_info)

	// Cycle to next frame slot
	current_frame = (current_frame + 1) % MAX_FRAMES_IN_FLIGHT

	return result == .SUCCESS || result == .SUBOPTIMAL_KHR
}

//───────────────────────────
// INSTANCE + DEVICE
//───────────────────────────
instance_extensions: Array(16, cstring)

get_instance_extensions :: proc() -> []cstring {
	instance_extensions.len = 0

	for ext in get_required_instance_extensions() {
		array_push(&instance_extensions, ext)
	}
	if ENABLE_VALIDATION {
		array_push(&instance_extensions, "VK_EXT_debug_utils")
		array_push(&instance_extensions, "VK_EXT_layer_settings")
	}

	return array_slice(&instance_extensions)
}

setup_physical_device :: proc() -> bool {
	count: u32
	if vk.EnumeratePhysicalDevices(instance, &count, nil) != .SUCCESS || count == 0 {
		fmt.println("No GPUs found");return false
	}
	devs := Array(8, vk.PhysicalDevice){}
	for i in 0 ..< count {
		array_push(&devs, vk.PhysicalDevice{})
	}
	vk.EnumeratePhysicalDevices(instance, &count, raw_data(array_slice(&devs)))

	for i in 0 ..< count {
		qcount: u32
		vk.GetPhysicalDeviceQueueFamilyProperties(devs.data[i], &qcount, nil)
		qprops := Array(16, vk.QueueFamilyProperties){}
		for j in 0 ..< qcount {
			array_push(&qprops, vk.QueueFamilyProperties{})
		}
		vk.GetPhysicalDeviceQueueFamilyProperties(
			devs.data[i],
			&qcount,
			raw_data(array_slice(&qprops)),
		)

		for j in 0 ..< qcount {
			support: b32
			vk.GetPhysicalDeviceSurfaceSupportKHR(devs.data[i], j, vulkan_surface, &support)
			if support && vk.QueueFlag.GRAPHICS in qprops.data[j].queueFlags {
				phys_device = devs.data[i];queue_family_index = j;return true
			}
		}
	}
	fmt.println("No graphics queue with present support");return false
}

create_logical_device :: proc() -> bool {
	qp: f32 = 1.0
	qinfo := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_family_index,
		queueCount       = 1,
		pQueuePriorities = &qp,
	}

	feat_shader_obj := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		shaderObject = true,
	}
	feat_dyn := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = .PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		pNext            = &feat_shader_obj,
		dynamicRendering = true,
	}
	feat_sync := vk.PhysicalDeviceSynchronization2Features {
		sType            = .PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		pNext            = &feat_dyn,
		synchronization2 = true,
	}

	//Device extensions
	exts := [?]cstring{"VK_KHR_swapchain", "VK_EXT_shader_object"}
	layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &feat_sync,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &qinfo,
		enabledExtensionCount   = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts[:]),
		enabledLayerCount       = ENABLE_VALIDATION ? 1 : 0,
		ppEnabledLayerNames     = ENABLE_VALIDATION ? &layers[0] : nil,
	}
	if vk.CreateDevice(phys_device, &info, nil, &device) !=
	   .SUCCESS {fmt.println("Device failed");return false}
	vk.GetDeviceQueue(device, queue_family_index, 0, &queue);return true
}

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageType: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()
	severity := "VERBOSE"
	if .INFO in messageSeverity do severity = "INFO"
	if .WARNING in messageSeverity do severity = "WARNING"
	if .ERROR in messageSeverity do severity = "ERROR"
	fmt.printf("[%s] %s\n", severity, pCallbackData.pMessage)
	return false
} //───────────────────────────
// SWAPCHAIN
//───────────────────────────

create_swapchain :: proc() -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &caps)

	// query formats
	fmt_count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &fmt_count, nil)
	if fmt_count == 0 do return false
	if fmt_count > 16 do fmt_count = 16
	fmts: [16]vk.SurfaceFormatKHR
	vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &fmt_count, &fmts[0])
	surface_fmt := fmts[0]

	// choose image count within limits
	img_count := caps.minImageCount + 1
	if caps.maxImageCount > 0 && img_count > caps.maxImageCount {
		img_count = caps.maxImageCount
	}

	sc_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = vulkan_surface,
		minImageCount    = img_count,
		imageFormat      = surface_fmt.format,
		imageColorSpace  = surface_fmt.colorSpace,
		imageExtent      = {window_width, window_height},
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .FIFO, // always valid
		clipped          = true,
	}

	if vk.CreateSwapchainKHR(device, &sc_info, nil, &swapchain) != .SUCCESS {
		fmt.printf("Create failed: %s\n", "swapchain")
		return false
	}

	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil)
	if image_count > MAX_SWAPCHAIN_IMAGES do image_count = MAX_SWAPCHAIN_IMAGES
	imgs: [MAX_SWAPCHAIN_IMAGES]vk.Image
	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, &imgs[0])

	for i in 0 ..< image_count {
		e := &elements[i]
		e.image = imgs[i]
		if vk.CreateImageView(
			device,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = imgs[i],
				viewType = .D2,
				format = surface_fmt.format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			nil,
			&e.imageView,
		) != .SUCCESS {
			fmt.printf("Create failed: %s\n", "view")
			continue
		}
		vk.AllocateCommandBuffers(
			device,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = command_pool,
				level = .PRIMARY,
				commandBufferCount = 1,
			},
			&e.commandBuffer,
		)
		e.layout = .UNDEFINED
	}
	return true
}

// simple image transition helper
transition_to_render :: proc(cmd: vk.CommandBuffer, e: ^SwapchainElement) {

	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
				sType = .IMAGE_MEMORY_BARRIER_2,
				oldLayout = e.layout,
				newLayout = .ATTACHMENT_OPTIMAL,
				srcStageMask = {.BOTTOM_OF_PIPE},
				dstStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstAccessMask = {.COLOR_ATTACHMENT_WRITE},
				image = e.image,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
		},
	)
	e.layout = .ATTACHMENT_OPTIMAL
}

transition_to_present :: proc(cmd: vk.CommandBuffer, e: ^SwapchainElement) {
	vk.CmdPipelineBarrier2(
		cmd,
		&vk.DependencyInfo {
			sType = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers = &vk.ImageMemoryBarrier2 {
				sType = .IMAGE_MEMORY_BARRIER_2,
				oldLayout = e.layout,
				newLayout = .PRESENT_SRC_KHR,
				srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
				dstStageMask = {.BOTTOM_OF_PIPE},
				srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
				image = e.image,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
		},
	)
	e.layout = .PRESENT_SRC_KHR
}


//───────────────────────────
// BUFFERS
//───────────────────────────

find_memory_type :: proc(type_filter: u32, properties: vk.MemoryPropertyFlags) -> u32 {
	mem_properties: vk.PhysicalDeviceMemoryProperties
	vk.GetPhysicalDeviceMemoryProperties(phys_device, &mem_properties)

	for i in 0 ..< mem_properties.memoryTypeCount {
		if (type_filter & (1 << i)) != 0 &&
		   (mem_properties.memoryTypes[i].propertyFlags & properties) == properties {
			return i
		}
	}
	return 0
}

create_buffer :: proc(
	res: ^BufferResource,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	memory_properties: vk.MemoryPropertyFlags = {vk.MemoryPropertyFlag.DEVICE_LOCAL},
) -> bool {
	info := vk.BufferCreateInfo {
		sType       = .BUFFER_CREATE_INFO,
		size        = size,
		usage       = usage,
		sharingMode = .EXCLUSIVE,
	}

	if vk.CreateBuffer(device, &info, nil, &res.buffer) != .SUCCESS {
		fmt.println("Failed to create buffer")
		res^ = BufferResource{}
		return false
	}

	req: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, res.buffer, &req)

	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = req.size,
		memoryTypeIndex = find_memory_type(req.memoryTypeBits, memory_properties),
	}

	if vk.AllocateMemory(device, &alloc, nil, &res.memory) != .SUCCESS {
		fmt.println("Failed to allocate buffer memory")
		vk.DestroyBuffer(device, res.buffer, nil)
		res^ = BufferResource{}
		return false
	}

	vk.BindBufferMemory(device, res.buffer, res.memory, 0)
	res.size = size
	return true
}

destroy_buffer :: proc(resource: ^BufferResource) {
	if resource.buffer != {} {
		vk.DestroyBuffer(device, resource.buffer, nil)
		resource.buffer = {}
	}
	if resource.memory != {} {
		vk.FreeMemory(device, resource.memory, nil)
		resource.memory = {}
	}
	resource.size = 0
}


//───────────────────────────
// MASTER INIT/CLEANUP
//───────────────────────────


vulkan_init :: proc() -> bool {
	vk.load_proc_addresses_global(get_instance_proc_address())
	exts := get_instance_extensions()

	layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	enable_value := b32(true)

	layer_settings := [?]vk.LayerSettingEXT {
		{
			cstring("VK_LAYER_KHRONOS_validation"),
			cstring("validate_best_practices"),
			.BOOL32,
			1,
			&enable_value,
		},
		{
			cstring("VK_LAYER_KHRONOS_validation"),
			cstring("validate_sync"),
			.BOOL32,
			1,
			&enable_value,
		},
	}

	debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR, .INFO, .VERBOSE},
		messageType     = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
	}

	layer_settings_info := vk.LayerSettingsCreateInfoEXT {
		sType        = .LAYER_SETTINGS_CREATE_INFO_EXT,
		settingCount = u32(len(layer_settings)),
		pSettings    = &layer_settings[0],
		pNext        = &debug_create_info,
	}

	vk.CreateInstance(
		&{
			sType = .INSTANCE_CREATE_INFO,
			pApplicationInfo = &vk.ApplicationInfo {
				.APPLICATION_INFO,
				nil,
				"CHAIN OVER",
				0,
				"Odin",
				0,
				vk.API_VERSION_1_3,
			},
			enabledExtensionCount = u32(len(exts)),
			ppEnabledExtensionNames = raw_data(exts),
			enabledLayerCount = ENABLE_VALIDATION ? 1 : 0,
			ppEnabledLayerNames = ENABLE_VALIDATION ? &layers[0] : nil,
			pNext = ENABLE_VALIDATION ? &layer_settings_info : nil,
		},
		nil,
		&instance,
	)

	vk.load_proc_addresses_instance(instance)
	init_window(instance)
	setup_physical_device() or_return
	create_logical_device() or_return
	vk.load_proc_addresses_device(device)

	if ENABLE_VALIDATION {
		vk.CreateDebugUtilsMessengerEXT(
			instance,
			&vk.DebugUtilsMessengerCreateInfoEXT {
				.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
				nil,
				{},
				{.WARNING, .ERROR, .INFO, .VERBOSE},
				{.GENERAL, .VALIDATION, .PERFORMANCE},
				debug_callback,
				nil,
			},
			nil,
			&debug_messenger,
		)
	}

	if vk.CreateCommandPool(
		device,
		&vk.CommandPoolCreateInfo {
			.COMMAND_POOL_CREATE_INFO,
			nil,
			{.RESET_COMMAND_BUFFER},
			queue_family_index,
		},
		nil,
		&command_pool,
	) != .SUCCESS {
		fmt.printf("Create failed: %s\n", "cmd pool")
		return false
	}

	vk.DeviceWaitIdle(device)
	create_swapchain() or_return
	init_sync_objects() or_return
	init_shaders() or_return
	return true
}

handle_resize :: proc() {
	vk.DeviceWaitIdle(device)
	destroy_swapchain()
	create_swapchain()

	resize()
}

destroy_swapchain :: proc() {
	for i in 0 ..< MAX_SWAPCHAIN_IMAGES {
		if elements[i].commandBuffer != {} do vk.FreeCommandBuffers(device, command_pool, 1, &elements[i].commandBuffer)
		if elements[i].imageView != {} do vk.DestroyImageView(device, elements[i].imageView, nil)
		elements[i] = SwapchainElement{}
	}
	if swapchain != {} do vk.DestroySwapchainKHR(device, swapchain, nil)
	swapchain = {}
}

destroy_all_sync_objects :: proc() {
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if image_available_semaphores[i] != {} do vk.DestroySemaphore(device, image_available_semaphores[i], nil)
		if in_flight_fences[i] != {} do vk.DestroyFence(device, in_flight_fences[i], nil)
	}
	for i in 0 ..< MAX_SWAPCHAIN_IMAGES {
		if render_finished_semaphores[i] != {} do vk.DestroySemaphore(device, render_finished_semaphores[i], nil)
	}
}

vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)
	cleanup_shaders()
	cleanup_render_resources()
	destroy_swapchain()
	destroy_all_sync_objects()
	if command_pool != {} do vk.DestroyCommandPool(device, command_pool, nil)
	vk.DestroyDevice(device, nil)
	vk.DestroySurfaceKHR(instance, vulkan_surface, nil)
	if ENABLE_VALIDATION do vk.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
	vk.DestroyInstance(instance, nil)
}
