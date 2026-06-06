const D3d11Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphIndexCache = @import("GlyphIndexCache.zig");
const types = @import("types.zig");

const com = @import("d3d11/com.zig");
const gpu = @import("d3d11/gpu.zig");
const color = @import("d3d11/color.zig");
const emoji = @import("d3d11/emoji.zig");
const font_mod = @import("d3d11/font.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");

const log = std.log.scoped(.d3d);

// Re-exports for external callers (state/render/tab_bar/tab_mgmt depend on
// these). New code inside the renderer should prefer the module-qualified
// names (`font_mod.FontConfig`, etc.).
pub const FontConfig = font_mod.FontConfig;
pub const scrollbarWidth = gpu.scrollbarWidth;
pub const default_primary_font_family = font_mod.default_primary_font_family;
pub const default_font_size_pt = font_mod.default_font_size_pt;

const Rgba8 = gpu.Rgba8;
const CellXY = gpu.CellXY;
const shader = gpu.shader;
const ShaderCells = gpu.ShaderCells;
const GlyphTexture = gpu.GlyphTexture;
const StagingTexture = gpu.StagingTexture;
const fatalHr = com.fatalHr;
const oom = com.oom;

// Debug-only counters for the row-upload diff. Used to evaluate whether
// merging contiguous dirty rows into a single UpdateSubresource would pay
// off — see uploadCellRow.
//
// rows_uploaded counts UpdateSubresource CALLS (i.e. the diff-vs-shadow
// returned not-equal OR force_full was set). It is NOT the count of
// "rows whose content actually changed": resize/recreate/scroll force_full
// passes can re-upload byte-identical rows. Read it as "how many small
// UpdateSubresource the driver had to absorb", which is the cost we'd
// eliminate with a contiguous-range upload.
//
// The fields are added unconditionally (two u64 in the renderer struct is
// negligible); `uploadCellRow` only bumps them under
// `comptime debug_stats_enabled`, so release builds emit nothing.
const debug_stats_enabled = builtin.mode == .Debug;
const DebugStats = struct {
    rows_uploaded: u64 = 0,
    rows_skipped: u64 = 0,
};

// D3D11 core
device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,

// Shaders
vertex_shader: *win32.ID3D11VertexShader,
pixel_shader: *win32.ID3D11PixelShader,
const_buf: *win32.ID3D11Buffer,

// DirectWrite
dwrite_factory: *win32.IDWriteFactory2,
d2d_factory: *win32.ID2D1Factory,
// One IDWriteTextFormat per (bold, italic) combination, indexed by
// `@intFromEnum(GlyphIndexCache.Style)`. Each format owns its own preferred
// family AND fallback chain so style-specific families can be plumbed
// independently (Step 2.2). When the user doesn't set a style-family it
// inherits the regular primary, and DirectWrite's synthetic bold/oblique
// kicks in via the format's weight/style.
text_formats: [4]*win32.IDWriteTextFormat,
font_fallbacks: [4]*win32.IDWriteFontFallback,
rendering_params: *win32.IDWriteRenderingParams,
dpi: u32,

// DirectComposition
dcomp_device: *win32.IDCompositionDevice = undefined,
dcomp_target: *win32.IDCompositionTarget = undefined,
dcomp_visual: *win32.IDCompositionVisual = undefined,

