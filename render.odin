package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"
import vk "vendor:vulkan"

PARTICLE_COUNT :: 1000000

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	compute_push := ComputePushConstants{time = elapsed_time, particle_count = PARTICLE_COUNT}
	post_push := PostProcessPushConstants{time = elapsed_time, intensity = 1.0}
	clear_value := vk.ClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}}

	encode_passes(&encoder,
		compute_pass("compute.wgsl", {u32((PARTICLE_COUNT + 63) / 64), 1, 1}, 
			{descriptor_set}, &compute_push, size_of(ComputePushConstants)),

		graphics_pass("vertex.wgsl", "fragment.wgsl", offscreen_render_pass, offscreen_framebuffer,
			6, PARTICLE_COUNT, {descriptor_set}, clear_values = {clear_value}),

		graphics_pass("post_process.wgsl", "post_process.wgsl", render_pass, element.framebuffer,
			3, 1, {post_process_descriptor_set}, &post_push, size_of(PostProcessPushConstants),
			{vk.ShaderStageFlag.FRAGMENT}, {clear_value}),
	)

	finish_encoding(&encoder)
}


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

recreate_graphics_pipeline :: proc() -> bool {
	vk.DeviceWaitIdle(device)
	vk.DestroyPipeline(device, graphics_pipeline, nil)
	vk.DestroyPipelineLayout(device, pipeline_layout, nil)
	return create_graphics_pipeline()
}

