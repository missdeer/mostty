const Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../config.zig");
const d3d11 = @import("d3d11.zig");
const gl46 = @import("gl46.zig");
const vulkan = @import("vulkan.zig");
const FontService = @import("font_service.zig");
const types = @import("types.zig");

pub const d3d12 = @import("d3d12.zig");

pub const RendererCommon = @import("renderer_common.zig");
const shared = @import("shared.zig");
const gpu = @import("d3d11/gpu.zig");

pub const BgImageDecoded = d3d11.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const FontConfig = FontService.FontConfig;
pub const D3d11InitError = d3d11.InitError;
/// Pane surfaces borrow process resources and own their mutable drawing state.
pub const PaneSurface = @import("PaneSurface.zig");
pub const scrollbarWidth = d3d11.scrollbarWidth;
pub const default_primary_font_family = FontService.default_primary_font_family;
pub const default_font_size_pt = FontService.default_font_size_pt;

pub fn d3d11InitErrorDescription(err: D3d11InitError) []const u8 {
    return d3d11.initErrorDescription(err);
}

/// Backends are all-or-nothing: every variant here fulfils the whole contract
/// below, because the facade dispatches every method to whichever one is
/// selected and a variant that could only draw part of the picture would be a
/// selectable broken terminal.
pub const RendererBackend = union(enum) {
    d3d11: d3d11,
    /// Verified for static and low-frequency correctness only. Selectable on
    /// request for comparison work, never the default, and not to be
    /// described as fully capable until sustained-load behaviour is settled.
    d3d12: d3d12.Renderer,
    /// OpenGL research path: complete baseline rendering through WGL and
    /// shared SPIR-V, with optional DirectComposition interoperability.
    opengl: gl46,
    vulkan: vulkan,
    @"native-vulkan": vulkan,
};

pub const StartupFallback = struct {
    configured: Config.RendererBackend,
    replacement: Config.RendererBackend = .d3d11,

    pub fn selectedBackend(self: StartupFallback, accepted: bool) ?Config.RendererBackend {
        return if (accepted) self.replacement else null;
    }
};

pub fn recommendStartupFallback(
    backend: Config.RendererBackend,
    startup_failed: bool,
) ?StartupFallback {
    if (!startup_failed or backend == .d3d11) return null;
    return .{ .configured = backend };
}

pub const StartupFailure = union(enum) {
    d3d12: d3d12.Renderer.StartupError,
    opengl: gl46.StartupError,
    vulkan: vulkan.StartupError,
    @"native-vulkan": vulkan.StartupError,

    pub fn description(self: StartupFailure) []const u8 {
        return switch (self) {
            .d3d12 => |err| d3d12.Renderer.startupErrorDescription(err),
            .opengl => |err| gl46.startupErrorDescription(err),
            .vulkan => |err| vulkan.startupErrorDescription(err),
            .@"native-vulkan" => |err| vulkan.startupErrorDescription(err),
        };
    }

    pub fn codeName(self: StartupFailure) []const u8 {
        return switch (self) {
            .d3d12 => |err| @errorName(err),
            .opengl => |err| @errorName(err),
            .vulkan => |err| @errorName(err),
            .@"native-vulkan" => |err| @errorName(err),
        };
    }
};

pub const RuntimeFailure = union(enum) {
    d3d12: d3d12.Renderer.RuntimeFailure,
    vulkan: vulkan.RuntimeFailure,
    @"native-vulkan": vulkan.RuntimeFailure,

    pub fn operationDescription(self: RuntimeFailure) []const u8 {
        return switch (self) {
            .d3d12 => |failure| failure.operation,
            .vulkan => |failure| failure.operation.description(),
            .@"native-vulkan" => |failure| failure.operation.description(),
        };
    }

    pub fn codeName(self: RuntimeFailure) []const u8 {
        return switch (self) {
            .d3d12 => "D3D12RuntimeFailure",
            .vulkan => |failure| @errorName(failure.cause),
            .@"native-vulkan" => |failure| @errorName(failure.cause),
        };
    }

    pub fn backendName(self: RuntimeFailure) []const u8 {
        return @tagName(self);
    }
};

