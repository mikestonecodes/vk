package main

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"


render_frame :: proc(start_time: time.Time) {
	// 1. Get next swapchain image
	if !acquire_next_image() do return

	// 2. Record draw commands
	element := &elements[image_index]
	record_commands(element, start_time)
	// 3. Submit to GPU and present
	submit_commands(element)
	present_frame()
	// No need to track current_frame with this simple approach
}


// Update window size from Wayland
update_window_size :: proc() {
	width = c.uint32_t(get_window_width())
	height = c.uint32_t(get_window_height())
}

// Handle window resize
handle_resize :: proc() {
	if wayland_resize_needed() != 0 {
		update_window_size()
		vk.DeviceWaitIdle(device)
		destroy_swapchain()
		create_swapchain()
		// Pipeline needs to be recreated with new viewport
		recreate_graphics_pipeline()
	}
}

vulkan_init :: proc() -> (ok: bool) {
	// Get initial window size
	fmt.println("DEBUG: Getting window size")
	update_window_size()

	fmt.println("DEBUG: Initializing Vulkan")
	if !init_vulkan() do return false
	fmt.println("DEBUG: Creating swapchain")
	create_swapchain()
	fmt.println("DEBUG: Creating graphics pipeline")
	if !create_graphics_pipeline() do return false
	fmt.println("DEBUG: Vulkan init complete")
	return true
}

vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)
	destroy_swapchain()
	vk.DestroyPipeline(device, graphics_pipeline, nil)
	vk.DestroyPipeline(device, compute_pipeline, nil)
	vk.DestroyPipeline(device, post_process_pipeline, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	vk.DestroyPipelineLayout(device, compute_pipeline_layout, nil)
	vk.DestroyPipelineLayout(device, post_process_pipeline_layout, nil)
	vk.DestroyDescriptorPool(device, descriptor_pool, nil)
	vk.DestroyDescriptorSetLayout(device, descriptor_set_layout, nil)
	vk.DestroyDescriptorSetLayout(device, post_process_descriptor_set_layout, nil)
	vk.DestroyBuffer(device, particle_buffer, nil)
	vk.FreeMemory(device, particle_buffer_memory, nil)
	vk.DestroyFramebuffer(device, offscreen_framebuffer, nil)
	vk.DestroyImageView(device, offscreen_image_view, nil)
	vk.DestroyImage(device, offscreen_image, nil)
	vk.FreeMemory(device, offscreen_image_memory, nil)
	vk.DestroyRenderPass(device, offscreen_render_pass, nil)
	vk.DestroySampler(device, texture_sampler, nil)
	vk.DestroySemaphore(device, timeline_semaphore, nil)
	vk.DestroySemaphore(device, image_available_semaphore, nil)
	// Image available semaphore destroyed in destroy_swapchain()
	vk.DestroyCommandPool(device, command_pool, nil)
	vk.DestroyDevice(device, nil)
	vk.DestroySurfaceKHR(instance, vulkan_surface, nil)
	if ENABLE_VALIDATION {
		vkDestroyDebugUtilsMessengerEXT := cast(proc "c" (
			_: vk.Instance,
			_: vk.DebugUtilsMessengerEXT,
			_: rawptr,
		))vk.GetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")
		if vkDestroyDebugUtilsMessengerEXT != nil do vkDestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
	}
	vk.DestroyInstance(instance, nil)
}

// Hot reload pipeline when shaders change
recreate_pipeline :: proc() {
	if !recreate_graphics_pipeline() do fmt.println("Failed to recreate pipeline")
}

