package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import vk "vendor:vulkan"
import "vendor:glfw"

QUAD_COUNT :: 10000


// Dual buffer system for efficient culling
worldBuffer: vk.Buffer      // All quads in world space
worldBufferMemory: vk.DeviceMemory
visibleBuffer: vk.Buffer    // Only visible quads
visibleBufferMemory: vk.DeviceMemory
visibleCountBuffer: vk.Buffer  // Count of visible quads
visibleCountBufferMemory: vk.DeviceMemory
// Indirect draw command buffer
indirectBuffer: vk.Buffer
indirectBufferMemory: vk.DeviceMemory

// Line buffer for connections between quads
lineBuffer: vk.Buffer
lineBufferMemory: vk.DeviceMemory

// Camera state buffer
cameraBuffer: vk.Buffer
cameraBufferMemory: vk.DeviceMemory

offscreenImage: vk.Image
offscreenImageMemory: vk.DeviceMemory
offscreenImageView: vk.ImageView

// Depth buffer for proper Z-testing
depthImage: vk.Image
depthImageMemory: vk.DeviceMemory
depthImageView: vk.ImageView

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
		rotation: f32,
		depth:    f32,
		_padding: [2]f32, // Align to 16-byte boundary
	}

	Line :: struct {
		start_pos: [2]f32,
		end_pos:   [2]f32,
		color:     [4]f32,
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

	// Buffer for VkDrawIndirectCommand (4 x u32)
	indirectBuffer, indirectBufferMemory = createBuffer(
		4 * size_of(u32),
		{vk.BufferUsageFlag.INDIRECT_BUFFER},
		{vk.MemoryPropertyFlag.HOST_VISIBLE, vk.MemoryPropertyFlag.HOST_COHERENT},
	)

	// Create line buffer - each quad can connect to its parent, so same count
	lineBuffer, lineBufferMemory = createBuffer(
		QUAD_COUNT * size_of(Line),
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

	// Create depth buffer with proper aspect mask
	depthImage, depthImageMemory, depthImageView = createDepthImage(
		width,
		height,
		vk.Format.D32_SFLOAT,
		{vk.ImageUsageFlag.DEPTH_STENCIL_ATTACHMENT},
	)

	// Create test texture (or load from file)
	// To load from file instead: textureImage, textureImageMemory, textureImageView, _ = loadTextureFromFile("path/to/texture.png")
	textureImage, textureImageMemory, textureImageView, _ = loadTextureFromFile("test3.png")
    fmt.println("DEBUG: Creating render pass...")
    // Use color-only offscreen pass to render without depth testing.
    offscreen_pass = create_render_pass(format)
    fmt.println("DEBUG: Creating framebuffer...")
    offscreen_fb = create_framebuffer(offscreen_pass, offscreenImageView, width, height)
	fmt.println("DEBUG: Initialization complete")
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder := begin_encoding(element)
	elapsed_time := f32(time.duration_seconds(time.diff(start_time, time.now())))

	// Gather input state
	mouse_x, mouse_y := get_mouse_position()

	// Read visible count from GPU buffer
	mapped_memory: rawptr
    vk.MapMemory(device, visibleCountBufferMemory, 0, size_of(u32), {}, &mapped_memory)
    visible_count := (^u32)(mapped_memory)^
    vk.UnmapMemory(device, visibleCountBufferMemory)
    // Fallback to avoid zero-instance first frame due to one-frame latency
    if visible_count == 0 {
        visible_count = QUAD_COUNT
    }

	// Write indirect draw command: {vertexCount, instanceCount, firstVertex, firstInstance}
	indirect_mapped: rawptr
	vk.MapMemory(device, indirectBufferMemory, 0, 4 * size_of(u32), {}, &indirect_mapped)
	cmd_params := (^[4]u32)(indirect_mapped)
	cmd_params^[0] = 6            // vertexCount per instance (two triangles)
	cmd_params^[1] = visible_count // instanceCount from compute result
	cmd_params^[2] = 0            // firstVertex
	cmd_params^[3] = 0            // firstInstance
	vk.UnmapMemory(device, indirectBufferMemory)

	// Update pre-allocated passes with current frame data
	render_passes[0] = compute_pass(
		"compute.hlsl",
		{u32((QUAD_COUNT + 63) / 64), 1, 1},
		{worldBuffer, visibleBuffer, visibleCountBuffer, cameraBuffer},
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
		},
		size_of(ComputePushConstants),
	)

/*

graphics_pass :: proc(
	shader: string,
	render_pass: vk.RenderPass,
	framebuffer: vk.Framebuffer,
	vertices: u32,
	instances: u32 = 1,
	resources: []DescriptorResource = nil,
	vertex_push_data: rawptr = nil,
	vertex_push_size: u32 = 0,
	fragment_push_data: rawptr = nil,
	fragment_push_size: u32 = 0,
	clear_values: [4]f32 = {0.0, 0.0, 0.0, 1.0},
	*/
    // Main scene to offscreen target with depth
    render_passes[1] = graphics_pass(
        shader = "graphics.hlsl",
        render_pass = offscreen_pass,
        framebuffer = offscreen_fb,
        vertices = 6,
        instances = visible_count, // not used when drawing indirect
        resources = {visibleBuffer, texture_sampler, textureImageView},
        vertex_push_data = &VertexPushConstants{screen_width = i32(width), screen_height = i32(height)},
        vertex_push_size = size_of(VertexPushConstants),
        clear_values = {0.0, 0.0, 0.0, 1.0},
    )
    // Indirect draw for the main pass
    render_passes[1].graphics.indirect_buffer = indirectBuffer
    render_passes[1].graphics.indirect_offset = 0

    // Post-process / present: sample offscreen color to swapchain
    // Provide fragment push constants to satisfy shader layout (intensity used in shader)
    render_passes[2] = graphics_pass(
        shader = "post_process.hlsl",
        render_pass = render_pass,
        framebuffer = element.framebuffer,
        vertices = 3,
        instances = 1,
        resources = {offscreenImageView, texture_sampler},
        fragment_push_data = &PostProcessPushConstants{time = elapsed_time, intensity = 1.0},
        fragment_push_size = size_of(PostProcessPushConstants),
        clear_values = {0.0, 0.0, 0.0, 1.0},
    )

    // Execute compute + main (depth) + post-process
    execute_passes(&encoder, render_passes[0:3])
    finish_encoding(&encoder)
}