common: RendererCommon,
font_service: FontService,
configured_backend: Config.RendererBackend,
backend: ?RendererBackend,
vulkan_recovery_attempted: bool,
d3d12_recovery_attempted: bool = false,
requires_alpha_composition: bool,

// Initialize in place: the backend borrows `common`, and the async glyph
// worker later borrows backend state. The process-global renderer provides
// the stable address required by both relationships.
pub fn init(
    self: *Renderer,
    dpi: u32,
    font_config: FontConfig,
    font_ligatures: bool,
    configured_gpu: ?[]const u8,
    backend: Config.RendererBackend,
    requires_alpha_composition: bool,
) d3d11.InitError!void {
    // The font service and the backend resolve the adapter from the same
    // configured name, which is what keeps them on one GPU. Splitting them
    // across adapters would leave rasterization and compositing on different
    // hardware and the visual-equivalence baseline would stop being single.
    self.font_service = FontService.init(
        &self.common,
        dpi,
        font_config,
        font_ligatures,
        configured_gpu,
    );
    self.configured_backend = backend;
    self.vulkan_recovery_attempted = false;
    self.d3d12_recovery_attempted = false;
    self.requires_alpha_composition = requires_alpha_composition;
    self.backend = switch (backend) {
        .d3d11 => .{ .d3d11 = try d3d11.init(&self.common, &self.font_service, configured_gpu) },
        .d3d12 => null,
        .opengl => .{
            .opengl = gl46.init(&self.common, &self.font_service, configured_gpu, .interop),
        },
        .@"pure-opengl" => .{
            .opengl = gl46.init(&self.common, &self.font_service, configured_gpu, .pure_wgl),
        },
        .vulkan => null,
        .@"native-vulkan" => null,
    };
}

test "research backend startup failure offers an explicit D3D11 fallback" {
    const fallback = recommendStartupFallback(.opengl, true).?;
    try std.testing.expectEqual(Config.RendererBackend.opengl, fallback.configured);
    try std.testing.expectEqual(
        Config.RendererBackend.d3d11,
        fallback.selectedBackend(true).?,
    );
    try std.testing.expectEqual(@as(?Config.RendererBackend, null), fallback.selectedBackend(false));
    try std.testing.expectEqual(Config.RendererBackend.d3d11, recommendStartupFallback(.d3d12, true).?.replacement);
}

test "successful startup and D3D11 failure do not offer a fallback" {
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.opengl, false));
    try std.testing.expectEqual(@as(?StartupFallback, null), recommendStartupFallback(.d3d11, true));
}

test "pure-opengl startup failure retains its configured identity" {
    const fallback = recommendStartupFallback(.@"pure-opengl", true).?;
    try std.testing.expectEqual(Config.RendererBackend.@"pure-opengl", fallback.configured);
    try std.testing.expectEqual(Config.RendererBackend.d3d11, fallback.replacement);
}

test "native Vulkan startup failure only offers explicit D3D11" {
    const fallback = recommendStartupFallback(.@"native-vulkan", true).?;
    try std.testing.expectEqual(Config.RendererBackend.@"native-vulkan", fallback.configured);
    try std.testing.expectEqual(Config.RendererBackend.d3d11, fallback.selectedBackend(true).?);
    try std.testing.expectEqual(@as(?Config.RendererBackend, null), fallback.selectedBackend(false));
}

test "Vulkan bridge startup failure never selects native Vulkan" {
    const fallback = recommendStartupFallback(.vulkan, true).?;
    try std.testing.expectEqual(Config.RendererBackend.vulkan, fallback.configured);
    try std.testing.expectEqual(Config.RendererBackend.d3d11, fallback.selectedBackend(true).?);
    try std.testing.expect(fallback.selectedBackend(true).? != .@"native-vulkan");
}

