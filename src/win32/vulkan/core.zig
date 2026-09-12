const std = @import("std");
const win32 = @import("win32").everything;

const loader = @import("loader.zig");
pub const vk = loader.vk;

const log = std.log.scoped(.vulkan);

pub const frame_count = 3;
pub const max_swapchain_images = 8;
pub const uniform_bytes = 1024 * 1024;
pub const max_descriptor_sets = 2048;
pub const acquire_stage: vk.VkPipelineStageFlags2 = vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT;

pub const Presentation = enum {
    dcomp_bridge,
    native_wsi,
};

pub const StartupError = error{
    VulkanLoaderUnavailable,
    LoaderProcedureUnavailable,
    InstanceUnavailable,
    SurfaceUnavailable,
    PhysicalDeviceUnavailable,
    RequiredApiVersionUnavailable,
    GpuOverrideUnavailable,
    GraphicsPresentQueueUnavailable,
    RequiredDeviceExtensionUnavailable,
    RequiredFeatureUnavailable,
    ExternalMemoryUnavailable,
    ExternalSemaphoreUnavailable,
    AdapterIdentityUnavailable,
    D3dDeviceUnavailable,
    CompositionUnavailable,
    BridgeSurfaceUnavailable,
    DeviceUnavailable,
    DeviceProcedureUnavailable,
    SwapchainCapabilitiesUnavailable,
    SwapchainFormatUnavailable,
    PresentTierOverrideInvalid,
    PresentTierUnavailable,
    WindowEffectsUnsupported,
    SwapchainUnavailable,
    SynchronizationUnavailable,
    CommandResourcesUnavailable,
    DescriptorResourcesUnavailable,
    PipelineUnavailable,
    MemoryTypeUnavailable,
    ResourceUnavailable,
};

pub fn startupErrorDescription(err: StartupError) []const u8 {
    return switch (err) {
        error.VulkanLoaderUnavailable => "vulkan-1.dll is unavailable",
        error.LoaderProcedureUnavailable => "the Vulkan loader is missing a required procedure",
        error.InstanceUnavailable => "the Vulkan loader rejected the required instance capabilities",
        error.SurfaceUnavailable => "the Win32 Vulkan presentation surface is unavailable",
        error.PhysicalDeviceUnavailable => "no Vulkan 1.3 physical device is available",
        error.RequiredApiVersionUnavailable => "the selected device exposes a Vulkan API version older than 1.3",
        error.GpuOverrideUnavailable => "the configured GPU does not expose the required Vulkan presentation capabilities",
        error.GraphicsPresentQueueUnavailable => "no queue family supports both graphics and Win32 presentation",
        error.RequiredDeviceExtensionUnavailable => "the selected device does not support Vulkan swapchains",
        error.RequiredFeatureUnavailable => "the selected device lacks timeline semaphore, synchronization2, or dynamic rendering support",
        error.ExternalMemoryUnavailable => "the selected device cannot import Direct3D 11 textures into Vulkan",
        error.ExternalSemaphoreUnavailable => "the selected device cannot share timeline synchronization with Direct3D",
        error.AdapterIdentityUnavailable => "the Vulkan device does not expose a Windows adapter identity",
        error.D3dDeviceUnavailable => "Direct3D 11 is unavailable on the selected Vulkan adapter",
        error.CompositionUnavailable => "DirectComposition could not attach the Vulkan bridge to the window",
        error.BridgeSurfaceUnavailable => "the Vulkan DirectComposition bridge surface is unavailable",
        error.DeviceUnavailable => "the Vulkan logical device could not be created",
        error.DeviceProcedureUnavailable => "the Vulkan device is missing a required procedure",
        error.SwapchainCapabilitiesUnavailable => "the Win32 surface capabilities could not be queried",
        error.SwapchainFormatUnavailable => "the Win32 surface has no usable sRGB format",
        error.PresentTierOverrideInvalid => "the diagnostic Vulkan present tier override is invalid",
        error.PresentTierUnavailable => "the requested Vulkan present tier is unavailable on this surface",
        error.WindowEffectsUnsupported => "native Vulkan presentation cannot preserve alpha composition on this surface; set background-opacity=1 and background-blur=false",
        error.SwapchainUnavailable => "the native Vulkan swapchain could not be created",
        error.SynchronizationUnavailable => "the Vulkan synchronization objects could not be created",
        error.CommandResourcesUnavailable => "the Vulkan command resources could not be created",
        error.DescriptorResourcesUnavailable => "the Vulkan descriptor resources could not be created",
        error.PipelineUnavailable => "the shared SPIR-V pipeline could not be created",
        error.MemoryTypeUnavailable => "the selected Vulkan device has no compatible memory type",
        error.ResourceUnavailable => "a required Vulkan rendering resource could not be created",
    };
}

pub const PresentTier = enum {
    present_wait_mailbox,
    timeline_mailbox,
    fifo,
};

pub const Buffer = struct {
    handle: vk.VkBuffer = null,
    memory: vk.VkDeviceMemory = null,
    mapped: ?[*]u8 = null,
    size: usize = 0,

    pub fn release(self: *Buffer, core: *Core) void {
        if (self.mapped != null) core.dp.unmap_memory(core.device, self.memory);
        if (self.handle != null) core.dp.destroy_buffer(core.device, self.handle, null);
        if (self.memory != null) core.dp.free_memory(core.device, self.memory, null);
        self.* = .{};
    }
};

pub const Image = struct {
    handle: vk.VkImage = null,
    memory: vk.VkDeviceMemory = null,
    view: vk.VkImageView = null,
    format: vk.VkFormat = vk.VK_FORMAT_UNDEFINED,
    width: u32 = 0,
    height: u32 = 0,
    layout: vk.VkImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,

    pub fn loaded(self: Image) bool {
        return self.handle != null;
    }

    pub fn release(self: *Image, core: *Core) void {
        if (self.view != null) core.dp.destroy_image_view(core.device, self.view, null);
        if (self.handle != null) core.dp.destroy_image(core.device, self.handle, null);
        if (self.memory != null) core.dp.free_memory(core.device, self.memory, null);
        self.* = .{};
    }
};

pub const Frame = struct {
    command_pool: vk.VkCommandPool = null,
    command_buffer: vk.VkCommandBuffer = null,
    image_acquired: vk.VkSemaphore = null,
    descriptor_pool: vk.VkDescriptorPool = null,
    cells: Buffer = .{},
    uniform: Buffer = .{},
    uniform_cursor: usize = 0,
    completion_value: u64 = 0,

    fn init(core: *Core) StartupError!Frame {
        var frame: Frame = .{};
        errdefer frame.release(core);

        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = core.queue_family,
        };
        if (core.dp.create_command_pool(core.device, &pool_info, null, &frame.command_pool) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = frame.command_pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (core.dp.allocate_command_buffers(core.device, &alloc_info, &frame.command_buffer) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;

        const semaphore_info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };
        if (core.dp.create_semaphore(core.device, &semaphore_info, null, &frame.image_acquired) != vk.VK_SUCCESS)
            return error.SynchronizationUnavailable;

        const pool_sizes = [_]vk.VkDescriptorPoolSize{
            .{ .type = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = max_descriptor_sets },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = max_descriptor_sets },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = max_descriptor_sets * 3 },
            .{ .type = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = max_descriptor_sets },
        };
        const descriptor_info = vk.VkDescriptorPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .maxSets = max_descriptor_sets,
            .poolSizeCount = pool_sizes.len,
            .pPoolSizes = &pool_sizes,
        };
        if (core.dp.create_descriptor_pool(core.device, &descriptor_info, null, &frame.descriptor_pool) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;
        frame.uniform = try core.createHostBuffer(uniform_bytes, vk.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT);
        return frame;
    }

    fn release(self: *Frame, core: *Core) void {
        self.uniform.release(core);
        self.cells.release(core);
        if (self.descriptor_pool != null) core.dp.destroy_descriptor_pool(core.device, self.descriptor_pool, null);
        if (self.image_acquired != null) core.dp.destroy_semaphore(core.device, self.image_acquired, null);
        if (self.command_pool != null) core.dp.destroy_command_pool(core.device, self.command_pool, null);
        self.* = .{};
    }
};

const Upload = struct { pool: vk.VkCommandPool, staging: Buffer, completion: u64 };

