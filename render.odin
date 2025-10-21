package main

import "base:runtime"
import "core:bytes"
import "core:c"
import "core:fmt"
import image "core:image"
import png "core:image/png"
import "vendor:glfw"
import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(5000)
// Dynamic particle count based on screen size for consistent performance
get_adaptive_particle_count :: proc() -> u32 {
	w := u32(window_width)
	h := u32(window_height)
	if w == 0 {w = 1}
	if h == 0 {h = 1}
	return w * h
}
COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2

// Fixed world dimensions - particles live in this coordinate space
WORLD_WIDTH :: u32(1920)
WORLD_HEIGHT :: u32(1080)

accumulation_buffer: BufferResource
fluid_state_buffer: BufferResource
color_history_buffer: BufferResource
sprite_texture: TextureResource
extra_data_buffer: BufferResource


PostProcessPushConstants :: struct {
	screen_width:  u32,
	screen_height: u32,
}

ComputePushConstants :: struct {
	time:           f32,
	delta_time:     f32,
	particle_count: u32,
	_pad0:          u32,
	screen_width:   u32,
	screen_height:  u32,
	brightness:     f32,
	mouse_x:        f32,
	mouse_y:        f32,
	mouse_left:     u32,
	mouse_right:    u32,
	_pad1:          u32,
}

GlobalData :: struct {
	prev_mouse_x:    f32,
	prev_mouse_y:    f32,
	prev_mouse_down: f32,
	frame_count:     f32,
	ping:            u32,
	pad0:            f32,
	pad1:            f32,
	pad2:            f32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	destroy_buffer(&fluid_state_buffer)
	destroy_buffer(&color_history_buffer)
	destroy_buffer(&extra_data_buffer)
	destroy_texture(&sprite_texture)

	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		4 *
		vk.DeviceSize(size_of(u32)), // 4 channels (RGBA)
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	create_buffer(
		&fluid_state_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		vk.DeviceSize(size_of(f32) * 4 * 2),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	create_buffer(
		&color_history_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		vk.DeviceSize(size_of(f32) * 4 * 2),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	create_buffer(
		&extra_data_buffer,
		vk.DeviceSize(size_of(GlobalData)),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)


	sprite_texture = create_texture_from_png("test3.png") or_return

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

	adaptive_count := get_adaptive_particle_count()
	compute_push_constants = ComputePushConstants {
		screen_width   = u32(window_width),
		screen_height  = u32(window_height),
		particle_count = adaptive_count,
		brightness     = 1.0,
	}

	post_process_push_constants = PostProcessPushConstants {
		screen_width  = u32(window_width),
		screen_height = u32(window_height),
	}

	bind_resource(0, &accumulation_buffer)
	bind_resource(1, &fluid_state_buffer)
	bind_resource(2, &color_history_buffer)
	bind_resource(0, &sprite_texture)
	bind_resource(0, &sprite_texture.sampler)
	bind_resource(0, &extra_data_buffer, 3)


	return true

}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	simulate_particles(frame)
	composite_to_swapchain(frame, element)
}

// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)

	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time
	compute_push_constants.screen_width = u32(window_width)
	compute_push_constants.screen_height = u32(window_height)

	mouse_left_pressed := is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT)
	mouse_right_pressed := is_mouse_button_pressed(glfw.MOUSE_BUTTON_RIGHT)

	compute_push_constants.mouse_x = f32(mouse_x)
	compute_push_constants.mouse_y = f32(mouse_y)
	compute_push_constants.mouse_left = u32(mouse_left_pressed)
	compute_push_constants.mouse_right = u32(mouse_right_pressed)

	adaptive_count := get_adaptive_particle_count()
	compute_push_constants.particle_count = adaptive_count

	bind(frame, &render_shader_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, (adaptive_count + 128 - 1) / 128, 1, 1)
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
	destroy_buffer(&fluid_state_buffer)
	destroy_buffer(&color_history_buffer)
	destroy_buffer(&extra_data_buffer)
	destroy_buffer(&accumulation_buffer)
	destroy_texture(&sprite_texture)
}
