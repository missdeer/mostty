//! Native Win32 Vulkan renderer.

const VulkanRenderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../config.zig");
const FontService = @import("font_service.zig");
const GlyphIndexCache = @import("glyph_index_cache.zig");
const RendererCommon = @import("renderer_common.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const bg_image = @import("d3d11/background_image.zig");
const cell_buffer = @import("d3d11/cell_buffer.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const gpu = @import("d3d11/gpu.zig");
const grid = @import("d3d11/grid.zig");
const kitty_image_mod = @import("d3d11/kitty_images.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");
const bridge_mod = @import("vulkan/bridge.zig");
const core_mod = @import("vulkan/core.zig");
const shader_assets = @import("shader_assets.zig");

const vk = core_mod.vk;
const CellXY = gpu.CellXY;
const shader = gpu.shader;
const log = std.log.scoped(.vulkan);

pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const scrollbarWidth = gpu.scrollbarWidth;
pub const glyph_handoff: shared.GlyphHandoff = .cpu_pixels;
pub const StartupError = core_mod.StartupError;
pub const startupErrorDescription = core_mod.startupErrorDescription;

pub const RuntimeFailure = struct {
    operation: Operation,
    cause: anyerror,

    pub const Operation = enum {
        frame_generation,
        tab_bar_image,
        tab_bar_upload,
        frame_submission,
        glyph_atlas_upload,
        surface_resources,

        pub fn description(self: Operation) []const u8 {
            return switch (self) {
                .frame_generation => "waiting for an available Vulkan frame",
                .tab_bar_image => "creating the Vulkan tab bar image",
                .tab_bar_upload => "uploading the Vulkan tab bar image",
                .frame_submission => "submitting or presenting a Vulkan frame",
                .glyph_atlas_upload => "uploading a Vulkan glyph atlas slot",
                .surface_resources => "updating Vulkan surface resources",
            };
        }
    };
};

pub const BackgroundImage = struct {
    owner: ?*VulkanRenderer = null,
    image: core_mod.Image = .{},
    src_w: u32 = 0,
    src_h: u32 = 0,

    pub fn loaded(self: BackgroundImage) bool {
        return self.image.loaded();
    }

    pub fn release(self: *BackgroundImage) void {
        if (self.owner) |owner| self.image.release(&owner.core.?);
        self.* = .{};
    }
};

pub const KittyImage = struct {
    owner: *VulkanRenderer,
    image: core_mod.Image,

    pub fn release(self: *KittyImage) void {
        const core = &self.owner.core.?;
        core.waitTimeline(core.timeline, core.timeline_value) catch |err| {
            const idle = core.dp.device_wait_idle(core.device);
            if (idle != vk.VK_SUCCESS and idle != vk.VK_ERROR_DEVICE_LOST) fatal("image retirement", err);
        };
        self.image.release(core);
        self.* = undefined;
    }
};

const PreparedFrame = struct {
    client_w: u32,
    client_h: u32,
    cs: CellXY,
    shader_col: u32,
    tab_bar_h: u32,
    term_pixel_h: u32,
    term_shader_row: u32,
    atlas: gpu.AtlasFrame,
    tex_cell_count: CellXY,
    config: shader.GridConfig,
};

const PresentOutcome = enum { presented, swapchain_recreated, deferred };

const DebugStats = struct {
    rows_uploaded: u64 = 0,
    rows_skipped: u64 = 0,
};

common: *RendererCommon,
parent: ?*VulkanRenderer = null,
frame_pending: bool = false,
chrome_rects: ?[]const win32.RECT = null,
chrome_background: u24 = 0,
chrome_opacity: f32 = 1,
test_fail_present: bool = false,
font_service: *FontService,
configured_gpu: ?[]const u8,
presentation: core_mod.Presentation,
requires_alpha_composition: bool,
core: ?core_mod.Core = null,
bridge: ?bridge_mod.Bridge = null,

shadow_cells: []shader.Cell = &.{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
cache_gen: u32 = 0,
grid_force_full: bool = true,
last_const_snapshot: grid.ConfigSnapshot = .{},
// Signature of the content last painted into the tab-bar image, plus the D2D
// target it came from. Both the CPU band and the Vulkan image survive across
// frames, so a matching signature skips the D2D pass and the image upload.
tabbar_sig: u64 = 0,
tabbar_sig_rt: ?*win32.ID2D1RenderTarget = null,
stats: DebugStats = .{},
diag_rows_uploaded: u64 = 0,
diag_rows_skipped: u64 = 0,

background_image: BackgroundImage = .{},
bg_image_path: []const u8 = &.{},
bg_image_allocator: ?std.mem.Allocator = null,
bg_image_generation: u32 = 0,
bg_image_opacity: f32 = 1.0,
bg_image_position: Config.BackgroundImagePosition = .center,
bg_image_fit: Config.BackgroundImageFit = .contain,
bg_image_repeat: bool = false,
bg_image_req_id: u32 = 0,
kitty_images: kitty_image_mod.Cache(KittyImage) = .{},

atlas: core_mod.Image = .{},
atlas_size: ?CellXY = null,
cells_count: u32 = 0,
tabbar_image: core_mod.Image = .{},
tabbar_size: win32.SIZE = .{ .cx = 0, .cy = 0 },
pending_failure: ?RuntimeFailure = null,

pub fn init(
    common: *RendererCommon,
    font_service: *FontService,
    configured_gpu: ?[]const u8,
    presentation: core_mod.Presentation,
    requires_alpha_composition: bool,
) VulkanRenderer {
    return .{
        .common = common,
        .font_service = font_service,
        .configured_gpu = configured_gpu,
        .presentation = presentation,
        .requires_alpha_composition = requires_alpha_composition,
    };
}

pub fn initSurface(parent: *VulkanRenderer, common: *RendererCommon) VulkanRenderer {
    var result = init(common, parent.font_service, null, parent.presentation, parent.requires_alpha_composition);
    result.parent = parent;
    result.cache_gen = parent.cache_gen;
    return result;
}

pub fn initializeWindow(self: *VulkanRenderer, hwnd: win32.HWND) StartupError!void {
    if (self.core != null) return;
    if (self.parent) |parent| {
        var core = try core_mod.Core.initSurface(&parent.core.?, hwnd, parent.requires_alpha_composition);
        errdefer core.deinit();
        const size = win32.getClientSize(hwnd);
        const bridge = if (self.presentation == .dcomp_bridge) try bridge_mod.Bridge.init(&core, hwnd, @intCast(@max(1, size.cx)), @intCast(@max(1, size.cy)), &parent.bridge.?) else null;
        self.core = core;
        self.bridge = bridge;
        log.info("pane created: id={} device=0x{x} queue=0x{x} mode={s}", .{ self.common.surface_id, @intFromPtr(core.device), @intFromPtr(core.queue), @tagName(self.presentation) });
        if (self.bridge) |bridge_state| log.info("pane bridge: id={} d3d_device=0x{x}", .{ self.common.surface_id, @intFromPtr(bridge_state.presenter.device) });
        return;
    }
    const context: StartupContext = .{ .renderer = self, .hwnd = hwnd };
    try initializeCandidates(context, initializeCandidate);
    const properties = self.core.?.physical_properties;
    self.common.remote_or_software_adapter = properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_CPU or
        properties.deviceType == vk.VK_PHYSICAL_DEVICE_TYPE_VIRTUAL_GPU;
}

const StartupContext = struct {
    renderer: *VulkanRenderer,
    hwnd: win32.HWND,
};

fn initializeCandidate(
    context: StartupContext,
    candidate_index: usize,
    attempt: *core_mod.CandidateAttempt,
) StartupError!void {
    const self = context.renderer;
    var core = try core_mod.Core.init(
        context.hwnd,
        self.configured_gpu,
        self.presentation,
        self.requires_alpha_composition,
        candidate_index,
        attempt,
        shader_assets.vertex.vulkan_spirv,
        shader_assets.pixel.vulkan_spirv,
        shader_assets.image_pixel.vulkan_spirv,
    );
    errdefer core.deinit();
    const bridge = if (self.presentation == .dcomp_bridge) blk: {
        const size = win32.getClientSize(context.hwnd);
        break :blk try bridge_mod.Bridge.init(
            &core,
            context.hwnd,
            @intCast(@max(1, size.cx)),
            @intCast(@max(1, size.cy)),
            null,
        );
    } else null;
    self.core = core;
    self.bridge = bridge;
    if (self.presentation == .dcomp_bridge) {
        log.info("Vulkan DirectComposition bridge device active: {s}", .{attempt.name()});
    }
}

pub fn supportsAlphaComposition(self: *const VulkanRenderer) bool {
    if (self.presentation == .dcomp_bridge) return true;
    return if (self.core) |*core| core.alpha_composition_enabled else false;
}

pub fn setRequiresAlphaComposition(self: *VulkanRenderer, required: bool) void {
    self.requires_alpha_composition = required;
    if (self.core) |*core| core.requires_alpha_composition = required;
}

fn initializeCandidates(context: anytype, comptime attempt_fn: anytype) StartupError!void {
    var candidate_index: usize = 0;
    while (true) {
        var attempt: core_mod.CandidateAttempt = .{};
        attempt_fn(context, candidate_index, &attempt) catch |err| {
            if (attempt.name_len == 0) return err;
            log.warn(
                "Vulkan candidate '{s}' failed complete initialization ({s}): {s}",
                .{ attempt.name(), @errorName(err), startupErrorDescription(err) },
            );
            candidate_index += 1;
            if (candidate_index < attempt.candidate_count) continue;
            return err;
        };
        return;
    }
}

pub fn deinit(self: *VulkanRenderer) void {
    if (self.core) |*core| {
        const idle = core.dp.device_wait_idle(core.device);
        if (idle != vk.VK_SUCCESS and idle != vk.VK_ERROR_DEVICE_LOST) fatal("surface teardown", error.SynchronizationUnavailable);
        self.kitty_images.deinit(std.heap.page_allocator);
        if (self.parent == null) self.background_image.release();
        self.tabbar_image.release(core);
        self.atlas.release(core);
        self.releaseGlyphState();
        if (self.bridge) |*bridge| bridge.deinit(core);
        core.deinit();
    } else {
        self.kitty_images.deinit(std.heap.page_allocator);
        self.releaseGlyphState();
    }
    if (self.bg_image_allocator) |allocator| allocator.free(self.bg_image_path);
    self.* = undefined;
}

fn releaseGlyphState(self: *VulkanRenderer) void {
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};
}

pub fn onFontStateChanged(self: *VulkanRenderer) void {
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
    self.grid_force_full = true;
}

pub fn cellsResize(self: *VulkanRenderer, count: u32) bool {
    if (count == self.cells_count and (count == 0 or self.core.?.frames[0].cells.handle != null)) return false;
    const recreated = self.core.?.ensureCellBuffers(@as(usize, count) * @sizeOf(shader.Cell)) catch |err|
        {
            self.recordFailure(.surface_resources, err);
            return false;
        };
    self.cells_count = count;
    return recreated;
}

pub fn cellsUpload(self: *VulkanRenderer, first_cell: u32, cells: []const shader.Cell) void {
    if (self.pending_failure != null) return;
    const frame = self.core.?.currentFrame();
    const bytes = std.mem.sliceAsBytes(cells);
    const offset = @as(usize, first_cell) * @sizeOf(shader.Cell);
    @memcpy(frame.cells.mapped.?[offset..][0..bytes.len], bytes);
}

pub fn atlasEnsure(self: *VulkanRenderer, tex_pixel: CellXY) bool {
    if (self.atlas_size) |size| if (size.eql(tex_pixel)) return true;
    var core = &self.core.?;
    if (core.dp.device_wait_idle(core.device) != vk.VK_SUCCESS) {
        self.recordFailure(.surface_resources, error.SynchronizationUnavailable);
        return false;
    }
    self.atlas.release(core);
    self.atlas = core.createImage(tex_pixel.x, tex_pixel.y, vk.VK_FORMAT_B8G8R8A8_UNORM) catch |err|
        {
            self.recordFailure(.surface_resources, err);
            return false;
        };
    self.atlas_size = tex_pixel;
    self.atlasClear(.{ .x = 0, .y = 0 });
    return false;
}

pub fn atlasWriteCpu(
    self: *VulkanRenderer,
    dst_coord: CellXY,
    region: CellXY,
    source: [*]const u8,
    source_pitch: u32,
) void {
    if (self.pending_failure != null) return;
    if (!self.atlas.loaded()) return;
    self.core.?.uploadImage(
        &self.atlas,
        dst_coord.x,
        dst_coord.y,
        region.x,
        region.y,
        source,
        source_pitch,
    ) catch |err| self.recordFailure(.glyph_atlas_upload, err);
}

pub fn atlasClear(self: *VulkanRenderer, dst_coord: CellXY) void {
    const cs = self.font_service.cell_size_xy;
    const row_bytes: usize = @as(usize, cs.x) * 4;
    const zeros = std.heap.page_allocator.alloc(u8, row_bytes * cs.y) catch |err|
        fatal("glyph atlas clear", err);
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    self.atlasWriteCpu(dst_coord, cs, zeros.ptr, @intCast(row_bytes));
}

pub fn atlasCopyStaging(
    self: *VulkanRenderer,
    staging: *gpu.StagingTexture.Cached,
    first: ?gpu.AtlasCopy,
    second: ?gpu.AtlasCopy,
) void {
    _ = .{ self, staging, first, second };
    unreachable;
}

pub fn backgroundImageRelease(self: *VulkanRenderer) void {
    self.bg_image_generation +%= 1;
    if (self.parent == null) {
        if (self.core) |*core| if (core.dp.device_wait_idle(core.device) != vk.VK_SUCCESS) {
            self.recordFailure(.surface_resources, error.SynchronizationUnavailable);
            return;
        };
        self.background_image.release();
    }
}

pub fn backgroundImageUpload(self: *VulkanRenderer, decoded: gpu.DecodedBackground) void {
    self.backgroundImageRelease();
    if (self.pending_failure != null) return;
    var core = &self.core.?;
    var image = core.createImage(decoded.w, decoded.h, vk.VK_FORMAT_B8G8R8A8_UNORM) catch |err| {
        self.recordFailure(.surface_resources, err);
        return;
    };
    core.uploadImage(&image, 0, 0, decoded.w, decoded.h, decoded.pixels.ptr, decoded.w * 4) catch |err| {
        image.release(core);
        self.recordFailure(.surface_resources, err);
        return;
    };
    self.background_image = .{ .owner = self, .image = image, .src_w = decoded.w, .src_h = decoded.h };
}

pub fn kittyImageUpload(self: *VulkanRenderer, width: u32, height: u32, rgba: []const u8) ?KittyImage {
    var core = &self.core.?;
    var image = core.createImage(width, height, vk.VK_FORMAT_R8G8B8A8_UNORM) catch return null;
    core.uploadImage(&image, 0, 0, width, height, rgba.ptr, width * 4) catch {
        image.release(core);
        return null;
    };
    return .{ .owner = self, .image = image };
}

/// Park a failure raised outside `render`'s error union so the next frame can
/// hand it to the runtime recovery path. The first cause is the diagnostic one;
/// everything after it is fallout from the same dead device.
fn recordFailure(self: *VulkanRenderer, operation: RuntimeFailure.Operation, cause: anyerror) void {
    if (self.pending_failure == null)
        self.pending_failure = .{ .operation = operation, .cause = cause };
}

fn takeFailure(self: *VulkanRenderer) ?RuntimeFailure {
    defer self.pending_failure = null;
    return self.pending_failure;
}

pub fn render(
    self: *VulkanRenderer,
    hwnd: win32.HWND,
    tab_id: types.TabId,
    term: *vt.Terminal,
    tabbar: types.TabBarDraw,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
    remote_session: bool,
    url_highlight: ?types.UrlHighlight,
) ?RuntimeFailure {
    _ = remote_session;
    self.initializeWindow(hwnd) catch |err| return .{ .operation = .surface_resources, .cause = err };
    if (self.takeFailure()) |failure| return failure;
    const prepared = (self.prepareFrame(hwnd, term, mouse_in_scrollbar) catch |err| return .{
        .operation = .frame_generation,
        .cause = err,
    }) orelse return null;

    if (self.kitty_images.sync(std.heap.page_allocator, self, tab_id, term)) self.grid_force_full = true;
    const build = cell_buffer.buildAndUpload(
        self,
        term,
        prepared.shader_col,
        prepared.term_shader_row,
        prepared.tex_cell_count,
        prepared.atlas,
        resizing,
        selection_fade,
        cursor_text,
        selection_bg,
        selection_fg,
        background_opacity,
        url_highlight,
    );
    self.common.syncBlinkTimer(hwnd, build.has_blink);
    if (self.takeFailure()) |failure| return failure;

    self.prepareTabbar(prepared, tabbar) catch |err| return .{
        .operation = if (err == error.ImageUnavailable) .tab_bar_image else .tab_bar_upload,
        .cause = err,
    };
    const outcome = self.recordAndPresent(hwnd, prepared) catch |err| return .{
        .operation = .frame_submission,
        .cause = err,
    };
    self.grid_force_full = outcome != .presented;
    self.frame_pending = outcome != .presented;
    return null;
}

pub fn syncSurface(self: *VulkanRenderer, parent: *VulkanRenderer) void {
    self.requires_alpha_composition = parent.requires_alpha_composition;
    if (self.core) |*core| core.requires_alpha_composition = parent.requires_alpha_composition;
    if (self.bg_image_generation != parent.bg_image_generation or self.background_image.image.handle != parent.background_image.image.handle) {
        self.background_image = parent.background_image;
        self.bg_image_generation = parent.bg_image_generation;
        self.grid_force_full = true;
    }
    if (self.bg_image_opacity != parent.bg_image_opacity or self.bg_image_position != parent.bg_image_position or self.bg_image_fit != parent.bg_image_fit or self.bg_image_repeat != parent.bg_image_repeat) self.grid_force_full = true;
    self.bg_image_opacity = parent.bg_image_opacity;
    self.bg_image_position = parent.bg_image_position;
    self.bg_image_fit = parent.bg_image_fit;
    self.bg_image_repeat = parent.bg_image_repeat;
}

pub fn renderChrome(self: *VulkanRenderer, hwnd: win32.HWND, term: *vt.Terminal, tabbar: types.TabBarDraw, background: u24, opacity: f32, remote_session: bool, pane_rects: []const win32.RECT) void {
    _ = remote_session;
    self.chrome_rects = pane_rects;
    defer self.chrome_rects = null;
    self.chrome_background = background;
    self.chrome_opacity = opacity;
    if (self.pending_failure != null) return;
    const prepared = (self.prepareFrame(hwnd, term, false) catch |err| {
        self.recordFailure(.frame_generation, err);
        return;
    }) orelse return;
    if (self.pending_failure != null) return;
    self.prepareTabbar(prepared, tabbar) catch |err| {
        self.recordFailure(.tab_bar_upload, err);
        return;
    };
    const outcome = self.recordAndPresent(hwnd, prepared) catch |err| {
        self.recordFailure(.frame_submission, err);
        return;
    };
    self.grid_force_full = outcome != .presented;
    self.frame_pending = outcome != .presented;
}

fn prepareFrame(
    self: *VulkanRenderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    mouse_in_scrollbar: bool,
) StartupError!?PreparedFrame {
    self.frame_pending = false;
    const size = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(size.cx);
    const client_h: u32 = @intCast(size.cy);
    if (client_w == 0 or client_h == 0) return null;
    if (self.parent != null) {
        if (!try self.core.?.frameReady()) {
            self.frame_pending = true;
            return null;
        }
        if (self.bridge) |*bridge| if (!bridge.presenter.frameReady()) {
            self.frame_pending = true;
            return null;
        };
    }
    _ = try self.core.?.beginFrame();

    const cs = self.font_service.cell_size_xy;
    const scrollbar_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_w -| scrollbar_px;
    const shader_col = @divTrunc(grid_w + cs.x - 1, cs.x);
    const tab_bar_h: u32 = @intCast(@max(0, self.common.tab_bar_height));
    const term_pixel_h = client_h -| tab_bar_h;
    const term_shader_row = @divTrunc(term_pixel_h + cs.y - 1, cs.y);
    if (shader_col > cell_buffer.max_shader_col) return null;

    const atlas = glyph_mod.setupGlyphAtlas(self);
    const tex_cell_count = atlas.tex_cell_count;

    var scrollbar: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    const scroll = term.screens.active.pages.scrollbar();
    const show = scroll.total > scroll.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
    if (show) {
        const origin_y: f32 = @floatFromInt(tab_bar_h);
        const window_h: f32 = @floatFromInt(client_h -| tab_bar_h);
        const track_h = @max(20.0, @as(f32, @floatFromInt(scroll.len)) / @as(f32, @floatFromInt(scroll.total)) * window_h);
        const max_offset = scroll.total - scroll.len;
        const track_y = origin_y + @as(f32, @floatFromInt(scroll.offset)) / @as(f32, @floatFromInt(max_offset)) * (window_h - track_h);
        scrollbar = .{ .x = @floatFromInt(grid_w), .y = track_y, .w = @floatFromInt(scrollbar_px), .h = track_h };
    }

    const snapshot: grid.ConfigSnapshot = .{
        .cell_w = cs.x,
        .cell_h = cs.y,
        .col_count = shader_col,
        .row_count = term_shader_row,
        .cells_per_row = tex_cell_count.x,
        .tab_bar_height = tab_bar_h,
        .scrollbar_x = scrollbar.x,
        .scrollbar_y = scrollbar.y,
        .scrollbar_width = scrollbar.w,
        .scrollbar_height = scrollbar.h,
    };
    if (!snapshot.eql(self.last_const_snapshot)) {
        self.grid_force_full = true;
        self.last_const_snapshot = snapshot;
    }

    var config: shader.GridConfig = .{
        .cell_size = .{ cs.x, cs.y },
        .col_count = shader_col,
        .row_count = term_shader_row,
        .scrollbar_y = scrollbar.y,
        .scrollbar_height = scrollbar.h,
        .scrollbar_x = scrollbar.x,
        .scrollbar_width = scrollbar.w,
        .cells_per_row = tex_cell_count.x,
        .tab_bar_height = tab_bar_h,
    };
    if (self.background_image.loaded()) {
        config.bg_image_flags = 1 | @as(u32, if (self.bg_image_repeat) 2 else 0);
        config.bg_image_opacity = self.bg_image_opacity;
        config.bg_image_dest = bg_image.computeDest(
            self,
            @floatFromInt(shader_col * cs.x),
            @floatFromInt(term_shader_row * cs.y),
        );
    }
    return .{
        .client_w = client_w,
        .client_h = client_h,
        .cs = cs,
        .shader_col = shader_col,
        .tab_bar_h = tab_bar_h,
        .term_pixel_h = term_pixel_h,
        .term_shader_row = term_shader_row,
        .atlas = atlas,
        .tex_cell_count = tex_cell_count,
        .config = config,
    };
}

fn prepareTabbar(self: *VulkanRenderer, prepared: PreparedFrame, tabbar: types.TabBarDraw) !void {
    if (prepared.tab_bar_h == 0) return;
    const band = self.font_service.cpuBand(prepared.client_w, prepared.tab_bar_h);
    var core = &self.core.?;
    if (!self.tabbar_image.loaded() or
        self.tabbar_size.cx != @as(i32, @intCast(prepared.client_w)) or
        self.tabbar_size.cy != @as(i32, @intCast(prepared.tab_bar_h)))
    {
        if (core.dp.device_wait_idle(core.device) != vk.VK_SUCCESS) return error.SynchronizationUnavailable;
        self.tabbar_image.release(core);
        self.tabbar_image = core.createImage(prepared.client_w, prepared.tab_bar_h, vk.VK_FORMAT_B8G8R8A8_UNORM) catch
            return error.ImageUnavailable;
        self.tabbar_size = .{ .cx = @intCast(prepared.client_w), .cy = @intCast(prepared.tab_bar_h) };
        // Fresh image contents are undefined; repaint even if the signature
        // happens to repeat (resize A -> B -> A).
        self.tabbar_sig_rt = null;
    }
    const sig = tabbar_paint.signature(tabbar, self.cache_gen, prepared.cs.x, prepared.client_w, prepared.tab_bar_h);
    if (self.tabbar_sig_rt == band.render_target and self.tabbar_sig == sig) return;
    tabbar_paint.paint(
        band.render_target,
        band.brush,
        &self.font_service.dwrite_factory.IDWriteFactory,
        self.font_service.tabbar_text_format,
        self.font_service.dpi,
        self.font_service.tabbar_trimming_sign,
        tabbar,
        prepared.cs.x,
        prepared.tab_bar_h,
    );
    const pixels = band.readPixels();
    try core.uploadImage(
        &self.tabbar_image,
        0,
        0,
        prepared.client_w,
        prepared.tab_bar_h,
        pixels.ptr,
        prepared.client_w * 4,
    );
    self.tabbar_sig = sig;
    self.tabbar_sig_rt = band.render_target;
}

fn recordAndPresent(self: *VulkanRenderer, hwnd: win32.HWND, prepared: PreparedFrame) !PresentOutcome {
    if (self.test_fail_present) {
        self.test_fail_present = false;
        return error.DiagnosticPresentationFailure;
    }
    return switch (self.presentation) {
        .dcomp_bridge => self.recordAndPresentBridge(prepared),
        .native_wsi => self.recordAndPresentNative(hwnd, prepared),
    };
}

fn recordAndPresentNative(self: *VulkanRenderer, hwnd: win32.HWND, prepared: PreparedFrame) !PresentOutcome {
    var core = &self.core.?;
    if (core.swapchain_extent.width != prepared.client_w or core.swapchain_extent.height != prepared.client_h) {
        try core.recreateSwapchain(hwnd);
        self.grid_force_full = true;
    }
    if (core.present_tier == .present_wait_mailbox and core.last_waitable_present_id != 0) {
        const wait_result = core.dp.wait_for_present.?(core.device, core.swapchain, core.last_waitable_present_id, if (self.parent != null) 0 else 100_000_000);
        if (wait_result == vk.VK_ERROR_OUT_OF_DATE_KHR or wait_result == vk.VK_SUBOPTIMAL_KHR) {
            try core.recreateSwapchain(hwnd);
            return .swapchain_recreated;
        }
        if (wait_result == vk.VK_TIMEOUT and self.parent != null) {
            self.frame_pending = true;
            return .deferred;
        }
        if (wait_result != vk.VK_SUCCESS and wait_result != vk.VK_TIMEOUT and wait_result != vk.VK_SUBOPTIMAL_KHR)
            return error.PresentationWaitFailed;
    }

    const frame = core.currentFrame();
    var image_index: u32 = 0;
    var acquire_result = core.dp.acquire_next_image.?(core.device, core.swapchain, if (self.parent != null) 0 else 100_000_000, frame.image_acquired, null, &image_index);
    if (acquire_result == vk.VK_ERROR_OUT_OF_DATE_KHR) {
        try core.recreateSwapchain(hwnd);
        acquire_result = core.dp.acquire_next_image.?(core.device, core.swapchain, if (self.parent != null) 0 else 100_000_000, frame.image_acquired, null, &image_index);
    }
    if (acquire_result == vk.VK_TIMEOUT or acquire_result == vk.VK_NOT_READY) {
        self.frame_pending = true;
        return .deferred;
    }
    if (acquire_result != vk.VK_SUCCESS and acquire_result != vk.VK_SUBOPTIMAL_KHR)
        return error.ImageAcquireFailed;
    core.acquired_frame = core.frame_cursor;
    const render_finished = core.swapchain_render_finished[image_index];

    try self.recordTarget(
        frame.command_buffer,
        core.swapchain_images[image_index],
        core.swapchain_views[image_index],
        core.swapchain_extent,
        core.swapchain_initialized[image_index],
        false,
        prepared,
    );

    const completion = core.timeline_value + 1;
    const wait = vk.VkSemaphoreSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = frame.image_acquired,
        .value = 0,
        .stageMask = core_mod.acquire_stage,
        .deviceIndex = 0,
    };
    const signals = [_]vk.VkSemaphoreSubmitInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = render_finished, .value = 0, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 },
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = core.timeline, .value = completion, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 },
    };
    const command = vk.VkCommandBufferSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = frame.command_buffer,
        .deviceMask = 0,
    };
    const submit = vk.VkSubmitInfo2{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = 1,
        .pWaitSemaphoreInfos = &wait,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command,
        .signalSemaphoreInfoCount = signals.len,
        .pSignalSemaphoreInfos = &signals,
    };
    if (core.dp.queue_submit2(core.queue, 1, &submit, null) != vk.VK_SUCCESS)
        return error.QueueSubmitFailed;
    core.acquired_frame = null;
    core.timeline_value = completion;
    frame.completion_value = completion;

    core.present_id += 1;
    const present_id = vk.VkPresentIdKHR{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_ID_KHR,
        .pNext = null,
        .swapchainCount = 1,
        .pPresentIds = &core.present_id,
    };
    const present = vk.VkPresentInfoKHR{
        .sType = vk.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = if (core.present_wait_enabled) &present_id else null,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &render_finished,
        .swapchainCount = 1,
        .pSwapchains = &core.swapchain,
        .pImageIndices = &image_index,
        .pResults = null,
    };
    const result = core.dp.queue_present.?(core.queue, &present);
    // SUBOPTIMAL still queues a presentation and must be retired as such.
    if (result == vk.VK_SUCCESS or result == vk.VK_SUBOPTIMAL_KHR) {
        if (core.present_wait_enabled) core.last_waitable_present_id = core.present_id;
        core.swapchain_initialized[image_index] = true;
    }
    if (result == vk.VK_ERROR_OUT_OF_DATE_KHR or result == vk.VK_SUBOPTIMAL_KHR) {
        try core.recreateSwapchain(hwnd);
        return .swapchain_recreated;
    } else if (result != vk.VK_SUCCESS) {
        return error.PresentationFailed;
    }
    return .presented;
}

