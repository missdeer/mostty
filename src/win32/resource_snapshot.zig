//! UI-thread diagnostic snapshots. No GPU waits/readback or OS memory queries.
const std = @import("std");
const builtin = @import("builtin");
const win32 = @import("win32").everything;
const state = @import("state.zig");
const Renderer = @import("renderer.zig");
const Config = @import("../config.zig");
const gpu = @import("d3d11/gpu.zig");
const Stats = @import("../renderer/resource_stats.zig");
const DecodeStats = @import("../renderer/background_decode.zig").Stats;

pub const Pane = struct {
    id: u32,
    visible: bool,
    cache_state: []const u8,
    viewport_hash: []const u8,
    terminal: Stats.Terminal,
    renderer: Stats.Renderer,
};
pub const Snapshot = struct {
    schema: u32 = 1,
    compiler: []const u8 = builtin.zig_version_string,
    mode: []const u8 = @tagName(builtin.mode),
    target_cpu: []const u8 = builtin.cpu.model.name,
    backend: []const u8,
    presentation: ?[]const u8,
    configured_gpu: ?[]const u8,
    font: []const u8,
    font_size_pt: f32,
    dpi: u32,
    window_pixels: [2]u32,
    pane_count: usize,
    active_panes: usize,
    hidden_panes: usize,
    glyph_worker_pending: u64,
    panes: []const Pane,
    process_renderer: Stats.Renderer,
    wallpaper_decode: ?DecodeStats,
    probe_us: u64,
};

pub fn capture(allocator: std.mem.Allocator, window: *state.Window, parent: *Renderer, cfg: *const Config) !Snapshot {
    const start = state.qpcNow();
    const active = if (parent.backend) |*backend| backend else return error.BackendUnavailable;
    const panes = try allocator.alloc(Pane, window.panes.items.len);
    var visible: usize = 0;
    const shown = win32.IsWindowVisible(window.hwnd) != 0 and win32.IsIconic(window.hwnd) == 0;
    for (window.panes.items, panes) |pane, *result| {
        const pane_visible = shown and window.paneVisible(pane);
        visible += @intFromBool(pane_visible);
        var resources: Stats.Renderer = if (pane.renderer) |*surface| switch (surface.backend) {
            inline else => |*backend, tag| backendResources(backend, tag, false),
        } else .{};
        resources.trim_count = pane.render_trim_count;
        resources.trimmed_logical_bytes = pane.render_trim_bytes;
        resources.restore_ns = pane.render_restore_us * 1000;
        result.* = .{
            .id = pane.id,
            .visible = pane_visible,
            .cache_state = @tagName(pane.render_cache.state),
            .viewport_hash = try std.fmt.allocPrint(allocator, "{x:0>16}", .{pane.session.viewportHash()}),
            .terminal = pane.session.memoryResources(),
            .renderer = resources,
        };
    }
    const size = win32.getClientSize(window.hwnd);
    return .{
        .backend = @tagName(std.meta.activeTag(active.*)),
        .presentation = switch (active.*) {
            .opengl => |backend| @tagName(backend.presentation),
            inline .vulkan, .@"native-vulkan" => |backend| @tagName(backend.presentation),
            else => null,
        },
        .configured_gpu = cfg.gpu,
        .font = try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(parent.font_service.effective_primary)),
        .font_size_pt = parent.font_service.font_size_pt,
        .dpi = parent.font_service.dpi,
        .window_pixels = .{ @intCast(@max(0, size.cx)), @intCast(@max(0, size.cy)) },
        .pane_count = panes.len,
        .active_panes = visible,
        .hidden_panes = panes.len - visible,
        .glyph_worker_pending = if (parent.font_service.glyph_worker_started) parent.font_service.glyph_worker.pending_count.load(.monotonic) else 0,
        .panes = panes,
        .process_renderer = switch (active.*) {
            inline else => |*backend, tag| backendResources(backend, tag, true),
        },
        .wallpaper_decode = switch (active.*) {
            inline else => |*backend| if (backend.bg_decoder) |worker| worker.stats() else null,
        },
        .probe_us = state.qpcUsSince(start),
    };
}

