package main

import "vendor:glfw"
import vk "vendor:vulkan"

COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2

CAMERA_UPDATE_FLAG :: u32(1 << 0)

// Physics configuration
PHYS_MAX_BODIES :: u32(512000)
PHYS_PLAYER_INDEX :: u32(0)
PHYS_PROJECTILE_START :: u32(1)
PHYS_PROJECTILE_POOL :: u32(60000)
PHYS_SOLVER_ITERATIONS :: u32(4)
PHYS_SUBSTEPS :: u32(1)

GRID_X :: u32(512)
GRID_Y :: u32(512)
GRID_CELL_COUNT :: u32(GRID_X * GRID_Y)


EXPLOSION_EVENT_CAPACITY :: u32(256)

CameraStateGPU :: struct {
	position:    [2]f32,
	zoom:        f32,
	pad0:        f32,
	initialized: u32,
	pad1:        [3]u32,
}


PostProcessPushConstants :: struct {
	screen_width:  u32,
	screen_height: u32,
}

ComputePushConstants :: struct {
	time:                    f32,
	delta_time:              f32,
	screen_width:            u32,
	screen_height:           u32,
	brightness:              f32,
	move_forward:            b32,
	move_backward:           b32,
	move_right:              b32,
	move_left:               b32,
	zoom_in:                 b32,
	zoom_out:                b32,
	speed:                   b32,
	reset_camera:            b32,
	options:                 u32,
	dispatch_mode:           u32,
	scan_offset:             u32,
	scan_source:             u32,
	solver_iteration:        u32,
	substep_index:           u32,
	substep_count:           u32,
	body_capacity:           u32,
	grid_x:                  u32,
	grid_y:                  u32,
	solver_iterations_total: u32,
	relaxation:              f32,
	dt_clamp:                f32,
	projectile_speed:        f32,
	projectile_radius:       f32,
	projectile_max_distance: f32,
	player_radius:           f32,
	player_damping:          f32,
	spawn_projectile:        b32,
	mouse_ndc_x:             f32,
	mouse_ndc_y:             f32,
	projectile_pool:         u32,
	_pad0:                   u32,
}

compute_push_constants := ComputePushConstants {
	screen_width            = u32(window_width),
	screen_height           = u32(window_height),
	brightness              = 1.0,
	substep_count           = PHYS_SUBSTEPS,
	body_capacity           = PHYS_MAX_BODIES,
	grid_x                  = GRID_X,
	grid_y                  = GRID_Y,
	solver_iterations_total = PHYS_SOLVER_ITERATIONS,
	relaxation              = 1.0,
	dt_clamp                = 1.0 / 30.0,
	projectile_speed        = 42.0,
	projectile_radius       = 0.20,
	projectile_max_distance = 450.0,
	player_radius           = 0.65,
	player_damping          = 0.02,
	projectile_pool         = PHYS_PROJECTILE_POOL,
}


post_process_push_constants := PostProcessPushConstants {
	screen_width  = u32(window_width),
	screen_height = u32(window_height),
}

ExplosionEventGPU :: struct {
	center:     [2]f32,
	radius:     f32,
	energy:     f32,
	start_time: f32,
	target_id:  u32,
	processed:  u32,
	reserved0:  u32,
	reserved1:  u32,
}

SpawnStateGPU :: struct {
	next_projectile:    u32,
	next_explosion:     u32,
	explosion_head:     u32,
	active_projectiles: u32,
	events:             [EXPLOSION_EVENT_CAPACITY]ExplosionEventGPU,
}

physics_initialized: bool

ComputeTask :: struct {
	mode:           DispatchMode,
	pipeline_index: u32,
	group:          [3]u32,
	repeat_count:   u32,
	label:          string,
}

DispatchMode :: enum u32 {
	CAMERA_UPDATE      = 0,
	INITIALIZE         = 1,
	CLEAR_GRID         = 2,
	SPAWN_PROJECTILE   = 3,
	INTEGRATE          = 4,
	HISTOGRAM          = 5,
	PREFIX_COPY        = 6,
	PREFIX_SCAN        = 7,
	PREFIX_COPY_SOURCE = 8,
	PREFIX_FINALIZE    = 9,
	SCATTER            = 10,
	ZERO_DELTAS        = 11,
	CONSTRAINTS        = 12,
	APPLY_DELTAS       = 13,
	FINALIZE           = 14,
	RENDER             = 15,
}