test "failed D3D11 fallback is returned without leaving a stale backend" {
    const FailingInit = struct {
        fn run(_: *RendererCommon, _: *FontService, _: ?[]const u8) d3d11.InitError!d3d11 {
            return error.DeviceUnavailable;
        }
    };

    var renderer: Renderer = undefined;
    renderer.backend = null;
    renderer.configured_backend = .vulkan;
    renderer.vulkan_recovery_attempted = true;

    try std.testing.expectError(
        error.DeviceUnavailable,
        renderer.fallbackToD3d11With(null, FailingInit.run),
    );
    try std.testing.expect(renderer.backend == null);
    try std.testing.expectEqual(Config.RendererBackend.d3d11, renderer.configured_backend);
    try std.testing.expect(!renderer.vulkan_recovery_attempted);
}

test "backend-dependent facade calls are ignored while no backend exists" {
    var renderer: Renderer = undefined;
    renderer.backend = null;

    renderer.onFontStateChanged();
    renderer.reloadBackgroundImage(std.testing.allocator, undefined, undefined);
    renderer.applyDecodedBackgroundImage(undefined);
    renderer.releaseKittyImagesForTab(0);
    try std.testing.expect(!renderer.applyGlyphResult(undefined));
}

test "native Vulkan runtime failure retains operation and cause" {
    const failure: RuntimeFailure = .{ .@"native-vulkan" = .{
        .operation = .frame_submission,
        .cause = error.PresentationFailed,
    } };
    try std.testing.expectEqualStrings("submitting or presenting a Vulkan frame", failure.operationDescription());
    try std.testing.expectEqualStrings("PresentationFailed", failure.codeName());
}

test "startup failure retains its backend-specific reason" {
    const failure: StartupFailure = .{ .opengl = error.VersionTooOld };
    try std.testing.expectEqualStrings("VersionTooOld", failure.codeName());
    try std.testing.expectEqualStrings(
        "the driver exposed an OpenGL version older than 4.6",
        failure.description(),
    );
    const d3d12_failure: StartupFailure = .{ .d3d12 = error.DeviceUnavailable };
    try std.testing.expectEqualStrings("DeviceUnavailable", d3d12_failure.codeName());
    try std.testing.expectEqualStrings(
        "no D3D12 device supports feature level 11_0",
        d3d12_failure.description(),
    );
}

pub fn initializeWindow(
    self: *Renderer,
    hwnd: win32.HWND,
    configured_gpu: ?[]const u8,
) ?StartupFailure {
    if (self.backend == null) {
        switch (self.configured_backend) {
            .d3d12 => {
                var backend = d3d12.Renderer.init(
                    &self.common,
                    &self.font_service,
                    configured_gpu,
                ) catch |err| return .{ .d3d12 = err };
                backend.initializeWindow(hwnd) catch |err| {
                    backend.deinit();
                    return .{ .d3d12 = err };
                };
                self.backend = .{ .d3d12 = backend };
            },
            .@"native-vulkan" => {
                var backend = vulkan.init(
                    &self.common,
                    &self.font_service,
                    configured_gpu,
                    .native_wsi,
                    self.requires_alpha_composition,
                );
                backend.initializeWindow(hwnd) catch |err| {
                    backend.deinit();
                    return .{ .@"native-vulkan" = err };
                };
                self.backend = .{ .@"native-vulkan" = backend };
            },
            .vulkan => {
                var backend = vulkan.init(
                    &self.common,
                    &self.font_service,
                    configured_gpu,
                    .dcomp_bridge,
                    self.requires_alpha_composition,
                );
                backend.initializeWindow(hwnd) catch |err| {
                    backend.deinit();
                    return .{ .vulkan = err };
                };
                self.backend = .{ .vulkan = backend };
            },
            else => unreachable,
        }
        return null;
    }
    return switch (self.backend.?) {
        .opengl => |*backend| blk: {
            backend.initializeWindow(hwnd) catch |err| break :blk .{ .opengl = err };
            break :blk null;
        },
        else => null,
    };
}

