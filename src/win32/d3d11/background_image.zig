//! Wallpaper decoding has one active job, newest pending path and one ready
//! result. Messages only notify; the worker retains ownership until UI take.
const std = @import("std");
const win32 = @import("win32").everything;
const D3d11Renderer = @import("../d3d11.zig");
const Config = @import("../../config.zig");
const gpu = @import("gpu.zig");
const types = @import("../types.zig");
const decode = @import("../../renderer/background_decode.zig");
const log = std.log.scoped(.d3d);

pub const BgImageDecoded = decode.Result;
pub const DecodeWorker = decode.Worker;

fn clearCachedPath(self: anytype) void {
    if (self.bg_image_allocator) |allocator| {
        if (self.bg_image_path.len != 0) allocator.free(self.bg_image_path);
    }
    self.bg_image_path = &.{};
    self.bg_image_allocator = null;
}

pub fn shutdown(self: anytype) void {
    if (self.bg_decoder) |worker| {
        worker.shutdown();
        const allocator = worker.allocator;
        allocator.destroy(worker);
        self.bg_decoder = null;
    }
    clearCachedPath(self);
}

pub fn reload(self: anytype, gpa: std.mem.Allocator, cfg: *const Config, hwnd: win32.HWND) void {
    const path = cfg.background_image;
    const retry = if (self.bg_decoder) |worker| worker.retryNeeded(self.bg_image_req_id) else false;
    const path_changed = retry or !std.mem.eql(u8, path, self.bg_image_path) or
        (path.len == 0 and self.background_image.loaded());
    const scalars_changed = self.bg_image_opacity != cfg.background_image_opacity or
        self.bg_image_position != cfg.background_image_position or
        self.bg_image_fit != cfg.background_image_fit or
        self.bg_image_repeat != cfg.background_image_repeat;
    self.bg_image_opacity = cfg.background_image_opacity;
    self.bg_image_position = cfg.background_image_position;
    self.bg_image_fit = cfg.background_image_fit;
    self.bg_image_repeat = cfg.background_image_repeat;
    if (scalars_changed) self.grid_force_full = true;
    if (!path_changed) return;

    self.bg_image_req_id +%= 1;
    if (self.bg_decoder) |worker| worker.cancel(self.bg_image_req_id);
    // This is the queued target path, not the displayed texture's owner.
    // Clearing it on every failed setup guarantees same-path reload can retry.
    clearCachedPath(self);
    if (path.len == 0) {
        self.backgroundImageRelease();
        self.grid_force_full = true;
        return;
    }
    const allocator = if (self.bg_decoder) |worker| worker.allocator else gpa;
    const path_dup = allocator.dupe(u8, path) catch return;
    const worker_path = allocator.dupe(u8, path) catch {
        allocator.free(path_dup);
        return;
    };
    const result = allocator.create(BgImageDecoded) catch {
        allocator.free(worker_path);
        allocator.free(path_dup);
        return;
    };
    result.* = .{ .req_id = self.bg_image_req_id, .path = worker_path };
    if (self.bg_decoder == null) {
        const worker = allocator.create(DecodeWorker) catch {
            result.deinit(allocator);
            allocator.free(path_dup);
            return;
        };
        worker.* = .{ .allocator = allocator, .notify_context = @ptrCast(hwnd), .notify = postNotification, .decode = decodeWic };
        worker.start() catch |err| {
            allocator.destroy(worker);
            result.deinit(allocator);
            allocator.free(path_dup);
            log.warn("background-image: worker start failed: {t}; keeping previous image", .{err});
            return;
        };
        self.bg_decoder = worker;
    }
    if (!self.bg_decoder.?.request(result)) {
        result.deinit(allocator);
        allocator.free(path_dup);
        return;
    }
    self.bg_image_path = path_dup;
    self.bg_image_allocator = allocator;
}

pub fn applyDecoded(self: anytype, result: *const BgImageDecoded) void {
    if (result.req_id != self.bg_image_req_id) return;
    const pixels = result.pixels orelse {
        clearCachedPath(self);
        return;
    };
    if (!self.backgroundImageUpload(.{ .pixels = pixels, .w = result.w, .h = result.h })) {
        clearCachedPath(self);
        return;
    }
    log.info("background-image: loaded '{s}' ({}x{})", .{ result.path, result.w, result.h });
    self.grid_force_full = true;
}

fn decodeWic(allocator: std.mem.Allocator, path: []const u8, guard: decode.Guard) ?decode.Decoded {
    if (!guard.valid()) return null;
    if (win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED) < 0) return null;
    defer win32.CoUninitialize();
    return gpu.decodeBackground(allocator, path, guard);
}

fn postNotification(context: *anyopaque) bool {
    return win32.PostMessageW(@ptrCast(context), types.WM_APP_BG_IMAGE_DECODED, 0, 0) != 0;
}

