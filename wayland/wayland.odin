package wayland

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:os"
import vk "vendor:vulkan"


render_frame: proc() -> bool
handle_resize: proc()
check_shader_reload: proc()


//──────────────────────────────────────────────
// Wayland imports
//──────────────────────────────────────────────
when ODIN_OS == .Linux {
	@(extra_linker_flags = "-lwayland-client")
	foreign import wl "system:wayland-client"
}

//──────────────────────────────────────────────
// Opaque structs
//──────────────────────────────────────────────
wl_display :: struct {}
wl_registry :: struct {}
wl_compositor :: struct {}
wl_surface :: struct {}
wl_seat :: struct {}
wl_keyboard :: struct {}
wl_pointer :: struct {}
wl_proxy :: struct {}

// Correct C layouts for libwayland
wl_message :: struct {
	name:      cstring,
	signature: cstring,
	types:     ^^wl_interface,
}
wl_interface :: struct {
	name:         cstring,
	version:      c.int,
	method_count: c.int,
	methods:      ^wl_message,
	event_count:  c.int,
	events:       ^wl_message,
}
// wl_array from <wayland-util.h>
wl_array :: struct {
	size:  c.size_t,
	alloc: c.size_t,
	data:  rawptr,
}

@(default_calling_convention = "c")
foreign wl {
	wl_display_connect :: proc(name: cstring) -> ^wl_display ---
	wl_display_disconnect :: proc(display: ^wl_display) ---
	wl_display_dispatch :: proc(display: ^wl_display) -> int ---
	wl_display_roundtrip :: proc(display: ^wl_display) -> int ---
	wl_display_dispatch_pending :: proc(display: ^wl_display) -> int ---
	wl_display_flush :: proc(display: ^wl_display) -> int ---
	wl_proxy_add_listener :: proc(proxy: ^wl_proxy, impl: ^rawptr, data: rawptr) -> int ---
	wl_proxy_marshal_flags :: proc(proxy: ^wl_proxy, opcode: u32, iface: ^wl_interface, version: u32, flags: u32, #c_vararg args: ..any) -> ^wl_proxy ---
	wl_proxy_get_version :: proc(proxy: ^wl_proxy) -> u32 ---
	wl_registry_interface: wl_interface
	wl_compositor_interface: wl_interface
	wl_surface_interface: wl_interface
	wl_seat_interface: wl_interface
	wl_keyboard_interface: wl_interface
	wl_pointer_interface: wl_interface
	wl_callback_interface: wl_interface
}

//──────────────────────────────────────────────
// XDG shell import
//──────────────────────────────────────────────
xdg_wm_base :: struct {}
xdg_surface :: struct {}
xdg_toplevel :: struct {}

when ODIN_OS == .Linux {
	foreign import xdg "libxdgshell.a"
}

@(default_calling_convention = "c")
foreign xdg {
	xdg_wm_base_interface: wl_interface
	xdg_surface_interface: wl_interface
	xdg_toplevel_interface: wl_interface
}

//──────────────────────────────────────────────
// Globals shared with renderer
//──────────────────────────────────────────────
window_width, window_height: u32 = 800, 600
window_resized: bool = false
should_quit: bool = false
mouse_x, mouse_y: f64
key_states: [512]bool
mouse_states: [8]bool

is_key_pressed :: proc(key: i32) -> bool {return key_states[key]}
is_mouse_button_pressed :: proc(btn: i32) -> bool {return mouse_states[btn]}

//──────────────────────────────────────────────
// Core Wayland state
//──────────────────────────────────────────────
display: ^wl_display
compositor: ^wl_compositor
wm_base: ^xdg_wm_base
surface: ^wl_surface
xdg_surf: ^xdg_surface
toplevel: ^xdg_toplevel
pending_serial: u32
seat: ^wl_seat
keyboard: ^wl_keyboard
pointer: ^wl_pointer

//──────────────────────────────────────────────
// Registry + listeners
//──────────────────────────────────────────────
wl_registry_listener :: struct {
	global:        proc(data: rawptr, reg: ^wl_registry, id: u32, iface: cstring, ver: u32),
	global_remove: proc(data: rawptr, reg: ^wl_registry, id: u32),
}

reg_listener := wl_registry_listener {
	proc(_: rawptr, reg: ^wl_registry, id: u32, iface: cstring, _: u32) {
		if iface == "wl_compositor" do compositor = cast(^wl_compositor)wl_registry_bind(reg, id, &wl_compositor_interface, 4)
		if iface == "xdg_wm_base" do wm_base = cast(^xdg_wm_base)wl_registry_bind(reg, id, &xdg_wm_base_interface, 1)
		if iface == "wl_seat" do seat = cast(^wl_seat)wl_registry_bind(reg, id, &wl_seat_interface, 5)
	},
	proc(_: rawptr, _: ^wl_registry, _: u32) {},
}

//──────────────────────────────────────────────
// XDG listeners (correct signatures)
//──────────────────────────────────────────────
xdg_wm_base_listener :: struct {
	ping: proc(data: rawptr, wm: ^xdg_wm_base, serial: u32),
}
xdg_surface_listener :: struct {
	configure: proc(data: rawptr, surf: ^xdg_surface, serial: u32),
}
xdg_toplevel_listener :: struct {
	// FIX: states is a single wl_array*, not (ptr,count)
	configure: proc(data: rawptr, top: ^xdg_toplevel, w: i32, h: i32, states: ^wl_array),
	close:     proc(data: rawptr, top: ^xdg_toplevel),
}

base_impl := xdg_wm_base_listener {
	proc(_: rawptr, wm: ^xdg_wm_base, serial: u32) {
		wl_proxy_marshal_flags(
			cast(^wl_proxy)wm,
			3, // xdg_wm_base.pong
			nil,
			wl_proxy_get_version(cast(^wl_proxy)wm),
			0,
			serial,
		)
	},
}

surf_impl := xdg_surface_listener {
	proc(_: rawptr, _: ^xdg_surface, serial: u32) {pending_serial = serial},
}

top_impl := xdg_toplevel_listener{proc(_: rawptr, _: ^xdg_toplevel, w: i32, h: i32, _: ^wl_array) {
		if w > 0 && h > 0 {
			window_width, window_height = u32(w), u32(h)
			if handle_resize != nil {
				handle_resize()
			}
		}
	}, proc(_: rawptr, _: ^xdg_toplevel) {should_quit = true}}

//──────────────────────────────────────────────
// Missing helper procs
//──────────────────────────────────────────────
wl_registry_bind :: proc(
	reg: ^wl_registry,
	name: u32,
	iface: ^wl_interface,
	version: u32,
) -> rawptr {
	return cast(rawptr)wl_proxy_marshal_flags(
			cast(^wl_proxy)reg,
			0, // wl_registry.bind
			iface,
			version,
			0,
			name,
			iface.name,
			version,
			nil,
		)
}

wl_compositor_create_surface :: proc(c: ^wl_compositor) -> ^wl_surface {
	return cast(^wl_surface)wl_proxy_marshal_flags(
			cast(^wl_proxy)c,
			0, // wl_compositor.create_surface
			&wl_surface_interface,
			wl_proxy_get_version(cast(^wl_proxy)c),
			0,
			nil,
		)
}

xdg_wm_base_get_xdg_surface :: proc(base: ^xdg_wm_base, surf: ^wl_surface) -> ^xdg_surface {
	return cast(^xdg_surface)wl_proxy_marshal_flags(
			cast(^wl_proxy)base,
			2, // xdg_wm_base.get_xdg_surface
			&xdg_surface_interface,
			wl_proxy_get_version(cast(^wl_proxy)base),
			0,
			nil,
			surf,
		)
}

xdg_surface_get_toplevel :: proc(x: ^xdg_surface) -> ^xdg_toplevel {
	return cast(^xdg_toplevel)wl_proxy_marshal_flags(
			cast(^wl_proxy)x,
			1, // xdg_surface.get_toplevel
			&xdg_toplevel_interface,
			wl_proxy_get_version(cast(^wl_proxy)x),
			0,
		)
}

xdg_surface_ack_configure :: proc(x: ^xdg_surface, serial: u32) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)x,
		4, // xdg_surface.ack_configure
		nil,
		wl_proxy_get_version(cast(^wl_proxy)x),
		0,
		serial,
	)
}

