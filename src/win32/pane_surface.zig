const PaneSurface = @This();

const win32 = @import("win32").everything;
const vt = @import("vt");
const Renderer = @import("renderer.zig");
const d3d11 = @import("d3d11.zig");
const d3d12 = @import("d3d12/renderer.zig");
const gl46 = @import("gl46.zig");
const vulkan = @import("vulkan.zig");
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
        inline .d3d12, .opengl, .vulkan, .@"native-vulkan" => |backend| backend.frame_pending,
        else => false,
    };
}

pub fn cacheGeneration(self: *const PaneSurface) u32 {
    return switch (self.backend) {
        inline else => |backend| backend.cache_gen,
    };
}

pub fn applyGlyphResult(self: *PaneSurface, result: *Renderer.RasterResult) bool {
    return switch (self.backend) {
        inline else => |*backend| backend.applyGlyphResult(result),
    };
}

pub fn render(
    self: *PaneSurface,
    hwnd: win32.HWND,
    pane_id: types.TabId,
    term: *vt.Terminal,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
    remote_session: bool,
    url_highlight: ?types.UrlHighlight,
) void {
    switch (self.backend) {
        inline else => |*backend, tag| {
            const result = backend.render(
                hwnd,
                pane_id,
                term,
                .{ .tabs = &.{}, .new_tab_col = null, .new_tab_hovered = false },
                resizing,
                mouse_in_scrollbar,
                selection_fade,
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