fn recordAndPresentBridge(self: *VulkanRenderer, prepared: PreparedFrame) !PresentOutcome {
    var core = &self.core.?;
    var bridge = &self.bridge.?;
    const resized = try bridge.ensureSize(core, prepared.client_w, prepared.client_h);
    if (resized) self.grid_force_full = true;

    const frame = core.currentFrame();
    const shared_frame = bridge.frame(core.frame_cursor);
    try self.recordTarget(
        frame.command_buffer,
        shared_frame.image.handle,
        shared_frame.image.view,
        .{ .width = prepared.client_w, .height = prepared.client_h },
        shared_frame.initialized,
        true,
        prepared,
    );

    const exchange = bridge.beginExchange();
    const completion = core.timeline_value + 1;
    const external_wait = vk.VkSemaphoreSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO,
        .pNext = null,
        .semaphore = bridge.semaphore,
        .value = exchange.wait_value,
        .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT,
        .deviceIndex = 0,
    };
    const signals = [_]vk.VkSemaphoreSubmitInfo{
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = bridge.semaphore, .value = exchange.ready_value, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 },
        .{ .sType = vk.VK_STRUCTURE_TYPE_SEMAPHORE_SUBMIT_INFO, .pNext = null, .semaphore = core.timeline, .value = completion, .stageMask = vk.VK_PIPELINE_STAGE_2_ALL_COMMANDS_BIT, .deviceIndex = 0 },
    };
    const command = vk.VkCommandBufferSubmitInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
        .pNext = null,
        .commandBuffer = frame.command_buffer,
        .deviceMask = 0,
    };
    const submit = vk.VkSubmitInfo2{
        .sType = vk.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
        .pNext = null,
        .flags = 0,
        .waitSemaphoreInfoCount = if (exchange.wait_value == 0) 0 else 1,
        .pWaitSemaphoreInfos = if (exchange.wait_value == 0) null else &external_wait,
        .commandBufferInfoCount = 1,
        .pCommandBufferInfos = &command,
        .signalSemaphoreInfoCount = signals.len,
        .pSignalSemaphoreInfos = &signals,
    };
    if (core.dp.queue_submit2(core.queue, 1, &submit, null) != vk.VK_SUCCESS)
        return error.QueueSubmitFailed;
    core.timeline_value = completion;
    frame.completion_value = completion;
    shared_frame.initialized = true;
    try bridge.present(shared_frame.view.?, exchange);
    return if (resized) .swapchain_recreated else .presented;
}

