package main

import "core:fmt"
import "core:c"
import "core:os"
import "base:runtime"

foreign import vulkan "system:vulkan"

// Vulkan types
VkResult :: c.int
VkInstance :: rawptr
VkSurfaceKHR :: rawptr
VkPhysicalDevice :: rawptr
VkDevice :: rawptr
VkQueue :: rawptr
VkSwapchainKHR :: rawptr
VkImage :: rawptr
VkImageView :: rawptr
VkRenderPass :: rawptr
VkPipelineLayout :: rawptr
VkPipeline :: rawptr
VkFramebuffer :: rawptr
VkCommandPool :: rawptr
VkCommandBuffer :: rawptr
VkShaderModule :: rawptr
VkSemaphore :: rawptr
VkFence :: rawptr
VkFormat :: c.uint32_t
VkDebugUtilsMessengerEXT :: rawptr

// Vulkan constants - only the ones actually used
VK_SUCCESS :: 0
VK_NULL_HANDLE: rawptr = nil
VK_ERROR_OUT_OF_DATE_KHR :: -1000001004
VK_SUBOPTIMAL_KHR :: 1000001003
VK_TRUE :: 1
VK_FALSE :: 0
UINT64_MAX :: 0xFFFFFFFFFFFFFFFF
VK_API_VERSION_1_0: c.uint32_t = (1 << 22) | (0 << 12) | 0

// Structure type constants
VK_STRUCTURE_TYPE_APPLICATION_INFO :: 0
VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO :: 1
VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR :: 1000006000
VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO :: 2
VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO :: 3
VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR :: 1000001000
VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO :: 15
VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO :: 38
VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO :: 37
VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO :: 39
VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO :: 40
VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO :: 43
VK_STRUCTURE_TYPE_SUBMIT_INFO :: 4
VK_STRUCTURE_TYPE_PRESENT_INFO_KHR :: 1000001001
VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO :: 9
VK_STRUCTURE_TYPE_FENCE_CREATE_INFO :: 8
VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO :: 42
VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO :: 16
VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO :: 18
VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO :: 19
VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO :: 20
VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO :: 22
VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO :: 23
VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO :: 24
VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO :: 26
VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO :: 28
VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO :: 30
VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT :: 1000128004
VK_STRUCTURE_TYPE_PUSH_CONSTANT_RANGE :: 31

// Vulkan flags and enums - only used ones
VK_QUEUE_GRAPHICS_BIT :: 0x00000001
VK_FORMAT_UNDEFINED :: 0
VK_FORMAT_B8G8R8A8_UNORM :: 44
VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT :: 0x00000010
VK_SHARING_MODE_EXCLUSIVE :: 0
VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR :: 0x00000001
VK_IMAGE_ASPECT_COLOR_BIT :: 0x00000001
VK_ATTACHMENT_LOAD_OP_CLEAR :: 1
VK_ATTACHMENT_LOAD_OP_DONT_CARE :: 2
VK_ATTACHMENT_STORE_OP_STORE :: 0
VK_ATTACHMENT_STORE_OP_DONT_CARE :: 1
VK_PIPELINE_BIND_POINT_GRAPHICS :: 0
VK_IMAGE_LAYOUT_UNDEFINED :: 0
VK_IMAGE_LAYOUT_PRESENT_SRC_KHR :: 1000001002
VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL :: 2
VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT :: 0x00000002
VK_COMMAND_BUFFER_LEVEL_PRIMARY :: 0
VK_IMAGE_VIEW_TYPE_2D :: 1
VK_COMPONENT_SWIZZLE_IDENTITY :: 0
VK_FENCE_CREATE_SIGNALED_BIT :: 0x00000001
VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT :: 0x00000001
VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT :: 0x00000400
VK_SAMPLE_COUNT_1_BIT :: 0x00000001
VK_SUBPASS_CONTENTS_INLINE :: 0
VK_PRESENT_MODE_FIFO_KHR :: 2
VK_SHADER_STAGE_VERTEX_BIT :: 0x00000001
VK_SHADER_STAGE_FRAGMENT_BIT :: 0x00000010
VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST :: 3
VK_POLYGON_MODE_FILL :: 0
VK_FRONT_FACE_CLOCKWISE :: 0
VK_BLEND_FACTOR_ONE :: 0
VK_BLEND_FACTOR_ZERO :: 1
VK_BLEND_OP_ADD :: 0
VK_COLOR_COMPONENT_R_BIT :: 0x00000001
VK_COLOR_COMPONENT_G_BIT :: 0x00000002
VK_COLOR_COMPONENT_B_BIT :: 0x00000004
VK_COLOR_COMPONENT_A_BIT :: 0x00000008

// Debug constants
VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT :: 0x00000001
VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT :: 0x00000010
VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT :: 0x00000100
VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT :: 0x00001000
VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT :: 0x00000001
VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT :: 0x00000002
VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT :: 0x00000004

// Vulkan structs - only used ones
VkExtent2D :: struct {
    width: c.uint32_t,
    height: c.uint32_t,
}

VkSurfaceCapabilitiesKHR :: struct {
    minImageCount: c.uint32_t,
    maxImageCount: c.uint32_t,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: c.uint32_t,
    supportedTransforms: c.uint32_t,
    currentTransform: c.uint32_t,
    supportedCompositeAlpha: c.uint32_t,
    supportedUsageFlags: c.uint32_t,
}

VkSurfaceFormatKHR :: struct {
    format: c.uint32_t,
    colorSpace: c.uint32_t,
}