body_vec2_size := DeviceSize(size_of(f32) * 2)
body_scalar_size := DeviceSize(size_of(f32))
body_uint_size := DeviceSize(size_of(u32))
body_capacity_size := DeviceSize(PHYS_MAX_BODIES)
grid_cell_size := DeviceSize(GRID_CELL_COUNT)


buffer_specs := []struct {
	size:    DeviceSize,
	flags:   vk.BufferUsageFlags,
	binding: u32,
} {
	{
		DeviceSize(window_width * window_height * 4 * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
		0,
	},
	{DeviceSize(size_of(CameraStateGPU)), {.STORAGE_BUFFER, .TRANSFER_DST}, 3},
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 20},
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 21},
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 22},
	{body_capacity_size * body_scalar_size, {.STORAGE_BUFFER}, 23},
	{body_capacity_size * body_scalar_size, {.STORAGE_BUFFER}, 24},
	{body_capacity_size * body_uint_size, {.STORAGE_BUFFER}, 25},
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 26},
	{DeviceSize(size_of(SpawnStateGPU)), {.STORAGE_BUFFER}, 27},
	{grid_cell_size * body_uint_size, {.STORAGE_BUFFER}, 30},
	{DeviceSize(GRID_CELL_COUNT + 1) * body_uint_size, {.STORAGE_BUFFER}, 31},
	{grid_cell_size * body_uint_size, {.STORAGE_BUFFER}, 32},
	{body_capacity_size * body_uint_size, {.STORAGE_BUFFER}, 33},
}


render_shader_configs := []ShaderProgramConfig {
	{
		compute_module = "compute.spv",
		push = {
			label = "ComputePushConstants",
			stage = {.COMPUTE},
			size = u32(size_of(ComputePushConstants)),
		},
	},
	{
		vertex_module = "graphics_vs.spv",
		fragment_module = "graphics_fs.spv",
		push = {
			label = "PostProcessPushConstants",
			stage = {.VERTEX, .FRAGMENT},
			size = u32(size_of(PostProcessPushConstants)),
		},
	},
}


