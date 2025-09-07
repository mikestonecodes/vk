package main

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

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


ShaderInfo :: struct {
	wgsl_path: string,
	spv_path: string,
	last_modified: time.Time,
}

shader_registry: map[string]ShaderInfo
shader_watch_initialized: bool

init_shader_times :: proc() {
	discover_shaders()
	shader_watch_initialized = true
}

discover_shaders :: proc() {
	handle, err := os.open(".")
	if err != nil {
		fmt.println("Failed to open current directory for shader discovery")
		return
	}
	defer os.close(handle)

	files, read_err := os.read_dir(handle, -1)
	if read_err != nil {
		fmt.println("Failed to read directory for shader discovery")
		return
	}
	defer delete(files)

	for file in files {
		if strings.has_suffix(file.name, ".wgsl") {
			spv_name, _ := strings.replace(file.name, ".wgsl", ".spv", 1)
			
			shader_registry[strings.clone(file.name)] = ShaderInfo{
				wgsl_path = strings.clone(file.name),
				spv_path = spv_name,
				last_modified = file.modification_time,
			}
		}
	}

	fmt.printf("Discovered %d shaders: ", len(shader_registry))
	for name in shader_registry {
		fmt.printf("%s ", name)
	}
	fmt.println()
}

check_shader_reload :: proc() -> bool {
	if !shader_watch_initialized {
		init_shader_times()
		return false
	}

	any_changed := false
	changed_shaders: [dynamic]string
	defer delete(changed_shaders)

	for name, &info in shader_registry {
		file_info, err := os.stat(info.wgsl_path)
		if err != nil {
			continue
		}

		if file_info.modification_time != info.last_modified {
			info.last_modified = file_info.modification_time
			append(&changed_shaders, name)
			any_changed = true
		}
	}

	if any_changed {
		fmt.printf("Detected changes in shaders: ")
		for shader in changed_shaders {
			fmt.printf("%s ", shader)
		}
		fmt.println()
		
		if compile_changed_shaders(changed_shaders[:]) {
			clear_pipeline_cache()
			return true
		}
	}

	return false
}

compile_changed_shaders :: proc(changed_shaders: []string) -> bool {
	fmt.printf("Recompiling %d shaders...\n", len(changed_shaders))
	success := true

	for shader_name in changed_shaders {
		info, ok := shader_registry[shader_name]
		if !ok {
			fmt.printf("Warning: shader %s not found in registry\n", shader_name)
			continue
		}

		cmd := fmt.aprintf("./naga %s %s", info.wgsl_path, info.spv_path)
		defer delete(cmd)
		
		cmd_cstr := strings.clone_to_cstring(cmd)
		defer delete(cmd_cstr)
		
		fmt.printf("Compiling %s -> %s\n", info.wgsl_path, info.spv_path)
		if system(cmd_cstr) != 0 {
			fmt.printf("Failed to compile %s\n", info.wgsl_path)
			success = false
		}
	}

	return success
}

clear_pipeline_cache :: proc() {
	fmt.printf("Clearing pipeline cache (%d entries)\n", len(pipeline_cache))
	
	for key, cached in pipeline_cache {
		vk.DestroyPipeline(device, cached.pipeline, nil)
		vk.DestroyPipelineLayout(device, cached.layout, nil)
		delete(key)
	}
	
	delete(pipeline_cache)
	pipeline_cache = make(map[string]struct{ pipeline: vk.Pipeline, layout: vk.PipelineLayout })
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


ComputePushConstants :: struct {
	time: f32,
	particle_count: u32,
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

foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