// Per-window state (lazily initialized)
swap_chain: ?*win32.IDXGISwapChain2 = null,
target_view: ?*win32.ID3D11RenderTargetView = null,
shader_cells: ShaderCells = .{},
// CPU shadow of the GPU cell buffer. Per-row equality vs scratch picks
// which rows actually need UpdateSubresource; on a steady-state terminal
// (idle prompt, partial-screen output) most rows are unchanged.
// Reallocated on grow; the grow flag forces full upload that frame so
// the GPU and shadow are seeded consistently.
shadow_cells: []shader.Cell = &.{},
glyph_texture: GlyphTexture = .{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
staging_texture: StagingTexture = .{},

stats: DebugStats = .{},
remote_or_software_adapter: bool = false,

cell_size: win32.SIZE,
cell_size_xy: CellXY,

// Effective font configuration (defaults if user didn't override). Lifetimes
// of the [*:0]u16 strings are owned by the caller of `init`.
font_size_pt: f32,
effective_primary: [*:0]const u16,
// Per-style primary overrides for bold/italic/bold-italic respectively.
// null entry == inherit regular primary. Held so updateDpi can rebuild
// text_formats without the caller re-supplying the font config.
effective_style_primaries: [3]?[*:0]const u16,
// Active `font-style*` pins retained for updateDpi rebuilds. Pointers into
// the caller's UTF-16 storage; same leak-by-design lifetime as families.
effective_style_specs: [4]FontConfig.StyleSpec,
// Maps a requested style (from styleFromFlags) to the style slot actually
// used at render time. Identity by default; entries 1..3 may collapse to 0
// when synthesis is disabled AND the chosen family lacks a real face.
// The cache key uses the EFFECTIVE style so suppressed cells share the
// regular atlas slots — no redundant entries for identical pixels.
effective_style: [4]GlyphIndexCache.Style,
effective_user_fallbacks: []const [*:0]const u16,
effective_codepoint_maps: []const FontConfig.CodepointMapEntry,

// Tab-bar title text format (regular weight only). Built from the tab-bar
// family/size overrides, falling back to the terminal primary/size. Rebuilt
// alongside text_formats on DPI change and font hot-reload. Consumed by the
// proportional band painter (tabbar_paint), which draws directly with D2D —
// the tab bar does not go through the glyph atlas.
tabbar_text_format: *win32.IDWriteTextFormat,
tabbar_fallback: *win32.IDWriteFontFallback,
// Ellipsis sign for the tab-bar format, cached so the per-frame painter reuses
// it. Rebuilt with the format on DPI/font change.
tabbar_trimming_sign: ?*win32.IDWriteInlineObject,
effective_tabbar_primary: [*:0]const u16,
tabbar_font_size_pt: f32,
// Tab-bar band height in physical pixels (line height of the tab-bar font +
// padding), independent of the terminal cell height. Drives the grid's pixel
// offset and every "where does the terminal start" geometry/input calc.
tab_bar_height: i32,
// Offscreen target the tab bar is painted into, then copied onto the back
// buffer's top strip. Recreated on resize / height change by getOrCreate.
band_texture: gpu.BandTexture = .{},
// Back-buffer texture retained alongside target_view so it can be the
// CopySubresourceRegion destination for the tab-bar band. Released/reacquired
// with target_view.
back_buffer_tex: ?*win32.ID3D11Texture2D = null,

pub fn cellSizeForDpi(self: *D3d11Renderer, dpi: u32) win32.SIZE {
    if (dpi == self.dpi) return self.cell_size;
    return font_mod.measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
}

// Band height = tab-bar font line height (or terminal cell height when the
// family isn't installed) + symmetric vertical padding so glyphs aren't cramped
// against the window edge / terminal. Kept in physical pixels.
fn computeTabBarHeight(
    dwrite_factory: *win32.IDWriteFactory2,
    dpi: u32,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
    fallback_cy: i32,
) i32 {
    const lh = font_mod.measureTabBarLineHeight(&dwrite_factory.IDWriteFactory, dpi, primary, font_size_pt_val);
    const base = if (lh > 0) lh else fallback_cy;
    const pad: i32 = @intFromFloat(@round(win32.scaleDpi(f32, 4.0, dpi)));
    return base + pad;
}

pub fn tabBarHeightForDpi(self: *D3d11Renderer, dpi: u32) i32 {
    if (dpi == self.dpi) return self.tab_bar_height;
    const cs = self.cellSizeForDpi(dpi);
    return computeTabBarHeight(self.dwrite_factory, dpi, self.effective_tabbar_primary, self.tabbar_font_size_pt, @intCast(cs.cy));
}

pub fn init(dpi: u32, font_config: FontConfig) D3d11Renderer {
    const effective_primary: [*:0]const u16 = if (font_config.families.len > 0)
        font_config.families[0]
    else
        default_primary_font_family;
    const effective_user_fallbacks: []const [*:0]const u16 = if (font_config.families.len > 1)
        font_config.families[1..]
    else
        &.{};
    const effective_font_size_pt: f32 = font_config.font_size_pt orelse default_font_size_pt;
    // Create D3D11 device
    const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    {
        const hr = win32.D3D11CreateDevice(
            null,
            .HARDWARE,
            null,
            .{ .BGRA_SUPPORT = 1, .SINGLETHREADED = 1 },
            &levels,
            levels.len,
            win32.D3D11_SDK_VERSION,
            &device,
            null,
            &context,
        );
        if (hr < 0) fatalHr("D3D11CreateDevice", hr);
    }
    const adapter_info = detectAdapter(device);
    log.info(
        "D3D11 device created: adapter='{s}', remote_or_software={}",
        .{ adapter_info.name[0..adapter_info.name_len], adapter_info.remote_or_software },
    );

    // Compile shaders
    const shader_source = @embedFile("terminal.hlsl");

    const vs_blob = gpu.compileShaderBlob(shader_source, "VertexMain", "vs_5_0");
    defer _ = vs_blob.IUnknown.Release();
    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    {
        const hr = device.CreateVertexShader(
            @ptrCast(vs_blob.GetBufferPointer()),
            vs_blob.GetBufferSize(),
            null,
            &vertex_shader,
        );
        if (hr < 0) fatalHr("CreateVertexShader", hr);
    }

    const ps_blob = gpu.compileShaderBlob(shader_source, "PixelMain", "ps_5_0");
    defer _ = ps_blob.IUnknown.Release();
    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    {
        const hr = device.CreatePixelShader(
            @ptrCast(ps_blob.GetBufferPointer()),
            ps_blob.GetBufferSize(),
            null,
            &pixel_shader,
        );
        if (hr < 0) fatalHr("CreatePixelShader", hr);
    }

    // Constant buffer
    var const_buf: *win32.ID3D11Buffer = undefined;
    {
        const desc: win32.D3D11_BUFFER_DESC = .{
            .ByteWidth = std.mem.alignForward(u32, @sizeOf(shader.GridConfig), 16),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        const hr = device.CreateBuffer(&desc, null, &const_buf);
        if (hr < 0) fatalHr("CreateConstBuffer", hr);
    }

    // DirectWrite (factory2 for custom font fallback support, Win 8.1+)
    var dwrite_factory: *win32.IDWriteFactory2 = undefined;
    {
        const hr = win32.DWriteCreateFactory(
            win32.DWRITE_FACTORY_TYPE_SHARED,
            win32.IID_IDWriteFactory2,
            @ptrCast(&dwrite_factory),
        );
        if (hr < 0) fatalHr("DWriteCreateFactory", hr);
    }

    const rendering_params = font_mod.buildRenderingParams(&dwrite_factory.IDWriteFactory);
    const style_primaries: [3]?[*:0]const u16 = .{ font_config.family_bold, font_config.family_italic, font_config.family_bold_italic };
    const synthesize: [3]bool = .{ font_config.synthesize_bold, font_config.synthesize_italic, font_config.synthesize_bold_italic };
    const effective_style = font_mod.computeEffectiveStyle(&dwrite_factory.IDWriteFactory, effective_primary, style_primaries, synthesize, font_config.style_specs);
    const set = font_mod.createTextFormatSet(
        dwrite_factory,
        dpi,
        effective_primary,
        style_primaries,
        font_config.style_specs,
        effective_user_fallbacks,
        font_config.codepoint_maps,
        effective_font_size_pt,
    );

    const cell_size = font_mod.measureCellSize(&dwrite_factory.IDWriteFactory, dpi, effective_primary, effective_font_size_pt);
    const cell_size_xy: CellXY = .{
        .x = @intCast(cell_size.cx),
        .y = @intCast(cell_size.cy),
    };

    const effective_tabbar_primary = font_config.tabbar_family orelse effective_primary;
    const effective_tabbar_size = font_config.tabbar_font_size_pt orelse effective_font_size_pt;
    const tabbar_format = font_mod.createTabBarTextFormat(
        dwrite_factory,
        dpi,
        effective_tabbar_primary,
        effective_user_fallbacks,
        font_config.codepoint_maps,
        effective_tabbar_size,
    );
    const tab_bar_height = computeTabBarHeight(dwrite_factory, dpi, effective_tabbar_primary, effective_tabbar_size, cell_size_xy.y);

    // Direct2D factory for glyph rendering
    var d2d_factory: *win32.ID2D1Factory = undefined;
    {
        const hr = win32.D2D1CreateFactory(
            .SINGLE_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr < 0) fatalHr("D2D1CreateFactory", hr);
    }

    return .{
        .device = device,
        .context = context,
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .const_buf = const_buf,
        .dwrite_factory = dwrite_factory,
        .d2d_factory = d2d_factory,
        .text_formats = set.formats,
        .font_fallbacks = set.fallbacks,
        .rendering_params = rendering_params,
        .cell_size = .{
            .cx = cell_size_xy.x,
            .cy = cell_size_xy.y,
        },
        .cell_size_xy = cell_size_xy,
        .dpi = dpi,
        .font_size_pt = effective_font_size_pt,
        .effective_primary = effective_primary,
        .effective_style_primaries = style_primaries,
        .effective_style_specs = font_config.style_specs,
        .effective_style = effective_style,
        .effective_user_fallbacks = effective_user_fallbacks,
        .effective_codepoint_maps = font_config.codepoint_maps,
        .tabbar_text_format = tabbar_format.format,
        .tabbar_fallback = tabbar_format.fallback,
        .tabbar_trimming_sign = tabbar_format.trimming_sign,
        .effective_tabbar_primary = effective_tabbar_primary,
        .tabbar_font_size_pt = effective_tabbar_size,
        .tab_bar_height = tab_bar_height,
        .remote_or_software_adapter = adapter_info.remote_or_software,
    };
}

const AdapterInfo = struct {
    // desc.Description is [128]u16 — UTF-8 worst case is 4 bytes/wchar so the
    // converted buffer must be at least 512 bytes, otherwise utf16LeToUtf8
    // returns NoSpaceLeft on localized GPU names and the heuristic silently
    // falls back to "unknown" + remote_or_software=false.
    name: [512]u8,
    name_len: usize,
    remote_or_software: bool,
};

fn detectAdapter(device: *win32.ID3D11Device) AdapterInfo {
    const dxgi_device = com.queryInterface(device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();

    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) return unknownAdapter();
    }
    defer _ = adapter.IUnknown.Release();

    var desc: win32.DXGI_ADAPTER_DESC = undefined;
    {
        const hr = adapter.GetDesc(&desc);
        if (hr < 0) return unknownAdapter();
    }

    const raw_name = std.mem.sliceTo(&desc.Description, 0);
    var name_buf: [512]u8 = undefined;
    const name_len = std.unicode.utf16LeToUtf8(&name_buf, raw_name) catch {
        return unknownAdapter();
    };
    const name = name_buf[0..name_len];
    const remote_or_software =
        desc.VendorId == 0x1414 or
        utf8ContainsIgnoreCase(name, "warp") or
        utf8ContainsIgnoreCase(name, "basic render") or
        utf8ContainsIgnoreCase(name, "remote");
    return .{ .name = name_buf, .name_len = name_len, .remote_or_software = remote_or_software };
}

fn unknownAdapter() AdapterInfo {
    var name_buf: [512]u8 = @splat(0);
    @memcpy(name_buf[0.."unknown".len], "unknown");
    return .{ .name = name_buf, .name_len = "unknown".len, .remote_or_software = false };
}

fn utf8ContainsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub fn updateDpi(self: *D3d11Renderer, dpi: u32) void {
    if (dpi == self.dpi) return;
    // DPI alone doesn't change style-family bindings or face availability,
    // so `effective_style` survives untouched. text_formats embed
    // size-in-DIPs so they must be rebuilt; we rebuild fallbacks too to keep
    // init/updateDpi/updateFont sharing one codepath (cost: a few micro-
    // allocations on a rare event).
    font_mod.releaseTextFormatSet(&self.text_formats, &self.font_fallbacks);
    const set = font_mod.createTextFormatSet(
        self.dwrite_factory,
        dpi,
        self.effective_primary,
        self.effective_style_primaries,
        self.effective_style_specs,
        self.effective_user_fallbacks,
        self.effective_codepoint_maps,
        self.font_size_pt,
    );
    self.text_formats = set.formats;
    self.font_fallbacks = set.fallbacks;

    var old_tabbar: font_mod.TabBarFormat = .{ .format = self.tabbar_text_format, .fallback = self.tabbar_fallback, .trimming_sign = self.tabbar_trimming_sign };
    font_mod.releaseTabBarFormat(&old_tabbar);
    const tabbar_format = font_mod.createTabBarTextFormat(
        self.dwrite_factory,
        dpi,
        self.effective_tabbar_primary,
        self.effective_user_fallbacks,
        self.effective_codepoint_maps,
        self.tabbar_font_size_pt,
    );
    self.tabbar_text_format = tabbar_format.format;
    self.tabbar_fallback = tabbar_format.fallback;
    self.tabbar_trimming_sign = tabbar_format.trimming_sign;
    self.dpi = dpi;

    const new_cs = font_mod.measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
    self.cell_size = new_cs;
    self.cell_size_xy = .{
        .x = @intCast(new_cs.cx),
        .y = @intCast(new_cs.cy),
    };
    self.tab_bar_height = computeTabBarHeight(self.dwrite_factory, dpi, self.effective_tabbar_primary, self.tabbar_font_size_pt, @intCast(new_cs.cy));

    // Invalidate glyph cache since font size changed.
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
}

// Re-applies font configuration at runtime (config hot-reload). Unlike
// updateDpi this also rebuilds the fallback chain, since the family list
// itself may have changed. The caller owns the lifetime of the [*:0]u16
// strings in font_config (same contract as init); the renderer keeps
// pointers into them via effective_primary/effective_user_fallbacks.
pub fn updateFont(self: *D3d11Renderer, font_config: FontConfig) void {
    const effective_primary: [*:0]const u16 = if (font_config.families.len > 0)
        font_config.families[0]
    else
        default_primary_font_family;
    const effective_user_fallbacks: []const [*:0]const u16 = if (font_config.families.len > 1)
        font_config.families[1..]
    else
        &.{};
    const effective_font_size_pt: f32 = font_config.font_size_pt orelse default_font_size_pt;

    font_mod.releaseTextFormatSet(&self.text_formats, &self.font_fallbacks);
    const style_primaries: [3]?[*:0]const u16 = .{ font_config.family_bold, font_config.family_italic, font_config.family_bold_italic };
    const synthesize: [3]bool = .{ font_config.synthesize_bold, font_config.synthesize_italic, font_config.synthesize_bold_italic };
    const effective_style = font_mod.computeEffectiveStyle(&self.dwrite_factory.IDWriteFactory, effective_primary, style_primaries, synthesize, font_config.style_specs);
    const set = font_mod.createTextFormatSet(
        self.dwrite_factory,
        self.dpi,
        effective_primary,
        style_primaries,
        font_config.style_specs,
        effective_user_fallbacks,
        font_config.codepoint_maps,
        effective_font_size_pt,
    );
    self.text_formats = set.formats;
    self.font_fallbacks = set.fallbacks;

    var old_tabbar: font_mod.TabBarFormat = .{ .format = self.tabbar_text_format, .fallback = self.tabbar_fallback, .trimming_sign = self.tabbar_trimming_sign };
    font_mod.releaseTabBarFormat(&old_tabbar);
    const effective_tabbar_primary = font_config.tabbar_family orelse effective_primary;
    const effective_tabbar_size = font_config.tabbar_font_size_pt orelse effective_font_size_pt;
    const tabbar_format = font_mod.createTabBarTextFormat(
        self.dwrite_factory,
        self.dpi,
        effective_tabbar_primary,
        effective_user_fallbacks,
        font_config.codepoint_maps,
        effective_tabbar_size,
    );
    self.tabbar_text_format = tabbar_format.format;
    self.tabbar_fallback = tabbar_format.fallback;
    self.tabbar_trimming_sign = tabbar_format.trimming_sign;
    self.effective_tabbar_primary = effective_tabbar_primary;
    self.tabbar_font_size_pt = effective_tabbar_size;

    self.font_size_pt = effective_font_size_pt;
    self.effective_primary = effective_primary;
    self.effective_style_primaries = style_primaries;
    self.effective_style_specs = font_config.style_specs;
    self.effective_style = effective_style;
    self.effective_user_fallbacks = effective_user_fallbacks;
    self.effective_codepoint_maps = font_config.codepoint_maps;

    const new_cs = font_mod.measureCellSize(&self.dwrite_factory.IDWriteFactory, self.dpi, effective_primary, effective_font_size_pt);
    self.cell_size = new_cs;
    self.cell_size_xy = .{
        .x = @intCast(new_cs.cx),
        .y = @intCast(new_cs.cy),
    };
    self.tab_bar_height = computeTabBarHeight(self.dwrite_factory, self.dpi, effective_tabbar_primary, effective_tabbar_size, @intCast(new_cs.cy));

    // Font changed: drop the glyph atlas so glyphs re-rasterize at the new face/size.
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
}

pub fn deinit(self: *D3d11Renderer) void {
    if (comptime debug_stats_enabled) {
        const total = self.stats.rows_uploaded + self.stats.rows_skipped;
        const skip_pct: f64 = if (total == 0) 0.0 else @as(f64, @floatFromInt(self.stats.rows_skipped)) / @as(f64, @floatFromInt(total)) * 100.0;
        log.info("uploadCellRow stats: uploaded={d} skipped={d} ({d:.1}% skipped)", .{ self.stats.rows_uploaded, self.stats.rows_skipped, skip_pct });
    }
    self.staging_texture.release();
    self.band_texture.release();
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_texture.release();
    self.shader_cells.release();
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};
    // Clear all D3D state and flush before releasing the swap chain,
    // otherwise DXGI keeps the window surface and GDI can't draw to it.
    self.context.ClearState();
    if (self.target_view) |tv| _ = tv.IUnknown.Release();
    self.target_view = null;
    if (self.back_buffer_tex) |bb| _ = bb.IUnknown.Release();
    self.back_buffer_tex = null;
    self.context.Flush();
    if (self.swap_chain) |sc| _ = sc.IUnknown.Release();
    _ = self.d2d_factory.IUnknown.Release();
    font_mod.releaseTextFormatSet(&self.text_formats, &self.font_fallbacks);
    {
        var tabbar: font_mod.TabBarFormat = .{ .format = self.tabbar_text_format, .fallback = self.tabbar_fallback, .trimming_sign = self.tabbar_trimming_sign };
        font_mod.releaseTabBarFormat(&tabbar);
    }
    _ = self.rendering_params.IUnknown.Release();
    _ = self.dwrite_factory.IUnknown.Release();
    _ = self.const_buf.IUnknown.Release();
    _ = self.pixel_shader.IUnknown.Release();
    _ = self.vertex_shader.IUnknown.Release();
    _ = self.context.IUnknown.Release();
    _ = self.device.IUnknown.Release();
    self.* = undefined;
}

