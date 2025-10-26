package main

import "core:os"
import "core:time"

start_time: time.Time

main :: proc() {
	for arg in os.args[1:] {
		if arg == "-release" do ENABLE_VALIDATION = false
	}

	start_time = time.now()

	if !init_platform() do return
	defer platform_cleanup()

	if !vulkan_init() do return
	defer vulkan_cleanup()

	platform_run()
}
