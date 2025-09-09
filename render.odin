package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"
import "vendor:glfw"

QUAD_COUNT :: 500000


// Simple variables
quadBuffer: vk.Buffer
quadBufferMemory: vk.DeviceMemory

// Camera state buffer
cameraBuffer: vk.Buffer
cameraBufferMemory: vk.DeviceMemory

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
	
	// Camera state
	CameraState :: struct {
		x: f32,
		y: f32,
		zoom: f32,
		_padding: f32, // Align to 16 bytes
	}
	cameraBuffer, cameraBufferMemory = createBuffer(
		size_of(CameraState),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
		{vk.MemoryPropertyFlag.HOST_VISIBLE, vk.MemoryPropertyFlag.HOST_COHERENT},
	)
	
	// Initialize camera state
	camera_data := CameraState{x = 0.0, y = 0.0, zoom = 1.4, _padding = 0.0}
	mapped_memory: rawptr
	vk.MapMemory(device, cameraBufferMemory, 0, size_of(CameraState), {}, &mapped_memory)
	(^CameraState)(mapped_memory)^ = camera_data
	vk.UnmapMemory(device, cameraBufferMemory)
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

	// Gather input state
	mouse_x, mouse_y := get_mouse_position()
	
	// Update pre-allocated passes with current frame data
	render_passes[0] = compute_pass(
		"compute.wgsl",
		{u32((QUAD_COUNT + 63) / 64), 1, 1},
		{quadBuffer, cameraBuffer},
		&ComputePushConstants{
			time = elapsed_time, 
			quad_count = QUAD_COUNT,
			delta_time = 0.016, // Approximate 60fps
			mouse_x = f32(mouse_x),
			mouse_y = f32(mouse_y),
			mouse_left = is_mouse_button_pressed(glfw.MOUSE_BUTTON_LEFT) ? 1 : 0,
			mouse_right = is_mouse_button_pressed(glfw.MOUSE_BUTTON_RIGHT) ? 1 : 0,
			key_h = is_key_pressed(glfw.KEY_H) ? 1 : 0,
			key_j = is_key_pressed(glfw.KEY_J) ? 1 : 0,
			key_k = is_key_pressed(glfw.KEY_K) ? 1 : 0,
			key_l = is_key_pressed(glfw.KEY_L) ? 1 : 0,
			key_w = is_key_pressed(glfw.KEY_W) ? 1 : 0,
			key_a = is_key_pressed(glfw.KEY_A) ? 1 : 0,
			key_s = is_key_pressed(glfw.KEY_S) ? 1 : 0,
			key_d = is_key_pressed(glfw.KEY_D) ? 1 : 0,
			key_q = is_key_pressed(glfw.KEY_Q) ? 1 : 0,
			key_e = is_key_pressed(glfw.KEY_E) ? 1 : 0,
		},
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
	
	vk.DestroyBuffer(device, cameraBuffer, nil)
	vk.FreeMemory(device, cameraBufferMemory, nil)

	vk.DestroyImageView(device, offscreenImageView, nil)
	vk.DestroyImage(device, offscreenImage, nil)
	vk.FreeMemory(device, offscreenImageMemory, nil)

	vk.DestroyImageView(device, textureImageView, nil)
	vk.DestroyImage(device, textureImage, nil)
	vk.FreeMemory(device, textureImageMemory, nil)

}