pub fn render(
    self: *D3d11Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    tabbar: types.TabBarDraw,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
    background_opacity: f32,
) void {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);
    if (client_w == 0 or client_h == 0) return;

    // Lazy swap chain init
    if (self.swap_chain == null) {
        self.swap_chain = self.initSwapChain(hwnd, client_w, client_h);
    }
    const swap_chain = self.swap_chain.?;

    // Resize swap chain if needed
    {
        var sc_w: u32 = undefined;
        var sc_h: u32 = undefined;
        const hr = swap_chain.GetSourceSize(&sc_w, &sc_h);
        if (hr < 0) fatalHr("GetSourceSize", hr);
        if (sc_w != client_w or sc_h != client_h) {
            self.context.ClearState();
            if (self.target_view) |tv| {
                _ = tv.IUnknown.Release();
                self.target_view = null;
            }
            // The retained back buffer is stale once the swap chain resizes;
            // drop it so createRenderTargetView reacquires the new one.
            if (self.back_buffer_tex) |bb| {
                _ = bb.IUnknown.Release();
                self.back_buffer_tex = null;
            }
            self.context.Flush();
            const rhr = swap_chain.IDXGISwapChain.ResizeBuffers(
                0,
                client_w,
                client_h,
                .UNKNOWN,
                @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT),
            );
            if (rhr < 0) fatalHr("ResizeBuffers", rhr);
        }
    }

    const cs = self.cell_size_xy;
    const sb_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w: u32 = client_w -| sb_px;
    const shader_col: u32 = @divTrunc(grid_w + cs.x - 1, cs.x);
    // The tab bar is a separate pixel band at the top (height tab_bar_h),
    // painted via D2D after the grid. The cell grid is terminal-only and the
    // grid quad is drawn under a viewport offset by tab_bar_h (see the draw
    // section); the shader subtracts tab_bar_h from SV_Position.y.
    const tab_bar_h: u32 = @intCast(@max(0, self.tab_bar_height));
    const term_pixel_h: u32 = client_h -| tab_bar_h;
    const term_shader_row: u32 = @divTrunc(term_pixel_h + cs.y - 1, cs.y);

    // Defensive cap matching the per-row scratch capacity below. Must come
    // before `shader_cells.updateCount` / `ensureShadowCapacity`: those
    // mutate GPU buffer and CPU shadow; bailing out after either would
    // leave shadow allocated but un-seeded, and a later in-range frame
    // with unchanged `cell_count` would diff against undefined bytes and
    // silently skip uploads. `render.zig` already gates `total_cols`, but
    // we keep this as a localized safety net.
    const max_shader_col: u32 = 4096;
    if (shader_col > max_shader_col) return;

    // Hoist per-frame atlas setup out of the per-cell loop; the cache /
    // texture state is identical for every cell in a single frame.
    // Also produces `tex_cell_count` needed by the const-buffer below.
    const atlas = glyph_mod.setupGlyphAtlas(self);
    const glyph_cache = atlas.cache;
    const tex_cell_count = atlas.tex_cell_count;

    // Update constant buffer
    {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.Map(
            &self.const_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) fatalHr("MapConstBuffer", hr);
        defer self.context.Unmap(&self.const_buf.ID3D11Resource, 0);
        const config: *shader.GridConfig = @ptrCast(@alignCast(mapped.pData));
        config.cell_size[0] = cs.x;
        config.cell_size[1] = cs.y;
        config.col_count = shader_col;
        config.row_count = term_shader_row;
        // Glyph atlas geometry — the shader uses this to convert a
        // glyph_index to (x,y) in the atlas. Previously the shader
        // called GetDimensions per pixel and divided by cell_size.
        config.cells_per_row = tex_cell_count.x;
        config.tab_bar_height = tab_bar_h;

        // Compute scrollbar geometry in pixels (within the reserved scrollbar area).
        // Coordinates are RT-absolute: the grid sits below the tab-bar band, so the
        // scrollbar's y origin is the band height.
        const sb = term.screens.active.pages.scrollbar();
        const show_scrollbar = sb.total > sb.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
        if (show_scrollbar) {
            const sb_x: f32 = @floatFromInt(grid_w);
            const sb_w: f32 = @floatFromInt(sb_px);
            const sb_origin_y: f32 = @floatFromInt(tab_bar_h);
            const win_h: f32 = @floatFromInt(client_h -| tab_bar_h);
            const min_track_height: f32 = 20.0;
            const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
            const max_offset = sb.total - sb.len;
            const track_y = sb_origin_y + @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);

            config.scrollbar_x = sb_x;
            config.scrollbar_width = sb_w;
            config.scrollbar_y = track_y;
            config.scrollbar_height = track_height;
        } else {
            config.scrollbar_x = 0;
            config.scrollbar_width = 0;
            config.scrollbar_y = 0;
            config.scrollbar_height = 0;
        }
    }

    // Build cell buffer from terminal state (terminal-only; the tab bar is a
    // separate band composited after the grid).
    const cell_count = shader_col * term_shader_row;
    const blank_glyph = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ' ', &.{}, .single, .regular);

    // Effective default fg/bg come from the terminal's dynamic colors (seeded
    // from the theme at tab creation, overridable live by OSC 10/11), falling
    // back to the module constants only if somehow unset.
    var eff_fg: u24 = if (term.colors.foreground.get()) |c| color.rgbToU24(c) else gpu.fallback_fg;
    var eff_bg: u24 = if (term.colors.background.get()) |c| color.rgbToU24(c) else gpu.fallback_bg;
    if (term.modes.get(.reverse_colors)) {
        const tmp = eff_fg;
        eff_fg = eff_bg;
        eff_bg = tmp;
    }
    const opacity_byte: u8 = @intFromFloat(@round(std.math.clamp(background_opacity, 0.0, 1.0) * 255.0));
    const bg_rgba: Rgba8 = .{
        .r = @intCast((eff_bg >> 16) & 0xFF),
        .g = @intCast((eff_bg >> 8) & 0xFF),
        .b = @intCast(eff_bg & 0xFF),
        .a = opacity_byte,
    };

    const cells_recreated = self.shader_cells.updateCount(self.device, cell_count);
    if (cell_count > 0) {
        const shadow_grown = self.ensureShadowCapacity(cell_count);
        // resize overlay re-writes arbitrary rows after the main per-row
        // upload pass has already issued UpdateSubresource for them; rather
        // than backtracking, force-full when resizing so shadow == GPU at
        // the end of the main pass and the overlay sees a known state.
        const force_full = cells_recreated or shadow_grown or resizing;

        // Per-row CPU scratch; one row at a time stays in L1 while we both
        // build it and diff it against the shadow. `max_shader_col` was
        // already gated above before any state mutation.
        var row_scratch: [max_shader_col]shader.Cell = undefined;
        const scratch = row_scratch[0..shader_col];
        const blank_cell: shader.Cell = .{
            .glyph_index = blank_glyph,
            .background = bg_rgba,
            .foreground = bg_rgba,
            .attrs = 0,
        };
        const blink_visible = @mod(@divFloor(std.time.milliTimestamp(), 500), 2) == 0;
        var has_blink = false;

        const screen = term.screens.active;
        const palette = &term.colors.palette.current;

        // Precompute selection bounds once per render. The per-cell loop
        // used to call `sel.contains` which walks the page linked list
        // three times per call (~36k traversals/frame at 200x60). The
        // selection is geometrically a contiguous range on each row, so
        // we just need top-left/bottom-right screen coords + the
        // per-row x-range derived from them (replicates the logic in
        // vt.Selection.containedRowCached without re-resolving pins).
        const SelBounds = struct {
            tl_y: usize,
            br_y: usize,
            tl_x: usize,
            br_x: usize,
            rectangle: bool,
            last_col: usize,
        };
        const sel_bounds: ?SelBounds = if (screen.selection) |sel| blk: {
            const tl_pin = sel.topLeft(screen);
            const br_pin = sel.bottomRight(screen);
            const tl = screen.pages.pointFromPin(.screen, tl_pin).?.screen;
            const br = screen.pages.pointFromPin(.screen, br_pin).?.screen;
            break :blk SelBounds{
                .tl_y = tl.y,
                .br_y = br.y,
                .tl_x = tl.x,
                .br_x = br.x,
                .rectangle = sel.rectangle,
                .last_col = screen.pages.cols - 1,
            };
        } else null;

        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var screen_row: u32 = 0;
        while (row_it.next()) |row_pin| {
            defer screen_row += 1;
            if (screen_row >= term_shader_row) break;

            const page = &row_pin.node.data;
            const page_cells = page.getCells(row_pin.rowAndCell().row);

            // Per-row x-range of the selection. `null` when the row is
            // outside the selection entirely. One pointFromPin per row
            // (~60 calls/frame) instead of three per cell.
            const SelRange = struct { sx: usize, ex: usize };
            const sel_row_range: ?SelRange = if (sel_bounds) |sb| range_blk: {
                const py = screen.pages.pointFromPin(.screen, row_pin).?.screen.y;
                if (py < sb.tl_y or py > sb.br_y) break :range_blk null;
                if (sb.rectangle) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.br_x };
                if (sb.tl_y == sb.br_y) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.br_x };
                if (py == sb.tl_y) break :range_blk SelRange{ .sx = sb.tl_x, .ex = sb.last_col };
                if (py == sb.br_y) break :range_blk SelRange{ .sx = 0, .ex = sb.br_x };
                break :range_blk SelRange{ .sx = 0, .ex = sb.last_col };
            } else null;

            // Cursor inversion is applied inline (not in a separate post-pass)
            // so that wide CJK glyphs get BOTH halves flipped, not just the
            // left one.
            const cursor_visible = screen.viewportIsBottom() and term.modes.get(.cursor_visible);
            const cursor_on_row = cursor_visible and screen.cursor.y == screen_row;
            const cursor_bg_rgba = Rgba8.fromU24(if (term.colors.cursor.get()) |c| color.rgbToU24(c) else eff_fg);
            const cursor_fg_rgba = Rgba8.fromU24(cursor_text orelse eff_bg);

            var col: u32 = 0;
            for (page_cells, 0..) |cell, cell_i| {
                if (col >= shader_col) break;
                if (cell.wide == .spacer_tail) {
                    // Already written by the .wide cell handler
                    continue;
                }

                const raw_cp: u21 = switch (cell.content_tag) {
                    .codepoint, .codepoint_grapheme => cell.content.codepoint,
                    .bg_color_palette, .bg_color_rgb => ' ',
                };
                const codepoint: u21 = if (raw_cp == 0) ' ' else raw_cp;
                const grapheme: []const u21 = if (cell.content_tag == .codepoint_grapheme)
                    page.lookupGrapheme(&page_cells[cell_i]) orelse &.{}
                else
                    &.{};

                var cell_fg: u24 = eff_fg;
                var cell_bg: u24 = eff_bg;
                // Whether this cell shows the default background and should get
                // the window blur-alpha. Tracked as a flag (not bg-value
                // equality) so a cell explicitly painted with the theme's bg
                // color stays opaque, and inverse video stays opaque too.
                var is_default_bg = true;
                var bold = false;
                var italic = false;
                var faint = false;
                var invisible = false;
                var attrs: u32 = 0;

                if (cell.style_id != 0) {
                    const style = page.styles.get(page.memory, cell.style_id).*;
                    cell_fg = color.resolveColor(style.fg_color, palette, eff_fg);
                    cell_bg = color.resolveColor(style.bg_color, palette, eff_bg);
                    bold = style.flags.bold;
                    italic = style.flags.italic;
                    faint = style.flags.faint;
                    invisible = style.flags.invisible;
                    if (style.flags.blink) {
                        has_blink = true;
                        if (!blink_visible) invisible = true;
                    }
                    attrs |= @as(u32, @intFromEnum(style.flags.underline)) & gpu.cell_attr_underline_mask;
                    if (style.flags.strikethrough) attrs |= gpu.cell_attr_strikethrough;
                    if (style.flags.overline) attrs |= gpu.cell_attr_overline;
                    if (style.flags.inverse) {
                        const tmp = cell_fg;
                        cell_fg = cell_bg;
                        cell_bg = tmp;
                        is_default_bg = false;
                    } else {
                        is_default_bg = switch (style.bg_color) {
                            .none => true,
                            else => false,
                        };
                    }
                }

                switch (cell.content_tag) {
                    .bg_color_palette => {
                        cell_bg = color.rgbToU24(palette[cell.content.color_palette]);
                        is_default_bg = false;
                    },
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
                        is_default_bg = false;
                    },
                    else => {},
                }
                if (emoji.isColorGlyphRun(codepoint, grapheme)) attrs |= gpu.cell_attr_color_glyph;
                if (invisible) attrs |= gpu.cell_attr_invisible;

                var bg = if (is_default_bg) bg_rgba else Rgba8.fromU24(cell_bg);
                if (faint) cell_fg = color.dimColor(cell_fg);
                var fg = if (invisible) bg else Rgba8.fromU24(cell_fg);

                // Highlight selected cells (with fade)
                if (sel_row_range) |r| {
                    if (col >= r.sx and col <= r.ex) {
                        const orig_bg = bg;
                        // Theme selection colors when provided, else invert the
                        // cell (selection bg := cell fg, selection text := cell bg).
                        var target_bg = if (selection_bg) |s| Rgba8.fromU24(s) else fg;
                        target_bg.a = 255;
                        var target_fg = if (selection_fg) |s| Rgba8.fromU24(s) else orig_bg;
                        target_fg.a = 255;
                        bg = color.lerpRgba8(orig_bg, target_bg, selection_fade);
                        fg = color.lerpRgba8(fg, target_fg, selection_fade);
                    }
                }

                // Cursor inversion applies to the LOGICAL cell at column `col`.
                // For wide cells both visual halves inherit this so the cursor
                // highlight covers the whole glyph.
                if (cursor_on_row and screen.cursor.x == col) {
                    bg = cursor_bg_rgba;
                    fg = cursor_fg_rgba;
                }

                const style_kind = self.effective_style[@intFromEnum(glyph_mod.styleFromFlags(bold, italic))];

                if (cell.wide == .wide) {
                    // One DirectWrite render for both halves; see
                    // generateWidePair.
                    const pair = glyph_mod.generateWidePair(self, glyph_cache, tex_cell_count, codepoint, grapheme, style_kind);
                    scratch[col] = .{
                        .glyph_index = pair.left,
                        .background = bg,
                        .foreground = fg,
                        .attrs = attrs,
                    };
                    col += 1;
                    if (col < shader_col) {
                        scratch[col] = .{
                            .glyph_index = pair.right,
                            .background = bg,
                            .foreground = fg,
                            .attrs = attrs,
                        };
                    }
                    col += 1;
                    continue;
                }

                // Space is ink-free, so its atlas slot is identical regardless
                // of bold/italic — reuse the per-frame blank_glyph instead of
                // hashing the cache for every interior space (prompt padding,
                // alignment gaps, bg_color_* cells which already normalize to
                // ' ' above). Trailing-blank and empty-row fills are handled
                // by the @memset paths below.
                const glyph_index = if (codepoint == ' ' and grapheme.len == 0)
                    blank_glyph
                else
                    glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, codepoint, grapheme, .single, style_kind);
                scratch[col] = .{
                    .glyph_index = glyph_index,
                    .background = bg,
                    .foreground = fg,
                    .attrs = attrs,
                };
                col += 1;
            }
            // Fill remaining columns with blanks
            if (col < shader_col) {
                @memset(scratch[col..shader_col], blank_cell);
            }

            const dst_row_offset = screen_row * shader_col;
            self.uploadCellRow(dst_row_offset, scratch, force_full);
        }
        // Fill remaining terminal rows with blanks. The row content is identical
        // across iterations so we build scratch once and let uploadCellRow's diff
        // skip any row whose shadow already matches.
        if (screen_row < term_shader_row) {
            @memset(scratch, blank_cell);
            while (screen_row < term_shader_row) : (screen_row += 1) {
                const dst_row_offset = screen_row * shader_col;
                self.uploadCellRow(dst_row_offset, scratch, force_full);
            }
        }

        // Cursor inversion is applied inline in the per-row cell loop so
        // wide CJK gets both halves flipped, not just the left one.

        // Draw resize overlay (e.g. "80x25") centered in the terminal region.
        // force_full above guarantees the shadow now mirrors GPU exactly, so we
        // can pull each overlaid row out of the shadow, apply the overlay
        // edits in-place, and re-upload — no need to recompute the row from
        // terminal state.
        if (resizing) {
            const overlay_bg = Rgba8.fromU24(0x333333);
            const overlay_fg = Rgba8.fromU24(0xffffff);

            var text_buf: [20]u8 = undefined;
            const text = std.fmt.bufPrint(&text_buf, "{}x{}", .{ term.cols, term.rows }) catch unreachable;

            const text_len: u32 = @intCast(text.len);
            const pad: u32 = 2;
            const box_w = text_len + pad;
            const box_h: u32 = 3;
            const box_x = (shader_col -| box_w) / 2;
            const box_y = (term_shader_row -| box_h) / 2;

            const tx = box_x + (box_w -| text_len) / 2;
            const ty = box_y + 1;

            var by: u32 = box_y;
            while (by < box_y + box_h and by < term_shader_row) : (by += 1) {
                const dst_row_offset = by * shader_col;
                @memcpy(scratch, self.shadow_cells[dst_row_offset..][0..shader_col]);

                // Background box on this row.
                var bx: u32 = box_x;
                while (bx < box_x + box_w and bx < shader_col) : (bx += 1) {
                    scratch[bx] = .{
                        .glyph_index = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ' ', &.{}, .single, .regular),
                        .background = overlay_bg,
                        .foreground = overlay_fg,
                        .attrs = 0,
                    };
                }
                // Text on the middle row only.
                if (by == ty) {
                    for (text, 0..) |ch, i| {
                        const tcol = tx + @as(u32, @intCast(i));
                        if (tcol < shader_col) {
                            scratch[tcol] = .{
                                .glyph_index = glyph_mod.generateGlyph(self, glyph_cache, tex_cell_count, ch, &.{}, .single, .regular),
                                .background = overlay_bg,
                                .foreground = overlay_fg,
                                .attrs = 0,
                            };
                        }
                    }
                }
                self.uploadCellRow(dst_row_offset, scratch, true);
            }
        }

        if (has_blink) {
            _ = win32.SetTimer(hwnd, types.TIMER_TEXT_BLINK, 250, null);
        } else {
            _ = win32.KillTimer(hwnd, types.TIMER_TEXT_BLINK);
        }
    }

    // Create render target view if needed
    if (self.target_view == null) {
        self.target_view = self.createRenderTargetView(swap_chain, client_w, client_h);
    }

    // Draw
    {
        var target_views = [_]?*win32.ID3D11RenderTargetView{self.target_view.?};
        self.context.OMSetRenderTargets(target_views.len, &target_views, null);
    }
    // Clear to transparent black for DWM glass compositing (whole RT; the band
    // strip stays transparent here and is overwritten by the band copy below).
    {
        const clear_color = [4]f32{ 0, 0, 0, 0 };
        self.context.ClearRenderTargetView(self.target_view.?, @ptrCast(&clear_color));
    }
    // Offset the grid below the tab-bar band. Set every frame from the current
    // size + tab_bar_h: a font/DPI/config reload can change tab_bar_h without a
    // swapchain resize (stale-viewport bug otherwise).
    {
        var viewport = win32.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = @floatFromInt(tab_bar_h),
            .Width = @floatFromInt(client_w),
            .Height = @floatFromInt(term_pixel_h),
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        };
        self.context.RSSetViewports(1, @ptrCast(&viewport));
    }
    self.context.PSSetConstantBuffers(0, 1, @ptrCast(@constCast(&self.const_buf)));
    var resources = [_]?*win32.ID3D11ShaderResourceView{
        if (cell_count > 0) self.shader_cells.cell_view else null,
        self.glyph_texture.view,
    };
    self.context.PSSetShaderResources(0, resources.len, &resources);
    self.context.VSSetShader(self.vertex_shader, null, 0);
    self.context.PSSetShader(self.pixel_shader, null, 0);
    self.context.Draw(4, 0);

    // Tab-bar band: paint proportionally into the offscreen band texture, then
    // copy it onto the back buffer's top strip. Mirrors the glyph-staging
    // pattern (D2D EndDraw flushes before the D3D copy reads the texture).
    if (tab_bar_h > 0) {
        const band = self.band_texture.getOrCreate(self.device, self.d2d_factory, client_w, tab_bar_h);
        tabbar_paint.paint(
            band.render_target,
            band.brush,
            &self.dwrite_factory.IDWriteFactory,
            self.tabbar_text_format,
            self.tabbar_trimming_sign,
            tabbar,
            cs.x,
            tab_bar_h,
        );
        // Unbind the RTV so the back buffer can be a CopySubresourceRegion dest.
        self.context.OMSetRenderTargets(0, null, null);
        if (self.back_buffer_tex) |bb| {
            const copy_h = @min(tab_bar_h, client_h);
            const src_box = win32.D3D11_BOX{
                .left = 0,
                .top = 0,
                .front = 0,
                .right = client_w,
                .bottom = copy_h,
                .back = 1,
            };
            self.context.CopySubresourceRegion(&bb.ID3D11Resource, 0, 0, 0, 0, &band.texture.ID3D11Resource, 0, &src_box);
        }
    }

    {
        // Sync interval 0: rate limiting lives in the SetTimer-driven render
        // throttle on the UI side. Present(1) on a 60Hz display would stack
        // with the 16ms software cap and halve effective FPS, and on RDP
        // DXGI's vsync wait is emulated and can block the UI thread for
        // arbitrary network-bound durations — exactly the CPU spike this
        // change is meant to avoid.
        const hr = swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0) fatalHr("Present", hr);
    }
}