submit_commands :: proc(element: ^SwapchainElement) {
	// Increment timeline for this frame
	timeline_value += 1

	wait_stages := [1]vk.PipelineStageFlags {
		vk.PipelineStageFlags{vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
	}

	// Timeline semaphore submit info
	timeline_submit_info := vk.TimelineSemaphoreSubmitInfo {
		sType = vk.StructureType.TIMELINE_SEMAPHORE_SUBMIT_INFO,
		waitSemaphoreValueCount = 0,
		pWaitSemaphoreValues = nil,
		signalSemaphoreValueCount = 1,
		pSignalSemaphoreValues = &timeline_value,
	}

	submit_info := vk.SubmitInfo {
		sType                = vk.StructureType.SUBMIT_INFO,
		pNext                = &timeline_submit_info,
		waitSemaphoreCount   = 1,
		pWaitSemaphores      = &image_available_semaphore,
		pWaitDstStageMask    = raw_data(wait_stages[:]),
		commandBufferCount   = 1,
		pCommandBuffers      = &element.commandBuffer,
		signalSemaphoreCount = 1,
		pSignalSemaphores    = &timeline_semaphore,
	}

	vk.QueueSubmit(queue, 1, &submit_info, {})
}

present_frame :: proc() {
	// Wait for timeline semaphore to reach current value (render complete)
	wait_info := vk.SemaphoreWaitInfo {
		sType = vk.StructureType.SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores = &timeline_semaphore,
		pValues = &timeline_value,
	}
	vk.WaitSemaphores(device, &wait_info, max(u64))

	// Present with no semaphore wait (we already waited above)
	present_info := vk.PresentInfoKHR {
		sType              = vk.StructureType.PRESENT_INFO_KHR,
		waitSemaphoreCount = 0,
		pWaitSemaphores    = nil,
		swapchainCount     = 1,
		pSwapchains        = &swapchain,
		pImageIndices      = &image_index,
	}

	result := vk.QueuePresentKHR(queue, &present_info)
	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		vk.DeviceWaitIdle(device)
		destroy_swapchain()
		create_swapchain()
	}
}


recreate_graphics_pipeline :: proc() -> bool {
	vk.DeviceWaitIdle(device)
	vk.DestroyPipeline(device, graphics_pipeline, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	return create_graphics_pipeline()
}

acquire_next_image :: proc() -> bool {
	result := vk.AcquireNextImageKHR(
		device,
		swapchain,
		max(u64),
		image_available_semaphore,
		{},
		&image_index,
	)

	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		vk.DeviceWaitIdle(device)
		destroy_swapchain()
		create_swapchain()
		return false
	}

	return result == vk.Result.SUCCESS
}


last_vertex_time: time.Time
last_fragment_time: time.Time
last_compute_time: time.Time
last_post_process_time: time.Time

init_shader_times :: proc() {
	if info, err := os.stat("vertex.wgsl"); err == nil do last_vertex_time = info.modification_time
	if info, err := os.stat("fragment.wgsl"); err == nil do last_fragment_time = info.modification_time
	if info, err := os.stat("compute.wgsl"); err == nil do last_compute_time = info.modification_time
	if info, err := os.stat("post_process.wgsl"); err == nil do last_post_process_time = info.modification_time
}

check_shader_reload :: proc() -> bool {
	vertex_info, vertex_err := os.stat("vertex.wgsl")
	fragment_info, fragment_err := os.stat("fragment.wgsl")
	compute_info, compute_err := os.stat("compute.wgsl")
	post_process_info, post_process_err := os.stat("post_process.wgsl")
	if vertex_err != nil || fragment_err != nil || compute_err != nil || post_process_err != nil do return false

	vertex_changed := vertex_info.modification_time != last_vertex_time
	fragment_changed := fragment_info.modification_time != last_fragment_time
	compute_changed := compute_info.modification_time != last_compute_time
	post_process_changed := post_process_info.modification_time != last_post_process_time

	if vertex_changed || fragment_changed || compute_changed || post_process_changed {
		last_vertex_time = vertex_info.modification_time
		last_fragment_time = fragment_info.modification_time
		last_compute_time = compute_info.modification_time
		last_post_process_time = post_process_info.modification_time
		return compile_shaders(vertex_changed, fragment_changed, compute_changed, post_process_changed)
	}

	return false
}

compile_shaders :: proc(vertex_changed, fragment_changed, compute_changed, post_process_changed: bool) -> bool {
	fmt.println("Recompiling shaders...")
	success := true

	if vertex_changed {
		vertex_cmd := strings.clone_to_cstring("./naga vertex.wgsl vertex.spv")
		defer delete(vertex_cmd)
		if system(vertex_cmd) != 0 do success = false
	}

	if fragment_changed {
		fragment_cmd := strings.clone_to_cstring("./naga fragment.wgsl fragment.spv")
		defer delete(fragment_cmd)
		if system(fragment_cmd) != 0 do success = false
	}

	if compute_changed {
		compute_cmd := strings.clone_to_cstring("./naga compute.wgsl compute.spv")
		defer delete(compute_cmd)
		if system(compute_cmd) != 0 do success = false
	}

	if post_process_changed {
		post_process_cmd := strings.clone_to_cstring("./naga post_process.wgsl post_process.spv")
		defer delete(post_process_cmd)
		if system(post_process_cmd) != 0 do success = false
	}

	return success
}