cleanup_render_resources :: proc() {
	// Destroy framebuffer first
	vk.DestroyFramebuffer(device, offscreen_fb, nil)

	// Destroy render pass
	vk.DestroyRenderPass(device, offscreen_pass, nil)

	vk.DestroyBuffer(device, worldBuffer, nil)
	vk.FreeMemory(device, worldBufferMemory, nil)
	vk.DestroyBuffer(device, visibleBuffer, nil)
	vk.FreeMemory(device, visibleBufferMemory, nil)
	vk.DestroyBuffer(device, visibleCountBuffer, nil)
	vk.FreeMemory(device, visibleCountBufferMemory, nil)

	vk.DestroyBuffer(device, lineBuffer, nil)
	vk.FreeMemory(device, lineBufferMemory, nil)

	vk.DestroyBuffer(device, indirectBuffer, nil)
	vk.FreeMemory(device, indirectBufferMemory, nil)

	vk.DestroyBuffer(device, cameraBuffer, nil)
	vk.FreeMemory(device, cameraBufferMemory, nil)

	vk.DestroyImageView(device, offscreenImageView, nil)
	vk.DestroyImage(device, offscreenImage, nil)
	vk.FreeMemory(device, offscreenImageMemory, nil)

	vk.DestroyImageView(device, depthImageView, nil)
	vk.DestroyImage(device, depthImage, nil)
	vk.FreeMemory(device, depthImageMemory, nil)

	vk.DestroyImageView(device, textureImageView, nil)
	vk.DestroyImage(device, textureImage, nil)
	vk.FreeMemory(device, textureImageMemory, nil)

}