VkSwapchainCreateInfoKHR :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    surface: VkSurfaceKHR,
    minImageCount: c.uint32_t,
    imageFormat: c.uint32_t,
    imageColorSpace: c.uint32_t,
    imageExtent: VkExtent2D,
    imageArrayLayers: c.uint32_t,
    imageUsage: c.uint32_t,
    imageSharingMode: c.uint32_t,
    queueFamilyIndexCount: c.uint32_t,
    pQueueFamilyIndices: [^]c.uint32_t,
    preTransform: c.uint32_t,
    compositeAlpha: c.uint32_t,
    presentMode: c.uint32_t,
    clipped: c.uint32_t,
    oldSwapchain: VkSwapchainKHR,
}

VkImageViewCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    image: VkImage,
    viewType: c.uint32_t,
    format: c.uint32_t,
    components: [4]c.uint32_t,
    subresourceRange: struct {
        aspectMask: c.uint32_t,
        baseMipLevel: c.uint32_t,
        levelCount: c.uint32_t,
        baseArrayLayer: c.uint32_t,
        layerCount: c.uint32_t,
    },
}

VkAttachmentDescription :: struct {
    flags: c.uint32_t,
    format: c.uint32_t,
    samples: c.uint32_t,
    loadOp: c.uint32_t,
    storeOp: c.uint32_t,
    stencilLoadOp: c.uint32_t,
    stencilStoreOp: c.uint32_t,
    initialLayout: c.uint32_t,
    finalLayout: c.uint32_t,
}

VkAttachmentReference :: struct {
    attachment: c.uint32_t,
    layout: c.uint32_t,
}

VkSubpassDescription :: struct {
    flags: c.uint32_t,
    pipelineBindPoint: c.uint32_t,
    inputAttachmentCount: c.uint32_t,
    pInputAttachments: [^]VkAttachmentReference,
    colorAttachmentCount: c.uint32_t,
    pColorAttachments: [^]VkAttachmentReference,
    pResolveAttachments: [^]VkAttachmentReference,
    pDepthStencilAttachment: ^VkAttachmentReference,
    preserveAttachmentCount: c.uint32_t,
    pPreserveAttachments: [^]c.uint32_t,
}

VkRenderPassCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    attachmentCount: c.uint32_t,
    pAttachments: [^]VkAttachmentDescription,
    subpassCount: c.uint32_t,
    pSubpasses: [^]VkSubpassDescription,
    dependencyCount: c.uint32_t,
    pDependencies: rawptr,
}

VkCommandPoolCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    queueFamilyIndex: c.uint32_t,
}

VkCommandBufferAllocateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    commandPool: VkCommandPool,
    level: c.uint32_t,
    commandBufferCount: c.uint32_t,
}

VkFramebufferCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    renderPass: VkRenderPass,
    attachmentCount: c.uint32_t,
    pAttachments: [^]VkImageView,
    width: c.uint32_t,
    height: c.uint32_t,
    layers: c.uint32_t,
}

VkClearValue :: struct {
    color: struct {
        float32: [4]f32,
    },
}

VkRenderPassBeginInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    renderPass: VkRenderPass,
    framebuffer: VkFramebuffer,
    renderArea: struct {
        offset: struct { x: c.int32_t, y: c.int32_t },
        extent: VkExtent2D,
    },
    clearValueCount: c.uint32_t,
    pClearValues: [^]VkClearValue,
}

VkSubmitInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    waitSemaphoreCount: c.uint32_t,
    pWaitSemaphores: ^VkSemaphore,
    pWaitDstStageMask: ^c.uint32_t,
    commandBufferCount: c.uint32_t,
    pCommandBuffers: ^VkCommandBuffer,
    signalSemaphoreCount: c.uint32_t,
    pSignalSemaphores: ^VkSemaphore,
}

VkPresentInfoKHR :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    waitSemaphoreCount: c.uint32_t,
    pWaitSemaphores: ^VkSemaphore,
    swapchainCount: c.uint32_t,
    pSwapchains: ^VkSwapchainKHR,
    pImageIndices: ^c.uint32_t,
    pResults: ^VkResult,
}

VkCommandBufferBeginInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    pInheritanceInfo: rawptr,
}

VkApplicationInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    pApplicationName: cstring,
    applicationVersion: c.uint32_t,
    pEngineName: cstring,
    engineVersion: c.uint32_t,
    apiVersion: c.uint32_t,
}

VkInstanceCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    pApplicationInfo: ^VkApplicationInfo,
    enabledLayerCount: c.uint32_t,
    ppEnabledLayerNames: [^]cstring,
    enabledExtensionCount: c.uint32_t,
    ppEnabledExtensionNames: [^]cstring,
}

VkWaylandSurfaceCreateInfoKHR :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    display: wl_display,
    surface: wl_surface,
}

VkQueueFamilyProperties :: struct {
    queueFlags: c.uint32_t,
    queueCount: c.uint32_t,
    timestampValidBits: c.uint32_t,
    minImageTransferGranularity: [3]c.uint32_t,
}

VkDeviceQueueCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    queueFamilyIndex: c.uint32_t,
    queueCount: c.uint32_t,
    pQueuePriorities: [^]f32,
}

VkDeviceCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    queueCreateInfoCount: c.uint32_t,
    pQueueCreateInfos: [^]VkDeviceQueueCreateInfo,
    enabledLayerCount: c.uint32_t,
    ppEnabledLayerNames: [^]cstring,
    enabledExtensionCount: c.uint32_t,
    ppEnabledExtensionNames: [^]cstring,
    pEnabledFeatures: rawptr,
}

VkSemaphoreCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
}

VkFenceCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
}

VkShaderModuleCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    codeSize: c.size_t,
    pCode: [^]c.uint32_t,
}

VkPipelineShaderStageCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    stage: c.uint32_t,
    module: VkShaderModule,
    pName: cstring,
    pSpecializationInfo: rawptr,
}

VkPipelineVertexInputStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    vertexBindingDescriptionCount: c.uint32_t,
    pVertexBindingDescriptions: rawptr,
    vertexAttributeDescriptionCount: c.uint32_t,
    pVertexAttributeDescriptions: rawptr,
}

VkPipelineInputAssemblyStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    topology: c.uint32_t,
    primitiveRestartEnable: c.uint32_t,
}

VkViewport :: struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    minDepth: f32,
    maxDepth: f32,
}

VkRect2D :: struct {
    offset: struct {
        x: c.int32_t,
        y: c.int32_t,
    },
    extent: VkExtent2D,
}

VkPipelineViewportStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    viewportCount: c.uint32_t,
    pViewports: [^]VkViewport,
    scissorCount: c.uint32_t,
    pScissors: [^]VkRect2D,
}

VkPipelineRasterizationStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    depthClampEnable: c.uint32_t,
    rasterizerDiscardEnable: c.uint32_t,
    polygonMode: c.uint32_t,
    cullMode: c.uint32_t,
    frontFace: c.uint32_t,
    depthBiasEnable: c.uint32_t,
    depthBiasConstantFactor: f32,
    depthBiasClamp: f32,
    depthBiasSlopeFactor: f32,
    lineWidth: f32,
}

VkPipelineMultisampleStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    rasterizationSamples: c.uint32_t,
    sampleShadingEnable: c.uint32_t,
    minSampleShading: f32,
    pSampleMask: [^]c.uint32_t,
    alphaToCoverageEnable: c.uint32_t,
    alphaToOneEnable: c.uint32_t,
}

VkPipelineColorBlendAttachmentState :: struct {
    blendEnable: c.uint32_t,
    srcColorBlendFactor: c.uint32_t,
    dstColorBlendFactor: c.uint32_t,
    colorBlendOp: c.uint32_t,
    srcAlphaBlendFactor: c.uint32_t,
    dstAlphaBlendFactor: c.uint32_t,
    alphaBlendOp: c.uint32_t,
    colorWriteMask: c.uint32_t,
}

VkPipelineColorBlendStateCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    logicOpEnable: c.uint32_t,
    logicOp: c.uint32_t,
    attachmentCount: c.uint32_t,
    pAttachments: [^]VkPipelineColorBlendAttachmentState,
    blendConstants: [4]f32,
}

VkPushConstantRange :: struct {
    stageFlags: c.uint32_t,
    offset: c.uint32_t,
    size: c.uint32_t,
}

VkPipelineLayoutCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    setLayoutCount: c.uint32_t,
    pSetLayouts: rawptr,
    pushConstantRangeCount: c.uint32_t,
    pPushConstantRanges: [^]VkPushConstantRange,
}

VkGraphicsPipelineCreateInfo :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    stageCount: c.uint32_t,
    pStages: [^]VkPipelineShaderStageCreateInfo,
    pVertexInputState: ^VkPipelineVertexInputStateCreateInfo,
    pInputAssemblyState: ^VkPipelineInputAssemblyStateCreateInfo,
    pTessellationState: rawptr,
    pViewportState: ^VkPipelineViewportStateCreateInfo,
    pRasterizationState: ^VkPipelineRasterizationStateCreateInfo,
    pMultisampleState: ^VkPipelineMultisampleStateCreateInfo,
    pDepthStencilState: rawptr,
    pColorBlendState: ^VkPipelineColorBlendStateCreateInfo,
    pDynamicState: rawptr,
    layout: VkPipelineLayout,
    renderPass: VkRenderPass,
    subpass: c.uint32_t,
    basePipelineHandle: VkPipeline,
    basePipelineIndex: c.int32_t,
}

VkDebugUtilsMessengerCallbackDataEXT :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    pMessageIdName: cstring,
    messageIdNumber: c.int32_t,
    pMessage: cstring,
    queueLabelCount: c.uint32_t,
    pQueueLabels: rawptr,
    cmdBufLabelCount: c.uint32_t,
    pCmdBufLabels: rawptr,
    objectCount: c.uint32_t,
    pObjects: rawptr,
}