SwapchainElement :: struct {
	commandBuffer: vk.CommandBuffer,
	image:         vk.Image,
	imageView:     vk.ImageView,
	framebuffer:   vk.Framebuffer,
}

// Extension and layer names
instance_extension_names := [?]cstring {
	"VK_KHR_surface",
	"VK_KHR_wayland_surface",
	"VK_EXT_debug_utils",
}
layer_names := [?]cstring{"VK_LAYER_KHRONOS_validation"}
device_extension_names := [?]cstring{"VK_KHR_swapchain"}


// Global Vulkan state
ENABLE_VALIDATION := true
instance: vk.Instance
debug_messenger: vk.DebugUtilsMessengerEXT
vulkan_surface: vk.SurfaceKHR
phys_device: vk.PhysicalDevice
device: vk.Device
queue_family_index: c.uint32_t
queue: vk.Queue
command_pool: vk.CommandPool
swapchain: vk.SwapchainKHR
render_pass: vk.RenderPass
pipeline_layout: vk.PipelineLayout
graphics_pipeline: vk.Pipeline
elements: [^]SwapchainElement
format: vk.Format = vk.Format.UNDEFINED
width: c.uint32_t = 800
height: c.uint32_t = 600
current_frame: c.uint32_t = 0
image_index: c.uint32_t = 0
image_count: c.uint32_t = 0
// Timeline semaphore for proper synchronization
timeline_semaphore: vk.Semaphore
timeline_value: c.uint64_t = 0
// Binary semaphore for swapchain
image_available_semaphore: vk.Semaphore


// =============================================================================
// BORING INITIALIZATION CODE - Surface, Device, Swapchain setup
// =============================================================================

debug_callback :: proc "system" (
	messageSeverity: vk.DebugUtilsMessageSeverityFlagsEXT,
	messageType: vk.DebugUtilsMessageTypeFlagsEXT,
	pCallbackData: ^vk.DebugUtilsMessengerCallbackDataEXT,
	pUserData: rawptr,
) -> b32 {
	context = runtime.default_context()
	fmt.printf("Validation layer: %s\n", pCallbackData.pMessage)
	return false
}

load_shader_spirv :: proc(filename: string) -> ([]c.uint32_t, bool) {
	data, ok := os.read_entire_file(filename)
	if !ok do return nil, false
	defer delete(data)

	if len(data) % 4 != 0 do return nil, false

	word_count := len(data) / 4
	spirv_data := make([]c.uint32_t, word_count)

	for i in 0 ..< word_count {
		byte_offset := i * 4
		spirv_data[i] =
			c.uint32_t(data[byte_offset]) |
			(c.uint32_t(data[byte_offset + 1]) << 8) |
			(c.uint32_t(data[byte_offset + 2]) << 16) |
			(c.uint32_t(data[byte_offset + 3]) << 24)
	}

	return spirv_data, true
}