xdg_toplevel_set_title :: proc(t: ^xdg_toplevel, title: cstring) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)t,
		2, // xdg_toplevel.set_title
		nil,
		wl_proxy_get_version(cast(^wl_proxy)t),
		0,
		title,
	)
}

xdg_toplevel_set_app_id :: proc(t: ^xdg_toplevel, app_id: cstring) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)t,
		3, // xdg_toplevel.set_app_id
		nil,
		wl_proxy_get_version(cast(^wl_proxy)t),
		0,
		app_id,
	)
}

wl_surface_commit :: proc(s: ^wl_surface) {
	wl_proxy_marshal_flags(
		cast(^wl_proxy)s,
		6, // wl_surface.commit
		nil,
		wl_proxy_get_version(cast(^wl_proxy)s),
		0,
	)
}

//──────────────────────────────────────────────
// Init
//──────────────────────────────────────────────

init :: proc() -> bool {
	display = wl_display_connect(nil)
	if display == nil {
		fmt.eprintln("Wayland connect failed")
		return false
	}

	reg := cast(^wl_registry)wl_proxy_marshal_flags(
		cast(^wl_proxy)display,
		1, // wl_display.get_registry
		&wl_registry_interface,
		wl_proxy_get_version(cast(^wl_proxy)display),
		0,
	)
	wl_proxy_add_listener(cast(^wl_proxy)reg, cast(^rawptr)&reg_listener, nil)
	wl_display_roundtrip(display)

	if compositor == nil || wm_base == nil {
		fmt.eprintln("Missing compositor/wm_base")
		return false
	}

	surface = wl_compositor_create_surface(compositor)
	xdg_surf = xdg_wm_base_get_xdg_surface(wm_base, surface)
	toplevel = xdg_surface_get_toplevel(xdg_surf)

	// Set window title & ID
	xdg_toplevel_set_title(toplevel, "Vulkan Window")
	xdg_toplevel_set_app_id(toplevel, "vk")

	wl_proxy_add_listener(cast(^wl_proxy)wm_base, cast(^rawptr)&base_impl, nil)
	wl_proxy_add_listener(cast(^wl_proxy)xdg_surf, cast(^rawptr)&surf_impl, nil)
	wl_proxy_add_listener(cast(^wl_proxy)toplevel, cast(^rawptr)&top_impl, nil)

	// First commit — tells compositor surface exists
	wl_surface_commit(surface)
	wl_display_roundtrip(display)

	// Wait until we get initial configure from compositor
	for pending_serial == 0 {
		_ = wl_display_dispatch(display)
	}

	// Ack configure, THEN commit → surface becomes mapped/visible
	xdg_surface_ack_configure(xdg_surf, pending_serial)
	if seat != nil {
		keyboard = wl_seat_get_keyboard(seat)
		pointer = wl_seat_get_pointer(seat)
		if keyboard != nil {
			wl_proxy_add_listener(cast(^wl_proxy)keyboard, cast(^rawptr)&kbd_impl, nil)
		}
		if pointer != nil {
			wl_proxy_add_listener(cast(^wl_proxy)pointer, cast(^rawptr)&ptr_impl, nil)
		}
	}
	fmt.println("Wayland window ready (awaiting first frame callback)")
	return true
}