fn paneClearRect(rect: win32.RECT, extent: vk.VkExtent2D) ?vk.VkClearRect {
    // Window dimensions can change before the next layout reflow reaches paint.
    const left = std.math.clamp(@as(i64, rect.left), 0, @as(i64, extent.width));
    const top = std.math.clamp(@as(i64, rect.top), 0, @as(i64, extent.height));
    const right = std.math.clamp(@as(i64, rect.right), 0, @as(i64, extent.width));
    const bottom = std.math.clamp(@as(i64, rect.bottom), 0, @as(i64, extent.height));
    if (right <= left or bottom <= top) return null;
    return .{ .rect = .{ .offset = .{ .x = @intCast(left), .y = @intCast(top) }, .extent = .{ .width = @intCast(right - left), .height = @intCast(bottom - top) } }, .baseArrayLayer = 0, .layerCount = 1 };
}

fn recordTarget(
    self: *VulkanRenderer,
    command: vk.VkCommandBuffer,
    image: vk.VkImage,
    view: vk.VkImageView,
    extent: vk.VkExtent2D,
    initialized: bool,
    external: bool,
    prepared: PreparedFrame,
) !void {
    var core = &self.core.?;
    const begin = vk.VkCommandBufferBeginInfo{
        .sType = vk.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = null,
        .flags = vk.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        .pInheritanceInfo = null,
    };
    if (core.dp.begin_command_buffer(command, &begin) != vk.VK_SUCCESS)
        return error.CommandRecordingFailed;

    if (external) {
        core.acquireExternalImage(command, image, initialized);
    } else {
        core.acquirePresentImage(command, image, initialized);
    }

    const clear = vk.VkClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 0 } } };
    const color_attachment = vk.VkRenderingAttachmentInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_ATTACHMENT_INFO,
        .pNext = null,
        .imageView = view,
        .imageLayout = vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .resolveMode = vk.VK_RESOLVE_MODE_NONE,
        .resolveImageView = null,
        .resolveImageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED,
        .loadOp = vk.VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.VK_ATTACHMENT_STORE_OP_STORE,
        .clearValue = clear,
    };
    const rendering = vk.VkRenderingInfo{
        .sType = vk.VK_STRUCTURE_TYPE_RENDERING_INFO,
        .pNext = null,
        .flags = 0,
        .renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent },
        .layerCount = 1,
        .viewMask = 0,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment,
        .pDepthAttachment = null,
        .pStencilAttachment = null,
    };
    core.dp.cmd_begin_rendering(command, &rendering);

    if (self.chrome_rects) |rects| {
        const opacity = self.chrome_opacity;
        const background = self.chrome_background;
        const fill = vk.VkClearAttachment{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue = .{ .color = .{ .float32 = .{
            std.math.pow(f32, @as(f32, @floatFromInt((background >> 16) & 0xff)) / 255, 2.2) * opacity,
            std.math.pow(f32, @as(f32, @floatFromInt((background >> 8) & 0xff)) / 255, 2.2) * opacity,
            std.math.pow(f32, @as(f32, @floatFromInt(background & 0xff)) / 255, 2.2) * opacity,
            opacity,
        } } } };
        const whole = vk.VkClearRect{ .rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent }, .baseArrayLayer = 0, .layerCount = 1 };
        core.dp.cmd_clear_attachments(command, 1, &fill, 1, &whole);
        const transparent = vk.VkClearAttachment{ .aspectMask = vk.VK_IMAGE_ASPECT_COLOR_BIT, .colorAttachment = 0, .clearValue = clear };
        for (rects) |rect| {
            const hole = paneClearRect(rect, extent) orelse continue;
            core.dp.cmd_clear_attachments(command, 1, &transparent, 1, &hole);
        }
    } else {
        try self.drawGrid(command, prepared);
        for (self.kitty_images.placements.items) |placement| {
            if (placement.z < 0) continue;
            const entry = self.kitty_images.images.get(.{
                .tab_id = self.kitty_images.last_tab_id,
                .image_id = placement.image_id,
            }) orelse continue;
            const config: kitty_image_mod.ImageConfig = .{
                .dest = .{
                    @floatFromInt(@as(i64, placement.x) * prepared.cs.x + placement.cell_offset_x),
                    @floatFromInt(@as(i64, placement.y) * prepared.cs.y + placement.cell_offset_y),
                    @floatFromInt(placement.width),
                    @floatFromInt(placement.height),
                },
                .source = .{
                    @floatFromInt(placement.source_x),
                    @floatFromInt(placement.source_y),
                    @floatFromInt(placement.source_width),
                    @floatFromInt(placement.source_height),
                },
                .image_size = .{ @floatFromInt(entry.width), @floatFromInt(entry.height) },
                .tab_bar_height = @floatFromInt(prepared.tab_bar_h),
            };
            try self.drawImage(command, &config, entry.image.image.view, prepared.client_w, prepared.client_h);
        }
    }
    if (prepared.tab_bar_h != 0) {
        const config: kitty_image_mod.ImageConfig = .{
            .dest = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .source = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .image_size = .{ @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .tab_bar_height = 0,
        };
        try self.drawImage(command, &config, self.tabbar_image.view, prepared.client_w, prepared.client_h);
    }

    core.dp.cmd_end_rendering(command);
    if (external) {
        core.releaseExternalImage(command, image);
    } else {
        core.imageBarrier(
            command,
            image,
            vk.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            vk.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
            vk.VK_PIPELINE_STAGE_2_COLOR_ATTACHMENT_OUTPUT_BIT,
            vk.VK_PIPELINE_STAGE_2_BOTTOM_OF_PIPE_BIT,
            vk.VK_ACCESS_2_COLOR_ATTACHMENT_WRITE_BIT,
            0,
        );
    }
    if (core.dp.end_command_buffer(command) != vk.VK_SUCCESS)
        return error.CommandRecordingFailed;
}

