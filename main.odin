package main

import "core:time"
import "core:os"
import "core:fmt"
import "vendor:glfw"

main :: proc() {
	// Handle command line arguments
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}

	start_time := time.now()

	// Initialize platform (GLFW)
	if !init_platform() do return
	defer glfw_cleanup()

	// Initialize Vulkan system (this will create the actual resources)
	if !vulkan_init() do return
	defer vulkan_cleanup()

	// Initialize shader hot reload
	init_shader_times()

	// Main render loop
	for glfw_should_quit() == 0 {
		glfw_poll_events()

		// Handle window resize
		handle_resize()

		// Hot reload shaders if changed
		check_shader_reload()

		// Handle input
		handle_input()

		// Only render when window is visible
		if glfw_window_visible() != 0 {
			// Reset descriptor pool each frame to prevent exhaustion
			reset_descriptor_pool()
			render_frame(start_time)
		} else {
			// Sleep when window is hidden to avoid busy waiting
			time.sleep(16 * time.Millisecond) // ~60 FPS equivalent
		}
	}
}

// Handle keyboard and mouse input
handle_input :: proc() {
	// Example input handling - modify as needed
	if is_key_pressed(glfw.KEY_W) {
		fmt.println("W key is pressed")
	}
	if is_key_pressed(glfw.KEY_A) {
		fmt.println("A key is pressed")
	}
	if is_key_pressed(glfw.KEY_S) {
		fmt.println("S key is pressed")  
	}
	if is_key_pressed(glfw.KEY_D) {
		fmt.println("D key is pressed")
	}
	
	if is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT) {
		mouse_x, mouse_y := get_mouse_position()
		fmt.printf("Left mouse button pressed at (%.2f, %.2f)\n", mouse_x, mouse_y)
	}
	
	scroll_x, scroll_y := get_scroll_delta()
	if scroll_x != 0 || scroll_y != 0 {
		fmt.printf("Scroll delta: (%.2f, %.2f)\n", scroll_x, scroll_y)
	}
}
