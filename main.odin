package main

import "core:os"
import "core:time"
import "vendor:glfw"

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}

	start_time := time.now()

	if !init_platform() do return
	defer glfw_cleanup()

	if !vulkan_init() do return
	defer vulkan_cleanup()


	for glfw_should_quit() == 0 {
		glfw_poll_events()
		handle_resize()
		check_shader_reload()
		render_frame(start_time)
	}
}