//──────────────────────────────────────────────
// Frame callback (Wayland vsync pacing)
//──────────────────────────────────────────────


wl_callback :: struct {} // opaque

wl_callback_listener :: struct {
	done: proc(data: rawptr, cb: ^wl_callback, time: u32),
}
frame_listener := wl_callback_listener {
	done = frame_done_cb,
}
frame_done_cb :: proc(data: rawptr, cb: ^wl_callback, time: u32) {
	render_frame()
	request_frame()
	wl_surface_commit(surface)
}

request_frame :: proc() {
	cb := cast(^wl_callback)wl_proxy_marshal_flags(
		cast(^wl_proxy)surface,
		3, // wl_surface.frame (correct opcode)
		&wl_callback_interface, // must be the callback interface
		wl_proxy_get_version(cast(^wl_proxy)surface),
		0,
	)
	_ = wl_proxy_add_listener(cast(^wl_proxy)cb, cast(^rawptr)&frame_listener, nil)
}

//──────────────────────────────────────────────
// Vulkan helpers
//──────────────────────────────────────────────
get_required_instance_extensions :: proc() -> []cstring {
	@(static) exts := []cstring{"VK_KHR_surface", "VK_KHR_wayland_surface"}
	return exts
}

get_instance_proc_address :: proc() -> rawptr {
	when ODIN_OS == .Linux {
		handle := os.dlopen("libvulkan.so.1", os.RTLD_NOW)
		if handle == nil do handle = os.dlopen("libvulkan.so", os.RTLD_NOW)
		if handle == nil {
			fmt.eprintln("Failed to load Vulkan lib")
			return nil
		}
		return os.dlsym(handle, "vkGetInstanceProcAddr")
	}
	return nil
}

