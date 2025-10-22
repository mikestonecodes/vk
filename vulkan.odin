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
format: vk.Format = vk.Format.UNDEFINED
width: c.uint32_t = 800
height: c.uint32_t = 600
image_index: c.uint32_t = 0
image_count: c.uint32_t = 0
// Timeline semaphore for render synchronization
timeline_semaphore: vk.Semaphore
timeline_value: c.uint64_t = 0
image_available_semaphore: vk.Semaphore
render_finished_semaphore: vk.Semaphore

MAX_FRAMES_IN_FLIGHT :: c.uint32_t(3)
MAX_SWAPCHAIN_IMAGES :: c.uint32_t(4) // 4 keeps headroom for triple-buffer drivers
elements: [MAX_SWAPCHAIN_IMAGES]SwapchainElement

instance_extensions := Array(16, cstring){}
physical_devices := Array(8, vk.PhysicalDevice){}
queue_families := Array(16, vk.QueueFamilyProperties){}
surface_formats := Array(16, vk.SurfaceFormatKHR){}

swapchain_image_handles: [MAX_SWAPCHAIN_IMAGES]vk.Image

MAX_SPIRV_BYTES :: 1 << 20
spirv_words := Array(MAX_SPIRV_BYTES / 4, u32){}

//frame_timeline_values: [MAX_FRAMES_IN_FLIGHT]c.uint64_t
frames_in_flight: c.uint32_t = 0
current_frame: c.uint32_t = 0

frame_slot_values: [MAX_FRAMES_IN_FLIGHT]c.uint64_t


