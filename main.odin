package main

import "core:os"
import "core:time"
import platform "wayland"
import backend "vulkan_backend"


main :: proc() {

	backend.record_commands = record_commands
	backend.resize = resize

	if !platform.init() do return
	defer platform.cleanup()

	if !backend.init(init()) do return
	defer backend.cleanup()

	platform.run()
}
