package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"

QUAD_COUNT :: 500000

// Simple variables
quadBuffer: vk.Buffer
quadBufferMemory: vk.DeviceMemory

offscreenImage: vk.Image
offscreenImageMemory: vk.DeviceMemory
offscreenImageView: vk.ImageView

// Texture resources
textureImage: vk.Image
textureImageMemory: vk.DeviceMemory
textureImageView: vk.ImageView
offscreen_pass: vk.RenderPass
offscreen_fb: vk.Framebuffer

render_passes: [3]Pass // Pre-allocated pass array

init_render_resources :: proc() {
	Quad :: struct {
		position: [2]f32,
		size:     [2]f32,
		color:    [4]f32,
	}
	quadBuffer, quadBufferMemory = createBuffer(
		QUAD_COUNT * size_of(Quad),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)
	offscreenImage, offscreenImageMemory, offscreenImageView = createImage(
		width,
		height,
		format,
		{vk.ImageUsageFlag.COLOR_ATTACHMENT, vk.ImageUsageFlag.SAMPLED},
	)

	// Create test texture (or load from file)
	// To load from file instead: textureImage, textureImageMemory, textureImageView, _ = loadTextureFromFile("path/to/texture.png")
	textureImage, textureImageMemory, textureImageView, _ = loadTextureFromFile("test.png")
	offscreen_pass = create_render_pass(format)
	offscreen_fb = create_framebuffer(offscreen_pass, offscreenImageView, width, height)
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	// Update pre-allocated passes with current frame data
	render_passes[0] = compute_pass(
		"compute.wgsl",
		{u32((QUAD_COUNT + 63) / 64), 1, 1},
		{quadBuffer},
		&ComputePushConstants{time = elapsed_time, quad_count = QUAD_COUNT},
		size_of(ComputePushConstants),
	)

	render_passes[1] = graphics_pass(
		"graphics.wgsl",
		offscreen_pass,
		offscreen_fb,
		6,
		QUAD_COUNT,
		{quadBuffer, texture_sampler, textureImageView},
		&VertexPushConstants{screen_width = i32(width), screen_height = i32(height)},
		size_of(VertexPushConstants),
	)

	render_passes[2] = graphics_pass(
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
	)

	execute_passes(&encoder, render_passes[:])
	finish_encoding(&encoder)
}

cleanup_render_resources :: proc() {
	vk.DestroyBuffer(device, quadBuffer, nil)
	vk.FreeMemory(device, quadBufferMemory, nil)

	vk.DestroyImageView(device, offscreenImageView, nil)
	vk.DestroyImage(device, offscreenImage, nil)
	vk.FreeMemory(device, offscreenImageMemory, nil)

	vk.DestroyImageView(device, textureImageView, nil)
	vk.DestroyImage(device, textureImage, nil)
	vk.FreeMemory(device, textureImageMemory, nil)

}
