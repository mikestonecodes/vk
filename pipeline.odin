package main

import "core:fmt"
import "core:c"
import "core:os"
import "core:time"
import "base:runtime"
import "core:strings"
import vk "vendor:vulkan"

ComputePass :: struct {
	shader: string,
	descriptor_sets: []vk.DescriptorSet,
	push_data: rawptr,
	push_size: u32,
	workgroups: [3]u32,
}

RenderPass :: struct {
	vertex_shader: string,
	fragment_shader: string,
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
	pipeline, layout := get_compute_pipeline(pass.shader)
	vk.CmdBindPipeline(encoder.cmd, vk.PipelineBindPoint.COMPUTE, pipeline)
	if len(pass.descriptor_sets) > 0 {
		vk.CmdBindDescriptorSets(encoder.cmd, vk.PipelineBindPoint.COMPUTE, layout, 0,
			u32(len(pass.descriptor_sets)), raw_data(pass.descriptor_sets), 0, nil)
	}
	if pass.push_data != nil {
		vk.CmdPushConstants(encoder.cmd, layout, {vk.ShaderStageFlag.COMPUTE}, 0, pass.push_size, pass.push_data)
	}
	vk.CmdDispatch(encoder.cmd, pass.workgroups.x, pass.workgroups.y, pass.workgroups.z)
}

