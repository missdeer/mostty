const FontService = @This();

const std = @import("std");
const win32 = @import("win32").everything;

const GlyphIndexCache = @import("glyph_index_cache.zig");
const RendererCommon = @import("renderer_common.zig");
const com = @import("d3d11/com.zig");
const font_mod = @import("d3d11/font.zig");
const font_state = @import("d3d11/font_state.zig");
const glyph_worker_mod = @import("d3d11/glyph_worker.zig");
const gpu = @import("d3d11/gpu.zig");
const swap_chain_mod = @import("d3d11/swap_chain.zig");
const types = @import("types.zig");

pub const FontConfig = font_mod.FontConfig;
pub const RasterResult = glyph_worker_mod.RasterResult;
pub const default_primary_font_family = font_mod.default_primary_font_family;
pub const default_font_size_pt = font_mod.default_font_size_pt;

const log = std.log.scoped(.font_service);

common: *RendererCommon,

// This device is process-lifetime font infrastructure. Renderer backends
// normally create a distinct device, and D2D output crosses that boundary
// through keyed shared textures owned by this service. If the driver refuses
// to create a second D3D11 device, the D3D11 backend may retain this device;
// the same keyed handoff is kept so both cases use one rendering path.
device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
dwrite_factory: *win32.IDWriteFactory2,
d2d_factory: *win32.ID2D1Factory,

text_formats: [4]*win32.IDWriteTextFormat,
font_fallbacks: [4]*win32.IDWriteFontFallback,
emoji_text_format: *win32.IDWriteTextFormat,
emoji_fallback: *win32.IDWriteFontFallback,
rendering_params: *win32.IDWriteRenderingParams,
dpi: u32,
cell_size_xy: gpu.CellXY,

font_size_pt: f32,
font_features: []const FontConfig.FontFeature = &.{},
effective_primary: [*:0]const u16,
effective_style_primaries: [3]?[*:0]const u16,
effective_style_specs: [4]FontConfig.StyleSpec,
effective_style: [4]GlyphIndexCache.Style,
effective_user_fallbacks: []const [*:0]const u16,
effective_emoji_families: []const [*:0]const u16,
effective_codepoint_maps: []const FontConfig.CodepointMapEntry,

tabbar_text_format: *win32.IDWriteTextFormat,
tabbar_fallback: *win32.IDWriteFontFallback,
tabbar_trimming_sign: ?*win32.IDWriteInlineObject,
effective_tabbar_primary: [*:0]const u16,
tabbar_font_size_pt: f32,

staging_texture: gpu.StagingTexture = .{},
band_texture: gpu.BandTexture = .{},

// CPU-addressable output form, for a backend that cannot open the shared
// surfaces above. Created lazily on first use, so a process running only the
// shared-surface backend never allocates any of it and its behaviour is
// untouched by this path existing.
cpu_band: gpu.CpuBandTexture = .{},
wic_factory: ?*win32.IWICImagingFactory = null,
sync_rasterizer: glyph_worker_mod.SyncRasterizer = .{},

glyph_worker: glyph_worker_mod.Worker = undefined,
glyph_worker_started: bool = false,

