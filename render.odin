package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"
import "vendor:glfw"
QUAD_COUNT :: 2000000


// Dual buffer system for efficient culling
worldBuffer: vk.Buffer      // All quads in world space
worldBufferMemory: vk.DeviceMemory
visibleBuffer: vk.Buffer    // Only visible quads
visibleBufferMemory: vk.DeviceMemory
visibleCountBuffer: vk.Buffer  // Count of visible quads
visibleCountBufferMemory: vk.DeviceMemory
// Camera state buffer
cameraBuffer: vk.Buffer
cameraBufferMemory: vk.DeviceMemory

// Accumulation target for the mega-splat pipeline
splatBuffer: vk.Buffer
splatBufferMemory: vk.DeviceMemory
splatBufferSize: vk.DeviceSize

// Particle sprite texture resources
particleTextureImage: vk.Image
particleTextureMemory: vk.DeviceMemory
particleTextureView: vk.ImageView

render_passes: [2]Pass // Pre-allocated pass array

init_render_resources :: proc() {
	Quad :: struct {
		position: [2]f32,
		size:     [2]f32,
		color:    [4]f32,
		rotation: f32,
		depth:    f32,
		_padding: [2]f32, // Align to 16-byte boundary
	}

	// Create world buffer for all quads
	worldBuffer, worldBufferMemory = createBuffer(
		QUAD_COUNT * size_of(Quad),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)

	// Create visible buffer (smaller, only for culled quads)
	visibleBuffer, visibleBufferMemory = createBuffer(
		QUAD_COUNT * size_of(Quad), // Max size, will be partially filled
		{vk.BufferUsageFlag.STORAGE_BUFFER},
	)

	// Buffer to store count of visible quads
	visibleCountBuffer, visibleCountBufferMemory = createBuffer(
		size_of(u32),
		{vk.BufferUsageFlag.STORAGE_BUFFER},
		{vk.MemoryPropertyFlag.HOST_VISIBLE, vk.MemoryPropertyFlag.HOST_COHERENT},
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

	// Create accumulation buffer (4 uints per texel)
	splatBufferSize = vk.DeviceSize(width) * vk.DeviceSize(height) * 4 * vk.DeviceSize(size_of(u32))
	splatBuffer, splatBufferMemory = createBuffer(
		int(splatBufferSize),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)

	// Load particle texture used by the compute splat shader
	ok: bool
	particleTextureImage, particleTextureMemory, particleTextureView, ok = loadTextureFromFile("test.png")
	if !ok {
		fmt.println("Falling back to procedural particle texture")
		particleTextureImage, particleTextureMemory, particleTextureView, ok = createTestTexture()
		if !ok {
			fmt.println("Failed to create fallback particle texture")
		}
	}

	fmt.println("DEBUG: Initialization complete")
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	// Reset accumulation buffer each frame before splatting
	if splatBuffer != {} && splatBufferSize > 0 {
		vk.CmdFillBuffer(encoder.command_buffer, splatBuffer, 0, splatBufferSize, 0)

		buffer_barrier := vk.BufferMemoryBarrier {
			sType = vk.StructureType.BUFFER_MEMORY_BARRIER,
			srcAccessMask = {vk.AccessFlag.TRANSFER_WRITE},
			dstAccessMask = {vk.AccessFlag.SHADER_WRITE},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = splatBuffer,
			offset = 0,
			size = splatBufferSize,
		}
		vk.CmdPipelineBarrier(
			encoder.command_buffer,
			{vk.PipelineStageFlag.TRANSFER},
			{vk.PipelineStageFlag.COMPUTE_SHADER},
			{},
			0, nil,
			1, &buffer_barrier,
			0, nil,
		)
	}

	// Gather input state
	mouse_x, mouse_y := get_mouse_position()

	// Update pre-allocated passes with current frame data
	render_passes[0] = compute_pass(
		"compute.hlsl",
		{u32((QUAD_COUNT + 63) / 64), 1, 1},
		{worldBuffer, visibleBuffer, visibleCountBuffer, cameraBuffer, splatBuffer, particleTextureView, texture_sampler},
		&ComputePushConstants{
			time = elapsed_time,
			quad_count = QUAD_COUNT,
			delta_time = 0.016, // Approximate 60fps
			spawn_delay = 0.8, // Each level appears 0.8 seconds after the previous
			max_visible_level = elapsed_time / 0.8, // Growing level limit
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
			texture_width = u32(width),
			texture_height = u32(height),
			splat_extent = 1.8,
			fog_strength = 0.75,
		},
		size_of(ComputePushConstants),
	)


    // Composite the accumulated splat texture directly onto the swapchain
	render_passes[1] = graphics_pass(
		shader = "post_process.hlsl",
		render_pass = render_pass,
		framebuffer = element.framebuffer,
		vertices = 3,
		instances = 1,
		resources = {splatBuffer},
		fragment_push_data = &PostProcessPushConstants{
			time = elapsed_time,
			intensity = 1.0,
			texture_width = u32(width),
			texture_height = u32(height),
		},
		fragment_push_size = size_of(PostProcessPushConstants),
		clear_values = {0.0, 0.0, 0.0, 1.0},
	)

	// Execute compute pass first
	execute_passes(&encoder, render_passes[0:1])

	// Make the splat texture available for sampling in the composite pass
	if splatBuffer != {} && splatBufferSize > 0 {
		buffer_barrier := vk.BufferMemoryBarrier {
			sType = vk.StructureType.BUFFER_MEMORY_BARRIER,
			srcAccessMask = {vk.AccessFlag.SHADER_WRITE},
			dstAccessMask = {vk.AccessFlag.SHADER_READ},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = splatBuffer,
			offset = 0,
			size = splatBufferSize,
		}
		vk.CmdPipelineBarrier(
			encoder.command_buffer,
			{vk.PipelineStageFlag.COMPUTE_SHADER},
			{vk.PipelineStageFlag.FRAGMENT_SHADER},
			{},
			0, nil,
			1, &buffer_barrier,
			0, nil,
		)
	}

	// Composite accumulation onto the swapchain
	execute_passes(&encoder, render_passes[1:2])

	finish_encoding(&encoder)
}

cleanup_render_resources :: proc() {
	vk.DestroyBuffer(device, worldBuffer, nil)
	vk.FreeMemory(device, worldBufferMemory, nil)
	vk.DestroyBuffer(device, visibleBuffer, nil)
	vk.FreeMemory(device, visibleBufferMemory, nil)
	vk.DestroyBuffer(device, visibleCountBuffer, nil)
	vk.FreeMemory(device, visibleCountBufferMemory, nil)

	vk.DestroyBuffer(device, cameraBuffer, nil)
	vk.FreeMemory(device, cameraBufferMemory, nil)

	vk.DestroyBuffer(device, splatBuffer, nil)
	vk.FreeMemory(device, splatBufferMemory, nil)

	if particleTextureView != {} {
		vk.DestroyImageView(device, particleTextureView, nil)
		particleTextureView = {}
	}
	if particleTextureImage != {} {
		vk.DestroyImage(device, particleTextureImage, nil)
		particleTextureImage = {}
	}
	if particleTextureMemory != {} {
		vk.FreeMemory(device, particleTextureMemory, nil)
		particleTextureMemory = {}
	}

}