// --- Swap chain ---

fn initSwapChain(self: *D3d11Renderer, hwnd: win32.HWND, width: u32, height: u32) *win32.IDXGISwapChain2 {
    const dxgi_device = com.queryInterface(self.device, win32.IDXGIDevice);
    defer _ = dxgi_device.IUnknown.Release();
    var adapter: *win32.IDXGIAdapter = undefined;
    {
        const hr = dxgi_device.GetAdapter(&adapter);
        if (hr < 0) fatalHr("GetAdapter", hr);
    }
    defer _ = adapter.IUnknown.Release();
    var factory: *win32.IDXGIFactory2 = undefined;
    {
        const hr = adapter.IDXGIObject.GetParent(win32.IID_IDXGIFactory2, @ptrCast(&factory));
        if (hr < 0) fatalHr("GetDxgiFactory", hr);
    }
    defer _ = factory.IUnknown.Release();

    const swap_chain_flags: u32 = @intFromEnum(win32.DXGI_SWAP_CHAIN_FLAG_FRAME_LATENCY_WAITABLE_OBJECT);
    var swap_chain1: *win32.IDXGISwapChain1 = undefined;
    {
        const desc = win32.DXGI_SWAP_CHAIN_DESC1{
            .Width = width,
            .Height = height,
            .Format = .B8G8R8A8_UNORM,
            .Stereo = 0,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = win32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .Scaling = .STRETCH,
            .SwapEffect = .FLIP_SEQUENTIAL,
            .AlphaMode = .PREMULTIPLIED,
            .Flags = swap_chain_flags,
        };
        const hr = factory.CreateSwapChainForComposition(
            &self.device.IUnknown,
            &desc,
            null,
            &swap_chain1,
        );
        if (hr < 0) fatalHr("CreateSwapChainForComposition", hr);
    }
    defer _ = swap_chain1.IUnknown.Release();

    // DirectComposition: bind swap chain to window
    {
        const hr = win32.DCompositionCreateDevice(dxgi_device, win32.IID_IDCompositionDevice, @ptrCast(&self.dcomp_device));
        if (hr < 0) fatalHr("DCompositionCreateDevice", hr);
    }
    {
        const hr = self.dcomp_device.CreateTargetForHwnd(hwnd, 1, @ptrCast(&self.dcomp_target));
        if (hr < 0) fatalHr("CreateTargetForHwnd", hr);
    }
    {
        const hr = self.dcomp_device.CreateVisual(@ptrCast(&self.dcomp_visual));
        if (hr < 0) fatalHr("CreateVisual", hr);
    }
    {
        const hr = self.dcomp_visual.SetContent(&swap_chain1.IUnknown);
        if (hr < 0) fatalHr("SetContent", hr);
    }
    {
        const hr = self.dcomp_target.SetRoot(self.dcomp_visual);
        if (hr < 0) fatalHr("SetRoot", hr);
    }
    {
        const hr = self.dcomp_device.Commit();
        if (hr < 0) fatalHr("DCompCommit", hr);
    }

    var swap_chain2: *win32.IDXGISwapChain2 = undefined;
    {
        const hr = swap_chain1.IUnknown.QueryInterface(win32.IID_IDXGISwapChain2, @ptrCast(&swap_chain2));
        if (hr < 0) fatalHr("QuerySwapChain2", hr);
    }
    return swap_chain2;
}

