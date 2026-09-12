//! Shared DXGI composition-swapchain and DirectComposition visual lifecycle.

const std = @import("std");
const win32 = @import("win32").everything;

pub const Error = error{PresentationUnavailable};

pub const DXGI_STATUS_OCCLUDED: i32 = 0x087A0001;

fn swapChainDesc(width: u32, height: u32, format: win32.DXGI_FORMAT) win32.DXGI_SWAP_CHAIN_DESC1 {
    return .{
        .Width = width,
        .Height = height,
        .Format = format,
        .Stereo = 0,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
        .BufferCount = 3,
        .Scaling = .STRETCH,
        .SwapEffect = .FLIP_SEQUENTIAL,
        .AlphaMode = .PREMULTIPLIED,
        .Flags = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT),
    };
}

pub const Surface = struct {
    swap_chain: *win32.IDXGISwapChain3,
    frame_latency_waitable: win32.HANDLE,
    dcomp_device: *win32.IDCompositionDevice,
    dcomp_target: *win32.IDCompositionTarget,
    dcomp_visual: *win32.IDCompositionVisual,

    pub fn init(
        producer: *win32.IUnknown,
        rendering_device: ?*win32.IDXGIDevice,
        hwnd: win32.HWND,
        width: u32,
        height: u32,
        format: win32.DXGI_FORMAT,
    ) Error!Surface {
        return initLayer(producer, rendering_device, hwnd, width, height, format, true);
    }

    pub fn initLayer(
        producer: *win32.IUnknown,
        rendering_device: ?*win32.IDXGIDevice,
        hwnd: win32.HWND,
        width: u32,
        height: u32,
        format: win32.DXGI_FORMAT,
        above_children: bool,
    ) Error!Surface {
        var factory: *win32.IDXGIFactory4 = undefined;
        if (win32.CreateDXGIFactory1(win32.IID_IDXGIFactory4, @ptrCast(&factory)) < 0)
            return error.PresentationUnavailable;
        defer _ = factory.IUnknown.Release();

        const desc = swapChainDesc(width, height, format);
        var swap_chain1: *win32.IDXGISwapChain1 = undefined;
        if (factory.IDXGIFactory2.CreateSwapChainForComposition(
            producer,
            &desc,
            null,
            &swap_chain1,
        ) < 0) return error.PresentationUnavailable;
        defer _ = swap_chain1.IUnknown.Release();

        var dcomp_device: *win32.IDCompositionDevice = undefined;
        if (win32.DCompositionCreateDevice(
            rendering_device,
            win32.IID_IDCompositionDevice,
            @ptrCast(&dcomp_device),
        ) < 0) return error.PresentationUnavailable;
        errdefer _ = dcomp_device.IUnknown.Release();

        var dcomp_target: *win32.IDCompositionTarget = undefined;
        if (dcomp_device.CreateTargetForHwnd(hwnd, @intFromBool(above_children), @ptrCast(&dcomp_target)) < 0)
            return error.PresentationUnavailable;
        errdefer _ = dcomp_target.IUnknown.Release();

        var dcomp_visual: *win32.IDCompositionVisual = undefined;
        if (dcomp_device.CreateVisual(@ptrCast(&dcomp_visual)) < 0)
            return error.PresentationUnavailable;
        errdefer _ = dcomp_visual.IUnknown.Release();

        if (dcomp_visual.SetContent(&swap_chain1.IUnknown) < 0 or
            dcomp_target.SetRoot(dcomp_visual) < 0 or
            dcomp_device.Commit() < 0)
            return error.PresentationUnavailable;

        var swap_chain3: *win32.IDXGISwapChain3 = undefined;
        if (swap_chain1.IUnknown.QueryInterface(
            win32.IID_IDXGISwapChain3,
            @ptrCast(&swap_chain3),
        ) < 0) return error.PresentationUnavailable;
        errdefer _ = swap_chain3.IUnknown.Release();
        if (swap_chain3.IDXGISwapChain2.SetMaximumFrameLatency(1) < 0)
            return error.PresentationUnavailable;
        const waitable = swap_chain3.IDXGISwapChain2.GetFrameLatencyWaitableObject() orelse
            return error.PresentationUnavailable;

        return .{
            .swap_chain = swap_chain3,
            .frame_latency_waitable = waitable,
            .dcomp_device = dcomp_device,
            .dcomp_target = dcomp_target,
            .dcomp_visual = dcomp_visual,
        };
    }

    pub fn deinit(self: *Surface) void {
        self.detach();
        _ = win32.CloseHandle(self.frame_latency_waitable);
        _ = self.dcomp_visual.IUnknown.Release();
        _ = self.dcomp_target.IUnknown.Release();
        _ = self.dcomp_device.IUnknown.Release();
        _ = self.swap_chain.IUnknown.Release();
        self.* = undefined;
    }

    pub fn detach(self: *Surface) void {
        _ = self.dcomp_target.SetRoot(null);
        _ = self.dcomp_device.Commit();
    }

    pub fn size(self: *Surface) ?struct { w: u32, h: u32 } {
        var w: u32 = undefined;
        var h: u32 = undefined;
        if (self.swap_chain.IDXGISwapChain2.GetSourceSize(&w, &h) < 0) return null;
        return .{ .w = w, .h = h };
    }

    pub fn resize(self: *Surface, width: u32, height: u32) Error!void {
        const flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
        if (self.swap_chain.IDXGISwapChain.ResizeBuffers(0, width, height, .UNKNOWN, flags) < 0)
            return error.PresentationUnavailable;
    }

    pub fn getBuffer(self: *Surface, comptime Interface: type) ?*Interface {
        const iid = if (Interface == win32.ID3D11Texture2D)
            win32.IID_ID3D11Texture2D
        else if (Interface == win32.ID3D12Resource)
            win32.IID_ID3D12Resource
        else
            @compileError("unsupported DirectComposition back-buffer interface");
        const index = self.swap_chain.GetCurrentBackBufferIndex();
        var buffer: *Interface = undefined;
        if (self.swap_chain.IDXGISwapChain.GetBuffer(index, iid, @ptrCast(&buffer)) < 0)
            return null;
        return buffer;
    }
};

test "composition swapchain preserves alpha and bounded queue depth" {
    const desc = swapChainDesc(800, 600, .B8G8R8A8_UNORM);
    try std.testing.expectEqual(@as(u32, 3), desc.BufferCount);
    try std.testing.expectEqual(win32.DXGI_ALPHA_MODE.PREMULTIPLIED, desc.AlphaMode);
    try std.testing.expect(desc.Flags & @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT) != 0);
}