init_window :: proc(instance: vk.Instance, vulkan_surface: ^vk.SurfaceKHR) -> bool {
	create_surface := cast(proc "c" (
		instance: vk.Instance,
		info: ^vk.WaylandSurfaceCreateInfoKHR,
		alloc: ^vk.AllocationCallbacks,
		out: ^vk.SurfaceKHR,
	) -> vk.Result)vk.GetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR")

	if create_surface == nil do return false

	info := vk.WaylandSurfaceCreateInfoKHR {
		sType   = .WAYLAND_SURFACE_CREATE_INFO_KHR,
		display = cast(^vk.wl_display)display,
		surface = cast(^vk.wl_surface)surface,
	}

	fmt.println("window init")
	return create_surface(instance, &info, nil, vulkan_surface) == .SUCCESS
}

//──────────────────────────────────────────────
// Keyboard & Mouse input
//──────────────────────────────────────────────

linux_to_key :: proc(code: u32) -> i32 {
	// A–Z (Linux scancode → ASCII)
	letter_map := [][2]u32 {
		{30, 'A'},
		{48, 'B'},
		{46, 'C'},
		{32, 'D'},
		{18, 'E'},
		{33, 'F'},
		{34, 'G'},
		{35, 'H'},
		{23, 'I'},
		{36, 'J'},
		{37, 'K'},
		{38, 'L'},
		{50, 'M'},
		{49, 'N'},
		{24, 'O'},
		{25, 'P'},
		{16, 'Q'},
		{19, 'R'},
		{31, 'S'},
		{20, 'T'},
		{22, 'U'},
		{47, 'V'},
		{17, 'W'},
		{45, 'X'},
		{21, 'Y'},
		{44, 'Z'},
	}
	for pair in letter_map {
		if pair[0] == code do return i32(pair[1])
	}

	// numbers 1–9,0
	if code >= 2 && code <= 10 do return '1' + i32(code - 2)
	if code == 11 do return '0'

	// space, escape, enter, tab, backspace, arrows
	special_map := [][2]u32 {
		{57, 32}, // space
		{1, 256}, // escape
		{28, 257}, // enter
		{15, 258}, // tab
		{14, 259}, // backspace
		{105, 263}, // left
		{106, 262}, // right
		{103, 265}, // up
		{108, 264}, // down
	}
	for pair in special_map {
		if pair[0] == code do return i32(pair[1])
	}

	return i32(code)
}
// seat helpers
wl_seat_get_keyboard :: proc(s: ^wl_seat) -> ^wl_keyboard {
	return(
		cast(^wl_keyboard)wl_proxy_marshal_flags(
			cast(^wl_proxy)s,
			1,
			&wl_keyboard_interface,
			wl_proxy_get_version(cast(^wl_proxy)s),
			0,
			nil,
		) \
	)
}
wl_seat_get_pointer :: proc(s: ^wl_seat) -> ^wl_pointer {
	return(
		cast(^wl_pointer)wl_proxy_marshal_flags(
			cast(^wl_proxy)s,
			0,
			&wl_pointer_interface,
			wl_proxy_get_version(cast(^wl_proxy)s),
			0,
			nil,
		) \
	)
}

// keyboard listener struct
wl_keyboard_listener :: struct {
	keymap:      proc(data: rawptr, kbd: ^wl_keyboard, format: u32, fd: i32, size: u32),
	enter:       proc(
		data: rawptr,
		kbd: ^wl_keyboard,
		serial: u32,
		surf: ^wl_surface,
		keys: ^rawptr,
	),
	leave:       proc(data: rawptr, kbd: ^wl_keyboard, serial: u32, surf: ^wl_surface),
	key:         proc(
		data: rawptr,
		kbd: ^wl_keyboard,
		serial: u32,
		time: u32,
		key: u32,
		state: u32,
	),
	modifiers:   proc(
		data: rawptr,
		kbd: ^wl_keyboard,
		serial: u32,
		md: u32,
		ml: u32,
		mk: u32,
		grp: u32,
	),
	repeat_info: proc(data: rawptr, kbd: ^wl_keyboard, rate: i32, delay: i32),
}