pub fn init(
    common: *RendererCommon,
    dpi: u32,
    font_config: FontConfig,
    font_ligatures: bool,
    configured_gpu: ?[]const u8,
) FontService {
    const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    const selected_adapter = if (configured_gpu) |name|
        swap_chain_mod.findHardwareAdapterByName(name) orelse
            std.debug.panic("configured GPU '{s}' was not found for the font service", .{name})
    else
        null;
    defer {
        if (selected_adapter) |adapter| _ = adapter.IUnknown.Release();
    }
    {
        const hr = win32.D3D11CreateDevice(
            if (selected_adapter) |adapter| &adapter.IDXGIAdapter else null,
            if (selected_adapter != null) .UNKNOWN else .HARDWARE,
            null,
            .{ .BGRA_SUPPORT = 1, .SINGLETHREADED = 1 },
            &levels,
            levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
        if (hr < 0) {
            if (configured_gpu) |name| std.debug.panic(
                "D3D11CreateDevice failed for font service GPU '{s}', hresult=0x{x}",
                .{ name, @as(u32, @bitCast(hr)) },
            );
            com.fatalHr("D3D11CreateDevice(font service)", hr);
        }
    }

    const adapter_info = swap_chain_mod.detectAdapter(device);
    log.info("font D3D11 device created: adapter='{s}'", .{adapter_info.name[0..adapter_info.name_len]});

    var dwrite_factory: *win32.IDWriteFactory2 = undefined;
    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory2,
            @ptrCast(&dwrite_factory),
        );
        if (hr < 0) com.fatalHr("DWriteCreateFactory(font service)", hr);
    }
    const rendering_params = font_mod.buildRenderingParams(&dwrite_factory.IDWriteFactory);
    const eff = font_state.deriveFromConfig(dwrite_factory, font_config);
    const fmts = font_state.buildFormats(dwrite_factory, dpi, eff);

    var d2d_factory: *win32.ID2D1Factory = undefined;
    {
        const hr = win32.D2D1CreateFactory(
            .SINGLE_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr < 0) com.fatalHr("D2D1CreateFactory(font service)", hr);
    }

    common.* = .{
        .cell_size = fmts.cell_size,
        .tab_bar_height = fmts.tab_bar_height,
        .font_ligatures = font_ligatures,
        .remote_or_software_adapter = false,
    };

    return .{
        .common = common,
        .device = device,
        .context = context,
        .dwrite_factory = dwrite_factory,
        .d2d_factory = d2d_factory,
        .text_formats = fmts.text_formats,
        .font_fallbacks = fmts.font_fallbacks,
        .emoji_text_format = fmts.emoji_format,
        .emoji_fallback = fmts.emoji_fallback,
        .rendering_params = rendering_params,
        .dpi = dpi,
        .cell_size_xy = fmts.cell_size_xy,
        .font_size_pt = eff.font_size_pt,
        .font_features = eff.font_features,
        .effective_primary = eff.primary,
        .effective_style_primaries = eff.style_primaries,
        .effective_style_specs = eff.style_specs,
        .effective_style = eff.style,
        .effective_user_fallbacks = eff.user_fallbacks,
        .effective_emoji_families = eff.emoji_families,
        .effective_codepoint_maps = eff.codepoint_maps,
        .tabbar_text_format = fmts.tabbar_format,
        .tabbar_fallback = fmts.tabbar_fallback,
        .tabbar_trimming_sign = fmts.tabbar_trimming_sign,
        .effective_tabbar_primary = eff.tabbar_primary,
        .tabbar_font_size_pt = eff.tabbar_font_size_pt,
    };
}

/// WIC factory for the CPU-addressable output form. Lazily created because
/// only a backend on the `cpu_pixels` handoff ever needs it.
fn wicFactory(self: *FontService) *win32.IWICImagingFactory {
    if (self.wic_factory) |f| return f;
    var factory: *win32.IWICImagingFactory = undefined;
    const hr = win32.CoCreateInstance(
        &win32.CLSID_WICImagingFactory,
        null,
        win32.CLSCTX_INPROC_SERVER,
        win32.IID_IWICImagingFactory,
        @ptrCast(&factory),
    );
    if (hr < 0) com.fatalHr("CoCreateInstance(WIC, font service)", hr);
    self.wic_factory = factory;
    return factory;
}

/// Tab-bar band rendered into ordinary memory. The returned target carries
/// the same D2D properties as the shared-surface band, so the caller paints
/// it with the identical routine; the bytes come back via `readPixels`.
///
/// The GPU never sees this memory: ownership of it stays here and the
/// consumer's obligation ends when it has copied the bytes out.
pub fn cpuBand(self: *FontService, width: u32, height: u32) *gpu.CpuBandTexture.Cached {
    return self.cpu_band.getOrCreate(self.d2d_factory, self.wicFactory(), width, height);
}