VkDebugUtilsMessengerCreateInfoEXT :: struct {
    sType: c.uint32_t,
    pNext: rawptr,
    flags: c.uint32_t,
    messageSeverity: c.uint32_t,
    messageType: c.uint32_t,
    pfnUserCallback: proc "c" (messageSeverity: c.uint32_t, messageType: c.uint32_t, pCallbackData: ^VkDebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> c.uint32_t,
    pUserData: rawptr,
}

SwapchainElement :: struct {
    commandBuffer: VkCommandBuffer,
    image: VkImage,
    imageView: VkImageView,
    framebuffer: VkFramebuffer,
    startSemaphore: VkSemaphore,
    endSemaphore: VkSemaphore,
    fence: VkFence,
    lastFence: VkFence,
}

// Extension and layer names
instance_extension_names := [?]cstring{
    "VK_KHR_surface",
    "VK_KHR_wayland_surface",
    "VK_EXT_debug_utils",
}

layer_names := [?]cstring{
    "VK_LAYER_KHRONOS_validation",
}

device_extension_names := [?]cstring{
    "VK_KHR_swapchain",
}

// Global Vulkan variables
ENABLE_VALIDATION := false
instance: VkInstance
debug_messenger: VkDebugUtilsMessengerEXT
vulkan_surface: VkSurfaceKHR
phys_device: VkPhysicalDevice
device: VkDevice
queue_family_index: c.uint32_t
queue: VkQueue
command_pool: VkCommandPool
swapchain: VkSwapchainKHR
render_pass: VkRenderPass
pipeline_layout: VkPipelineLayout
graphics_pipeline: VkPipeline
elements: [^]SwapchainElement
format: VkFormat = VK_FORMAT_UNDEFINED
width: c.uint32_t = 1600
height: c.uint32_t = 900
current_frame: c.uint32_t = 0
image_index: c.uint32_t = 0
image_count: c.uint32_t = 0

// Vulkan function declarations - only the ones actually used
@(default_calling_convention="c")
foreign vulkan {
    vkCreateInstance :: proc(create_info: ^VkInstanceCreateInfo, allocator: rawptr, instance: ^VkInstance) -> VkResult ---
    vkDestroyInstance :: proc(instance: VkInstance, allocator: rawptr) ---
    vkDestroySurfaceKHR :: proc(instance: VkInstance, surface: VkSurfaceKHR, allocator: rawptr) ---
    vkCreateWaylandSurfaceKHR :: proc(instance: VkInstance, create_info: ^VkWaylandSurfaceCreateInfoKHR, allocator: rawptr, surface: ^VkSurfaceKHR) -> VkResult ---
    vkEnumeratePhysicalDevices :: proc(instance: VkInstance, device_count: ^c.uint32_t, devices: [^]VkPhysicalDevice) -> VkResult ---
    vkGetPhysicalDeviceQueueFamilyProperties :: proc(device: VkPhysicalDevice, queue_family_count: ^c.uint32_t, queue_families: [^]VkQueueFamilyProperties) ---
    vkGetPhysicalDeviceSurfaceSupportKHR :: proc(physical_device: VkPhysicalDevice, queue_family_index: c.uint32_t, surface: VkSurfaceKHR, present_support: ^c.uint32_t) -> VkResult ---
    vkCreateDevice :: proc(physical_device: VkPhysicalDevice, create_info: ^VkDeviceCreateInfo, allocator: rawptr, device: ^VkDevice) -> VkResult ---
    vkDestroyDevice :: proc(device: VkDevice, allocator: rawptr) ---
    vkDeviceWaitIdle :: proc(device: VkDevice) -> VkResult ---
    vkGetDeviceQueue :: proc(device: VkDevice, queue_family_index: c.uint32_t, queue_index: c.uint32_t, queue: ^VkQueue) ---
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR :: proc(physical_device: VkPhysicalDevice, surface: VkSurfaceKHR, surface_capabilities: ^VkSurfaceCapabilitiesKHR) -> VkResult ---
    vkGetPhysicalDeviceSurfaceFormatsKHR :: proc(physical_device: VkPhysicalDevice, surface: VkSurfaceKHR, format_count: ^c.uint32_t, formats: [^]VkSurfaceFormatKHR) -> VkResult ---
    vkCreateSwapchainKHR :: proc(device: VkDevice, create_info: ^VkSwapchainCreateInfoKHR, allocator: rawptr, swapchain: ^VkSwapchainKHR) -> VkResult ---
    vkDestroySwapchainKHR :: proc(device: VkDevice, swapchain: VkSwapchainKHR, allocator: rawptr) ---
    vkGetSwapchainImagesKHR :: proc(device: VkDevice, swapchain: VkSwapchainKHR, image_count: ^c.uint32_t, images: [^]VkImage) -> VkResult ---
    vkCreateImageView :: proc(device: VkDevice, create_info: ^VkImageViewCreateInfo, allocator: rawptr, image_view: ^VkImageView) -> VkResult ---
    vkDestroyImageView :: proc(device: VkDevice, image_view: VkImageView, allocator: rawptr) ---
    vkCreateRenderPass :: proc(device: VkDevice, create_info: ^VkRenderPassCreateInfo, allocator: rawptr, render_pass: ^VkRenderPass) -> VkResult ---
    vkDestroyRenderPass :: proc(device: VkDevice, render_pass: VkRenderPass, allocator: rawptr) ---
    vkCreateCommandPool :: proc(device: VkDevice, create_info: ^VkCommandPoolCreateInfo, allocator: rawptr, command_pool: ^VkCommandPool) -> VkResult ---
    vkDestroyCommandPool :: proc(device: VkDevice, command_pool: VkCommandPool, allocator: rawptr) ---
    vkAllocateCommandBuffers :: proc(device: VkDevice, allocate_info: ^VkCommandBufferAllocateInfo, command_buffers: [^]VkCommandBuffer) -> VkResult ---
    vkFreeCommandBuffers :: proc(device: VkDevice, command_pool: VkCommandPool, command_buffer_count: c.uint32_t, command_buffers: [^]VkCommandBuffer) ---
    vkCreateFramebuffer :: proc(device: VkDevice, create_info: ^VkFramebufferCreateInfo, allocator: rawptr, framebuffer: ^VkFramebuffer) -> VkResult ---
    vkDestroyFramebuffer :: proc(device: VkDevice, framebuffer: VkFramebuffer, allocator: rawptr) ---
    vkBeginCommandBuffer :: proc(command_buffer: VkCommandBuffer, begin_info: ^VkCommandBufferBeginInfo) -> VkResult ---
    vkEndCommandBuffer :: proc(command_buffer: VkCommandBuffer) -> VkResult ---
    vkCmdBeginRenderPass :: proc(command_buffer: VkCommandBuffer, render_pass_begin: ^VkRenderPassBeginInfo, contents: c.uint32_t) ---
    vkCmdEndRenderPass :: proc(command_buffer: VkCommandBuffer) ---
    vkQueueSubmit :: proc(queue: VkQueue, submit_count: c.uint32_t, submits: ^VkSubmitInfo, fence: VkFence) -> VkResult ---
    vkAcquireNextImageKHR :: proc(device: VkDevice, swapchain: VkSwapchainKHR, timeout: c.uint64_t, semaphore: VkSemaphore, fence: VkFence, image_index: ^c.uint32_t) -> VkResult ---
    vkQueuePresentKHR :: proc(queue: VkQueue, present_info: ^VkPresentInfoKHR) -> VkResult ---
    vkCreateSemaphore :: proc(device: VkDevice, create_info: ^VkSemaphoreCreateInfo, allocator: rawptr, semaphore: ^VkSemaphore) -> VkResult ---
    vkDestroySemaphore :: proc(device: VkDevice, semaphore: VkSemaphore, allocator: rawptr) ---
    vkCreateFence :: proc(device: VkDevice, create_info: ^VkFenceCreateInfo, allocator: rawptr, fence: ^VkFence) -> VkResult ---
    vkDestroyFence :: proc(device: VkDevice, fence: VkFence, allocator: rawptr) ---
    vkWaitForFences :: proc(device: VkDevice, fence_count: c.uint32_t, fences: ^VkFence, wait_all: c.uint32_t, timeout: c.uint64_t) -> VkResult ---
    vkResetFences :: proc(device: VkDevice, fence_count: c.uint32_t, fences: ^VkFence) -> VkResult ---
    vkCreateShaderModule :: proc(device: VkDevice, create_info: ^VkShaderModuleCreateInfo, allocator: rawptr, shader_module: ^VkShaderModule) -> VkResult ---
    vkDestroyShaderModule :: proc(device: VkDevice, shader_module: VkShaderModule, allocator: rawptr) ---
    vkCreatePipelineLayout :: proc(device: VkDevice, create_info: ^VkPipelineLayoutCreateInfo, allocator: rawptr, pipeline_layout: ^VkPipelineLayout) -> VkResult ---
    vkDestroyPipelineLayout :: proc(device: VkDevice, pipeline_layout: VkPipelineLayout, allocator: rawptr) ---
    vkCreateGraphicsPipelines :: proc(device: VkDevice, pipeline_cache: rawptr, create_info_count: c.uint32_t, create_infos: [^]VkGraphicsPipelineCreateInfo, allocator: rawptr, pipelines: [^]VkPipeline) -> VkResult ---
    vkDestroyPipeline :: proc(device: VkDevice, pipeline: VkPipeline, allocator: rawptr) ---
    vkCmdBindPipeline :: proc(command_buffer: VkCommandBuffer, pipeline_bind_point: c.uint32_t, pipeline: VkPipeline) ---
    vkCmdDraw :: proc(command_buffer: VkCommandBuffer, vertex_count: c.uint32_t, instance_count: c.uint32_t, first_vertex: c.uint32_t, first_instance: c.uint32_t) ---
    vkResetCommandBuffer :: proc(command_buffer: VkCommandBuffer, flags: c.uint32_t) -> VkResult ---
    vkGetInstanceProcAddr :: proc(instance: VkInstance, pName: cstring) -> rawptr ---
    vkCmdPushConstants :: proc(command_buffer: VkCommandBuffer, layout: VkPipelineLayout, stageFlags: c.uint32_t, offset: c.uint32_t, size: c.uint32_t, pValues: rawptr) ---
}

// Debug callback
debug_callback :: proc "c" (messageSeverity: c.uint32_t, messageType: c.uint32_t, pCallbackData: ^VkDebugUtilsMessengerCallbackDataEXT, pUserData: rawptr) -> c.uint32_t {
    context = runtime.default_context()
    fmt.printf("Validation layer: %s\n", pCallbackData.pMessage)
    return 0
}

// Utility functions
load_shader_spirv :: proc(filename: string) -> ([]c.uint32_t, bool) {
    data, ok := os.read_entire_file(filename)
    if !ok do return nil, false
    defer delete(data)

    if len(data) % 4 != 0 do return nil, false

    word_count := len(data) / 4
    spirv_data := make([]c.uint32_t, word_count)

    for i in 0..<word_count {
        byte_offset := i * 4
        spirv_data[i] = c.uint32_t(data[byte_offset]) |
                       (c.uint32_t(data[byte_offset + 1]) << 8) |
                       (c.uint32_t(data[byte_offset + 2]) << 16) |
                       (c.uint32_t(data[byte_offset + 3]) << 24)
    }

    return spirv_data, true
}

create_graphics_pipeline :: proc() -> bool {
    vertex_shader_code, vert_ok := load_shader_spirv("vertex.spv")
    if !vert_ok {
        fmt.println("Failed to load vertex shader")
        return false
    }
    defer delete(vertex_shader_code)

    fragment_shader_code, frag_ok := load_shader_spirv("fragment.spv")
    if !frag_ok {
        fmt.println("Failed to load fragment shader")
        return false
    }
    defer delete(fragment_shader_code)

    vert_shader_create_info := VkShaderModuleCreateInfo{
        sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        codeSize = len(vertex_shader_code) * size_of(c.uint32_t),
        pCode = raw_data(vertex_shader_code),
    }

    vert_shader_module: VkShaderModule
    result := vkCreateShaderModule(device, &vert_shader_create_info, nil, &vert_shader_module)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create vertex shader module: %d\n", result)
        return false
    }
    defer vkDestroyShaderModule(device, vert_shader_module, nil)

    frag_shader_create_info := VkShaderModuleCreateInfo{
        sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        codeSize = len(fragment_shader_code) * size_of(c.uint32_t),
        pCode = raw_data(fragment_shader_code),
    }

    frag_shader_module: VkShaderModule
    result = vkCreateShaderModule(device, &frag_shader_create_info, nil, &frag_shader_module)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create fragment shader module: %d\n", result)
        return false
    }
    defer vkDestroyShaderModule(device, frag_shader_module, nil)

    vert_shader_stage_info := VkPipelineShaderStageCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = VK_SHADER_STAGE_VERTEX_BIT,
        module = vert_shader_module,
        pName = "vs_main",
    }

    frag_shader_stage_info := VkPipelineShaderStageCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        stage = VK_SHADER_STAGE_FRAGMENT_BIT,
        module = frag_shader_module,
        pName = "fs_main",
    }

    shader_stages := [?]VkPipelineShaderStageCreateInfo{vert_shader_stage_info, frag_shader_stage_info}

    vertex_input_info := VkPipelineVertexInputStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
    }

    input_assembly := VkPipelineInputAssemblyStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
        topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
        primitiveRestartEnable = VK_FALSE,
    }

    viewport := VkViewport{
        x = 0.0,
        y = 0.0,
        width = f32(width),
        height = f32(height),
        minDepth = 0.0,
        maxDepth = 1.0,
    }

    scissor := VkRect2D{
        offset = {0, 0},
        extent = {width, height},
    }

    viewport_state := VkPipelineViewportStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
        viewportCount = 1,
        pViewports = &viewport,
        scissorCount = 1,
        pScissors = &scissor,
    }

    rasterizer := VkPipelineRasterizationStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
        depthClampEnable = VK_FALSE,
        rasterizerDiscardEnable = VK_FALSE,
        polygonMode = VK_POLYGON_MODE_FILL,
        lineWidth = 1.0,
        cullMode = 0,
        frontFace = VK_FRONT_FACE_CLOCKWISE,
        depthBiasEnable = VK_FALSE,
    }

    multisampling := VkPipelineMultisampleStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
        sampleShadingEnable = VK_FALSE,
        rasterizationSamples = VK_SAMPLE_COUNT_1_BIT,
    }

    color_write_mask := VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT | VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT
    color_blend_attachment := VkPipelineColorBlendAttachmentState{
        blendEnable = 0,
        srcColorBlendFactor = VK_BLEND_FACTOR_ONE,
        dstColorBlendFactor = VK_BLEND_FACTOR_ZERO,
        colorBlendOp = VK_BLEND_OP_ADD,
        srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE,
        dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO,
        alphaBlendOp = VK_BLEND_OP_ADD,
        colorWriteMask = c.uint32_t(color_write_mask),
    }

    color_blending := VkPipelineColorBlendStateCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
        logicOpEnable = VK_FALSE,
        attachmentCount = 1,
        pAttachments = &color_blend_attachment,
    }

    push_constant_range := VkPushConstantRange{
        stageFlags = VK_SHADER_STAGE_VERTEX_BIT,
        offset = 0,
        size = size_of(f32),
    }

    pipeline_layout_info := VkPipelineLayoutCreateInfo{
        sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        pushConstantRangeCount = 1,
        pPushConstantRanges = &push_constant_range,
    }

    result = vkCreatePipelineLayout(device, &pipeline_layout_info, nil, &pipeline_layout)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create pipeline layout: %d\n", result)
        return false
    }

    pipeline_info := VkGraphicsPipelineCreateInfo{
        sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
        stageCount = 2,
        pStages = raw_data(shader_stages[:]),
        pVertexInputState = &vertex_input_info,
        pInputAssemblyState = &input_assembly,
        pViewportState = &viewport_state,
        pRasterizationState = &rasterizer,
        pMultisampleState = &multisampling,
        pColorBlendState = &color_blending,
        layout = pipeline_layout,
        renderPass = render_pass,
        subpass = 0,
        basePipelineHandle = VK_NULL_HANDLE,
        basePipelineIndex = -1,
    }

    result = vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, nil, &graphics_pipeline)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create graphics pipeline: %d\n", result)
        return false
    }

    return true
}

