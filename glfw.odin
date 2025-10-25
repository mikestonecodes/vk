package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "vendor:glfw"

// Global window state
window: glfw.WindowHandle
window_width: u32 = 1
window_height: u32 = 1
should_quit_key: bool = false

// Input state
key_states: [512]bool
mouse_states: [8]bool
mouse_x, mouse_y: f64

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


window_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()

	fb_width, fb_height := glfw.GetFramebufferSize(window)
	fmt.println("Framebuffer size:", fb_width, "x", fb_height)
	// Use window size, not framebuffer size
	window_width = u32(width)
	window_height = u32(height)

	fmt.println("Window size:", width, "x", height)
	handle_resize()
}

error_callback :: proc "c" (error_code: i32, description: cstring) {
}

// Platform interface implementation
init_platform :: proc() -> bool {
	fmt.println("DEBUG: Initializing GLFW platform")

	glfw.SetErrorCallback(error_callback)

	if !glfw.Init() {
		fmt.println("Failed to initialize GLFW")
		return false
	}

	fmt.println("DEBUG: GLFW initialized successfully")

	// Don't create an OpenGL context
	glfw.WindowHint(glfw.CLIENT_API, glfw.NO_API)
	glfw.WindowHint(glfw.RESIZABLE, glfw.TRUE)
	glfw.WindowHint(glfw.DOUBLEBUFFER, glfw.FALSE)
	glfw.WindowHint(glfw.REFRESH_RATE, glfw.DONT_CARE)
	glfw.WindowHint(glfw.SCALE_FRAMEBUFFER, glfw.FALSE)
	glfw.WindowHint(glfw.SCALE_TO_MONITOR, glfw.FALSE)
	glfw.WindowHint(glfw.DECORATED, glfw.FALSE)
	if ENABLE_VALIDATION do glfw.WindowHint(glfw.CONTEXT_DEBUG, glfw.TRUE)

	window = glfw.CreateWindow(1, 1, "CHAIN OVER", nil, nil)

	// Check both window size and framebuffer size
	win_w, win_h := glfw.GetWindowSize(window)

	// Use window size for Vulkan, not framebuffer
	window_width = u32(win_w)
	window_height = u32(win_h)

	// Set up callbacks
	glfw.SetFramebufferSizeCallback(window, window_size_callback)
	glfw.SetKeyCallback(window, key_callback)
	glfw.SetMouseButtonCallback(window, mouse_button_callback)
	glfw.SetCursorPosCallback(window, cursor_pos_callback)

	fmt.println("DEBUG: GLFW platform setup complete")
	return true
}
get_instance_proc_address :: proc() -> rawptr {
	return rawptr(glfw.GetInstanceProcAddress)
}
get_required_instance_extensions :: proc() -> []cstring {
	return glfw.GetRequiredInstanceExtensions()
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
