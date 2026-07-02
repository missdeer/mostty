//! Presentation surface lifecycle: composition swap chain, DirectComposition
//! visual tree, back-buffer texture, adapter classification, and the cheap
//! occlusion-test fast path.
//!
//! Bundles adapter detection here because both swap-chain creation and the
//! adapter heuristic touch IDXGI (shared domain) and `remote_or_software`
//! directly drives the present sync-interval policy.

const std = @import("std");
const win32 = @import("win32").everything;
const D3d11Renderer = @import("../d3d11.zig");
const com = @import("com.zig");

// DXGI success code: window is fully covered (compositor will discard the
// Present). Positive HRESULT, so `if (hr < 0)` won't catch it. Not defined
// by zigwin32 (only the negative DXGI_ERROR_* set is exposed); spelled out
// from the dxgi.h SDK header.
pub const DXGI_STATUS_OCCLUDED: i32 = 0x087A0001;

pub const AdapterInfo = struct {
    // desc.Description is [128]u16 — UTF-8 worst case is 4 bytes/wchar so the
    // converted buffer must be at least 512 bytes, otherwise utf16LeToUtf8
    // returns NoSpaceLeft on localized GPU names and the heuristic silently
    // falls back to "unknown" + remote_or_software=false.
    name: [512]u8,
    name_len: usize,
    remote_or_software: bool,
};

pub fn detectAdapter(device: *win32.ID3D11Device) AdapterInfo {
    const dxgi_device = com.queryInterface(device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();

    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) return unknownAdapter();
    }
    defer _ = adapter.IUnknown.Release();

    var desc: win32.DXGI_ADAPTER_DESC = undefined;
    {
        const hr = adapter.GetDesc(&desc);
        if (hr < 0) return unknownAdapter();
    }

    const raw_name = std.mem.sliceTo(&desc.Description, 0);
    var name_buf: [512]u8 = undefined;
    const name_len = std.unicode.utf16LeToUtf8(&name_buf, raw_name) catch {
        return unknownAdapter();
    };
    const name = name_buf[0..name_len];
    const remote_or_software =
        desc.VendorId == 0x1414 or
        utf8ContainsIgnoreCase(name, "warp") or
        utf8ContainsIgnoreCase(name, "basic render") or
        utf8ContainsIgnoreCase(name, "remote");
    return .{ .name = name_buf, .name_len = name_len, .remote_or_software = remote_or_software };
}

fn unknownAdapter() AdapterInfo {
    var name_buf: [512]u8 = @splat(0);
    @memcpy(name_buf[0.."unknown".len], "unknown");
    return .{ .name = name_buf, .name_len = "unknown".len, .remote_or_software = false };
}

fn utf8ContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn init(self: *D3d11Renderer, hwnd: win32.HWND, width: u32, height: u32) *win32.IDXGISwapChain2 {
    const dxgi_device = com.queryInterface(self.device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();
    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) com.fatalHr("GetAdapter", hr);
    }
    defer _ = adapter.IUnknown.Release();
    var factory: *win32.IDXGIFactory2 = undefined;
    {
        const hr = adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr < 0) com.fatalHr("GetDxgiFactory", hr);
    }
    defer _ = factory.IUnknown.Release();

    const swap_chain_flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
    var swap_chain1: *win32.IDXGISwapChain1 = undefined;
    {
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            // 3 back buffers give DWM one buffer of slack during window
            // drag/resize, when its hold time on the presented buffer spikes.
            // MaxFrameLatency=1 below caps the queued-frame depth so this
            // does not translate into an extra frame of input latency.
            .BufferCount = 3,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = swap_chain_flags,
        };
        const hr = factory.CreateSwapChainForComposition(
            &self.device.IUnknown,
            &desc,
            null,
            &swap_chain1,
        );
        if (hr < 0) com.fatalHr("CreateSwapChainForComposition", hr);
    }
    defer _ = swap_chain1.IUnknown.Release();

    // DirectComposition: bind swap chain to window
    {
        const hr = win32.DCompositionCreateDevice(dxgi_device, win32.IID_IDCompositionDevice, @ptrCast(&self.dcomp_device));
        if (hr < 0) com.fatalHr("DCompositionCreateDevice", hr);
    }
    {
        const hr = self.dcomp_device.CreateTargetForHwnd(hwnd, 1, @ptrCast(&self.dcomp_target));
        if (hr < 0) com.fatalHr("CreateTargetForHwnd", hr);
    }
    {
        const hr = self.dcomp_device.CreateVisual(@ptrCast(&self.dcomp_visual));
        if (hr < 0) com.fatalHr("CreateVisual", hr);
    }
    {
        const hr = self.dcomp_visual.SetContent(&swap_chain1.IUnknown);
        if (hr < 0) com.fatalHr("SetContent", hr);
    }
    {
        const hr = self.dcomp_target.SetRoot(self.dcomp_visual);
        if (hr < 0) com.fatalHr("SetRoot", hr);
    }
    {
        const hr = self.dcomp_device.Commit();
        if (hr < 0) com.fatalHr("DCompCommit", hr);
    }

    var swap_chain2: *win32.IDXGISwapChain2 = undefined;
    {
        const hr = swap_chain1.IUnknown.QueryInterface(win32.IID_IDXGISwapChain2, @ptrCast(&swap_chain2));
        if (hr < 0) com.fatalHr("QuerySwapChain2", hr);
    }
    {
        const hr = swap_chain2.SetMaximumFrameLatency(1);
        if (hr < 0) com.fatalHr("SetMaximumFrameLatency", hr);
    }
    // Cache the waitable handle so prepareFrame can gate CPU frame work on
    // DXGI queue availability. Survives ResizeBuffers along with the
    // MaxFrameLatency setting.
    self.frame_latency_waitable = swap_chain2.GetFrameLatencyWaitableObject();
    if (self.frame_latency_waitable == null) @panic("GetFrameLatencyWaitableObject returned null");
    return swap_chain2;
}

pub fn acquireBackBufferTexture(self: *D3d11Renderer, swap_chain: *win32.IDXGISwapChain2) void {
    if (self.back_buffer_tex != null) return;

    var back_buffer: *win32.ID3D11Texture2D = undefined;
    {
        const hr = swap_chain.IDXGISwapChain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
        if (hr < 0) com.fatalHr("GetBuffer", hr);
    }
    self.back_buffer_tex = back_buffer;

    // ClearState during swap-chain resize resets IA state; restore the
    // full-screen triangle topology when reacquiring the back buffer.
    self.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
}
