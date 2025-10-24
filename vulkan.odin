package main
import "base:runtime"
import "core:fmt"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"

//───────────────────────────
// GLOBALS
//───────────────────────────
ENABLE_VALIDATION := true
instance: vk.Instance
vulkan_surface: vk.SurfaceKHR
phys_device: vk.PhysicalDevice
device: vk.Device
queue_family_index: u32
queue: vk.Queue
command_pool: vk.CommandPool
swapchain: vk.SwapchainKHR
format: vk.Format
width, height: u32
image_index, image_count: u32
debug_messenger: vk.DebugUtilsMessengerEXT

image_available_semaphore: vk.Semaphore
render_finished_semaphore: vk.Semaphore
in_flight_fence: vk.Fence
present_fence: vk.Fence

MAX_SWAPCHAIN_IMAGES :: 4
elements: [MAX_SWAPCHAIN_IMAGES]SwapchainElement

SwapchainElement :: struct {
	commandBuffer: vk.CommandBuffer,
	image:         vk.Image,
	imageView:     vk.ImageView,
	layout:        vk.ImageLayout,
}

// buffer/texture structs exported for other files
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

//───────────────────────────
// WRAPPERS
//───────────────────────────
vkw_create :: proc(call: $T, dev: vk.Device, info: ^$U, msg: string, $Out: typeid) -> (Out, bool) {
	out: Out
	if call(dev, info, nil, &out) !=
	   .SUCCESS {fmt.printf("Create failed: %s\n", msg);return {}, false}
	return out, true
}
vkw_allocate :: proc(call: $T, dev: vk.Device, info: ^$U, out: ^$Out, msg: string) -> bool {
	if call(dev, info, out) != .SUCCESS {fmt.printf("Alloc failed: %s\n", msg);return false}
	return true
}
vkw :: proc {
	vkw_create,
	vkw_allocate,
}

//───────────────────────────
// SYNC + FRAME
//───────────────────────────
init_sync_objects :: proc() -> bool {
	semaphore_info := vk.SemaphoreCreateInfo {
		sType = .SEMAPHORE_CREATE_INFO,
	}
	vk.CreateSemaphore(device, &semaphore_info, nil, &image_available_semaphore)
	vk.CreateSemaphore(device, &semaphore_info, nil, &render_finished_semaphore)
	fence_info := vk.FenceCreateInfo {
		sType = .FENCE_CREATE_INFO,
		flags = {vk.FenceCreateFlag.SIGNALED},
	}
	vk.CreateFence(device, &fence_info, nil, &in_flight_fence)
	// Present fence starts signaled so first frame doesn't wait
	vk.CreateFence(device, &fence_info, nil, &present_fence)
	return true
}


render_frame :: proc(start_time: time.Time) -> bool {
	// Wait for previous present to complete before reusing render_finished_semaphore
	vk.WaitForFences(device, 1, &present_fence, true, max(u64))
	vk.ResetFences(device, 1, &present_fence)

	vk.WaitForFences(device, 1, &in_flight_fence, true, max(u64))
	vk.ResetFences(device, 1, &in_flight_fence)
	if vk.AcquireNextImageKHR(device, swapchain, max(u64), image_available_semaphore, {}, &image_index) != .SUCCESS do return false
	e := &elements[image_index]
	enc, f := begin_frame_commands(e, start_time)
	record_commands(e, f)
	transition_swapchain_image_layout(f.cmd, e, vk.ImageLayout.PRESENT_SRC_KHR)
	vk.EndCommandBuffer(enc.command_buffer)
	stage := vk.PipelineStageFlags{.COLOR_ATTACHMENT_OUTPUT}
	vk.QueueSubmit(
		queue,
		1,
		&vk.SubmitInfo {
			sType = .SUBMIT_INFO,
			waitSemaphoreCount = 1,
			pWaitSemaphores = &image_available_semaphore,
			pWaitDstStageMask = &stage,
			commandBufferCount = 1,
			pCommandBuffers = &e.commandBuffer,
			signalSemaphoreCount = 1,
			pSignalSemaphores = &render_finished_semaphore,
		},
		in_flight_fence,
	)
	// Use swapchain_maintenance1 extension to provide a fence for present
	present_fence_info := vk.SwapchainPresentFenceInfoEXT {
		sType = .SWAPCHAIN_PRESENT_FENCE_INFO_EXT,
		swapchainCount = 1,
		pFences = &present_fence,
	}
	return(
		vk.QueuePresentKHR(
			queue,
			&vk.PresentInfoKHR {
				sType = .PRESENT_INFO_KHR,
				pNext = &present_fence_info,
				waitSemaphoreCount = 1,
				pWaitSemaphores = &render_finished_semaphore,
				swapchainCount = 1,
				pSwapchains = &swapchain,
				pImageIndices = &image_index,
			},
		) ==
		.SUCCESS \
	)
}