encode_render :: proc(encoder: ^Encoder, pass: ^RenderPass) {
	pipeline, layout := get_graphics_pipeline(pass.vertex_shader, pass.fragment_shader, pass.render_pass, pass.descriptor_sets)
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
	vk.CmdBindPipeline(encoder.cmd, vk.PipelineBindPoint.GRAPHICS, pipeline)

	if len(pass.descriptor_sets) > 0 {
		vk.CmdBindDescriptorSets(encoder.cmd, vk.PipelineBindPoint.GRAPHICS, layout, 0,
			u32(len(pass.descriptor_sets)), raw_data(pass.descriptor_sets), 0, nil)
	}
	if pass.push_data != nil {
		vk.CmdPushConstants(encoder.cmd, layout, pass.push_stages, 0, pass.push_size, pass.push_data)
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

pipeline_cache := make(map[string]struct{ pipeline: vk.Pipeline, layout: vk.PipelineLayout })

compute_pass :: proc(shader: string, workgroups: [3]u32, descriptor_sets: []vk.DescriptorSet = nil, 
	push_data: rawptr = nil, push_size: u32 = 0) -> ComputePass {
	return {
		shader = shader,
		descriptor_sets = descriptor_sets,
		push_data = push_data,
		push_size = push_size,
		workgroups = workgroups,
	}
}

graphics_pass :: proc(vertex_shader: string, fragment_shader: string, render_pass: vk.RenderPass,
	framebuffer: vk.Framebuffer, vertices: u32, instances: u32 = 1,
	descriptor_sets: []vk.DescriptorSet = nil, push_data: rawptr = nil, push_size: u32 = 0,
	push_stages: vk.ShaderStageFlags = {}, clear_values: []vk.ClearValue = nil) -> RenderPass {
	return {
		vertex_shader = vertex_shader,
		fragment_shader = fragment_shader,
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

compile_shader :: proc(wgsl_file: string) -> bool {
	spv_file, _ := strings.replace(wgsl_file, ".wgsl", ".spv", 1)
	defer delete(spv_file)
	
	cmd := fmt.aprintf("./naga %s %s", wgsl_file, spv_file)
	defer delete(cmd)
	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)
	
	if system(cmd_cstr) != 0 {
		fmt.printf("Failed to compile %s\n", wgsl_file)
		return false
	}
	return true
}

get_compute_pipeline :: proc(shader: string) -> (vk.Pipeline, vk.PipelineLayout) {
	if cached, ok := pipeline_cache[shader]; ok {
		return cached.pipeline, cached.layout
	}
	
	if !compile_shader(shader) {
		return {}, {}
	}
	
	spv_file, _ := strings.replace(shader, ".wgsl", ".spv", 1)
	defer delete(spv_file)
	
	shader_code, ok := load_shader_spirv(spv_file)
	if !ok {
		return {}, {}
	}
	defer delete(shader_code)
	
	shader_module: vk.ShaderModule
	create_info := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(shader_code) * size_of(u32),
		pCode = raw_data(shader_code),
	}
	if vk.CreateShaderModule(device, &create_info, nil, &shader_module) != vk.Result.SUCCESS {
		return {}, {}
	}
	defer vk.DestroyShaderModule(device, shader_module, nil)
	
	push_range := vk.PushConstantRange{
		stageFlags = {vk.ShaderStageFlag.COMPUTE},
		offset = 0,
		size = size_of(ComputePushConstants),
	}
	
	layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts = &descriptor_set_layout,
		pushConstantRangeCount = 1,
		pPushConstantRanges = &push_range,
	}
	
	layout: vk.PipelineLayout
	if vk.CreatePipelineLayout(device, &layout_info, nil, &layout) != vk.Result.SUCCESS {
		return {}, {}
	}
	
	pipeline_info := vk.ComputePipelineCreateInfo{
		sType = vk.StructureType.COMPUTE_PIPELINE_CREATE_INFO,
		stage = {
			sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {vk.ShaderStageFlag.COMPUTE},
			module = shader_module,
			pName = "main",
		},
		layout = layout,
	}
	
	pipeline: vk.Pipeline
	if vk.CreateComputePipelines(device, {}, 1, &pipeline_info, nil, &pipeline) != vk.Result.SUCCESS {
		vk.DestroyPipelineLayout(device, layout, nil)
		return {}, {}
	}
	
	pipeline_cache[strings.clone(shader)] = {pipeline, layout}
	return pipeline, layout
}

get_graphics_pipeline :: proc(vertex_shader: string, fragment_shader: string, render_pass: vk.RenderPass, descriptor_sets: []vk.DescriptorSet = nil) -> (vk.Pipeline, vk.PipelineLayout) {
	key := fmt.aprintf("%s+%s", vertex_shader, fragment_shader)
	defer delete(key)
	
	if cached, ok := pipeline_cache[key]; ok {
		return cached.pipeline, cached.layout
	}
	
	if !compile_shader(vertex_shader) || !compile_shader(fragment_shader) {
		return {}, {}
	}
	
	vert_spv, _ := strings.replace(vertex_shader, ".wgsl", ".spv", 1)
	frag_spv, _ := strings.replace(fragment_shader, ".wgsl", ".spv", 1)
	defer delete(vert_spv)
	defer delete(frag_spv)
	
	vert_code, vert_ok := load_shader_spirv(vert_spv)
	frag_code, frag_ok := load_shader_spirv(frag_spv)
	if !vert_ok || !frag_ok {
		return {}, {}
	}
	defer delete(vert_code)
	defer delete(frag_code)
	
	vert_module, frag_module: vk.ShaderModule
	
	vert_create := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(vert_code) * size_of(u32),
		pCode = raw_data(vert_code),
	}
	frag_create := vk.ShaderModuleCreateInfo{
		sType = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(frag_code) * size_of(u32),
		pCode = raw_data(frag_code),
	}
	
	if vk.CreateShaderModule(device, &vert_create, nil, &vert_module) != vk.Result.SUCCESS ||
	   vk.CreateShaderModule(device, &frag_create, nil, &frag_module) != vk.Result.SUCCESS {
		return {}, {}
	}
	defer vk.DestroyShaderModule(device, vert_module, nil)
	defer vk.DestroyShaderModule(device, frag_module, nil)
	
	stages := [2]vk.PipelineShaderStageCreateInfo{
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.VERTEX}, module = vert_module, pName = "vs_main"},
		{sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO, stage = {vk.ShaderStageFlag.FRAGMENT}, module = frag_module, pName = "fs_main"},
	}
	
	vertex_input := vk.PipelineVertexInputStateCreateInfo{sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO}
	input_assembly := vk.PipelineInputAssemblyStateCreateInfo{
		sType = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = vk.PrimitiveTopology.TRIANGLE_LIST,
	}
	
	viewport := vk.Viewport{width = f32(width), height = f32(height), maxDepth = 1.0}
	scissor := vk.Rect2D{extent = {width, height}}
	viewport_state := vk.PipelineViewportStateCreateInfo{
		sType = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1, pViewports = &viewport,
		scissorCount = 1, pScissors = &scissor,
	}
	
	rasterizer := vk.PipelineRasterizationStateCreateInfo{
		sType = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = vk.PolygonMode.FILL,
		lineWidth = 1.0,
		frontFace = vk.FrontFace.CLOCKWISE,
	}
	
	multisampling := vk.PipelineMultisampleStateCreateInfo{
		sType = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {vk.SampleCountFlag._1},
	}
	
	color_attachment := vk.PipelineColorBlendAttachmentState{
		colorWriteMask = {vk.ColorComponentFlag.R, vk.ColorComponentFlag.G, vk.ColorComponentFlag.B, vk.ColorComponentFlag.A},
	}
	color_blending := vk.PipelineColorBlendStateCreateInfo{
		sType = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1, pAttachments = &color_attachment,
	}
	
	// Use the correct descriptor set layout based on what we're binding
	layout_to_use := descriptor_set_layout
	if len(descriptor_sets) > 0 {
		// Check if this is a post-process descriptor set by looking at the binding pattern
		if len(descriptor_sets) == 1 && descriptor_sets[0] == post_process_descriptor_set {
			layout_to_use = post_process_descriptor_set_layout
		}
	}
	
	layout_info := vk.PipelineLayoutCreateInfo{
		sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1, pSetLayouts = &layout_to_use,
	}
	
	// Add push constant support for fragment shaders if needed
	push_ranges: [1]vk.PushConstantRange
	push_count := u32(0)
	if fragment_shader == "post_process.wgsl" {
		push_ranges[0] = vk.PushConstantRange{
			stageFlags = {vk.ShaderStageFlag.FRAGMENT},
			offset = 0,
			size = size_of(PostProcessPushConstants),
		}
		push_count = 1
		layout_info.pushConstantRangeCount = push_count
		layout_info.pPushConstantRanges = raw_data(push_ranges[:])
	}
	
	layout: vk.PipelineLayout
	if vk.CreatePipelineLayout(device, &layout_info, nil, &layout) != vk.Result.SUCCESS {
		return {}, {}
	}
	
	pipeline_info := vk.GraphicsPipelineCreateInfo{
		sType = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount = 2, pStages = raw_data(stages[:]),
		pVertexInputState = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState = &multisampling,
		pColorBlendState = &color_blending,
		layout = layout,
		renderPass = render_pass,
	}
	
	pipeline: vk.Pipeline
	if vk.CreateGraphicsPipelines(device, {}, 1, &pipeline_info, nil, &pipeline) != vk.Result.SUCCESS {
		vk.DestroyPipelineLayout(device, layout, nil)
		return {}, {}
	}
	
	pipeline_cache[strings.clone(key)] = {pipeline, layout}
	return pipeline, layout
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

