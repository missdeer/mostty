//! Vulkan/D3D11 external-resource bridge feeding the shared DComp presenter.

const std = @import("std");
const win32 = @import("win32").everything;

const dcomp_blit = @import("../dcomp_blit.zig");
const core_mod = @import("core.zig");

const vk = core_mod.vk;
const log = std.log.scoped(.vulkan_bridge);

pub const Exchange = struct {
    wait_value: u64,
    ready_value: u64,
};

pub const SharedFrame = struct {
    texture: ?*win32.ID3D11Texture2D = null,
    view: ?*win32.ID3D11ShaderResourceView = null,
    image: core_mod.Image = .{},
    initialized: bool = false,

    fn release(self: *SharedFrame, core: *core_mod.Core) void {
        self.image.release(core);
        if (self.view) |view| _ = view.IUnknown.Release();
        if (self.texture) |texture| _ = texture.IUnknown.Release();
        self.* = .{};
    }
};

pub const Bridge = struct {
    presenter: dcomp_blit.Presenter,
    device5: *win32.ID3D11Device5,
    context4: *win32.ID3D11DeviceContext4,
    semaphore: vk.VkSemaphore,
    fence: *win32.ID3D11Fence,
    frames: [core_mod.frame_count]SharedFrame = @splat(.{}),
    width: u32,
    height: u32,
    released_value: u64 = 0,
    pane: bool = false,

    pub fn init(
        core: *core_mod.Core,
        hwnd: win32.HWND,
        width: u32,
        height: u32,
        parent: ?*Bridge,
    ) core_mod.StartupError!Bridge {
        var factory: *win32.IDXGIFactory4 = undefined;
        if (win32.CreateDXGIFactory1(win32.IID_IDXGIFactory4, @ptrCast(&factory)) < 0)
            return error.AdapterIdentityUnavailable;
        defer _ = factory.IUnknown.Release();

        var adapter: *win32.IDXGIAdapter1 = undefined;
        if (factory.EnumAdapterByLuid(
            try core.deviceLuid(),
            win32.IID_IDXGIAdapter1,
            @ptrCast(&adapter),
        ) < 0) return error.AdapterIdentityUnavailable;
        defer _ = adapter.IUnknown.Release();

        var presenter = (if (parent) |p| dcomp_blit.Presenter.initSurface(&p.presenter, hwnd, width, height) else dcomp_blit.Presenter.initLayer(hwnd, width, height, adapter, false)) catch |err| {
            log.err("D3D11 DComp presenter creation failed: {s}", .{@errorName(err)});
            return switch (err) {
                error.DeviceUnavailable => error.D3dDeviceUnavailable,
                error.PresentationUnavailable => error.CompositionUnavailable,
                else => error.BridgeSurfaceUnavailable,
            };
        };
        errdefer presenter.deinit();

        var device5: *win32.ID3D11Device5 = undefined;
        if (presenter.device.IUnknown.QueryInterface(
            win32.IID_ID3D11Device5,
            @ptrCast(&device5),
        ) < 0) return error.ExternalSemaphoreUnavailable;
        errdefer _ = device5.IUnknown.Release();

        var context4: *win32.ID3D11DeviceContext4 = undefined;
        if (presenter.context.IUnknown.QueryInterface(
            win32.IID_ID3D11DeviceContext4,
            @ptrCast(&context4),
        ) < 0) return error.ExternalSemaphoreUnavailable;
        errdefer _ = context4.IUnknown.Release();

        var fence: *win32.ID3D11Fence = undefined;
        if (device5.CreateFence(
            0,
            .{ .SHARED = 1 },
            win32.IID_ID3D11Fence,
            @ptrCast(&fence),
        ) < 0) return error.ExternalSemaphoreUnavailable;
        errdefer _ = fence.IUnknown.Release();

        var maybe_fence_handle: ?win32.HANDLE = null;
        if (fence.CreateSharedHandle(null, win32.GENERIC_ALL, null, &maybe_fence_handle) < 0)
            return error.ExternalSemaphoreUnavailable;
        const fence_handle = maybe_fence_handle orelse return error.ExternalSemaphoreUnavailable;
        defer _ = win32.CloseHandle(fence_handle);
        const semaphore = try core.importExternalTimeline(fence_handle);
        errdefer core.dp.destroy_semaphore(core.device, semaphore, null);

        var bridge: Bridge = .{
            .presenter = presenter,
            .pane = parent != null,
            .device5 = device5,
            .context4 = context4,
            .semaphore = semaphore,
            .fence = fence,
            .width = width,
            .height = height,
        };
        errdefer bridge.releaseFrames(core);
        try bridge.createFrames(core);
        return bridge;
    }

    pub fn deinit(self: *Bridge, core: *core_mod.Core) void {
        self.drain() catch {
            if (self.presenter.device.GetDeviceRemovedReason() >= 0) @panic("Vulkan bridge teardown could not drain the D3D device");
        };
        self.releaseFrames(core);
        _ = self.fence.IUnknown.Release();
        core.dp.destroy_semaphore(core.device, self.semaphore, null);
        _ = self.context4.IUnknown.Release();
        _ = self.device5.IUnknown.Release();
        self.presenter.deinit();
        self.* = undefined;
    }

    pub fn ensureSize(
        self: *Bridge,
        core: *core_mod.Core,
        width: u32,
        height: u32,
    ) core_mod.StartupError!bool {
        if (self.width == width and self.height == height) return false;
        if (core.dp.device_wait_idle(core.device) != vk.VK_SUCCESS)
            return error.SynchronizationUnavailable;
        try self.drain();
        self.releaseFrames(core);
        self.presenter.resize(width, height) catch return error.BridgeSurfaceUnavailable;
        self.width = width;
        self.height = height;
        try self.createFrames(core);
        return true;
    }

    pub fn frame(self: *Bridge, cursor: usize) *SharedFrame {
        return &self.frames[cursor];
    }

    pub fn beginExchange(self: *const Bridge) Exchange {
        return exchangeAfter(self.released_value);
    }

    pub fn present(self: *Bridge, source: *win32.ID3D11ShaderResourceView, exchange: Exchange) !void {
        if (self.context4.Wait(self.fence, exchange.ready_value) < 0)
            return error.ExternalWaitFailed;
        if (!self.pane) self.presenter.waitForFrame();
        try self.presenter.present(source, self.width, self.height);
        const released_value = exchange.ready_value + 1;
        if (self.context4.Signal(self.fence, released_value) < 0)
            return error.ExternalSignalFailed;
        self.presenter.context.Flush();
        self.released_value = released_value;
    }

    fn drain(self: *Bridge) core_mod.StartupError!void {
        const value = self.released_value + 2;
        if (self.context4.Signal(self.fence, value) < 0) return error.SynchronizationUnavailable;
        self.presenter.context.Flush();
        if (self.fence.GetCompletedValue() < value) {
            const event = win32.CreateEventW(null, 0, 0, null) orelse return error.SynchronizationUnavailable;
            defer _ = win32.CloseHandle(event);
            if (self.fence.SetEventOnCompletion(value, event) < 0 or win32.WaitForSingleObject(event, 10_000) != .NO_ERROR) return error.SynchronizationUnavailable;
        }
        self.released_value = value;
    }

    pub fn detach(self: *Bridge) void {
        self.presenter.detach();
    }

    fn createFrames(self: *Bridge, core: *core_mod.Core) core_mod.StartupError!void {
        for (&self.frames) |*shared_frame| {
            shared_frame.* = try createFrame(core, self.presenter.device, self.width, self.height);
        }
    }

    fn releaseFrames(self: *Bridge, core: *core_mod.Core) void {
        for (&self.frames) |*shared_frame| shared_frame.release(core);
    }
};

