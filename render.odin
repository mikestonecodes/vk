package main

import "core:fmt"
import "core:time"
import vk "vendor:vulkan"

// Texture resources
textureImage: vk.Image
textureImageMemory: vk.DeviceMemory
textureImageView: vk.ImageView

init_render_resources :: proc() {
	// Load texture
	textureImage, textureImageMemory, textureImageView, _ = loadTextureFromFile("test3.png")
	fmt.println("DEBUG: Basic render resources initialized")
}

record_commands :: proc(element: ^SwapchainElement, start_time: time.Time) {
	// Begin command buffer
	begin_info := vk.CommandBufferBeginInfo {
		sType = vk.StructureType.COMMAND_BUFFER_BEGIN_INFO,
		flags = {vk.CommandBufferUsageFlag.ONE_TIME_SUBMIT},
	}
	vk.BeginCommandBuffer(element.commandBuffer, &begin_info)

	// Get basic graphics pipeline
	pipeline, pipeline_layout, descriptor_layout := get_basic_graphics_pipeline(render_pass)
	if pipeline == {} {
		fmt.println("Failed to get graphics pipeline")
		vk.EndCommandBuffer(element.commandBuffer)
		return
	}

	// Create descriptor set for texture
	descriptor_set := create_texture_descriptor_set(textureImageView, texture_sampler, descriptor_layout)
	if descriptor_set == {} {
		fmt.println("Failed to create descriptor set")
		vk.EndCommandBuffer(element.commandBuffer)
		return
	}

	// Begin render pass
	clear_color := vk.ClearValue {
		color = vk.ClearColorValue {
			float32 = {0.2, 0.3, 0.6, 1.0},
		},
	}

	render_pass_info := vk.RenderPassBeginInfo {
		sType       = vk.StructureType.RENDER_PASS_BEGIN_INFO,
		renderPass  = render_pass,
		framebuffer = element.framebuffer,
		renderArea  = {
			extent = {width, height},
		},
		clearValueCount = 1,
		pClearValues    = &clear_color,
	}

	vk.CmdBeginRenderPass(element.commandBuffer, &render_pass_info, .INLINE)

	// Bind pipeline and draw
	vk.CmdBindPipeline(element.commandBuffer, .GRAPHICS, pipeline)
	vk.CmdBindDescriptorSets(
		element.commandBuffer,
		.GRAPHICS,
		pipeline_layout,
		0,
		1,
		&descriptor_set,
		0,
		nil,
	)

	// Draw fullscreen quad (6 vertices)
	vk.CmdDraw(element.commandBuffer, 6, 1, 0, 0)

	vk.CmdEndRenderPass(element.commandBuffer)
	vk.EndCommandBuffer(element.commandBuffer)
}

cleanup_render_resources :: proc() {
	if textureImageView != {} {
		vk.DestroyImageView(device, textureImageView, nil)
	}
	if textureImage != {} {
		vk.DestroyImage(device, textureImage, nil)
	}
	if textureImageMemory != {} {
		vk.FreeMemory(device, textureImageMemory, nil)
	}
}