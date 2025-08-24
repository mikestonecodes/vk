package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

foreign import libc "system:c"
foreign libc {
	system :: proc(command: cstring) -> c.int ---
}

// Global Wayland objects
display: wl_display
surface: wl_surface

// Shader hot reload
last_vertex_time: time.Time
last_fragment_time: time.Time

main :: proc() {
	// Check for validation flag
	for arg in os.args[1:] {
		if arg == "-validation" {
			ENABLE_VALIDATION = true
		}
	}

	start_time := time.now()

	// Initialize platform
	if !init_platform() {
		return
	}
	defer wayland_cleanup()

	// Initialize Vulkan
	if !init_vulkan() {
		return
	}


	// Initialize shader file modification times
	if vertex_info, err := os.stat("vertex.wgsl"); err == nil {
		last_vertex_time = vertex_info.modification_time
	}
	if fragment_info, err := os.stat("fragment.wgsl"); err == nil {
		last_fragment_time = fragment_info.modification_time
	}
	defer {
		vkDestroyCommandPool(device, command_pool, nil)
		vkDestroyDevice(device, nil)
		vkDestroySurfaceKHR(instance, vulkan_surface, nil)
		if ENABLE_VALIDATION {
			vkDestroyDebugUtilsMessengerEXT := cast(proc "c" (
				instance: VkInstance,
				debug_messenger: VkDebugUtilsMessengerEXT,
				allocator: rawptr,
			))vkGetInstanceProcAddr(instance, "vkDestroyDebugUtilsMessengerEXT")
			if vkDestroyDebugUtilsMessengerEXT != nil do vkDestroyDebugUtilsMessengerEXT(instance, debug_messenger, nil)
		}
		vkDestroyInstance(instance, nil)
	}

	create_swapchain()
	defer destroy_swapchain()

	fmt.println("Creating graphics pipeline...")
	if !create_graphics_pipeline() {
		fmt.println("Failed to create graphics pipeline")
		return
	}
	fmt.println("Graphics pipeline created successfully")
	defer {
		vkDestroyPipeline(device, graphics_pipeline, nil)
		vkDestroyPipelineLayout(device, pipeline_layout, nil)
	}

	// Main loop
	result: VkResult
	for wayland_should_quit() == 0 {
		wayland_poll_events()

		// Check for shader hot reload
		if check_shader_reload() {
			// Simple system call approach - will use external process to recompile
			// For now, just recreate pipeline assuming shaders are already recompiled
			if !recreate_graphics_pipeline() {
				fmt.println("Failed to recreate graphics pipeline")
				break
			}
		}

		current_element := &elements[current_frame]

		result = vkAcquireNextImageKHR(
			device,
			swapchain,
			UINT64_MAX,
			current_element.startSemaphore,
			VK_NULL_HANDLE,
			&image_index,
		)

		if result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR {
			vkDeviceWaitIdle(device)
			destroy_swapchain()
			create_swapchain()
			continue
		} else if result != VK_SUCCESS {
			fmt.printf("Failed to acquire image: %d\n", result)
			break
		}

		element := &elements[image_index]

		// Wait for previous frame if needed, then reset fence
		if element.lastFence != VK_NULL_HANDLE {
			vkWaitForFences(device, 1, &element.lastFence, VK_TRUE, UINT64_MAX)
		}
		vkResetFences(device, 1, &element.fence)
		element.lastFence = element.fence

		begin_info := VkCommandBufferBeginInfo {
			sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
			flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
		}

		// Reset command buffer first
		vkResetCommandBuffer(element.commandBuffer, 0)
		result = vkBeginCommandBuffer(element.commandBuffer, &begin_info)
		if result != VK_SUCCESS {
			fmt.printf("Failed to begin command buffer: %d\n", result)
			break
		}

		clear_value := VkClearValue {
			color = {float32 = {0.0, 0.0, 0.0, 1.0}},
		}

		render_pass_begin := VkRenderPassBeginInfo {
			sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
			renderPass = render_pass,
			framebuffer = element.framebuffer,
			renderArea = {offset = {0, 0}, extent = {width, height}},
			clearValueCount = 1,
			pClearValues = &clear_value,
		}

		vkCmdBeginRenderPass(element.commandBuffer, &render_pass_begin, VK_SUBPASS_CONTENTS_INLINE)
		vkCmdBindPipeline(
			element.commandBuffer,
			VK_PIPELINE_BIND_POINT_GRAPHICS,
			graphics_pipeline,
		)

		// Push time constant for rotation
		elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))
		vkCmdPushConstants(
			element.commandBuffer,
			pipeline_layout,
			VK_SHADER_STAGE_VERTEX_BIT,
			0,
			size_of(f32),
			&elapsed_time,
		)

		vkCmdDraw(element.commandBuffer, 3, 1, 0, 0)
		vkCmdEndRenderPass(element.commandBuffer)

		result = vkEndCommandBuffer(element.commandBuffer)
		if result != VK_SUCCESS {
			fmt.printf("Failed to end command buffer: %d\n", result)
			break
		}

		wait_stage: c.uint32_t = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
		submit_info := VkSubmitInfo {
			sType              = VK_STRUCTURE_TYPE_SUBMIT_INFO,
			waitSemaphoreCount = 1,
			pWaitSemaphores    = &current_element.startSemaphore,
			pWaitDstStageMask  = &wait_stage,
			commandBufferCount = 1,
			pCommandBuffers    = &element.commandBuffer,
		}

		result = vkQueueSubmit(queue, 1, &submit_info, element.fence)
		if result != VK_SUCCESS {
			fmt.printf("Failed to submit queue: %d\n", result)
			break
		}

		// Wait for render to finish before presenting
		vkWaitForFences(device, 1, &element.fence, VK_TRUE, UINT64_MAX)

		present_info := VkPresentInfoKHR {
			sType          = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
			swapchainCount = 1,
			pSwapchains    = &swapchain,
			pImageIndices  = &image_index,
		}

		result = vkQueuePresentKHR(queue, &present_info)
		if result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR {
			vkDeviceWaitIdle(device)
			destroy_swapchain()
			create_swapchain()
		} else if result != VK_SUCCESS {
			fmt.printf("Failed to present: %d\n", result)
			break
		}

		current_frame = (current_frame + 1) % image_count
	}

	vkDeviceWaitIdle(device)
}

