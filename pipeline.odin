package main

import vk "vendor:vulkan"
import "core:fmt"
import "core:strings"
import "core:os"
import "core:c"
import "core:strconv"

// Unified pass system for easy composition
PassType :: enum {
    COMPUTE,
    GRAPHICS,
}



CommandEncoder :: struct {
    command_buffer: vk.CommandBuffer,
}

PipelineEntry :: struct {
    pipeline: vk.Pipeline,
    layout: vk.PipelineLayout,
    descriptor_set_layouts: []vk.DescriptorSetLayout,
}

// Function to get descriptor set layout for a specific pipeline
get_pipeline_descriptor_layout :: proc(pipeline_name: string) -> (vk.DescriptorSetLayout, bool) {
    if entry, ok := pipeline_cache[pipeline_name]; ok {
        if len(entry.descriptor_set_layouts) > 0 {
            return entry.descriptor_set_layouts[0], true
        }
    }
    return {}, false
}

// Resource union for different descriptor types
DescriptorResource :: union {
    vk.Buffer,
    struct { image_view: vk.ImageView, sampler: vk.Sampler },
}

// Create a descriptor set using the pipeline's layout with flexible resources
create_pipeline_descriptor_generic :: proc(pipeline_name: string, resources: []DescriptorResource) -> (vk.DescriptorSet, bool) {
    layout, ok := get_pipeline_descriptor_layout(pipeline_name)
    if !ok {
        fmt.printf("Pipeline %s not found or has no descriptor layouts\n", pipeline_name)
        return {}, false
    }
    
    // Need to determine pool sizes from the pipeline's layout
    // For now, create a pool that can handle common descriptor types
    pool_sizes := [4]vk.DescriptorPoolSize{
        {type = .STORAGE_BUFFER, descriptorCount = 4},
        {type = .UNIFORM_BUFFER, descriptorCount = 4}, 
        {type = .SAMPLED_IMAGE, descriptorCount = 4},
        {type = .SAMPLER, descriptorCount = 4},
    }
    
    pool_info := vk.DescriptorPoolCreateInfo{
        sType = vk.StructureType.DESCRIPTOR_POOL_CREATE_INFO,
        poolSizeCount = len(pool_sizes),
        pPoolSizes = raw_data(pool_sizes[:]),
        maxSets = 1,
    }
    
    pool: vk.DescriptorPool
    if vk.CreateDescriptorPool(device, &pool_info, nil, &pool) != vk.Result.SUCCESS {
        return {}, false
    }
    
    alloc_info := vk.DescriptorSetAllocateInfo{
        sType = vk.StructureType.DESCRIPTOR_SET_ALLOCATE_INFO,
        descriptorPool = pool,
        descriptorSetCount = 1,
        pSetLayouts = &layout,
    }
    
    set: vk.DescriptorSet
    if vk.AllocateDescriptorSets(device, &alloc_info, &set) != vk.Result.SUCCESS {
        vk.DestroyDescriptorPool(device, pool, nil)
        return {}, false
    }
    
    // Write descriptors based on resource types
    writes := make([dynamic]vk.WriteDescriptorSet)
    defer delete(writes)
    
    buffer_infos := make([dynamic]vk.DescriptorBufferInfo)
    defer delete(buffer_infos)
    
    image_infos := make([dynamic]vk.DescriptorImageInfo)  
    defer delete(image_infos)
    
    for resource, i in resources {
        write := vk.WriteDescriptorSet{
            sType = vk.StructureType.WRITE_DESCRIPTOR_SET,
            dstSet = set,
            dstBinding = u32(i),
            dstArrayElement = 0,
            descriptorCount = 1,
        }
        
        switch r in resource {
        case vk.Buffer:
            write.descriptorType = .STORAGE_BUFFER
            buffer_info := vk.DescriptorBufferInfo{
                buffer = r,
                offset = 0,
                range = vk.DeviceSize(vk.WHOLE_SIZE),
            }
            append(&buffer_infos, buffer_info)
            write.pBufferInfo = &buffer_infos[len(buffer_infos)-1]
            
        case struct { image_view: vk.ImageView, sampler: vk.Sampler }:
            // Handle both image and sampler
            // Binding i = image, binding i+1 = sampler
            image_info := vk.DescriptorImageInfo{
                imageView = r.image_view,
                imageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL,
            }
            append(&image_infos, image_info)
            
            write.descriptorType = .SAMPLED_IMAGE
            write.pImageInfo = &image_infos[len(image_infos)-1]
            append(&writes, write)
            
            // Add sampler write
            sampler_write := write
            sampler_write.dstBinding = u32(i) + 1
            sampler_write.descriptorType = .SAMPLER
            sampler_info := vk.DescriptorImageInfo{
                sampler = r.sampler,
            }
            append(&image_infos, sampler_info)
            sampler_write.pImageInfo = &image_infos[len(image_infos)-1]
            append(&writes, sampler_write)
            continue
        }
        
        append(&writes, write)
    }
    
    if len(writes) > 0 {
        vk.UpdateDescriptorSets(device, u32(len(writes)), raw_data(writes), 0, nil)
    }
    
    return set, true
}