fn backendResources(backend: anytype, comptime tag: anytype, owns_wallpaper: bool) Stats.Renderer {
    var result: Stats.Renderer = .{ .cpu_grid_bytes = @as(u64, backend.shadow_cells.len) * @sizeOf(gpu.shader.Cell), .atlas_growths = backend.common.atlas_growths };
    const size = if (comptime tag == .d3d11) backend.glyph_texture.size else backend.atlas_size;
    if (size) |extent| {
        result.atlas_width = extent.x;
        result.atlas_height = extent.y;
        result.atlas_logical_bytes = @as(u64, extent.x) * extent.y * 4;
    }
    if (backend.glyph_cache) |cache| {
        result.glyph_slots = cache.nodes.len;
        result.glyph_used = cache.map.count();
        for (cache.nodes) |node| result.glyph_pending += @intFromBool(node.pending);
        result.glyph_hits = cache.hits;
        result.glyph_misses = cache.misses;
        result.glyph_evictions = cache.evictions;
        result.glyph_no_slot = cache.frame_no_slot;
        result.glyph_index_requested_bytes = cache.requested_bytes;
    }
    result.renderer_image_count = backend.kitty_images.images.count();
    var images = backend.kitty_images.images.valueIterator();
    while (images.next()) |image| result.renderer_image_logical_bytes += @as(u64, image.width) * image.height * 4;
    if (owns_wallpaper and backend.background_image.loaded())
        result.wallpaper_logical_bytes = @as(u64, backend.background_image.src_w) * backend.background_image.src_h * 4;
    result.cache_lower_bound_bytes = result.cpu_grid_bytes + result.atlas_logical_bytes + result.glyph_index_requested_bytes + result.renderer_image_logical_bytes;
    if (comptime tag == .d3d11) {
        result.grid_buffer_logical_bytes = @as(u64, backend.shader_cells.count) * @sizeOf(gpu.shader.Cell);
        result.grid_target_logical_bytes = @as(u64, @intCast(@max(0, backend.grid_texture_size.cx))) * @as(u64, @intCast(@max(0, backend.grid_texture_size.cy))) * 4;
    } else if (comptime tag == .d3d12) {
        result.grid_buffer_logical_bytes = @as(u64, backend.cells_count) * @sizeOf(gpu.shader.Cell);
        result.grid_target_logical_bytes = @as(u64, @intCast(@max(0, backend.grid_size.cx))) * @as(u64, @intCast(@max(0, backend.grid_size.cy))) * 4;
        result.staging_retained_logical_bytes = 0;
        result.retired_resource_count = backend.retired_after_failure.items.len;
        for (backend.arenas) |arena| {
            result.staging_retained_logical_bytes.? += arena.capacity;
            result.retired_resource_count.? += arena.retired.items.len;
        }
    } else if (comptime tag == .opengl) {
        result.grid_buffer_logical_bytes = backend.cells.size;
    } else {
        if (backend.core) |*core| {
            for (core.frames) |frame| result.grid_buffer_logical_bytes += frame.cells.size;
            const stats = core.upload_stats;
            result.uploads = .{
                .active_bytes = core.inflight_upload_bytes + core.pending_upload_bytes,
                .active_tasks = core.uploads.items.len - core.uploads_head + core.pending_uploads.items.len,
                .idle_bytes = core.pooled_upload_bytes,
                .idle_tasks = core.free_uploads.items.len,
                .pending_tasks = core.pending_uploads.items.len,
                .allocations = stats.allocations,
                .pools_created = stats.pools_created,
                .submits = stats.submits,
                .requests = stats.requests,
                .reuses = stats.reuses,
                .backpressure = stats.backpressure,
                .peak_active_bytes = stats.peak_inflight_bytes,
                .peak_allocated_bytes = stats.peak_allocated_bytes,
                .max_reclaim_ns = stats.max_reclaim_ns,
            };
        }
    }
    return result;
}
