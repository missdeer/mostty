//! Background image (`background-image` config item) full lifecycle:
//! WIC async decode worker, GPU upload, fit/position geometry, and the
//! linear-clamp sampler used by the cell pixel shader to sample it.
//!
//! Functions take `*D3d11Renderer` because they own a slice of its state
//! (`background_image`, `bg_image_*`, `bg_sampler`). Same pattern as
//! `glyph.zig` / `font_state.zig`.

const std = @import("std");
const win32 = @import("win32").everything;
const D3d11Renderer = @import("../d3d11.zig");
const Config = @import("../../Config.zig");
const gpu = @import("gpu.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.d3d);

// Result payload posted from the WIC decode worker back to the UI thread via
// WM_APP_BG_IMAGE_DECODED. The pointer travels through lParam; the handler
// owns the struct (and its pixels + path) and must call `deinit`.
//
// `pixels == null` means decode failed; the handler still consults `req_id`
// to decide whether to release the currently-displayed image (a failed
// decode for the latest request clears the image so the displayed state
// matches the configured path).
pub const BgImageDecoded = struct {
    req_id: u32,
    path: []u8,
    pixels: ?[]u8,
    w: u32,
    h: u32,

    pub fn deinit(self: *BgImageDecoded, gpa: std.mem.Allocator) void {
        if (self.pixels) |p| gpa.free(p);
        gpa.free(self.path);
        gpa.destroy(self);
    }
};

// Async (re)configure of the background image. Used by both cold-start
// (right after CreateWindowExW) and config hot-reload. Updates cheap scalars
// and the cached path synchronously, then — if the path changed — kicks the
// WIC decode onto a worker thread so a 100ms+ decode no longer hangs the
// message loop. The currently-displayed image stays visible until the worker
// delivers the new one, avoiding a brief "no image" flash mid-reload.
pub fn reload(
    self: *D3d11Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    const path = cfg.background_image;
    const path_changed = !std.mem.eql(u8, path, self.bg_image_path);

    const scalars_changed = self.bg_image_opacity != cfg.background_image_opacity or
        self.bg_image_position != cfg.background_image_position or
        self.bg_image_fit != cfg.background_image_fit or
        self.bg_image_repeat != cfg.background_image_repeat;

    self.bg_image_opacity = cfg.background_image_opacity;
    self.bg_image_position = cfg.background_image_position;
    self.bg_image_fit = cfg.background_image_fit;
    self.bg_image_repeat = cfg.background_image_repeat;

    if (path_changed) {
        // Bump first: any worker still in flight from a prior reload is now
        // stale and its result will be dropped by the handler.
        self.bg_image_req_id +%= 1;

        if (path.len == 0) {
            // Clearing the image is cheap — apply directly, no worker.
            self.background_image.release();
            if (self.bg_image_path.len != 0) gpa.free(self.bg_image_path);
            self.bg_image_path = &.{};
            self.grid_force_full = true;
            return;
        }

        // Setup order is chosen so that any pre-spawn failure leaves
        // `bg_image_path` UNCHANGED. Without that, a failed setup would
        // poison the cached path: a subsequent reload with the same
        // configured path would hit `path_changed == false` and never
        // retry, leaving the old (or no) image visible forever.

        const path_dup = gpa.dupe(u8, path) catch {
            log.warn("background-image: OOM dup'ing path '{s}'; keeping previous image", .{path});
            if (scalars_changed) self.grid_force_full = true;
            return;
        };
        const worker_path = gpa.dupe(u8, path) catch {
            gpa.free(path_dup);
            log.warn("background-image: OOM dup'ing worker path '{s}'; keeping previous image", .{path});
            if (scalars_changed) self.grid_force_full = true;
            return;
        };

        // Pre-allocate the result envelope on the UI thread so the worker
        // is never in a "decoded but can't post" state: its only post-spawn
        // failure mode becomes PostMessage returning 0 (window gone, i.e.
        // shutdown), and ownership of the envelope is unambiguous.
        const result = gpa.create(BgImageDecoded) catch {
            gpa.free(worker_path);
            gpa.free(path_dup);
            log.warn("background-image: OOM allocating result envelope; keeping previous image", .{});
            if (scalars_changed) self.grid_force_full = true;
            return;
        };
        result.* = .{
            .req_id = self.bg_image_req_id,
            .path = worker_path,
            .pixels = null,
            .w = 0,
            .h = 0,
        };

        const thread = std.Thread.spawn(.{}, decodeWorker, .{ gpa, hwnd, result }) catch |e| {
            // `result.deinit` frees worker_path along with the envelope.
            result.deinit(gpa);
            gpa.free(path_dup);
            log.warn("background-image: spawn worker failed: {s}; keeping previous image", .{@errorName(e)});
            if (scalars_changed) self.grid_force_full = true;
            return;
        };
        thread.detach();

        // Worker is committed; only now publish the new cached path. A
        // follow-up reload with the same path will see `path_changed ==
        // false` and won't respawn. Image swap + grid_force_full happen in
        // the message handler so the previous frame keeps the old image.
        if (self.bg_image_path.len != 0) gpa.free(self.bg_image_path);
        self.bg_image_path = path_dup;
        return;
    }

    if (scalars_changed) self.grid_force_full = true;
}

// Apply a worker's decoded result on the UI thread. Stale results (whose
// req_id no longer matches the latest reload) are ignored — only the
// currently-targeted image gets uploaded and displayed.
pub fn applyDecoded(
    self: *D3d11Renderer,
    result: *const BgImageDecoded,
) void {
    if (result.req_id != self.bg_image_req_id) return;

    self.background_image.release();
    if (result.pixels) |pixels| {
        const decoded: gpu.DecodedBackground = .{ .pixels = pixels, .w = result.w, .h = result.h };
        self.background_image = gpu.uploadBackground(self.device, decoded);
        if (self.background_image.loaded()) {
            log.info("background-image: loaded '{s}' ({}x{})", .{ result.path, result.w, result.h });
        }
    }
    self.grid_force_full = true;
}

// Worker entry point. Runs on a detached `std.Thread` and takes ownership
// of `result` (envelope + `result.path`, both gpa-allocated by the caller).
// On WIC decode failure `result.pixels` stays null; the handler treats that
// as "configured image couldn't load" and releases the displayed image.
// WIC needs CoInitialize on the calling thread; MTA suits a one-shot
// decode that posts back and exits.
fn decodeWorker(
    gpa: std.mem.Allocator,
    hwnd: win32.HWND,
    result: *BgImageDecoded,
) void {
    _ = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    defer win32.CoUninitialize();

    if (gpu.decodeBackground(gpa, result.path)) |decoded| {
        result.pixels = decoded.pixels;
        result.w = decoded.w;
        result.h = decoded.h;
    }

    const lparam: win32.LPARAM = @bitCast(@intFromPtr(result));
    if (win32.PostMessageW(hwnd, types.WM_APP_BG_IMAGE_DECODED, 0, lparam) == 0) {
        // Window already gone (shutdown). Free everything ourselves.
        result.deinit(gpa);
    }
}

// Computes the fitted/positioned destination rectangle of the background image
// within a `container_w` x `container_h` pixel area (the terminal grid region
// below the tab bar). Returns offset.xy + size.xy in that space. Pure geometry.
pub fn computeDest(self: *D3d11Renderer, container_w: f32, container_h: f32) [4]f32 {
    const sw: f32 = @floatFromInt(self.background_image.src_w);
    const sh: f32 = @floatFromInt(self.background_image.src_h);
    if (sw <= 0 or sh <= 0) return .{ 0, 0, 0, 0 };

    var dw: f32 = sw;
    var dh: f32 = sh;
    switch (self.bg_image_fit) {
        .none => {},
        .stretch => {
            dw = container_w;
            dh = container_h;
        },
        .contain => {
            const s = @min(container_w / sw, container_h / sh);
            dw = sw * s;
            dh = sh * s;
        },
        .cover => {
            const s = @max(container_w / sw, container_h / sh);
            dw = sw * s;
            dh = sh * s;
        },
    }

    const free_x = container_w - dw;
    const free_y = container_h - dh;
    const ox: f32 = switch (self.bg_image_position) {
        .top_left, .center_left, .bottom_left => 0,
        .top_center, .center, .bottom_center => free_x * 0.5,
        .top_right, .center_right, .bottom_right => free_x,
    };
    const oy: f32 = switch (self.bg_image_position) {
        .top_left, .top_center, .top_right => 0,
        .center_left, .center, .center_right => free_y * 0.5,
        .bottom_left, .bottom_center, .bottom_right => free_y,
    };
    return .{ ox, oy, dw, dh };
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
