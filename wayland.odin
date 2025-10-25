package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:time"
import vk "vendor:vulkan"

//──────────────────────────────────────────────
// Wayland core foreigns + opaque types
//──────────────────────────────────────────────
when ODIN_OS == .Linux {
	@(extra_linker_flags = "-lwayland-client")
	foreign import wl_client "system:wayland-client"
}

wl_display :: struct {}
wl_registry :: struct {}
wl_compositor :: struct {}
wl_surface :: struct {}
wl_proxy :: struct {}
wl_interface :: struct {
	name: cstring,
}

wl_registry_listener :: struct {
	global:
	proc(data: rawptr, wl_registry: ^wl_registry, name: u32, interface: cstring, version: u32),
	global_remove:
	proc(data: rawptr, wl_registry: ^wl_registry, name: u32),
}

@(default_calling_convention = "c")
foreign wl_client {
	// core display
	wl_display_connect :: proc(name: cstring) -> ^wl_display ---
	wl_display_disconnect :: proc(display: ^wl_display) ---
	wl_display_dispatch :: proc(display: ^wl_display) -> c.int ---
	wl_display_roundtrip :: proc(display: ^wl_display) -> c.int ---

	// generic proxy utils
	wl_proxy_add_listener :: proc(proxy: ^wl_proxy, implementation: ^rawptr, data: rawptr) -> int ---
	wl_proxy_marshal_flags :: proc(proxy: ^wl_proxy, opcode: u32, iface: ^wl_interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^wl_proxy ---
	wl_proxy_get_version :: proc(proxy: ^wl_proxy) -> u32 ---

	// exported wl_interface singletons
	wl_registry_interface: wl_interface
	wl_compositor_interface: wl_interface
	wl_surface_interface: wl_interface
}

//──────────────────────────────────────────────
// xdg-shell (generated C stubs in libxdgshell.a)
// (build once with wayland-scanner; link local .a)
//──────────────────────────────────────────────
when ODIN_OS == .Linux {
	foreign import xdgshell "libxdgshell.a"
}

xdg_wm_base :: struct {}
xdg_surface :: struct {}
xdg_toplevel :: struct {}

@(default_calling_convention = "c")
foreign xdgshell {
	// exported xdg interfaces
	xdg_wm_base_interface: wl_interface
	xdg_surface_interface: wl_interface
	xdg_toplevel_interface: wl_interface
}

//──────────────────────────────────────────────
// Helpers built on wl_proxy_marshal_flags
//──────────────────────────────────────────────
xdg_wm_base_get_xdg_surface :: proc(wm_base: ^xdg_wm_base, surface: ^wl_surface) -> ^xdg_surface {
	id := wl_proxy_marshal_flags(
		cast(^wl_proxy)wm_base,
		2, // xdg_wm_base.get_xdg_surface
		&xdg_surface_interface,
		wl_proxy_get_version(cast(^wl_proxy)wm_base),
		0,
		nil,
		surface,
	)
	return cast(^xdg_surface)id
}

xdg_surface_get_toplevel :: proc(xdg_surf: ^xdg_surface) -> ^xdg_toplevel {
	id := wl_proxy_marshal_flags(
		cast(^wl_proxy)xdg_surf,
		1, // xdg_surface.get_toplevel
		&xdg_toplevel_interface,
		wl_proxy_get_version(cast(^wl_proxy)xdg_surf),
		0,
		nil,
	)
	return cast(^xdg_toplevel)id
}

xdg_toplevel_set_title :: proc(toplevel: ^xdg_toplevel, title: cstring) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)toplevel,
		2, // xdg_toplevel.set_title
		nil,
		wl_proxy_get_version(cast(^wl_proxy)toplevel),
		0,
		title,
	)
}

xdg_surface_ack_configure :: proc(xdg_surf: ^xdg_surface, serial: u32) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)xdg_surf,
		4, // xdg_surface.ack_configure
		nil,
		wl_proxy_get_version(cast(^wl_proxy)xdg_surf),
		0,
		serial,
	)
}

// wl_surface.commit is a header-inline in C, so implement here
wl_surface_commit :: proc(surface: ^wl_surface) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)surface,
		6, // wl_surface.commit
		nil,
		wl_proxy_get_version(cast(^wl_proxy)surface),
		0,
	)
}

//───────────────────────────
// Globals / input state
//───────────────────────────
window_width: u32 = 1
window_height: u32 = 1
should_quit_key: bool = false

key_states: [512]bool
mouse_states: [8]bool
mouse_x, mouse_y: f64

