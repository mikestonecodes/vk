package main

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:fmt"
import image "core:image"
import png "core:image/png"
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
format: vk.Format = vk.Format.UNDEFINED
width: c.uint32_t = 800
height: c.uint32_t = 600
image_index: c.uint32_t = 0
image_count: c.uint32_t = 0
// Timeline semaphore for render synchronization
timeline_semaphore: vk.Semaphore
timeline_value: c.uint64_t = 0

MAX_FRAMES_IN_FLIGHT :: c.uint32_t(3)
MAX_SWAPCHAIN_IMAGES :: c.uint32_t(8) // 8 is plenty; most drivers use 2–4
//image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore

image_available: [MAX_FRAMES_IN_FLIGHT]vk.Semaphore
elements: [MAX_SWAPCHAIN_IMAGES]SwapchainElement
image_render_finished: [MAX_SWAPCHAIN_IMAGES]vk.Semaphore

//frame_timeline_values: [MAX_FRAMES_IN_FLIGHT]c.uint64_t
frames_in_flight: c.uint32_t = 0
current_frame: c.uint32_t = 0

frame_slot_values: [MAX_FRAMES_IN_FLIGHT]c.uint64_t

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

submit_commands :: proc(element: ^SwapchainElement, frame_index: u32) {
	timeline_value += 1
	new_value := timeline_value
	old_value := element.last_value

	wait_values := [2]u64{0, old_value}
	signal_values := [2]u64{0, new_value}

	wait_semaphores := [2]vk.Semaphore{image_available[frame_index], timeline_semaphore}
	wait_stages := [2]vk.PipelineStageFlags {
		{vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
		{vk.PipelineStageFlag.TOP_OF_PIPE},
	}
	signal_semaphores := [2]vk.Semaphore{image_render_finished[image_index], timeline_semaphore}

	timeline_submit_info := vk.TimelineSemaphoreSubmitInfo {
		sType                     = vk.StructureType.TIMELINE_SEMAPHORE_SUBMIT_INFO,
		waitSemaphoreValueCount   = 2,
		pWaitSemaphoreValues      = raw_data(wait_values[:]),
		signalSemaphoreValueCount = 2,
		pSignalSemaphoreValues    = raw_data(signal_values[:]),
	}

	submit_info := vk.SubmitInfo {
		sType                = vk.StructureType.SUBMIT_INFO,
		pNext                = &timeline_submit_info,
		waitSemaphoreCount   = 2,
		pWaitSemaphores      = raw_data(wait_semaphores[:]),
		pWaitDstStageMask    = raw_data(wait_stages[:]),
		commandBufferCount   = 1,
		pCommandBuffers      = &element.commandBuffer,
		signalSemaphoreCount = 2,
		pSignalSemaphores    = raw_data(signal_semaphores[:]),
	}

	vk.QueueSubmit(queue, 1, &submit_info, {})
	element.last_value = new_value
	frame_slot_values[frame_index] = new_value // 🔑 track per-frame slot too
}

present_frame :: proc(image_index: c.uint32_t) -> bool {
	index_copy := image_index
	wait_semaphores := [1]vk.Semaphore{image_render_finished[image_index]}

	present_info := vk.PresentInfoKHR {
		sType              = vk.StructureType.PRESENT_INFO_KHR,
		waitSemaphoreCount = cast(u32)len(wait_semaphores),
		pWaitSemaphores    = raw_data(wait_semaphores[:]),
		swapchainCount     = 1,
		pSwapchains        = &swapchain,
		pImageIndices      = &index_copy,
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
	if frames_in_flight == 0 {
		return false
	}

	frame_index := current_frame % frames_in_flight

	wait_for_timeline(frame_slot_values[frame_index])
	acquire_next_image(frame_index) or_return

	element := &elements[image_index]
	wait_for_timeline(element.last_value)

	// 4. Record rendering commands
	encoder, frame := begin_frame_commands(element, start_time)
	record_commands(element, frame)
	finish_encoding(&encoder)

	// 5. Submit draw work
	submit_commands(element, frame_index)

	// 6. Present once rendering completes
	present_frame(image_index) or_return

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

	changed: [dynamic]string
	defer delete(changed)

	for name, &info in shader_registry {
		if file_info, err := os.stat(info.source_path);
		   err == nil && file_info.modification_time != info.last_modified {
			info.last_modified = file_info.modification_time
			append(&changed, name)
		}
	}

	if len(changed) > 0 && compile_changed_shaders(changed[:]) {
		vk.QueueWaitIdle(queue) // 🔒 make sure old pipelines are done
		destroy_render_pipeline_state(render_pipeline_states[:])
		if !init_render_pipeline_state(render_pipeline_specs[:], render_pipeline_states[:]) {
			return false
		}
		pipelines_ready = build_pipelines(render_pipeline_specs[:], render_pipeline_states[:])
	}

	return pipelines_ready
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
	// Query caps
	caps: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &caps) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to query surface caps")
		return false
	}

	// Pick format
	formats, ok := vkw_enumerate_surface(
		vk.GetPhysicalDeviceSurfaceFormatsKHR,
		phys_device,
		vulkan_surface,
		"surface formats",
		vk.SurfaceFormatKHR,
	)
	if !ok do return false
	defer delete(formats)

	chosen := formats[0]
	for f in formats {
		if f.format == vk.Format.B8G8R8A8_UNORM {chosen = f;break}
	}
	format = chosen.format

	// Pick image count
	desired := caps.minImageCount + 1
	if caps.maxImageCount > 0 && desired > caps.maxImageCount {
		desired = caps.maxImageCount
	}

	// Create swapchain
	swapchain = vkw(
		vk.CreateSwapchainKHR,
		device,
		&vk.SwapchainCreateInfoKHR {
			sType = vk.StructureType.SWAPCHAIN_CREATE_INFO_KHR,
			surface = vulkan_surface,
			minImageCount = desired,
			imageFormat = chosen.format,
			imageColorSpace = chosen.colorSpace,
			imageExtent = {width, height},
			imageArrayLayers = 1,
			imageUsage = {vk.ImageUsageFlag.COLOR_ATTACHMENT},
			imageSharingMode = vk.SharingMode.EXCLUSIVE,
			preTransform = caps.currentTransform,
			compositeAlpha = {vk.CompositeAlphaFlagKHR.OPAQUE},
			presentMode = vk.PresentModeKHR.IMMEDIATE,
			clipped = true,
		},
		"swapchain",
		vk.SwapchainKHR,
	) or_return

	// Create render pass
	render_pass = vkw(
		vk.CreateRenderPass,
		device,
		&vk.RenderPassCreateInfo {
			sType = vk.StructureType.RENDER_PASS_CREATE_INFO,
			attachmentCount = 1,
			pAttachments = &vk.AttachmentDescription {
				format = format,
				samples = {vk.SampleCountFlag._1},
				loadOp = vk.AttachmentLoadOp.CLEAR,
				storeOp = vk.AttachmentStoreOp.STORE,
				initialLayout = vk.ImageLayout.UNDEFINED,
				finalLayout = vk.ImageLayout.PRESENT_SRC_KHR,
			},
			subpassCount = 1,
			pSubpasses = &vk.SubpassDescription {
				pipelineBindPoint = vk.PipelineBindPoint.GRAPHICS,
				colorAttachmentCount = 1,
				pColorAttachments = &vk.AttachmentReference {
					attachment = 0,
					layout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
				},
			},
		},
		"render pass",
		vk.RenderPass,
	) or_return

	// Get swapchain images
	image_count = desired
	if vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil) != vk.Result.SUCCESS {
		fmt.println("Failed to query swapchain images")
		return false
	}
	imgs := make([^]vk.Image, image_count)
	defer free(imgs)
	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, imgs)

	// Allocate elements + semaphores
	for i in 0 ..< image_count {
		elements[i].image = imgs[i]
		elements[i].last_value = 0

		elements[i].imageView = vkw(
			vk.CreateImageView,
			device,
			&vk.ImageViewCreateInfo {
				sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
				viewType = vk.ImageViewType.D2,
				format = format,
				subresourceRange = {
					aspectMask = {vk.ImageAspectFlag.COLOR},
					levelCount = 1,
					layerCount = 1,
				},
				image = imgs[i],
			},
			"image view",
			vk.ImageView,
		) or_return

		elements[i].framebuffer = vkw(
			vk.CreateFramebuffer,
			device,
			&vk.FramebufferCreateInfo {
				sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
				renderPass = render_pass,
				attachmentCount = 1,
				pAttachments = &elements[i].imageView,
				width = width,
				height = height,
				layers = 1,
			},
			"framebuffer",
			vk.Framebuffer,
		) or_return

		vk.AllocateCommandBuffers(
			device,
			&vk.CommandBufferAllocateInfo {
				sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = command_pool,
				commandBufferCount = 1,
				level = vk.CommandBufferLevel.PRIMARY,
			},
			&elements[i].commandBuffer,
		)

		image_render_finished[i] = vkw(
			vk.CreateSemaphore,
			device,
			&vk.SemaphoreCreateInfo{sType = vk.StructureType.SEMAPHORE_CREATE_INFO},
			"render finished semaphore",
			vk.Semaphore,
		) or_return
	}


	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		image_available[i] = vkw(
			vk.CreateSemaphore,
			device,
			&vk.SemaphoreCreateInfo{sType = vk.StructureType.SEMAPHORE_CREATE_INFO},
			"image available semaphore",
			vk.Semaphore,
		) or_return
	}


	frames_in_flight = min(image_count, MAX_FRAMES_IN_FLIGHT)
	if frames_in_flight == 0 do frames_in_flight = 1
	current_frame = 0
	//	for i in 0 ..< len(frame_timeline_values) do frame_timeline_values[i] = 0

	return true
}

