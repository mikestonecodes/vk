package main

import "core:c"

// Opaque types for Wayland objects
wl_display :: rawptr
wl_surface :: rawptr

// Link to our C wrapper
foreign import wayland_wrapper "libwayland_wrapper.so"

@(default_calling_convention="c")
foreign wayland_wrapper {
    wayland_init :: proc() -> c.int ---
    wayland_cleanup :: proc() ---
    get_wayland_display :: proc() -> wl_display ---
    get_wayland_surface :: proc() -> wl_surface ---
    wayland_should_quit :: proc() -> c.int ---
    wayland_poll_events :: proc() ---
    get_window_width :: proc() -> c.int32_t ---
    get_window_height :: proc() -> c.int32_t ---
    wayland_resize_needed :: proc() -> c.int ---
}

init_platform :: proc() -> bool {
    if wayland_init() == 0 {
        return false
    }

    display = get_wayland_display()
    surface = get_wayland_surface()
    if display == nil || surface == nil {
        return false
    }

    return true
}