create_swapchain :: proc() {
	result: vk.Result

	capabilities: vk.SurfaceCapabilitiesKHR
	result = vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &capabilities)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error getting surface capabilities: %d\n", result)
		return
	}

	format_count: c.uint32_t
	result = vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &format_count, nil)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error getting surface format count: %d\n", result)
		return
	}

	formats := make([^]vk.SurfaceFormatKHR, format_count)
	defer free(formats)
	result = vk.GetPhysicalDeviceSurfaceFormatsKHR(
		phys_device,
		vulkan_surface,
		&format_count,
		formats,
	)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error getting surface formats: %d\n", result)
		return
	}

	chosen_format := formats[0]
	for i in 0 ..< format_count {
		if formats[i].format == vk.Format.B8G8R8A8_UNORM {
			chosen_format = formats[i]
			break
		}
	}
	format = chosen_format.format

	image_count = capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
		image_count = capabilities.minImageCount
	}

	create_info := vk.SwapchainCreateInfoKHR {
		sType            = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
		surface          = vulkan_surface,
		minImageCount    = image_count,
		imageFormat      = chosen_format.format,
		imageColorSpace  = chosen_format.colorSpace,
		imageExtent      = {width, height},
		imageArrayLayers = 1,
		imageUsage       = {vk.ImageUsageFlag.COLOR_ATTACHMENT},
		imageSharingMode = vk.SharingMode.EXCLUSIVE,
		preTransform     = capabilities.currentTransform,
		compositeAlpha   = {vk.CompositeAlphaFlagKHR.OPAQUE},
		presentMode      = vk.PresentModeKHR.FIFO,
		clipped          = true,
		oldSwapchain     = {},
	}

	result = vk.CreateSwapchainKHR(device, &create_info, nil, &swapchain)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error creating swapchain: %d\n", result)
		return
	}

	attachment := vk.AttachmentDescription {
		format         = format,
		samples        = {vk.SampleCountFlag._1},
		loadOp         = vk.AttachmentLoadOp.CLEAR,
		storeOp        = vk.AttachmentStoreOp.STORE,
		stencilLoadOp  = vk.AttachmentLoadOp.DONT_CARE,
		stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE,
		initialLayout  = vk.ImageLayout.UNDEFINED,
		finalLayout    = vk.ImageLayout.PRESENT_SRC_KHR,
	}

	attachment_ref := vk.AttachmentReference {
		attachment = 0,
		layout     = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
	}

	subpass := vk.SubpassDescription {
		pipelineBindPoint    = vk.PipelineBindPoint.GRAPHICS,
		colorAttachmentCount = 1,
		pColorAttachments    = &attachment_ref,
	}

	render_pass_info := vk.RenderPassCreateInfo {
		sType           = vk.StructureType.RENDER_PASS_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &attachment,
		subpassCount    = 1,
		pSubpasses      = &subpass,
	}

	result = vk.CreateRenderPass(device, &render_pass_info, nil, &render_pass)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error creating render pass: %d\n", result)
		return
	}

	result = vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error getting swapchain image count: %d\n", result)
		return
	}

	images := make([^]vk.Image, image_count)
	defer free(images)
	result = vk.GetSwapchainImagesKHR(device, swapchain, &image_count, images)
	if result != vk.Result.SUCCESS {
		fmt.printf("Error getting swapchain images: %d\n", result)
		return
	}

	elements = make([^]SwapchainElement, image_count)

	for i in 0 ..< image_count {
		alloc_info := vk.CommandBufferAllocateInfo {
			sType              = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
			commandPool        = command_pool,
			commandBufferCount = 1,
			level              = vk.CommandBufferLevel.PRIMARY,
		}
		vk.AllocateCommandBuffers(device, &alloc_info, &elements[i].commandBuffer)

		elements[i].image = images[i]

		view_info := vk.ImageViewCreateInfo {
			sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
			viewType = vk.ImageViewType.D2,
			components = {
				vk.ComponentSwizzle.IDENTITY,
				vk.ComponentSwizzle.IDENTITY,
				vk.ComponentSwizzle.IDENTITY,
				vk.ComponentSwizzle.IDENTITY,
			},
			subresourceRange = {
				aspectMask = {vk.ImageAspectFlag.COLOR},
				baseMipLevel = 0,
				levelCount = 1,
				baseArrayLayer = 0,
				layerCount = 1,
			},
			image = elements[i].image,
			format = format,
		}
		result = vk.CreateImageView(device, &view_info, nil, &elements[i].imageView)
		if result != vk.Result.SUCCESS {
			fmt.printf("Error creating image view: %d\n", result)
			return
		}

		fb_info := vk.FramebufferCreateInfo {
			sType           = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
			renderPass      = render_pass,
			attachmentCount = 1,
			pAttachments    = &elements[i].imageView,
			width           = width,
			height          = height,
			layers          = 1,
		}
		result = vk.CreateFramebuffer(device, &fb_info, nil, &elements[i].framebuffer)
		if result != vk.Result.SUCCESS {
			fmt.printf("Error creating framebuffer: %d\n", result)
			return
		}

		// Note: synchronization objects are created in init_vulkan()
	}
}

