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
// Timeline semaphore for render synchronization
timeline_semaphore: vk.Semaphore
timeline_value: c.uint64_t = 0

MAX_FRAMES_IN_FLIGHT :: c.uint32_t(3)

image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
render_finished: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
frames_in_flight: c.uint32_t = 0
current_frame: c.uint32_t = 0

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

//----//


wait_for_timeline :: proc(value: c.uint64_t) {
	if value == 0 {
		return
	}

	current: c.uint64_t
	if vk.GetSemaphoreCounterValue(device, timeline_semaphore, &current) == vk.Result.SUCCESS &&
	   current >= value {
		return
	}

	wait_value := value
	wait_info := vk.SemaphoreWaitInfo {
		sType          = vk.StructureType.SEMAPHORE_WAIT_INFO,
		semaphoreCount = 1,
		pSemaphores    = &timeline_semaphore,
		pValues        = &wait_value,
	}

	vk.WaitSemaphores(device, &wait_info, max(u64))
}

acquire_next_image :: proc(frame_index: c.uint32_t) -> bool {
	result := vk.AcquireNextImageKHR(
		device,
		swapchain,
		max(u64),
		image_available[frame_index],
		{},
		&image_index,
	)

	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		destroy_swapchain()
		create_swapchain() or_return
		return false
	}

	return result == vk.Result.SUCCESS
}

submit_commands :: proc(element: ^SwapchainElement, frame_index: c.uint32_t) {
	// Increment timeline value for this frame
	timeline_value += 1

	wait_stages := [1]vk.PipelineStageFlags {
		vk.PipelineStageFlags{vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
	}

	timeline_values := [2]c.uint64_t{c.uint64_t(0), timeline_value}

	timeline_submit_info := vk.TimelineSemaphoreSubmitInfo {
		sType                     = vk.StructureType.TIMELINE_SEMAPHORE_SUBMIT_INFO,
		waitSemaphoreValueCount   = 0,
		pWaitSemaphoreValues      = nil,
		signalSemaphoreValueCount = cast(u32)len(timeline_values),
		pSignalSemaphoreValues    = raw_data(timeline_values[:]),
	}

	wait_semaphores := [1]vk.Semaphore{image_available[frame_index]}

	signal_semaphores := [2]vk.Semaphore{render_finished[frame_index], timeline_semaphore}

	submit_info := vk.SubmitInfo {
		sType                = vk.StructureType.SUBMIT_INFO,
		pNext                = &timeline_submit_info,
		waitSemaphoreCount   = cast(u32)len(wait_semaphores),
		pWaitSemaphores      = raw_data(wait_semaphores[:]),
		pWaitDstStageMask    = raw_data(wait_stages[:]),
		commandBufferCount   = 1,
		pCommandBuffers      = &element.commandBuffer,
		signalSemaphoreCount = cast(u32)len(signal_semaphores),
		pSignalSemaphores    = raw_data(signal_semaphores[:]),
	}

	vk.QueueSubmit(queue, 1, &submit_info, {})
	element.last_value = timeline_value
}

present_frame :: proc(frame_index: c.uint32_t) -> bool {
	wait_semaphores := [1]vk.Semaphore{render_finished[frame_index]}

	present_info := vk.PresentInfoKHR {
		sType              = vk.StructureType.PRESENT_INFO_KHR,
		waitSemaphoreCount = cast(u32)len(wait_semaphores),
		pWaitSemaphores    = raw_data(wait_semaphores[:]),
		swapchainCount     = 1,
		pSwapchains        = &swapchain,
		pImageIndices      = &image_index,
	}

	result := vk.QueuePresentKHR(queue, &present_info)
	if result == vk.Result.ERROR_OUT_OF_DATE_KHR || result == vk.Result.SUBOPTIMAL_KHR {
		destroy_swapchain()
		create_swapchain() or_return
		return false
	}
	return true
}

render_frame :: proc(start_time: time.Time) -> bool {
	if frames_in_flight == 0 || elements == nil {
		return false
	}

	frame_index := current_frame % frames_in_flight

	// 1. Acquire swapchain image for this frame slot
	acquire_next_image(frame_index) or_return

	// 2. Wait for the image's previous work to finish before reusing resources
	element := &elements[image_index]
	wait_for_timeline(element.last_value)

	// 3. Record rendering commands targeting the acquired image
	encoder, frame := begin_frame_commands(element, start_time)
	record_commands(element, frame)
	finish_encoding(&encoder)

	// 4. Submit draw work, signaling both the render-finished semaphore and timeline
	submit_commands(element, frame_index)

	// 5. Present once rendering completes
	present_frame(frame_index) or_return

	current_frame = (frame_index + 1) % frames_in_flight

	return true
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
		destroy_render_pipeline_state(render_pipeline_states[:])

		pipelines_ready = false
		destroy_swapchain()
		if !create_swapchain() {
			return
		}

		if width == 0 || height == 0 {
			runtime.assert(false, "width and height must be greater than 0")
			return
		}
		// Recreate offscreen resources with new dimensions (handled by render init)
		init_render_resources()

		destroy_render_pipeline_state(render_pipeline_states[:])
		pipelines_ready = build_pipelines(render_pipeline_specs[:], render_pipeline_states[:])

	}
}