PassType :: enum {
	COMPUTE,
	GRAPHICS_OFFSCREEN, 
	GRAPHICS_PRESENT,
}

get_pass_type :: proc(pass: any) -> PassType {
	switch p in pass {
	case ^ComputePass, ComputePass:
		return .COMPUTE
	case ^RenderPass:
		if p.vertex_shader == "post_process.wgsl" {
			return .GRAPHICS_PRESENT
		}
		return .GRAPHICS_OFFSCREEN
	case RenderPass:
		if p.vertex_shader == "post_process.wgsl" {
			return .GRAPHICS_PRESENT
		}
		return .GRAPHICS_OFFSCREEN
	}
	return .COMPUTE // fallback
}

insert_automatic_barrier :: proc(encoder: ^Encoder, prev_type: PassType, curr_type: PassType, offscreen_image: vk.Image) {
	switch {
	case prev_type == .COMPUTE && curr_type == .GRAPHICS_OFFSCREEN:
		// Compute -> Graphics: Shader writes to vertex buffer read
		barrier := MemorySync{
			src_access = {vk.AccessFlag.SHADER_WRITE},
			dst_access = {vk.AccessFlag.VERTEX_ATTRIBUTE_READ},
			src_stage = {vk.PipelineStageFlag.COMPUTE_SHADER},
			dst_stage = {vk.PipelineStageFlag.VERTEX_INPUT},
		}
		encode_memory_barrier(encoder, &barrier)
		
	case prev_type == .GRAPHICS_OFFSCREEN && curr_type == .GRAPHICS_PRESENT:
		// Offscreen render -> Post-process: Color attachment to shader read
		barrier := MemorySync{
			src_access = {vk.AccessFlag.COLOR_ATTACHMENT_WRITE},
			dst_access = {vk.AccessFlag.SHADER_READ},
			src_stage = {vk.PipelineStageFlag.COLOR_ATTACHMENT_OUTPUT},
			dst_stage = {vk.PipelineStageFlag.FRAGMENT_SHADER},
			image = offscreen_image,
			old_layout = .COLOR_ATTACHMENT_OPTIMAL,
			new_layout = .SHADER_READ_ONLY_OPTIMAL,
		}
		encode_memory_barrier(encoder, &barrier)
	}
}

encode_passes :: proc(encoder: ^Encoder, passes: ..any) {
	prev_type: PassType = .COMPUTE // Initialize to avoid barriers on first pass
	first_pass := true
	
	for pass in passes {
		// Skip manual memory sync passes - we handle them automatically now
		switch p in pass {
		case ^MemorySync, MemorySync:
			continue
		}
		
		curr_type := get_pass_type(pass)
		
		// Insert automatic barrier if needed (skip for first pass)
		if !first_pass {
			// We need offscreen_image for image layout transitions
			// For now, we'll assume it exists as a global - this could be parameterized
			insert_automatic_barrier(encoder, prev_type, curr_type, offscreen_image)
		}
		
		// Execute the actual pass
		switch p in pass {
		case ^ComputePass: encode_compute(encoder, p)
		case ^RenderPass: encode_render(encoder, p)
		case ComputePass:
			temp := p
			encode_compute(encoder, &temp)
		case RenderPass:
			temp := p
			encode_render(encoder, &temp)
		}
		
		prev_type = curr_type
		first_pass = false
	}
}