pub const Core = struct {
    parent: ?*Core = null,
    uploads: std.ArrayListUnmanaged(Upload) = .empty,
    acquired_frame: ?usize = null,
    swapchain_render_finished: [max_swapchain_images]vk.VkSemaphore = @splat(null),
    presentation: Presentation,
    requires_alpha_composition: bool,
    alpha_composition_enabled: bool,
    global: loader.Global,
    instance: vk.VkInstance,
    ip: loader.Instance,
    surface: vk.VkSurfaceKHR,
    physical_device: vk.VkPhysicalDevice,
    physical_properties: vk.VkPhysicalDeviceProperties,
    memory_properties: vk.VkPhysicalDeviceMemoryProperties,
    queue_family: u32,
    device: vk.VkDevice,
    dp: loader.Device,
    queue: vk.VkQueue,
    present_wait_enabled: bool,
    present_tier_override: ?PresentTier,
    timeline: vk.VkSemaphore,
    timeline_value: u64 = 0,
    sampler: vk.VkSampler,
    descriptor_layout: vk.VkDescriptorSetLayout,
    pipeline_layout: vk.VkPipelineLayout,
    grid_pipeline: vk.VkPipeline,
    image_pipeline: vk.VkPipeline,
    swapchain: vk.VkSwapchainKHR,
    swapchain_format: vk.VkFormat,
    swapchain_extent: vk.VkExtent2D,
    swapchain_images: [max_swapchain_images]vk.VkImage = @splat(null),
    swapchain_views: [max_swapchain_images]vk.VkImageView = @splat(null),
    swapchain_initialized: [max_swapchain_images]bool = @splat(false),
    swapchain_image_count: u32 = 0,
    present_tier: PresentTier,
    frames: [frame_count]Frame,
    frame_cursor: usize = frame_count - 1,
    last_frame_cursor: ?usize = null,
    transparent_image: Image,
    uniform_alignment: usize,
    present_id: u64 = 0,
    last_waitable_present_id: u64 = 0,

    pub fn init(
        hwnd: win32.HWND,
        configured_gpu: ?[]const u8,
        presentation: Presentation,
        requires_alpha_composition: bool,
        candidate_index: usize,
        attempt: *CandidateAttempt,
        vertex_spirv: []align(4) const u8,
        pixel_spirv: []align(4) const u8,
        image_pixel_spirv: []align(4) const u8,
    ) StartupError!Core {
        const present_tier_override = try diagnosticPresentTierOverride();
        var global = loader.Global.init() catch |err| return switch (err) {
            error.LibraryUnavailable => error.VulkanLoaderUnavailable,
            error.ProcedureUnavailable => error.LoaderProcedureUnavailable,
        };
        var global_owned = true;
        errdefer if (global_owned) global.deinit();

        const app_info = vk.VkApplicationInfo{
            .sType = vk.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "Mostty",
            .applicationVersion = 1,
            .pEngineName = null,
            .engineVersion = 0,
            .apiVersion = apiVersion(1, 3, 0),
        };
        var instance_extensions: [2][*:0]const u8 = undefined;
        const instance_extension_count: u32 = if (presentation == .native_wsi) blk: {
            instance_extensions[0] = "VK_KHR_surface";
            instance_extensions[1] = "VK_KHR_win32_surface";
            break :blk 2;
        } else 0;
        const instance_info = vk.VkInstanceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = instance_extension_count,
            .ppEnabledExtensionNames = if (instance_extension_count != 0) &instance_extensions else null,
        };
        var instance: vk.VkInstance = null;
        if (global.create_instance(&instance_info, null, &instance) != vk.VK_SUCCESS)
            return error.InstanceUnavailable;
        var ip = global.loadInstance(instance) catch return error.LoaderProcedureUnavailable;
        var instance_owned = true;
        errdefer if (instance_owned) ip.destroy_instance(instance, null);

        var surface: vk.VkSurfaceKHR = null;
        var surface_owned = false;
        if (presentation == .native_wsi) {
            const surface_info = vk.VkWin32SurfaceCreateInfoKHR{
                .sType = vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR,
                .pNext = null,
                .flags = 0,
                .hinstance = cHandleFromInt(vk.HINSTANCE, @intFromPtr(win32.GetModuleHandleW(null))),
                .hwnd = cHandleFromInt(vk.HWND, @intFromPtr(hwnd)),
            };
            const create_surface = ip.create_win32_surface orelse return error.LoaderProcedureUnavailable;
            if (create_surface(instance, &surface_info, null, &surface) != vk.VK_SUCCESS)
                return error.SurfaceUnavailable;
            surface_owned = true;
        }
        errdefer if (surface_owned) ip.destroy_surface.?(instance, surface, null);

        const selection = try selectPhysicalDevice(
            &ip,
            instance,
            presentation,
            surface,
            configured_gpu,
            candidate_index,
            attempt,
        );
        const physical_device = selection.device;
        const queue_family = selection.queue_family;
        var present_wait_enabled = selection.present_wait;

        var features13 = vk.VkPhysicalDeviceVulkan13Features{
            .sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES,
            .pNext = null,
            .robustImageAccess = vk.VK_FALSE,
            .inlineUniformBlock = vk.VK_FALSE,
            .descriptorBindingInlineUniformBlockUpdateAfterBind = vk.VK_FALSE,
            .pipelineCreationCacheControl = vk.VK_FALSE,
            .privateData = vk.VK_FALSE,
            .shaderDemoteToHelperInvocation = vk.VK_FALSE,
            .shaderTerminateInvocation = vk.VK_FALSE,
            .subgroupSizeControl = vk.VK_FALSE,
            .computeFullSubgroups = vk.VK_FALSE,
            .synchronization2 = vk.VK_TRUE,
            .textureCompressionASTC_HDR = vk.VK_FALSE,
            .shaderZeroInitializeWorkgroupMemory = vk.VK_FALSE,
            .dynamicRendering = vk.VK_TRUE,
            .shaderIntegerDotProduct = vk.VK_FALSE,
            .maintenance4 = vk.VK_FALSE,
        };
        var features12 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        features12.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        features12.pNext = &features13;
        features12.timelineSemaphore = vk.VK_TRUE;
        var available13 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan13Features);
        available13.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
        var available12 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
        available12.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
        available12.pNext = &available13;
        var available_present_wait = std.mem.zeroes(vk.VkPhysicalDevicePresentWaitFeaturesKHR);
        available_present_wait.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR;
        available_present_wait.pNext = &available12;
        var available_present_id = std.mem.zeroes(vk.VkPhysicalDevicePresentIdFeaturesKHR);
        available_present_id.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR;
        available_present_id.pNext = &available_present_wait;
        var available = std.mem.zeroes(vk.VkPhysicalDeviceFeatures2);
        available.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
        available.pNext = if (present_wait_enabled) &available_present_id else &available12;
        ip.get_physical_device_features2(physical_device, &available);
        if (available12.timelineSemaphore == vk.VK_FALSE or
            available13.synchronization2 == vk.VK_FALSE or
            available13.dynamicRendering == vk.VK_FALSE)
            return error.RequiredFeatureUnavailable;
        if (present_wait_enabled and
            (available_present_id.presentId == vk.VK_FALSE or available_present_wait.presentWait == vk.VK_FALSE))
        {
            present_wait_enabled = false;
        }

        var present_wait_features = std.mem.zeroes(vk.VkPhysicalDevicePresentWaitFeaturesKHR);
        present_wait_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_WAIT_FEATURES_KHR;
        present_wait_features.pNext = &features12;
        present_wait_features.presentWait = vk.VK_TRUE;
        var present_id_features = std.mem.zeroes(vk.VkPhysicalDevicePresentIdFeaturesKHR);
        present_id_features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PRESENT_ID_FEATURES_KHR;
        present_id_features.pNext = &present_wait_features;
        present_id_features.presentId = vk.VK_TRUE;

        const priority: f32 = 1.0;
        const queue_info = vk.VkDeviceQueueCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = queue_family,
            .queueCount = 1,
            .pQueuePriorities = &priority,
        };
        var extension_names: [3][*:0]const u8 = undefined;
        var extension_count: u32 = 0;
        if (presentation == .native_wsi) {
            extension_names[0] = "VK_KHR_swapchain";
            extension_count = 1;
            if (present_wait_enabled) {
                extension_names[1] = "VK_KHR_present_id";
                extension_names[2] = "VK_KHR_present_wait";
                extension_count = 3;
            }
        } else {
            extension_names[0] = "VK_KHR_external_memory_win32";
            extension_names[1] = "VK_KHR_external_semaphore_win32";
            extension_count = 2;
        }
        const device_info = vk.VkDeviceCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = if (presentation == .native_wsi and present_wait_enabled) &present_id_features else &features12,
            .flags = 0,
            .queueCreateInfoCount = 1,
            .pQueueCreateInfos = &queue_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extension_count,
            .ppEnabledExtensionNames = &extension_names,
            .pEnabledFeatures = null,
        };
        var device: vk.VkDevice = null;
        if (ip.create_device(physical_device, &device_info, null, &device) != vk.VK_SUCCESS)
            return error.DeviceUnavailable;
        var dp = ip.loadDevice(device) catch return error.DeviceProcedureUnavailable;
        var device_owned = true;
        errdefer if (device_owned) dp.destroy_device(device, null);
        var queue: vk.VkQueue = null;
        dp.get_device_queue(device, queue_family, 0, &queue);

        var physical_properties: vk.VkPhysicalDeviceProperties = undefined;
        ip.get_physical_device_properties(physical_device, &physical_properties);
        var memory_properties: vk.VkPhysicalDeviceMemoryProperties = undefined;
        ip.get_physical_device_memory_properties(physical_device, &memory_properties);

        var core: Core = undefined;
        core.parent = null;
        core.uploads = .empty;
        core.acquired_frame = null;
        core.swapchain_render_finished = @splat(null);
        core.presentation = presentation;
        core.requires_alpha_composition = requires_alpha_composition;
        core.alpha_composition_enabled = false;
        core.global = global;
        core.instance = instance;
        core.ip = ip;
        core.surface = surface;
        core.physical_device = physical_device;
        core.physical_properties = physical_properties;
        core.memory_properties = memory_properties;
        core.queue_family = queue_family;
        core.device = device;
        core.dp = dp;
        core.queue = queue;
        core.present_wait_enabled = present_wait_enabled;
        core.present_tier_override = present_tier_override;
        core.timeline = null;
        core.timeline_value = 0;
        core.sampler = null;
        core.descriptor_layout = null;
        core.pipeline_layout = null;
        core.grid_pipeline = null;
        core.image_pipeline = null;
        core.swapchain = null;
        core.swapchain_format = if (presentation == .dcomp_bridge) vk.VK_FORMAT_B8G8R8A8_UNORM else vk.VK_FORMAT_UNDEFINED;
        core.swapchain_extent = .{ .width = 0, .height = 0 };
        core.swapchain_images = @splat(null);
        core.swapchain_views = @splat(null);
        core.swapchain_initialized = @splat(false);
        core.swapchain_image_count = 0;
        core.present_tier = .fifo;
        core.frames = undefined;
        core.frame_cursor = frame_count - 1;
        core.last_frame_cursor = null;
        core.transparent_image = .{};
        core.uniform_alignment = @max(1, @as(usize, @intCast(physical_properties.limits.minUniformBufferOffsetAlignment)));
        core.present_id = 0;
        core.last_waitable_present_id = 0;
        global_owned = false;
        instance_owned = false;
        surface_owned = false;
        device_owned = false;
        var frame_init_count: usize = 0;
        errdefer {
            for (core.frames[0..frame_init_count]) |*frame| frame.release(&core);
            core.releaseCreated();
        }

        try core.createSynchronization();
        try core.createDescriptorContract();
        if (presentation == .native_wsi) try core.createSwapchain(hwnd, null);
        try core.createPipelines(vertex_spirv, pixel_spirv, image_pixel_spirv);
        for (&core.frames) |*frame| {
            frame.* = try Frame.init(&core);
            frame_init_count += 1;
        }
        core.transparent_image = try core.createImage(1, 1, vk.VK_FORMAT_R8G8B8A8_UNORM);
        const transparent = [_]u8{ 0, 0, 0, 0 };
        core.uploadImage(&core.transparent_image, 0, 0, 1, 1, &transparent, 4) catch
            return error.ResourceUnavailable;

        const name = std.mem.sliceTo(&physical_properties.deviceName, 0);
        if (presentation == .native_wsi) {
            log.info(
                "native Vulkan device active: {s}; present tier={s}; alpha composition={s}",
                .{ name, @tagName(core.present_tier), if (core.alpha_composition_enabled) "enabled" else "opaque" },
            );
        }
        return core;
    }

    pub fn initSurface(parent: *Core, hwnd: win32.HWND, requires_alpha_composition: bool) StartupError!Core {
        var core = parent.*;
        core.parent = parent;
        core.requires_alpha_composition = requires_alpha_composition;
        core.surface = null;
        core.timeline = null;
        core.timeline_value = 0;
        core.swapchain = null;
        core.swapchain_extent = .{ .width = 0, .height = 0 };
        core.swapchain_images = @splat(null);
        core.swapchain_views = @splat(null);
        core.swapchain_render_finished = @splat(null);
        core.swapchain_initialized = @splat(false);
        core.swapchain_image_count = 0;
        core.frames = @splat(.{});
        core.frame_cursor = frame_count - 1;
        core.last_frame_cursor = null;
        core.present_id = 0;
        core.last_waitable_present_id = 0;
        core.acquired_frame = null;
        core.uploads = .empty;
        errdefer core.deinit();
        if (core.presentation == .native_wsi) {
            const info = vk.VkWin32SurfaceCreateInfoKHR{ .sType = vk.VK_STRUCTURE_TYPE_WIN32_SURFACE_CREATE_INFO_KHR, .pNext = null, .flags = 0, .hinstance = cHandleFromInt(vk.HINSTANCE, @intFromPtr(win32.GetModuleHandleW(null))), .hwnd = cHandleFromInt(vk.HWND, @intFromPtr(hwnd)) };
            if (core.ip.create_win32_surface.?(core.instance, &info, null, &core.surface) != vk.VK_SUCCESS) return error.SurfaceUnavailable;
            var supported: vk.VkBool32 = vk.VK_FALSE;
            if (core.ip.get_surface_support.?(core.physical_device, core.queue_family, core.surface, &supported) != vk.VK_SUCCESS or supported == vk.VK_FALSE) return error.GraphicsPresentQueueUnavailable;
            try core.createSwapchain(hwnd, null);
        }
        try core.createSynchronization();
        for (&core.frames) |*frame| frame.* = try Frame.init(&core);
        return core;
    }

    fn releaseCreated(self: *Core) void {
        self.releaseUploads();
        self.destroySwapchain();
        if (self.timeline != null) self.dp.destroy_semaphore(self.device, self.timeline, null);
        if (self.surface != null) self.ip.destroy_surface.?(self.instance, self.surface, null);
        if (self.parent == null) {
            self.transparent_image.release(self);
            if (self.image_pipeline != null) self.dp.destroy_pipeline(self.device, self.image_pipeline, null);
            if (self.grid_pipeline != null) self.dp.destroy_pipeline(self.device, self.grid_pipeline, null);
            if (self.pipeline_layout != null) self.dp.destroy_pipeline_layout(self.device, self.pipeline_layout, null);
            if (self.descriptor_layout != null) self.dp.destroy_descriptor_set_layout(self.device, self.descriptor_layout, null);
            if (self.sampler != null) self.dp.destroy_sampler(self.device, self.sampler, null);
            if (self.device != null) self.dp.destroy_device(self.device, null);
            if (self.instance != null) self.ip.destroy_instance(self.instance, null);
            self.global.deinit();
        }
    }

    pub fn deinit(self: *Core) void {
        self.consumeAcquiredImage();
        const idle = self.dp.device_wait_idle(self.device);
        if (idle != vk.VK_SUCCESS and idle != vk.VK_ERROR_DEVICE_LOST) @panic("Vulkan teardown could not establish device completion");
        for (&self.frames) |*frame| frame.release(self);
        self.releaseCreated();
        self.* = undefined;
    }

    fn consumeAcquiredImage(self: *Core) void {
        const index = self.acquired_frame orelse return;
        const wait = vk.VkSemaphoreSubmitInfo{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = self.frames[index].image_acquired, .value = 0, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 };
        const submit = vk.VkSubmitInfo2{ .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2, .pNext = null, .flags = 0, .waitSemaphoreInfoCount = 1, .pWaitSemaphoreInfos = &wait, .commandBufferInfoCount = 0, .pCommandBufferInfos = null, .signalSemaphoreInfoCount = 0, .pSignalSemaphoreInfos = null };
        const result = self.dp.queue_submit2(self.queue, 1, &submit, null);
        if (result != vk.VK_SUCCESS and result != vk.VK_ERROR_DEVICE_LOST) @panic("Vulkan acquired-image cleanup could not submit its wait");
        self.acquired_frame = null;
    }

    fn releaseUploads(self: *Core) void {
        for (self.uploads.items) |*pending| {
            pending.staging.release(self);
            self.dp.destroy_command_pool(self.device, pending.pool, null);
        }
        self.uploads.deinit(std.heap.page_allocator);
    }

    fn collectUploads(self: *Core) StartupError!void {
        if (self.uploads.items.len == 0) return;
        var completed: u64 = 0;
        if (self.dp.get_semaphore_counter_value(self.device, self.timeline, &completed) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        var i: usize = 0;
        while (i < self.uploads.items.len) {
            if (self.uploads.items[i].completion <= completed) {
                var pending = self.uploads.swapRemove(i);
                pending.staging.release(self);
                self.dp.destroy_command_pool(self.device, pending.pool, null);
            } else i += 1;
        }
    }

    pub fn frameReady(self: *Core) StartupError!bool {
        var completed: u64 = 0;
        if (self.dp.get_semaphore_counter_value(self.device, self.timeline, &completed) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        return completed >= self.frames[(self.frame_cursor + 1) % frame_count].completion_value;
    }

    fn createSynchronization(self: *Core) StartupError!void {
        const type_info = vk.VkSemaphoreTypeCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO,
            .pNext = null,
            .semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE,
            .initialValue = 0,
        };
        const info = vk.VkSemaphoreCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = &type_info,
            .flags = 0,
        };
        if (self.dp.create_semaphore(self.device, &info, null, &self.timeline) != vk.VK_SUCCESS)
            return error.SynchronizationUnavailable;
    }

    pub fn deviceLuid(self: *const Core) StartupError!win32.LUID {
        var id = std.mem.zeroes(vk.VkPhysicalDeviceIDProperties);
        id.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ID_PROPERTIES;
        var properties = std.mem.zeroes(vk.VkPhysicalDeviceProperties2);
        properties.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2;
        properties.pNext = &id;
        self.ip.get_physical_device_properties2(self.physical_device, &properties);
        if (id.deviceLUIDValid == vk.VK_FALSE) return error.AdapterIdentityUnavailable;
        const raw: u64 = @bitCast(id.deviceLUID);
        return .{
            .LowPart = @truncate(raw),
            .HighPart = @bitCast(@as(u32, @truncate(raw >> 32))),
        };
    }

    pub fn importExternalTimeline(self: *Core, handle: win32.HANDLE) StartupError!vk.VkSemaphore {
        var type_info = std.mem.zeroes(vk.VkSemaphoreTypeCreateInfo);
        type_info.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO;
        type_info.semaphoreType = vk.VK_SEMAPHORE_TYPE_TIMELINE;
        var info = std.mem.zeroes(vk.VkSemaphoreCreateInfo);
        info.sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        info.pNext = &type_info;
        var semaphore: vk.VkSemaphore = null;
        if (self.dp.create_semaphore(self.device, &info, null, &semaphore) != vk.VK_SUCCESS)
            return error.ExternalSemaphoreUnavailable;
        errdefer self.dp.destroy_semaphore(self.device, semaphore, null);
        const import_handle = self.dp.import_semaphore_win32_handle orelse
            return error.ExternalSemaphoreUnavailable;
        var import_info = std.mem.zeroes(vk.VkImportSemaphoreWin32HandleInfoKHR);
        import_info.sType = vk.VK_STRUCTURE_TYPE_IMPORT_SEMAPHORE_WIN32_HANDLE_INFO_KHR;
        import_info.semaphore = semaphore;
        import_info.handleType = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT;
        import_info.handle = @ptrCast(handle);
        if (import_handle(self.device, &import_info) != vk.VK_SUCCESS)
            return error.ExternalSemaphoreUnavailable;
        return semaphore;
    }

    pub fn importD3d11Texture(
        self: *Core,
        handle: win32.HANDLE,
        width: u32,
        height: u32,
    ) StartupError!Image {
        const get_properties = self.dp.get_memory_win32_handle_properties orelse
            return error.ExternalMemoryUnavailable;
        var external_info = std.mem.zeroes(vk.VkExternalMemoryImageCreateInfo);
        external_info.sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO;
        external_info.handleTypes = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
        const image_info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external_info,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = vk.VK_FORMAT_B8G8R8A8_UNORM,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        var image: Image = .{ .format = vk.VK_FORMAT_B8G8R8A8_UNORM, .width = width, .height = height };
        errdefer image.release(self);
        if (self.dp.create_image(self.device, &image_info, null, &image.handle) != vk.VK_SUCCESS)
            return error.ExternalMemoryUnavailable;

        var requirements: vk.VkMemoryRequirements = undefined;
        self.dp.get_image_memory_requirements(self.device, image.handle, &requirements);
        var handle_properties = std.mem.zeroes(vk.VkMemoryWin32HandlePropertiesKHR);
        handle_properties.sType = vk.VK_STRUCTURE_TYPE_MEMORY_WIN32_HANDLE_PROPERTIES_KHR;
        const vk_handle: vk.HANDLE = @ptrCast(handle);
        if (get_properties(
            self.device,
            vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT,
            vk_handle,
            &handle_properties,
        ) != vk.VK_SUCCESS) return error.ExternalMemoryUnavailable;
        const memory_type = self.findMemoryType(
            requirements.memoryTypeBits & handle_properties.memoryTypeBits,
            0,
        ) orelse return error.MemoryTypeUnavailable;

        var dedicated = std.mem.zeroes(vk.VkMemoryDedicatedAllocateInfo);
        dedicated.sType = vk.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO;
        dedicated.image = image.handle;
        var import_info = std.mem.zeroes(vk.VkImportMemoryWin32HandleInfoKHR);
        import_info.sType = vk.VK_STRUCTURE_TYPE_IMPORT_MEMORY_WIN32_HANDLE_INFO_KHR;
        import_info.pNext = &dedicated;
        import_info.handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
        import_info.handle = vk_handle;
        const allocation = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &import_info,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        if (self.dp.allocate_memory(self.device, &allocation, null, &image.memory) != vk.VK_SUCCESS or
            self.dp.bind_image_memory(self.device, image.handle, image.memory, 0) != vk.VK_SUCCESS)
            return error.ExternalMemoryUnavailable;

        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = image.handle,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = image.format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = colorRange(),
        };
        if (self.dp.create_image_view(self.device, &view_info, null, &image.view) != vk.VK_SUCCESS)
            return error.ExternalMemoryUnavailable;
        return image;
    }

    pub fn waitTimeline(self: *Core, semaphore: vk.VkSemaphore, value: u64) StartupError!void {
        if (value == 0) return;
        const info = vk.VkSemaphoreWaitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
            .pNext = null,
            .flags = 0,
            .semaphoreCount = 1,
            .pSemaphores = &semaphore,
            .pValues = &value,
        };
        if (self.dp.wait_semaphores(self.device, &info, 10_000_000_000) != vk.VK_SUCCESS)
            return error.ExternalSemaphoreUnavailable;
    }

    fn createDescriptorContract(self: *Core) StartupError!void {
        const bindings = [_]vk.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLER, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, .descriptorCount = 1, .stageFlags = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .pImmutableSamplers = null },
        };
        const layout_info = vk.VkDescriptorSetLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .bindingCount = bindings.len,
            .pBindings = &bindings,
        };
        if (self.dp.create_descriptor_set_layout(self.device, &layout_info, null, &self.descriptor_layout) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;
        const pipeline_layout_info = vk.VkPipelineLayoutCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 1,
            .pSetLayouts = &self.descriptor_layout,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };
        if (self.dp.create_pipeline_layout(self.device, &pipeline_layout_info, null, &self.pipeline_layout) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;

        const sampler_info = vk.VkSamplerCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .magFilter = vk.VK_FILTER_LINEAR,
            .minFilter = vk.VK_FILTER_LINEAR,
            .mipmapMode = vk.VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0,
            .anisotropyEnable = vk.VK_FALSE,
            .maxAnisotropy = 1,
            .compareEnable = vk.VK_FALSE,
            .compareOp = vk.VK_COMPARE_OP_ALWAYS,
            .minLod = 0,
            .maxLod = 0,
            .borderColor = vk.VK_BORDER_COLOR_FLOAT_TRANSPARENT_BLACK,
            .unnormalizedCoordinates = vk.VK_FALSE,
        };
        if (self.dp.create_sampler(self.device, &sampler_info, null, &self.sampler) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;
    }

    fn createPipelines(
        self: *Core,
        vertex_spirv: []align(4) const u8,
        pixel_spirv: []align(4) const u8,
        image_pixel_spirv: []align(4) const u8,
    ) StartupError!void {
        const vertex = try self.createShader(vertex_spirv);
        defer self.dp.destroy_shader_module(self.device, vertex, null);
        const pixel = try self.createShader(pixel_spirv);
        defer self.dp.destroy_shader_module(self.device, pixel, null);
        const image_pixel = try self.createShader(image_pixel_spirv);
        defer self.dp.destroy_shader_module(self.device, image_pixel, null);
        self.grid_pipeline = try self.createPipeline(vertex, pixel, false);
        errdefer self.dp.destroy_pipeline(self.device, self.grid_pipeline, null);
        self.image_pipeline = try self.createPipeline(vertex, image_pixel, true);
    }

    fn createShader(self: *Core, spirv: []align(4) const u8) StartupError!vk.VkShaderModule {
        const info = vk.VkShaderModuleCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .codeSize = spirv.len,
            .pCode = @ptrCast(spirv.ptr),
        };
        var module: vk.VkShaderModule = null;
        if (self.dp.create_shader_module(self.device, &info, null, &module) != vk.VK_SUCCESS)
            return error.PipelineUnavailable;
        return module;
    }

    fn createPipeline(self: *Core, vertex: vk.VkShaderModule, pixel: vk.VkShaderModule, blend: bool) StartupError!vk.VkPipeline {
        const stages = [_]vk.VkPipelineShaderStageCreateInfo{
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_VERTEX_BIT, .module = vertex, .pName = "VertexMain", .pSpecializationInfo = null },
            .{ .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .pNext = null, .flags = 0, .stage = vk.VK_SHADER_STAGE_FRAGMENT_BIT, .module = pixel, .pName = if (blend) "ImagePixelMain" else "PixelMain", .pSpecializationInfo = null },
        };
        const vertex_input = vk.VkPipelineVertexInputStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .vertexBindingDescriptionCount = 0,
            .pVertexBindingDescriptions = null,
            .vertexAttributeDescriptionCount = 0,
            .pVertexAttributeDescriptions = null,
        };
        const input_assembly = vk.VkPipelineInputAssemblyStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .topology = vk.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP,
            .primitiveRestartEnable = vk.VK_FALSE,
        };
        const viewport_state = vk.VkPipelineViewportStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .viewportCount = 1,
            .pViewports = null,
            .scissorCount = 1,
            .pScissors = null,
        };
        const raster = vk.VkPipelineRasterizationStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .depthClampEnable = vk.VK_FALSE,
            .rasterizerDiscardEnable = vk.VK_FALSE,
            .polygonMode = vk.VK_POLYGON_MODE_FILL,
            .cullMode = vk.VK_CULL_MODE_NONE,
            .frontFace = vk.VK_FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.VK_FALSE,
            .depthBiasConstantFactor = 0,
            .depthBiasClamp = 0,
            .depthBiasSlopeFactor = 0,
            .lineWidth = 1,
        };
        const multisample = vk.VkPipelineMultisampleStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .rasterizationSamples = vk.VK_SAMPLE_COUNT_1_BIT,
            .sampleShadingEnable = vk.VK_FALSE,
            .minSampleShading = 0,
            .pSampleMask = null,
            .alphaToCoverageEnable = vk.VK_FALSE,
            .alphaToOneEnable = vk.VK_FALSE,
        };
        const blend_attachment = vk.VkPipelineColorBlendAttachmentState{
            .blendEnable = if (blend) vk.VK_TRUE else vk.VK_FALSE,
            .srcColorBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstColorBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .colorBlendOp = vk.VK_BLEND_OP_ADD,
            .srcAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE,
            .dstAlphaBlendFactor = vk.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA,
            .alphaBlendOp = vk.VK_BLEND_OP_ADD,
            .colorWriteMask = vk.VK_COLOR_COMPONENT_R_BIT | vk.VK_COLOR_COMPONENT_G_BIT | vk.VK_COLOR_COMPONENT_B_BIT | vk.VK_COLOR_COMPONENT_A_BIT,
        };
        const blend_state = vk.VkPipelineColorBlendStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .logicOpEnable = vk.VK_FALSE,
            .logicOp = vk.VK_LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &blend_attachment,
            .blendConstants = .{ 0, 0, 0, 0 },
        };
        const dynamic_states = [_]vk.VkDynamicState{ vk.VK_DYNAMIC_STATE_VIEWPORT, vk.VK_DYNAMIC_STATE_SCISSOR };
        const dynamic = vk.VkPipelineDynamicStateCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .dynamicStateCount = dynamic_states.len,
            .pDynamicStates = &dynamic_states,
        };
        const rendering = vk.VkPipelineRenderingCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_PIPELINE_RENDERING_CREATE_INFO,
            .pNext = null,
            .viewMask = 0,
            .colorAttachmentCount = 1,
            .pColorAttachmentFormats = &self.swapchain_format,
            .depthAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
            .stencilAttachmentFormat = vk.VK_FORMAT_UNDEFINED,
        };
        const info = vk.VkGraphicsPipelineCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .pNext = &rendering,
            .flags = 0,
            .stageCount = stages.len,
            .pStages = &stages,
            .pVertexInputState = &vertex_input,
            .pInputAssemblyState = &input_assembly,
            .pTessellationState = null,
            .pViewportState = &viewport_state,
            .pRasterizationState = &raster,
            .pMultisampleState = &multisample,
            .pDepthStencilState = null,
            .pColorBlendState = &blend_state,
            .pDynamicState = &dynamic,
            .layout = self.pipeline_layout,
            .renderPass = null,
            .subpass = 0,
            .basePipelineHandle = null,
            .basePipelineIndex = -1,
        };
        var pipeline: vk.VkPipeline = null;
        if (self.dp.create_graphics_pipelines(self.device, null, 1, &info, null, &pipeline) != vk.VK_SUCCESS)
            return error.PipelineUnavailable;
        return pipeline;
    }

    pub fn recreateSwapchain(self: *Core, hwnd: win32.HWND) StartupError!void {
        if (self.dp.device_wait_idle(self.device) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        const old = self.swapchain;
        defer if (old != null) self.dp.destroy_swapchain.?(self.device, old, null);
        self.destroySwapchainViews();
        self.swapchain = null;
        try self.createSwapchain(hwnd, old);
    }

    fn createSwapchain(self: *Core, hwnd: win32.HWND, old: vk.VkSwapchainKHR) StartupError!void {
        var capabilities: vk.VkSurfaceCapabilitiesKHR = undefined;
        if (self.ip.get_surface_capabilities.?(self.physical_device, self.surface, &capabilities) != vk.VK_SUCCESS)
            return error.SwapchainCapabilitiesUnavailable;
        const size = win32.getClientSize(hwnd);
        if (size.cx <= 0 or size.cy <= 0) return error.SwapchainUnavailable;
        const width = if (capabilities.currentExtent.width != std.math.maxInt(u32))
            capabilities.currentExtent.width
        else
            std.math.clamp(@as(u32, @intCast(size.cx)), capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
        const height = if (capabilities.currentExtent.height != std.math.maxInt(u32))
            capabilities.currentExtent.height
        else
            std.math.clamp(@as(u32, @intCast(size.cy)), capabilities.minImageExtent.height, capabilities.maxImageExtent.height);

        var format_count: u32 = 0;
        if (self.ip.get_surface_formats.?(self.physical_device, self.surface, &format_count, null) != vk.VK_SUCCESS or format_count == 0)
            return error.SwapchainFormatUnavailable;
        var formats: [32]vk.VkSurfaceFormatKHR = undefined;
        format_count = @min(format_count, formats.len);
        if (self.ip.get_surface_formats.?(self.physical_device, self.surface, &format_count, &formats) != vk.VK_SUCCESS)
            return error.SwapchainFormatUnavailable;
        var chosen: ?vk.VkSurfaceFormatKHR = null;
        for (formats[0..format_count]) |format| {
            if ((format.format == vk.VK_FORMAT_B8G8R8A8_SRGB or format.format == vk.VK_FORMAT_R8G8B8A8_SRGB) and
                format.colorSpace == vk.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                chosen = format;
                break;
            }
        }
        const surface_format = chosen orelse return error.SwapchainFormatUnavailable;
        if (self.grid_pipeline != null and surface_format.format != self.swapchain_format) return error.SwapchainFormatUnavailable;

        var mode_count: u32 = 0;
        if (self.ip.get_surface_present_modes.?(self.physical_device, self.surface, &mode_count, null) != vk.VK_SUCCESS)
            return error.SwapchainCapabilitiesUnavailable;
        var modes: [16]vk.VkPresentModeKHR = undefined;
        mode_count = @min(mode_count, modes.len);
        if (self.ip.get_surface_present_modes.?(self.physical_device, self.surface, &mode_count, &modes) != vk.VK_SUCCESS)
            return error.SwapchainCapabilitiesUnavailable;
        var has_mailbox = false;
        for (modes[0..mode_count]) |mode| if (mode == vk.VK_PRESENT_MODE_MAILBOX_KHR) {
            has_mailbox = true;
        };
        self.present_tier = try selectPresentTier(
            has_mailbox,
            self.present_wait_enabled and self.dp.wait_for_present != null,
            self.present_tier_override,
        );
        const present_mode: vk.VkPresentModeKHR = if (self.present_tier == .fifo)
            vk.VK_PRESENT_MODE_FIFO_KHR
        else
            vk.VK_PRESENT_MODE_MAILBOX_KHR;

        log.info(
            "native Vulkan surface on '{s}': composite alpha flags=0x{x}",
            .{ std.mem.sliceTo(&self.physical_properties.deviceName, 0), capabilities.supportedCompositeAlpha },
        );
        const composite_alpha = chooseCompositeAlpha(
            capabilities.supportedCompositeAlpha,
            self.requires_alpha_composition,
        ) orelse
            return error.WindowEffectsUnsupported;
        self.alpha_composition_enabled = composite_alpha != vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        var image_count: u32 = @max(3, capabilities.minImageCount);
        if (capabilities.maxImageCount != 0) image_count = @min(image_count, capabilities.maxImageCount);
        const info = vk.VkSwapchainCreateInfoKHR{
            .sType = vk.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = .{ .width = width, .height = height },
            .imageArrayLayers = 1,
            .imageUsage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = composite_alpha,
            .presentMode = present_mode,
            .clipped = vk.VK_TRUE,
            .oldSwapchain = old,
        };
        var swapchain: vk.VkSwapchainKHR = null;
        if (self.dp.create_swapchain.?(self.device, &info, null, &swapchain) != vk.VK_SUCCESS)
            return error.SwapchainUnavailable;
        errdefer self.dp.destroy_swapchain.?(self.device, swapchain, null);
        var images: [max_swapchain_images]vk.VkImage = @splat(null);
        var views: [max_swapchain_images]vk.VkImageView = @splat(null);
        errdefer for (views) |view| {
            if (view != null) self.dp.destroy_image_view(self.device, view, null);
        };
        var actual_count: u32 = max_swapchain_images;
        if (self.dp.get_swapchain_images.?(self.device, swapchain, &actual_count, &images) != vk.VK_SUCCESS or actual_count == 0)
            return error.SwapchainUnavailable;
        for (images[0..actual_count], views[0..actual_count]) |image, *view| {
            const view_info = vk.VkImageViewCreateInfo{
                .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
                .format = surface_format.format,
                .components = .{
                    .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = colorRange(),
            };
            if (self.dp.create_image_view(self.device, &view_info, null, view) != vk.VK_SUCCESS)
                return error.SwapchainUnavailable;
        }
        var finished: [max_swapchain_images]vk.VkSemaphore = @splat(null);
        errdefer for (finished) |semaphore| {
            if (semaphore != null) self.dp.destroy_semaphore(self.device, semaphore, null);
        };
        const semaphore_info = vk.VkSemaphoreCreateInfo{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO, .pNext = null, .flags = 0 };
        for (finished[0..actual_count]) |*semaphore| {
            if (self.dp.create_semaphore(self.device, &semaphore_info, null, semaphore) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        }
        self.swapchain_render_finished = finished;
        self.swapchain = swapchain;
        self.swapchain_images = images;
        self.swapchain_views = views;
        self.swapchain_format = surface_format.format;
        self.swapchain_extent = .{ .width = width, .height = height };
        self.swapchain_image_count = actual_count;
        self.swapchain_initialized = @splat(false);
        self.present_id = 0;
        self.last_waitable_present_id = 0;
    }

    fn destroySwapchainViews(self: *Core) void {
        if (self.last_waitable_present_id != 0 and self.dp.wait_for_present != null) {
            const result = self.dp.wait_for_present.?(self.device, self.swapchain, self.last_waitable_present_id, 10_000_000_000);
            if (result != vk.VK_SUCCESS and result != vk.VK_ERROR_OUT_OF_DATE_KHR and result != vk.VK_ERROR_DEVICE_LOST) @panic("Vulkan presentation retirement did not complete");
            self.last_waitable_present_id = 0;
        }
        for (self.swapchain_render_finished) |semaphore| {
            if (semaphore != null) self.dp.destroy_semaphore(self.device, semaphore, null);
        }
        self.swapchain_render_finished = @splat(null);
        for (self.swapchain_views[0..self.swapchain_image_count]) |view| {
            if (view != null) self.dp.destroy_image_view(self.device, view, null);
        }
        self.swapchain_views = @splat(null);
        self.swapchain_images = @splat(null);
        self.swapchain_image_count = 0;
    }

    fn destroySwapchain(self: *Core) void {
        self.destroySwapchainViews();
        if (self.swapchain != null) self.dp.destroy_swapchain.?(self.device, self.swapchain, null);
        self.swapchain = null;
    }

    pub fn beginFrame(self: *Core) StartupError!*Frame {
        try self.collectUploads();
        const next = (self.frame_cursor + 1) % frame_count;
        var frame = &self.frames[next];
        if (frame.completion_value != 0) {
            const wait_info = vk.VkSemaphoreWaitInfo{
                .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO,
                .pNext = null,
                .flags = 0,
                .semaphoreCount = 1,
                .pSemaphores = &self.timeline,
                .pValues = &frame.completion_value,
            };
            if (self.dp.wait_semaphores(self.device, &wait_info, 10_000_000_000) != vk.VK_SUCCESS)
                return error.SynchronizationUnavailable;
        }
        if (self.dp.reset_command_pool(self.device, frame.command_pool, 0) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        if (self.dp.reset_descriptor_pool(self.device, frame.descriptor_pool, 0) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;
        frame.uniform_cursor = 0;
        if (frame.cells.mapped) |dst| if (self.last_frame_cursor) |previous| {
            const source = self.frames[previous].cells;
            if (source.mapped) |src| if (source.size == frame.cells.size and frame.cells.size != 0) {
                @memcpy(dst[0..frame.cells.size], src[0..source.size]);
            };
        };
        self.frame_cursor = next;
        self.last_frame_cursor = next;
        return frame;
    }

    pub fn currentFrame(self: *Core) *Frame {
        return &self.frames[self.frame_cursor];
    }

    pub fn ensureCellBuffers(self: *Core, bytes: usize) StartupError!bool {
        if (self.frames[0].cells.size == bytes and bytes != 0) return false;
        if (self.dp.device_wait_idle(self.device) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        for (&self.frames) |*frame| {
            frame.cells.release(self);
            if (bytes != 0) frame.cells = try self.createHostBuffer(bytes, vk.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT);
        }
        self.last_frame_cursor = self.frame_cursor;
        return true;
    }

    pub fn writeUniform(self: *Core, bytes: []const u8) StartupError!vk.VkDescriptorBufferInfo {
        var frame = self.currentFrame();
        const offset = alignForward(frame.uniform_cursor, self.uniform_alignment);
        if (offset + bytes.len > frame.uniform.size) return error.ResourceUnavailable;
        @memcpy(frame.uniform.mapped.?[offset..][0..bytes.len], bytes);
        frame.uniform_cursor = offset + bytes.len;
        return .{ .buffer = frame.uniform.handle, .offset = offset, .range = bytes.len };
    }

    pub fn allocateDescriptorSet(self: *Core) StartupError!vk.VkDescriptorSet {
        var set: vk.VkDescriptorSet = null;
        const info = vk.VkDescriptorSetAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = self.currentFrame().descriptor_pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &self.descriptor_layout,
        };
        if (self.dp.allocate_descriptor_sets(self.device, &info, &set) != vk.VK_SUCCESS)
            return error.DescriptorResourcesUnavailable;
        return set;
    }

    pub fn createHostBuffer(self: *Core, size: usize, usage: vk.VkBufferUsageFlags) StartupError!Buffer {
        var result: Buffer = .{};
        errdefer result.release(self);
        const info = vk.VkBufferCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = @max(1, size),
            .usage = usage,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };
        if (self.dp.create_buffer(self.device, &info, null, &result.handle) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        var requirements: vk.VkMemoryRequirements = undefined;
        self.dp.get_buffer_memory_requirements(self.device, result.handle, &requirements);
        const memory_type = self.findMemoryType(
            requirements.memoryTypeBits,
            vk.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        ) orelse return error.MemoryTypeUnavailable;
        const alloc = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        if (self.dp.allocate_memory(self.device, &alloc, null, &result.memory) != vk.VK_SUCCESS or
            self.dp.bind_buffer_memory(self.device, result.handle, result.memory, 0) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        var mapped: ?*anyopaque = null;
        if (self.dp.map_memory(self.device, result.memory, 0, requirements.size, 0, &mapped) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        result.mapped = @ptrCast(mapped.?);
        result.size = size;
        if (size != 0) @memset(result.mapped.?[0..size], 0);
        return result;
    }

    pub fn createImage(self: *Core, width: u32, height: u32, format: vk.VkFormat) StartupError!Image {
        var result: Image = .{ .format = format, .width = width, .height = height };
        errdefer result.release(self);
        const info = vk.VkImageCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .imageType = vk.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = width, .height = height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.VK_SAMPLE_COUNT_1_BIT,
            .tiling = vk.VK_IMAGE_TILING_OPTIMAL,
            .usage = vk.VK_IMAGE_USAGE_TRANSFER_DST_BIT | vk.VK_IMAGE_USAGE_SAMPLED_BIT,
            .sharingMode = vk.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .initialLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        };
        if (self.dp.create_image(self.device, &info, null, &result.handle) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        var requirements: vk.VkMemoryRequirements = undefined;
        self.dp.get_image_memory_requirements(self.device, result.handle, &requirements);
        const memory_type = self.findMemoryType(requirements.memoryTypeBits, vk.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT) orelse
            return error.MemoryTypeUnavailable;
        const alloc = vk.VkMemoryAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = requirements.size,
            .memoryTypeIndex = memory_type,
        };
        if (self.dp.allocate_memory(self.device, &alloc, null, &result.memory) != vk.VK_SUCCESS or
            self.dp.bind_image_memory(self.device, result.handle, result.memory, 0) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        const view_info = vk.VkImageViewCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .image = result.handle,
            .viewType = vk.VK_IMAGE_VIEW_TYPE_2D,
            .format = format,
            .components = .{
                .r = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .g = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .b = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
                .a = vk.VK_COMPONENT_SWIZZLE_IDENTITY,
            },
            .subresourceRange = colorRange(),
        };
        if (self.dp.create_image_view(self.device, &view_info, null, &result.view) != vk.VK_SUCCESS)
            return error.ResourceUnavailable;
        return result;
    }

    pub fn uploadImage(
        self: *Core,
        image: *Image,
        x: u32,
        y: u32,
        width: u32,
        height: u32,
        source: [*]const u8,
        source_pitch: u32,
    ) StartupError!void {
        try self.collectUploads();
        const row_bytes = @as(usize, width) * 4;
        const byte_count = row_bytes * height;
        var staging = try self.createHostBuffer(byte_count, vk.VK_BUFFER_USAGE_TRANSFER_SRC_BIT);
        errdefer staging.release(self);
        for (0..height) |row| {
            @memcpy(
                staging.mapped.?[row * row_bytes ..][0..row_bytes],
                source[row * source_pitch ..][0..row_bytes],
            );
        }

        var pool: vk.VkCommandPool = null;
        const pool_info = vk.VkCommandPoolCreateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
            .queueFamilyIndex = self.queue_family,
        };
        if (self.dp.create_command_pool(self.device, &pool_info, null, &pool) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        errdefer self.dp.destroy_command_pool(self.device, pool, null);
        var command: vk.VkCommandBuffer = null;
        const alloc_info = vk.VkCommandBufferAllocateInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = pool,
            .level = vk.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };
        if (self.dp.allocate_command_buffers(self.device, &alloc_info, &command) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        const begin = vk.VkCommandBufferBeginInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
            .pInheritanceInfo = null,
        };
        if (self.dp.begin_command_buffer(command, &begin) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        self.imageBarrier(
            command,
            image.handle,
            image.layout,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            if (image.layout == vk.VK_IMAGE_LAYOUT_UNDEFINED) vk.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT else vk.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            vk.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            if (image.layout == vk.VK_IMAGE_LAYOUT_UNDEFINED) 0 else vk.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
            vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
        );
        const region = vk.VkBufferImageCopy{
            .bufferOffset = 0,
            .bufferRowLength = 0,
            .bufferImageHeight = 0,
            .imageSubresource = .{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .baseArrayLayer = 0, .layerCount = 1 },
            .imageOffset = .{ .x = @intCast(x), .y = @intCast(y), .z = 0 },
            .imageExtent = .{ .width = width, .height = height, .depth = 1 },
        };
        self.dp.cmd_copy_buffer_to_image(command, staging.handle, image.handle, vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);
        self.imageBarrier(
            command,
            image.handle,
            vk.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            vk.VK_PIPELINE_STAGE_2_TRANSFER_BIT,
            vk.VK_PIPELINE_STAGE_2_FRAGMENT_SHADER_BIT,
            vk.VK_ACCESS_2_TRANSFER_WRITE_BIT,
            vk.VK_ACCESS_2_SHADER_SAMPLED_READ_BIT,
        );
        if (self.dp.end_command_buffer(command) != vk.VK_SUCCESS)
            return error.CommandResourcesUnavailable;
        const command_info = vk.VkCommandBufferSubmitInfo{
            .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .pNext = null,
            .commandBuffer = command,
            .deviceMask = 0,
        };
        self.uploads.ensureUnusedCapacity(std.heap.page_allocator, 1) catch return error.ResourceUnavailable;
        const completion = self.timeline_value + 1;
        const signal = vk.VkSemaphoreSubmitInfo{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = self.timeline, .value = completion, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 };
        const submit = vk.VkSubmitInfo2{
            .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .pNext = null,
            .flags = 0,
            .waitSemaphoreInfoCount = 0,
            .pWaitSemaphoreInfos = null,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &command_info,
            .signalSemaphoreInfoCount = 1,
            .pSignalSemaphoreInfos = &signal,
        };
        if (self.dp.queue_submit2(self.queue, 1, &submit, null) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        self.timeline_value = completion;
        self.uploads.appendAssumeCapacity(.{ .pool = pool, .staging = staging, .completion = completion });
        image.layout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    }

    pub fn imageBarrier(
        self: *Core,
        command: vk.VkCommandBuffer,
        image: vk.VkImage,
        old_layout: vk.VkImageLayout,
        new_layout: vk.VkImageLayout,
        source_stage: vk.VkPipelineStageFlags2,
        destination_stage: vk.VkPipelineStageFlags2,
        source_access: vk.VkAccessFlags2,
        destination_access: vk.VkAccessFlags2,
    ) void {
        self.imageBarrierQueues(
            command,
            image,
            old_layout,
            new_layout,
            source_stage,
            destination_stage,
            source_access,
            destination_access,
            vk.VK_QUEUE_FAMILY_IGNORED,
            vk.VK_QUEUE_FAMILY_IGNORED,
        );
    }

    pub fn acquirePresentImage(self: *Core, command: vk.VkCommandBuffer, image: vk.VkImage, initialized: bool) void {
        // The layout transition must participate in the acquisition semaphore's
        // execution dependency, including the first UNDEFINED-layout use.
        self.imageBarrier(command, image, if (initialized) vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR else vk.VK_IMAGE_LAYOUT_UNDEFINED, vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, acquire_stage, acquire_stage, 0, vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT);
    }

    pub fn acquireExternalImage(self: *Core, command: vk.VkCommandBuffer, image: vk.VkImage, initialized: bool) void {
        self.imageBarrierQueues(
            command,
            image,
            if (initialized) vk.VK_IMAGE_LAYOUT_GENERAL else vk.VK_IMAGE_LAYOUT_UNDEFINED,
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.VK_PIPELINE_STAGE_2_TOP_OF_PIPE_BIT,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            0,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            if (initialized) vk.VK_QUEUE_FAMILY_EXTERNAL else vk.VK_QUEUE_FAMILY_IGNORED,
            if (initialized) self.queue_family else vk.VK_QUEUE_FAMILY_IGNORED,
        );
    }

    pub fn releaseExternalImage(self: *Core, command: vk.VkCommandBuffer, image: vk.VkImage) void {
        self.imageBarrierQueues(
            command,
            image,
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_GENERAL,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
            self.queue_family,
            vk.VK_QUEUE_FAMILY_EXTERNAL,
        );
    }

    fn imageBarrierQueues(
        self: *Core,
        command: vk.VkCommandBuffer,
        image: vk.VkImage,
        old_layout: vk.VkImageLayout,
        new_layout: vk.VkImageLayout,
        source_stage: vk.VkPipelineStageFlags2,
        destination_stage: vk.VkPipelineStageFlags2,
        source_access: vk.VkAccessFlags2,
        destination_access: vk.VkAccessFlags2,
        source_queue: u32,
        destination_queue: u32,
    ) void {
        const barrier = vk.VkImageMemoryBarrier2{
            .sType = vk.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER_2,
            .pNext = null,
            .srcStageMask = source_stage,
            .srcAccessMask = source_access,
            .dstStageMask = destination_stage,
            .dstAccessMask = destination_access,
            .oldLayout = old_layout,
            .newLayout = new_layout,
            .srcQueueFamilyIndex = source_queue,
            .dstQueueFamilyIndex = destination_queue,
            .image = image,
            .subresourceRange = colorRange(),
        };
        const dependency = vk.VkDependencyInfo{
            .sType = vk.VK_STRUCTURE_TYPE_DEPENDENCY_INFO,
            .pNext = null,
            .dependencyFlags = 0,
            .memoryBarrierCount = 0,
            .pMemoryBarriers = null,
            .bufferMemoryBarrierCount = 0,
            .pBufferMemoryBarriers = null,
            .imageMemoryBarrierCount = 1,
            .pImageMemoryBarriers = &barrier,
        };
        self.dp.cmd_pipeline_barrier2(command, &dependency);
    }

    fn findMemoryType(self: Core, bits: u32, required: vk.VkMemoryPropertyFlags) ?u32 {
        for (0..self.memory_properties.memoryTypeCount) |index| {
            if (bits & (@as(u32, 1) << @intCast(index)) == 0) continue;
            if (self.memory_properties.memoryTypes[index].propertyFlags & required == required)
                return @intCast(index);
        }
        return null;
    }
};

const Selection = struct {
    device: vk.VkPhysicalDevice,
    queue_family: u32,
    present_wait: bool,
};

pub const CandidateAttempt = struct {
    candidate_count: usize = 0,
    name_buf: [vk.VK_MAX_PHYSICAL_DEVICE_NAME_SIZE]u8 = @splat(0),
    name_len: usize = 0,

    pub fn name(self: *const CandidateAttempt) []const u8 {
        return self.name_buf[0..self.name_len];
    }

    fn select(self: *CandidateAttempt, count: usize, device_name: []const u8) void {
        self.candidate_count = count;
        self.name_len = @min(device_name.len, self.name_buf.len);
        @memcpy(self.name_buf[0..self.name_len], device_name[0..self.name_len]);
    }
};

const RankedDevice = struct {
    device: vk.VkPhysicalDevice,
    properties: vk.VkPhysicalDeviceProperties,
    enumeration_index: u32,
};

fn selectPhysicalDevice(
    ip: *const loader.Instance,
    instance: vk.VkInstance,
    presentation: Presentation,
    surface: vk.VkSurfaceKHR,
    configured_gpu: ?[]const u8,
    candidate_index: usize,
    attempt: *CandidateAttempt,
) StartupError!Selection {
    var count: u32 = 0;
    if (ip.enumerate_physical_devices(instance, &count, null) != vk.VK_SUCCESS or count == 0)
        return error.PhysicalDeviceUnavailable;
    var devices: [32]vk.VkPhysicalDevice = undefined;
    count = @min(count, devices.len);
    if (ip.enumerate_physical_devices(instance, &count, &devices) != vk.VK_SUCCESS)
        return error.PhysicalDeviceUnavailable;
    var ranked: [32]RankedDevice = undefined;
    var ranked_count: usize = 0;
    for (devices[0..count], 0..) |device, enumeration_index| {
        var properties: vk.VkPhysicalDeviceProperties = undefined;
        ip.get_physical_device_properties(device, &properties);
        const name = std.mem.sliceTo(&properties.deviceName, 0);
        if (!matchesConfiguredGpu(configured_gpu, name)) continue;
        insertRankedDevice(&ranked, &ranked_count, .{
            .device = device,
            .properties = properties,
            .enumeration_index = @intCast(enumeration_index),
        });
    }
    if (ranked_count == 0) return if (configured_gpu != null)
        error.GpuOverrideUnavailable
    else
        error.PhysicalDeviceUnavailable;
    if (candidate_index >= ranked_count) return error.PhysicalDeviceUnavailable;

    const candidate = ranked[candidate_index];
    const device = candidate.device;
    const name = std.mem.sliceTo(&candidate.properties.deviceName, 0);
    attempt.select(ranked_count, name);
    if (candidate.properties.apiVersion < apiVersion(1, 3, 0))
        return error.RequiredApiVersionUnavailable;
    if (!supportsRequiredFeatures(ip, device)) return error.RequiredFeatureUnavailable;

    const queue_family = switch (presentation) {
        .native_wsi => blk: {
            if (!hasExtension(ip, device, "VK_KHR_swapchain"))
                return error.RequiredDeviceExtensionUnavailable;
            break :blk findGraphicsPresentQueue(ip, device, surface) orelse
                return error.GraphicsPresentQueueUnavailable;
        },
        .dcomp_bridge => blk: {
            if (!hasExtension(ip, device, "VK_KHR_external_memory_win32"))
                return error.ExternalMemoryUnavailable;
            if (!hasExtension(ip, device, "VK_KHR_external_semaphore_win32"))
                return error.ExternalSemaphoreUnavailable;
            try requireExternalInterop(ip, device);
            break :blk findGraphicsQueue(ip, device) orelse
                return error.GraphicsPresentQueueUnavailable;
        },
    };
    return .{
        .device = device,
        .queue_family = queue_family,
        .present_wait = presentation == .native_wsi and
            hasExtension(ip, device, "VK_KHR_present_id") and
            hasExtension(ip, device, "VK_KHR_present_wait"),
    };
}

fn matchesConfiguredGpu(configured_gpu: ?[]const u8, name: []const u8) bool {
    const wanted = configured_gpu orelse return true;
    return std.mem.indexOf(u8, name, wanted) != null;
}

fn deviceTypeScore(device_type: vk.VkPhysicalDeviceType) u32 {
    return switch (device_type) {
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU => 3,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU => 2,
        vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU => 1,
        else => 0,
    };
}

fn insertRankedDevice(devices: *[32]RankedDevice, count: *usize, candidate: RankedDevice) void {
    var index = count.*;
    while (index > 0 and
        deviceTypeScore(candidate.properties.deviceType) > deviceTypeScore(devices[index - 1].properties.deviceType))
    {
        devices[index] = devices[index - 1];
        index -= 1;
    }
    devices[index] = candidate;
    count.* += 1;
}

fn supportsRequiredFeatures(ip: *const loader.Instance, device: vk.VkPhysicalDevice) bool {
    var features13 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan13Features);
    features13.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES;
    var features12 = std.mem.zeroes(vk.VkPhysicalDeviceVulkan12Features);
    features12.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES;
    features12.pNext = &features13;
    var features = std.mem.zeroes(vk.VkPhysicalDeviceFeatures2);
    features.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2;
    features.pNext = &features12;
    ip.get_physical_device_features2(device, &features);
    return features12.timelineSemaphore == vk.VK_TRUE and
        features13.synchronization2 == vk.VK_TRUE and
        features13.dynamicRendering == vk.VK_TRUE;
}

fn findGraphicsPresentQueue(ip: *const loader.Instance, device: vk.VkPhysicalDevice, surface: vk.VkSurfaceKHR) ?u32 {
    var count: u32 = 0;
    ip.get_physical_device_queue_family_properties(device, &count, null);
    var properties: [32]vk.VkQueueFamilyProperties = undefined;
    count = @min(count, properties.len);
    ip.get_physical_device_queue_family_properties(device, &count, &properties);
    for (properties[0..count], 0..) |property, index| {
        if (property.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT == 0) continue;
        var supported: vk.VkBool32 = vk.VK_FALSE;
        if (ip.get_surface_support.?(device, @intCast(index), surface, &supported) == vk.VK_SUCCESS and supported == vk.VK_TRUE)
            return @intCast(index);
    }
    return null;
}

fn findGraphicsQueue(ip: *const loader.Instance, device: vk.VkPhysicalDevice) ?u32 {
    var count: u32 = 0;
    ip.get_physical_device_queue_family_properties(device, &count, null);
    var properties: [32]vk.VkQueueFamilyProperties = undefined;
    count = @min(count, properties.len);
    ip.get_physical_device_queue_family_properties(device, &count, &properties);
    for (properties[0..count], 0..) |property, index| {
        if (property.queueFlags & vk.VK_QUEUE_GRAPHICS_BIT != 0) return @intCast(index);
    }
    return null;
}

fn requireExternalInterop(ip: *const loader.Instance, device: vk.VkPhysicalDevice) StartupError!void {
    var external_image_info = std.mem.zeroes(vk.VkPhysicalDeviceExternalImageFormatInfo);
    external_image_info.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_IMAGE_FORMAT_INFO;
    external_image_info.handleType = vk.VK_EXTERNAL_MEMORY_HANDLE_TYPE_D3D11_TEXTURE_KMT_BIT;
    var image_info = std.mem.zeroes(vk.VkPhysicalDeviceImageFormatInfo2);
    image_info.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_IMAGE_FORMAT_INFO_2;
    image_info.pNext = &external_image_info;
    image_info.format = vk.VK_FORMAT_B8G8R8A8_UNORM;
    image_info.type = vk.VK_IMAGE_TYPE_2D;
    image_info.tiling = vk.VK_IMAGE_TILING_OPTIMAL;
    image_info.usage = vk.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    var external_image = std.mem.zeroes(vk.VkExternalImageFormatProperties);
    external_image.sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_IMAGE_FORMAT_PROPERTIES;
    var image_properties = std.mem.zeroes(vk.VkImageFormatProperties2);
    image_properties.sType = vk.VK_STRUCTURE_TYPE_IMAGE_FORMAT_PROPERTIES_2;
    image_properties.pNext = &external_image;
    const image_result = ip.get_physical_device_image_format_properties2(device, &image_info, &image_properties);
    if (image_result != vk.VK_SUCCESS or
        external_image.externalMemoryProperties.externalMemoryFeatures & vk.VK_EXTERNAL_MEMORY_FEATURE_IMPORTABLE_BIT == 0)
    {
        log.warn(
            "Vulkan DComp external image rejected: result={} features=0x{x}",
            .{ image_result, external_image.externalMemoryProperties.externalMemoryFeatures },
        );
        return error.ExternalMemoryUnavailable;
    }

    var semaphore_info = std.mem.zeroes(vk.VkPhysicalDeviceExternalSemaphoreInfo);
    semaphore_info.sType = vk.VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_EXTERNAL_SEMAPHORE_INFO;
    semaphore_info.handleType = vk.VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_D3D12_FENCE_BIT;
    var semaphore_properties = std.mem.zeroes(vk.VkExternalSemaphoreProperties);
    semaphore_properties.sType = vk.VK_STRUCTURE_TYPE_EXTERNAL_SEMAPHORE_PROPERTIES;
    ip.get_physical_device_external_semaphore_properties(device, &semaphore_info, &semaphore_properties);
    const importable = semaphore_properties.externalSemaphoreFeatures & vk.VK_EXTERNAL_SEMAPHORE_FEATURE_IMPORTABLE_BIT != 0;
    if (!importable) return error.ExternalSemaphoreUnavailable;
}

fn hasExtension(ip: *const loader.Instance, device: vk.VkPhysicalDevice, wanted: []const u8) bool {
    var count: u32 = 0;
    if (ip.enumerate_device_extension_properties(device, null, &count, null) != vk.VK_SUCCESS) return false;
    const extensions = std.heap.page_allocator.alloc(vk.VkExtensionProperties, count) catch return false;
    defer std.heap.page_allocator.free(extensions);
    if (ip.enumerate_device_extension_properties(device, null, &count, extensions.ptr) != vk.VK_SUCCESS) return false;
    for (extensions[0..count]) |extension| {
        if (std.mem.eql(u8, std.mem.sliceTo(&extension.extensionName, 0), wanted)) return true;
    }
    return false;
}

fn chooseCompositeAlpha(
    flags: vk.VkCompositeAlphaFlagsKHR,
    requires_alpha_composition: bool,
) ?vk.VkCompositeAlphaFlagBitsKHR {
    inline for (.{
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        vk.VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    }) |candidate| {
        if (flags & candidate != 0) return candidate;
    }
    if (!requires_alpha_composition and flags & vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR != 0)
        return vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    return null;
}

fn colorRange() vk.VkImageSubresourceRange {
    return .{
        .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
}

fn apiVersion(major: u32, minor: u32, patch: u32) u32 {
    return major << 22 | minor << 12 | patch;
}

fn cHandleFromInt(comptime Handle: type, value: usize) Handle {
    // Win32 handles are opaque tokens and may use low bits; Vulkan's C
    // declarations model them as pointers even though they are never
    // dereferenced. A Zig pointer-alignment check is therefore invalid here.
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn alignForward(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, std.math.ceilPowerOfTwoAssert(usize, alignment));
}

fn diagnosticPresentTierOverride() StartupError!?PresentTier {
    const environ: std.process.Environ = .{ .block = .global };
    if (!environ.containsConstant("MOSTTY_DIAG")) return null;
    const value = environ.getAlloc(std.heap.page_allocator, "MOSTTY_VULKAN_PRESENT_TIER") catch return null;
    defer std.heap.page_allocator.free(value);
    return parsePresentTierOverride(value) orelse error.PresentTierOverrideInvalid;
}

fn parsePresentTierOverride(value: []const u8) ?PresentTier {
    return std.meta.stringToEnum(PresentTier, value);
}

fn selectPresentTier(
    has_mailbox: bool,
    has_present_wait: bool,
    requested: ?PresentTier,
) StartupError!PresentTier {
    if (requested) |tier| return switch (tier) {
        .present_wait_mailbox => if (has_mailbox and has_present_wait) tier else error.PresentTierUnavailable,
        .timeline_mailbox => if (has_mailbox) tier else error.PresentTierUnavailable,
        .fifo => tier,
    };
    if (has_mailbox and has_present_wait) return .present_wait_mailbox;
    if (has_mailbox) return .timeline_mailbox;
    return .fifo;
}

test "present tier preference is ordered from explicit wait to FIFO" {
    try std.testing.expectEqual(@as(usize, 3), @typeInfo(PresentTier).@"enum".fields.len);
    try std.testing.expectEqual(PresentTier.present_wait_mailbox, try selectPresentTier(true, true, null));
    try std.testing.expectEqual(PresentTier.timeline_mailbox, try selectPresentTier(true, false, null));
    try std.testing.expectEqual(PresentTier.fifo, try selectPresentTier(false, false, null));
}

test "diagnostic present tier override forces available lower tiers and rejects unavailable tiers" {
    try std.testing.expectEqual(PresentTier.timeline_mailbox, try selectPresentTier(true, true, .timeline_mailbox));
    try std.testing.expectEqual(PresentTier.fifo, try selectPresentTier(true, true, .fifo));
    try std.testing.expectError(error.PresentTierUnavailable, selectPresentTier(false, true, .timeline_mailbox));
    try std.testing.expectError(error.PresentTierUnavailable, selectPresentTier(true, false, .present_wait_mailbox));
}

test "diagnostic present tier names are exact" {
    try std.testing.expectEqual(PresentTier.present_wait_mailbox, parsePresentTierOverride("present_wait_mailbox").?);
    try std.testing.expectEqual(PresentTier.timeline_mailbox, parsePresentTierOverride("timeline_mailbox").?);
    try std.testing.expectEqual(PresentTier.fifo, parsePresentTierOverride("fifo").?);
    try std.testing.expectEqual(@as(?PresentTier, null), parsePresentTierOverride("mailbox"));
}

test "opaque Win32 Vulkan handles preserve unaligned handle values" {
    const handle = cHandleFromInt(vk.HWND, 0x101);
    try std.testing.expectEqual(@as(usize, 0x101), @intFromPtr(handle));
}

test "native alpha policy accepts opaque surfaces only when window effects do not need alpha" {
    const opaque_flag = vk.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    try std.testing.expectEqual(@as(?vk.VkCompositeAlphaFlagBitsKHR, null), chooseCompositeAlpha(opaque_flag, true));
    try std.testing.expectEqual(opaque_flag, chooseCompositeAlpha(opaque_flag, false).?);
    try std.testing.expectEqual(
        vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        chooseCompositeAlpha(vk.VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR | opaque_flag, false).?,
    );
}

test "Vulkan candidates prefer discrete GPUs and preserve equal-rank enumeration order" {
    var devices: [32]RankedDevice = undefined;
    var count: usize = 0;
    const device_types = [_]vk.VkPhysicalDeviceType{
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
        vk.VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU,
        vk.VK_PHYSICAL_DEVICE_TYPE_INTEGRATED_GPU,
        vk.VK_PHYSICAL_DEVICE_TYPE_CPU,
    };
    for (device_types, 0..) |device_type, enumeration_index| {
        var properties = std.mem.zeroes(vk.VkPhysicalDeviceProperties);
        properties.deviceType = device_type;
        insertRankedDevice(&devices, &count, .{
            .device = null,
            .properties = properties,
            .enumeration_index = @intCast(enumeration_index),
        });
    }
    try std.testing.expectEqualSlices(u32, &.{ 1, 0, 2, 3 }, &.{
        devices[0].enumeration_index,
        devices[1].enumeration_index,
        devices[2].enumeration_index,
        devices[3].enumeration_index,
    });
}

test "configured Vulkan GPU restricts candidates to matching device names" {
    try std.testing.expect(matchesConfiguredGpu(null, "Intel(R) Iris(R) Xe Graphics"));
    try std.testing.expect(matchesConfiguredGpu("Iris(R) Xe", "Intel(R) Iris(R) Xe Graphics"));
    try std.testing.expect(!matchesConfiguredGpu("NVIDIA", "Intel(R) Iris(R) Xe Graphics"));
    try std.testing.expect(!matchesConfiguredGpu("iris", "Intel(R) Iris(R) Xe Graphics"));
}

test "native image layout transitions depend on the acquisition wait stage" {
    const Capture = struct {
        var barrier: vk.VkImageMemoryBarrier2 = undefined;
        fn record(_: vk.VkCommandBuffer, info: [*c]const vk.VkDependencyInfo) callconv(.winapi) void {
            barrier = info[0].pImageMemoryBarriers[0];
        }
    };
    var core: Core = undefined;
    core.dp.cmd_pipeline_barrier2 = Capture.record;
    inline for (.{ false, true }) |initialized| {
        core.acquirePresentImage(null, null, initialized);
        try std.testing.expect(Capture.barrier.srcStageMask & acquire_stage != 0);
        try std.testing.expect(Capture.barrier.dstStageMask & vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT != 0);
        try std.testing.expectEqual(vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, Capture.barrier.newLayout);
        try std.testing.expectEqual(if (initialized) vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR else vk.VK_IMAGE_LAYOUT_UNDEFINED, Capture.barrier.oldLayout);
    }
}