is_key_pressed :: proc(key: i32) -> bool {return key_states[key]}
is_mouse_button_pressed :: proc(button: i32) -> bool {return mouse_states[button]}

//───────────────────────────
// Wayland state
//───────────────────────────
display: ^wl_display
registry: ^wl_registry
compositor: ^wl_compositor
wm_base: ^xdg_wm_base
surface: ^wl_surface
xdg_surf: ^xdg_surface
toplevel: ^xdg_toplevel
pending_serial: u32

//───────────────────────────
// Registry binding + helpers
//───────────────────────────
wl_registry_bind :: proc(
	reg: ^wl_registry,
	name: u32,
	iface: ^wl_interface,
	version: u32,
) -> rawptr {
	id := wl_proxy_marshal_flags(
		cast(^wl_proxy)reg,
		0,
		iface,
		version,
		0,
		name,
		iface.name,
		version,
		nil,
	)
	return cast(rawptr)id
}

global_registry_handler :: proc(
	data: rawptr,
	reg: ^wl_registry,
	id: u32,
	iface: cstring,
	ver: u32,
) {
	if iface == "wl_compositor" {
		compositor = cast(^wl_compositor)wl_registry_bind(reg, id, &wl_compositor_interface, 4)
	}
	if iface == "xdg_wm_base" {
		wm_base = cast(^xdg_wm_base)wl_registry_bind(reg, id, &xdg_wm_base_interface, 1)
	}
}
global_registry_remover :: proc(data: rawptr, reg: ^wl_registry, id: u32) {}

reg_listener := wl_registry_listener{global_registry_handler, global_registry_remover}

wl_registry_add_listener :: proc(
	reg: ^wl_registry,
	listener: ^wl_registry_listener,
	data: rawptr,
) -> int {
	return wl_proxy_add_listener(cast(^wl_proxy)reg, cast(^rawptr)listener, data)
}

wl_display_get_registry :: proc(display: ^wl_display) -> ^wl_registry {
	id := wl_proxy_marshal_flags(
		cast(^wl_proxy)display,
		1,
		&wl_registry_interface,
		wl_proxy_get_version(cast(^wl_proxy)display),
		0,
		nil,
	)
	return cast(^wl_registry)id
}

wl_compositor_create_surface :: proc(comp: ^wl_compositor) -> ^wl_surface {
	id := wl_proxy_marshal_flags(
		cast(^wl_proxy)comp,
		0,
		&wl_surface_interface,
		wl_proxy_get_version(cast(^wl_proxy)comp),
		0,
		nil,
	)
	return cast(^wl_surface)id
}

//───────────────────────────
// xdg-shell listeners (ping / configure / close)
//───────────────────────────
xdg_wm_base_listener :: struct {
	ping: proc(data: rawptr, wm: ^xdg_wm_base, serial: u32),
}
xdg_surface_listener :: struct {
	configure: proc(data: rawptr, surf: ^xdg_surface, serial: u32),
}
xdg_toplevel_listener :: struct {
	configure:
	proc(data: rawptr, top: ^xdg_toplevel, w: i32, h: i32, states: ^rawptr, num_states: i32),
	close:
	proc(data: rawptr, top: ^xdg_toplevel),
}

xdg_wm_base_pong :: proc(wm_base: ^xdg_wm_base, serial: u32) {
	// implemented by us via wl_proxy_marshal_flags? No — provided below.
	// (We provide our own version just above; this is the callback body.)
	// Nothing here; the marshal happens in the helper above.
}

xdg_wm_base_ping_cb :: proc(data: rawptr, wm: ^xdg_wm_base, serial: u32) {
	// our helper:
	wl_proxy_marshal_flags(
		cast(^wl_proxy)wm,
		3,
		nil,
		wl_proxy_get_version(cast(^wl_proxy)wm),
		0,
		serial,
	)
}

xdg_surface_configure_cb :: proc(data: rawptr, surf: ^xdg_surface, serial: u32) {
	pending_serial = serial
}

xdg_toplevel_configure_cb :: proc(
	data: rawptr,
	top: ^xdg_toplevel,
	w: i32,
	h: i32,
	states: ^rawptr,
	num_states: i32,
) {
	if w > 0 && h > 0 {
		window_width = u32(w)
		window_height = u32(h)
	}
}

xdg_toplevel_close_cb :: proc(data: rawptr, top: ^xdg_toplevel) {
	should_quit_key = true
}

