package main

import vk "vendor:vulkan"

COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2
// Physics configuration
PHYS_MAX_BODIES :: u32(512000)
PHYS_SOLVER_ITERATIONS :: u32(4)
PHYS_SUBSTEPS :: u32(1)
GRID_X :: u32(512)
GRID_Y :: u32(512)
GRID_CELL_COUNT :: u32(GRID_X * GRID_Y)

// Global state buffer to avoid small allocation warnings
GlobalStateGPU :: struct {
	camera_position: [2]f32,
	camera_zoom:     f32,
	_pad0:           f32,
	spawn_next:      u32,
	spawn_active:    u32,
	_pad1:           u32,
	_pad2:           u32,
}

PostProcessPushConstants :: struct {
	screen_width:  u32,
	screen_height: u32,
}
post_process_push_constants := PostProcessPushConstants{}

ComputePushConstants :: struct {
	time:          f32,
	delta_time:    f32,
	screen_width:  u32,
	screen_height: u32,
	move_forward:  b32,
	move_backward: b32,
	move_right:    b32,
	move_left:     b32,
	zoom_in:       b32,
	zoom_out:      b32,
	speed:         b32,
	reset_camera:  b32,
	dispatch_mode: u32,
	scan_offset:   u32,
	scan_source:   u32,
	spawn_body:    b32,
	mouse_ndc_x:   f32,
	mouse_ndc_y:   f32,
	_pad0:         u32,
	_pad1:         u32,
}

compute_push_constants := ComputePushConstants {}


DispatchMode :: enum u32 {
	BEGIN_FRAME,
	INITIALIZE,
	CLEAR_GRID,
	INTEGRATE,
	HISTOGRAM,
	PREFIX_COPY,
	PREFIX_SCAN,
	PREFIX_COPY_SOURCE,
	PREFIX_FINALIZE,
	SCATTER,
	ZERO_DELTAS,
	CONSTRAINTS,
	APPLY_DELTAS,
	FINALIZE,
	RENDER,
}

body_vec2_size := DeviceSize(size_of(f32) * 2)
body_scalar_size := DeviceSize(size_of(f32))
body_uint_size := DeviceSize(size_of(u32))
body_capacity_size := DeviceSize(PHYS_MAX_BODIES)
grid_cell_size := DeviceSize(GRID_CELL_COUNT)


buffer_specs := []struct {
	size:        DeviceSize,
	flags:       BufferUsageFlags,
	binding:     u32,
	stage_flags: ShaderStageFlags,
} {
	{
		DeviceSize(window_width * window_height * 4 * size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
		0,
		{.COMPUTE, .FRAGMENT},
	},
	{DeviceSize(size_of(GlobalStateGPU)), {.STORAGE_BUFFER, .TRANSFER_DST}, 3, {.COMPUTE}},
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 20, {.COMPUTE}}, //body_pos
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 21, {.COMPUTE}}, //body_pos_pred
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 22, {.COMPUTE}}, //body_vel
	{body_capacity_size * body_scalar_size, {.STORAGE_BUFFER}, 23, {.COMPUTE}}, //body_radius
	{body_capacity_size * body_scalar_size, {.STORAGE_BUFFER}, 24, {.COMPUTE}}, //body_inv_mass
	{body_capacity_size * body_uint_size, {.STORAGE_BUFFER}, 25, {.COMPUTE}}, //body_flags
	{body_capacity_size * body_vec2_size, {.STORAGE_BUFFER}, 26, {.COMPUTE}}, //body_delta
	{grid_cell_size * body_uint_size, {.STORAGE_BUFFER}, 30, {.COMPUTE}}, //grid_count
	{DeviceSize(GRID_CELL_COUNT + 1) * body_uint_size, {.STORAGE_BUFFER}, 31, {.COMPUTE}}, //grid_offset
	{grid_cell_size * body_uint_size, {.STORAGE_BUFFER}, 32, {.COMPUTE}}, //grid_scan
	{body_capacity_size * body_uint_size, {.STORAGE_BUFFER}, 33, {.COMPUTE}}, //body_grid_index
}

DescriptorBindingSpec :: struct {
	binding:          u32,
	descriptor_type:  DescriptorType,
	descriptor_count: u32,
	stage_flags:      ShaderStageFlags,
}

global_descriptor_extras :: []DescriptorBindingSpec {
	{1, .SAMPLED_IMAGE, 2, {.FRAGMENT}},
	{2, .SAMPLER, 2, {.FRAGMENT}},
}


render_shader_configs := []ShaderProgramConfig {
	{
		compute_module = "compute.spv",
		push = {stage = {.COMPUTE}, size = u32(size_of(ComputePushConstants))},
	},
	{
		vertex_module = "graphics_vs.spv",
		fragment_module = "graphics_fs.spv",
		push = {stage = {.VERTEX, .FRAGMENT}, size = u32(size_of(PostProcessPushConstants))},
	},
}

