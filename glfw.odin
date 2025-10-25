package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "vendor:glfw"

// Global window state
window: glfw.WindowHandle
window_width: u32 = 800
window_height: u32 = 600
resize_needed: bool = false
should_quit_key: bool = false

// Input state
key_states: [512]bool
mouse_states: [8]bool
mouse_x, mouse_y: f64
scroll_x, scroll_y: f64

// Callback implementations
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key >= 0 && key < len(key_states) {
		key_states[key] = (action == glfw.PRESS || action == glfw.REPEAT)
	}
}

mouse_button_callback :: proc "c" (window: glfw.WindowHandle, button, action, mods: i32) {
	if button >= 0 && button < len(mouse_states) {
		mouse_states[button] = (action == glfw.PRESS)
	}
}

cursor_pos_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	mouse_x = xpos
	mouse_y = ypos
}

scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	scroll_x += xoffset
	scroll_y += yoffset
}

window_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()
	window_width = u32(width)
	window_height = u32(height)
	fmt.printf("Window resized to %dx%d\n", width, height)
	resize_needed = true
}

// Platform interface implementation
init_platform :: proc() -> bool {
	fmt.println("DEBUG: Initializing GLFW platform")

	if !glfw.Init() {
		fmt.println("Failed to initialize GLFW")
		return false
	}

	// Don't create an OpenGL context
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.SwapInterval(0)

	window = glfw.CreateWindow(i32(window_width), i32(window_height), "Vulkan with GLFW", nil, nil)
	if window == nil {
		fmt.println("Failed to create GLFW window")
		glfw.Terminate()
		return false
	}

	// Set up callbacks
	glfw.SetWindowSizeCallback(window, window_size_callback)
	glfw.SetKeyCallback(window, key_callback)
	glfw.SetMouseButtonCallback(window, mouse_button_callback)
	glfw.SetCursorPosCallback(window, cursor_pos_callback)
	glfw.SetScrollCallback(window, scroll_callback)

	fmt.println("DEBUG: GLFW platform setup complete")
	return true
}

platform_cleanup :: proc() {
	fmt.println("Cleaning up GLFW...")
	glfw.DestroyWindow(window)
	glfw.Terminate()
}

should_quit :: proc() -> bool {
	return bool(glfw.WindowShouldClose(window))
}

poll_events :: proc() {
	glfw.PollEvents()
}

init_window :: proc() {
	glfw.CreateWindowSurface(instance, window, nil, &vulkan_surface)
}

is_key_pressed :: proc(key: i32) -> bool {
	return key_states[key]
}
is_mouse_button_pressed :: proc(button: i32) -> bool {
	return mouse_states[button]
}