destroy_swapchain :: proc() {
	for i in 0 ..< image_count {
		vk.DestroyFramebuffer(device, elements[i].framebuffer, nil)
		vk.DestroyImageView(device, elements[i].imageView, nil)
		vk.FreeCommandBuffers(device, command_pool, 1, &elements[i].commandBuffer)
	}

	free(elements)
	vk.DestroyRenderPass(device, render_pass, nil)
	vk.DestroySwapchainKHR(device, swapchain, nil)
}

init_vulkan :: proc() -> bool {
	result: vk.Result
	
	fmt.println("DEBUG: Loading Vulkan library")
	vulkan_lib, lib_ok := dynlib.load_library("libvulkan.so.1")
	if !lib_ok {
		fmt.println("Failed to load Vulkan library")
		return false
	}
	
	vk_get_instance_proc_addr, proc_ok := dynlib.symbol_address(vulkan_lib, "vkGetInstanceProcAddr")
	if !proc_ok {
		fmt.println("Failed to get vkGetInstanceProcAddr")
		return false
	}
	
	fmt.println("DEBUG: Loading global Vulkan procedures")
	vk.load_proc_addresses_global(vk_get_instance_proc_addr)
	
	fmt.println("DEBUG: Creating application info")

	// Create Vulkan instance - try minimal setup first
	app_info := vk.ApplicationInfo {
		sType              = vk.StructureType.APPLICATION_INFO,
		pApplicationName   = "Wayland Vulkan Example",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "No Engine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}
	fmt.println("DEBUG: Application info created")

	create_info := vk.InstanceCreateInfo {
		sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = ENABLE_VALIDATION ? len(layer_names) : 0,
		ppEnabledLayerNames     = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
		enabledExtensionCount   = len(instance_extension_names),
		ppEnabledExtensionNames = raw_data(instance_extension_names[:]),
	}

	fmt.println("DEBUG: About to create Vulkan instance")
	fmt.printf("DEBUG: Validation layers enabled: %v\n", ENABLE_VALIDATION)
	fmt.printf("DEBUG: Extension count: %d\n", len(instance_extension_names))
	fmt.printf("DEBUG: Layer count: %d\n", ENABLE_VALIDATION ? len(layer_names) : 0)
	// Try with cast to make sure types are correct
	result = vk.CreateInstance(&create_info, nil, &instance)
	fmt.printf("DEBUG: CreateInstance returned: %v\n", result)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create instance: %d\n", result)
		return false
	}
	fmt.println("DEBUG: Instance created successfully")
	
	// Load instance-specific procedure addresses
	fmt.println("DEBUG: Loading instance procedures")
	vk.load_proc_addresses_instance(instance)

	// Setup debug messenger
	if ENABLE_VALIDATION && !setup_debug_messenger() {
		return false
	}

	// Create Wayland surface
	fmt.println("DEBUG: Creating Vulkan surface")
	surface_create_info := vk.WaylandSurfaceCreateInfoKHR{
		sType = vk.StructureType.WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = cast(^vk.wl_display)display,
		surface = cast(^vk.wl_surface)surface,
	}
	result = vk.CreateWaylandSurfaceKHR(instance, &surface_create_info, nil, &vulkan_surface)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create Wayland surface: %d\n", result)
		return false
	}

	// Setup physical device
	if !setup_physical_device() {
		return false
	}

	// Create logical device
	if !create_logical_device() {
		return false
	}
	
	// Load device-specific procedure addresses
	fmt.println("DEBUG: Loading device procedures")
	vk.load_proc_addresses_device(device)

	// Create command pool
	pool_info := vk.CommandPoolCreateInfo {
		sType            = vk.StructureType.COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = queue_family_index,
		flags            = {vk.CommandPoolCreateFlag.RESET_COMMAND_BUFFER},
	}

	result = vk.CreateCommandPool(device, &pool_info, nil, &command_pool)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create command pool: %d\n", result)
		return false
	}

	// Create timeline semaphore
	timeline_type_info := vk.SemaphoreTypeCreateInfo {
		sType = vk.StructureType.SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = vk.SemaphoreType.TIMELINE,
		initialValue = 0,
	}

	sem_info := vk.SemaphoreCreateInfo {
		sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
		pNext = &timeline_type_info,
	}

	result = vk.CreateSemaphore(device, &sem_info, nil, &timeline_semaphore)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create timeline semaphore: %d\n", result)
		return false
	}

	// Create binary semaphore for image acquisition
	binary_sem_info := vk.SemaphoreCreateInfo {
		sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
	}

	result = vk.CreateSemaphore(device, &binary_sem_info, nil, &image_available_semaphore)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create image available semaphore: %d\n", result)
		return false
	}

	return true
}

