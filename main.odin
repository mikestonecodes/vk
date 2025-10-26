package main

import "core:os"
import "core:time"
import platform "wayland"

start_time: time.Time

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}


	if !platform.init() do return
	defer platform.cleanup()

	if !vulkan_init() do return
	defer vulkan_cleanup()

	platform.run()
}