fn drawGrid(self: *VulkanRenderer, command: vk.VkCommandBuffer, prepared: PreparedFrame) !void {
    var core = &self.core.?;
    const uniform = try core.writeUniform(std.mem.asBytes(&prepared.config));
    const cells = core.currentFrame().cells;
    const set = try core.allocateDescriptorSet();
    const background_view = if (self.background_image.loaded()) self.background_image.image.view else core.transparent_image.view;
    self.writeGridDescriptors(set, uniform, .{ .buffer = cells.handle, .offset = 0, .range = cells.size }, background_view);
    const viewport = vk.VkViewport{
        .x = 0,
        .y = @floatFromInt(prepared.tab_bar_h),
        .width = @floatFromInt(prepared.client_w),
        .height = @floatFromInt(prepared.term_pixel_h),
        .minDepth = 0,
        .maxDepth = 1,
    };
    const scissor = vk.VkRect2D{
        .offset = .{ .x = 0, .y = @intCast(prepared.tab_bar_h) },
        .extent = .{ .width = prepared.client_w, .height = prepared.term_pixel_h },
    };
    core.dp.cmd_set_viewport(command, 0, 1, &viewport);
    core.dp.cmd_set_scissor(command, 0, 1, &scissor);
    core.dp.cmd_bind_pipeline(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, core.grid_pipeline);
    core.dp.cmd_bind_descriptor_sets(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, core.pipeline_layout, 0, 1, &set, 0, null);
    core.dp.cmd_draw(command, 4, 1, 0, 0);
}

