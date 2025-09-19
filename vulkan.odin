package main

import "base:runtime"
import "core:c"
import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "vendor:glfw"
import vk "vendor:vulkan"


// ============================================
// Single-object create wrapper
// ============================================


// Single object create wrapper
vkw_create :: proc(
	call: $T,
	device: vk.Device,
	info: ^$U,
	msg: string,
	$Out: typeid,
) -> (
	Out,
	bool,
) {
	out: Out
	if call(device, info, nil, &out) != vk.Result.SUCCESS {
		fmt.printf("%s\n", msg)
		return {}, false
	}
	return out, true
}

// Array enumeration wrapper (get count, then get array)
vkw_enumerate :: proc(call: $T, first_param: $P, msg: string, $Out: typeid) -> ([]Out, bool) {
	count: u32
	if call(first_param, &count, nil) != .SUCCESS {
		fmt.printf("Failed to get count for %s\n", msg)
		return nil, false
	}

	if count == 0 {
		return nil, true
	}

	array := make([]Out, count)
	if call(first_param, &count, raw_data(array)) != .SUCCESS {
		fmt.printf("Failed to get array for %s\n", msg)
		delete(array)
		return nil, false
	}

	return array, true
}

// Device enumeration wrapper (instance-specific)
vkw_enumerate_device :: proc(
	call: $T,
	instance: vk.Instance,
	msg: string,
	$Out: typeid,
) -> (
	[]Out,
	bool,
) {
	return vkw_enumerate(call, instance, msg, Out)
}

// Physical device specific enumeration
vkw_enumerate_physical :: proc(
	call: $T,
	phys_device: vk.PhysicalDevice,
	msg: string,
	$Out: typeid,
) -> (
	[]Out,
	bool,
) {
	return vkw_enumerate(call, phys_device, msg, Out)
}

// Surface-specific enumeration (with physical device and surface)
vkw_enumerate_surface :: proc(
	call: $T,
	phys_device: vk.PhysicalDevice,
	surface: vk.SurfaceKHR,
	msg: string,
	$Out: typeid,
) -> (
	[]Out,
	bool,
) {
	count: u32
	if call(phys_device, surface, &count, nil) != .SUCCESS {
		fmt.printf("Failed to get count for %s\n", msg)
		return nil, false
	}

	if count == 0 {
		return nil, true
	}

	array := make([]Out, count)
	if call(phys_device, surface, &count, raw_data(array)) != .SUCCESS {
		fmt.printf("Failed to get array for %s\n", msg)
		delete(array)
		return nil, false
	}

	return array, true
}

// Get single property wrapper
vkw_get_property :: proc(call: $T, first_param: $P, out: ^$Out, msg: string) -> bool {
	call(first_param, out)
	return true // Most property getters don't return errors
}

// Allocate wrapper (for descriptor sets, command buffers, etc)
vkw_allocate :: proc(call: $T, device: vk.Device, info: ^$U, out: ^$Out, msg: string) -> bool {
	if call(device, info, out) != .SUCCESS {
		fmt.printf("Failed to allocate %s\n", msg)
		return false
	}
	return true
}

// Create pipeline wrapper (handles array of pipelines)
vkw_create_pipelines :: proc(
	call: $T,
	device: vk.Device,
	cache: vk.PipelineCache,
	count: u32,
	info: ^$U,
	out: ^$Out,
	msg: string,
) -> bool {
	if call(device, cache, count, info, nil, out) != .SUCCESS {
		fmt.printf("Failed to create pipeline %s\n", msg)
		return false
	}
	return true
}

// Generic overloaded wrapper
vkw :: proc {
	vkw_create,
	vkw_enumerate,
	vkw_enumerate_device,
	vkw_enumerate_physical,
	vkw_enumerate_surface,
	vkw_get_property,
	vkw_allocate,
	vkw_create_pipelines,
}


