const std = @import("std");
const win32 = @import("win32").everything;

pub const vk = @cImport({
    @cDefine("VK_NO_PROTOTYPES", "1");
    @cDefine("VK_USE_PLATFORM_WIN32_KHR", "1");
    @cInclude("vulkan/vulkan_win32_abi.h");
});

pub const LoadError = error{ LibraryUnavailable, ProcedureUnavailable };

fn Fn(comptime T: type) type {
    return @typeInfo(T).optional.child;
}

fn castProc(comptime T: type, raw: vk.PFN_vkVoidFunction) ?Fn(T) {
    const proc = raw orelse return null;
    return @ptrCast(proc);
}

pub const Global = struct {
    library: win32.HINSTANCE,
    get_instance_proc_addr: Fn(vk.PFN_vkGetInstanceProcAddr),
    create_instance: Fn(vk.PFN_vkCreateInstance),

    pub fn init() LoadError!Global {
        const library = win32.LoadLibraryW(win32.L("vulkan-1.dll")) orelse
            return error.LibraryUnavailable;
        errdefer _ = win32.FreeLibrary(library);
        const raw_get = win32.GetProcAddress(library, "vkGetInstanceProcAddr") orelse
            return error.ProcedureUnavailable;
        const get_instance_proc_addr: Fn(vk.PFN_vkGetInstanceProcAddr) = @ptrCast(raw_get);
        const create_instance = castProc(
            vk.PFN_vkCreateInstance,
            get_instance_proc_addr(null, "vkCreateInstance"),
        ) orelse return error.ProcedureUnavailable;
        return .{
            .library = library,
            .get_instance_proc_addr = get_instance_proc_addr,
            .create_instance = create_instance,
        };
    }

    pub fn deinit(self: *Global) void {
        _ = win32.FreeLibrary(self.library);
        self.* = undefined;
    }

    pub fn loadInstance(self: Global, instance: vk.VkInstance) LoadError!Instance {
        return Instance.init(self.get_instance_proc_addr, instance);
    }
};