fn drawImage(
    self: *VulkanRenderer,
    command: vk.VkCommandBuffer,
    config: *const kitty_image_mod.ImageConfig,
    image_view: vk.VkImageView,
    width: u32,
    height: u32,
) !void {
    var core = &self.core.?;
    const uniform = try core.writeUniform(std.mem.asBytes(config));
    const set = try core.allocateDescriptorSet();
    const uniform_infos = [_]vk.VkDescriptorBufferInfo{uniform};
    const image_infos = [_]vk.VkDescriptorImageInfo{
        .{ .sampler = null, .imageView = image_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        .{ .sampler = core.sampler, .imageView = null, .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED },
    };
    const writes = [_]vk.VkWriteDescriptorSet{
        descriptorBufferWrite(set, 0, vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, &uniform_infos[0]),
        descriptorImageWrite(set, 4, vk.VK_DESCRIPTOR_TYPE_SAMPLER, &image_infos[1]),
        descriptorImageWrite(set, 5, vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &image_infos[0]),
    };
    core.dp.update_descriptor_sets(core.device, writes.len, &writes, 0, null);
    const viewport = vk.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .minDepth = 0, .maxDepth = 1 };
    const scissor = vk.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = width, .height = height } };
    core.dp.cmd_set_viewport(command, 0, 1, &viewport);
    core.dp.cmd_set_scissor(command, 0, 1, &scissor);
    core.dp.cmd_bind_pipeline(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, core.image_pipeline);
    core.dp.cmd_bind_descriptor_sets(command, vk.VK_PIPELINE_BIND_POINT_GRAPHICS, core.pipeline_layout, 0, 1, &set, 0, null);
    core.dp.cmd_draw(command, 4, 1, 0, 0);
}

