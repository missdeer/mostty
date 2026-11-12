const PaneSurface = @This();
const std = @import("std");

const win32 = @import("win32").everything;
const vt = @import("vt");
const Renderer = @import("renderer.zig");
const d3d11 = @import("d3d11.zig");
const d3d12 = @import("d3d12/renderer.zig");
const gl46 = @import("gl46.zig");
const vulkan = @import("vulkan.zig");
const gpu = @import("d3d11/gpu.zig");
pub const InitError = d3d12.StartupError || gl46.StartupError || vulkan.StartupError;
const types = @import("types.zig");

// Only implementations with a complete pane lifecycle enter this union.
backend: union(enum) {
    d3d11: d3d11,
    d3d12: d3d12,
    opengl: gl46,
    vulkan: vulkan,
    @"native-vulkan": vulkan,
},
font_generation: u32,

pub fn init(parent: *Renderer, common: *Renderer.RendererCommon) InitError!?PaneSurface {
    const active = if (parent.backend) |*backend| backend else return null;
    return switch (active.*) {
        .d3d11 => |*backend| .{
            .backend = .{ .d3d11 = d3d11.initSurface(backend, common) },
            .font_generation = backend.cache_gen,
        },
        .d3d12 => |*backend| .{
            .backend = .{ .d3d12 = try d3d12.initSurface(backend, common) },
            .font_generation = backend.cache_gen,
        },
        .opengl => |*backend| if (backend.initialized) .{ .backend = .{ .opengl = gl46.initSurface(backend, common) }, .font_generation = backend.cache_gen } else null,
        inline .vulkan, .@"native-vulkan" => |*backend, tag| if (backend.core != null) .{ .backend = @unionInit(@FieldType(PaneSurface, "backend"), @tagName(tag), vulkan.initSurface(backend, common)), .font_generation = backend.cache_gen } else null,
    };
}

pub fn deinit(self: *PaneSurface) void {
    switch (self.backend) {
        inline else => |*backend| backend.deinit(),
    }
    self.* = undefined;
}

pub fn sync(self: *PaneSurface, parent: *Renderer, focused: bool) void {
    switch (self.backend) {
        inline else => |*backend, tag| {
            const source = &@field(parent.backend.?, @tagName(tag));
            if (self.font_generation != source.cache_gen) {
                backend.onFontStateChanged();
                self.font_generation = source.cache_gen;
            }
            backend.common.focused = focused;
            backend.common.cell_size = parent.common.cell_size;
            backend.common.font_ligatures = parent.common.font_ligatures;
            backend.common.glyph_atlas_budget_bytes = parent.common.glyph_atlas_budget_bytes;
            backend.common.remote_or_software_adapter = parent.common.remote_or_software_adapter;
            backend.syncSurface(source);
        },
    }
}

pub fn runtimeFailure(self: *PaneSurface) ?Renderer.RuntimeFailure {
    switch (self.backend) {
        .d3d12 => |*backend| {
            _ = backend.healthy();
            if (backend.failure) |failure| return .{ .d3d12 = failure };
        },
        .opengl => |*backend| if (backend.failure) |failure| {
            return .{ .opengl = failure };
        },
        inline .vulkan, .@"native-vulkan" => |*backend, tag| if (backend.pending_failure) |failure| {
            return @unionInit(Renderer.RuntimeFailure, @tagName(tag), failure);
        },
        else => {},
    }
    return null;
}

pub fn needsFrame(self: *const PaneSurface) bool {
    return switch (self.backend) {
        inline .d3d12, .opengl, .vulkan, .@"native-vulkan" => |backend| backend.frame_pending or backend.common.glyph_retry,
        .d3d11 => |backend| backend.common.glyph_retry,
    };
}

pub fn invalidatePresentation(self: *PaneSurface) void {
    switch (self.backend) {
        inline else => |*backend| backend.common.pane_present_valid = false,
    }
}

/// Called on config publication, including for panes that never draw again.
pub fn releaseTerminalImages(self: *PaneSurface, pane_id: types.TabId) void {
    switch (self.backend) {
        inline else => |*backend| {
            backend.releaseKittyImagesForTab(pane_id);
            backend.grid_force_full = true;
            backend.common.pane_present_valid = false;
        },
    }
}

