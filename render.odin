package main

import "base:runtime"
import "core:bytes"
import "core:fmt"
import image "core:image"
import png "core:image/png"

import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(980_000)
COMPUTE_GROUP_SIZE :: u32(128)
PIPELINE_COUNT :: 6

// Fixed world dimensions - particles live in this coordinate space
WORLD_WIDTH :: u32(7680)
WORLD_HEIGHT :: u32(4320)

accumulation_buffer: BufferResource
accumulation_barriers: BufferBarriers
sprite_texture: TextureResource
sprite_texture_width: u32
sprite_texture_height: u32

// Mega splat resources
density_texture: TextureResource
blur_temp_texture: TextureResource
mega_splat_sampler: vk.Sampler

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
	total_threads:  u32,
	camera_zoom:    u32,
	camera_pos:     u32,
}

// Mega splat push constants (matches HLSL structure)
MegaSplatPushConstants :: struct {
	time:           f32,
	delta_time:     f32,
	particle_count: u32,
	_pad0:          u32,
	screen_width:   u32,
	screen_height:  u32,
	brightness:     f32,
	blur_radius:    u32,
	blur_sigma:     f32,
	_pad1:          u32,
	_pad2:          u32,
	_pad3:          u32,
}

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants
mega_splat_push_constants: MegaSplatPushConstants

init_render_resources :: proc() -> bool {

	destroy_buffer(&accumulation_buffer)
	reset_buffer_barriers(&accumulation_barriers)
	destroy_texture(&sprite_texture)
	destroy_texture(&density_texture)
	destroy_texture(&blur_temp_texture)
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

	init_buffer_barriers(&accumulation_barriers, &accumulation_buffer)
	sprite_texture = create_texture_from_png("test3.png") or_return

	sprite_texture_width = sprite_texture.width
	sprite_texture_height = sprite_texture.height

	// Create mega splat textures (single channel float for density)
	density_texture = create_storage_texture(u32(window_width), u32(window_height), vk.Format.R32_SFLOAT) or_return
	blur_temp_texture = create_storage_texture(u32(window_width), u32(window_height), vk.Format.R32_SFLOAT) or_return

	// Mega Splat Pipeline 0: Scatter
	render_pipeline_specs[0] = {
		name = "mega-splat-scatter",
		compute_module = "mega_splat_scatter.spv",
		push = PushConstantInfo {
			label = "MegaSplatPushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(MegaSplatPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{
				label = "density-texture",
				descriptorType = .STORAGE_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 0,
				texture = &density_texture,
			},
			{},
			{},
			{},
		},
		descriptor_count = 1,
	}

	render_pipeline_specs[1] = {
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

	// Mega Splat Pipeline 0: Scatter
	render_pipeline_specs[2] = {
		name = "mega-splat-scatter",
		compute_module = "mega_splat_scatter.spv",
		push = PushConstantInfo {
			label = "MegaSplatPushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(MegaSplatPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{
				label = "density-texture",
				descriptorType = .STORAGE_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 0,
				texture = &density_texture,
			},
			{},
			{},
			{},
		},
		descriptor_count = 1,
	}

	// Mega Splat Pipeline 1: Blur Horizontal
	render_pipeline_specs[3] = {
		name = "mega-splat-blur-h",
		compute_module = "mega_splat_blur_h.spv",
		push = PushConstantInfo {
			label = "MegaSplatPushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(MegaSplatPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{},
			{
				label = "blur-input",
				descriptorType = .SAMPLED_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 1,
				texture = &density_texture,
			},
			{
				label = "blur-output",
				descriptorType = .STORAGE_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 2,
				texture = &blur_temp_texture,
			},
			{
				label = "blur-sampler",
				descriptorType = .SAMPLER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 3,
				sampler = &density_texture.sampler,
			},
		},
		descriptor_count = 3,
	}

	// Mega Splat Pipeline 2: Blur Vertical
	render_pipeline_specs[4] = {
		name = "mega-splat-blur-v",
		compute_module = "mega_splat_blur_v.spv",
		push = PushConstantInfo {
			label = "MegaSplatPushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(MegaSplatPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{},
			{
				label = "blur-input",
				descriptorType = .SAMPLED_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 1,
				texture = &blur_temp_texture,
			},
			{
				label = "blur-output",
				descriptorType = .STORAGE_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 2,
				texture = &density_texture,
			},
			{
				label = "blur-sampler",
				descriptorType = .SAMPLER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 3,
				sampler = &blur_temp_texture.sampler,
			},
		},
		descriptor_count = 3,
	}

	// Mega Splat Pipeline 3: Colorize
	render_pipeline_specs[5] = {
		name = "mega-splat-colorize",
		compute_module = "mega_splat_colorize.spv",
		push = PushConstantInfo {
			label = "MegaSplatPushConstants",
			stage = {vk.ShaderStageFlag.COMPUTE},
			size = u32(size_of(MegaSplatPushConstants)),
		},
		descriptors = [4]DescriptorBindingInfo {
			{
				label = "blur-input",
				descriptorType = .SAMPLED_IMAGE,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 1,
				texture = &density_texture,
			},
			{},
			{
				label = "blur-sampler",
				descriptorType = .SAMPLER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 3,
				sampler = &density_texture.sampler,
			},
			{
				label = "color-output",
				descriptorType = .STORAGE_BUFFER,
				stage = {vk.ShaderStageFlag.COMPUTE},
				binding = 4,
				buffer = &accumulation_buffer,
			},
		},
		descriptor_count = 3,
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

	mega_splat_push_constants = MegaSplatPushConstants {
		screen_width   = u32(width),
		screen_height  = u32(height),
		particle_count = PARTICLE_COUNT,
		brightness     = 1.0,
		blur_radius    = 8,
		blur_sigma     = 3.0,
	}

	return true

}

