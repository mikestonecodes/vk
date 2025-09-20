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

accumulation_buffer: BufferResource
accumulation_barriers: BufferBarriers
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
	texture_width:     u32,
	texture_height:    u32,
	vignette_strength: f32,
	_pad0:             f32,
}


ComputePushConstants :: struct {
	time:           f32,
	delta_time:     f32,
	particle_count: u32,
	_pad0:          u32,
	texture_width:  u32,
	texture_height: u32,
	spread:         f32,
	brightness:     f32,
	sprite_width:   u32,
	sprite_height:  u32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	reset_buffer_barriers(&accumulation_barriers)
	destroy_texture(&sprite_texture)
	sprite_texture_width = 0
	sprite_texture_height = 0

	create_buffer(
		&accumulation_buffer,
		vk.DeviceSize(width) * vk.DeviceSize(height) * 4 * vk.DeviceSize(size_of(u32)),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	init_buffer_barriers(&accumulation_barriers, &accumulation_buffer)
	sprite_texture = create_texture_from_png("test3.png") or_return
	render_pipeline_specs[0] = {
		name = "particles",
		compute_module = "compute.spv",
		push = PushConstantInfo {
			label = "ComputePushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(ComputePushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{
				label = "accumulation-buffer",
				descriptorType = .STORAGE_BUFFER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 0,
				buffer = &accumulation_buffer,
			},
			{
				label = "sprite-texture",
				descriptorType = .SAMPLED_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 1,
				texture = &sprite_texture,
			},
			{
				label = "sprite-sampler",
				descriptorType = .SAMPLER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 2,
				sampler = &sprite_texture.sampler,
			},
			{},
		},
		descriptor_count = 3,
	}

	render_pipeline_specs[1] =  {
		name = "tone-map",
		vertex_module = "post_process_vs.spv",
		fragment_module = "post_process_fs.spv",
		push = PushConstantInfo {
			label = "PostProcessPushConstants",
			stage = {vk.ShaderStageFlag.FRAGMENT},
			size = u32(size_of(PostProcessPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{
				label = "accumulation-buffer",
				descriptorType = .STORAGE_BUFFER,
				stage = {vk.ShaderStageFlag.FRAGMENT},
				binding = 0,
				buffer = &accumulation_buffer,
			},
			{},
			{},
			{},
		},
		descriptor_count = 1,
	}
	compute_push_constants = ComputePushConstants {
		texture_width  = u32(width),
		texture_height = u32(height),
		particle_count = PARTICLE_COUNT,
		spread         = 1.0,
		brightness     = 1.0,
		sprite_width   = 999,
		sprite_height  = 999,
	}

	post_process_push_constants = PostProcessPushConstants {
		texture_width     = u32(width),
		texture_height    = u32(height),
		exposure          = 1.2,
		gamma             = 2.2,
		contrast          = 1.0,
		vignette_strength = 0.35,
	}
	return true

}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	simulate_particles(frame)
	composite_to_swapchain(frame, element.framebuffer)
}


// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)
	apply_transfer_to_compute_barrier(frame.cmd, &accumulation_barriers)

	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time
	compute_push_constants.sprite_width = sprite_texture_width
	compute_push_constants.sprite_height = sprite_texture_height
	bind(frame, &render_pipeline_states[0], .COMPUTE, &compute_push_constants)

	vk.CmdDispatch(frame.cmd, (PARTICLE_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE, 1, 1)
	apply_compute_to_fragment_barrier(frame.cmd, &accumulation_barriers)
}

// accumulation_buffer -> post_process.hlsl -> swapchain framebuffer
composite_to_swapchain :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {
	begin_render_pass(frame, framebuffer)
	post_process_push_constants.time = frame.time
	bind(frame, &render_pipeline_states[1], .GRAPHICS, &post_process_push_constants)
	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRenderPass(frame.cmd)
}

cleanup_render_resources :: proc() {
	destroy_buffer(&accumulation_buffer)
	reset_buffer_barriers(&accumulation_barriers)
	destroy_texture(&sprite_texture)
}
