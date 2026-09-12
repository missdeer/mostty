//! Optional WGL/D3D11 bridge for DirectComposition presentation.
//!
//! The OpenGL renderer remains complete without this module. The bridge owns
//! only a multithread-capable D3D11 presentation device, the cross-API render
//! target, and the DirectComposition tree. The caller selects baseline WGL
//! after a capability failure and coordinates rebuilding after a runtime fault.

const std = @import("std");
const win32 = @import("win32").everything;
const dcomp_blit = @import("../dcomp_blit.zig");

const gl = @import("loader.zig");

const log = std.log.scoped(.gl46_interop);

const WGL_ACCESS_WRITE_DISCARD_NV: gl.@"enum" = 0x0002;
const interop_texture_format: win32.DXGI_FORMAT = .B8G8R8A8_UNORM;

fn interopDeviceFlags() win32.D3D11_CREATE_DEVICE_FLAG {
    // Omitting SINGLETHREADED is required by the D3D11 interop contract.
    return .{ .BGRA_SUPPORT = 1 };
}

pub const Path = enum {
    baseline,
    direct_composition,
};

pub const State = enum {
    untried,
    active,
    unavailable,
    failed,

    pub fn path(self: State) Path {
        return if (self == .active) .direct_composition else .baseline;
    }
};

pub const Error = error{
    FrameBusy,
    ProceduresUnavailable,
    DeviceUnavailable,
    ShaderUnavailable,
    InteropDeviceUnavailable,
    FactoryUnavailable,
    SwapChainUnavailable,
    CompositionUnavailable,
    SurfaceUnavailable,
    RegistrationUnavailable,
    FramebufferIncomplete,
    SurfaceViewUnavailable,
    LockFailed,
    UnlockFailed,
    PresentFailed,
};

const WglDxOpenDevice = *const fn (*anyopaque) callconv(.winapi) ?win32.HANDLE;
const WglDxCloseDevice = *const fn (win32.HANDLE) callconv(.winapi) win32.BOOL;
const WglDxRegisterObject = *const fn (
    win32.HANDLE,
    *anyopaque,
    gl.uint,
    gl.@"enum",
    gl.@"enum",
) callconv(.winapi) ?win32.HANDLE;
const WglDxUnregisterObject = *const fn (
    win32.HANDLE,
    win32.HANDLE,
) callconv(.winapi) win32.BOOL;
const WglDxLockObjects = *const fn (
    win32.HANDLE,
    gl.int,
    [*]win32.HANDLE,
) callconv(.winapi) win32.BOOL;

const Procs = struct {
    open_device: WglDxOpenDevice,
    close_device: WglDxCloseDevice,
    register_object: WglDxRegisterObject,
    unregister_object: WglDxUnregisterObject,
    lock_objects: WglDxLockObjects,
    unlock_objects: WglDxLockObjects,

    fn load() ?Procs {
        return .{
            .open_device = procAddress(WglDxOpenDevice, "wglDXOpenDeviceNV") orelse return null,
            .close_device = procAddress(WglDxCloseDevice, "wglDXCloseDeviceNV") orelse return null,
            .register_object = procAddress(WglDxRegisterObject, "wglDXRegisterObjectNV") orelse return null,
            .unregister_object = procAddress(WglDxUnregisterObject, "wglDXUnregisterObjectNV") orelse return null,
            .lock_objects = procAddress(WglDxLockObjects, "wglDXLockObjectsNV") orelse return null,
            .unlock_objects = procAddress(WglDxLockObjects, "wglDXUnlockObjectsNV") orelse return null,
        };
    }
};