pub fn fallbackToD3d11(self: *Renderer, configured_gpu: ?[]const u8) d3d11.InitError!void {
    return self.fallbackToD3d11With(configured_gpu, d3d11.init);
}

fn fallbackToD3d11With(
    self: *Renderer,
    configured_gpu: ?[]const u8,
    comptime init_fn: anytype,
) d3d11.InitError!void {
    if (self.backend) |*active| switch (active.*) {
        .d3d11 => return,
        inline else => |*backend| backend.deinit(),
    };
    self.backend = null;
    self.configured_backend = .d3d11;
    self.vulkan_recovery_attempted = false;
    self.d3d12_recovery_attempted = false;
    self.requires_alpha_composition = false;
    const replacement = try init_fn(&self.common, &self.font_service, configured_gpu);
    self.backend = .{ .d3d11 = replacement };
}

pub fn reportD3d11Unavailable(hwnd: ?win32.HWND, err: D3d11InitError) void {
    var message_buf: [512]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "Mostty could not initialize its D3D11 renderer ({s}).\n\n" ++
            "There is no usable renderer left, so Mostty will exit.",
        .{@errorName(err)},
    ) catch "Mostty could not initialize its D3D11 renderer. Mostty will exit.";
    _ = win32.MessageBoxA(
        hwnd,
        message,
        "Mostty Renderer Unavailable",
        .{ .ICONHAND = 1 },
    );
}

pub fn recoverVulkan(self: *Renderer, hwnd: win32.HWND, configured_gpu: ?[]const u8) bool {
    if (self.vulkan_recovery_attempted) return false;
    const active = if (self.backend) |*backend| backend else return false;
    switch (active.*) {
        .vulkan => |*backend| backend.deinit(),
        .@"native-vulkan" => |*backend| backend.deinit(),
        else => return false,
    }
    self.backend = null;
    self.vulkan_recovery_attempted = true;
    if (self.initializeWindow(hwnd, configured_gpu)) |failure| {
        std.log.err(
            "renderer: {s} runtime recovery failed ({s}): {s}",
            .{ @tagName(self.configured_backend), failure.codeName(), failure.description() },
        );
        return false;
    }
    return true;
}

fn activeBackend(self: *Renderer) *RendererBackend {
    return if (self.backend) |*backend| backend else @panic("renderer backend used before its startup capability gate");
}

fn deinitBackend(self: *Renderer) void {
    if (self.backend) |*active| switch (active.*) {
        inline else => |*backend| backend.deinit(),
    };
}

pub fn paneRuntimeFailure(self: *Renderer) ?RuntimeFailure {
    const active = if (self.backend) |*backend| backend else return null;
    switch (active.*) {
        .d3d12 => |*backend| {
            _ = backend.healthy();
            if (backend.failure) |failure| return .{ .d3d12 = failure };
        },
        else => {},
    }
    return null;
}

// All borrowing pane surfaces must be released before rebuilding the device.
pub fn recoverD3d12(self: *Renderer, hwnd: win32.HWND, configured_gpu: ?[]const u8, generation: u32) bool {
    if (self.d3d12_recovery_attempted) return false;
    self.d3d12_recovery_attempted = true;
    const parent = &self.backend.?.d3d12;
    const background_generation = parent.bg_image_req_id +% 1;
    parent.deinit();
    self.backend = null;
    if (self.initializeWindow(hwnd, configured_gpu)) |failure| {
        std.log.err("D3D12 recovery initialization failed: {s}", .{failure.description()});
        return false;
    }
    self.backend.?.d3d12.cache_gen = generation;
    self.backend.?.d3d12.bg_image_req_id = background_generation;
    return true;
}

pub fn supportsPanes(self: *const Renderer) bool {
    return if (self.backend) |backend| (backend == .d3d11 or backend == .d3d12) else false;
}

