package main

import "core:c"
import "core:fmt"
import "base:runtime"
import "vendor:glfw"

// Global window state
window: glfw.WindowHandle
window_width: c.int = 800
window_height: c.int = 600
resize_needed: bool = false
should_quit: bool = false

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
    
    // Handle escape to quit
    if key == glfw.KEY_ESCAPE && action == glfw.PRESS {
        should_quit = true
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
    window_width = c.int(width)
    window_height = c.int(height)
    resize_needed = true
    fmt.printf("Window resized to %dx%d\n", width, height)
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

glfw_cleanup :: proc() {
    fmt.println("Cleaning up GLFW...")
    if window != nil {
        glfw.DestroyWindow(window)
        window = nil
    }
    glfw.Terminate()
}

glfw_should_quit :: proc() -> c.int {
    if should_quit do return 1
    return c.int(glfw.WindowShouldClose(window) ? 1 : 0)
}

glfw_poll_events :: proc() {
    glfw.PollEvents()
}

get_window_width :: proc() -> c.int32_t {
    return c.int32_t(window_width)
}

get_window_height :: proc() -> c.int32_t {
    return c.int32_t(window_height)
}

glfw_resize_needed :: proc() -> c.int {
    if resize_needed {
        resize_needed = false
        return 1
    }
    return 0
}

glfw_window_visible :: proc() -> c.int {
    // GLFW window is always considered visible unless iconified
    return 1
}

get_glfw_window :: proc() -> glfw.WindowHandle {
    return window
}

// Input query functions
is_key_pressed :: proc(key: i32) -> bool {
    if key >= 0 && key < len(key_states) {
        return key_states[key]
    }
    return false
}

is_mouse_button_pressed :: proc(button: i32) -> bool {
    if button >= 0 && button < len(mouse_states) {
        return mouse_states[button]
    }
    return false
}

get_mouse_position :: proc() -> (f64, f64) {
    return mouse_x, mouse_y
}

get_scroll_delta :: proc() -> (f64, f64) {
    sx, sy := scroll_x, scroll_y
    scroll_x, scroll_y = 0, 0  // Reset scroll delta
    return sx, sy
}