//───────────────────────────
// INSTANCE + DEVICE
//───────────────────────────
instance_extensions: Array(16, cstring)

get_instance_extensions :: proc() -> []cstring {
	instance_extensions.len = 0

	for ext in glfw.GetRequiredInstanceExtensions() {
		array_push(&instance_extensions, ext)
	}
	array_push(&instance_extensions, "VK_KHR_get_surface_capabilities2")
	// Required by VK_EXT_swapchain_maintenance1 (deprecated but needed until KHR version is in bindings)
	array_push(&instance_extensions, "VK_EXT_surface_maintenance1")
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
	feat_swapchain_maintenance := vk.PhysicalDeviceSwapchainMaintenance1FeaturesEXT {
		sType                = .PHYSICAL_DEVICE_SWAPCHAIN_MAINTENANCE_1_FEATURES_EXT,
		swapchainMaintenance1 = true,
	}
	feat_shader_obj := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		pNext        = &feat_swapchain_maintenance,
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
	feat_12 := vk.PhysicalDeviceVulkan12Features {
		sType                  = .PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                  = &feat_sync,
		descriptorIndexing     = true,
		runtimeDescriptorArray = true,
	}
	feats := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &feat_12,
		features = vk.PhysicalDeviceFeatures{fragmentStoresAndAtomics = true},
	}

	//Device extensions
	exts := [?]cstring{"VK_KHR_swapchain", "VK_EXT_swapchain_maintenance1", "VK_EXT_shader_object"}
	layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &feats,
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

	// Get window dimensions from surface capabilities
	if caps.currentExtent.width != max(u32) {
		width = caps.currentExtent.width
		height = caps.currentExtent.height
	} else {
		// Fallback if surface doesn't provide extent
		width = u32(get_window_width())
		height = u32(get_window_height())
	}

	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &count, nil)
	formats := Array(16, vk.SurfaceFormatKHR){}
	for i in 0 ..< count {
		array_push(&formats, vk.SurfaceFormatKHR{})
	}
	vk.GetPhysicalDeviceSurfaceFormatsKHR(
		phys_device,
		vulkan_surface,
		&count,
		raw_data(array_slice(&formats)),
	)
	format = formats.data[0].format
	for i in 0 ..< count {
		if formats.data[i].format == vk.Format.B8G8R8A8_SRGB {
			format = formats.data[i].format
		}
	}

	img_count := clamp(caps.minImageCount + 1, caps.minImageCount, caps.maxImageCount)
	present_mode := vk.PresentModeKHR.IMMEDIATE
	present_modes_info := vk.SwapchainPresentModesCreateInfoEXT {
		sType            = .SWAPCHAIN_PRESENT_MODES_CREATE_INFO_EXT,
		presentModeCount = 1,
		pPresentModes    = &present_mode,
	}
	sc_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		pNext            = &present_modes_info,
		surface          = vulkan_surface,
		minImageCount    = img_count,
		imageFormat      = format,
		imageColorSpace  = vk.ColorSpaceKHR.SRGB_NONLINEAR,
		imageExtent      = {width, height},
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		presentMode      = .IMMEDIATE,
		clipped          = true,
	}

	swapchain = vkw(vk.CreateSwapchainKHR, device, &sc_info, "swapchain", vk.SwapchainKHR) or_return

	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil)
	imgs := Array(MAX_SWAPCHAIN_IMAGES, vk.Image){}
	for i in 0 ..< image_count {
		array_push(&imgs, vk.Image{})
	}

	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, raw_data(array_slice(&imgs)))
	for i in 0 ..< image_count {
		e := &elements[i];e.image = imgs.data[i]
		e.imageView =
		vkw(
			vk.CreateImageView,
			device,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = imgs.data[i],
				viewType = .D2,
				format = format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			"view",
			vk.ImageView,
		) or_continue
		vkw(
			vk.AllocateCommandBuffers,
			device,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = command_pool,
				level = .PRIMARY,
				commandBufferCount = 1,
			},
			&e.commandBuffer,
			"cmd",
		)
		e.layout = vk.ImageLayout.UNDEFINED
	}
	return true
}

// simple image transition helper
transition_swapchain_image_layout :: proc(
	cmd: vk.CommandBuffer,
	e: ^SwapchainElement,
	new_layout: vk.ImageLayout,
) {
	if e.layout == new_layout do return
	bar := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		oldLayout = e.layout,
		newLayout = new_layout,
		image = e.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
		srcStageMask = {.COLOR_ATTACHMENT_OUTPUT},
		dstStageMask = {.BOTTOM_OF_PIPE},
		srcAccessMask = {.COLOR_ATTACHMENT_WRITE},
		dstAccessMask = {},
	}
	dep := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &bar,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
	e.layout = new_layout
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
	}
	if resource.memory != {} {
		vk.FreeMemory(device, resource.memory, nil)
	}
	resource^ = BufferResource{}
}