pub fn initPaneSurface(self: *Renderer, common: *RendererCommon) d3d12.Renderer.StartupError!?PaneSurface {
    return PaneSurface.init(self, common);
}

pub fn renderChrome(self: *Renderer, hwnd: win32.HWND, term: *vt.Terminal, tabbar: types.TabBarDraw, background: u24, opacity: f32, remote_session: bool, pane_rects: []const win32.RECT) void {
    switch (self.activeBackend().*) {
        inline .d3d11, .d3d12 => |*backend| backend.renderChrome(hwnd, term, tabbar, background, opacity, remote_session, pane_rects),
        else => unreachable, // Only reached after the pane capability gate.
    }
}

pub fn cellSizeForDpi(self: *Renderer, dpi: u32) win32.SIZE {
    return self.font_service.cellSizeForDpi(dpi);
}

pub fn tabBarHeightForDpi(self: *Renderer, dpi: u32) i32 {
    return self.font_service.tabBarHeightForDpi(dpi);
}

pub fn updateDpi(self: *Renderer, dpi: u32) void {
    if (self.font_service.updateDpi(dpi)) {
        self.onFontStateChanged();
    }
}

pub fn updateFont(self: *Renderer, font_config: FontConfig) void {
    self.font_service.updateFont(font_config);
    self.onFontStateChanged();
}

pub fn applyWindowEffects(self: *Renderer, requires_alpha_composition: bool) bool {
    const supported = if (!requires_alpha_composition) true else switch (self.configured_backend) {
        .@"native-vulkan" => switch (self.activeBackend().*) {
            .@"native-vulkan" => |*backend| backend.supportsAlphaComposition(),
            else => false,
        },
        else => true,
    };
    if (!supported) return false;

    self.requires_alpha_composition = requires_alpha_composition;
    if (self.backend) |*active| switch (active.*) {
        .@"native-vulkan" => |*backend| backend.setRequiresAlphaComposition(requires_alpha_composition),
        else => {},
    };
    return true;
}

fn onFontStateChanged(self: *Renderer) void {
    const active = if (self.backend) |*backend| backend else return;
    switch (active.*) {
        inline else => |*backend| backend.onFontStateChanged(),
    }
}

pub fn deinit(self: *Renderer) void {
    self.deinitBackend();
    self.font_service.deinit();
    self.* = undefined;
}