check_shader_reload :: proc() -> bool {
	vertex_info, vertex_err := os.stat("vertex.wgsl")
	fragment_info, fragment_err := os.stat("fragment.wgsl")

	if vertex_err != nil || fragment_err != nil {
		return false
	}

	vertex_changed := vertex_info.modification_time != last_vertex_time
	fragment_changed := fragment_info.modification_time != last_fragment_time

	if vertex_changed || fragment_changed {
		last_vertex_time = vertex_info.modification_time
		last_fragment_time = fragment_info.modification_time

		fmt.println("Shader files changed, recompiling...")
		
		// Compile shaders using naga
		success := true
		
		if vertex_changed {
			fmt.println("Compiling vertex shader...")
			vertex_cmd := strings.clone_to_cstring("./naga vertex.wgsl vertex.spv")
			vertex_result := system(vertex_cmd)
			delete(vertex_cmd)
			if vertex_result != 0 {
				fmt.println("Failed to compile vertex shader")
				success = false
			}
		}
		
		if fragment_changed {
			fmt.println("Compiling fragment shader...")
			fragment_cmd := strings.clone_to_cstring("./naga fragment.wgsl fragment.spv")
			fragment_result := system(fragment_cmd)
			delete(fragment_cmd)
			if fragment_result != 0 {
				fmt.println("Failed to compile fragment shader")
				success = false
			}
		}
		
		if success {
			fmt.println("Shaders compiled successfully!")
		}
		
		return success
	}

	return false
}
