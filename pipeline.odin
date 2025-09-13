package main

import "core:c"
import "core:fmt"
import "core:os"
import "core:strings"
import vk "vendor:vulkan"

pipeline_cache: map[string]PipelineEntry

PipelineEntry :: struct {
	pipeline:               vk.Pipeline,
	layout:                 vk.PipelineLayout,
	descriptor_set_layouts: []vk.DescriptorSetLayout,
}

// Global descriptor pool for all descriptor sets
global_descriptor_pool: vk.DescriptorPool

// Initialize global descriptor pool
init_descriptor_pool :: proc() -> bool {
	pool_sizes := [2]vk.DescriptorPoolSize {
		{type = .SAMPLED_IMAGE, descriptorCount = 100},
		{type = .SAMPLER, descriptorCount = 100},
	}

	pool_info := vk.DescriptorPoolCreateInfo {
		sType         = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
		flags         = {},
		poolSizeCount = len(pool_sizes),
		pPoolSizes    = raw_data(pool_sizes[:]),
		maxSets       = 100,
	}

	if vk.CreateDescriptorPool(device, &pool_info, nil, &global_descriptor_pool) !=
	   vk.Result.SUCCESS {
		return false
	}
	return true
}

// Create a simple descriptor set for texture + sampler
create_texture_descriptor_set :: proc(texture_view: vk.ImageView, sampler: vk.Sampler, layout: vk.DescriptorSetLayout) -> vk.DescriptorSet {
	alloc_info := vk.DescriptorSetAllocateInfo {
		sType              = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
		descriptorPool     = global_descriptor_pool,
		descriptorSetCount = 1,
		pSetLayouts        = &layout,
	}

	descriptor_set: vk.DescriptorSet
	if vk.AllocateDescriptorSets(device, &alloc_info, &descriptor_set) != vk.Result.SUCCESS {
		fmt.println("Failed to allocate descriptor set")
		return {}
	}

	// Update texture binding
	image_info := vk.DescriptorImageInfo {
		imageView   = texture_view,
		imageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
	}

	sampler_info := vk.DescriptorImageInfo {
		sampler = sampler,
	}

	writes := [2]vk.WriteDescriptorSet {
		{
			sType           = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet          = descriptor_set,
			dstBinding      = 0,
			dstArrayElement = 0,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = 1,
			pImageInfo      = &image_info,
		},
		{
			sType           = vk.StructureType.WRITE_DESCRIPTOR_SET,
			dstSet          = descriptor_set,
			dstBinding      = 1,
			dstArrayElement = 0,
			descriptorType  = .SAMPLER,
			descriptorCount = 1,
			pImageInfo      = &sampler_info,
		},
	}

	vk.UpdateDescriptorSets(device, len(writes), raw_data(writes[:]), 0, nil)
	return descriptor_set
}