//───────────────────────────
// Init Platform
//───────────────────────────
init_platform :: proc() -> bool {
	display = wl_display_connect(nil)
	if display == nil {
		fmt.println("Could not connect to display")
		return false
	}

	fmt.println("Connected to Wayland display!")
	registry = wl_display_get_registry(display)
	wl_registry_add_listener(registry, &reg_listener, nil)

	wl_display_dispatch(display)
	wl_display_roundtrip(display)

	if compositor == nil {
		fmt.println("Cannot find wl_compositor")
		os.exit(1)
	}
	if wm_base == nil {
		fmt.println("Cannot find xdg_wm_base (required)")
		os.exit(1)
	}
	fmt.println("Found compositor + wm_base")

	// listeners
	base_impl := xdg_wm_base_listener{xdg_wm_base_ping_cb}
	surf_impl := xdg_surface_listener{xdg_surface_configure_cb}

	wl_proxy_add_listener(cast(^wl_proxy)wm_base, cast(^rawptr)&base_impl, nil)

	// surface graph
	surface = wl_compositor_create_surface(compositor)
	xdg_surf = xdg_wm_base_get_xdg_surface(wm_base, surface)
	wl_proxy_add_listener(cast(^wl_proxy)xdg_surf, cast(^rawptr)&surf_impl, nil)

	toplevel = xdg_surface_get_toplevel(xdg_surf)
	xdg_toplevel_set_title(toplevel, "Odin Wayland Window")

	// toplevel listener (configure/close)
	top_impl := xdg_toplevel_listener{xdg_toplevel_configure_cb, xdg_toplevel_close_cb}
	wl_proxy_add_listener(cast(^wl_proxy)toplevel, cast(^rawptr)&top_impl, nil)

	// first commit → compositor will send initial configure
	wl_surface_commit(surface)

	fmt.println("Created xdg_surface + toplevel, waiting for configure...")
	for pending_serial == 0 {
		wl_display_dispatch(display)
	}
	xdg_surface_ack_configure(xdg_surf, pending_serial)
	fmt.println("Window ready")
	return true
}

//───────────────────────────
// Blocking event wait & cleanup
//───────────────────────────
poll_events :: proc() {
	_ = wl_display_dispatch(display) // if you want manual pumping
}

wait_until_window_close :: proc() {
	for !should_quit_key {
		if wl_display_dispatch(display) < 0 {
			break
		}
	}
}

should_quit :: proc() -> bool {
	return should_quit_key
}

platform_cleanup :: proc() {
	if display != nil {
		wl_display_disconnect(display)
	}
	fmt.println("Disconnected from Wayland display")
}

//───────────────────────────
// Vulkan integration helpers
//───────────────────────────
get_required_instance_extensions :: proc() -> []cstring {
	@(static) exts := []cstring{"VK_KHR_surface", "VK_KHR_wayland_surface"}
	return exts
}

get_instance_proc_address :: proc() -> rawptr {
	when ODIN_OS == .Linux {
		handle := os.dlopen("libvulkan.so.1", os.RTLD_NOW)
		if handle == nil {handle = os.dlopen("libvulkan.so", os.RTLD_NOW)}
		if handle == nil {
			fmt.eprintln("Failed to load Vulkan library")
			return nil
		}
		return os.dlsym(handle, "vkGetInstanceProcAddr")
	}
	return nil
}

// Optional: create VkSurfaceKHR from current Wayland objects

init_window :: proc(instance: vk.Instance) -> bool {
	if display == nil || surface == nil {
		fmt.eprintln("[WAYLAND] display/surface not ready")
		return false
	}

	// Dynamically fetch vkCreateWaylandSurfaceKHR (portable)
	create_wayland_surface := cast(proc(
		instance: vk.Instance,
		pCreateInfo: ^vk.WaylandSurfaceCreateInfoKHR,
		pAllocator: ^vk.AllocationCallbacks,
		pSurface: ^vk.SurfaceKHR,
	) -> vk.Result)vk.GetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR")

	if create_wayland_surface == nil {
		fmt.eprintln(
			"[VULKAN] vkCreateWaylandSurfaceKHR not found (enable VK_KHR_wayland_surface)",
		)
		return false
	}

	ci := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = cast(^vk.wl_display)display,
		surface = cast(^vk.wl_surface)surface,
	}

	res := create_wayland_surface(instance, &ci, nil, &vulkan_surface)
	if res != .SUCCESS {
		fmt.printf("[VULKAN] vkCreateWaylandSurfaceKHR failed: %v\n", res)
		vulkan_surface = {}
		return false
	}

	fmt.println("[VULKAN] Wayland VkSurfaceKHR created")
	return true
}
