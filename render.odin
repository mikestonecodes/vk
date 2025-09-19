package main

import "base:runtime"
import "core:time"
import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(980_000)
COMPUTE_GROUP_SIZE :: u32(128)

accumulation_buffer: vk.Buffer
accumulation_memory: vk.DeviceMemory
accumulation_size: vk.DeviceSize

compute_push_constants: ComputePushConstants
post_process_push_constants: PostProcessPushConstants

PipelineKind :: enum {
	Compute,
	Post,
}

PIPELINE_COUNT :: 2
render_pipeline_specs: [PIPELINE_COUNT]PipelineSpec
render_pipeline_states: [PIPELINE_COUNT]PipelineState

init_render_resources :: proc() {
	destroy_accumulation_buffer()

	if width == 0 || height == 0 {
		runtime.assert(false, "width and height must be greater than 0")
		pipelines_ready = false
		return
	}

	accumulation_size =
		vk.DeviceSize(width) * vk.DeviceSize(height) * 4 * vk.DeviceSize(size_of(u32))
	accumulation_buffer, accumulation_memory = createBuffer(
		int(accumulation_size),
		{vk.BufferUsageFlag.STORAGE_BUFFER, vk.BufferUsageFlag.TRANSFER_DST},
	)
	runtime.assert(accumulation_buffer != {}, "accumulation buffer allocation failed")


	render_pipeline_specs[0] = make_compute_pipeline_spec(
		ComputePipelineConfig {
			name = "particles",
			shader = "compute.spv",
			push = push_constant_info(
				"ComputePushConstants",
				{vk.ShaderStageFlag.COMPUTE},
				u32(size_of(ComputePushConstants)),
			),
			descriptor = storage_buffer_binding(
				"accumulation-buffer",
				{vk.ShaderStageFlag.COMPUTE},
			),
		},
	)

	render_pipeline_specs[1] = make_graphics_pipeline_spec(
		GraphicsPipelineConfig {
			name = "tone-map",
			vertex = "post_process_vs.spv",
			fragment = "post_process_fs.spv",
			push = push_constant_info(
				"PostProcessPushConstants",
				{vk.ShaderStageFlag.FRAGMENT},
				u32(size_of(PostProcessPushConstants)),
			),
			descriptor = storage_buffer_binding(
				"accumulation-buffer",
				{vk.ShaderStageFlag.FRAGMENT},
			),
		},
	)



	compute_push_constants = ComputePushConstants {
		time           = 0.0,
		delta_time     = 0.0,
		particle_count = PARTICLE_COUNT,
		texture_width  = u32(width),
		texture_height = u32(height),
		spread         = 1.0,
		brightness     = 1.0,
	}

	post_process_push_constants = PostProcessPushConstants {
		time              = 0.0,
		exposure          = 1.2,
		gamma             = 2.2,
		contrast          = 1.0,
		texture_width     = u32(width),
		texture_height    = u32(height),
		vignette_strength = 0.35,
		_pad0             = 0.0,
	}

	last_frame_time = 0.0
	init_accumulation_barriers(accumulation_buffer, accumulation_size)
	compile_shader("compute.hlsl")
	compile_shader("post_process.hlsl")
	init_render_pipeline_state(render_pipeline_specs[:], render_pipeline_states[:])
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	encoder, frame := begin_frame_commands(element, start_time)
	simulate_particles(frame)
	composite_to_swapchain(frame, element.framebuffer)
	finish_frame_commands(&encoder)
}


// compute.hlsl -> accumulation_buffer
simulate_particles :: proc(frame: FrameInputs) {
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer, 0, accumulation_size, 0)
	apply_transfer_to_compute_barrier(frame.cmd)

	compute_state := &render_pipeline_states[int(PipelineKind.Compute)]
	runtime.assert(pipelines_ready, "dispatch without ready pipelines")
	runtime.assert(compute_state.pipeline != {}, "compute pipeline missing")
	runtime.assert(compute_state.descriptor_set != {}, "compute descriptor set missing")

	compute_push_constants.time = frame.time
	compute_push_constants.delta_time = frame.delta_time


	bind_pipeline(frame.cmd, .COMPUTE, compute_state)
	bind_descriptor_set(frame.cmd, .COMPUTE, compute_state)
	push_compute_constants(frame.cmd, compute_state.layout, &compute_push_constants)

	vk.CmdDispatch(frame.cmd, (PARTICLE_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE, 1, 1)
	apply_compute_to_fragment_barrier(frame.cmd)
}

// accumulation_buffer -> post_process.hlsl -> swapchain framebuffer
composite_to_swapchain :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {
	post_state := &render_pipeline_states[int(PipelineKind.Post)]
	runtime.assert(post_state.pipeline != {}, "post pipeline missing")
	runtime.assert(post_state.descriptor_set != {}, "post descriptor set missing")

	vk.CmdBeginRenderPass(
		frame.cmd,
		&vk.RenderPassBeginInfo {
			sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
			renderPass = render_pass,
			framebuffer = framebuffer,
			renderArea = {{x = 0, y = 0}, {width, height}},
			clearValueCount = 1,
			pClearValues = &vk.ClearValue {
				color = vk.ClearColorValue{float32 = [4]f32{0.0, 0.0, 0.0, 1.0}},
			},
		},
		.INLINE,
	)

	post_process_push_constants.time = frame.time


	bind_pipeline(frame.cmd, .GRAPHICS, post_state)
	bind_descriptor_set(frame.cmd, .GRAPHICS, post_state)
	push_post_process_constants(frame.cmd, post_state.layout, &post_process_push_constants)

	vk.CmdDraw(frame.cmd, 3, 1, 0, 0)
	vk.CmdEndRenderPass(frame.cmd)
}

cleanup_render_resources :: proc() {
	destroy_render_pipeline_state(render_pipeline_states[:])
	destroy_accumulation_buffer()
}

destroy_accumulation_buffer :: proc() {
	if accumulation_buffer == {} {
		accumulation_memory = {}
		accumulation_size = 0
		reset_accumulation_barriers()
		return
	}

	vk.DestroyBuffer(device, accumulation_buffer, nil)
	vk.FreeMemory(device, accumulation_memory, nil)
	accumulation_buffer = {}
	accumulation_memory = {}
	accumulation_size = 0
	reset_accumulation_barriers()
}