// Get or create basic graphics pipeline
get_basic_graphics_pipeline :: proc(render_pass: vk.RenderPass) -> (vk.Pipeline, vk.PipelineLayout, vk.DescriptorSetLayout) {
	key := "basic_graphics"

	if cached, ok := pipeline_cache[key]; ok {
		layout := cached.descriptor_set_layouts[0] if len(cached.descriptor_set_layouts) > 0 else vk.DescriptorSetLayout{}
		return cached.pipeline, cached.layout, layout
	}

	// Compile shaders
	if !compile_shader("vertex.hlsl") || !compile_shader("fragment.hlsl") {
		return {}, {}, {}
	}

	// Load compiled shader code
	vert_code, vert_ok := load_shader_spirv("vertex.spv")
	frag_code, frag_ok := load_shader_spirv("fragment.spv")
	if !vert_ok || !frag_ok {
		return {}, {}, {}
	}
	defer delete(vert_code)
	defer delete(frag_code)

	// Create shader modules
	vert_module, frag_module: vk.ShaderModule

	vert_create := vk.ShaderModuleCreateInfo {
		sType    = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(vert_code) * size_of(u32),
		pCode    = raw_data(vert_code),
	}
	frag_create := vk.ShaderModuleCreateInfo {
		sType    = vk.StructureType.SHADER_MODULE_CREATE_INFO,
		codeSize = len(frag_code) * size_of(u32),
		pCode    = raw_data(frag_code),
	}

	if vk.CreateShaderModule(device, &vert_create, nil, &vert_module) != vk.Result.SUCCESS ||
	   vk.CreateShaderModule(device, &frag_create, nil, &frag_module) != vk.Result.SUCCESS {
		return {}, {}, {}
	}
	defer vk.DestroyShaderModule(device, vert_module, nil)
	defer vk.DestroyShaderModule(device, frag_module, nil)

	// Create descriptor set layout for texture + sampler
	bindings := [2]vk.DescriptorSetLayoutBinding {
		{
			binding         = 0,
			descriptorType  = .SAMPLED_IMAGE,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
		{
			binding         = 1,
			descriptorType  = .SAMPLER,
			descriptorCount = 1,
			stageFlags      = {.FRAGMENT},
		},
	}

	descriptor_layout_info := vk.DescriptorSetLayoutCreateInfo {
		sType        = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
		bindingCount = len(bindings),
		pBindings    = raw_data(bindings[:]),
	}

	descriptor_set_layout: vk.DescriptorSetLayout
	if vk.CreateDescriptorSetLayout(device, &descriptor_layout_info, nil, &descriptor_set_layout) != vk.Result.SUCCESS {
		return {}, {}, {}
	}

	// Create pipeline layout
	layout_info := vk.PipelineLayoutCreateInfo {
		sType          = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
		setLayoutCount = 1,
		pSetLayouts    = &descriptor_set_layout,
	}

	pipeline_layout: vk.PipelineLayout
	if vk.CreatePipelineLayout(device, &layout_info, nil, &pipeline_layout) != vk.Result.SUCCESS {
		vk.DestroyDescriptorSetLayout(device, descriptor_set_layout, nil)
		return {}, {}, {}
	}

	// Configure graphics pipeline
	stages := [2]vk.PipelineShaderStageCreateInfo {
		{
			sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {vk.ShaderStageFlag.VERTEX},
			module = vert_module,
			pName = "main",
		},
		{
			sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
			stage = {vk.ShaderStageFlag.FRAGMENT},
			module = frag_module,
			pName = "main",
		},
	}

	vertex_input := vk.PipelineVertexInputStateCreateInfo {
		sType = vk.StructureType.PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
	}

	input_assembly := vk.PipelineInputAssemblyStateCreateInfo {
		sType    = vk.StructureType.PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
		topology = vk.PrimitiveTopology.TRIANGLE_LIST,
	}

	viewport := vk.Viewport {
		width    = f32(width),
		height   = f32(height),
		maxDepth = 1.0,
	}
	scissor := vk.Rect2D {
		extent = {width, height},
	}
	viewport_state := vk.PipelineViewportStateCreateInfo {
		sType         = vk.StructureType.PIPELINE_VIEWPORT_STATE_CREATE_INFO,
		viewportCount = 1,
		pViewports    = &viewport,
		scissorCount  = 1,
		pScissors     = &scissor,
	}

	rasterizer := vk.PipelineRasterizationStateCreateInfo {
		sType       = vk.StructureType.PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
		polygonMode = vk.PolygonMode.FILL,
		lineWidth   = 1.0,
		frontFace   = vk.FrontFace.CLOCKWISE,
	}

	multisampling := vk.PipelineMultisampleStateCreateInfo {
		sType                = vk.StructureType.PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
		rasterizationSamples = {vk.SampleCountFlag._1},
	}

	color_attachment := vk.PipelineColorBlendAttachmentState {
		colorWriteMask = {
			vk.ColorComponentFlag.R,
			vk.ColorComponentFlag.G,
			vk.ColorComponentFlag.B,
			vk.ColorComponentFlag.A,
		},
	}

	color_blending := vk.PipelineColorBlendStateCreateInfo {
		sType           = vk.StructureType.PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
		attachmentCount = 1,
		pAttachments    = &color_attachment,
	}

	pipeline_info := vk.GraphicsPipelineCreateInfo {
		sType               = vk.StructureType.GRAPHICS_PIPELINE_CREATE_INFO,
		stageCount          = 2,
		pStages             = raw_data(stages[:]),
		pVertexInputState   = &vertex_input,
		pInputAssemblyState = &input_assembly,
		pViewportState      = &viewport_state,
		pRasterizationState = &rasterizer,
		pMultisampleState   = &multisampling,
		pColorBlendState    = &color_blending,
		layout              = pipeline_layout,
		renderPass          = render_pass,
	}

	pipeline: vk.Pipeline
	if vk.CreateGraphicsPipelines(device, {}, 1, &pipeline_info, nil, &pipeline) != vk.Result.SUCCESS {
		vk.DestroyPipelineLayout(device, pipeline_layout, nil)
		vk.DestroyDescriptorSetLayout(device, descriptor_set_layout, nil)
		return {}, {}, {}
	}

	// Cache the pipeline
	layouts := make([]vk.DescriptorSetLayout, 1)
	layouts[0] = descriptor_set_layout
	pipeline_cache[strings.clone(key)] = PipelineEntry {
		pipeline               = pipeline,
		layout                 = pipeline_layout,
		descriptor_set_layouts = layouts,
	}

	return pipeline, pipeline_layout, descriptor_set_layout
}

// Shader compilation
compile_shader :: proc(hlsl_file: string) -> bool {
	spv_file, _ := strings.replace(hlsl_file, ".hlsl", ".spv", 1)
	defer delete(spv_file)

	stage_flag := ""
	if strings.contains(hlsl_file, "vertex") {
		stage_flag = "-T vs_6_0"
	} else if strings.contains(hlsl_file, "fragment") {
		stage_flag = "-T ps_6_0"
	} else {
		return false
	}

	cmd := fmt.aprintf("dxc -spirv %s -E main -fspv-target-env=vulkan1.3 -Fo %s %s", stage_flag, spv_file, hlsl_file)
	defer delete(cmd)
	cmd_cstr := strings.clone_to_cstring(cmd)
	defer delete(cmd_cstr)

	if system(cmd_cstr) != 0 {
		fmt.printf("Failed to compile %s\n", hlsl_file)
		return false
	}
	return true
}

cleanup_pipelines :: proc() {
	for key, entry in pipeline_cache {
		vk.DestroyPipeline(device, entry.pipeline, nil)
		vk.DestroyPipelineLayout(device, entry.layout, nil)
		for layout in entry.descriptor_set_layouts {
			vk.DestroyDescriptorSetLayout(device, layout, nil)
		}
		delete(entry.descriptor_set_layouts)
		delete(key)
	}
	delete(pipeline_cache)

	if global_descriptor_pool != {} {
		vk.DestroyDescriptorPool(device, global_descriptor_pool, nil)
	}
}