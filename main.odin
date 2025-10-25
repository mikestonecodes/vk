package main

import "core:os"
import "core:time"

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}

	start_time := time.now()

	if !init_platform() do return
	defer platform_cleanup()

	if !vulkan_init() do return
	defer vulkan_cleanup()


	for should_quit() == false {
		check_shader_reload()
		render_frame(start_time)
		poll_events()
	}
}