test "wallpaper failure preserves the displayed image and clear supersedes late results" {
    const Mock = struct {
        const Image = struct {
            present: bool = true,
            pub fn loaded(self: @This()) bool {
                return self.present;
            }
        };
        background_image: Image = .{},
        bg_image_path: []const u8 = &.{},
        bg_image_allocator: ?std.mem.Allocator = null,
        bg_decoder: ?*DecodeWorker = null,
        bg_image_req_id: u32 = 7,
        bg_image_opacity: f32 = 1,
        bg_image_position: Config.BackgroundImagePosition = .center,
        bg_image_fit: Config.BackgroundImageFit = .contain,
        bg_image_repeat: bool = false,
        grid_force_full: bool = false,
        succeed: bool = false,
        uploads: u32 = 0,
        releases: u32 = 0,
        pub fn backgroundImageUpload(self: *@This(), _: gpu.DecodedBackground) bool {
            if (!self.succeed) return false;
            self.uploads += 1;
            self.background_image.present = true;
            return true;
        }
        pub fn backgroundImageRelease(self: *@This()) void {
            self.releases += 1;
            self.background_image.present = false;
        }
    };
    var mock: Mock = .{};
    defer shutdown(&mock);
    mock.bg_image_path = try std.testing.allocator.dupe(u8, "same");
    mock.bg_image_allocator = std.testing.allocator;
    var result: BgImageDecoded = .{ .req_id = 7, .path = @constCast("same") };
    applyDecoded(&mock, &result);
    try std.testing.expect(mock.background_image.loaded() and mock.bg_image_path.len == 0);
    var pixels = [_]u8{ 1, 2, 3, 255 };
    result.pixels = &pixels;
    result.w = 1;
    result.h = 1;
    applyDecoded(&mock, &result); // Failed GPU preparation must not blank the old image.
    try std.testing.expect(mock.background_image.loaded() and mock.releases == 0);
    mock.succeed = true;
    result.req_id = 6;
    applyDecoded(&mock, &result);
    try std.testing.expectEqual(@as(u32, 0), mock.uploads);
    result.req_id = 7;
    applyDecoded(&mock, &result);
    try std.testing.expectEqual(@as(u32, 1), mock.uploads);
    mock.bg_image_path = try std.testing.allocator.dupe(u8, "same");
    mock.bg_image_allocator = std.testing.allocator;
    var cfg: Config = .{ .background_image = "same", .background_image_opacity = 0.5 };
    mock.grid_force_full = false;
    reload(&mock, std.testing.allocator, &cfg, undefined);
    try std.testing.expect(mock.bg_decoder == null and mock.bg_image_req_id == 7 and mock.grid_force_full);
    try std.testing.expectEqual(@as(f32, 0.5), mock.bg_image_opacity);
    cfg.background_image = "new";
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    reload(&mock, failing.allocator(), &cfg, undefined);
    try std.testing.expect(mock.background_image.loaded() and mock.bg_image_path.len == 0 and mock.bg_decoder == null);
    cfg.background_image = "";
    reload(&mock, std.testing.allocator, &cfg, undefined);
    reload(&mock, std.testing.allocator, &cfg, undefined);
    applyDecoded(&mock, &result);
    try std.testing.expect(!mock.background_image.loaded());
    try std.testing.expectEqual(@as(u32, 1), mock.releases);
}

// Computes the fitted/positioned destination rectangle of the background image
// within a `container_w` x `container_h` pixel area (the terminal grid region
// below the tab bar). Returns offset.xy + size.xy in that space. Pure geometry.
pub fn computeDest(self: anytype, container_w: f32, container_h: f32) [4]f32 {
    return @import("../../renderer/background_geometry.zig").computeDest(
        @floatFromInt(self.background_image.src_w),
        @floatFromInt(self.background_image.src_h),
        container_w,
        container_h,
        self.bg_image_fit,
        self.bg_image_position,
    );
}

// Linear/clamp sampler for the background image. CLAMP is fine even when
// tiling: the shader does its own frac() wrap and only ever samples inside
// [0,1). Lazily created on first frame that needs it.
pub fn ensureSampler(self: *D3d11Renderer) *win32.ID3D11SamplerState {
    if (self.bg_sampler) |s| return s;
    const desc: win32.D3D11_SAMPLER_DESC = .{
        .Filter = .MIN_MAG_MIP_LINEAR,
        .AddressU = .CLAMP,
        .AddressV = .CLAMP,
        .AddressW = .CLAMP,
        .MipLODBias = 0,
        .MaxAnisotropy = 1,
        .ComparisonFunc = .NEVER,
        .BorderColor = .{ 0, 0, 0, 0 },
        .MinLOD = 0,
        .MaxLOD = win32.D3D11_FLOAT32_MAX,
    };
    var sampler: *win32.ID3D11SamplerState = undefined;
    const hr = self.device.CreateSamplerState(&desc, &sampler);
    if (hr < 0) @import("com.zig").fatalHr("CreateSamplerState(bg-image)", hr);
    self.bg_sampler = sampler;
    return sampler;
}
