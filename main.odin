package main

import "core:time"
import "core:os"

// Global state 
display: wl_display
surface: wl_surface

main :: proc() {
	// Handle command line arguments
	for arg in os.args[1:] {
		if arg == "-validation" do ENABLE_VALIDATION = true
	}

	start_time := time.now()

	// Initialize platform (wayland)
	if !init_platform() do return
	defer wayland_cleanup()

	// Initialize Vulkan system
	if !vulkan_init() do return
	defer vulkan_cleanup()

	// Initialize shader hot reload
	init_shader_times()

	// Main render loop
	for wayland_should_quit() == 0 {
		wayland_poll_events()
		
		// Hot reload shaders if changed
		if check_shader_reload() do recreate_pipeline()
		
		// Render frame
		render_frame(start_time)
	}
}