vulkan_init :: proc() -> (ok: bool) {
	// Get initial window size
	fmt.println("DEBUG: Getting window size")
	update_window_size()

	fmt.println("DEBUG: Initializing Vulkan")
	if !init_vulkan() do return false
	fmt.println("DEBUG: Creating swapchain")
	create_swapchain() or_return
	fmt.println("DEBUG: Initializing resources")
	if !init_vulkan_resources() do return false
	fmt.println("DEBUG: Vulkan init complete")
	return true
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


//RELOAD
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
				fmt.println("Failed to refresh shader modules after shader reload")
				return false
			}
			pipelines_ready = build_pipelines(render_pipeline_specs[:], render_pipeline_states[:])
			if !pipelines_ready {
				fmt.println("Failed to rebuild pipelines after shader reload")
			}
			return pipelines_ready
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
	last_value:    c.uint64_t,
}


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

create_swapchain :: proc() -> bool {
	capabilities: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &capabilities) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to query surface capabilities")
		return false
	}

	formats, ok := vkw_enumerate_surface(
		vk.GetPhysicalDeviceSurfaceFormatsKHR,
		phys_device,
		vulkan_surface,
		"surface formats",
		vk.SurfaceFormatKHR,
	)
	if !ok {
		return false
	}
	defer delete(formats)

	chosen_format := formats[0]
	for fmt_idx in 0 ..< len(formats) {
		if formats[fmt_idx].format == vk.Format.B8G8R8A8_UNORM {
			chosen_format = formats[fmt_idx]
			break
		}
	}
	format = chosen_format.format

	desired_images := capabilities.minImageCount + 1
	if capabilities.maxImageCount > 0 && desired_images > capabilities.maxImageCount {
		desired_images = capabilities.maxImageCount
	}

	new_swapchain := vkw(
		vk.CreateSwapchainKHR,
		device,
		&vk.SwapchainCreateInfoKHR {
			sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
			surface = vulkan_surface,
			minImageCount = desired_images,
			imageFormat = chosen_format.format,
			imageColorSpace = chosen_format.colorSpace,
			imageExtent = {width, height},
			imageArrayLayers = 1,
			imageUsage = {vk.ImageUsageFlag.COLOR_ATTACHMENT},
			imageSharingMode = vk.SharingMode.EXCLUSIVE,
			preTransform = capabilities.currentTransform,
			compositeAlpha = {vk.CompositeAlphaFlagKHR.OPAQUE},
			presentMode = vk.PresentModeKHR.FIFO,
			clipped = true,
		},
		"swapchain",
		vk.SwapchainKHR,
	) or_return

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

	new_render_pass := vkw(
		vk.CreateRenderPass,
		device,
		&vk.RenderPassCreateInfo {
			sType = vk.StructureType.RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &attachment,
			subpassCount = 1,
			pSubpasses = &subpass,
		},
		"render pass",
		vk.RenderPass,
	) or_return

	actual_image_count := desired_images
	if vk.GetSwapchainImagesKHR(device, new_swapchain, &actual_image_count, nil) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to query swapchain images")
		vk.DestroyRenderPass(device, new_render_pass, nil)
		vk.DestroySwapchainKHR(device, new_swapchain, nil)
		return false
	}

	images := make([^]vk.Image, actual_image_count)
	defer free(images)
	if vk.GetSwapchainImagesKHR(device, new_swapchain, &actual_image_count, images) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to fetch swapchain images")
		vk.DestroyRenderPass(device, new_render_pass, nil)
		vk.DestroySwapchainKHR(device, new_swapchain, nil)
		return false
	}

	new_elements := make([^]SwapchainElement, actual_image_count)
	success := false
	defer {
		if !success {
			for i in 0 ..< actual_image_count {
				if new_elements[i].framebuffer != {} {
					vk.DestroyFramebuffer(device, new_elements[i].framebuffer, nil)
				}
				if new_elements[i].imageView != {} {
					vk.DestroyImageView(device, new_elements[i].imageView, nil)
				}
				if new_elements[i].commandBuffer != {} {
					vk.ResetCommandBuffer(new_elements[i].commandBuffer, {})
				}
			}
			free(new_elements)
			vk.DestroyRenderPass(device, new_render_pass, nil)
			vk.DestroySwapchainKHR(device, new_swapchain, nil)
		}
	}

	for i in 0 ..< actual_image_count {
		vk.AllocateCommandBuffers(
			device,
			&vk.CommandBufferAllocateInfo {
				sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = command_pool,
				commandBufferCount = 1,
				level = vk.CommandBufferLevel.PRIMARY,
			},
			&new_elements[i].commandBuffer,
		)
		new_elements[i].image = images[i]
		new_elements[i].last_value = 0

		new_elements[i].imageView = vkw(
			vk.CreateImageView,
			device,
			&vk.ImageViewCreateInfo {
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
				image = new_elements[i].image,
				format = format,
			},
			"image view",
			vk.ImageView,
		) or_return

		new_elements[i].framebuffer = vkw(
			vk.CreateFramebuffer,
			device,
			&vk.FramebufferCreateInfo {
				sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
				renderPass = new_render_pass,
				attachmentCount = 1,
				pAttachments = &new_elements[i].imageView,
				width = width,
				height = height,
				layers = 1,
			},
			"framebuffer",
			vk.Framebuffer,
		) or_return
	}

	frames_in_flight = actual_image_count
	if frames_in_flight > MAX_FRAMES_IN_FLIGHT {
		frames_in_flight = MAX_FRAMES_IN_FLIGHT
	}
	if frames_in_flight == 0 {
		frames_in_flight = 1
	}
	current_frame = 0

	if elements != nil {
		free(elements)
	}

	swapchain = new_swapchain
	render_pass = new_render_pass
	elements = new_elements
	image_count = actual_image_count
	success = true
	return true
}