recreate_graphics_pipeline :: proc() -> bool {
    // Wait for device to be idle
    vkDeviceWaitIdle(device)
    
    // Destroy old pipeline
    vkDestroyPipeline(device, graphics_pipeline, nil)
    vkDestroyPipelineLayout(device, pipeline_layout, nil)
    
    // Recreate pipeline
    return create_graphics_pipeline()
}

create_swapchain :: proc() {
    result: VkResult

    capabilities: VkSurfaceCapabilitiesKHR
    result = vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys_device, vulkan_surface, &capabilities)
    if result != VK_SUCCESS {
        fmt.printf("Error getting surface capabilities: %d\n", result)
        return
    }

    format_count: c.uint32_t
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &format_count, nil)
    if result != VK_SUCCESS {
        fmt.printf("Error getting surface format count: %d\n", result)
        return
    }

    formats := make([^]VkSurfaceFormatKHR, format_count)
    defer free(formats)
    result = vkGetPhysicalDeviceSurfaceFormatsKHR(phys_device, vulkan_surface, &format_count, formats)
    if result != VK_SUCCESS {
        fmt.printf("Error getting surface formats: %d\n", result)
        return
    }

    chosen_format := formats[0]
    for i in 0..<format_count {
        if formats[i].format == VK_FORMAT_B8G8R8A8_UNORM {
            chosen_format = formats[i]
            break
        }
    }
    format = chosen_format.format

    image_count = capabilities.minImageCount + 1
    if capabilities.maxImageCount > 0 && image_count > capabilities.maxImageCount {
        image_count = capabilities.minImageCount
    }

    create_info := VkSwapchainCreateInfoKHR{
        sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        surface = vulkan_surface,
        minImageCount = image_count,
        imageFormat = chosen_format.format,
        imageColorSpace = chosen_format.colorSpace,
        imageExtent = {width, height},
        imageArrayLayers = 1,
        imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        preTransform = capabilities.currentTransform,
        compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        presentMode = VK_PRESENT_MODE_FIFO_KHR,
        clipped = 1,
        oldSwapchain = VK_NULL_HANDLE,
    }

    result = vkCreateSwapchainKHR(device, &create_info, nil, &swapchain)
    if result != VK_SUCCESS {
        fmt.printf("Error creating swapchain: %d\n", result)
        return
    }

    attachment := VkAttachmentDescription{
        format = format,
        samples = VK_SAMPLE_COUNT_1_BIT,
        loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    }

    attachment_ref := VkAttachmentReference{
        attachment = 0,
        layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    }

    subpass := VkSubpassDescription{
        pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        colorAttachmentCount = 1,
        pColorAttachments = &attachment_ref,
    }

    render_pass_info := VkRenderPassCreateInfo{
        sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        attachmentCount = 1,
        pAttachments = &attachment,
        subpassCount = 1,
        pSubpasses = &subpass,
    }

    result = vkCreateRenderPass(device, &render_pass_info, nil, &render_pass)
    if result != VK_SUCCESS {
        fmt.printf("Error creating render pass: %d\n", result)
        return
    }

    result = vkGetSwapchainImagesKHR(device, swapchain, &image_count, nil)
    if result != VK_SUCCESS {
        fmt.printf("Error getting swapchain image count: %d\n", result)
        return
    }

    images := make([^]VkImage, image_count)
    defer free(images)
    result = vkGetSwapchainImagesKHR(device, swapchain, &image_count, images)
    if result != VK_SUCCESS {
        fmt.printf("Error getting swapchain images: %d\n", result)
        return
    }

    elements = make([^]SwapchainElement, image_count)

    for i in 0..<image_count {
        alloc_info := VkCommandBufferAllocateInfo{
            sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            commandPool = command_pool,
            commandBufferCount = 1,
            level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        }
        vkAllocateCommandBuffers(device, &alloc_info, &elements[i].commandBuffer)

        elements[i].image = images[i]

        view_info := VkImageViewCreateInfo{
            sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            viewType = VK_IMAGE_VIEW_TYPE_2D,
            components = {VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY, VK_COMPONENT_SWIZZLE_IDENTITY},
            subresourceRange = {
                aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                baseMipLevel = 0,
                levelCount = 1,
                baseArrayLayer = 0,
                layerCount = 1,
            },
            image = elements[i].image,
            format = format,
        }
        result = vkCreateImageView(device, &view_info, nil, &elements[i].imageView)
        if result != VK_SUCCESS {
            fmt.printf("Error creating image view: %d\n", result)
            return
        }

        fb_info := VkFramebufferCreateInfo{
            sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            renderPass = render_pass,
            attachmentCount = 1,
            pAttachments = &elements[i].imageView,
            width = width,
            height = height,
            layers = 1,
        }
        result = vkCreateFramebuffer(device, &fb_info, nil, &elements[i].framebuffer)
        if result != VK_SUCCESS {
            fmt.printf("Error creating framebuffer: %d\n", result)
            return
        }

        sem_info := VkSemaphoreCreateInfo{
            sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        }
        result = vkCreateSemaphore(device, &sem_info, nil, &elements[i].startSemaphore)
        if result != VK_SUCCESS {
            fmt.printf("Error creating start semaphore: %d\n", result)
            return
        }

        result = vkCreateSemaphore(device, &sem_info, nil, &elements[i].endSemaphore)
        if result != VK_SUCCESS {
            fmt.printf("Error creating end semaphore: %d\n", result)
            return
        }

        fence_info := VkFenceCreateInfo{
            sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            flags = VK_FENCE_CREATE_SIGNALED_BIT,
        }
        result = vkCreateFence(device, &fence_info, nil, &elements[i].fence)
        if result != VK_SUCCESS {
            fmt.printf("Error creating fence: %d\n", result)
            return
        }

        elements[i].lastFence = VK_NULL_HANDLE
    }
}