resize :: proc() {
	destroy_buffer(&buffers.data[0])
	create_buffer(
		&buffers.data[0],
		DeviceSize(window_width) * DeviceSize(window_height) * 4 * DeviceSize(size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	bind_resource(0, &buffers.data[0])
}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	simulate_particles(frame)
	composite_to_swapchain(frame, element)
}

// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {
	mouse_x, mouse_y := get_mouse_position()
	width := max(f64(window_width), 1.0)
	height := max(f64(window_height), 1.0)
	total_pixels := u32(window_width) * u32(window_height)
	pixel_dispatch := (total_pixels + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	body_dispatch := (PHYS_MAX_BODIES + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	grid_dispatch := (GRID_CELL_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE


	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time
	compute_push_constants.screen_width = u32(window_width)
	compute_push_constants.screen_height = u32(window_height)
	compute_push_constants.brightness = 1.0
	compute_push_constants.move_forward = b32(is_key_pressed(glfw.KEY_W))
	compute_push_constants.move_backward = b32(is_key_pressed(glfw.KEY_S))
	compute_push_constants.move_right = b32(is_key_pressed(glfw.KEY_D))
	compute_push_constants.move_left = b32(is_key_pressed(glfw.KEY_A))
	compute_push_constants.zoom_in = b32(is_key_pressed(glfw.KEY_E))
	compute_push_constants.zoom_out = b32(is_key_pressed(glfw.KEY_Q))
	compute_push_constants.speed = b32(is_key_pressed(glfw.KEY_T))
	compute_push_constants.reset_camera = b32(is_key_pressed(glfw.KEY_R))
	compute_push_constants.spawn_projectile = b32(is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT))
	compute_push_constants.mouse_ndc_x = f32(clamp(mouse_x / width, 0.0, 1.0))
	compute_push_constants.mouse_ndc_y = f32(clamp(mouse_y / height, 0.0, 1.0))


	substep_count_f := f32(PHYS_SUBSTEPS)
	if substep_count_f <= 0.0 {substep_count_f = 1.0}
	physics_dt := frame.delta_time / substep_count_f
	if physics_dt < 0.0 {physics_dt = 0.0}

	// ---- Camera update ----
	compute_push_constants.options = CAMERA_UPDATE_FLAG
	dispatch_compute(frame, {mode = .CAMERA_UPDATE})

	// ---- One-time physics init ----
	if !physics_initialized {
		dispatch_compute(frame, {mode = .INITIALIZE})
		physics_initialized = true
	}

	// ---- Substeps ----
	for substep_index: u32 = 0; substep_index < PHYS_SUBSTEPS; substep_index += 1 {
		compute_push_constants.substep_index = substep_index
		compute_push_constants.delta_time = physics_dt

		// Clear cell grid
		dispatch_compute(frame, {mode = .CLEAR_GRID, group = {grid_dispatch, 1, 1}})

		// Spawn projectile (only if requested)
		if compute_push_constants.spawn_projectile {
			dispatch_compute(frame, ComputeTask{mode = .SPAWN_PROJECTILE})
		}
		// Integrate and predict
		dispatch_compute(frame, {mode = .INTEGRATE, group = {body_dispatch, 1, 1}})
		dispatch_compute(frame, {mode = .HISTOGRAM, group = {body_dispatch, 1, 1}})
		dispatch_compute(frame, {mode = .PREFIX_COPY, group = {grid_dispatch, 1, 1}})
		parity: u32 = 0
		offset: u32 = 1
		for offset < GRID_CELL_COUNT {
			compute_push_constants.dispatch_mode = u32(DispatchMode.PREFIX_SCAN)
			compute_push_constants.scan_offset = offset
			compute_push_constants.scan_source = parity
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
			compute_barrier(frame.cmd)
			parity = 1 - parity
			offset <<= 1
		}
		if parity == 0 {
			dispatch_compute(frame, {mode = .PREFIX_COPY_SOURCE, group = {grid_dispatch, 1, 1}})
			parity = 1
		}
		compute_push_constants.scan_source = parity
		dispatch_compute(frame, {mode = .PREFIX_FINALIZE, group = {grid_dispatch, 1, 1}})
		dispatch_compute(frame, {mode = .SCATTER, group = {body_dispatch, 1, 1}})
		for iter: u32 = 0; iter < PHYS_SOLVER_ITERATIONS; iter += 1 {
			compute_push_constants.solver_iteration = iter
			dispatch_compute(frame, {mode = .ZERO_DELTAS, group = {body_dispatch, 1, 1}})
			dispatch_compute(frame, {mode = .CONSTRAINTS, group = {body_dispatch, 1, 1}})
			dispatch_compute(frame, {mode = .APPLY_DELTAS, group = {body_dispatch, 1, 1}})
		}
	}

	dispatch_compute(frame, {mode = .FINALIZE, group = {body_dispatch, 1, 1}})
	// ---- Prepare accumulation buffer ----
	zero_buffer(frame, &buffers.data[0])
	transfer_to_compute_barrier(frame.cmd, &buffers.data[0])

	dispatch_compute(frame, {mode = .RENDER, group = {pixel_dispatch, 1, 1}})
}

// accumulation_buffer -> post_process.hlsl -> swapchain image
composite_to_swapchain :: proc(frame: FrameInputs, element: ^SwapchainElement) {
	apply_compute_to_fragment_barrier(frame.cmd, &buffers.data[0])
	begin_rendering(frame, element)
	bind(
		frame,
		&render_shader_states[1],
		.GRAPHICS,
		&PostProcessPushConstants {
			screen_width = u32(window_width),
			screen_height = u32(window_height),
		},
	)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRendering(frame.cmd)
	transition_swapchain_image_layout(frame.cmd, element, .PRESENT_SRC_KHR)
}