pub fn cellSizeForDpi(self: *FontService, dpi: u32) win32.SIZE {
    if (dpi == self.dpi) return self.common.cell_size;
    return font_mod.measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
}

pub fn tabBarHeightForDpi(self: *FontService, dpi: u32) i32 {
    if (dpi == self.dpi) return self.common.tab_bar_height;
    const cs = self.cellSizeForDpi(dpi);
    return font_state.computeTabBarHeight(self.dwrite_factory, dpi, self.effective_tabbar_primary, self.tabbar_font_size_pt, @intCast(cs.cy));
}

pub fn updateDpi(self: *FontService, dpi: u32) bool {
    if (dpi == self.dpi) return false;
    font_state.rebuildAndAssign(self, dpi, font_state.snapshot(self));
    return true;
}

pub fn updateFont(self: *FontService, font_config: FontConfig) void {
    const eff = font_state.deriveFromConfig(self.dwrite_factory, font_config);
    font_state.rebuildAndAssign(self, self.dpi, eff);
}

pub fn setWorkerHwnd(self: *FontService, gpa: std.mem.Allocator, hwnd: win32.HWND) void {
    self.glyph_worker.start(gpa, self.dwrite_factory) catch |e| {
        log.warn("glyph raster worker spawn failed: {s}; falling back to UI-thread raster", .{@errorName(e)});
        return;
    };
    self.glyph_worker_started = true;
    self.glyph_worker.setHwnd(hwnd);
}

pub const RetainedD3d11Device = struct {
    device: *win32.ID3D11Device,
    context: *win32.ID3D11DeviceContext,
};

pub fn retainD3d11Device(self: *FontService) RetainedD3d11Device {
    _ = self.device.IUnknown.AddRef();
    _ = self.context.IUnknown.AddRef();
    return .{ .device = self.device, .context = self.context };
}

pub fn resetRetainedD3d11Context(self: *FontService) void {
    self.context.ClearState();
    self.context.Flush();
}

pub fn deinit(self: *FontService) void {
    if (self.glyph_worker_started) {
        self.glyph_worker.shutdown();
        drainGlyphReadyQueue(self.glyph_worker.gpa);
    }
    self.staging_texture.release();
    self.band_texture.release();
    self.cpu_band.release();
    self.sync_rasterizer.deinit();
    if (self.wic_factory) |f| _ = f.IUnknown.Release();
    self.wic_factory = null;
    _ = self.d2d_factory.IUnknown.Release();
    font_mod.releaseTextFormatSet(&self.text_formats, &self.font_fallbacks);
    {
        var emoji_fmt: font_mod.EmojiFormat = .{
            .format = self.emoji_text_format,
            .fallback = self.emoji_fallback,
        };
        font_mod.releaseEmojiFormat(&emoji_fmt);
    }
    {
        var tabbar: font_mod.TabBarFormat = .{
            .format = self.tabbar_text_format,
            .fallback = self.tabbar_fallback,
            .trimming_sign = self.tabbar_trimming_sign,
        };
        font_mod.releaseTabBarFormat(&tabbar);
    }
    _ = self.rendering_params.IUnknown.Release();
    _ = self.dwrite_factory.IUnknown.Release();
    self.context.ClearState();
    self.context.Flush();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
    self.* = undefined;
}

fn drainGlyphReadyQueue(gpa: std.mem.Allocator) void {
    var msg: win32.MSG = undefined;
    while (true) {
        const got = win32.PeekMessageW(
            &msg,
            null,
            types.WM_APP_GLYPH_READY,
            types.WM_APP_GLYPH_READY,
            win32.PM_REMOVE,
        );
        if (got == 0) break;
        const result: *RasterResult = @ptrFromInt(@as(usize, @bitCast(msg.lParam)));
        result.deinit(gpa);
    }
}