fn writeGridDescriptors(
    self: *VulkanRenderer,
    set: vk.VkDescriptorSet,
    uniform: vk.VkDescriptorBufferInfo,
    cells: vk.VkDescriptorBufferInfo,
    background_view: vk.VkImageView,
) void {
    var core = &self.core.?;
    const buffers = [_]vk.VkDescriptorBufferInfo{ uniform, cells };
    const images = [_]vk.VkDescriptorImageInfo{
        .{ .sampler = null, .imageView = self.atlas.view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        .{ .sampler = null, .imageView = background_view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
        .{ .sampler = core.sampler, .imageView = null, .imageLayout = vk.VK_IMAGE_LAYOUT_UNDEFINED },
        .{ .sampler = null, .imageView = core.transparent_image.view, .imageLayout = vk.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL },
    };
    const writes = [_]vk.VkWriteDescriptorSet{
        descriptorBufferWrite(set, 0, vk.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, &buffers[0]),
        descriptorBufferWrite(set, 1, vk.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, &buffers[1]),
        descriptorImageWrite(set, 2, vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &images[0]),
        descriptorImageWrite(set, 3, vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &images[1]),
        descriptorImageWrite(set, 4, vk.VK_DESCRIPTOR_TYPE_SAMPLER, &images[2]),
        descriptorImageWrite(set, 5, vk.VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, &images[3]),
    };
    core.dp.update_descriptor_sets(core.device, writes.len, &writes, 0, null);
}

fn descriptorBufferWrite(
    set: vk.VkDescriptorSet,
    binding: u32,
    descriptor_type: vk.VkDescriptorType,
    info: *const vk.VkDescriptorBufferInfo,
) vk.VkWriteDescriptorSet {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = set,
        .dstBinding = binding,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = descriptor_type,
        .pImageInfo = null,
        .pBufferInfo = info,
        .pTexelBufferView = null,
    };
}

fn descriptorImageWrite(
    set: vk.VkDescriptorSet,
    binding: u32,
    descriptor_type: vk.VkDescriptorType,
    info: *const vk.VkDescriptorImageInfo,
) vk.VkWriteDescriptorSet {
    return .{
        .sType = vk.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,
        .dstSet = set,
        .dstBinding = binding,
        .dstArrayElement = 0,
        .descriptorCount = 1,
        .descriptorType = descriptor_type,
        .pImageInfo = info,
        .pBufferInfo = null,
        .pTexelBufferView = null,
    };
}

pub fn applyGlyphResult(self: *VulkanRenderer, result: *RasterResult) bool {
    if (self.core == null) return false;
    return glyph_mod.applyRasterResult(self, result);
}

pub fn reloadBackgroundImage(
    self: *VulkanRenderer,
    allocator: std.mem.Allocator,
    config: *const Config,
    hwnd: win32.HWND,
) void {
    if (self.core == null) initializeWindow(self, hwnd) catch |err|
        fatal("background image startup", err);
    self.bg_image_allocator = allocator;
    bg_image.reload(self, allocator, config, hwnd);
}

pub fn applyDecodedBackgroundImage(self: *VulkanRenderer, result: *const BgImageDecoded) void {
    if (self.core == null) return;
    bg_image.applyDecoded(self, result);
}

pub fn releaseKittyImagesForTab(self: *VulkanRenderer, tab_id: types.TabId) void {
    self.kitty_images.releaseForTab(std.heap.page_allocator, tab_id);
}

fn fatal(what: []const u8, err: anyerror) noreturn {
    std.debug.panic("Vulkan renderer: {s} failed ({s})", .{ what, @errorName(err) });
}

test "native Vulkan uses the shared shader and CPU glyph contracts" {
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, glyph_handoff);
    inline for (.{ shader_assets.vertex, shader_assets.pixel, shader_assets.image_pixel }) |asset| {
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, asset.vulkan_spirv[0..4]);
    }
}