pub fn render(
    self: *Renderer,
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
    return switch (self.activeBackend().*) {
        .vulkan => |*backend| blk: {
            if (backend.render(
                hwnd,
                tab_id,
                term,
                tabbar,
                resizing,
                mouse_in_scrollbar,
                selection_fade,
                cursor_text,
                selection_bg,
                selection_fg,
                background_opacity,
                remote_session,
                url_highlight,
            )) |failure| break :blk .{ .vulkan = failure };
            self.vulkan_recovery_attempted = false;
            break :blk null;
        },
        .@"native-vulkan" => |*backend| blk: {
            if (backend.render(
                hwnd,
                tab_id,
                term,
                tabbar,
                resizing,
                mouse_in_scrollbar,
                selection_fade,
                cursor_text,
                selection_bg,
                selection_fg,
                background_opacity,
                remote_session,
                url_highlight,
            )) |failure| break :blk .{ .@"native-vulkan" = failure };
            self.vulkan_recovery_attempted = false;
            break :blk null;
        },
        inline else => |*backend| blk: {
            backend.render(
                hwnd,
                tab_id,
                term,
                tabbar,
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
            break :blk null;
        },
    };
}

pub fn confirmRuntimeFallback(hwnd: win32.HWND, failure: RuntimeFailure) bool {
    var message_buf: [768]u8 = undefined;
    const message = std.fmt.bufPrintZ(
        &message_buf,
        "The configured renderer ({s}) encountered an unrecoverable runtime failure while {s}.\n\n" ++
            "{s}.\n\nUse D3D11 for this session instead?\n\n" ++
            "Choose Yes to continue with D3D11, or No to exit Mostty.",
        .{ failure.backendName(), failure.operationDescription(), failure.codeName() },
    ) catch unreachable;
    return win32.MessageBoxA(
        hwnd,
        message,
        "Mostty Renderer Fallback",
        .{ .YESNO = 1, .ICONHAND = 1, .ICONQUESTION = 1, .DEFBUTTON2 = 1 },
    ) == win32.IDYES;
}

pub fn setWorkerHwnd(self: *Renderer, gpa: std.mem.Allocator, hwnd: win32.HWND) void {
    self.font_service.setWorkerHwnd(gpa, hwnd);
}

pub fn applyGlyphResult(self: *Renderer, result: *RasterResult) bool {
    // A failed recoverVulkan leaves no backend while the fallback prompt pumps
    // the queue, and the raster worker keeps posting results into it.
    const active = if (self.backend) |*backend| backend else return false;
    return switch (active.*) {
        inline else => |*backend| backend.applyGlyphResult(result),
    };
}

pub fn reloadBackgroundImage(
    self: *Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    const active = if (self.backend) |*backend| backend else return;
    switch (active.*) {
        inline else => |*backend| backend.reloadBackgroundImage(gpa, cfg, hwnd),
    }
}

pub fn applyDecodedBackgroundImage(self: *Renderer, result: *const BgImageDecoded) void {
    const active = if (self.backend) |*backend| backend else return;
    switch (active.*) {
        inline else => |*backend| backend.applyDecodedBackgroundImage(result),
    }
}

pub fn releaseKittyImagesForTab(self: *Renderer, tab_id: types.TabId) void {
    if (self.backend == null) return;
    switch (self.activeBackend().*) {
        inline else => |*backend| backend.releaseKittyImagesForTab(tab_id),
    }
}

test "every selectable backend answers the whole facade contract" {
    // The facade dispatches each of these to whichever variant is selected,
    // so a variant missing any one of them would be a selectable terminal
    // that cannot draw part of its picture. Fulfilling the contract is what
    // earns selectability, so assert it of every variant rather than trusting
    // that the union was extended carefully.
    const contract = .{
        "init",                        "deinit",
        "render",                      "onFontStateChanged",
        "applyGlyphResult",            "reloadBackgroundImage",
        "applyDecodedBackgroundImage", "releaseKittyImagesForTab",
    };
    inline for (@typeInfo(RendererBackend).@"union".fields) |field| {
        inline for (contract) |name| {
            try std.testing.expect(@hasDecl(field.type, name));
        }
    }
}

test "d3d11 stays the default so an untouched install is unaffected" {
    // D3D12 is verified only for static and low-frequency correctness; it may
    // be asked for, but it must never become what a user gets by default.
    try std.testing.expectEqual(Config.RendererBackend.d3d11, (Config{}).renderer);
    try std.testing.expectEqualStrings(
        "d3d11",
        @typeInfo(RendererBackend).@"union".fields[0].name,
    );
}

test "all backends consume one rasterizer, differing only in handoff form" {
    // Text coverage compositing is judged against d3d11, and that comparison
    // only means anything while both backends render from the same glyph
    // source. Differing handoff form is expected; a second rasterizer is not.
    try std.testing.expectEqual(shared.GlyphHandoff.shared_surface, d3d11.glyph_handoff);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, d3d12.Renderer.glyph_handoff);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, gl46.glyph_handoff);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, vulkan.glyph_handoff);
    inline for (@typeInfo(RendererBackend).@"union".fields) |field| {
        // Neither backend may own font machinery; it belongs to the service.
        inline for (.{ "dwrite_factory", "d2d_factory", "text_formats" }) |owned_by_service| {
            try std.testing.expect(!@hasField(field.type, owned_by_service));
        }
    }
}