pipeline_cache: map[string]PipelineEntry

PushConstantInfo :: struct {
    data: rawptr,
    size: u32,
    stage_flags: vk.ShaderStageFlags,
}

ComputePassInfo :: struct {
    shader: string,
    workgroup_count: [3]u32,
    resources: []DescriptorResource,
    push_constants: Maybe(PushConstantInfo),
}

GraphicsPassInfo :: struct {
    vertex_shader: string,
    fragment_shader: string,
    render_pass: vk.RenderPass,
    framebuffer: vk.Framebuffer,
    vertices: u32,
    instances: u32,
    resources: []DescriptorResource,
    push_constants: Maybe(PushConstantInfo),
    clear_values: []vk.ClearValue,
}

Pass :: struct {
    type: PassType,
    compute: ComputePassInfo,
    graphics: GraphicsPassInfo,
}

// Helper functions to create passes
compute_pass :: proc(shader: string, workgroups: [3]u32, resources: []DescriptorResource, 
                    push_data: rawptr = nil, push_size: u32 = 0) -> Pass {
    pass := Pass{type = .COMPUTE}
    pass.compute.shader = shader
    pass.compute.workgroup_count = workgroups
    pass.compute.resources = resources
    
    if push_data != nil {
        pass.compute.push_constants = PushConstantInfo{
            data = push_data,
            size = push_size,
            stage_flags = {.COMPUTE},
        }
    }
    
    return pass
}

graphics_pass :: proc(vertex_shader: string, fragment_shader: string, 
                     render_pass: vk.RenderPass, framebuffer: vk.Framebuffer,
                     vertices: u32, instances: u32 = 1,
                     resources: []DescriptorResource = nil,
                     vertex_push_data: rawptr = nil, vertex_push_size: u32 = 0,
                     fragment_push_data: rawptr = nil, fragment_push_size: u32 = 0,
                     clear_values: []vk.ClearValue = nil) -> Pass {
    pass := Pass{type = .GRAPHICS}
    pass.graphics.vertex_shader = vertex_shader
    pass.graphics.fragment_shader = fragment_shader
    pass.graphics.render_pass = render_pass
    pass.graphics.framebuffer = framebuffer
    pass.graphics.vertices = vertices
    pass.graphics.instances = instances
    pass.graphics.resources = resources
    pass.graphics.clear_values = clear_values
    
    // Handle push constants - prioritize vertex, then fragment
    if vertex_push_data != nil {
        pass.graphics.push_constants = PushConstantInfo{
            data = vertex_push_data,
            size = vertex_push_size,
            stage_flags = {.VERTEX},
        }
    } else if fragment_push_data != nil {
        pass.graphics.push_constants = PushConstantInfo{
            data = fragment_push_data,
            size = fragment_push_size,
            stage_flags = {.FRAGMENT},
        }
    }
    
    return pass
}

// Execute a sequence of passes
execute_passes :: proc(encoder: ^CommandEncoder, passes: []Pass) {
    for i in 0..<len(passes) {
        pass := &passes[i]
        
        switch pass.type {
        case .COMPUTE:
            execute_compute_pass(encoder, &pass.compute)
        case .GRAPHICS:
            execute_graphics_pass(encoder, &pass.graphics)
        }
        
        // Insert barriers between passes if needed
        if i < len(passes) - 1 {
            insert_pass_barrier(encoder, pass.type, passes[i+1].type)
        }
    }
}