fn createRenderTargetView(
    self: *D3d11Renderer,
    swap_chain: *win32.IDXGISwapChain2,
    width: u32,
    height: u32,
) *win32.ID3D11RenderTargetView {
    var back_buffer: *win32.ID3D11Texture2D = undefined;
    {
        const hr = swap_chain.IDXGISwapChain.GetBuffer(0, win32.IID_ID3D11Texture2D, @ptrCast(&back_buffer));
        if (hr < 0) fatalHr("GetBuffer", hr);
    }
    // Retain the back buffer as the CopySubresourceRegion destination for the
    // tab-bar band. Released/replaced together with target_view.
    if (self.back_buffer_tex) |old| _ = old.IUnknown.Release();
    self.back_buffer_tex = back_buffer;

    var target_view: *win32.ID3D11RenderTargetView = undefined;
    {
        // Swap chain is B8G8R8A8_UNORM (flip-model + DComp require it), but
        // the RTV uses the _SRGB view so the GPU does linear→sRGB encoding
        // on store. Shader blends in linear space.
        const rtv_desc: win32.D3D11_RENDER_TARGET_VIEW_DESC = .{
            .Format = .B8G8R8A8_UNORM_SRGB,
            .ViewDimension = .TEXTURE2D,
            .Anonymous = .{ .Texture2D = .{ .MipSlice = 0 } },
        };
        const hr = self.device.CreateRenderTargetView(&back_buffer.ID3D11Resource, &rtv_desc, &target_view);
        if (hr < 0) fatalHr("CreateRenderTargetView", hr);
    }

    var viewport = win32.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = 0,
        .Width = @floatFromInt(width),
        .Height = @floatFromInt(height),
        .MinDepth = 0.0,
        .MaxDepth = 0.0,
    };
    self.context.RSSetViewports(1, @ptrCast(&viewport));
    self.context.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

    return target_view;
}