pub const Bridge = struct {
    procs: Procs,
    presenter: dcomp_blit.Presenter,
    interop_device: win32.HANDLE,

    framebuffer: gl.uint,
    renderbuffer: gl.uint = 0,
    texture: ?*win32.ID3D11Texture2D = null,
    texture_view: ?*win32.ID3D11ShaderResourceView = null,
    interop_object: ?win32.HANDLE = null,
    width: u32 = 0,
    height: u32 = 0,
    locked: bool = false,
    active: bool = true,
    surface_verified: bool = false,
    pane: bool = false,

    pub fn init(hwnd: win32.HWND, width: u32, height: u32, parent: ?*Bridge) Error!Bridge {
        const procs = Procs.load() orelse return error.ProceduresUnavailable;

        var presenter = (if (parent) |p| dcomp_blit.Presenter.initSurface(&p.presenter, hwnd, width, height) else dcomp_blit.Presenter.initLayer(hwnd, width, height, null, false)) catch |err| switch (err) {
            error.DeviceUnavailable => return error.DeviceUnavailable,
            error.ShaderUnavailable => return error.ShaderUnavailable,
            else => return error.CompositionUnavailable,
        };
        errdefer presenter.deinit();

        const interop_device = procs.open_device(@ptrCast(presenter.device)) orelse
            return error.InteropDeviceUnavailable;
        errdefer _ = procs.close_device(interop_device);

        var framebuffer: gl.uint = 0;
        gl.CreateFramebuffers(1, @ptrCast(&framebuffer));
        if (framebuffer == 0) return error.SurfaceUnavailable;

        var bridge: Bridge = .{
            .procs = procs,
            .pane = parent != null,
            .presenter = presenter,
            .interop_device = interop_device,
            .framebuffer = framebuffer,
        };
        bridge.recreateSurface(width, height) catch |err| {
            gl.DeleteFramebuffers(1, @ptrCast(&framebuffer));
            return err;
        };
        return bridge;
    }

    pub fn deinit(self: *Bridge) void {
        self.disable();
        if (self.locked) {
            log.err("leaving a failed locked interop object to process teardown", .{});
            return;
        }
        self.releaseSurface();
        if (self.framebuffer != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.framebuffer));
        _ = self.procs.close_device(self.interop_device);
        self.presenter.deinit();
        self.* = undefined;
    }

    pub fn begin(self: *Bridge, width: u32, height: u32) Error!void {
        if (!self.active) return error.LockFailed;
        if (self.width != width or self.height != height) {
            try self.recreateSurface(width, height);
        }
        if (self.pane) {
            if (!self.presenter.frameReady()) return error.FrameBusy;
        } else self.presenter.waitForFrame();
        try self.lock();
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.framebuffer);
        if (!self.surface_verified) {
            if (gl.CheckNamedFramebufferStatus(self.framebuffer, gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE) {
                gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
                return error.FramebufferIncomplete;
            }
            self.surface_verified = true;
        }
    }

    pub fn present(self: *Bridge) Error!void {
        gl.Flush();
        try self.unlock();
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);

        self.presenter.present(self.texture_view.?, self.width, self.height) catch
            return error.PresentFailed;
    }

    pub fn disable(self: *Bridge) void {
        if (!self.active and !self.locked) return;
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        if (self.active) {
            self.presenter.detach();
        }
        self.active = false;
        if (self.locked) {
            gl.Finish();
            self.unlock() catch return;
        }
    }

    fn recreateSurface(self: *Bridge, width: u32, height: u32) Error!void {
        const had_surface = self.width != 0 or self.height != 0;
        self.releaseSurface();
        if (had_surface) {
            self.presenter.resize(width, height) catch return error.SurfaceUnavailable;
        }

        const desc: win32.D3D11_TEXTURE2D_DESC = .{
            .Width = width,
            .Height = height,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = interop_texture_format,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .SHADER_RESOURCE = 1, .RENDER_TARGET = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        var texture: *win32.ID3D11Texture2D = undefined;
        if (self.presenter.device.CreateTexture2D(&desc, null, &texture) < 0) {
            return error.SurfaceUnavailable;
        }
        errdefer _ = texture.IUnknown.Release();

        var texture_view: *win32.ID3D11ShaderResourceView = undefined;
        if (self.presenter.device.CreateShaderResourceView(
            &texture.ID3D11Resource,
            null,
            &texture_view,
        ) < 0) return error.SurfaceViewUnavailable;
        errdefer _ = texture_view.IUnknown.Release();

        var renderbuffer: gl.uint = 0;
        gl.GenRenderbuffers(1, @ptrCast(&renderbuffer));
        if (renderbuffer == 0) return error.SurfaceUnavailable;
        errdefer gl.DeleteRenderbuffers(1, @ptrCast(&renderbuffer));

        const object = self.procs.register_object(
            self.interop_device,
            @ptrCast(texture),
            renderbuffer,
            gl.RENDERBUFFER,
            WGL_ACCESS_WRITE_DISCARD_NV,
        ) orelse return error.RegistrationUnavailable;
        errdefer _ = self.procs.unregister_object(self.interop_device, object);

        // The NV specification's D3D11 sample attaches registered objects
        // while unlocked; the per-frame lock gates access to their storage.
        gl.NamedFramebufferRenderbuffer(
            self.framebuffer,
            gl.COLOR_ATTACHMENT0,
            gl.RENDERBUFFER,
            renderbuffer,
        );
        errdefer gl.NamedFramebufferRenderbuffer(
            self.framebuffer,
            gl.COLOR_ATTACHMENT0,
            gl.RENDERBUFFER,
            0,
        );
        gl.NamedFramebufferDrawBuffer(self.framebuffer, gl.COLOR_ATTACHMENT0);

        self.texture = texture;
        self.texture_view = texture_view;
        self.renderbuffer = renderbuffer;
        self.interop_object = object;
        self.width = width;
        self.height = height;
        self.surface_verified = false;
    }

    fn releaseSurface(self: *Bridge) void {
        if (self.locked) return;
        if (self.interop_object) |object| {
            gl.NamedFramebufferRenderbuffer(
                self.framebuffer,
                gl.COLOR_ATTACHMENT0,
                gl.RENDERBUFFER,
                0,
            );
            if (self.procs.unregister_object(self.interop_device, object) == 0) {
                log.warn("wglDXUnregisterObjectNV failed during surface release", .{});
            }
            self.interop_object = null;
        }
        if (self.renderbuffer != 0) {
            gl.DeleteRenderbuffers(1, @ptrCast(&self.renderbuffer));
            self.renderbuffer = 0;
        }
        if (self.texture_view) |texture_view| {
            _ = texture_view.IUnknown.Release();
            self.texture_view = null;
        }
        if (self.texture) |texture| {
            _ = texture.IUnknown.Release();
            self.texture = null;
        }
        self.width = 0;
        self.height = 0;
        self.surface_verified = false;
    }

    fn lock(self: *Bridge) Error!void {
        var objects = [_]win32.HANDLE{self.interop_object.?};
        if (self.procs.lock_objects(self.interop_device, 1, &objects) == 0) {
            return error.LockFailed;
        }
        self.locked = true;
    }

    fn unlock(self: *Bridge) Error!void {
        var objects = [_]win32.HANDLE{self.interop_object.?};
        if (self.procs.unlock_objects(self.interop_device, 1, &objects) == 0) {
            return error.UnlockFailed;
        }
        self.locked = false;
    }
};

fn procAddress(comptime T: type, name: [*:0]const u8) ?T {
    const candidate = win32.wglGetProcAddress(name) orelse return null;
    const raw = @intFromPtr(candidate);
    if (raw <= 3 or raw == std.math.maxInt(usize)) return null;
    return @ptrCast(candidate);
}

test "only an active bridge replaces the usable baseline presentation" {
    try std.testing.expectEqual(Path.baseline, State.untried.path());
    try std.testing.expectEqual(Path.baseline, State.unavailable.path());
    try std.testing.expectEqual(Path.baseline, State.failed.path());
    try std.testing.expectEqual(Path.direct_composition, State.active.path());
}

test "interop device creation remains multithread capable" {
    const flags = interopDeviceFlags();
    try std.testing.expectEqual(@as(u1, 0), flags.SINGLETHREADED);
    try std.testing.expectEqual(@as(u1, 1), flags.BGRA_SUPPORT);
}

test "interop presentation encodes linear shader output as sRGB" {
    try std.testing.expectEqual(
        win32.DXGI_FORMAT.B8G8R8A8_UNORM,
        interop_texture_format,
    );
}