execute_compute_pass :: proc(encoder: ^CommandEncoder, pass: ^ComputePassInfo) {
    pipeline, layout := get_compute_pipeline(pass.shader, pass.push_constants)
    if pipeline == {} do return
    
    vk.CmdBindPipeline(encoder.command_buffer, .COMPUTE, pipeline)
    
    // Auto-create descriptor set from resources
    if len(pass.resources) > 0 {
        if descriptor_set, ok := create_pipeline_descriptor_generic(pass.shader, pass.resources); ok {
            vk.CmdBindDescriptorSets(encoder.command_buffer, .COMPUTE, layout,
                                    0, 1, &descriptor_set, 0, nil)
        }
    }
    
    if push_info, has_push := pass.push_constants.?; has_push {
        vk.CmdPushConstants(encoder.command_buffer, layout, 
                           push_info.stage_flags, 0, push_info.size, push_info.data)
    }
    
    vk.CmdDispatch(encoder.command_buffer, pass.workgroup_count.x, 
                   pass.workgroup_count.y, pass.workgroup_count.z)
}

execute_graphics_pass :: proc(encoder: ^CommandEncoder, pass: ^GraphicsPassInfo) {
    pipeline, layout := get_graphics_pipeline(pass.vertex_shader, pass.fragment_shader, 
                                             pass.render_pass, pass.push_constants)
    if pipeline == {} do return
    
    render_area := vk.Rect2D{extent = {width, height}}
    
    begin_info := vk.RenderPassBeginInfo{
        sType = vk.StructureType.RENDER_PASS_BEGIN_INFO,
        renderPass = pass.render_pass,
        framebuffer = pass.framebuffer,
        renderArea = render_area,
    }
    
    if len(pass.clear_values) > 0 {
        begin_info.clearValueCount = u32(len(pass.clear_values))
        begin_info.pClearValues = raw_data(pass.clear_values)
    }
    
    vk.CmdBeginRenderPass(encoder.command_buffer, &begin_info, .INLINE)
    vk.CmdBindPipeline(encoder.command_buffer, .GRAPHICS, pipeline)
    
    // Auto-create descriptor set from resources
    if len(pass.resources) > 0 {
        graphics_key := fmt.aprintf("%s+%s+%dx%d", pass.vertex_shader, pass.fragment_shader, width, height)
        defer delete(graphics_key)
        if descriptor_set, ok := create_pipeline_descriptor_generic(graphics_key, pass.resources); ok {
            vk.CmdBindDescriptorSets(encoder.command_buffer, .GRAPHICS, layout,
                                    0, 1, &descriptor_set, 0, nil)
        }
    }
    
    if push_info, has_push := pass.push_constants.?; has_push {
        vk.CmdPushConstants(encoder.command_buffer, layout,
                           push_info.stage_flags, 0, push_info.size, push_info.data)
    }
    
    vk.CmdDraw(encoder.command_buffer, pass.vertices, pass.instances, 0, 0)
    vk.CmdEndRenderPass(encoder.command_buffer)
}

insert_pass_barrier :: proc(encoder: ^CommandEncoder, from_type: PassType, to_type: PassType) {
    src_stage: vk.PipelineStageFlags
    dst_stage: vk.PipelineStageFlags
    src_access: vk.AccessFlags
    dst_access: vk.AccessFlags
    
    switch from_type {
    case .COMPUTE:
        src_stage = {.COMPUTE_SHADER}
        src_access = {.SHADER_WRITE}
    case .GRAPHICS:
        src_stage = {.COLOR_ATTACHMENT_OUTPUT}
        src_access = {.COLOR_ATTACHMENT_WRITE}
    }
    
    switch to_type {
    case .COMPUTE:
        dst_stage = {.COMPUTE_SHADER}
        dst_access = {.SHADER_READ}
    case .GRAPHICS:
        dst_stage = {.VERTEX_SHADER}
        dst_access = {.SHADER_READ}
    }
    
    memory_barrier := vk.MemoryBarrier{
        sType = vk.StructureType.MEMORY_BARRIER,
        srcAccessMask = src_access,
        dstAccessMask = dst_access,
    }
    
    vk.CmdPipelineBarrier(encoder.command_buffer, src_stage, dst_stage, {},
                         1, &memory_barrier, 0, nil, 0, nil)
}


