package main

import "core:os"
import "core:time"
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
		handle_resize()
		check_shader_reload()
		render_frame(start_time)
	}
}