test "a glyph atlas upload failure reaches the runtime recovery path instead of panicking" {
    var renderer = init(undefined, undefined, null, .dcomp_bridge, false);
    try std.testing.expect(renderer.takeFailure() == null);

    renderer.recordFailure(.glyph_atlas_upload, error.SynchronizationUnavailable);
    renderer.recordFailure(.frame_submission, error.PresentationFailed);

    const failure = renderer.takeFailure().?;
    try std.testing.expectEqual(RuntimeFailure.Operation.glyph_atlas_upload, failure.operation);
    try std.testing.expectEqual(error.SynchronizationUnavailable, failure.cause);
    try std.testing.expect(renderer.takeFailure() == null);
}

test "every Vulkan runtime failure operation can be named in the fallback prompt" {
    inline for (@typeInfo(RuntimeFailure.Operation).@"enum".fields) |field| {
        const operation: RuntimeFailure.Operation = @enumFromInt(field.value);
        try std.testing.expect(operation.description().len > 0);
    }
}

test "native Vulkan remains separate from the DirectComposition bridge" {
    const source = @embedFile("vulkan/core.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "DCompositionCreateDevice") == null);
    try std.testing.expect(std.mem.indexOf(u8, source, "CreateSwapChainForComposition") == null);
}

const FakeCandidateContext = struct {
    candidate_count: usize,
    failures_before_success: usize,
    failure: StartupError = error.DeviceUnavailable,
    always_fail: bool = false,
    attempted: [4]usize = @splat(0),
    attempt_count: usize = 0,
};

fn fakeInitializeCandidate(
    context: *FakeCandidateContext,
    candidate_index: usize,
    attempt: *core_mod.CandidateAttempt,
) StartupError!void {
    const names = [_][]const u8{ "discrete", "integrated", "virtual", "cpu" };
    const name = names[candidate_index];
    attempt.candidate_count = context.candidate_count;
    attempt.name_len = name.len;
    @memcpy(attempt.name_buf[0..name.len], name);
    context.attempted[context.attempt_count] = candidate_index;
    context.attempt_count += 1;
    if (context.always_fail or candidate_index < context.failures_before_success)
        return context.failure;
}

test "Vulkan initialization continues until a later candidate succeeds" {
    var context: FakeCandidateContext = .{
        .candidate_count = 3,
        .failures_before_success = 1,
        .failure = error.RequiredApiVersionUnavailable,
    };
    try initializeCandidates(&context, fakeInitializeCandidate);
    try std.testing.expectEqual(@as(usize, 2), context.attempt_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, context.attempted[0..context.attempt_count]);
}

test "Vulkan initialization reports failure only after every candidate fails" {
    var context: FakeCandidateContext = .{
        .candidate_count = 3,
        .failures_before_success = 0,
        .always_fail = true,
    };
    try std.testing.expectError(error.DeviceUnavailable, initializeCandidates(&context, fakeInitializeCandidate));
    try std.testing.expectEqual(@as(usize, 3), context.attempt_count);
    try std.testing.expectEqualSlices(usize, &.{ 0, 1, 2 }, context.attempted[0..context.attempt_count]);
}

test "Vulkan panes share device pipelines and fonts while owning frames and presentation" {
    const TestWindows = struct {
        fn proc(hwnd: win32.HWND, msg: u32, wp: win32.WPARAM, lp: win32.LPARAM) callconv(.winapi) win32.LRESULT {
            return win32.DefWindowProcW(hwnd, msg, wp, lp);
        }
        fn create(parent: ?win32.HWND, native: bool) !win32.HWND {
            const name = win32.L("MosttyVulkanPaneTest");
            const wc: win32.WNDCLASSEXW = .{ .cbSize = @sizeOf(win32.WNDCLASSEXW), .style = .{}, .lpfnWndProc = proc, .cbClsExtra = 0, .cbWndExtra = 0, .hInstance = win32.GetModuleHandleW(null), .hIcon = null, .hCursor = null, .hbrBackground = null, .lpszMenuName = null, .lpszClassName = name, .hIconSm = null };
            if (win32.RegisterClassExW(&wc) == 0 and win32.GetLastError() != .ERROR_CLASS_ALREADY_EXISTS) return error.TestWindowUnavailable;
            return win32.CreateWindowExW(.{ .NOREDIRECTIONBITMAP = if (native) 0 else 1 }, name, win32.L(""), .{ .CHILD = if (parent != null) 1 else 0 }, 0, 0, 200, 160, parent, null, wc.hInstance, null) orelse error.TestWindowUnavailable;
        }
    };
    inline for (.{ core_mod.Presentation.dcomp_bridge, .native_wsi }) |mode| {
        const hwnd = try TestWindows.create(null, mode == .native_wsi);
        defer _ = win32.DestroyWindow(hwnd);
        const ah = try TestWindows.create(hwnd, mode == .native_wsi);
        defer _ = win32.DestroyWindow(ah);
        const bh = try TestWindows.create(hwnd, mode == .native_wsi);
        defer _ = win32.DestroyWindow(bh);
        var common: RendererCommon = undefined;
        var fonts = FontService.init(&common, 96, .{}, true, null);
        defer fonts.deinit();
        var parent = init(&common, &fonts, null, mode, false);
        defer parent.deinit();
        parent.initializeWindow(hwnd) catch |err| switch (err) {
            error.VulkanLoaderUnavailable,
            error.PhysicalDeviceUnavailable,
            error.RequiredApiVersionUnavailable,
            error.RequiredDeviceExtensionUnavailable,
            error.RequiredFeatureUnavailable,
            error.ExternalMemoryUnavailable,
            error.ExternalSemaphoreUnavailable,
            => {
                log.warn("Vulkan pane GPU test unavailable: {s}", .{@errorName(err)});
                return error.SkipZigTest;
            },
            else => return err,
        };
        var ac = common;
        ac.surface_id = 1;
        ac.tab_bar_height = 0;
        var bc = ac;
        bc.surface_id = 2;
        var a = initSurface(&parent, &ac);
        defer a.deinit();
        var b = initSurface(&parent, &bc);
        defer b.deinit();
        try a.initializeWindow(ah);
        try b.initializeWindow(bh);
        const pa = &a.core.?;
        const pb = &b.core.?;
        try std.testing.expect(pa.device == parent.core.?.device and pb.device == pa.device);
        try std.testing.expect(pa.queue == pb.queue and pa.instance == pb.instance);
        try std.testing.expect(pa.grid_pipeline == pb.grid_pipeline and pa.sampler == parent.core.?.sampler);
        try std.testing.expect(a.font_service == &fonts and b.font_service == &fonts);
        try std.testing.expect(pa.frames[0].command_pool != pb.frames[0].command_pool);
        try std.testing.expect(pa.frames[0].descriptor_pool != pb.frames[0].descriptor_pool);
        try std.testing.expect(pa.timeline != pb.timeline);
        try std.testing.expect(a.cellsResize(4) and b.cellsResize(4));
        try std.testing.expect(pa.frames[0].cells.handle != pb.frames[0].cells.handle);
        var pixels = [_]u8{ 255, 0, 0, 255 };
        const image_a = a.kittyImageUpload(1, 1, &pixels).?;
        var retired_a = image_a;
        defer retired_a.release();
        const image_b = b.kittyImageUpload(1, 1, &pixels).?;
        var retired_b = image_b;
        defer retired_b.release();
        try std.testing.expect(image_a.image.handle != image_b.image.handle);
        try std.testing.expect(pa.uploads.items.len > 0);
        try pa.waitTimeline(pa.timeline, pa.timeline_value);
        _ = try pa.beginFrame();
        try std.testing.expectEqual(@as(usize, 0), pa.uploads.items.len);
        pa.frames[(pa.frame_cursor + 1) % core_mod.frame_count].completion_value = pa.timeline_value + 1;
        try std.testing.expect(!try pa.frameReady());
        try std.testing.expect(try pb.frameReady());
        pa.frames[(pa.frame_cursor + 1) % core_mod.frame_count].completion_value = 0;
        if (mode == .native_wsi) {
            try std.testing.expect(pa.swapchain != pb.swapchain);
            try std.testing.expect(pa.surface != pb.surface);
            try std.testing.expect(pa.swapchain_image_count >= 2);
            try std.testing.expect(pa.swapchain_render_finished[0] != pa.swapchain_render_finished[1]);
            try std.testing.expect(pa.swapchain_render_finished[0] != pb.swapchain_render_finished[0]);
        } else {
            try std.testing.expect(a.bridge.?.presenter.device == parent.bridge.?.presenter.device);
            try std.testing.expect(b.bridge.?.presenter.device == a.bridge.?.presenter.device);
            try std.testing.expect(a.bridge.?.presenter.surface.swap_chain != b.bridge.?.presenter.surface.swap_chain);
        }
    }
}

test "pane clears stay within a resized framebuffer while layout catches up" {
    const extent = vk.VkExtent2D{ .width = 934, .height = 611 };
    const stale = win32.RECT{ .left = 484, .top = 36, .right = 1084, .bottom = 721 };
    const clipped = paneClearRect(stale, extent).?.rect;
    try std.testing.expectEqual(extent.width, @as(u32, @intCast(clipped.offset.x)) + clipped.extent.width);
    try std.testing.expectEqual(extent.height, @as(u32, @intCast(clipped.offset.y)) + clipped.extent.height);
    try std.testing.expect(paneClearRect(.{ .left = 1000, .top = 0, .right = 1100, .bottom = 20 }, extent) == null);
    const negative = paneClearRect(.{ .left = -5, .top = -4, .right = 12, .bottom = 14 }, extent).?.rect;
    try std.testing.expectEqual(@as(i32, 0), negative.offset.x);
    try std.testing.expectEqual(@as(i32, 0), negative.offset.y);
    try std.testing.expectEqual(@as(u32, 12), negative.extent.width);
    try std.testing.expect(paneClearRect(stale, .{ .width = 0, .height = 0 }) == null);
}