record_commands :: proc(element: ^SwapchainElement, frame: FrameInputs) {
	mega_splat_particles(frame)
	composite_to_swapchain(frame, element.framebuffer)
}


// Mega Splat Pipeline: scatter -> blur_h -> blur_v -> colorize -> accumulation_buffer

mega_splat_particles :: proc(frame: FrameInputs) {
	// Clear density texture
	vk.CmdClearColorImage(frame.cmd, density_texture.image, vk.ImageLayout.GENERAL,
		&vk.ClearColorValue{float32 = {0, 0, 0, 0}}, 1,
		&vk.ImageSubresourceRange{aspectMask = {vk.ImageAspectFlag.COLOR}, levelCount = 1, layerCount = 1})

	// Clear output buffer
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer.buffer, 0, accumulation_buffer.size, 0)
	apply_transfer_to_compute_barrier(frame.cmd, &accumulation_barriers)

	// Update push constants
	mega_splat_push_constants.time = frame.time
	mega_splat_push_constants.delta_time = frame.delta_time
	mega_splat_push_constants.screen_width = u32(window_width)
	mega_splat_push_constants.screen_height = u32(window_height)

	// Compute dispatch groups
	particle_groups := (PARTICLE_COUNT + 128 - 1) / 128
	screen_groups_x := (u32(window_width) + 8 - 1) / 8
	screen_groups_y := (u32(window_height) + 8 - 1) / 8

	// Memory barrier for compute-compute transitions
	memory_barrier := vk.MemoryBarrier {
		sType = vk.StructureType.MEMORY_BARRIER,
		srcAccessMask = {vk.AccessFlag.SHADER_WRITE},
		dstAccessMask = {vk.AccessFlag.SHADER_READ},
	}

	// Stage 1: Scatter - particles write density
	bind(frame, &render_pipeline_states[0], .COMPUTE, &mega_splat_push_constants)
	vk.CmdDispatch(frame.cmd, particle_groups, 1, 1)

	// Barrier: scatter writes -> blur reads
	vk.CmdPipelineBarrier(frame.cmd,
		{vk.PipelineStageFlag.COMPUTE_SHADER}, {vk.PipelineStageFlag.COMPUTE_SHADER},
		{}, 1, &memory_barrier, 0, nil, 0, nil)

	// Stage 2: Blur Horizontal - density_texture -> blur_temp_texture
	bind(frame, &render_pipeline_states[2], .COMPUTE, &mega_splat_push_constants)
	vk.CmdDispatch(frame.cmd, screen_groups_x, screen_groups_y, 1)

	// Barrier: blur_h writes -> blur_v reads
	vk.CmdPipelineBarrier(frame.cmd,
		{vk.PipelineStageFlag.COMPUTE_SHADER}, {vk.PipelineStageFlag.COMPUTE_SHADER},
		{}, 1, &memory_barrier, 0, nil, 0, nil)

	// Stage 3: Blur Vertical - blur_temp_texture -> density_texture
	bind(frame, &render_pipeline_states[3], .COMPUTE, &mega_splat_push_constants)
	vk.CmdDispatch(frame.cmd, screen_groups_x, screen_groups_y, 1)

	// Barrier: blur_v writes -> colorize reads
	vk.CmdPipelineBarrier(frame.cmd,
		{vk.PipelineStageFlag.COMPUTE_SHADER}, {vk.PipelineStageFlag.COMPUTE_SHADER},
		{}, 1, &memory_barrier, 0, nil, 0, nil)

	// Stage 4: Colorize - density_texture -> accumulation_buffer
	bind(frame, &render_pipeline_states[4], .COMPUTE, &mega_splat_push_constants)
	vk.CmdDispatch(frame.cmd, screen_groups_x, screen_groups_y, 1)

	// Final barrier: compute writes -> fragment reads
	apply_compute_to_fragment_barrier(frame.cmd, &accumulation_barriers)
}


// accumulation_buffer -> post_process.hlsl -> swapchain framebuffer
composite_to_swapchain :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {
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
	reset_buffer_barriers(&accumulation_barriers)
	destroy_texture(&sprite_texture)
	destroy_texture(&density_texture)
	destroy_texture(&blur_temp_texture)
}
