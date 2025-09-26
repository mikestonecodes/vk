package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import image "core:image"
import png "core:image/png"
import "vendor:glfw"
import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(1_000_000)
// Dynamic particle count based on screen size for consistent performance
get_adaptive_particle_count :: proc() -> u32 {
	pixel_count := window_width * window_height
	base_count : u32 = 1_000_000
	// Scale particle count to maintain consistent density regardless of resolution
	scale_factor := f32(pixel_count) / f32(1920 * 1080) // Scale proportionally to screen area
	return u32(f32(base_count) * scale_factor)
}
COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2

// Fixed world dimensions - particles live in this coordinate space
WORLD_WIDTH :: u32(7680)
WORLD_HEIGHT :: u32(4320)

accumulation_buffer: BufferResource
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
	key_h:          u32,
	key_j:          u32,
	key_k:          u32,
	key_l:          u32,
	key_w:          u32,
	key_a:          u32,
	key_s:          u32,
	key_d:          u32,
	key_q:          u32,
	key_e:          u32,
}

GlobalData :: struct {
	camPos_x: f32,
	camPos_y: f32,
	zoom:     f32,
	padding:  f32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	destroy_buffer(&extra_data_buffer)
	destroy_texture(&sprite_texture)

	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		4 *
		vk.DeviceSize(size_of(u32)), // 4 channels
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	create_buffer(
		&extra_data_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		vk.DeviceSize(size_of(GlobalData)), // 4 channels
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)


	sprite_texture = create_texture_from_png("test3.png") or_return

	render_pipeline_specs[0] = {
		name = "particles",
		compute_module = "compute.spv",
		push = PushConstantInfo {
			label = "ComputePushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(ComputePushConstants)),
		},
	}

	render_pipeline_specs[1] = {
		name = "graphics",
		vertex_module = "graphics_vs.spv",
		fragment_module = "graphics_fs.spv",
		push = PushConstantInfo {
			label = "PostProcessPushConstants",
			stage = {vk.ShaderStageFlag.FRAGMENT},
			size = u32(size_of(PostProcessPushConstants)),
		},
	}

	adaptive_count := get_adaptive_particle_count()
	compute_push_constants = ComputePushConstants {
		screen_width   = u32(width),
		screen_height  = u32(height),
		particle_count = adaptive_count,
		brightness     = 1.0,
	}

	post_process_push_constants = PostProcessPushConstants {
		screen_width  = u32(width),
		screen_height = u32(height),
	}

	bind_resource(0, &accumulation_buffer)
	bind_resource(0, &sprite_texture)
	bind_resource(0, &sprite_texture.sampler)
	bind_resource(0, &extra_data_buffer, 3)


	return true

}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	simulate_particles(frame)
	composite_to_swapchain(frame, element.framebuffer)
}

// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)
	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time
	compute_push_constants.screen_width = u32(window_width)
	compute_push_constants.screen_height = u32(window_height)
	compute_push_constants.mouse_x = f32(mouse_x)
	compute_push_constants.mouse_y = f32(mouse_y)
	compute_push_constants.mouse_left = is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT) ? 1 : 0
	compute_push_constants.mouse_right = is_mouse_button_pressed(glfw.MOUSE_BUTTON_RIGHT) ? 1 : 0
	compute_push_constants.key_h = is_key_pressed(glfw.KEY_H) ? 1 : 0
	compute_push_constants.key_j = is_key_pressed(glfw.KEY_J) ? 1 : 0
	compute_push_constants.key_k = is_key_pressed(glfw.KEY_K) ? 1 : 0
	compute_push_constants.key_l = is_key_pressed(glfw.KEY_L) ? 1 : 0
	compute_push_constants.key_w = is_key_pressed(glfw.KEY_W) ? 1 : 0
	compute_push_constants.key_a = is_key_pressed(glfw.KEY_A) ? 1 : 0
	compute_push_constants.key_s = is_key_pressed(glfw.KEY_S) ? 1 : 0
	compute_push_constants.key_d = is_key_pressed(glfw.KEY_D) ? 1 : 0
	compute_push_constants.key_q = is_key_pressed(glfw.KEY_Q) ? 1 : 0
	compute_push_constants.key_e = is_key_pressed(glfw.KEY_E) ? 1 : 0
	bind(frame, &render_pipeline_states[0], .COMPUTE, &compute_push_constants)
	adaptive_count := get_adaptive_particle_count()
	compute_push_constants.particle_count = adaptive_count
	vk.CmdDispatch(frame.cmd, (adaptive_count + 128 - 1) / 128, 1, 1)
}


// accumulation_buffer -> post_process.hlsl -> swapchain framebuffer
composite_to_swapchain :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {

	apply_compute_to_fragment_barrier(frame.cmd, &accumulation_buffer)
	begin_render_pass(frame, framebuffer)
	post_process_push_constants.screen_width = u32(window_width)
	post_process_push_constants.screen_height = u32(window_height)
	bind(frame, &render_pipeline_states[1], .GRAPHICS, &post_process_push_constants)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRenderPass(frame.cmd)
}

cleanup_render_resources :: proc() {
	destroy_buffer(&extra_data_buffer)
	destroy_buffer(&accumulation_buffer)
	destroy_texture(&sprite_texture)
}