// Helper to detect shader descriptor usage from WGSL
detect_shader_descriptors :: proc(wgsl_content: string) -> []vk.DescriptorSetLayoutBinding {
    bindings := make([dynamic]vk.DescriptorSetLayoutBinding)
    
    lines := strings.split(wgsl_content, "\n")
    defer delete(lines)
    
    for line in lines {
        trimmed := strings.trim_space(line)
        
        // Look for @group(X) @binding(Y) var<storage, ...> patterns
        if strings.contains(trimmed, "@group(") && strings.contains(trimmed, "@binding(") {
            // Extract group and binding numbers
            group_start := strings.index(trimmed, "@group(")
            binding_start := strings.index(trimmed, "@binding(")
            
            if group_start >= 0 && binding_start >= 0 {
                // For now, assume group 0 and extract binding number
                if strings.contains(trimmed, "@group(0)") {
                    binding_num_start := binding_start + len("@binding(")
                    binding_end := strings.index(trimmed[binding_num_start:], ")")
                    if binding_end > 0 {
                        binding_str := trimmed[binding_num_start:binding_num_start+binding_end]
                        if binding_num, ok := strconv.parse_int(binding_str); ok {
                            descriptor_type := vk.DescriptorType.STORAGE_BUFFER
                            
                            // Determine descriptor type based on var declaration
                            if strings.contains(trimmed, "var<storage,") {
                                descriptor_type = .STORAGE_BUFFER
                            } else if strings.contains(trimmed, "var<uniform,") {
                                descriptor_type = .UNIFORM_BUFFER
                            } else if strings.contains(trimmed, "texture_2d") || strings.contains(trimmed, "texture_3d") {
                                descriptor_type = .SAMPLED_IMAGE
                            } else if strings.contains(trimmed, "sampler") {
                                descriptor_type = .SAMPLER
                            }
                            
                            binding := vk.DescriptorSetLayoutBinding{
                                binding = u32(binding_num),
                                descriptorType = descriptor_type,
                                descriptorCount = 1,
                                stageFlags = {.COMPUTE, .VERTEX, .FRAGMENT}, // Will be filtered per pipeline
                            }
                            append(&bindings, binding)
                        }
                    }
                }
            }
        }
    }
    
    return bindings[:]
}

// Generic pipeline creation
get_graphics_pipeline :: proc(vertex_shader: string, fragment_shader: string, 
                             render_pass: vk.RenderPass, 
                             push_constants: Maybe(PushConstantInfo)) -> (vk.Pipeline, vk.PipelineLayout) {
    key := fmt.aprintf("%s+%s+%dx%d", vertex_shader, fragment_shader, width, height)
    defer delete(key)
    
    if cached, ok := pipeline_cache[key]; ok {
        return cached.pipeline, cached.layout
    }
    
    if !compile_shader(vertex_shader) || !compile_shader(fragment_shader) {
        return {}, {}
    }
    
    // Read WGSL files to detect descriptors
    vert_content, vert_read_ok := os.read_entire_file(vertex_shader)
    frag_content, frag_read_ok := os.read_entire_file(fragment_shader)
    if !vert_read_ok || !frag_read_ok {
        fmt.printf("Failed to read shader files\n")
        return {}, {}
    }
    defer delete(vert_content)
    defer delete(frag_content)
    
    vert_text := string(vert_content)
    frag_text := string(frag_content)
    
    vert_bindings := detect_shader_descriptors(vert_text)
    frag_bindings := detect_shader_descriptors(frag_text)
    defer delete(vert_bindings)
    defer delete(frag_bindings)
    
    // Combine and deduplicate bindings
    combined_bindings := make([dynamic]vk.DescriptorSetLayoutBinding)
    defer delete(combined_bindings)
    
    // Add vertex bindings with broad stage compatibility
    for binding in vert_bindings {
        graphics_binding := binding
        graphics_binding.stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE}
        append(&combined_bindings, graphics_binding)
    }
    
    // Add fragment bindings (merge if binding already exists)
    for frag_binding in frag_bindings {
        found := false
        for &existing_binding in combined_bindings {
            if existing_binding.binding == frag_binding.binding {
                // Already added with broad compatibility
                found = true
                break
            }
        }
        if !found {
            graphics_binding := frag_binding
            graphics_binding.stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE}
            append(&combined_bindings, graphics_binding)
        }
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
    
    // Create descriptor set layout if bindings exist
    descriptor_set_layouts := make([dynamic]vk.DescriptorSetLayout)
    defer delete(descriptor_set_layouts)
    
    if len(combined_bindings) > 0 {
        descriptor_layout_info := vk.DescriptorSetLayoutCreateInfo{
            sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            bindingCount = u32(len(combined_bindings)),
            pBindings = raw_data(combined_bindings),
        }
        
        descriptor_set_layout: vk.DescriptorSetLayout
        if vk.CreateDescriptorSetLayout(device, &descriptor_layout_info, nil, &descriptor_set_layout) != vk.Result.SUCCESS {
            return {}, {}
        }
        append(&descriptor_set_layouts, descriptor_set_layout)
    }
    
    // Create pipeline layout with descriptor set layouts and optional push constants
    layout_info := vk.PipelineLayoutCreateInfo{
        sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = u32(len(descriptor_set_layouts)),
        pSetLayouts = len(descriptor_set_layouts) > 0 ? raw_data(descriptor_set_layouts) : nil,
    }
    
    // Add push constants if provided
    push_range: vk.PushConstantRange
    if push_info, has_push := push_constants.?; has_push {
        push_range = vk.PushConstantRange{
            stageFlags = push_info.stage_flags,
            offset = 0,
            size = push_info.size,
        }
        layout_info.pushConstantRangeCount = 1
        layout_info.pPushConstantRanges = &push_range
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
    
    // Cache the result
    cached_layouts := make([]vk.DescriptorSetLayout, len(descriptor_set_layouts))
    copy(cached_layouts, descriptor_set_layouts[:])
    pipeline_cache[strings.clone(key)] = PipelineEntry{
        pipeline = pipeline, 
        layout = layout,
        descriptor_set_layouts = cached_layouts,
    }
    
    return pipeline, layout
}