/// Grow `shadow_cells` to hold `count` entries. Returns true on grow so the
/// caller forces a full upload that frame (newly-allocated tail is undefined
/// and would otherwise alias a stale row's content). Shrinks are kept as-is:
/// the tail past `count` is never read.
fn ensureShadowCapacity(self: *D3d11Renderer, count: u32) bool {
    if (self.shadow_cells.len >= count) return false;
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = std.heap.page_allocator.alloc(shader.Cell, count) catch oom(error.OutOfMemory);
    return true;
}

/// Diff `scratch` against the shadow row at `row_start_cell`; if changed (or
/// `force_full`), push the row to the GPU via UpdateSubresource and sync the
/// shadow. `row_start_cell` is in cell units (not bytes).
fn uploadCellRow(
    self: *D3d11Renderer,
    row_start_cell: u32,
    scratch: []const shader.Cell,
    force_full: bool,
) void {
    const shadow_row = self.shadow_cells[row_start_cell..][0..scratch.len];
    if (!force_full and std.mem.eql(
        u8,
        std.mem.sliceAsBytes(shadow_row),
        std.mem.sliceAsBytes(scratch),
    )) {
        if (comptime debug_stats_enabled) self.stats.rows_skipped += 1;
        return;
    }
    if (comptime debug_stats_enabled) self.stats.rows_uploaded += 1;
    const cell_bytes: u32 = @sizeOf(shader.Cell);
    const box: win32.D3D11_BOX = .{
        .left = row_start_cell * cell_bytes,
        .right = (row_start_cell + @as(u32, @intCast(scratch.len))) * cell_bytes,
        .top = 0,
        .bottom = 1,
        .front = 0,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.shader_cells.cell_buf.ID3D11Resource,
        0,
        &box,
        scratch.ptr,
        0,
        0,
    );
    @memcpy(shadow_row, scratch);
}