pub fn cacheGeneration(self: *const PaneSurface) u32 {
    return switch (self.backend) {
        inline else => |backend| backend.cache_gen,
    };
}

pub fn setCacheGeneration(self: *PaneSurface, generation: u32) void {
    switch (self.backend) {
        inline else => |*backend| backend.cache_gen = generation,
    }
}

/// Logical cache capacity lower bound; excludes presentation, allocator and
/// driver overhead, and must not be added to OS memory measurements.
pub fn cacheBytes(self: *const PaneSurface) u64 {
    return switch (self.backend) {
        inline else => |*backend, tag| bytes: {
            var result: u64 = @as(u64, backend.shadow_cells.len) * @sizeOf(gpu.shader.Cell);
            const atlas_size = if (comptime tag == .d3d11) backend.glyph_texture.size else backend.atlas_size;
            if (atlas_size) |size| result += @as(u64, size.x) * size.y * 4;
            if (backend.glyph_cache) |cache| result += @as(u64, cache.nodes.len) * @sizeOf(@TypeOf(cache.nodes[0]));
            var images = backend.kitty_images.images.valueIterator();
            while (images.next()) |image| result += @as(u64, image.width) * image.height * 4;
            break :bytes result;
        },
    };
}

pub fn applyGlyphResult(self: *PaneSurface, result: *Renderer.RasterResult) bool {
    return switch (self.backend) {
        inline else => |*backend| backend.applyGlyphResult(result),
    };
}

test "restored surface rejects a late job even when the key, slot and slot generation match" {
    const Cache = @import("glyph_index_cache.zig");
    var common: Renderer.RendererCommon = undefined;
    common.surface_id = 4;
    var surface: PaneSurface = .{ .backend = .{ .d3d11 = undefined }, .font_generation = 0 };
    const backend = &surface.backend.d3d11;
    backend.common = &common;
    backend.glyph_cache = try Cache.init(std.testing.allocator, 2);
    defer backend.glyph_cache.?.deinit(std.testing.allocator);
    surface.setCacheGeneration(10);
    const key = Cache.Key.init('x', &.{}, .single, .regular);
    const old = (try backend.glyph_cache.?.reserve(std.testing.allocator, key)).newly_reserved_pending;
    var result: Renderer.RasterResult = .{ .surface_id = 4, .cache_gen = 10, .slot = old.index, .slot_gen = old.slot_gen, .key = key, .bytes = &.{}, .w = 0, .h = 0, .is_color = false, .failed = true };
    backend.glyph_cache.?.clearRetainingCapacity();
    const current = (try backend.glyph_cache.?.reserve(std.testing.allocator, key)).newly_reserved_pending;
    try std.testing.expectEqual(old.index, current.index);
    try std.testing.expectEqual(old.slot_gen, current.slot_gen);
    surface.setCacheGeneration(11);
    try std.testing.expect(!surface.applyGlyphResult(&result));
    try std.testing.expect((try backend.glyph_cache.?.reserve(std.testing.allocator, key)) == .already_pending);
}

pub fn render(
    self: *PaneSurface,
    hwnd: win32.HWND,
    pane_id: types.TabId,
    term: *vt.Terminal,
    resizing: bool,
    mouse_in_scrollbar: bool,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
    remote_session: bool,
    url_highlight: ?types.UrlHighlight,
) void {
    // The parent may render and ValidateRect before the child's WM_PAINT is
    // dispatched. Preserve that exposure obligation before it is consumed.
    if (win32.GetUpdateRect(hwnd, null, 0) != 0) self.invalidatePresentation();
    switch (self.backend) {
        inline else => |*backend, tag| {
            const result = backend.render(
                hwnd,
                pane_id,
                term,
                .{ .tabs = &.{}, .new_tab_col = null, .new_tab_hovered = false },
                resizing,
                mouse_in_scrollbar,
                cursor_text,
                selection_bg,
                selection_fg,
                background_opacity,
                remote_session,
                url_highlight,
            );
            if (comptime tag == .vulkan or tag == .@"native-vulkan") {
                if (result) |failure| backend.pending_failure = failure;
            }
        },
    }
}