//───────────────────────────
// MASTER INIT/CLEANUP
//───────────────────────────


vulkan_init :: proc() -> bool {
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	exts := get_instance_extensions()
	layers := [1]cstring{"VK_LAYER_KHRONOS_validation"}
	enable_value := b32(true)

	layer_settings := [?]vk.LayerSettingEXT {
		{cstring("VK_LAYER_KHRONOS_validation"), cstring("validate_best_practices"), .BOOL32, 1, &enable_value},
		{cstring("VK_LAYER_KHRONOS_validation"), cstring("validate_sync"), .BOOL32, 1, &enable_value},
	}

	debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType = .DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {.WARNING, .ERROR, .INFO, .VERBOSE},
		messageType = {.GENERAL, .VALIDATION, .PERFORMANCE},
		pfnUserCallback = debug_callback,
	}

	layer_settings_info := vk.LayerSettingsCreateInfoEXT {
		sType = .LAYER_SETTINGS_CREATE_INFO_EXT,
		settingCount = u32(len(layer_settings)),
		pSettings = &layer_settings[0],
		pNext = &debug_create_info,
	}

	vk.CreateInstance(& {
		sType = .INSTANCE_CREATE_INFO,
		pApplicationInfo = &vk.ApplicationInfo{.APPLICATION_INFO, nil, "CHAIN OVER", 0, "Odin", 0, vk.API_VERSION_1_3},
		enabledExtensionCount = u32(len(exts)),
		ppEnabledExtensionNames = raw_data(exts),
		enabledLayerCount = ENABLE_VALIDATION ? 1 : 0,
		ppEnabledLayerNames = ENABLE_VALIDATION ? &layers[0] : nil,
		pNext = ENABLE_VALIDATION ? &layer_settings_info : nil,
	}, nil, &instance)

	vk.load_proc_addresses_instance(instance)
	glfw.CreateWindowSurface(instance, get_glfw_window(), nil, &vulkan_surface)
	setup_physical_device() or_return
	create_logical_device() or_return
	vk.load_proc_addresses_device(device)

	if ENABLE_VALIDATION {
		vk.CreateDebugUtilsMessengerEXT(instance, &vk.DebugUtilsMessengerCreateInfoEXT{.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT, nil, {}, {.WARNING, .ERROR, .INFO, .VERBOSE}, {.GENERAL, .VALIDATION, .PERFORMANCE}, debug_callback, nil}, nil, &debug_messenger)
	}

	command_pool = vkw(vk.CreateCommandPool, device, &vk.CommandPoolCreateInfo{.COMMAND_POOL_CREATE_INFO, nil, {.RESET_COMMAND_BUFFER}, queue_family_index}, "cmd pool", vk.CommandPool) or_return
	create_swapchain() or_return
	init_sync_objects() or_return
	init_shaders() or_return
	return true
}

handle_resize :: proc() {
	if glfw_resize_needed() != 0 {
		// Wait for GPU to finish all work before destroying resources
		vk.DeviceWaitIdle(device)

		resize()
		destroy_swapchain()
		if !create_swapchain() {
			return
		}

		if width == 0 || height == 0 {
			runtime.assert(false, "width and height must be greater than 0")
			return
		}
		// Recreate offscreen resources with new dimensions (handled by render init)
		//	init_render_resources()


	}
}
destroy_swapchain :: proc() {
	for i in 0 ..< MAX_SWAPCHAIN_IMAGES {
		if elements[i].imageView != {} do vk.DestroyImageView(device, elements[i].imageView, nil)
		elements[i] = SwapchainElement{}
	}
	if swapchain != {} do vk.DestroySwapchainKHR(device, swapchain, nil)
	swapchain = {}
}

destroy_all_sync_objects :: proc() {
	if image_available_semaphore != {} do vk.DestroySemaphore(device, image_available_semaphore, nil)
	if render_finished_semaphore != {} do vk.DestroySemaphore(device, render_finished_semaphore, nil)
	if in_flight_fence != {} do vk.DestroyFence(device, in_flight_fence, nil)
	if present_fence != {} do vk.DestroyFence(device, present_fence, nil)
}

vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)
	destroy_swapchain()
	destroy_all_sync_objects()
	if command_pool != {} do vk.DestroyCommandPool(device, command_pool, nil)
	vk.DestroyDevice(device, nil)
	vk.DestroySurfaceKHR(instance, vulkan_surface, nil)
	if ENABLE_VALIDATION do vk.DestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
	vk.DestroyInstance(instance, nil)
}
