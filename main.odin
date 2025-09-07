package main

import "core:time"
import "core:os"

// Global state
display: wl_display
surface: wl_surface

main :: proc() {
	// Handle command line arguments
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}

	start_time := time.now()

	// Initialize platform (wayland)
	if !init_platform() do return
	defer wayland_cleanup()

	// Initialize Vulkan system (this will create the actual resources)
	if !vulkan_init() do return
	defer vulkan_cleanup()

	// Initialize shader hot reload
	init_shader_times()

	// Main render loop
	for wayland_should_quit() == 0 {
		wayland_poll_events()

		// Handle window resize
		handle_resize()

		// Hot reload shaders if changed
		check_shader_reload()

		// Only render when window is visible
		if wayland_window_visible() != 0 {
			// Reset descriptor pool each frame to prevent exhaustion
			reset_descriptor_pool()
			render_frame(start_time)
		} else {
			// Sleep when window is hidden to avoid busy waiting
			time.sleep(16 * time.Millisecond) // ~60 FPS equivalent
		}
	}
}
