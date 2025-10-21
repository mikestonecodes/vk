package main

import "vendor:glfw"
import vk "vendor:vulkan"

COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2

CAMERA_UPDATE_FLAG :: u32(1 << 0)

CameraStateGPU :: struct {
	position:   [2]f32,
	zoom:       f32,
	pad0:       f32,
	initialized: u32,
	pad1:       [3]u32,
}

accumulation_buffer: BufferResource
camera_state_buffer: BufferResource

PostProcessPushConstants :: struct {
	screen_width:  u32,
	screen_height: u32,
}

ComputePushConstants :: struct {
	time:          f32,
	delta_time:    f32,
	screen_width:  u32,
	screen_height: u32,
	brightness:    f32,
	move_forward:  b32,
	move_backward: b32,
	move_right:    b32,
	move_left:     b32,
	zoom_in:       b32,
	zoom_out:      b32,
	speed:         b32,
	reset_camera:  b32,
	options:       u32,
	_pad0:         u32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)

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
		screen_width   = u32(window_width),
		screen_height  = u32(window_height),
		brightness     = 1.0,
	}

	post_process_push_constants = PostProcessPushConstants {
		screen_width  = u32(window_width),
		screen_height = u32(window_height),
	}

	bind_resource(0, &accumulation_buffer)
	bind_resource(0, &camera_state_buffer, 3)

	return true

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
	compute_push_constants.options = CAMERA_UPDATE_FLAG

	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, 1, 1, 1)

	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)

	compute_push_constants.options = 0

	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	total_pixels := u32(window_width) * u32(window_height)
	dispatch_x := (total_pixels + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE
	vk.CmdDispatch(frame.cmd, dispatch_x, 1, 1)
}

// accumulation_buffer -> post_process.hlsl -> swapchain image
composite_to_swapchain :: proc(frame: FrameInputs, element: ^SwapchainElement) {

	begin_rendering(frame,element)
	bind(frame, &render_shader_states[1], .GRAPHICS, &PostProcessPushConstants{
		screen_width = u32(window_width),
		screen_height = u32(window_height),
	})
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRendering(frame.cmd)
	transition_swapchain_image_layout(frame.cmd, element, vk.ImageLayout.PRESENT_SRC_KHR)
}

cleanup_render_resources :: proc() {
	destroy_buffer(&camera_state_buffer)
	destroy_buffer(&accumulation_buffer)
}