destroy_swapchain :: proc() {
    for i in 0..<image_count {
        vkDestroyFence(device, elements[i].fence, nil)
        vkDestroySemaphore(device, elements[i].endSemaphore, nil)
        vkDestroySemaphore(device, elements[i].startSemaphore, nil)
        vkDestroyFramebuffer(device, elements[i].framebuffer, nil)
        vkDestroyImageView(device, elements[i].imageView, nil)
        vkFreeCommandBuffers(device, command_pool, 1, &elements[i].commandBuffer)
    }

    free(elements)
    vkDestroyRenderPass(device, render_pass, nil)
    vkDestroySwapchainKHR(device, swapchain, nil)
}

init_vulkan :: proc() -> bool {
    result: VkResult

    // Create Vulkan instance
    app_info := VkApplicationInfo{
        sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        pApplicationName = "Wayland Vulkan Example",
        applicationVersion = 1,
        engineVersion = 1,
        apiVersion = VK_API_VERSION_1_0,
    }

    create_info := VkInstanceCreateInfo{
        sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        pApplicationInfo = &app_info,
        enabledLayerCount = ENABLE_VALIDATION ? len(layer_names) : 0,
        ppEnabledLayerNames = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
        enabledExtensionCount = ENABLE_VALIDATION ? len(instance_extension_names) : 2,
        ppEnabledExtensionNames = ENABLE_VALIDATION ? raw_data(instance_extension_names[:]) : raw_data(instance_extension_names[:2]),
    }

    result = vkCreateInstance(&create_info, nil, &instance)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create instance: %d\n", result)
        return false
    }

    // Setup debug messenger
    if ENABLE_VALIDATION && !setup_debug_messenger() {
        return false
    }

    // Create Wayland surface
    surface_info := VkWaylandSurfaceCreateInfoKHR{
        sType = VK_STRUCTURE_TYPE_WAYLAND_SURFACE_CREATE_INFO_KHR,
        display = display,
        surface = surface,
    }

    result = vkCreateWaylandSurfaceKHR(instance, &surface_info, nil, &vulkan_surface)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create surface: %d\n", result)
        return false
    }

    // Setup physical device
    if !setup_physical_device() {
        return false
    }

    // Create logical device
    if !create_logical_device() {
        return false
    }

    // Create command pool
    pool_info := VkCommandPoolCreateInfo{
        sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        queueFamilyIndex = queue_family_index,
        flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
    }

    result = vkCreateCommandPool(device, &pool_info, nil, &command_pool)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create command pool: %d\n", result)
        return false
    }

    return true
}