key_bindings := []struct {
	key:   i32,
	field: ^b32,
} {
	{i32(KEY_W), &compute_push_constants.move_forward},
	{i32(KEY_S), &compute_push_constants.move_backward},
	{i32(KEY_D), &compute_push_constants.move_right},
	{i32(KEY_A), &compute_push_constants.move_left},
	{i32(KEY_E), &compute_push_constants.zoom_in},
	{i32(KEY_Q), &compute_push_constants.zoom_out},
	{i32(KEY_T), &compute_push_constants.speed},
	{i32(KEY_R), &compute_push_constants.reset_camera},
}


resize :: proc() -> bool  {
	destroy_buffer(&buffers.data[0])
	create_buffer(
		&buffers.data[0],
		DeviceSize(window_width) * DeviceSize(window_height) * 4 * DeviceSize(size_of(u32)),
		{.STORAGE_BUFFER, .TRANSFER_DST},
	)
	bind_resource(0, &buffers.data[0])

	compute_push_constants.screen_width = u32(window_width)
	compute_push_constants.screen_height = u32(window_height)
	post_process_push_constants.screen_width = u32(window_width)
	post_process_push_constants.screen_height = u32(window_height)
	return true
}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	compute(frame)
	graphics(frame, element)
}

physics_initialized: bool

// compute.hlsl -> accumulation_buffer
compute :: proc(frame: FrameInputs) {
	mouse_x, mouse_y := get_mouse_position()
	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time


	for binding in key_bindings {
		binding.field^ = b32(is_key_pressed(binding.key))
	}

	compute_push_constants.spawn_body = b32(is_mouse_button_pressed(MOUSE_BUTTON_LEFT))
	compute_push_constants.mouse_ndc_x = f32(
		clamp(mouse_x / max(f64(window_width), 1.0), 0.0, 1.0),
	)
	compute_push_constants.mouse_ndc_y = f32(
		clamp(mouse_y / max(f64(window_height), 1.0), 0.0, 1.0),
	)


	// ---- Camera update ----
	dispatch_compute(frame, .BEGIN_FRAME, 1)

	total_pixels := u32(window_width) * u32(window_height)
	pixel_dispatch := (total_pixels + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	physics(frame, pixel_dispatch)

	dispatch_compute(frame, .RENDER, pixel_dispatch)
}

prefix_scan :: proc(frame: FrameInputs, grid_dispatch: u32) {
	parity: u32 = 0
	offset: u32 = 1
	for offset < GRID_CELL_COUNT {
		compute_push_constants.scan_offset = offset
		compute_push_constants.scan_source = parity
		dispatch_compute(frame, .PREFIX_SCAN, grid_dispatch)
		parity = 1 - parity
		offset <<= 1
	}
	if parity == 0 {
		dispatch_compute(frame, .PREFIX_COPY_SOURCE, grid_dispatch)
		parity = 1
	}
	compute_push_constants.scan_source = parity
}

physics :: proc(frame: FrameInputs, pixel_dispatch: u32) {

	substep_count_f := f32(PHYS_SUBSTEPS)
	if substep_count_f <= 0.0 {substep_count_f = 1.0}
	physics_dt := frame.delta_time / substep_count_f
	if physics_dt < 0.0 {physics_dt = 0.0}

	if !physics_initialized {
		dispatch_compute(frame, .INITIALIZE, 1)
		physics_initialized = true
	}

	body_dispatch := (PHYS_MAX_BODIES + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	grid_dispatch := (GRID_CELL_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	// ---- Substeps ----
	for substep_index: u32 = 0; substep_index < PHYS_SUBSTEPS; substep_index += 1 {
		compute_push_constants.delta_time = physics_dt

		dispatch_compute(frame, .CLEAR_GRID, grid_dispatch)
		dispatch_compute(frame, .INTEGRATE, body_dispatch)
		dispatch_compute(frame, .HISTOGRAM, body_dispatch)
		dispatch_compute(frame, .PREFIX_COPY, grid_dispatch)

		prefix_scan(frame, grid_dispatch)
		dispatch_compute(frame, .PREFIX_FINALIZE, grid_dispatch)
		dispatch_compute(frame, .SCATTER, body_dispatch)
		for iter: u32 = 0; iter < PHYS_SOLVER_ITERATIONS; iter += 1 {
			dispatch_compute(frame, .ZERO_DELTAS, body_dispatch)
			dispatch_compute(frame, .CONSTRAINTS, body_dispatch)
			dispatch_compute(frame, .APPLY_DELTAS, body_dispatch)
		}
	}
	dispatch_compute(frame, .FINALIZE, body_dispatch)


}

// accumulation_buffer -> post_process.hlsl -> swapchain image
graphics :: proc(frame: FrameInputs, element: ^SwapchainElement) {

//	apply_compute_to_fragment_barrier(frame.cmd, &buffers.data[0])
	begin_rendering(frame, element)
	bind(
		frame,
		&render_shader_states[1],
		.GRAPHICS,
		&PostProcessPushConstants{u32(window_width), u32(window_height)},
	)
	draw(frame, 3, 1, 0, 0)
	end_rendering(frame)
}