SwapchainElement :: struct {
	commandBuffer: vk.CommandBuffer,
	image:         vk.Image,
	imageView:     vk.ImageView,
	layout:        vk.ImageLayout,
	last_value:    c.uint64_t,
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

acquire_next_image :: proc(_: c.uint32_t) -> bool {

	acquire_info := vk.AcquireNextImageInfoKHR {
		sType      = .ACQUIRE_NEXT_IMAGE_INFO_KHR,
		swapchain  = swapchain,
		timeout    = max(u64),
		semaphore  = image_available_semaphore, // timeline semaphore used later
		fence      = {},
		deviceMask = 1,
	}

	result := vk.AcquireNextImage2KHR(device, &acquire_info, &image_index)

	if result == .ERROR_OUT_OF_DATE_KHR || result == .SUBOPTIMAL_KHR {
		destroy_swapchain()
		create_swapchain() or_return
		return false
	}

	return result == .SUCCESS
}

submit_commands :: proc(element: ^SwapchainElement, frame_index: u32) {
	old_value := element.last_value
	timeline_value += 1
	new_value := timeline_value

	wait_infos := [2]vk.SemaphoreSubmitInfo{}
	wait_count: u32 = 0

	if image_available_semaphore != {} {
		wait_infos[wait_count] = vk.SemaphoreSubmitInfo {
			sType     = vk.StructureType.SEMAPHORE_SUBMIT_INFO,
			semaphore = image_available_semaphore,
			value     = 0,
			stageMask = {vk.PipelineStageFlag2.COLOR_ATTACHMENT_OUTPUT},
		}
		wait_count += 1
	}

	if old_value != 0 {
		wait_infos[wait_count] = vk.SemaphoreSubmitInfo {
			sType     = vk.StructureType.SEMAPHORE_SUBMIT_INFO,
			semaphore = timeline_semaphore,
			value     = old_value,
			stageMask = {vk.PipelineStageFlag2.TOP_OF_PIPE},
		}
		wait_count += 1
	}

	wait_ptr: ^vk.SemaphoreSubmitInfo = nil
	if wait_count > 0 {
		wait_ptr = &wait_infos[0]
	}

	command_infos := [1]vk.CommandBufferSubmitInfo {
		{
			sType = vk.StructureType.COMMAND_BUFFER_SUBMIT_INFO,
			commandBuffer = element.commandBuffer,
			deviceMask = 1,
		},
	}

	signal_infos := [1]vk.SemaphoreSubmitInfo {
		{
			sType = vk.StructureType.SEMAPHORE_SUBMIT_INFO,
			semaphore = timeline_semaphore,
			value = new_value,
			stageMask = {vk.PipelineStageFlag2.ALL_GRAPHICS},
		},
	}

	submit_info := vk.SubmitInfo2 {
		sType                    = vk.StructureType.SUBMIT_INFO_2,
		waitSemaphoreInfoCount   = wait_count,
		pWaitSemaphoreInfos      = wait_ptr,
		commandBufferInfoCount   = 1,
		pCommandBufferInfos      = &command_infos[0],
		signalSemaphoreInfoCount = 1,
		pSignalSemaphoreInfos    = &signal_infos[0],
	}

	vk.QueueSubmit2(queue, 1, &submit_info, {})
	element.last_value = new_value
	frame_slot_values[frame_index] = new_value // 🔑 track per-frame slot too
}

present_frame :: proc(image_index: c.uint32_t) -> bool {
	element := &elements[image_index]

	index_copy := image_index

	present_info := vk.PresentInfoKHR {
		sType              = vk.StructureType.PRESENT_INFO_KHR,
		waitSemaphoreCount = 1,
		pWaitSemaphores    = &timeline_semaphore,
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

	// 4. Record rendering commands
	encoder, frame := begin_frame_commands(element, start_time)
	transition_swapchain_image_layout(frame.cmd, element, vk.ImageLayout.ATTACHMENT_OPTIMAL)
	record_commands(element, frame)
	transition_swapchain_image_layout(frame.cmd, element, vk.ImageLayout.PRESENT_SRC_KHR)
	vk.EndCommandBuffer(encoder.command_buffer)

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

		// Ensure outstanding GPU work is complete before rebuilding resources
		wait_for_timeline(timeline_value)

		// Destroy old offscreen image resource (handled by render cleanup)
		//		cleanup_render_resources()
		//		destroy_render_shader_state(render_shader_states[:])

		//	shaders_ready = false

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

vulkan_init :: proc() -> (ok: bool) {
	update_window_size()
	init_vulkan() or_return
	create_swapchain() or_return
	init_global_descriptors() or_return
	init_vulkan_resources() or_return
	return true
}

// Extension and layer names
get_instance_extensions :: proc() -> []cstring {
	// Get required extensions from GLFW
	glfw_extensions := glfw.GetRequiredInstanceExtensions()
	instance_extensions.len = 0
	extra_extensions := 0
	if ENABLE_VALIDATION do extra_extensions = 3
	runtime.assert(
		len(glfw_extensions) + extra_extensions <= len(instance_extensions.data),
		"instance extension buffer too small",
	)

	for ext in glfw_extensions {
		array_push(&instance_extensions, ext)
	}
	array_push(&instance_extensions, "VK_EXT_surface_maintenance1") // optional but useful
	if ENABLE_VALIDATION {
		array_push(&instance_extensions, "VK_EXT_debug_utils")
		array_push(&instance_extensions, "VK_EXT_validation_features") // optional but useful
	}

	return array_slice(&instance_extensions)
}
layer_names := [?]cstring{"VK_LAYER_KHRONOS_validation"}

// ──────────────────────────────────────────────────────────────
// Device extensions to reduce boilerplate & enable advanced features
// ──────────────────────────────────────────────────────────────


create_logical_device :: proc() -> bool {
	queue_priority: f32 = 1.0
	queue_info := vk.DeviceQueueCreateInfo {
		sType            = .DEVICE_QUEUE_CREATE_INFO,
		queueFamilyIndex = queue_family_index,
		queueCount       = 1,
		pQueuePriorities = &queue_priority,
	}

	// ───────────────────────────────
	// Vulkan 1.3 core + common extras
	// ───────────────────────────────

	shader_object := vk.PhysicalDeviceShaderObjectFeaturesEXT {
		sType        = .PHYSICAL_DEVICE_SHADER_OBJECT_FEATURES_EXT,
		shaderObject = true,
	}
	extended_dynamic := vk.PhysicalDeviceExtendedDynamicStateFeaturesEXT {
		sType                = .PHYSICAL_DEVICE_EXTENDED_DYNAMIC_STATE_FEATURES_EXT,
		extendedDynamicState = true,
	}
	vulkan12 := vk.PhysicalDeviceVulkan12Features {
		sType                  = vk.StructureType.PHYSICAL_DEVICE_VULKAN_1_2_FEATURES,
		pNext                  = &extended_dynamic,
		descriptorIndexing     = true,
		runtimeDescriptorArray = true,
		timelineSemaphore      = true,
	}
	sync2 := vk.PhysicalDeviceSynchronization2Features {
		sType            = vk.StructureType.PHYSICAL_DEVICE_SYNCHRONIZATION_2_FEATURES,
		pNext            = &vulkan12,
		synchronization2 = true,
	}
	dynamic_rendering := vk.PhysicalDeviceDynamicRenderingFeatures {
		sType            = vk.StructureType.PHYSICAL_DEVICE_DYNAMIC_RENDERING_FEATURES,
		pNext            = &sync2,
		dynamicRendering = true,
	}
	extended_dynamic.pNext = &shader_object

	features := vk.PhysicalDeviceFeatures2 {
		sType = .PHYSICAL_DEVICE_FEATURES_2,
		pNext = &dynamic_rendering,
		features = vk.PhysicalDeviceFeatures{fragmentStoresAndAtomics = true},
	}
	vk.GetPhysicalDeviceFeatures2(phys_device, &features)

	device_exts := [?]cstring {
		"VK_KHR_swapchain",
		"VK_KHR_timeline_semaphore",
		"VK_KHR_synchronization2", // core in 1.3, kept for safety
		"VK_KHR_dynamic_rendering", // core in 1.3, kept for safety
		"VK_EXT_descriptor_indexing", // core in 1.2+, safe everywhere
		"VK_EXT_extended_dynamic_state", // optional QoL
		"VK_EXT_shader_object", // optional modern path
	}

	device_info := vk.DeviceCreateInfo {
		sType                   = .DEVICE_CREATE_INFO,
		pNext                   = &features,
		queueCreateInfoCount    = 1,
		pQueueCreateInfos       = &queue_info,
		enabledExtensionCount   = u32(len(device_exts)),
		ppEnabledExtensionNames = raw_data(device_exts[:]),
		enabledLayerCount       = ENABLE_VALIDATION ? len(layer_names) : 0,
		ppEnabledLayerNames     = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
	}

	if vk.CreateDevice(phys_device, &device_info, nil, &device) != .SUCCESS {
		fmt.println("Failed to create device")
		return false
	}

	vk.GetDeviceQueue(device, queue_family_index, 0, &queue)
	return true
}

// ──────────────────────────────────────────────────────────────────────────────
// Shader registry (canonical: .hlsl)
// ──────────────────────────────────────────────────────────────────────────────

ShaderInfo :: struct {
	source_path:   string, // e.g. "sprite.hlsl"
	last_modified: time.Time,
}

shader_registry: map[string]ShaderInfo
shader_watch_initialized: bool
MAX_TRACKED_SHADERS :: 32

init_shader_times :: proc() {
	discover_shaders()
	shader_watch_initialized = true
}

discover_shaders :: proc() {
	// Recreate registry
	delete(shader_registry)
	shader_registry = map[string]ShaderInfo{}

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
			// Keep source name as-is; use .hlsl as canonical
			shader_registry[file.name] = ShaderInfo {
				source_path   = file.name,
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
// ──────────────────────────────────────────────────────────────────────────────
// Filename helpers
// ──────────────────────────────────────────────────────────────────────────────

// From a pipeline .spv output, get the canonical .hlsl source.
// Accepts: "foo.spv", "foo_vs.spv", "bar_fs.spv"

spv_to_hlsl :: proc(spv: string) -> string {
	if strings.has_suffix(spv, "_vs.spv") {
		return fmt.aprintf("%s.hlsl", strings.trim_suffix(spv, "_vs.spv"))
	}
	if strings.has_suffix(spv, "_fs.spv") {
		return fmt.aprintf("%s.hlsl", strings.trim_suffix(spv, "_fs.spv"))
	}
	if strings.has_suffix(spv, ".spv") {
		return fmt.aprintf("%s.hlsl", strings.trim_suffix(spv, ".spv"))
	}
	return spv // fallback
}

hlsl_outputs :: proc(hlsl: string) -> (is_compute: bool, out0, out1: string) {
	base := strings.trim_suffix(hlsl, ".hlsl")
	if strings.contains(hlsl, "compute") {
		return true, fmt.aprintf("%s.spv", base), ""
	}
	return false, fmt.aprintf("%s_vs.spv", base), fmt.aprintf("%s_fs.spv", base)
}


// ──────────────────────────────────────────────────────────────────────────────
compile_hlsl :: proc(hlsl_file, profile, entry, output: string) -> bool {

	cmd := fmt.aprintf(
		"dxc -spirv -fvk-use-gl-layout -fspv-target-env=vulkan1.3 -T %s -E %s -Fo %s %s",
		profile,
		entry,
		output,
		hlsl_file,
	)

	return system(strings.clone_to_cstring(cmd, context.temp_allocator)) == 0
}

compile_shader :: proc(hlsl_file: string) -> bool {

	fmt.println("compiling shader:", hlsl_file)
	is_compute, out0, out1 := hlsl_outputs(hlsl_file)
	if is_compute {
		return compile_hlsl(hlsl_file, "cs_6_0", "main", out0)
	}
	vs_ok := compile_hlsl(hlsl_file, "vs_6_0", "vs_main", out0)
	fs_ok := compile_hlsl(hlsl_file, "ps_6_0", "fs_main", out1)

	fmt.println(
		"compiled shader successfully! ignore previous compile errors for this file:",
		hlsl_file,
	)
	return vs_ok && fs_ok
}

// ──────────────────────────────────────────────────────────────────────────────
// Pipeline init: specs refer to compiled outputs; we map back to .hlsl and compile.
// ──────────────────────────────────────────────────────────────────────────────

prepare_render_shaders :: proc(configs: []ShaderProgramConfig) -> bool {
	for cfg in configs {
		if cfg.compute_module != "" do compile_shader(spv_to_hlsl(cfg.compute_module))
		if cfg.vertex_module != "" do compile_shader(spv_to_hlsl(cfg.vertex_module))
		if cfg.fragment_module != "" do compile_shader(spv_to_hlsl(cfg.fragment_module))
	}
	return true
}

// ──────────────────────────────────────────────────────────────────────────────
load_shader_spirv :: proc(path: string) -> ([]u32, bool) {
	data, ok := os.read_entire_file(path)
	if !ok || len(data) % 4 != 0 {
		return nil, false
	}
	defer delete(data)

	if len(data) > MAX_SPIRV_BYTES {
		fmt.printf("SPIR-V file too large for staging buffer: %s\n", path)
		return nil, false
	}

	word_count := len(data) / 4
	spirv_words.len = 0
	for i in 0 ..< word_count {
		idx := i * 4
		spirv_words.data[i] =
			u32(data[idx + 0]) |
			(u32(data[idx + 1]) << 8) |
			(u32(data[idx + 2]) << 16) |
			(u32(data[idx + 3]) << 24)
	}
	spirv_words.len = i32(word_count)

	// Optional: sanity check SPIR-V magic 0x07230203
	if word_count > 0 && spirv_words.data[0] != u32(0x07230203) {
		fmt.printf("WARN: %s does not look like SPIR-V (magic=%#x)\n", path, spirv_words.data[0])
	}
	return array_slice(&spirv_words), true
}

load_shader_code_words :: proc(path: string) -> ([]u32, bool) {
	// Try to compile matching .hlsl if it exists
	hlsl := spv_to_hlsl(path)
	if os.exists(hlsl) {
		if !compile_shader(hlsl) {
			fmt.printf("Shader compilation failed: %s\n", hlsl)
			//	return {}, false
		}
	}

	return load_shader_spirv(path)
}

load_shader_module :: proc(path: string) -> (shader: vk.ShaderModule, ok: bool) {
	code := load_shader_code_words(path) or_return
	return vkw(
		vk.CreateShaderModule,
		device,
		&vk.ShaderModuleCreateInfo {
			sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
			codeSize = len(code) * size_of(u32),
			pCode = raw_data(code),
		},
		"Failed to create shader module",
		vk.ShaderModule,
	)
}

// ──────────────────────────────────────────────────────────────────────────────
// Hot-reload: detect changed .hlsl, recompile, rebuild pipelines.
// ──────────────────────────────────────────────────────────────────────────────

compile_changed_shaders :: proc(changed_hlsl: []string) -> bool {
	ok_all := true
	for hlsl in changed_hlsl {
		info, present := shader_registry[hlsl]
		if !present {
			fmt.printf("Warning: %s not in registry\n", hlsl)
			continue
		}
		fmt.printf("Recompiling %s\n", info.source_path)
		if !compile_shader(info.source_path) {
			fmt.printf("Failed: %s\n", info.source_path)
			ok_all = false
		}
	}
	return ok_all
}

check_shader_reload :: proc() -> bool {
	if !shader_watch_initialized {
		init_shader_times()
		return false
	}

	changed := Array(MAX_TRACKED_SHADERS, string){}
	missing := Array(MAX_TRACKED_SHADERS, string){}

	// Pick up newly added shaders
	handle, err := os.open(".")
	assert(err == nil, "shader sync: failed to open cwd")
	defer os.close(handle)
	files, read_err := os.read_dir(handle, -1)
	assert(read_err == nil, "shader sync: failed to read cwd")
	defer delete(files)
	for file in files {
		if !strings.has_suffix(file.name, ".hlsl") {
			continue
		}
		_, present := shader_registry[file.name]
		if present {
			continue
		}
		shader_registry[file.name] = ShaderInfo {
			source_path   = file.name,
			last_modified = file.modification_time,
		}
		array_push(&changed, file.name)
	}

	for name, &info in shader_registry {
		st, err := os.stat(info.source_path)
		if err != nil {
			// File missing → drop it from registry
			fmt.printf("Shader source missing: %s\n", info.source_path)
			array_push(&missing, name)
			continue
		}

		if st.modification_time != info.last_modified {
			info.last_modified = st.modification_time
			array_push(&changed, name)
		}
	}

	if changed.len == 0 && missing.len == 0 {
		return shaders_ready
	}

	if changed.len > 0 {
		if !compile_changed_shaders(array_slice(&changed)) {
			return shaders_ready // keep old shaders if rebuild fails
		}
	}

	for i in 0 ..< missing.len {
		name := missing.data[i]
		delete_key(&shader_registry, name)
	}

	// Full rebuild
	vk.QueueWaitIdle(queue)
	destroy_render_shader_state(render_shader_states[:])

	if !prepare_render_shaders(render_shader_configs[:]) {
		fmt.println("Shader reload failed during init")
		return false
	}

	if !build_shader_programs(render_shader_configs[:], render_shader_states[:]) {
		fmt.println("Shader reload failed during program build")
		return false
	}

	return shaders_ready
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


create_swapchain :: proc() -> bool {
	caps: vk.SurfaceCapabilitiesKHR
	if vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &caps) != .SUCCESS {
		return false
	}

	// Prefer SRGB format
	count: u32
	vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &count, nil)
	if count == 0 do return false
	surface_cap := u32(len(surface_formats.data))
	if count > surface_cap {
		count = surface_cap
	}
	formats_ptr := raw_data(surface_formats.data[:])
	if vk.GetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &count, formats_ptr) !=
	   .SUCCESS {
		return false
	}
	surface_formats.len = i32(count)
	format = surface_formats.data[0].format
	for i in 0 ..< int(count) {
		fmt := surface_formats.data[i]
		if fmt.format == vk.Format.B8G8R8A8_SRGB {
			format = fmt.format
			break
		}
	}

	desired := min(
		caps.minImageCount + 1,
		caps.maxImageCount > 0 ? caps.maxImageCount : caps.minImageCount + 1,
	)

	sc_info := vk.SwapchainCreateInfoKHR {
		sType            = .SWAPCHAIN_CREATE_INFO_KHR,
		surface          = vulkan_surface,
		minImageCount    = desired,
		imageFormat      = format,
		imageColorSpace  = vk.ColorSpaceKHR.SRGB_NONLINEAR,
		imageExtent      = {width, height},
		imageArrayLayers = 1,
		imageUsage       = {.COLOR_ATTACHMENT},
		presentMode      = .IMMEDIATE,
		preTransform     = caps.currentTransform,
		compositeAlpha   = {.OPAQUE},
		clipped          = true,
	}
	if vk.CreateSwapchainKHR(device, &sc_info, nil, &swapchain) != .SUCCESS do return false

	// Fetch images and make simple views / cmd buffers
	vk.GetSwapchainImagesKHR(device, swapchain, &image_count, nil)
	if image_count == 0 {
		return false
	}
	if image_count > MAX_SWAPCHAIN_IMAGES {
		image_count = MAX_SWAPCHAIN_IMAGES
	}
	image_ptr := raw_data(swapchain_image_handles[:])
	if vk.GetSwapchainImagesKHR(device, swapchain, &image_count, image_ptr) != .SUCCESS {
		return false
	}
	for i in 0 ..< int(image_count) {
		elements[i].image = swapchain_image_handles[i]
		vk.CreateImageView(
			device,
			&vk.ImageViewCreateInfo {
				sType = .IMAGE_VIEW_CREATE_INFO,
				image = swapchain_image_handles[i],
				viewType = .D2,
				format = format,
				subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
			},
			nil,
			&elements[i].imageView,
		)
		vk.AllocateCommandBuffers(
			device,
			&vk.CommandBufferAllocateInfo {
				sType = .COMMAND_BUFFER_ALLOCATE_INFO,
				commandPool = command_pool,
				level = .PRIMARY,
				commandBufferCount = 1,
			},
			&elements[i].commandBuffer,
		)
		elements[i].layout = vk.ImageLayout.UNDEFINED
	}

	frames_in_flight = max(1, min(image_count, MAX_FRAMES_IN_FLIGHT))
	current_frame = 0
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT do frame_slot_values[i] = 0
	return true
}

init_vulkan :: proc() -> bool {
	// Load global function pointers (this uses the loader already provided by the system)
	vk.load_proc_addresses_global(rawptr(glfw.GetInstanceProcAddress))

	// --- Create instance ---
	instance_extensions := get_instance_extensions()

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

	binary_info := vk.SemaphoreCreateInfo {
		sType = vk.StructureType.SEMAPHORE_CREATE_INFO,
	}
	if vk.CreateSemaphore(device, &binary_info, nil, &image_available_semaphore) !=
	   vk.Result.SUCCESS {
		vk.DestroySemaphore(device, timeline_semaphore, nil)
		timeline_semaphore = {}
		fmt.println("Failed to create image-available semaphore")
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
	device_count: u32
	if vk.EnumeratePhysicalDevices(instance, &device_count, nil) != .SUCCESS || device_count == 0 {
		fmt.println("No physical devices found")
		return false
	}

	capacity := u32(len(physical_devices.data))
	if device_count > capacity {
		device_count = capacity
	}

	device_ptr := raw_data(physical_devices.data[:])
	if vk.EnumeratePhysicalDevices(instance, &device_count, device_ptr) != .SUCCESS {
		fmt.println("Failed to enumerate physical devices")
		return false
	}

	physical_devices.len = i32(device_count)
	phys_device = physical_devices.data[0]

	queue_family_count: u32
	vk.GetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, nil)
	if queue_family_count == 0 {
		fmt.println("No queue families found")
		return false
	}
	queue_cap := u32(len(queue_families.data))
	if queue_family_count > queue_cap {
		queue_family_count = queue_cap
	}

	queue_ptr := raw_data(queue_families.data[:])
	vk.GetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, queue_ptr)
	queue_families.len = i32(queue_family_count)

	for idx in 0 ..< int(queue_family_count) {
		qf := queue_families.data[idx]
		present_support: b32
		if vk.GetPhysicalDeviceSurfaceSupportKHR(
			   phys_device,
			   u32(idx),
			   vulkan_surface,
			   &present_support,
		   ) ==
			   .SUCCESS &&
		   present_support &&
		   vk.QueueFlag.GRAPHICS in qf.queueFlags {
			queue_family_index = u32(idx)
			return true
		}
	}

	fmt.println("No suitable queue family found")
	return false
}

init_vulkan_resources :: proc() -> bool {

	if width == 0 || height == 0 {
		runtime.assert(false, "width and height must be greater than 0")
		shaders_ready = false
		return false
	}

	init_render_resources()

	if !prepare_render_shaders(render_shader_configs[:]) {
		fmt.println("Render shader preparation failed")
		return false
	}
	if !build_shader_programs(render_shader_configs[:], render_shader_states[:]) {
		fmt.println("Render shaders failed to initialize")
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
compute_barrier :: proc(cmd: vk.CommandBuffer) {
	barrier := vk.MemoryBarrier2 {
		sType         = .MEMORY_BARRIER_2,
		srcStageMask  = {vk.PipelineStageFlag2.COMPUTE_SHADER},
		srcAccessMask = {vk.AccessFlag2.SHADER_READ, vk.AccessFlag2.SHADER_WRITE},
		dstStageMask  = {vk.PipelineStageFlag2.COMPUTE_SHADER},
		dstAccessMask = {vk.AccessFlag2.SHADER_READ, vk.AccessFlag2.SHADER_WRITE},
	}
	dependency := vk.DependencyInfo {
		sType              = .DEPENDENCY_INFO,
		memoryBarrierCount = 1,
		pMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency)
}


transfer_to_compute_barrier :: proc(cmd: vk.CommandBuffer, buf: ^BufferResource) {
	runtime.assert(
		buf.buffer != {},
		"transfer/computation barrier requested before initialization",
	)

	barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {vk.PipelineStageFlag2.TRANSFER},
		srcAccessMask = {vk.AccessFlag2.TRANSFER_WRITE},
		dstStageMask  = {vk.PipelineStageFlag2.COMPUTE_SHADER},
		dstAccessMask = {vk.AccessFlag2.SHADER_READ, vk.AccessFlag2.SHADER_WRITE},
		buffer        = buf.buffer,
		offset        = 0,
		size          = buf.size,
	}
	dependency := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dependency)
}


apply_compute_to_fragment_barrier :: proc(cmd: vk.CommandBuffer, buf: ^BufferResource) {
	runtime.assert(buf.buffer != {}, "compute barrier requested before initialization")

	barrier := vk.BufferMemoryBarrier2 {
		sType         = .BUFFER_MEMORY_BARRIER_2,
		srcStageMask  = {.COMPUTE_SHADER},
		srcAccessMask = {.SHADER_WRITE},
		dstStageMask  = {.FRAGMENT_SHADER},
		dstAccessMask = {.SHADER_READ},
		buffer        = buf.buffer,
		offset        = 0,
		size          = buf.size,
	}
	dep := vk.DependencyInfo {
		sType                    = .DEPENDENCY_INFO,
		bufferMemoryBarrierCount = 1,
		pBufferMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(cmd, &dep)
}

transition_swapchain_image_layout :: proc(
	cmd: vk.CommandBuffer,
	element: ^SwapchainElement,
	new_layout: vk.ImageLayout,
) {
	runtime.assert(element.image != {}, "swapchain image missing before layout transition")

	old_layout := element.layout
	if old_layout == new_layout {
		return
	}

	barrier_needed := false
	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		oldLayout = old_layout,
		newLayout = new_layout,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = element.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}

	#partial switch new_layout {
	case vk.ImageLayout.ATTACHMENT_OPTIMAL:
		barrier.dstStageMask = {vk.PipelineStageFlag2.COLOR_ATTACHMENT_OUTPUT}
		barrier.dstAccessMask = {vk.AccessFlag2.COLOR_ATTACHMENT_WRITE}
		barrier_needed = true
	case vk.ImageLayout.PRESENT_SRC_KHR:
		barrier.srcStageMask = {vk.PipelineStageFlag2.COLOR_ATTACHMENT_OUTPUT}
		barrier.srcAccessMask = {vk.AccessFlag2.COLOR_ATTACHMENT_WRITE}
		barrier_needed = true
	}

	if barrier_needed {
		dependency := vk.DependencyInfo {
			sType                   = .DEPENDENCY_INFO,
			imageMemoryBarrierCount = 1,
			pImageMemoryBarriers    = &barrier,
		}

		vk.CmdPipelineBarrier2(cmd, &dependency)
	}

	element.layout = new_layout
}


destroy_all_sync_objects :: proc() {
	if image_available_semaphore != {} {
		vk.DestroySemaphore(device, image_available_semaphore, nil)
		image_available_semaphore = {}
	}
	// Timeline semaphore
	if timeline_semaphore != {} {
		vk.DestroySemaphore(device, timeline_semaphore, nil)
		timeline_semaphore = {}
	}
}
destroy_swapchain :: proc() {
	for i in 0 ..< MAX_SWAPCHAIN_IMAGES {
		if elements[i].imageView != {} do vk.DestroyImageView(device, elements[i].imageView, nil)
		if elements[i].commandBuffer != {} do vk.ResetCommandBuffer(elements[i].commandBuffer, {})

		elements[i] = SwapchainElement{}
	}

	image_count = 0
	frames_in_flight = 0
	current_frame = 0
	for i in 0 ..< MAX_FRAMES_IN_FLIGHT {
		frame_slot_values[i] = 0
	}

	if swapchain != {} do vk.DestroySwapchainKHR(device, swapchain, nil)
	swapchain = {}
}

vulkan_cleanup :: proc() {

	vk.DeviceWaitIdle(device)
	// Swapchain
	destroy_swapchain()
	destroy_all_sync_objects()

	// Buffers, textures
	cleanup_render_resources()
	// Pipelines + layouts
	destroy_render_shader_state(render_shader_states[:])
	// Descriptor pool & layout
	if global_desc_pool != {} do vk.DestroyDescriptorPool(device, global_desc_pool, nil)
	if global_desc_layout != {} do vk.DestroyDescriptorSetLayout(device, global_desc_layout, nil)

	// Command pool
	if command_pool != {} do vk.DestroyCommandPool(device, command_pool, nil)

	// Device & instance
	vk.DestroyDevice(device, nil)
	vk.DestroySurfaceKHR(instance, vulkan_surface, nil)

	if ENABLE_VALIDATION {
		vkDestroyDebugUtilsMessengerEXT := cast(proc "c" (
			_: vk.Instance,
			_: vk.DebugUtilsMessengerEXT,
			_: rawptr,
		))vk.GetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")
		if vkDestroyDebugUtilsMessengerEXT != nil {
			vkDestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
		}
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

	// --- Image
	ci := vk.ImageCreateInfo {
		sType         = .IMAGE_CREATE_INFO,
		imageType     = .D2,
		format        = .R8G8B8A8_UNORM,
		extent        = {u32(img.width), u32(img.height), 1},
		mipLevels     = 1,
		arrayLayers   = 1,
		samples       = {._1},
		tiling        = .LINEAR,
		usage         = {.SAMPLED},
		sharingMode   = .EXCLUSIVE,
		initialLayout = .PREINITIALIZED,
	}
	tex.image, _ = vkw(vk.CreateImage, device, &ci, "texture image", vk.Image)

	mem_req: vk.MemoryRequirements
	vk.GetImageMemoryRequirements(device, tex.image, &mem_req)

	alloc := vk.MemoryAllocateInfo {
		sType           = .MEMORY_ALLOCATE_INFO,
		allocationSize  = mem_req.size,
		memoryTypeIndex = find_memory_type(
			mem_req.memoryTypeBits,
			{.HOST_VISIBLE, .HOST_COHERENT},
		),
	}
	vk.AllocateMemory(device, &alloc, nil, &tex.memory)
	vk.BindImageMemory(device, tex.image, tex.memory, 0)

	// --- Copy pixels
	data: rawptr
	vk.MapMemory(device, tex.memory, 0, mem_req.size, {}, &data)
	runtime.mem_copy_non_overlapping(data, raw_data(src), required)
	vk.UnmapMemory(device, tex.memory)

	// --- Transition to shader-read layout before sampling
	transition_cmd: vk.CommandBuffer
	alloc_info := vk.CommandBufferAllocateInfo {
		sType              = .COMMAND_BUFFER_ALLOCATE_INFO,
		commandPool        = command_pool,
		level              = .PRIMARY,
		commandBufferCount = 1,
	}
	if vk.AllocateCommandBuffers(device, &alloc_info, &transition_cmd) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate command buffer for texture transition")
		destroy_texture(&tex)
		return tex, false
	}

	begin_info := vk.CommandBufferBeginInfo {
		sType = .COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(transition_cmd, &begin_info)

	barrier := vk.ImageMemoryBarrier2 {
		sType = .IMAGE_MEMORY_BARRIER_2,
		srcStageMask = {vk.PipelineStageFlag2.HOST},
		srcAccessMask = {vk.AccessFlag2.HOST_WRITE},
		dstStageMask = {vk.PipelineStageFlag2.FRAGMENT_SHADER},
		dstAccessMask = {vk.AccessFlag2.SHADER_READ},
		oldLayout = vk.ImageLayout.PREINITIALIZED,
		newLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		image = tex.image,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	dependency := vk.DependencyInfo {
		sType                   = .DEPENDENCY_INFO,
		imageMemoryBarrierCount = 1,
		pImageMemoryBarriers    = &barrier,
	}
	vk.CmdPipelineBarrier2(transition_cmd, &dependency)
	vk.EndCommandBuffer(transition_cmd)

	cmd_submit := vk.CommandBufferSubmitInfo {
		sType         = vk.StructureType.COMMAND_BUFFER_SUBMIT_INFO,
		commandBuffer = transition_cmd,
		deviceMask    = 1,
	}
	submit_info := vk.SubmitInfo2 {
		sType                  = vk.StructureType.SUBMIT_INFO_2,
		commandBufferInfoCount = 1,
		pCommandBufferInfos    = &cmd_submit,
	}
	vk.QueueSubmit2(queue, 1, &submit_info, {})
	vk.QueueWaitIdle(queue)
	vk.FreeCommandBuffers(device, command_pool, 1, &transition_cmd)

	tex.layout = .SHADER_READ_ONLY_OPTIMAL

	// --- View
	vi := vk.ImageViewCreateInfo {
		sType = .IMAGE_VIEW_CREATE_INFO,
		image = tex.image,
		viewType = .D2,
		format = .R8G8B8A8_UNORM,
		subresourceRange = {aspectMask = {.COLOR}, levelCount = 1, layerCount = 1},
	}
	tex.view, _ = vkw(vk.CreateImageView, device, &vi, "texture view", vk.ImageView)

	// --- Sampler
	si := vk.SamplerCreateInfo {
		sType        = .SAMPLER_CREATE_INFO,
		magFilter    = .LINEAR,
		minFilter    = .LINEAR,
		addressModeU = .CLAMP_TO_EDGE,
		addressModeV = .CLAMP_TO_EDGE,
		addressModeW = .CLAMP_TO_EDGE,
	}
	tex.sampler, _ = vkw(vk.CreateSampler, device, &si, "sampler", vk.Sampler)

	tex.width = u32(img.width)
	tex.height = u32(img.height)
	tex.format = .R8G8B8A8_UNORM
	return tex, true
}


foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}
