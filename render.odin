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

DISPATCH_CAMERA_UPDATE :: u32(0)
DISPATCH_INITIALIZE :: u32(1)
DISPATCH_CLEAR_GRID :: u32(2)
DISPATCH_SPAWN_PROJECTILE :: u32(3)
DISPATCH_INTEGRATE :: u32(4)
DISPATCH_HISTOGRAM :: u32(5)
DISPATCH_PREFIX_COPY :: u32(6)
DISPATCH_PREFIX_SCAN :: u32(7)
DISPATCH_PREFIX_COPY_SOURCE :: u32(8)
DISPATCH_PREFIX_FINALIZE :: u32(9)
DISPATCH_SCATTER :: u32(10)
DISPATCH_ZERO_DELTAS :: u32(11)
DISPATCH_CONSTRAINTS :: u32(12)
DISPATCH_APPLY_DELTAS :: u32(13)
DISPATCH_FINALIZE :: u32(14)
DISPATCH_RENDER :: u32(15)

EXPLOSION_EVENT_CAPACITY :: u32(256)

CameraStateGPU :: struct {
	position:    [2]f32,
	zoom:        f32,
	pad0:        f32,
	initialized: u32,
	pad1:        [3]u32,
}

accumulation_buffer: BufferResource
camera_state_buffer: BufferResource
body_pos_buffer: BufferResource
body_pos_pred_buffer: BufferResource
body_vel_buffer: BufferResource
body_radius_buffer: BufferResource
body_inv_mass_buffer: BufferResource
body_active_buffer: BufferResource
body_delta_buffer: BufferResource
cell_counts_buffer: BufferResource
cell_offsets_buffer: BufferResource
cell_scratch_buffer: BufferResource
sorted_indices_buffer: BufferResource
spawn_state_buffer: BufferResource

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
	spawn_projectile:        u32,
	mouse_ndc_x:             f32,
	mouse_ndc_y:             f32,
	projectile_pool:         u32,
	_pad0:                   u32,
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

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants
physics_initialized: bool

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	destroy_buffer(&camera_state_buffer)
	destroy_buffer(&body_pos_buffer)
	destroy_buffer(&body_pos_pred_buffer)
	destroy_buffer(&body_vel_buffer)
	destroy_buffer(&body_radius_buffer)
	destroy_buffer(&body_inv_mass_buffer)
	destroy_buffer(&body_active_buffer)
	destroy_buffer(&body_delta_buffer)
	destroy_buffer(&cell_counts_buffer)
	destroy_buffer(&cell_offsets_buffer)
	destroy_buffer(&cell_scratch_buffer)
	destroy_buffer(&sorted_indices_buffer)
	destroy_buffer(&spawn_state_buffer)

	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		4 *
		vk.DeviceSize(size_of(u32)), // 4 channels (RGBA)
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	create_buffer(
		&camera_state_buffer,
		vk.DeviceSize(size_of(CameraStateGPU)),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	body_vec2_size := vk.DeviceSize(size_of(f32) * 2)
	body_scalar_size := vk.DeviceSize(size_of(f32))
	body_uint_size := vk.DeviceSize(size_of(u32))
	body_capacity_size := vk.DeviceSize(PHYS_MAX_BODIES)
	grid_cell_size := vk.DeviceSize(GRID_CELL_COUNT)

	create_buffer(
		&body_pos_buffer,
		body_capacity_size * body_vec2_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_pos_pred_buffer,
		body_capacity_size * body_vec2_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_vel_buffer,
		body_capacity_size * body_vec2_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_radius_buffer,
		body_capacity_size * body_scalar_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_inv_mass_buffer,
		body_capacity_size * body_scalar_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_active_buffer,
		body_capacity_size * body_uint_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&body_delta_buffer,
		body_capacity_size * body_vec2_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&cell_counts_buffer,
		grid_cell_size * body_uint_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&cell_offsets_buffer,
		(vk.DeviceSize(GRID_CELL_COUNT + 1) * body_uint_size),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&cell_scratch_buffer,
		grid_cell_size * body_uint_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&sorted_indices_buffer,
		body_capacity_size * body_uint_size,
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	create_buffer(
		&spawn_state_buffer,
		vk.DeviceSize(size_of(SpawnStateGPU)),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)

	render_shader_configs[0] = {
		compute_module = "compute.spv",
		push = PushConstantInfo {
			label = "ComputePushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(ComputePushConstants)),
		},
	}

	render_shader_configs[1] = {
		vertex_module = "graphics_vs.spv",
		fragment_module = "graphics_fs.spv",
		push = PushConstantInfo {
			label = "PostProcessPushConstants",
			stage = {vk.ShaderStageFlag.VERTEX, vk.ShaderStageFlag.FRAGMENT},
			size = u32(size_of(PostProcessPushConstants)),
		},
	}

	compute_push_constants = ComputePushConstants {
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


	bind_resource(0, &accumulation_buffer)
	bind_resource(0, &camera_state_buffer, 3)
	bind_resource(0, &body_pos_buffer, 20)
	bind_resource(0, &body_pos_pred_buffer, 21)
	bind_resource(0, &body_vel_buffer, 22)
	bind_resource(0, &body_radius_buffer, 23)
	bind_resource(0, &body_inv_mass_buffer, 24)
	bind_resource(0, &body_active_buffer, 25)
	bind_resource(0, &body_delta_buffer, 26)
	bind_resource(0, &spawn_state_buffer, 27)
	bind_resource(0, &cell_counts_buffer, 30)
	bind_resource(0, &cell_offsets_buffer, 31)
	bind_resource(0, &cell_scratch_buffer, 32)
	bind_resource(0, &sorted_indices_buffer, 33)

	post_process_push_constants = PostProcessPushConstants {
		screen_width  = u32(window_width),
		screen_height = u32(window_height),
	}
	physics_initialized = false

	return true

}

resize :: proc() {
	destroy_buffer(&accumulation_buffer)
	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		4 *
		vk.DeviceSize(size_of(u32)),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)
	bind_resource(0, &accumulation_buffer)
}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	simulate_particles(frame)
	composite_to_swapchain(frame, element)
}

// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {

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

	mouse_x, mouse_y := get_mouse_position()
	width := max(f64(window_width), 1.0)
	height := max(f64(window_height), 1.0)
	compute_push_constants.mouse_ndc_x = f32(clamp(mouse_x / width, 0.0, 1.0))
	compute_push_constants.mouse_ndc_y = f32(clamp(mouse_y / height, 0.0, 1.0))

	fire_pressed := is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT)
	compute_push_constants.spawn_projectile = fire_pressed ? u32(1) : u32(0)

	total_pixels := u32(window_width) * u32(window_height)
	pixel_dispatch := (total_pixels + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	body_dispatch := (PHYS_MAX_BODIES + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	grid_dispatch := (GRID_CELL_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE

	substep_count_f := f32(PHYS_SUBSTEPS)
	if substep_count_f <= 0.0 {
		substep_count_f = 1.0
	}
	physics_dt := frame.delta_time / substep_count_f
	if physics_dt < 0.0 {
		physics_dt = 0.0
	}

	// Camera update pass
	compute_push_constants.options = CAMERA_UPDATE_FLAG
	compute_push_constants.dispatch_mode = DISPATCH_CAMERA_UPDATE
	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, 1, 1, 1)
	compute_barrier(frame.cmd)

	// Physics initialization (once per resource lifetime)
	if !physics_initialized {
		compute_push_constants.options = 0
		compute_push_constants.dispatch_mode = DISPATCH_INITIALIZE
		compute_push_constants.solver_iteration = 0
		compute_push_constants.substep_index = 0
		compute_push_constants.scan_offset = 0
		compute_push_constants.scan_source = 0
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
		compute_barrier(frame.cmd)
		physics_initialized = true
	}

	compute_push_constants.options = 0
	compute_push_constants.solver_iteration = 0
	compute_push_constants.substep_index = 0

	for substep_index: u32 = 0; substep_index < PHYS_SUBSTEPS; substep_index += 1 {
		compute_push_constants.substep_index = substep_index
		compute_push_constants.delta_time = physics_dt

		// Clear cell counters
		compute_push_constants.dispatch_mode = DISPATCH_CLEAR_GRID
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		// Spawn request
		if compute_push_constants.spawn_projectile != 0 {
			compute_push_constants.dispatch_mode = DISPATCH_SPAWN_PROJECTILE
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, 1, 1, 1)
			compute_barrier(frame.cmd)
			compute_push_constants.spawn_projectile = 0
		}

		// Integrate and predict
		compute_push_constants.dispatch_mode = DISPATCH_INTEGRATE
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		// Histogram (cell population)
		compute_push_constants.dispatch_mode = DISPATCH_HISTOGRAM
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		// Prefix sum preparation
		compute_push_constants.dispatch_mode = DISPATCH_PREFIX_COPY
		compute_push_constants.scan_source = 0
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		parity: u32 = 0
		offset: u32 = 1
		for offset < GRID_CELL_COUNT {
			compute_push_constants.dispatch_mode = DISPATCH_PREFIX_SCAN
			compute_push_constants.scan_offset = offset
			compute_push_constants.scan_source = parity
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
			compute_barrier(frame.cmd)

			parity = 1 - parity
			offset <<= 1
		}

		if parity == 0 {
			compute_push_constants.dispatch_mode = DISPATCH_PREFIX_COPY_SOURCE
			compute_push_constants.scan_source = 0
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
			compute_barrier(frame.cmd)
			parity = 1
		}

		compute_push_constants.dispatch_mode = DISPATCH_PREFIX_FINALIZE
		compute_push_constants.scan_source = parity
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, grid_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		// Scatter bodies into sorted list
		compute_push_constants.dispatch_mode = DISPATCH_SCATTER
		bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
		vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
		compute_barrier(frame.cmd)

		for iter: u32 = 0; iter < PHYS_SOLVER_ITERATIONS; iter += 1 {
			compute_push_constants.solver_iteration = iter

			compute_push_constants.dispatch_mode = DISPATCH_ZERO_DELTAS
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
			compute_barrier(frame.cmd)

			compute_push_constants.dispatch_mode = DISPATCH_CONSTRAINTS
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
			compute_barrier(frame.cmd)

			compute_push_constants.dispatch_mode = DISPATCH_APPLY_DELTAS
			bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
			vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
			compute_barrier(frame.cmd)
		}
	}

	compute_push_constants.dispatch_mode = DISPATCH_FINALIZE
	compute_push_constants.solver_iteration = 0
	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, body_dispatch, 1, 1)
	compute_barrier(frame.cmd)

	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)
	transfer_to_compute_barrier(frame.cmd, &accumulation_buffer)

	compute_push_constants.dispatch_mode = DISPATCH_RENDER
	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, pixel_dispatch, 1, 1)
}

// accumulation_buffer -> post_process.hlsl -> swapchain image
composite_to_swapchain :: proc(frame: FrameInputs, element: ^SwapchainElement) {

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
	transition_swapchain_image_layout(frame.cmd, element, vk.ImageLayout.PRESENT_SRC_KHR)
}

cleanup_render_resources :: proc() {
	destroy_buffer(&spawn_state_buffer)
	destroy_buffer(&sorted_indices_buffer)
	destroy_buffer(&cell_scratch_buffer)
	destroy_buffer(&cell_offsets_buffer)
	destroy_buffer(&cell_counts_buffer)
	destroy_buffer(&body_delta_buffer)
	destroy_buffer(&body_active_buffer)
	destroy_buffer(&body_inv_mass_buffer)
	destroy_buffer(&body_radius_buffer)
	destroy_buffer(&body_vel_buffer)
	destroy_buffer(&body_pos_pred_buffer)
	destroy_buffer(&body_pos_buffer)
	destroy_buffer(&camera_state_buffer)
	destroy_buffer(&accumulation_buffer)
	physics_initialized = false
}