test "a wide glyph's two halves are copied under one surface acquisition" {
    // The font-service handoff alternates keys, so acquiring twice without an
    // intervening write blocks the UI thread forever. Taking both halves in
    // one call is what makes that impossible; a signature accepting a single
    // region would invite the caller to loop and deadlock instead.
    const params = @typeInfo(@TypeOf(d3d11.atlasCopyStaging)).@"fn".params;
    try std.testing.expectEqual(@as(usize, 4), params.len);
    try std.testing.expectEqual(?gpu.AtlasCopy, params[2].type.?);
    try std.testing.expectEqual(?gpu.AtlasCopy, params[3].type.?);
}

test "backend does not duplicate renderer common state" {
    inline for (.{ "cell_size", "tab_bar_height", "font_ligatures", "remote_or_software_adapter" }) |field_name| {
        try std.testing.expect(@hasField(RendererCommon, field_name));
        try std.testing.expect(!@hasField(d3d11, field_name));
    }
    try std.testing.expect(@hasField(d3d11, "common"));
}

test "font service owns font and raster lifecycle outside the backend" {
    try std.testing.expect(@hasField(Renderer, "font_service"));
    try std.testing.expect(@hasField(FontService, "device"));
    try std.testing.expect(@hasField(FontService, "glyph_worker"));
    try std.testing.expect(@hasField(d3d11, "font_service"));
    inline for (.{ "dwrite_factory", "d2d_factory", "text_formats", "glyph_worker", "staging_texture" }) |field_name| {
        try std.testing.expect(@hasField(FontService, field_name));
        try std.testing.expect(!@hasField(d3d11, field_name));
    }
}

test "pane capability rejects unsupported or unavailable backends without changing selection" {
    var renderer: Renderer = undefined;
    renderer.backend = null;
    try std.testing.expect(!renderer.supportsPanes());
    try std.testing.expect((try renderer.initPaneSurface(undefined)) == null);
    inline for (.{ Config.RendererBackend.opengl, .@"pure-opengl", .vulkan, .@"native-vulkan" }) |selected| {
        renderer.configured_backend = selected;
        renderer.backend = switch (selected) {
            .d3d12 => .{ .d3d12 = undefined },
            .opengl, .@"pure-opengl" => .{ .opengl = undefined },
            .vulkan => .{ .vulkan = undefined },
            .@"native-vulkan" => .{ .@"native-vulkan" = undefined },
            else => unreachable,
        };
        try std.testing.expect(!renderer.supportsPanes());
        try std.testing.expect((try renderer.initPaneSurface(undefined)) == null);
        try std.testing.expectEqual(selected, renderer.configured_backend);
    }
}