pub const Instance = struct {
    destroy_instance: Fn(vk.PFN_vkDestroyInstance),
    enumerate_physical_devices: Fn(vk.PFN_vkEnumeratePhysicalDevices),
    get_physical_device_properties: Fn(vk.PFN_vkGetPhysicalDeviceProperties),
    get_physical_device_properties2: Fn(vk.PFN_vkGetPhysicalDeviceProperties2),
    get_physical_device_features2: Fn(vk.PFN_vkGetPhysicalDeviceFeatures2),
    get_physical_device_image_format_properties2: Fn(vk.PFN_vkGetPhysicalDeviceImageFormatProperties2),
    get_physical_device_external_semaphore_properties: Fn(vk.PFN_vkGetPhysicalDeviceExternalSemaphoreProperties),
    get_physical_device_queue_family_properties: Fn(vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties),
    get_physical_device_memory_properties: Fn(vk.PFN_vkGetPhysicalDeviceMemoryProperties),
    enumerate_device_extension_properties: Fn(vk.PFN_vkEnumerateDeviceExtensionProperties),
    create_device: Fn(vk.PFN_vkCreateDevice),
    get_device_proc_addr: Fn(vk.PFN_vkGetDeviceProcAddr),
    create_win32_surface: ?Fn(vk.PFN_vkCreateWin32SurfaceKHR),
    destroy_surface: ?Fn(vk.PFN_vkDestroySurfaceKHR),
    get_surface_support: ?Fn(vk.PFN_vkGetPhysicalDeviceSurfaceSupportKHR),
    get_surface_capabilities: ?Fn(vk.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR),
    get_surface_formats: ?Fn(vk.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR),
    get_surface_present_modes: ?Fn(vk.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR),

    fn init(get: Fn(vk.PFN_vkGetInstanceProcAddr), instance: vk.VkInstance) LoadError!Instance {
        return .{
            .destroy_instance = try instanceProc(vk.PFN_vkDestroyInstance, get, instance, "vkDestroyInstance"),
            .enumerate_physical_devices = try instanceProc(vk.PFN_vkEnumeratePhysicalDevices, get, instance, "vkEnumeratePhysicalDevices"),
            .get_physical_device_properties = try instanceProc(vk.PFN_vkGetPhysicalDeviceProperties, get, instance, "vkGetPhysicalDeviceProperties"),
            .get_physical_device_properties2 = try instanceProc(vk.PFN_vkGetPhysicalDeviceProperties2, get, instance, "vkGetPhysicalDeviceProperties2"),
            .get_physical_device_features2 = try instanceProc(vk.PFN_vkGetPhysicalDeviceFeatures2, get, instance, "vkGetPhysicalDeviceFeatures2"),
            .get_physical_device_image_format_properties2 = try instanceProc(vk.PFN_vkGetPhysicalDeviceImageFormatProperties2, get, instance, "vkGetPhysicalDeviceImageFormatProperties2"),
            .get_physical_device_external_semaphore_properties = try instanceProc(vk.PFN_vkGetPhysicalDeviceExternalSemaphoreProperties, get, instance, "vkGetPhysicalDeviceExternalSemaphoreProperties"),
            .get_physical_device_queue_family_properties = try instanceProc(vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties, get, instance, "vkGetPhysicalDeviceQueueFamilyProperties"),
            .get_physical_device_memory_properties = try instanceProc(vk.PFN_vkGetPhysicalDeviceMemoryProperties, get, instance, "vkGetPhysicalDeviceMemoryProperties"),
            .enumerate_device_extension_properties = try instanceProc(vk.PFN_vkEnumerateDeviceExtensionProperties, get, instance, "vkEnumerateDeviceExtensionProperties"),
            .create_device = try instanceProc(vk.PFN_vkCreateDevice, get, instance, "vkCreateDevice"),
            .get_device_proc_addr = try instanceProc(vk.PFN_vkGetDeviceProcAddr, get, instance, "vkGetDeviceProcAddr"),
            .create_win32_surface = instanceProc(vk.PFN_vkCreateWin32SurfaceKHR, get, instance, "vkCreateWin32SurfaceKHR") catch null,
            .destroy_surface = instanceProc(vk.PFN_vkDestroySurfaceKHR, get, instance, "vkDestroySurfaceKHR") catch null,
            .get_surface_support = instanceProc(vk.PFN_vkGetPhysicalDeviceSurfaceSupportKHR, get, instance, "vkGetPhysicalDeviceSurfaceSupportKHR") catch null,
            .get_surface_capabilities = instanceProc(vk.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR, get, instance, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR") catch null,
            .get_surface_formats = instanceProc(vk.PFN_vkGetPhysicalDeviceSurfaceFormatsKHR, get, instance, "vkGetPhysicalDeviceSurfaceFormatsKHR") catch null,
            .get_surface_present_modes = instanceProc(vk.PFN_vkGetPhysicalDeviceSurfacePresentModesKHR, get, instance, "vkGetPhysicalDeviceSurfacePresentModesKHR") catch null,
        };
    }

    pub fn loadDevice(self: Instance, device: vk.VkDevice) LoadError!Device {
        return Device.init(self.get_device_proc_addr, device);
    }
};

fn instanceProc(
    comptime T: type,
    get: Fn(vk.PFN_vkGetInstanceProcAddr),
    instance: vk.VkInstance,
    comptime name: [:0]const u8,
) LoadError!Fn(T) {
    return castProc(T, get(instance, name)) orelse error.ProcedureUnavailable;
}

pub const Device = struct {
    destroy_device: Fn(vk.PFN_vkDestroyDevice),
    get_device_queue: Fn(vk.PFN_vkGetDeviceQueue),
    device_wait_idle: Fn(vk.PFN_vkDeviceWaitIdle),
    queue_wait_idle: Fn(vk.PFN_vkQueueWaitIdle),
    queue_submit2: Fn(vk.PFN_vkQueueSubmit2),
    queue_present: ?Fn(vk.PFN_vkQueuePresentKHR),
    create_swapchain: ?Fn(vk.PFN_vkCreateSwapchainKHR),
    destroy_swapchain: ?Fn(vk.PFN_vkDestroySwapchainKHR),
    get_swapchain_images: ?Fn(vk.PFN_vkGetSwapchainImagesKHR),
    acquire_next_image: ?Fn(vk.PFN_vkAcquireNextImageKHR),
    create_semaphore: Fn(vk.PFN_vkCreateSemaphore),
    destroy_semaphore: Fn(vk.PFN_vkDestroySemaphore),
    wait_semaphores: Fn(vk.PFN_vkWaitSemaphores),
    get_semaphore_counter_value: Fn(vk.PFN_vkGetSemaphoreCounterValue),
    create_command_pool: Fn(vk.PFN_vkCreateCommandPool),
    destroy_command_pool: Fn(vk.PFN_vkDestroyCommandPool),
    reset_command_pool: Fn(vk.PFN_vkResetCommandPool),
    allocate_command_buffers: Fn(vk.PFN_vkAllocateCommandBuffers),
    begin_command_buffer: Fn(vk.PFN_vkBeginCommandBuffer),
    end_command_buffer: Fn(vk.PFN_vkEndCommandBuffer),
    create_shader_module: Fn(vk.PFN_vkCreateShaderModule),
    destroy_shader_module: Fn(vk.PFN_vkDestroyShaderModule),
    create_descriptor_set_layout: Fn(vk.PFN_vkCreateDescriptorSetLayout),
    destroy_descriptor_set_layout: Fn(vk.PFN_vkDestroyDescriptorSetLayout),
    create_pipeline_layout: Fn(vk.PFN_vkCreatePipelineLayout),
    destroy_pipeline_layout: Fn(vk.PFN_vkDestroyPipelineLayout),
    create_descriptor_pool: Fn(vk.PFN_vkCreateDescriptorPool),
    destroy_descriptor_pool: Fn(vk.PFN_vkDestroyDescriptorPool),
    reset_descriptor_pool: Fn(vk.PFN_vkResetDescriptorPool),
    allocate_descriptor_sets: Fn(vk.PFN_vkAllocateDescriptorSets),
    update_descriptor_sets: Fn(vk.PFN_vkUpdateDescriptorSets),
    create_sampler: Fn(vk.PFN_vkCreateSampler),
    destroy_sampler: Fn(vk.PFN_vkDestroySampler),
    create_graphics_pipelines: Fn(vk.PFN_vkCreateGraphicsPipelines),
    destroy_pipeline: Fn(vk.PFN_vkDestroyPipeline),
    create_image: Fn(vk.PFN_vkCreateImage),
    destroy_image: Fn(vk.PFN_vkDestroyImage),
    get_image_memory_requirements: Fn(vk.PFN_vkGetImageMemoryRequirements),
    bind_image_memory: Fn(vk.PFN_vkBindImageMemory),
    create_image_view: Fn(vk.PFN_vkCreateImageView),
    destroy_image_view: Fn(vk.PFN_vkDestroyImageView),
    create_buffer: Fn(vk.PFN_vkCreateBuffer),
    destroy_buffer: Fn(vk.PFN_vkDestroyBuffer),
    get_buffer_memory_requirements: Fn(vk.PFN_vkGetBufferMemoryRequirements),
    bind_buffer_memory: Fn(vk.PFN_vkBindBufferMemory),
    allocate_memory: Fn(vk.PFN_vkAllocateMemory),
    free_memory: Fn(vk.PFN_vkFreeMemory),
    map_memory: Fn(vk.PFN_vkMapMemory),
    unmap_memory: Fn(vk.PFN_vkUnmapMemory),
    cmd_pipeline_barrier2: Fn(vk.PFN_vkCmdPipelineBarrier2),
    cmd_copy_buffer_to_image: Fn(vk.PFN_vkCmdCopyBufferToImage),
    cmd_begin_rendering: Fn(vk.PFN_vkCmdBeginRendering),
    cmd_end_rendering: Fn(vk.PFN_vkCmdEndRendering),
    cmd_clear_attachments: Fn(vk.PFN_vkCmdClearAttachments),
    cmd_bind_pipeline: Fn(vk.PFN_vkCmdBindPipeline),
    cmd_set_viewport: Fn(vk.PFN_vkCmdSetViewport),
    cmd_set_scissor: Fn(vk.PFN_vkCmdSetScissor),
    cmd_bind_descriptor_sets: Fn(vk.PFN_vkCmdBindDescriptorSets),
    cmd_draw: Fn(vk.PFN_vkCmdDraw),
    wait_for_present: ?Fn(vk.PFN_vkWaitForPresentKHR),
    get_memory_win32_handle_properties: ?Fn(vk.PFN_vkGetMemoryWin32HandlePropertiesKHR),
    import_semaphore_win32_handle: ?Fn(vk.PFN_vkImportSemaphoreWin32HandleKHR),

    fn init(get: Fn(vk.PFN_vkGetDeviceProcAddr), device: vk.VkDevice) LoadError!Device {
        return .{
            .destroy_device = try deviceProc(vk.PFN_vkDestroyDevice, get, device, "vkDestroyDevice"),
            .get_device_queue = try deviceProc(vk.PFN_vkGetDeviceQueue, get, device, "vkGetDeviceQueue"),
            .device_wait_idle = try deviceProc(vk.PFN_vkDeviceWaitIdle, get, device, "vkDeviceWaitIdle"),
            .queue_wait_idle = try deviceProc(vk.PFN_vkQueueWaitIdle, get, device, "vkQueueWaitIdle"),
            .queue_submit2 = try deviceProc(vk.PFN_vkQueueSubmit2, get, device, "vkQueueSubmit2"),
            .queue_present = deviceProc(vk.PFN_vkQueuePresentKHR, get, device, "vkQueuePresentKHR") catch null,
            .create_swapchain = deviceProc(vk.PFN_vkCreateSwapchainKHR, get, device, "vkCreateSwapchainKHR") catch null,
            .destroy_swapchain = deviceProc(vk.PFN_vkDestroySwapchainKHR, get, device, "vkDestroySwapchainKHR") catch null,
            .get_swapchain_images = deviceProc(vk.PFN_vkGetSwapchainImagesKHR, get, device, "vkGetSwapchainImagesKHR") catch null,
            .acquire_next_image = deviceProc(vk.PFN_vkAcquireNextImageKHR, get, device, "vkAcquireNextImageKHR") catch null,
            .create_semaphore = try deviceProc(vk.PFN_vkCreateSemaphore, get, device, "vkCreateSemaphore"),
            .destroy_semaphore = try deviceProc(vk.PFN_vkDestroySemaphore, get, device, "vkDestroySemaphore"),
            .wait_semaphores = try deviceProc(vk.PFN_vkWaitSemaphores, get, device, "vkWaitSemaphores"),
            .get_semaphore_counter_value = try deviceProc(vk.PFN_vkGetSemaphoreCounterValue, get, device, "vkGetSemaphoreCounterValue"),
            .create_command_pool = try deviceProc(vk.PFN_vkCreateCommandPool, get, device, "vkCreateCommandPool"),
            .destroy_command_pool = try deviceProc(vk.PFN_vkDestroyCommandPool, get, device, "vkDestroyCommandPool"),
            .reset_command_pool = try deviceProc(vk.PFN_vkResetCommandPool, get, device, "vkResetCommandPool"),
            .allocate_command_buffers = try deviceProc(vk.PFN_vkAllocateCommandBuffers, get, device, "vkAllocateCommandBuffers"),
            .begin_command_buffer = try deviceProc(vk.PFN_vkBeginCommandBuffer, get, device, "vkBeginCommandBuffer"),
            .end_command_buffer = try deviceProc(vk.PFN_vkEndCommandBuffer, get, device, "vkEndCommandBuffer"),
            .create_shader_module = try deviceProc(vk.PFN_vkCreateShaderModule, get, device, "vkCreateShaderModule"),
            .destroy_shader_module = try deviceProc(vk.PFN_vkDestroyShaderModule, get, device, "vkDestroyShaderModule"),
            .create_descriptor_set_layout = try deviceProc(vk.PFN_vkCreateDescriptorSetLayout, get, device, "vkCreateDescriptorSetLayout"),
            .destroy_descriptor_set_layout = try deviceProc(vk.PFN_vkDestroyDescriptorSetLayout, get, device, "vkDestroyDescriptorSetLayout"),
            .create_pipeline_layout = try deviceProc(vk.PFN_vkCreatePipelineLayout, get, device, "vkCreatePipelineLayout"),
            .destroy_pipeline_layout = try deviceProc(vk.PFN_vkDestroyPipelineLayout, get, device, "vkDestroyPipelineLayout"),
            .create_descriptor_pool = try deviceProc(vk.PFN_vkCreateDescriptorPool, get, device, "vkCreateDescriptorPool"),
            .destroy_descriptor_pool = try deviceProc(vk.PFN_vkDestroyDescriptorPool, get, device, "vkDestroyDescriptorPool"),
            .reset_descriptor_pool = try deviceProc(vk.PFN_vkResetDescriptorPool, get, device, "vkResetDescriptorPool"),
            .allocate_descriptor_sets = try deviceProc(vk.PFN_vkAllocateDescriptorSets, get, device, "vkAllocateDescriptorSets"),
            .update_descriptor_sets = try deviceProc(vk.PFN_vkUpdateDescriptorSets, get, device, "vkUpdateDescriptorSets"),
            .create_sampler = try deviceProc(vk.PFN_vkCreateSampler, get, device, "vkCreateSampler"),
            .destroy_sampler = try deviceProc(vk.PFN_vkDestroySampler, get, device, "vkDestroySampler"),
            .create_graphics_pipelines = try deviceProc(vk.PFN_vkCreateGraphicsPipelines, get, device, "vkCreateGraphicsPipelines"),
            .destroy_pipeline = try deviceProc(vk.PFN_vkDestroyPipeline, get, device, "vkDestroyPipeline"),
            .create_image = try deviceProc(vk.PFN_vkCreateImage, get, device, "vkCreateImage"),
            .destroy_image = try deviceProc(vk.PFN_vkDestroyImage, get, device, "vkDestroyImage"),
            .get_image_memory_requirements = try deviceProc(vk.PFN_vkGetImageMemoryRequirements, get, device, "vkGetImageMemoryRequirements"),
            .bind_image_memory = try deviceProc(vk.PFN_vkBindImageMemory, get, device, "vkBindImageMemory"),
            .create_image_view = try deviceProc(vk.PFN_vkCreateImageView, get, device, "vkCreateImageView"),
            .destroy_image_view = try deviceProc(vk.PFN_vkDestroyImageView, get, device, "vkDestroyImageView"),
            .create_buffer = try deviceProc(vk.PFN_vkCreateBuffer, get, device, "vkCreateBuffer"),
            .destroy_buffer = try deviceProc(vk.PFN_vkDestroyBuffer, get, device, "vkDestroyBuffer"),
            .get_buffer_memory_requirements = try deviceProc(vk.PFN_vkGetBufferMemoryRequirements, get, device, "vkGetBufferMemoryRequirements"),
            .bind_buffer_memory = try deviceProc(vk.PFN_vkBindBufferMemory, get, device, "vkBindBufferMemory"),
            .allocate_memory = try deviceProc(vk.PFN_vkAllocateMemory, get, device, "vkAllocateMemory"),
            .free_memory = try deviceProc(vk.PFN_vkFreeMemory, get, device, "vkFreeMemory"),
            .map_memory = try deviceProc(vk.PFN_vkMapMemory, get, device, "vkMapMemory"),
            .unmap_memory = try deviceProc(vk.PFN_vkUnmapMemory, get, device, "vkUnmapMemory"),
            .cmd_pipeline_barrier2 = try deviceProc(vk.PFN_vkCmdPipelineBarrier2, get, device, "vkCmdPipelineBarrier2"),
            .cmd_copy_buffer_to_image = try deviceProc(vk.PFN_vkCmdCopyBufferToImage, get, device, "vkCmdCopyBufferToImage"),
            .cmd_begin_rendering = try deviceProc(vk.PFN_vkCmdBeginRendering, get, device, "vkCmdBeginRendering"),
            .cmd_end_rendering = try deviceProc(vk.PFN_vkCmdEndRendering, get, device, "vkCmdEndRendering"),
            .cmd_clear_attachments = try deviceProc(vk.PFN_vkCmdClearAttachments, get, device, "vkCmdClearAttachments"),
            .cmd_bind_pipeline = try deviceProc(vk.PFN_vkCmdBindPipeline, get, device, "vkCmdBindPipeline"),
            .cmd_set_viewport = try deviceProc(vk.PFN_vkCmdSetViewport, get, device, "vkCmdSetViewport"),
            .cmd_set_scissor = try deviceProc(vk.PFN_vkCmdSetScissor, get, device, "vkCmdSetScissor"),
            .cmd_bind_descriptor_sets = try deviceProc(vk.PFN_vkCmdBindDescriptorSets, get, device, "vkCmdBindDescriptorSets"),
            .cmd_draw = try deviceProc(vk.PFN_vkCmdDraw, get, device, "vkCmdDraw"),
            .wait_for_present = deviceProc(vk.PFN_vkWaitForPresentKHR, get, device, "vkWaitForPresentKHR") catch null,
            .get_memory_win32_handle_properties = deviceProc(vk.PFN_vkGetMemoryWin32HandlePropertiesKHR, get, device, "vkGetMemoryWin32HandlePropertiesKHR") catch null,
            .import_semaphore_win32_handle = deviceProc(vk.PFN_vkImportSemaphoreWin32HandleKHR, get, device, "vkImportSemaphoreWin32HandleKHR") catch null,
        };
    }
};

fn deviceProc(
    comptime T: type,
    get: Fn(vk.PFN_vkGetDeviceProcAddr),
    device: vk.VkDevice,
    comptime name: [:0]const u8,
) LoadError!Fn(T) {
    return castProc(T, get(device, name)) orelse error.ProcedureUnavailable;
}

test "Vulkan SDK headers expose the Win32 and synchronization contracts" {
    try std.testing.expect(@hasDecl(vk, "VkWin32SurfaceCreateInfoKHR"));
    try std.testing.expect(@hasDecl(vk, "VkSubmitInfo2"));
    try std.testing.expect(@hasDecl(vk, "VkRenderingInfo"));
    try std.testing.expect(@hasDecl(vk, "PFN_vkWaitForPresentKHR"));
    try std.testing.expect(@hasDecl(vk, "VkImportMemoryWin32HandleInfoKHR"));
    try std.testing.expect(@hasDecl(vk, "VkImportSemaphoreWin32HandleInfoKHR"));
}
