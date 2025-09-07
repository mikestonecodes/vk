package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

PARTICLE_COUNT :: 1000000

// Simple variables
particleBuffer: vk.Buffer
particleBufferMemory: vk.DeviceMemory

offscreenImage: vk.Image
offscreenImageMemory: vk.DeviceMemory
offscreenImageView: vk.ImageView

init :: proc() {
	// Nothing to do here
}

init_render_resources :: proc() {
	Particle :: struct {
		position: [2]f32,
		color: [3]f32,
		_padding: f32,
	}

	// Create resources only - no descriptors needed
	particleBuffer, particleBufferMemory = createBuffer(PARTICLE_COUNT * size_of(Particle), {vk.BufferUsageFlag.STORAGE_BUFFER})
	offscreenImage, offscreenImageMemory, offscreenImageView = createImage(width, height, format, {vk.ImageUsageFlag.COLOR_ATTACHMENT, vk.ImageUsageFlag.SAMPLED})
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	// Create offscreen render pass and framebuffer on-demand
	offscreen_pass := create_render_pass(format)
	offscreen_fb := create_framebuffer(offscreen_pass, offscreenImageView, width, height)

	clear_value := vk.ClearValue{color = {float32 = {0.0, 0.0, 0.0, 1.0}}}

	passes := []Pass{
		compute_pass(
			"compute.wgsl",
			{u32((PARTICLE_COUNT + 63) / 64), 1, 1},
			{particleBuffer},
			&ComputePushConstants{time = elapsed_time, particle_count = PARTICLE_COUNT},
			size_of(ComputePushConstants),
		),
		graphics_pass(
			"vertex.wgsl",
			"fragment.wgsl",
			offscreen_pass,
			offscreen_fb,
			6,
			PARTICLE_COUNT,
			{particleBuffer},
			&VertexPushConstants{screen_width = f32(width), screen_height = f32(height)},
			size_of(VertexPushConstants),
			nil,
			0,
			{clear_value},
		),
		graphics_pass(
			"post_process.wgsl",
			"post_process.wgsl",
			render_pass,
			element.framebuffer,
			3,
			1,
			{struct{ image_view: vk.ImageView, sampler: vk.Sampler }{image_view = offscreenImageView, sampler = texture_sampler}},
			nil,
			0,
			&PostProcessPushConstants{time = elapsed_time, intensity = 1.0},
			size_of(PostProcessPushConstants),
			{clear_value},
		),
	}

	execute_passes(&encoder, passes)
	finish_encoding(&encoder)
}

cleanup_render_resources :: proc() {
	if particleBuffer != {} {
		vk.DestroyBuffer(device, particleBuffer, nil)
		vk.FreeMemory(device, particleBufferMemory, nil)
	}

	if offscreenImage != {} {
		vk.DestroyImageView(device, offscreenImageView, nil)
		vk.DestroyImage(device, offscreenImage, nil)
		vk.FreeMemory(device, offscreenImageMemory, nil)
	}
}
