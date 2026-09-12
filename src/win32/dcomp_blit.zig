//! D3D11 full-screen blit presenter backed by the shared DComp surface.

const win32 = @import("win32").everything;

const dcomp = @import("dcomp.zig");
const shader_assets = @import("shader_assets.zig");

pub const Error = dcomp.Error || error{
    DeviceUnavailable,
    ShaderUnavailable,
    SurfaceViewUnavailable,
    PresentFailed,
};

const presentation_view_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM_SRGB;

pub const Presenter = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
    vertex_shader: *win32.ID3D11VertexShader,
    pixel_shader: *win32.ID3D11PixelShader,
    surface: dcomp.Surface,

    pub fn init(
        hwnd: win32.HWND,
        width: u32,
        height: u32,
        adapter: ?*win32.IDXGIAdapter1,
    ) Error!Presenter {
        return initLayer(hwnd, width, height, adapter, true);
    }

    pub fn initLayer(hwnd: win32.HWND, width: u32, height: u32, adapter: ?*win32.IDXGIAdapter1, above_children: bool) Error!Presenter {
        const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
        var device: *win32.ID3D11Device = undefined;
        var context: *win32.ID3D11DeviceContext = undefined;
        if (win32.D3D11CreateDevice(
            if (adapter) |selected| &selected.IDXGIAdapter else null,
            if (adapter != null) .UNKNOWN else .HARDWARE,
            null,
            .{ .BGRA_SUPPORT = 1 },
            &levels,
            levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        ) < 0) return error.DeviceUnavailable;
        errdefer {
            _ = context.IUnknown.Release();
            _ = device.IUnknown.Release();
        }

        var vertex_shader: *win32.ID3D11VertexShader = undefined;
        if (device.CreateVertexShader(
            shader_assets.vertex.dxbc.ptr,
            shader_assets.vertex.dxbc.len,
            null,
            &vertex_shader,
        ) < 0) return error.ShaderUnavailable;
        errdefer _ = vertex_shader.IUnknown.Release();

        var pixel_shader: *win32.ID3D11PixelShader = undefined;
        if (device.CreatePixelShader(
            shader_assets.present_pixel.ptr,
            shader_assets.present_pixel.len,
            null,
            &pixel_shader,
        ) < 0) return error.ShaderUnavailable;
        errdefer _ = pixel_shader.IUnknown.Release();

        var dxgi_device: *win32.IDXGIDevice = undefined;
        if (device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device)) < 0)
            return error.DeviceUnavailable;
        defer _ = dxgi_device.IUnknown.Release();

        const surface = dcomp.Surface.initLayer(
            &device.IUnknown,
            dxgi_device,
            hwnd,
            width,
            height,
            .B8G8R8A8_UNORM,
            above_children,
        ) catch return error.PresentationUnavailable;
        return .{
            .device = device,
            .context = context,
            .vertex_shader = vertex_shader,
            .pixel_shader = pixel_shader,
            .surface = surface,
        };
    }

    pub fn initSurface(parent: *Presenter, hwnd: win32.HWND, width: u32, height: u32) Error!Presenter {
        var dxgi_device: *win32.IDXGIDevice = undefined;
        if (parent.device.IUnknown.QueryInterface(win32.IID_IDXGIDevice, @ptrCast(&dxgi_device)) < 0) return error.DeviceUnavailable;
        defer _ = dxgi_device.IUnknown.Release();
        const surface = try dcomp.Surface.initLayer(&parent.device.IUnknown, dxgi_device, hwnd, width, height, .B8G8R8A8_UNORM, true);
        inline for (.{ parent.device, parent.context, parent.vertex_shader, parent.pixel_shader }) |object| _ = object.IUnknown.AddRef();
        return .{ .device = parent.device, .context = parent.context, .vertex_shader = parent.vertex_shader, .pixel_shader = parent.pixel_shader, .surface = surface };
    }

    pub fn frameReady(self: *Presenter) bool {
        return win32.WaitForSingleObject(self.surface.frame_latency_waitable, 0) == .NO_ERROR;
    }

    pub fn deinit(self: *Presenter) void {
        self.surface.deinit();
        _ = self.pixel_shader.IUnknown.Release();
        _ = self.vertex_shader.IUnknown.Release();
        self.context.ClearState();
        self.context.Flush();
        _ = self.context.IUnknown.Release();
        _ = self.device.IUnknown.Release();
        self.* = undefined;
    }

    pub fn resize(self: *Presenter, width: u32, height: u32) Error!void {
        self.context.ClearState();
        self.context.Flush();
        self.surface.resize(width, height) catch return error.PresentationUnavailable;
    }

    pub fn waitForFrame(self: *Presenter) void {
        _ = win32.WaitForSingleObjectEx(self.surface.frame_latency_waitable, 100, 0);
    }

    pub fn detach(self: *Presenter) void {
        self.surface.detach();
    }

    pub fn present(
        self: *Presenter,
        source: *win32.ID3D11ShaderResourceView,
        width: u32,
        height: u32,
    ) Error!void {
        const back_buffer = self.surface.getBuffer(win32.ID3D11Texture2D) orelse
            return error.PresentFailed;
        defer _ = back_buffer.IUnknown.Release();

        const rtv_desc: win32.D3D11_RENDER_TARGET_VIEW_DESC = .{
            .Format = presentation_view_format,
            .ViewDimension = .TEXTURE2D,
            .Anonymous = .{ .Texture2D = .{ .MipSlice = 0 } },
        };
        var render_target: *win32.ID3D11RenderTargetView = undefined;
        if (self.device.CreateRenderTargetView(
            &back_buffer.ID3D11Resource,
            &rtv_desc,
            &render_target,
        ) < 0) return error.SurfaceViewUnavailable;
        defer _ = render_target.IUnknown.Release();

        var targets = [_]?*win32.ID3D11RenderTargetView{render_target};
        self.context.OMSetRenderTargets(targets.len, &targets, null);
        var viewport: win32.D3D11_VIEWPORT = .{
            .TopLeftX = 0,
            .TopLeftY = 0,
            .Width = @floatFromInt(width),
            .Height = @floatFromInt(height),
            .MinDepth = 0,
            .MaxDepth = 0,
        };
        self.context.RSSetViewports(1, @ptrCast(&viewport));
        self.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);
        self.context.VSSetShader(self.vertex_shader, null, 0);
        self.context.PSSetShader(self.pixel_shader, null, 0);
        var resources = [_]?*win32.ID3D11ShaderResourceView{source};
        self.context.PSSetShaderResources(4, resources.len, &resources);
        self.context.Draw(4, 0);
        var no_resources = [_]?*win32.ID3D11ShaderResourceView{null};
        self.context.PSSetShaderResources(4, no_resources.len, &no_resources);
        self.context.OMSetRenderTargets(0, null, null);

        const hr = self.surface.swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0 and hr != dcomp.DXGI_STATUS_OCCLUDED) return error.PresentFailed;
    }
};

test "presentation view encodes linear shader output as sRGB" {
    try @import("std").testing.expectEqual(
        win32.DXGI_FORMAT.B8G8R8A8_UNORM_SRGB,
        presentation_view_format,
    );
}