fn createFrame(
    core: *core_mod.Core,
    device: *win32.ID3D11Device,
    width: u32,
    height: u32,
) core_mod.StartupError!SharedFrame {
    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1, .RENDER_TARGET = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{ .SHARED = 1 },
    };
    var texture: *win32.ID3D11Texture2D = undefined;
    const texture_hr = device.CreateTexture2D(&desc, null, &texture);
    if (texture_hr < 0) {
        log.err("shared D3D11 texture creation failed: HRESULT=0x{x}", .{@as(u32, @bitCast(texture_hr))});
        return error.BridgeSurfaceUnavailable;
    }
    errdefer _ = texture.IUnknown.Release();

    var view: *win32.ID3D11ShaderResourceView = undefined;
    const view_hr = device.CreateShaderResourceView(&texture.ID3D11Resource, null, &view);
    if (view_hr < 0) {
        log.err("shared D3D11 texture view creation failed: HRESULT=0x{x}", .{@as(u32, @bitCast(view_hr))});
        return error.BridgeSurfaceUnavailable;
    }
    errdefer _ = view.IUnknown.Release();

    var resource: *win32.IDXGIResource = undefined;
    if (texture.IUnknown.QueryInterface(win32.IID_IDXGIResource, @ptrCast(&resource)) < 0)
        return error.ExternalMemoryUnavailable;
    defer _ = resource.IUnknown.Release();

    var maybe_handle: ?win32.HANDLE = null;
    if (resource.GetSharedHandle(&maybe_handle) < 0) return error.ExternalMemoryUnavailable;
    const handle = maybe_handle orelse return error.ExternalMemoryUnavailable;

    const image = core.importD3d11Texture(handle, width, height) catch |err| {
        log.err("shared D3D11 texture Vulkan import failed: {s}", .{@errorName(err)});
        return err;
    };
    return .{
        .texture = texture,
        .view = view,
        .image = image,
    };
}

fn exchangeAfter(released_value: u64) Exchange {
    return .{ .wait_value = released_value, .ready_value = released_value + 1 };
}

test "cross-API exchange signals Vulkan after the D3D release" {
    const exchange = exchangeAfter(8);
    try std.testing.expectEqual(@as(u64, 8), exchange.wait_value);
    try std.testing.expectEqual(@as(u64, 9), exchange.ready_value);
}
