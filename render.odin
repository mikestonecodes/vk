package main

import "base:runtime"
import "core:fmt"
import "core:time"
import vk "vendor:vulkan"

PARTICLE_COUNT :: u32(180_000)
COMPUTE_GROUP_SIZE :: u32(128)

accumulation_buffer: vk.Buffer
accumulation_memory: vk.DeviceMemory
accumulation_size: vk.DeviceSize

PipelineKind :: enum {
	Compute,
	Post,
}

PIPELINE_COUNT :: 2

render_pipeline_specs := [PIPELINE_COUNT]PipelineSpec {
	{
		name = "compute",
		descriptor_stage = {vk.ShaderStageFlag.COMPUTE},
		push_stage = {vk.ShaderStageFlag.COMPUTE},
		push_size = u32(size_of(ComputePushConstants)),
		compute_module = "compute.spv",
	},
	{
		name = "post",
		descriptor_stage = {vk.ShaderStageFlag.FRAGMENT},
		push_stage = {vk.ShaderStageFlag.FRAGMENT},
		push_size = u32(size_of(PostProcessPushConstants)),
		vertex_module = "post_process_vs.spv",
		fragment_module = "post_process_fs.spv",
	},
}

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
	compile_shader("compute.hlsl")
	compile_shader("post_process.hlsl")
	init_render_pipeline_state(render_pipeline_specs[:], render_pipeline_states[:])
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	runtime.assert(
		accumulation_buffer != {},
		"accumulation buffer missing before recording commands",
	)
	runtime.assert(accumulation_size > 0, "accumulation buffer size must be positive")

	encoder := begin_encoding(element)
	frame := FrameInputs {
		cmd  = encoder.command_buffer,
		time = f32(time.duration_seconds(time.diff(start_time, time.now()))),
	}

	reset_accumulation(frame)
	issue_compute_pass(frame)
	issue_post_pass(frame, element.framebuffer)

	finish_encoding(&encoder)
}

FrameInputs :: struct {
	cmd:  vk.CommandBuffer,
	time: f32,
}

reset_accumulation :: proc(frame: FrameInputs) {
	vk.CmdFillBuffer(frame.cmd, accumulation_buffer, 0, accumulation_size, 0)
	vk.CmdPipelineBarrier(
		frame.cmd,
		{vk.PipelineStageFlag.TRANSFER},
		{vk.PipelineStageFlag.COMPUTE_SHADER},
		{},
		0,
		nil,
		1,
		&vk.BufferMemoryBarrier {
			sType = vk.StructureType.BUFFER_MEMORY_BARRIER,
			srcAccessMask = {vk.AccessFlag.TRANSFER_WRITE},
			dstAccessMask = {vk.AccessFlag.SHADER_WRITE},
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			buffer = accumulation_buffer,
			offset = 0,
			size = accumulation_size,
		},
		0,
		nil,
	)
}

issue_compute_pass :: proc(frame: FrameInputs) {
	compute_state := &render_pipeline_states[int(PipelineKind.Compute)]
	runtime.assert(pipelines_ready, "dispatch without ready pipelines")
	runtime.assert(compute_state.pipeline != {}, "compute pipeline missing")
	runtime.assert(compute_state.descriptor_set != {}, "compute descriptor set missing")

	push := ComputePushConstants {
		time           = frame.time,
		delta_time     = 0.016,
		particle_count = PARTICLE_COUNT,
		texture_width  = u32(width),
		texture_height = u32(height),
		spread         = 1.0,
		brightness     = 1.0,
	}
	workgroups := [3]u32{(PARTICLE_COUNT + COMPUTE_GROUP_SIZE - 1) / COMPUTE_GROUP_SIZE, 1, 1}

	vk.CmdBindPipeline(frame.cmd, .COMPUTE, compute_state.pipeline)
	vk.CmdBindDescriptorSets(
		frame.cmd,
		.COMPUTE,
		compute_state.layout,
		0,
		1,
		&compute_state.descriptor_set,
		0,
		nil,
	)

	vk.CmdPushConstants(
		frame.cmd,
		compute_state.layout,
		{vk.ShaderStageFlag.COMPUTE},
		0,
		u32(size_of(ComputePushConstants)),
		&push,
	)

	vk.CmdDispatch(frame.cmd, workgroups[0], workgroups[1], workgroups[2])

	barrier := vk.BufferMemoryBarrier {
		sType               = vk.StructureType.BUFFER_MEMORY_BARRIER,
		srcAccessMask       = {vk.AccessFlag.SHADER_WRITE},
		dstAccessMask       = {vk.AccessFlag.SHADER_READ},
		srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
		buffer              = accumulation_buffer,
		offset              = 0,
		size                = accumulation_size,
	}

	vk.CmdPipelineBarrier(
		frame.cmd,
		{vk.PipelineStageFlag.COMPUTE_SHADER},
		{vk.PipelineStageFlag.FRAGMENT_SHADER},
		{},
		0,
		nil,
		1,
		&barrier,
		0,
		nil,
	)
}

issue_post_pass :: proc(frame: FrameInputs, framebuffer: vk.Framebuffer) {
	post_state := &render_pipeline_states[int(PipelineKind.Post)]
	runtime.assert(post_state.pipeline != {}, "post pipeline missing")
	runtime.assert(post_state.descriptor_set != {}, "post descriptor set missing")

	vk.CmdBeginRenderPass(frame.cmd, &vk.RenderPassBeginInfo {
		sType           = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass      = render_pass,
		framebuffer     = framebuffer,
		renderArea      = {{x = 0, y = 0}, {width, height}},
		clearValueCount = 1,
		pClearValues    = &vk.ClearValue{color = vk.ClearColorValue{float32 = [4]f32{0.0, 0.0, 0.0, 1.0}}},
	}, .INLINE)

	vk.CmdBindPipeline(frame.cmd, .GRAPHICS, post_state.pipeline)
	vk.CmdBindDescriptorSets(
		frame.cmd,
		.GRAPHICS,
		post_state.layout,
		0,
		1,
		&post_state.descriptor_set,
		0,
		nil,
	)

	vk.CmdPushConstants(
		frame.cmd,
		post_state.layout,
		{vk.ShaderStageFlag.FRAGMENT},
		0,
		u32(size_of(PostProcessPushConstants)),
		&PostProcessPushConstants{frame.time, 1.2, 2.2, 1.0, u32(width), u32(height), 0.35, 0.0},
	)

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
		return
	}

	vk.DestroyBuffer(device, accumulation_buffer, nil)
	vk.FreeMemory(device, accumulation_memory, nil)
	accumulation_buffer = {}
	accumulation_memory = {}
	accumulation_size = 0
}
