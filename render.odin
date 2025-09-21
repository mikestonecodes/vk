package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import image "core:image"
import png "core:image/png"

import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(980_000)
COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 2

// Fixed world dimensions - particles live in this coordinate space
WORLD_WIDTH :: u32(7680)
WORLD_HEIGHT :: u32(4320)

accumulation_buffer: BufferResource
sprite_texture: TextureResource
sprite_texture_width: u32
sprite_texture_height: u32

TextureUploadContext :: struct {
	texture: ^TextureResource,
	staging: ^BufferResource,
	width:   u32,
	height:  u32,
}

PostProcessPushConstants :: struct {
	time:              f32,
	exposure:          f32,
	gamma:             f32,
	contrast:          f32,
	screen_width:      u32,
	screen_height:     u32,
	vignette_strength: f32,
	_pad0:             f32,
	world_width:       u32,
	world_height:      u32,
	_pad1:             u32,
	_pad2:             u32,
}


ComputePushConstants :: struct {
	time:           f32,
	delta_time:     f32,
	particle_count: u32,
	_pad0:          u32,
	screen_width:   u32,
	screen_height:  u32,
	spread:         f32,
	brightness:     f32,
	sprite_width:   u32,
	sprite_height:  u32,
	total_threads:  u32, // <--- add this
	camera_zoom:    u32,
	camera_pos:     u32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	destroy_texture(&sprite_texture)
	sprite_texture_width = 0
	sprite_texture_height = 0


	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(window_width) *
		vk.DeviceSize(window_height) *
		4 *
		vk.DeviceSize(size_of(u32)), // 4 channels
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	sprite_texture = create_texture_from_png("test3.png") or_return
	update_bindless_texture(0, &sprite_texture) or_return

	sprite_texture_width = sprite_texture.width
	sprite_texture_height = sprite_texture.height

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

	compute_push_constants = ComputePushConstants {
		screen_width   = u32(width),
		screen_height  = u32(height),
		particle_count = PARTICLE_COUNT,
		spread         = 1.0,
		brightness     = 1.0,
		camera_zoom    = 1.0,
		sprite_width   = sprite_texture_width,
		sprite_height  = sprite_texture_height,
	}

	post_process_push_constants = PostProcessPushConstants {
		screen_width      = u32(width),
		screen_height     = u32(height),
		exposure          = 1.2,
		gamma             = 2.2,
		contrast          = 1.0,
		vignette_strength = 0.35,
		world_width       = WORLD_WIDTH,
		world_height      = WORLD_HEIGHT,
	}

	update_global_descriptors() or_return
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
	compute_push_constants.spread = 4.0 // try 2..8
	compute_push_constants.brightness = 1.0

	bind(frame, &render_pipeline_states[0], .COMPUTE, &compute_push_constants)
	vk.CmdDispatch(frame.cmd, (PARTICLE_COUNT + 128 - 1) / 128, 1, 1)

}


// accumulation_buffer -> post_process.hlsl -> swapchain framebuffer
composite_to_swapchain :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {

	apply_compute_to_fragment_barrier(frame.cmd, &accumulation_buffer)
	begin_render_pass(frame, framebuffer)
	post_process_push_constants.time = frame.time
	post_process_push_constants.screen_width = u32(window_width)
	post_process_push_constants.screen_height = u32(window_height)
	bind(frame, &render_pipeline_states[1], .GRAPHICS, &post_process_push_constants)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRenderPass(frame.cmd)
}

cleanup_render_resources :: proc() {
	destroy_buffer(&accumulation_buffer)
	destroy_texture(&sprite_texture)
}