setup_debug_messenger :: proc() -> bool {
    vkCreateDebugUtilsMessengerEXT := cast(proc "c" (instance: VkInstance, create_info: ^VkDebugUtilsMessengerCreateInfoEXT, allocator: rawptr, debug_messenger: ^VkDebugUtilsMessengerEXT) -> VkResult)vkGetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT")
    
    debug_create_info := VkDebugUtilsMessengerCreateInfoEXT{
        sType = VK_STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
        messageSeverity = VK_DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
        messageType = VK_DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT | VK_DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
        pfnUserCallback = debug_callback,
    }
    
    if vkCreateDebugUtilsMessengerEXT != nil {
        result := vkCreateDebugUtilsMessengerEXT(instance, &debug_create_info, nil, &debug_messenger)
        if result != VK_SUCCESS {
            fmt.printf("Failed to create debug messenger: %d\n", result)
            return false
        } else {
            fmt.println("Debug messenger created successfully")
        }
    } else {
        fmt.println("Debug utils extension not available")
    }
    return true
}

setup_physical_device :: proc() -> bool {
    device_count: c.uint32_t
    vkEnumeratePhysicalDevices(instance, &device_count, nil)
    if device_count == 0 {
        fmt.println("No physical devices found")
        return false
    }

    devices := make([^]VkPhysicalDevice, device_count)
    defer free(devices)
    vkEnumeratePhysicalDevices(instance, &device_count, devices)
    phys_device = devices[0]

    // Find queue family
    queue_family_count: c.uint32_t
    vkGetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, nil)

    queue_families := make([^]VkQueueFamilyProperties, queue_family_count)
    defer free(queue_families)
    vkGetPhysicalDeviceQueueFamilyProperties(phys_device, &queue_family_count, queue_families)

    found_queue_family := false
    for i in 0..<queue_family_count {
        present_support: c.uint32_t = 0
        result := vkGetPhysicalDeviceSurfaceSupportKHR(phys_device, i, vulkan_surface, &present_support)
        if result == VK_SUCCESS && present_support != 0 && (queue_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 {
            queue_family_index = i
            found_queue_family = true
            break
        }
    }

    if !found_queue_family {
        fmt.println("No suitable queue family found")
        return false
    }

    return true
}

create_logical_device :: proc() -> bool {
    queue_priority: f32 = 1.0
    queue_create_info := VkDeviceQueueCreateInfo{
        sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        queueFamilyIndex = queue_family_index,
        queueCount = 1,
        pQueuePriorities = &queue_priority,
    }

    device_create_info := VkDeviceCreateInfo{
        sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        queueCreateInfoCount = 1,
        pQueueCreateInfos = &queue_create_info,
        enabledLayerCount = ENABLE_VALIDATION ? len(layer_names) : 0,
        ppEnabledLayerNames = ENABLE_VALIDATION ? raw_data(layer_names[:]) : nil,
        enabledExtensionCount = len(device_extension_names),
        ppEnabledExtensionNames = raw_data(device_extension_names[:]),
    }

    result := vkCreateDevice(phys_device, &device_create_info, nil, &device)
    if result != VK_SUCCESS {
        fmt.printf("Failed to create device: %d\n", result)
        return false
    }

    vkGetDeviceQueue(device, queue_family_index, 0, &queue)
    return true
}
