package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"
import vk "vendor:vulkan"

ComputePass :: struct {
	pipeline: vk.Pipeline,
	layout: vk.PipelineLayout,
	descriptor_sets: []vk.DescriptorSet,
	push_data: rawptr,
	push_size: u32,
	workgroups: [3]u32,
}

RenderPass :: struct {
	pipeline: vk.Pipeline,
	layout: vk.PipelineLayout,
	descriptor_sets: []vk.DescriptorSet,
	push_data: rawptr,
	push_size: u32,
	push_stages: vk.ShaderStageFlags,
	render_pass: vk.RenderPass,
	framebuffer: vk.Framebuffer,
	clear_values: []vk.ClearValue,
	vertices: u32,
	instances: u32,
}

MemorySync :: struct {
	src_access: vk.AccessFlags,
	dst_access: vk.AccessFlags,
	src_stage: vk.PipelineStageFlags,
	dst_stage: vk.PipelineStageFlags,
	image: vk.Image,
	old_layout: vk.ImageLayout,
	new_layout: vk.ImageLayout,
}

Encoder :: struct {
	cmd: vk.CommandBuffer,
}

begin_encoding :: proc(element: ^SwapchainElement) -> Encoder {
	begin_info := vk.CommandBufferBeginInfo{
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}
	vk.ResetCommandBuffer(element.commandBuffer, {})
	vk.BeginCommandBuffer(element.commandBuffer, &begin_info)
	return {cmd = element.commandBuffer}
}

encode_compute :: proc(encoder: ^Encoder, pass: ^ComputePass) {
	vk.CmdBindPipeline(encoder.cmd, vk.PipelineBindPoint.COMPUTE, pass.pipeline)
	if len(pass.descriptor_sets) > 0 {
		vk.CmdBindDescriptorSets(encoder.cmd, vk.PipelineBindPoint.COMPUTE, pass.layout, 0,
			u32(len(pass.descriptor_sets)), raw_data(pass.descriptor_sets), 0, nil)
	}
	if pass.push_data != nil {
		vk.CmdPushConstants(encoder.cmd, pass.layout, {vk.ShaderStageFlag.COMPUTE}, 0, pass.push_size, pass.push_data)
	}
	vk.CmdDispatch(encoder.cmd, pass.workgroups.x, pass.workgroups.y, pass.workgroups.z)
}

encode_render :: proc(encoder: ^Encoder, pass: ^RenderPass) {
	render_area := vk.Rect2D{offset = {0, 0}, extent = {width, height}}
	begin_info := vk.RenderPassBeginInfo{
		sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass = pass.render_pass,
		framebuffer = pass.framebuffer,
		renderArea = render_area,
		clearValueCount = u32(len(pass.clear_values)),
		pClearValues = len(pass.clear_values) > 0 ? raw_data(pass.clear_values) : nil,
	}

	vk.CmdBeginRenderPass(encoder.cmd, &begin_info, vk.SubpassContents.INLINE)
	vk.CmdBindPipeline(encoder.cmd, vk.PipelineBindPoint.GRAPHICS, pass.pipeline)

	if len(pass.descriptor_sets) > 0 {
		vk.CmdBindDescriptorSets(encoder.cmd, vk.PipelineBindPoint.GRAPHICS, pass.layout, 0,
			u32(len(pass.descriptor_sets)), raw_data(pass.descriptor_sets), 0, nil)
	}
	if pass.push_data != nil {
		vk.CmdPushConstants(encoder.cmd, pass.layout, pass.push_stages, 0, pass.push_size, pass.push_data)
	}

	vk.CmdDraw(encoder.cmd, pass.vertices, pass.instances, 0, 0)
	vk.CmdEndRenderPass(encoder.cmd)
}

encode_memory_barrier :: proc(encoder: ^Encoder, sync: ^MemorySync) {
	if sync.image != {} {
		barrier := vk.ImageMemoryBarrier{
			sType = vk.StructureType.IMAGE_MEMORY_BARRIER,
			srcAccessMask = sync.src_access,
			dstAccessMask = sync.dst_access,
			oldLayout = sync.old_layout,
			newLayout = sync.new_layout,
			srcQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			dstQueueFamilyIndex = vk.QUEUE_FAMILY_IGNORED,
			image = sync.image,
			subresourceRange = {
				aspectMask = {vk.ImageAspectFlag.COLOR},
				baseMipLevel = 0, levelCount = 1,
				baseArrayLayer = 0, layerCount = 1,
			},
		}
		vk.CmdPipelineBarrier(encoder.cmd, sync.src_stage, sync.dst_stage, {}, 0, nil, 0, nil, 1, &barrier)
	} else {
		barrier := vk.MemoryBarrier{
			sType = vk.StructureType.MEMORY_BARRIER,
			srcAccessMask = sync.src_access,
			dstAccessMask = sync.dst_access,
		}
		vk.CmdPipelineBarrier(encoder.cmd, sync.src_stage, sync.dst_stage, {}, 1, &barrier, 0, nil, 0, nil)
	}
}

finish_encoding :: proc(encoder: ^Encoder) {
	vk.EndCommandBuffer(encoder.cmd)
}

make_compute_pass :: proc(pipeline: vk.Pipeline, layout: vk.PipelineLayout, workgroups: [3]u32,
	descriptor_sets: []vk.DescriptorSet = nil, push_data: rawptr = nil, push_size: u32 = 0) -> ComputePass {
	return {
		pipeline = pipeline,
		layout = layout,
		descriptor_sets = descriptor_sets,
		push_data = push_data,
		push_size = push_size,
		workgroups = workgroups,
	}
}

make_render_pass :: proc(pipeline: vk.Pipeline, layout: vk.PipelineLayout, render_pass: vk.RenderPass,
	framebuffer: vk.Framebuffer, vertices: u32, instances: u32 = 1,
	descriptor_sets: []vk.DescriptorSet = nil, push_data: rawptr = nil, push_size: u32 = 0,
	push_stages: vk.ShaderStageFlags = {}, clear_values: []vk.ClearValue = nil) -> RenderPass {
	return {
		pipeline = pipeline,
		layout = layout,
		descriptor_sets = descriptor_sets,
		push_data = push_data,
		push_size = push_size,
		push_stages = push_stages,
		render_pass = render_pass,
		framebuffer = framebuffer,
		clear_values = clear_values,
		vertices = vertices,
		instances = instances,
	}
}

make_memory_sync :: proc(src_access: vk.AccessFlags, dst_access: vk.AccessFlags,
	src_stage: vk.PipelineStageFlags, dst_stage: vk.PipelineStageFlags,
	image: vk.Image = {}, old_layout: vk.ImageLayout = .UNDEFINED, new_layout: vk.ImageLayout = .UNDEFINED) -> MemorySync {
	return {
		src_access = src_access,
		dst_access = dst_access,
		src_stage = src_stage,
		dst_stage = dst_stage,
		image = image,
		old_layout = old_layout,
		new_layout = new_layout,
	}
}

encode_passes :: proc(encoder: ^Encoder, passes: ..any) {
	for pass in passes {
		switch p in pass {
		case ^ComputePass: encode_compute(encoder, p)
		case ^RenderPass: encode_render(encoder, p)
		case ^MemorySync: encode_memory_barrier(encoder, p)
		case ComputePass:
			temp := p
			encode_compute(encoder, &temp)
		case RenderPass:
			temp := p
			encode_render(encoder, &temp)
		case MemorySync:
			temp := p
			encode_memory_barrier(encoder, &temp)
		}
	}
}