get_compute_pipeline :: proc(shader: string, push_constants: Maybe(PushConstantInfo)) -> (vk.Pipeline, vk.PipelineLayout) {
    if cached, ok := pipeline_cache[shader]; ok {
        return cached.pipeline, cached.layout
    }
    
    if !compile_shader(shader) {
        return {}, {}
    }
    
    // Read WGSL file to detect descriptors
    wgsl_content, read_ok := os.read_entire_file(shader)
    if !read_ok {
        fmt.printf("Failed to read shader file: %s\n", shader)
        return {}, {}
    }
    defer delete(wgsl_content)
    
    wgsl_text := string(wgsl_content)
    bindings := detect_shader_descriptors(wgsl_text)
    defer delete(bindings)
    
    // Filter bindings for compute stage
    compute_bindings := make([dynamic]vk.DescriptorSetLayoutBinding)
    defer delete(compute_bindings)
    
    for binding in bindings {
        compute_binding := binding
        // Make it compatible with existing descriptors by using broader stage flags
        compute_binding.stageFlags = {.VERTEX, .FRAGMENT, .COMPUTE}
        append(&compute_bindings, compute_binding)
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
    
    // Create descriptor set layout if bindings exist
    descriptor_set_layouts := make([dynamic]vk.DescriptorSetLayout)
    defer delete(descriptor_set_layouts)
    
    if len(compute_bindings) > 0 {
        descriptor_layout_info := vk.DescriptorSetLayoutCreateInfo{
            sType = vk.StructureType.DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            bindingCount = u32(len(compute_bindings)),
            pBindings = raw_data(compute_bindings),
        }
        
        descriptor_set_layout: vk.DescriptorSetLayout
        if vk.CreateDescriptorSetLayout(device, &descriptor_layout_info, nil, &descriptor_set_layout) != vk.Result.SUCCESS {
            return {}, {}
        }
        append(&descriptor_set_layouts, descriptor_set_layout)
    }
    
    // Create pipeline layout with descriptor set layouts and optional push constants
    layout_info := vk.PipelineLayoutCreateInfo{
        sType = vk.StructureType.PIPELINE_LAYOUT_CREATE_INFO,
        setLayoutCount = u32(len(descriptor_set_layouts)),
        pSetLayouts = len(descriptor_set_layouts) > 0 ? raw_data(descriptor_set_layouts) : nil,
    }
    
    push_range: vk.PushConstantRange
    if push_info, has_push := push_constants.?; has_push {
        push_range = vk.PushConstantRange{
            stageFlags = push_info.stage_flags,
            offset = 0,
            size = push_info.size,
        }
        layout_info.pushConstantRangeCount = 1
        layout_info.pPushConstantRanges = &push_range
    }
    
    layout: vk.PipelineLayout
    if vk.CreatePipelineLayout(device, &layout_info, nil, &layout) != vk.Result.SUCCESS {
        return {}, {}
    }
    
    stage := vk.PipelineShaderStageCreateInfo{
        sType = vk.StructureType.PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = {vk.ShaderStageFlag.COMPUTE},
        module = shader_module,
        pName = "main",
    }
    
    pipeline_info := vk.ComputePipelineCreateInfo{
        sType = vk.StructureType.COMPUTE_PIPELINE_CREATE_INFO,
        stage = stage,
        layout = layout,
    }
    
    pipeline: vk.Pipeline
    if vk.CreateComputePipelines(device, {}, 1, &pipeline_info, nil, &pipeline) != vk.Result.SUCCESS {
        vk.DestroyPipelineLayout(device, layout, nil)
        return {}, {}
    }
    
    // Cache the result
    cached_layouts := make([]vk.DescriptorSetLayout, len(descriptor_set_layouts))
    copy(cached_layouts, descriptor_set_layouts[:])
    pipeline_cache[strings.clone(shader)] = PipelineEntry{
        pipeline = pipeline, 
        layout = layout,
        descriptor_set_layouts = cached_layouts,
    }
    
    return pipeline, layout
}

// Shader compilation
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

// load_shader_spirv is already defined in vulkan.odin

// Generic render pass creation
create_render_pass :: proc(format: vk.Format, final_layout: vk.ImageLayout = vk.ImageLayout.SHADER_READ_ONLY_OPTIMAL) -> vk.RenderPass {
    attachment := vk.AttachmentDescription{
        format = format,
        samples = {vk.SampleCountFlag._1},
        loadOp = vk.AttachmentLoadOp.CLEAR,
        storeOp = vk.AttachmentStoreOp.STORE,
        stencilLoadOp = vk.AttachmentLoadOp.DONT_CARE,
        stencilStoreOp = vk.AttachmentStoreOp.DONT_CARE,
        initialLayout = vk.ImageLayout.UNDEFINED,
        finalLayout = final_layout,
    }

    attachment_ref := vk.AttachmentReference{
        attachment = 0,
        layout = vk.ImageLayout.COLOR_ATTACHMENT_OPTIMAL,
    }

    subpass := vk.SubpassDescription{
        pipelineBindPoint = vk.PipelineBindPoint.GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments = &attachment_ref,
    }

    render_pass_info := vk.RenderPassCreateInfo{
        sType = vk.StructureType.RENDER_PASS_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &attachment,
        subpassCount = 1,
        pSubpasses = &subpass,
    }

    render_pass: vk.RenderPass
    if vk.CreateRenderPass(device, &render_pass_info, nil, &render_pass) != vk.Result.SUCCESS {
        fmt.println("Failed to create render pass")
        return {}
    }

    return render_pass
}

// Generic framebuffer creation
create_framebuffer :: proc(render_pass: vk.RenderPass, image_view: vk.ImageView, width, height: u32) -> vk.Framebuffer {
    attachments := [1]vk.ImageView{image_view}
    
    fb_info := vk.FramebufferCreateInfo{
        sType = vk.StructureType.FRAMEBUFFER_CREATE_INFO,
        renderPass = render_pass,
        attachmentCount = 1,
        pAttachments = raw_data(attachments[:]),
        width = width,
        height = height,
        layers = 1,
    }

    framebuffer: vk.Framebuffer
    if vk.CreateFramebuffer(device, &fb_info, nil, &framebuffer) != vk.Result.SUCCESS {
        fmt.println("Failed to create framebuffer")
        return {}
    }

    return framebuffer
}

// Command encoding helpers
begin_encoding :: proc(element: ^SwapchainElement) -> CommandEncoder {
    encoder := CommandEncoder{command_buffer = element.commandBuffer}
    
    begin_info := vk.CommandBufferBeginInfo{
        sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
        flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
    }
    
    vk.BeginCommandBuffer(encoder.command_buffer, &begin_info)
    return encoder
}

finish_encoding :: proc(encoder: ^CommandEncoder) {
    vk.EndCommandBuffer(encoder.command_buffer)
}

