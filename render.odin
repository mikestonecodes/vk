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

// Texture resources
textureImage: vk.Image
textureImageMemory: vk.DeviceMemory
textureImageView: vk.ImageView
offscreen_pass: vk.RenderPass
offscreen_fb: vk.Framebuffer

passes: []Pass
render_passes: [3]Pass // Pre-allocated pass array

clear_value := vk.ClearValue {
	color = {float32 = {0.0, 0.0, 0.0, 1.0}},
}


init :: proc() {
	// Nothing to do here
}

init_render_resources :: proc() {
	Particle :: struct {
		position: [2]f32,
		color:    [3]f32,
		_padding: f32,
	}
	particleBuffer, particleBufferMemory = createBuffer(
		PARTICLE_COUNT * size_of(Particle),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	offscreenImage, offscreenImageMemory, offscreenImageView = createImage(
		width,
		height,
		format,
		{vk.ImageUsageFlag.COLOR_ATTACHMENT, vk.ImageUsageFlag.SAMPLED},
	)

	// Create test texture
	textureImage, textureImageMemory, textureImageView, _ = createTestTexture()
	offscreen_pass = create_render_pass(format)
	offscreen_fb = create_framebuffer(offscreen_pass, offscreenImageView, width, height)
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	// Update pre-allocated passes with current frame data
	render_passes[0] = compute_pass(
		"compute.wgsl",
		{u32((PARTICLE_COUNT + 63) / 64), 1, 1},
		{particleBuffer},
		&ComputePushConstants{time = elapsed_time, particle_count = PARTICLE_COUNT},
		size_of(ComputePushConstants),
	)

	render_passes[1] = graphics_pass(
		"vertex.wgsl",
		"fragment.wgsl",
		offscreen_pass,
		offscreen_fb,
		6,
		PARTICLE_COUNT,
		{particleBuffer, texture_sampler, textureImageView},
		&VertexPushConstants{screen_width = f32(width), screen_height = f32(height)},
		size_of(VertexPushConstants),
		nil,
		0,
		{clear_value},
	)

	render_passes[2] = graphics_pass(
		"post_process.wgsl",
		"post_process.wgsl",
		render_pass,
		element.framebuffer,
		3,
		1,
		{offscreenImageView, texture_sampler},
		nil,
		0,
		&PostProcessPushConstants{time = elapsed_time, intensity = 1.0},
		size_of(PostProcessPushConstants),
		{clear_value},
	)

	execute_passes(&encoder, render_passes[:])
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

	if textureImage != {} {
		vk.DestroyImageView(device, textureImageView, nil)
		vk.DestroyImage(device, textureImage, nil)
		vk.FreeMemory(device, textureImageMemory, nil)
	}
}