submit_commands :: proc(element: ^SwapchainElement) {
	// Increment timeline value for this frame
	timeline_value += 1

	wait_stages := [1]vk.PipelineStageFlags {
		vk.PipelineStageFlags{vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
	}

	timeline_submit_info := vk.TimelineSemaphoreSubmitInfo {
		sType                     = vk.StructureType.TIMELINE_SEMAPHORE_SUBMIT_INFO,
		signalSemaphoreValueCount = 1,
		pSignalSemaphoreValues    = &timeline_value,
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

	vk.QueueSubmit(queue, 1, &submit_info, element.fence)
}

present_frame :: proc() {
	// Wait for current frame to complete before present
	wait_info := vk.SemaphoreWaitInfo {
		sType          = vk.StructureType.SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &timeline_semaphore,
		pValues        = &timeline_value,
	}
	vk.WaitSemaphores(device, &wait_info, max(u64))

	// Simple present without semaphore wait
	present_info := vk.PresentInfoKHR {
		sType          = vk.StructureType.PRESENT_INFO_KHR,
		swapchainCount = 1,
		pSwapchains    = &swapchain,
		pImageIndices  = &image_index,
	}

	result := vk.QueuePresentKHR(queue, &present_info)
	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		destroy_swapchain()
		create_swapchain()
	}
}


render_frame :: proc(start_time: time.Time) {
	// 1. Get next swapchain image
	if !acquire_next_image() do return

	// 2. Wait for this frame's fence instead of all GPU work
	element := &elements[image_index]
	vk.WaitForFences(device, 1, &element.fence, true, ~u64(0))
	vk.ResetFences(device, 1, &element.fence)

	// 3. Record draw commands
	record_commands(element, start_time)
	// 4. Submit to GPU and present
	submit_commands(element)
	present_frame()
}

// Update window size from Wayland
update_window_size :: proc() {
	width = c.uint32_t(get_window_width())
	height = c.uint32_t(get_window_height())
}

// Handle window resize
handle_resize :: proc() {
	if glfw_resize_needed() != 0 {
		update_window_size()

		// Wait only for queue idle instead of full device
		vk.QueueWaitIdle(queue)

		// Destroy old offscreen image resource (handled by render cleanup)
		cleanup_render_resources()

		destroy_swapchain()
		create_swapchain()

		if width == 0 || height == 0 {
			runtime.assert(false, "width and height must be greater than 0")
			pipelines_ready = false
			return
		}
		// Recreate offscreen resources with new dimensions (handled by render init)
		init_render_resources()
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
	fmt.println("DEBUG: Initializing resources")
	if !init_vulkan_resources() do return false
	fmt.println("DEBUG: Vulkan init complete")
	return true
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
		destroy_swapchain()
		create_swapchain()
		return false
	}

	return result == vk.Result.SUCCESS
}


ShaderInfo :: struct {
	source_path:   string,
	last_modified: time.Time,
}

shader_registry: map[string]ShaderInfo
shader_watch_initialized: bool

init_shader_times :: proc() {
	discover_shaders()
	shader_watch_initialized = true
}

discover_shaders :: proc() {
	if shader_registry == nil {
		shader_registry = make(map[string]ShaderInfo)
	} else {
		delete(shader_registry)
		shader_registry = make(map[string]ShaderInfo)
	}

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
		if strings.has_suffix(file.name, ".hlsl") {
			shader_registry[strings.clone(file.name)] = ShaderInfo {
				source_path   = strings.clone(file.name),
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
		file_info, err := os.stat(info.source_path)
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
			destroy_render_pipeline_state(render_pipeline_states[:])
			if !init_render_pipeline_state(render_pipeline_specs[:], render_pipeline_states[:]) {
				fmt.println("Failed to rebuild pipelines after shader reload")
			}
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

		fmt.printf("Compiling shader %s\n", info.source_path)
		if !compile_shader(info.source_path) {
			fmt.printf("Failed to compile %s\n", info.source_path)
			success = false
		}
	}

	return success
}

SwapchainElement :: struct {
	commandBuffer: vk.CommandBuffer,
	image:         vk.Image,
	imageView:     vk.ImageView,
	framebuffer:   vk.Framebuffer,
	fence:         vk.Fence,
}

// Extension and layer names
get_instance_extensions :: proc() -> []cstring {
	// Get required extensions from GLFW
	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	extensions := make([]cstring, len(glfw_extensions) + 1)
	for i in 0 ..< len(glfw_extensions) {
		extensions[i] = glfw_extensions[i]
	}
	extensions[len(glfw_extensions)] = "VK_EXT_debug_utils"
	return extensions
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
elements: [^]SwapchainElement
format: vk.Format = vk.Format.UNDEFINED
width: c.uint32_t = 800
height: c.uint32_t = 600
image_index: c.uint32_t = 0
image_count: c.uint32_t = 0
// Timeline semaphore for render synchronization + binary for acquire
timeline_semaphore: vk.Semaphore
timeline_value: c.uint64_t = 0
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

		// Create fence for tracking frame completion
		fence_info := vk.FenceCreateInfo {
			sType = vk.StructureType.FENCE_CREATE_INFO,
			flags = {.SIGNALED}, // Start signaled so first frame doesn't wait
		}
		vk.CreateFence(device, &fence_info, nil, &elements[i].fence)

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
		vk.DestroyFence(device, elements[i].fence, nil)
		// Reset command buffer instead of freeing for better performance
		if elements[i].commandBuffer != {} {
			vk.ResetCommandBuffer(elements[i].commandBuffer, {})
		}
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

	vk_get_instance_proc_addr, proc_ok := dynlib.symbol_address(
		vulkan_lib,
		"vkGetInstanceProcAddr",
	)
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

	instance_extensions := get_instance_extensions()
	defer delete(instance_extensions)

	create_info := vk.InstanceCreateInfo {
		sType                   = vk.StructureType.INSTANCE_CREATE_INFO,
		pApplicationInfo        = &app_info,
		enabledLayerCount       = ENABLE_VALIDATION ? len(layer_names) : 0,
		ppEnabledLayerNames     = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
		enabledExtensionCount   = u32(len(instance_extensions)),
		ppEnabledExtensionNames = raw_data(instance_extensions[:]),
	}

	fmt.println("DEBUG: About to create Vulkan instance")
	fmt.printf("DEBUG: Validation layers enabled: %v\n", ENABLE_VALIDATION)
	fmt.printf("DEBUG: Extension count: %d\n", len(instance_extensions))
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

	// Create surface using GLFW
	fmt.println("DEBUG: Creating Vulkan surface")
	window := get_glfw_window()
	result = cast(vk.Result)glfw.CreateWindowSurface(instance, window, nil, &vulkan_surface)
	if result != vk.Result.SUCCESS {
		fmt.printf("Failed to create surface: %d\n", result)
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
		sType         = vk.StructureType.SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = vk.SemaphoreType.TIMELINE,
		initialValue  = 0,
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

	// Create binary semaphore for image acquisition only
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


PostProcessPushConstants :: struct {
	time:              f32,
	exposure:          f32,
	gamma:             f32,
	contrast:          f32,
	texture_width:     u32,
	texture_height:    u32,
	vignette_strength: f32,
	_pad0:             f32,
}


ComputePushConstants :: struct {
	time:           f32,
	delta_time:     f32,
	particle_count: u32,
	_pad0:          u32,
	texture_width:  u32,
	texture_height: u32,
	spread:         f32,
	brightness:     f32,
}

VertexPushConstants :: struct {
	screen_width:  i32,
	screen_height: i32,
}

init_vulkan_resources :: proc() -> bool {

	if width == 0 || height == 0 {
		runtime.assert(false, "width and height must be greater than 0")
		pipelines_ready = false
		return false
	}
	init_render_resources()
	if !pipelines_ready {
		fmt.println("Render pipelines failed to initialize")
		return false
	}
	return true
}

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


// Generic buffer creation
createBuffer :: proc(
	size_bytes: int,
	usage: vk.BufferUsageFlags,
	memory_properties: vk.MemoryPropertyFlags = {vk.MemoryPropertyFlag.DEVICE_LOCAL},
) -> (
	vk.Buffer,
	vk.DeviceMemory,
) {
	buffer_info := vk.BufferCreateInfo {
		sType       = vk.StructureType.BUFFER_CREATE_INFO,
		size        = vk.DeviceSize(size_bytes),
		usage       = usage,
		sharingMode = vk.SharingMode.EXCLUSIVE,
	}

	buffer: vk.Buffer
	if vk.CreateBuffer(device, &buffer_info, nil, &buffer) != vk.Result.SUCCESS {
		fmt.println("Failed to create buffer")
		return {}, {}
	}

	mem_requirements: vk.MemoryRequirements
	vk.GetBufferMemoryRequirements(device, buffer, &mem_requirements)

	alloc_info := vk.MemoryAllocateInfo {
		sType           = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_requirements.size,
		memoryTypeIndex = find_memory_type(mem_requirements.memoryTypeBits, memory_properties),
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


vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)

	// Command buffers are freed automatically when command pool is destroyed
	// No need to manually free them since they're allocated from the pool

	destroy_swapchain()

	cleanup_render_resources()

	// Cleanup remaining vulkan resources
	vk.DestroySemaphore(device, timeline_semaphore, nil)
	vk.DestroySemaphore(device, image_available_semaphore, nil)
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

foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
