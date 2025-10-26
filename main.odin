package main

import "core:os"
import "core:time"
import platform "wayland"
import backend "vulkan_backend"


init :: proc(
) -> (
	[]backend.BufferSpec,
	[]backend.DescriptorBindingSpec,
	[]backend.ShaderProgramConfig,
) {

	backend.record_commands = record_commands
	backend.resize = resize
	return buffer_specs, global_descriptor_extras, render_shader_configs
}

main :: proc() {
	//using backend

	if !platform.init() do return
	defer platform.cleanup()

	if !backend.init(init()) do return
	defer backend.cleanup()

	platform.run()

}