setup_debug_messenger :: proc() -> bool {
	vkCreateDebugUtilsMessengerEXT := cast(proc "c" (
		instance: vk.Instance,
		create_info: ^vk.DebugUtilsMessengerCreateInfoEXT,
		allocator: rawptr,
		debug_messenger: ^vk.DebugUtilsMessengerEXT,
	) -> vk.Result)vk.GetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT")

	debug_create_info := vk.DebugUtilsMessengerCreateInfoEXT {
		sType           = vk.StructureType.DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
		messageSeverity = {
			vk.DebugUtilsMessageSeverityFlagEXT.VERBOSE,
			vk.DebugUtilsMessageSeverityFlagEXT.INFO,
			vk.DebugUtilsMessageSeverityFlagEXT.WARNING,
			vk.DebugUtilsMessageSeverityFlagEXT.ERROR,
		},
		messageType     = {
			vk.DebugUtilsMessageTypeFlagEXT.GENERAL,
			vk.DebugUtilsMessageTypeFlagEXT.VALIDATION,
			vk.DebugUtilsMessageTypeFlagEXT.PERFORMANCE,
		},
		pfnUserCallback = debug_callback,
	}

	if vkCreateDebugUtilsMessengerEXT != nil {
		result := vkCreateDebugUtilsMessengerEXT(
			instance,
			&debug_create_info,
			nil,
			&debug_messenger,
		)
		if result != vk.Result.SUCCESS {
			fmt.printf("Failed to create debug messenger: %d\n", result)
			return false
		}
	}
	return true
}

setup_physical_device :: proc() -> bool {
	device_count: c.uint32_t
	vk.EnumeratePhysicalDevices(instance, &device_count, nil)
	if device_count == 0 {
		fmt.println("No physical devices found")
		return false
	}

	devices := make([^]vk.PhysicalDevice, device_count)
	defer free(devices)
	vk.EnumeratePhysicalDevices(instance, &device_count, devices)
	phys_device = devices[0]

	// Find queue family
	queue_family_count: c.uint32_t
	vk.GetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, nil)

	queue_families := make([^]vk.QueueFamilyProperties, queue_family_count)
	defer free(queue_families)
	vk.GetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, queue_families)

	found_queue_family := false
	for i in 0 ..< queue_family_count {
		present_support: b32 = false
		result := vk.GetPhysicalDeviceSurfaceSupportKHR(
			phys_device,
			i,
			vulkan_surface,
			&present_support,
		)
		if result == vk.Result.SUCCESS &&
		   present_support &&
		   vk.QueueFlag.GRAPHICS in queue_families[i].queueFlags {
			queue_family_index = i
			found_queue_family = true
			break
		}
	}

	if !found_queue_family {
		fmt.println("No suitable queue family found")
		return false
	}

	return true
}

create_logical_device :: proc() -> bool {
	queue_priority: f32 = 1.0
	queue_create_info := vk.DeviceQueueCreateInfo {
		sType            = vk.StructureType.DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_family_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	// Enable timeline semaphore features
	timeline_features := vk.PhysicalDeviceTimelineSemaphoreFeatures {
		sType             = vk.StructureType.PHYSICAL_DEVICE_TIMELINE_SEMAPHORE_FEATURES,
		timelineSemaphore = true,
	}

	device_create_info := vk.DeviceCreateInfo {
		sType                   = vk.StructureType.DEVICE_CREATE_INFO,
		pNext                   = &timeline_features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_create_info,
		enabledLayerCount       = ENABLE_VALIDATION ? len(layer_names) : 0,
		ppEnabledLayerNames     = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
		enabledExtensionCount   = len(device_extension_names),
		ppEnabledExtensionNames = raw_data(device_extension_names[:]),
	}

	result := vk.CreateDevice(phys_device, &device_create_info, nil, &device)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create device: %d\n", result)
		return false
	}

	vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
	return true
}


foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