// minimal key handler (ESC quits)
keyboard_keymap_cb :: proc(data: rawptr, kbd: ^wl_keyboard, format: u32, fd: i32, size: u32) {}
keyboard_enter_cb :: proc(
	data: rawptr,
	kbd: ^wl_keyboard,
	serial: u32,
	surf: ^wl_surface,
	keys: ^rawptr,
) {}
keyboard_leave_cb :: proc(data: rawptr, kbd: ^wl_keyboard, serial: u32, surf: ^wl_surface) {}
keyboard_modifiers_cb :: proc(
	data: rawptr,
	kbd: ^wl_keyboard,
	serial: u32,
	md: u32,
	ml: u32,
	mk: u32,
	grp: u32,
) {}
keyboard_repeat_info_cb :: proc(data: rawptr, kbd: ^wl_keyboard, rate: i32, delay: i32) {}

keyboard_key_cb :: proc(
	data: rawptr,
	kbd: ^wl_keyboard,
	serial: u32,
	time: u32,
	key: u32,
	state: u32,
) {
	k := linux_to_key(key)
	if k >= 0 && k < 512 {key_states[k] = (state == 1)}
}

kbd_impl := wl_keyboard_listener {
	keyboard_keymap_cb, // opcode 0: keymap
	keyboard_enter_cb, // 1: enter
	keyboard_leave_cb, // 2: leave
	keyboard_key_cb, // 3: key
	keyboard_modifiers_cb, // 4: modifiers
	keyboard_repeat_info_cb, // 5: repeat_info
}


// pointer listener struct
wl_pointer_listener :: struct {
	enter:  proc(data: rawptr, ptr: ^wl_pointer, serial: u32, surf: ^wl_surface, sx: i32, sy: i32),
	leave:  proc(data: rawptr, ptr: ^wl_pointer, serial: u32, surf: ^wl_surface),
	motion: proc(data: rawptr, ptr: ^wl_pointer, time: u32, sx: i32, sy: i32),
	button: proc(data: rawptr, ptr: ^wl_pointer, serial: u32, time: u32, button: u32, state: u32),
	axis:   proc(data: rawptr, ptr: ^wl_pointer, time: u32, axis: u32, value: i32),
	frame:  proc(data: rawptr, ptr: ^wl_pointer),
}

pointer_enter_cb :: proc(
	data: rawptr,
	ptr: ^wl_pointer,
	serial: u32,
	surf: ^wl_surface,
	sx: i32,
	sy: i32,
) {}
pointer_leave_cb :: proc(data: rawptr, ptr: ^wl_pointer, serial: u32, surf: ^wl_surface) {}
pointer_motion_cb :: proc(data: rawptr, ptr: ^wl_pointer, time: u32, sx: i32, sy: i32) {
	mouse_x = f64(sx) / 256.0
	mouse_y = f64(sy) / 256.0
}
pointer_button_cb :: proc(
	data: rawptr,
	ptr: ^wl_pointer,
	serial: u32,
	time: u32,
	button: u32,
	state: u32,
) {
	btn: i32 = -1
	switch button {
	case 0x110:
		btn = 0
	case 0x111:
		btn = 1
	case 0x112:
		btn = 2
	}
	if btn >= 0 && btn < len(mouse_states) {
		mouse_states[btn] = (state == 1)
	}
}
pointer_axis_cb :: proc(data: rawptr, ptr: ^wl_pointer, time: u32, axis: u32, value: i32) {}
pointer_frame_cb :: proc(data: rawptr, ptr: ^wl_pointer) {}

ptr_impl := wl_pointer_listener {
	pointer_enter_cb, // 0
	pointer_leave_cb, // 1
	pointer_motion_cb, // 2
	pointer_button_cb, // 3
	pointer_axis_cb, // 4
	pointer_frame_cb, // 5
}
//──────────────────────────────────────────────
// Event / cleanup
//──────────────────────────────────────────────
run :: proc() {
	fmt.println("starting prun")
	render_frame()
	wl_display_flush(display)
	wl_display_dispatch_pending(display)
	render_frame()
	request_frame()
	for !should_quit {
		check_shader_reload()
		_ = wl_display_dispatch(display)
	}
}

cleanup :: proc() {
	if display != nil {wl_display_disconnect(display)}
}