destroy_swapchain :: proc() {
	if elements != nil {
		for i in 0 ..< image_count {
			if elements[i].framebuffer != {} {
				vk.DestroyFramebuffer(device, elements[i].framebuffer, nil)
			}
			if elements[i].imageView != {} {
				vk.DestroyImageView(device, elements[i].imageView, nil)
			}
			if elements[i].commandBuffer != {} {
				vk.ResetCommandBuffer(elements[i].commandBuffer, {})
			}
		}
		free(elements)
		elements = nil
	}
	image_count = 0
	frames_in_flight = 0
	current_frame = 0
	if render_pass != {} {
		vk.DestroyRenderPass(device, render_pass, nil)
		render_pass = {}
	}
	if swapchain != {} {
		vk.DestroySwapchainKHR(device, swapchain, nil)
		swapchain = {}
	}
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

	binary_sem_info := vk.SemaphoreCreateInfo {
		sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
	}

	for i in 0 ..< len(image_available) {
		image_available[i] = vkw(
			vk.CreateSemaphore,
			device,
			&binary_sem_info,
			"image available semaphore",
			vk.Semaphore,
		) or_return
		render_finished[i] = vkw(
			vk.CreateSemaphore,
			device,
			&binary_sem_info,
			"render finished semaphore",
			vk.Semaphore,
		) or_return
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
	destroy_render_pipeline_state(render_pipeline_states[:])
	pipelines_ready = build_pipelines(render_pipeline_specs[:], render_pipeline_states[:])
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

BufferResource :: struct {
	buffer: vk.Buffer,
	memory: vk.DeviceMemory,
	size:   vk.DeviceSize,
}

create_buffer :: proc(
	resource: ^BufferResource,
	size: vk.DeviceSize,
	usage: vk.BufferUsageFlags,
	memory_properties: vk.MemoryPropertyFlags = {vk.MemoryPropertyFlag.DEVICE_LOCAL},
) -> bool {
	buffer, memory := createBuffer(int(size), usage, memory_properties)
	if buffer == {} {
		resource^ = BufferResource{}
		return false
	}

	resource.buffer = buffer
	resource.memory = memory
	resource.size = size
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

BufferBarriers :: struct {
	transfer_to_compute: vk.BufferMemoryBarrier,
	compute_to_fragment: vk.BufferMemoryBarrier,
}

init_buffer_barriers :: proc(barriers: ^BufferBarriers, resource: ^BufferResource) {
	if resource.buffer == {} {
		barriers^ = BufferBarriers{}
		return
	}

	barriers.transfer_to_compute = vk.BufferMemoryBarrier {
		sType               = vk.StructureType.BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {vk.AccessFlag.TRANSFER_WRITE},
		dstAccessMask       = {vk.AccessFlag.SHADER_WRITE},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = resource.buffer,
		offset              = 0,
		size                = resource.size,
	}

	barriers.compute_to_fragment = vk.BufferMemoryBarrier {
		sType               = vk.StructureType.BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {vk.AccessFlag.SHADER_WRITE},
		dstAccessMask       = {vk.AccessFlag.SHADER_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = resource.buffer,
		offset              = 0,
		size                = resource.size,
	}
}

reset_buffer_barriers :: proc(barriers: ^BufferBarriers) {
	barriers.transfer_to_compute = vk.BufferMemoryBarrier{}
	barriers.compute_to_fragment = vk.BufferMemoryBarrier{}
}

apply_transfer_to_compute_barrier :: proc(cmd: vk.CommandBuffer, barriers: ^BufferBarriers) {
	runtime.assert(
		barriers.transfer_to_compute.buffer != {},
		"transfer barrier requested before initialization",
	)
	vk.CmdPipelineBarrier(
		cmd,
		{vk.PipelineStageFlag.TRANSFER},
		{vk.PipelineStageFlag.COMPUTE_SHADER},
		{},
		0,
		nil,
		1,
		&barriers.transfer_to_compute,
		0,
		nil,
	)
}

apply_compute_to_fragment_barrier :: proc(cmd: vk.CommandBuffer, barriers: ^BufferBarriers) {
	runtime.assert(
		barriers.compute_to_fragment.buffer != {},
		"compute barrier requested before initialization",
	)
	vk.CmdPipelineBarrier(
		cmd,
		{vk.PipelineStageFlag.COMPUTE_SHADER},
		{vk.PipelineStageFlag.FRAGMENT_SHADER},
		{},
		0,
		nil,
		1,
		&barriers.compute_to_fragment,
		0,
		nil,
	)
}


vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)

	// Command buffers are freed automatically when command pool is destroyed
	// No need to manually free them since they're allocated from the pool

	destroy_swapchain()

	cleanup_render_resources()

	destroy_render_pipeline_state(render_pipeline_states[:])

	// Cleanup remaining vulkan resources
	vk.DestroySemaphore(device, timeline_semaphore, nil)
	for i in 0 ..< len(image_available) {
		if image_available[i] != {} {
			vk.DestroySemaphore(device, image_available[i], nil)
			image_available[i] = {}
		}
		if render_finished[i] != {} {
			vk.DestroySemaphore(device, render_finished[i], nil)
			render_finished[i] = {}
		}
	}
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