test "pane facade retains shared infrastructure but isolates caches and update generations" {
    var renderer: Renderer = undefined;
    renderer.d3d12_recovery_attempted = true;
    try renderer.init(96, .{}, true, null, .d3d11, false);
    defer renderer.deinit();
    try std.testing.expect(!renderer.d3d12_recovery_attempted);
    try std.testing.expect(renderer.supportsPanes());
    var first_common = renderer.common;
    first_common.surface_id = 1;
    first_common.tab_bar_height = 0;
    var second_common = first_common;
    second_common.surface_id = 2;
    var first = (try renderer.initPaneSurface(&first_common)).?;
    defer first.deinit();
    var second = (try renderer.initPaneSurface(&second_common)).?;
    defer second.deinit();
    const parent = &renderer.backend.?.d3d11;
    const a = &first.backend.d3d11;
    const b = &second.backend.d3d11;
    try std.testing.expect(a.device == parent.device and b.device == parent.device);
    try std.testing.expect(a.context == parent.context and b.context == parent.context);
    try std.testing.expect(a.font_service == &renderer.font_service and b.font_service == &renderer.font_service);
    try std.testing.expect(a.vertex_shader == parent.vertex_shader and b.vertex_shader == parent.vertex_shader);
    try std.testing.expect(a.common == &first_common and b.common == &second_common);
    try std.testing.expect(a.cellsResize(4) and b.cellsResize(4));
    try std.testing.expect(a.shader_cells.cell_buf != b.shader_cells.cell_buf);
    _ = a.atlasEnsure(.{ .x = 32, .y = 32 });
    _ = b.atlasEnsure(.{ .x = 32, .y = 32 });
    try std.testing.expect(a.glyph_texture.obj != null and b.glyph_texture.obj != null);
    try std.testing.expect(a.glyph_texture.obj != b.glyph_texture.obj);

    const Cache = @import("GlyphIndexCache.zig");
    a.glyph_cache = try Cache.init(a.glyph_cache_arena.allocator(), 2);
    b.glyph_cache = try Cache.init(b.glyph_cache_arena.allocator(), 2);
    const key: Cache.Key = .init('x', &.{}, .single, .regular);
    const reserved = (try a.glyph_cache.?.reserve(a.glyph_cache_arena.allocator(), key)).newly_reserved_pending;
    _ = try b.glyph_cache.?.reserve(b.glyph_cache_arena.allocator(), key);
    var result: RasterResult = .{
        .surface_id = first_common.surface_id,
        .slot = reserved.index,
        .slot_gen = reserved.slot_gen,
        .cache_gen = a.cache_gen,
        .key = key,
        .bytes = &.{},
        .w = 0,
        .h = 0,
        .is_color = false,
        .failed = true,
    };
    try std.testing.expect(!second.applyGlyphResult(&result));
    try std.testing.expect((try b.glyph_cache.?.reserve(b.glyph_cache_arena.allocator(), key)) == .already_pending);
    try std.testing.expect(first.applyGlyphResult(&result));

    renderer.updateDpi(144);
    first.sync(&renderer, true);
    try std.testing.expect(a.glyph_cache == null);
    try std.testing.expect(b.glyph_cache != null); // A hidden pane invalidates when synchronized.
    try std.testing.expect(!first.applyGlyphResult(&result));
    second.sync(&renderer, false);
    try std.testing.expect(b.glyph_cache == null);
    try std.testing.expect(first_common.focused and !second_common.focused);
    try std.testing.expectEqual(renderer.common.cell_size.cx, first_common.cell_size.cx);
    try std.testing.expectEqual(renderer.common.cell_size.cy, second_common.cell_size.cy);
    try std.testing.expectEqual(@as(i32, 0), first_common.tab_bar_height);
    try std.testing.expectEqual(@as(u32, 2), second_common.surface_id);
    const generation = a.cache_gen;
    first.sync(&renderer, true);
    try std.testing.expectEqual(generation, a.cache_gen); // Unchanged fonts must not cancel pending work.

    var pixels = [_]u8{ 0, 64, 128, 255 };
    var decoded: BgImageDecoded = .{ .req_id = parent.bg_image_req_id, .path = @constCast("pane-test"), .pixels = &pixels, .w = 1, .h = 1 };
    renderer.applyDecodedBackgroundImage(&decoded);
    try std.testing.expect(parent.background_image.loaded());
    first.sync(&renderer, true);
    second.sync(&renderer, false);
    const retained = a.background_image.texture.?;
    try std.testing.expect(b.background_image.texture == retained);
    a.grid_force_full = false;
    first.sync(&renderer, true);
    try std.testing.expect(!a.grid_force_full);
    parent.bg_image_opacity = 0.5;
    first.sync(&renderer, true);
    try std.testing.expect(a.grid_force_full);
    try std.testing.expectEqual(@as(f32, 0.5), a.bg_image_opacity);
    decoded.pixels = null;
    renderer.applyDecodedBackgroundImage(&decoded);
    try std.testing.expect(!parent.background_image.loaded());
    try std.testing.expect(a.background_image.texture == retained); // Pane retains its own COM reference.
    first.sync(&renderer, true);
    try std.testing.expect(!a.background_image.loaded());
    try std.testing.expect(b.background_image.texture == retained);
    second.sync(&renderer, false);
    try std.testing.expect(!b.background_image.loaded());
}