destroy_swapchain :: proc() {

	for i in 0 ..< image_count {
		if elements[i].framebuffer != {} do vk.DestroyFramebuffer(device, elements[i].framebuffer, nil)
		if elements[i].imageView != {} do vk.DestroyImageView(device, elements[i].imageView, nil)
		if elements[i].commandBuffer != {} do vk.ResetCommandBuffer(elements[i].commandBuffer, {})
		if image_render_finished[i] != {} do vk.DestroySemaphore(device, image_render_finished[i], nil)

		// zero-out the slots (optional but tidy)
		elements[i] = SwapchainElement{}
		image_render_finished[i] = {}
	}
	image_count = 0
	frames_in_flight = 0
	current_frame = 0

	vk.DestroyRenderPass(device, render_pass, nil)
	vk.DestroySwapchainKHR(device, swapchain, nil)
}

init_vulkan :: proc() -> bool {
	// Load global function pointers (this uses the loader already provided by the system)
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	// --- Create instance ---
	instance_extensions := get_instance_extensions()
	defer delete(instance_extensions)

	app_info := vk.ApplicationInfo {
		sType              = vk.StructureType.APPLICATION_INFO,
		pApplicationName   = "Wayland Vulkan Example",
		applicationVersion = vk.MAKE_VERSION(1, 0, 0),
		pEngineName        = "No Engine",
		engineVersion      = vk.MAKE_VERSION(1, 0, 0),
		apiVersion         = vk.API_VERSION_1_3,
	}

	if vk.CreateInstance(
		   &vk.InstanceCreateInfo {
			   sType = vk.StructureType.INSTANCE_CREATE_INFO,
			   pApplicationInfo = &app_info,
			   enabledLayerCount = ENABLE_VALIDATION ? len(layer_names) : 0,
			   ppEnabledLayerNames = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
			   enabledExtensionCount = u32(len(instance_extensions)),
			   ppEnabledExtensionNames = raw_data(instance_extensions),
		   },
		   nil,
		   &instance,
	   ) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to create instance")
		return false
	}

	// Load instance-level functions
	vk.load_proc_addresses_instance(instance)

	if ENABLE_VALIDATION && !setup_debug_messenger() {
		return false
	}

	// Create window surface (GLFW provides helper)
	if cast(vk.Result)glfw.CreateWindowSurface(
		   instance,
		   get_glfw_window(),
		   nil,
		   &vulkan_surface,
	   ) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to create surface")
		return false
	}

	// Pick physical + logical device
	setup_physical_device() or_return
	create_logical_device() or_return

	// Load device-level functions
	vk.load_proc_addresses_device(device)

	// Command pool
	cmd_pool_info := vk.CommandPoolCreateInfo {
		sType            = vk.StructureType.COMMAND_POOL_CREATE_INFO,
		queueFamilyIndex = queue_family_index,
		flags            = {vk.CommandPoolCreateFlag.RESET_COMMAND_BUFFER},
	}
	if vk.CreateCommandPool(device, &cmd_pool_info, nil, &command_pool) != vk.Result.SUCCESS {
		fmt.println("Failed to create command pool")
		return false
	}

	// Timeline semaphore
	timeline_info := vk.SemaphoreTypeCreateInfo {
		sType         = vk.StructureType.SEMAPHORE_TYPE_CREATE_INFO,
		semaphoreType = vk.SemaphoreType.TIMELINE,
		initialValue  = 0,
	}
	sem_info := vk.SemaphoreCreateInfo {
		sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
		pNext = &timeline_info,
	}


	if vk.CreateSemaphore(device, &sem_info, nil, &timeline_semaphore) != vk.Result.SUCCESS {
		fmt.println("Failed to create timeline semaphore")
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

TextureResource :: struct {
	image:   vk.Image,
	memory:  vk.DeviceMemory,
	view:    vk.ImageView,
	sampler: vk.Sampler,
	width:   u32,
	height:  u32,
	format:  vk.Format,
	layout:  vk.ImageLayout,
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

destroy_texture :: proc(resource: ^TextureResource) {
	if resource.view != {} {
		vk.DestroyImageView(device, resource.view, nil)
	}
	if resource.image != {} {
		vk.DestroyImage(device, resource.image, nil)
	}
	if resource.memory != {} {
		vk.FreeMemory(device, resource.memory, nil)
	}
	if resource.sampler != {} {
		vk.DestroySampler(device, resource.sampler, nil)
	}
	resource^ = TextureResource{}
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


execute_single_time_commands :: proc(
	record: proc(cmd: vk.CommandBuffer, user_data: rawptr) -> bool,
	user_data: rawptr,
) -> bool {
	cmd: vk.CommandBuffer
	if vk.AllocateCommandBuffers(
		   device,
		   &vk.CommandBufferAllocateInfo {
			   sType = vk.StructureType.COMMAND_BUFFER_ALLOCATE_INFO,
			   commandPool = command_pool,
			   level = vk.CommandBufferLevel.PRIMARY,
			   commandBufferCount = 1,
		   },
		   &cmd,
	   ) !=
	   vk.Result.SUCCESS {
		fmt.println("Failed to allocate single-time command buffer")
		return false
	}
	defer vk.FreeCommandBuffers(device, command_pool, 1, &cmd)

	begin_info := vk.CommandBufferBeginInfo {
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}

	if vk.BeginCommandBuffer(cmd, &begin_info) != vk.Result.SUCCESS {
		fmt.println("Failed to begin single-time command buffer")
		return false
	}

	if !record(cmd, user_data) {
		vk.EndCommandBuffer(cmd)
		return false
	}

	if vk.EndCommandBuffer(cmd) != vk.Result.SUCCESS {
		fmt.println("Failed to end single-time command buffer")
		return false
	}

	submit := vk.SubmitInfo {
		sType              = vk.StructureType.SUBMIT_INFO,
		commandBufferCount = 1,
		pCommandBuffers    = &cmd,
	}

	if vk.QueueSubmit(queue, 1, &submit, vk.Fence{}) != vk.Result.SUCCESS {
		fmt.println("Failed to submit single-time commands")
		return false
	}

	vk.QueueWaitIdle(queue)
	return true
}


vulkan_cleanup :: proc() {
	vk.DeviceWaitIdle(device)

	// Command buffers are freed automatically when command pool is destroyed
	// No need to manually free them since they're allocated from the pool

	destroy_swapchain()

	cleanup_render_resources()

	destroy_render_pipeline_state(render_pipeline_states[:])

	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		if image_available[i] != {} do vk.DestroySemaphore(device, image_available[i], nil)
	}
	// Cleanup remaining vulkan resources
	vk.DestroySemaphore(device, timeline_semaphore, nil)

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


//images

// Single path: decode -> allocate -> copy -> view -> sampler

create_texture_from_png :: proc(path: string) -> (TextureResource, bool) {
	tex: TextureResource

	img, err := png.load_from_file(path, {.alpha_add_if_missing})
	if err != nil || img == nil {
		return tex, false
	}
	defer png.destroy(img)

	required := img.width * img.height * 4
	src := bytes.buffer_to_bytes(&img.pixels)
	pixels := make([]u8, required)
	defer delete(pixels)

	copy(pixels, src[:required])

	// --- Image
	ci := vk.ImageCreateInfo {
		sType = vk.StructureType.IMAGE_CREATE_INFO,
		imageType = vk.ImageType.D2,
		format = vk.Format.R8G8B8A8_UNORM,
		extent = {width = u32(img.width), height = u32(img.height), depth = 1},
		mipLevels = 1,
		arrayLayers = 1,
		samples = {vk.SampleCountFlag._1},
		tiling = vk.ImageTiling.LINEAR,
		usage = {vk.ImageUsageFlag.SAMPLED},
		sharingMode = vk.SharingMode.EXCLUSIVE,
		initialLayout = vk.ImageLayout.PREINITIALIZED,
	}
	tex.image, _ = vkw(vk.CreateImage, device, &ci, "texture image", vk.Image)

	mem_req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, tex.image, &mem_req)

	alloc := vk.MemoryAllocateInfo {
		sType           = vk.StructureType.MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_req.size,
		memoryTypeIndex = find_memory_type(
			mem_req.memoryTypeBits,
			{vk.MemoryPropertyFlag.HOST_VISIBLE, vk.MemoryPropertyFlag.HOST_COHERENT},
		),
	}
	vk.AllocateMemory(device, &alloc, nil, &tex.memory)
	vk.BindImageMemory(device, tex.image, tex.memory, 0)

	// --- Copy pixels
	data: rawptr
	vk.MapMemory(device, tex.memory, 0, mem_req.size, {}, &data)
	runtime.mem_copy_non_overlapping(data, raw_data(pixels), len(pixels))
	vk.UnmapMemory(device, tex.memory)

	// --- Transition layout from PREINITIALIZED to GENERAL
	if !execute_single_time_commands(proc(cmd: vk.CommandBuffer, user_data: rawptr) -> bool {
		tex := (^TextureResource)(user_data)
		return transition_image_layout(cmd, tex.image, vk.ImageLayout.PREINITIALIZED, vk.ImageLayout.GENERAL)
	}, &tex) {
		return tex, false
	}

	// --- Metadata
	tex.width = u32(img.width)
	tex.height = u32(img.height)
	tex.format = vk.Format.R8G8B8A8_UNORM
	tex.layout = vk.ImageLayout.GENERAL

	// --- View
	vi := vk.ImageViewCreateInfo {
		sType = vk.StructureType.IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = vk.ImageViewType.D2,
		format = tex.format,
		subresourceRange = {
			aspectMask = {vk.ImageAspectFlag.COLOR},
			levelCount = 1,
			layerCount = 1,
		},
	}
	tex.view, _ = vkw(vk.CreateImageView, device, &vi, "texture view", vk.ImageView)

	// --- Sampler
	si := vk.SamplerCreateInfo {
		sType        = vk.StructureType.SAMPLER_CREATE_INFO,
		magFilter    = vk.Filter.LINEAR,
		minFilter    = vk.Filter.LINEAR,
		addressModeU = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		addressModeV = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		addressModeW = vk.SamplerAddressMode.CLAMP_TO_EDGE,
		borderColor  = vk.BorderColor.FLOAT_OPAQUE_WHITE,
	}
	tex.sampler, _ = vkw(vk.CreateSampler, device, &si, "sampler", vk.Sampler)

	return tex, true
}


foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
