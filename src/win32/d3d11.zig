const D3d11Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphIndexCache = @import("GlyphIndexCache.zig");
const sprite = @import("sprite.zig");

const log = std.log.scoped(.d3d);

// Shared types with the shader
const shader = struct {
    const GridConfig = extern struct {
        cell_size: [2]u32,
        col_count: u32,
        row_count: u32,
        scrollbar_y: f32,
        scrollbar_height: f32,
        scrollbar_x: f32,
        scrollbar_width: f32,
        cells_per_row: u32,
        _pad: [3]u32 = .{ 0, 0, 0 },
    };
    const Cell = extern struct {
        glyph_index: u32,
        background: Rgba8,
        foreground: Rgba8,
    };
};

const Rgba8 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
    fn fromU24(c: u24) Rgba8 {
        return .{
            .r = @intCast((c >> 16) & 0xFF),
            .g = @intCast((c >> 8) & 0xFF),
            .b = @intCast(c & 0xFF),
            .a = 255,
        };
    }
};

/// One cell's worth of tab-bar content, laid out by the caller and
/// rendered into the reserved top row by `render`.
pub const TabBarCell = struct {
    codepoint: u21,
    bg: Rgba8,
    fg: Rgba8,
    pub fn rgba(c: u24) Rgba8 {
        return Rgba8.fromU24(c);
    }
};

// Used only when the terminal's dynamic fg/bg colors are unset (which normally
// never happens — tab creation seeds term.colors from the active theme).
const fallback_fg: u24 = 0xc8c4d0;
const fallback_bg: u24 = 0x2a2a2a;

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
text_format: *win32.IDWriteTextFormat,
font_fallback: *win32.IDWriteFontFallback,
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

cell_size: win32.SIZE,
cell_size_xy: CellXY,

// Effective font configuration (defaults if user didn't override). Lifetimes
// of the [*:0]u16 strings are owned by the caller of `init`.
font_size_pt: f32,
effective_primary: [*:0]const u16,
effective_user_fallbacks: []const [*:0]const u16,

pub const FontConfig = struct {
    /// First entry becomes the primary family; the rest are inserted at the
    /// front of the fallback chain. Empty -> use built-in defaults.
    families: []const [*:0]const u16 = &.{},
    /// Font size in points. Null -> use built-in default.
    font_size_pt: ?f32 = null,
};

const scrollbar_logical_width: u16 = 14;

pub fn scrollbarWidth(dpi: u32) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scrollbar_logical_width)) * @as(f32, @floatFromInt(dpi)) / 96.0));
}

fn measureCellSize(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
) win32.SIZE {
    // Query the primary font face's canonical design metrics rather than
    // measuring a specific glyph via text layout. Some monospace fonts (e.g.
    // Rec Mono Casual) have a U+2588 advance that's wider than their ASCII
    // letters, which previously made cells too wide and stretched every letter
    // horizontally. Using designUnitsPerEm + advanceWidth from the font face
    // gives the true monospace advance, independent of which glyph we sample.
    var system_collection: *win32.IDWriteFontCollection = undefined;
    {
        const hr = dwrite_factory.GetSystemFontCollection(&system_collection, 0);
        if (hr < 0) fatalHr("GetSystemFontCollection", hr);
    }
    defer _ = system_collection.IUnknown.Release();

    var family_index: u32 = 0;
    var family_exists: win32.BOOL = 0;
    {
        const hr = system_collection.FindFamilyName(primary, &family_index, &family_exists);
        if (hr < 0) fatalHr("FindFamilyName", hr);
    }
    if (family_exists == 0) {
        std.log.warn("primary font family not installed; trying fallback monospace", .{});
        for (&measurement_fallbacks) |candidate| {
            const hr = system_collection.FindFamilyName(candidate, &family_index, &family_exists);
            if (hr >= 0 and family_exists != 0) break;
        }
        if (family_exists == 0) fatalHr("FindFamilyName (no monospace family found)", -1);
    }

    var family: *win32.IDWriteFontFamily = undefined;
    {
        const hr = system_collection.GetFontFamily(family_index, &family);
        if (hr < 0) fatalHr("GetFontFamily", hr);
    }
    defer _ = family.IUnknown.Release();

    var font: *win32.IDWriteFont = undefined;
    {
        const hr = family.GetFirstMatchingFont(.NORMAL, .NORMAL, .NORMAL, &font);
        if (hr < 0) fatalHr("GetFirstMatchingFont", hr);
    }
    defer _ = font.IUnknown.Release();

    var face: *win32.IDWriteFontFace = undefined;
    {
        const hr = font.CreateFontFace(&face);
        if (hr < 0) fatalHr("CreateFontFace", hr);
    }
    defer _ = face.IUnknown.Release();

    var font_metrics: win32.DWRITE_FONT_METRICS = undefined;
    face.GetMetrics(&font_metrics);

    // Sample 'M' for the advance (any ASCII letter works in a monospace font).
    const codepoint: u32 = 'M';
    var glyph_index: [1:0]u16 = .{0};
    {
        const hr = face.GetGlyphIndices(@ptrCast(&codepoint), 1, &glyph_index);
        if (hr < 0) fatalHr("GetGlyphIndices", hr);
    }
    var glyph_metrics: win32.DWRITE_GLYPH_METRICS = undefined;
    {
        const hr = face.GetDesignGlyphMetrics(&glyph_index, 1, @ptrCast(&glyph_metrics), 0);
        if (hr < 0) fatalHr("GetDesignGlyphMetrics", hr);
    }

    const font_size_dips = fontSizeDips(dpi, font_size_pt_val);
    const units_per_em: f32 = @floatFromInt(font_metrics.designUnitsPerEm);
    const design_to_dips = font_size_dips / units_per_em;

    const advance_dips = @as(f32, @floatFromInt(glyph_metrics.advanceWidth)) * design_to_dips;
    const ascent_dips = @as(f32, @floatFromInt(font_metrics.ascent)) * design_to_dips;
    const descent_dips = @as(f32, @floatFromInt(font_metrics.descent)) * design_to_dips;
    const line_gap_dips = @as(f32, @floatFromInt(font_metrics.lineGap)) * design_to_dips;
    const line_height_dips = ascent_dips + descent_dips + line_gap_dips;

    return .{
        .cx = @intFromFloat(@round(advance_dips)),
        .cy = @intFromFloat(@round(line_height_dips)),
    };
}

// Font configuration (mirrors WezTerm config). Primary family, then ordered
// fallbacks: CJK -> Nerd Font icons -> Emoji. Missing families on the system
// are silently skipped by DirectWrite when resolving glyphs.
pub const default_primary_font_family: [*:0]const u16 = win32.L("Consolas");
pub const default_font_size_pt: f32 = 13.0;

// Computes the font size to pass to CreateTextFormat. CreateTextFormat
// nominally takes DIPs (1/96 inch), and our config is in points (1/72 inch),
// so we convert pt -> DIPs (x 96/72) then apply DPI scaling for the monitor.
// Note: the staging render target runs in D2D1_UNIT_MODE_PIXELS, which makes
// the value we return coincide with physical pixels for our specific draw
// path. The name "Dips" reflects the API contract, not the eventual unit.
fn fontSizeDips(dpi: u32, font_size_pt_val: f32) f32 {
    return win32.scaleDpi(f32, font_size_pt_val * 96.0 / 72.0, dpi);
}

// Fallback families used by measureCellSize when the primary isn't installed.
// Picked to be common Windows monospace fonts so a sensible cell size is found
// even on minimal installs.
const measurement_fallbacks = blk: {
    @setEvalBranchQuota(4000);
    break :blk [_][*:0]const u16{
        win32.L("Cascadia Mono"),
        win32.L("Consolas"),
        win32.L("Courier New"),
    };
};

const font_fallback_families = [_][*:0]const u16{
    win32.L("Segoe UI Emoji"),
};

fn createTextFormat(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    font_fallback: *win32.IDWriteFontFallback,
    primary: [*:0]const u16,
    font_size_pt_val: f32,
) *win32.IDWriteTextFormat {
    var text_format: *win32.IDWriteTextFormat = undefined;
    const hr = dwrite_factory.CreateTextFormat(
        primary,
        null,
        .NORMAL,
        .NORMAL,
        .NORMAL,
        fontSizeDips(dpi, font_size_pt_val),
        win32.L(""),
        &text_format,
    );
    if (hr < 0) fatalHr("CreateTextFormat", hr);

    // Attach our custom fallback chain so CJK / Nerd Font / Emoji glyphs render.
    const text_format1 = queryInterface(text_format, win32.IDWriteTextFormat1);
    defer _ = text_format1.IUnknown.Release();
    const sfhr = text_format1.SetFontFallback(font_fallback);
    if (sfhr < 0) fatalHr("SetFontFallback", sfhr);

    // Single-glyph layouts must never wrap; we measure & scale to fit instead.
    const wwhr = text_format.SetWordWrapping(win32.DWRITE_WORD_WRAPPING_NO_WRAP);
    if (wwhr < 0) fatalHr("SetWordWrapping", wwhr);

    return text_format;
}

// Custom rendering parameters so the atlas is reproducible across machines
// and aligns with the shader's gamma 2.0 (`c*c`) decode of the ClearType
// mask. `enhanced_contrast=0` removes D2D's non-invertible contrast curve
// so the stored mask is a predictable function of coverage; `RGB` stripe
// and `NATURAL_SYMMETRIC` rendering mode pick the standard subpixel
// layout and the best horizontal subpixel positioning (experimental —
// can fall back to `NATURAL` if vertical edges look soft on a given
// monitor). Gamma here MUST match the shader's `to_linear` exponent
// (currently 2.0) or text will look washed out / over-saturated.
fn buildRenderingParams(factory: *win32.IDWriteFactory) *win32.IDWriteRenderingParams {
    var params: *win32.IDWriteRenderingParams = undefined;
    const hr = factory.CreateCustomRenderingParams(
        2.0,
        0.0,
        1.0,
        win32.DWRITE_PIXEL_GEOMETRY_RGB,
        win32.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
        &params,
    );
    if (hr < 0) fatalHr("CreateCustomRenderingParams", hr);
    return params;
}

// Hard cap on user-supplied fallback families. Anything beyond is ignored;
// the chain is already long once you include the hardcoded CJK/icon/emoji
// fonts, and DirectWrite walks it linearly.
const max_user_fallbacks: usize = 32;

fn buildFontFallback(
    factory: *win32.IDWriteFactory2,
    user_fallbacks: []const [*:0]const u16,
) *win32.IDWriteFontFallback {
    var builder: *win32.IDWriteFontFallbackBuilder = undefined;
    {
        const hr = factory.CreateFontFallbackBuilder(&builder);
        if (hr < 0) fatalHr("CreateFontFallbackBuilder", hr);
    }
    defer _ = builder.IUnknown.Release();

    // AddMapping takes a prioritized list of family names for a single Unicode
    // range, in order. Calling it once per family with the full range would
    // make only the first family ever match (DirectWrite picks the first
    // mapping whose range contains the codepoint, then walks its family list).
    var family_ptrs: [max_user_fallbacks + font_fallback_families.len]?*const u16 = undefined;
    const user_n = @min(user_fallbacks.len, max_user_fallbacks);
    if (user_fallbacks.len > max_user_fallbacks) {
        std.log.warn("config: dropping {d} extra font-family fallback(s) past cap {d}", .{
            user_fallbacks.len - max_user_fallbacks,
            max_user_fallbacks,
        });
    }
    for (user_fallbacks[0..user_n], 0..) |family, i| {
        family_ptrs[i] = @ptrCast(family);
    }
    for (font_fallback_families, 0..) |family, i| {
        family_ptrs[user_n + i] = @ptrCast(family);
    }
    const total = user_n + font_fallback_families.len;
    const full_range = win32.DWRITE_UNICODE_RANGE{ .first = 0, .last = 0x10FFFF };
    {
        const hr = builder.AddMapping(
            @ptrCast(&full_range),
            1,
            &family_ptrs,
            @intCast(total),
            null,
            null,
            null,
            1.0,
        );
        if (hr < 0) fatalHr("AddMapping", hr);
    }

    // Chain the system fallback so codepoints not covered above still resolve.
    {
        var system_fallback: *win32.IDWriteFontFallback = undefined;
        const hr = factory.GetSystemFontFallback(&system_fallback);
        if (hr < 0) fatalHr("GetSystemFontFallback", hr);
        defer _ = system_fallback.IUnknown.Release();
        const ahr = builder.AddMappings(system_fallback);
        if (ahr < 0) fatalHr("AddMappings", ahr);
    }

    var fallback: *win32.IDWriteFontFallback = undefined;
    {
        const hr = builder.CreateFontFallback(&fallback);
        if (hr < 0) fatalHr("CreateFontFallback", hr);
    }
    return fallback;
}

pub fn cellSizeForDpi(self: *D3d11Renderer, dpi: u32) win32.SIZE {
    if (dpi == self.dpi) return self.cell_size;
    return measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
}

const CellXY = struct {
    x: u16,
    y: u16,
    fn eql(a: CellXY, b: CellXY) bool {
        return a.x == b.x and a.y == b.y;
    }
};

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
    log.info("D3D11 device created", .{});

    // Compile shaders
    const shader_source = @embedFile("terminal.hlsl");

    const vs_blob = compileShaderBlob(shader_source, "VertexMain", "vs_5_0");
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

    const ps_blob = compileShaderBlob(shader_source, "PixelMain", "ps_5_0");
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

    const font_fallback = buildFontFallback(dwrite_factory, effective_user_fallbacks);
    const rendering_params = buildRenderingParams(&dwrite_factory.IDWriteFactory);
    const text_format = createTextFormat(&dwrite_factory.IDWriteFactory, dpi, font_fallback, effective_primary, effective_font_size_pt);

    const cell_size = measureCellSize(&dwrite_factory.IDWriteFactory, dpi, effective_primary, effective_font_size_pt);
    const cell_size_xy: CellXY = .{
        .x = @intCast(cell_size.cx),
        .y = @intCast(cell_size.cy),
    };

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
        .text_format = text_format,
        .font_fallback = font_fallback,
        .rendering_params = rendering_params,
        .cell_size = .{
            .cx = cell_size_xy.x,
            .cy = cell_size_xy.y,
        },
        .cell_size_xy = cell_size_xy,
        .dpi = dpi,
        .font_size_pt = effective_font_size_pt,
        .effective_primary = effective_primary,
        .effective_user_fallbacks = effective_user_fallbacks,
    };
}

pub fn updateDpi(self: *D3d11Renderer, dpi: u32) void {
    if (dpi == self.dpi) return;
    _ = self.text_format.IUnknown.Release();
    self.text_format = createTextFormat(&self.dwrite_factory.IDWriteFactory, dpi, self.font_fallback, self.effective_primary, self.font_size_pt);
    self.dpi = dpi;

    const new_cs = measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
    self.cell_size = new_cs;
    self.cell_size_xy = .{
        .x = @intCast(new_cs.cx),
        .y = @intCast(new_cs.cy),
    };

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

    _ = self.font_fallback.IUnknown.Release();
    self.font_fallback = buildFontFallback(self.dwrite_factory, effective_user_fallbacks);
    _ = self.text_format.IUnknown.Release();
    self.text_format = createTextFormat(&self.dwrite_factory.IDWriteFactory, self.dpi, self.font_fallback, effective_primary, effective_font_size_pt);

    self.font_size_pt = effective_font_size_pt;
    self.effective_primary = effective_primary;
    self.effective_user_fallbacks = effective_user_fallbacks;

    const new_cs = measureCellSize(&self.dwrite_factory.IDWriteFactory, self.dpi, effective_primary, effective_font_size_pt);
    self.cell_size = new_cs;
    self.cell_size_xy = .{
        .x = @intCast(new_cs.cx),
        .y = @intCast(new_cs.cy),
    };

    // Font changed: drop the glyph atlas so glyphs re-rasterize at the new face/size.
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
}

pub fn deinit(self: *D3d11Renderer) void {
    self.staging_texture.release();
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
    self.context.Flush();
    if (self.swap_chain) |sc| _ = sc.IUnknown.Release();
    _ = self.d2d_factory.IUnknown.Release();
    _ = self.text_format.IUnknown.Release();
    _ = self.rendering_params.IUnknown.Release();
    _ = self.font_fallback.IUnknown.Release();
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
    tab_bar: []const TabBarCell,
    resizing: bool,
    mouse_in_scrollbar: bool,
    selection_fade: f32,
    cursor_text: ?u24,
    selection_bg: ?u24,
    selection_fg: ?u24,
) void {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);

    // Lazy swap chain init
    if (self.swap_chain == null) {
        self.swap_chain = self.initSwapChain(hwnd, client_w, client_h);
    }
    const swap_chain = self.swap_chain.?;
    if (client_w == 0 or client_h == 0) return;

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
    const shader_row: u32 = @divTrunc(client_h + cs.y - 1, cs.y);
    // Row 0 is reserved for the tab bar; terminal cells render in rows 1..shader_row.
    const term_row_offset: u32 = 1;
    const term_shader_row: u32 = if (shader_row > term_row_offset) shader_row - term_row_offset else 0;

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
    const atlas = self.setupGlyphAtlas();
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
        config.row_count = shader_row;
        // Glyph atlas geometry — the shader uses this to convert a
        // glyph_index to (x,y) in the atlas. Previously the shader
        // called GetDimensions per pixel and divided by cell_size.
        config.cells_per_row = tex_cell_count.x;

        // Compute scrollbar geometry in pixels (within the reserved scrollbar area)
        // Only show the thumb when scrolled up or mouse is hovering over the scrollbar.
        // The grid sits below the tab bar, so the scrollbar's y origin shifts down by one cell.
        const sb = term.screens.active.pages.scrollbar();
        const show_scrollbar = sb.total > sb.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
        if (show_scrollbar) {
            const sb_x: f32 = @floatFromInt(grid_w);
            const sb_w: f32 = @floatFromInt(sb_px);
            const sb_origin_y: f32 = @floatFromInt(cs.y * term_row_offset);
            const win_h: f32 = @floatFromInt(client_h -| (cs.y * term_row_offset));
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

    // Build cell buffer from terminal state
    const cell_count = shader_col * shader_row;
    const blank_glyph = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = ' ', .half = .single });

    // Effective default fg/bg come from the terminal's dynamic colors (seeded
    // from the theme at tab creation, overridable live by OSC 10/11), falling
    // back to the module constants only if somehow unset.
    const eff_fg: u24 = if (term.colors.foreground.get()) |c| rgbToU24(c) else fallback_fg;
    const eff_bg: u24 = if (term.colors.background.get()) |c| rgbToU24(c) else fallback_bg;
    const bg_rgba: Rgba8 = .{
        .r = @intCast((eff_bg >> 16) & 0xFF),
        .g = @intCast((eff_bg >> 8) & 0xFF),
        .b = @intCast(eff_bg & 0xFF),
        .a = 0,
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
        };

        // Tab bar in shader row 0.
        {
            var col: u32 = 0;
            while (col < shader_col) : (col += 1) {
                if (col < tab_bar.len) {
                    const tb = tab_bar[col];
                    scratch[col] = .{
                        .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = tb.codepoint, .half = .single }),
                        .background = tb.bg,
                        .foreground = tb.fg,
                    };
                } else {
                    scratch[col] = blank_cell;
                }
            }
            self.uploadCellRow(0, scratch, force_full);
        }

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
            const cursor_bg_rgba = Rgba8.fromU24(if (term.colors.cursor.get()) |c| rgbToU24(c) else eff_fg);
            const cursor_fg_rgba = Rgba8.fromU24(cursor_text orelse eff_bg);

            var col: u32 = 0;
            for (page_cells) |cell| {
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

                var cell_fg: u24 = eff_fg;
                var cell_bg: u24 = eff_bg;
                // Whether this cell shows the default background and should get
                // the window blur-alpha. Tracked as a flag (not bg-value
                // equality) so a cell explicitly painted with the theme's bg
                // color stays opaque, and inverse video stays opaque too.
                var is_default_bg = true;

                if (cell.style_id != 0) {
                    const style = page.styles.get(page.memory, cell.style_id).*;
                    cell_fg = resolveColor(style.fg_color, palette, eff_fg);
                    cell_bg = resolveColor(style.bg_color, palette, eff_bg);
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
                        cell_bg = rgbToU24(palette[cell.content.color_palette]);
                        is_default_bg = false;
                    },
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
                        is_default_bg = false;
                    },
                    else => {},
                }

                var bg = if (is_default_bg) bg_rgba else Rgba8.fromU24(cell_bg);
                var fg = Rgba8.fromU24(cell_fg);

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
                        bg = lerpRgba8(orig_bg, target_bg, selection_fade);
                        fg = lerpRgba8(fg, target_fg, selection_fade);
                    }
                }

                // Cursor inversion applies to the LOGICAL cell at column `col`.
                // For wide cells both visual halves inherit this so the cursor
                // highlight covers the whole glyph.
                if (cursor_on_row and screen.cursor.x == col) {
                    bg = cursor_bg_rgba;
                    fg = cursor_fg_rgba;
                }

                if (cell.wide == .wide) {
                    scratch[col] = .{
                        .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = codepoint, .half = .wide_left }),
                        .background = bg,
                        .foreground = fg,
                    };
                    col += 1;
                    if (col < shader_col) {
                        scratch[col] = .{
                            .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = codepoint, .half = .wide_right }),
                            .background = bg,
                            .foreground = fg,
                        };
                    }
                    col += 1;
                    continue;
                }

                scratch[col] = .{
                    .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = codepoint, .half = .single }),
                    .background = bg,
                    .foreground = fg,
                };
                col += 1;
            }
            // Fill remaining columns with blanks
            if (col < shader_col) {
                @memset(scratch[col..shader_col], blank_cell);
            }

            const dst_row_offset = (screen_row + term_row_offset) * shader_col;
            self.uploadCellRow(dst_row_offset, scratch, force_full);
        }
        // Fill remaining terminal rows with blanks (offset by tab bar row).
        // The row content is identical across iterations so we build scratch
        // once and let uploadCellRow's diff skip any row whose shadow already
        // matches.
        if (screen_row < term_shader_row) {
            @memset(scratch, blank_cell);
            while (screen_row < term_shader_row) : (screen_row += 1) {
                const dst_row_offset = (screen_row + term_row_offset) * shader_col;
                self.uploadCellRow(dst_row_offset, scratch, force_full);
            }
        }

        // Cursor inversion is applied inline in the per-row cell loop so
        // wide CJK gets both halves flipped, not just the left one.

        // Draw resize overlay (e.g. "80x25") in the terminal region (skip tab bar row).
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
            const box_y_inner = (term_shader_row -| box_h) / 2;
            const box_y = box_y_inner + term_row_offset;

            const tx = box_x + (box_w -| text_len) / 2;
            const ty = box_y + 1;

            var by: u32 = box_y;
            while (by < box_y + box_h and by < shader_row) : (by += 1) {
                const dst_row_offset = by * shader_col;
                @memcpy(scratch, self.shadow_cells[dst_row_offset..][0..shader_col]);

                // Background box on this row.
                var bx: u32 = box_x;
                while (bx < box_x + box_w and bx < shader_col) : (bx += 1) {
                    scratch[bx] = .{
                        .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = ' ', .half = .single }),
                        .background = overlay_bg,
                        .foreground = overlay_fg,
                    };
                }
                // Text on the middle row only.
                if (by == ty) {
                    for (text, 0..) |ch, i| {
                        const tcol = tx + @as(u32, @intCast(i));
                        if (tcol < shader_col) {
                            scratch[tcol] = .{
                                .glyph_index = self.generateGlyph(glyph_cache, tex_cell_count, .{ .codepoint = ch, .half = .single }),
                                .background = overlay_bg,
                                .foreground = overlay_fg,
                            };
                        }
                    }
                }
                self.uploadCellRow(dst_row_offset, scratch, true);
            }
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
    // Clear to transparent black for DWM glass compositing
    {
        const clear_color = [4]f32{ 0, 0, 0, 0 };
        self.context.ClearRenderTargetView(self.target_view.?, @ptrCast(&clear_color));
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

    {
        const hr = swap_chain.IDXGISwapChain.Present(0, 0);
        if (hr < 0) fatalHr("Present", hr);
    }
}

// --- Glyph generation ---

// Frame-invariant glyph atlas setup. Call once per render() so the
// per-cell generateGlyph path does only the cache lookup + miss work.
// Recreates the cache if the cell size changed or the atlas texture
// was reallocated.
const AtlasFrame = struct {
    cache: *GlyphIndexCache,
    tex_cell_count: CellXY,
};

fn setupGlyphAtlas(self: *D3d11Renderer) AtlasFrame {
    const cs = self.cell_size_xy;
    const tex_cell_count = getTextureMaxCellCount(cs);
    const tex_total: u32 = @as(u32, tex_cell_count.x) * @as(u32, tex_cell_count.y);

    const tex_pixel: CellXY = .{
        .x = tex_cell_count.x * cs.x,
        .y = tex_cell_count.y * cs.y,
    };
    const tex_retained = self.glyph_texture.updateSize(self.device, tex_pixel);

    const cache_valid = if (self.glyph_cache_cell_size) |s| s.eql(cs) else false;
    self.glyph_cache_cell_size = cs;

    if (!tex_retained or !cache_valid) {
        if (self.glyph_cache) |*c| {
            c.deinit(self.glyph_cache_arena.allocator());
            _ = self.glyph_cache_arena.reset(.retain_capacity);
            self.glyph_cache = null;
        }
    }

    if (self.glyph_cache == null) {
        self.glyph_cache = GlyphIndexCache.init(
            self.glyph_cache_arena.allocator(),
            tex_total,
        ) catch oom(error.OutOfMemory);
    }

    const cache = &self.glyph_cache.?;
    cache.beginFrame();
    return .{ .cache = cache, .tex_cell_count = tex_cell_count };
}

fn generateGlyph(
    self: *D3d11Renderer,
    cache: *GlyphIndexCache,
    tex_cell_count: CellXY,
    key: GlyphIndexCache.Key,
) u32 {
    const cs = self.cell_size_xy;

    switch (cache.reserve(self.glyph_cache_arena.allocator(), key) catch oom(error.OutOfMemory)) {
        .newly_reserved => |reserved| {
            const pos = cellPosFromIndex(reserved.index, tex_cell_count.x);
            const coord: CellXY = .{ .x = cs.x * pos.x, .y = cs.y * pos.y };

            // Sprite fast path: tile-design codepoints (Block Elements, Box
            // Drawing, Braille, Powerline, Geometric Shapes, Legacy Computing)
            // are rendered procedurally by ghostty's sprite drawing code so
            // they tile seamlessly regardless of the font's natural advance.
            // Block elements out of a font would get squashed by the narrow-
            // Latin cell width and break Claude Code's block-art logo.
            //
            // Render failures must NOT silently return — the reserved atlas
            // slot would otherwise display stale pixels from the evicted
            // glyph. OOM is fatal; any other error falls through to the
            // DirectWrite path so we render *something* into the slot.
            sprite_path: {
                if (!sprite.hasCodepoint(key.codepoint)) break :sprite_path;
                self.uploadSpriteToAtlas(key, coord) catch |err| switch (err) {
                    error.OutOfMemory => oom(error.OutOfMemory),
                    else => {
                        std.log.warn("sprite render U+{X} failed ({s}); falling back to DirectWrite", .{ key.codepoint, @errorName(err) });
                        break :sprite_path;
                    },
                };
                return reserved.index;
            }

            // Render glyph to staging texture (2 cells wide to accommodate wide chars).
            const staging_size: CellXY = .{ .x = cs.x * 2, .y = cs.y };
            const staging = self.staging_texture.getOrCreate(self.device, self.d2d_factory, staging_size);

            const codepoint = key.codepoint;
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 1;

            var utf16_buf: [2]u16 = undefined;
            const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8_buf[0..utf8_len]) catch 0;

            const target_width: f32 = @floatFromInt(
                if (key.half != .single) cs.x * @as(u16, 2) else cs.x,
            );
            const cs_y_f: f32 = @floatFromInt(cs.y);

            // Ambiguous EAW symbols (● ✶ ★ etc. outside the sprite range)
            // render in a single cell with ink-bounds best-fit + center
            // alignment + center-anchored uniform scale. This produces round
            // (not squashed) symbols of consistent size within a row,
            // matching WezTerm's per-cell layout where every ● looks the
            // same regardless of what surrounds it. Each symbol stays inside
            // its own cell so adjacent letters / underscores / other symbols
            // remain fully visible.
            const is_ambiguous_symbol = sprite.isAmbiguousOverflow(key.codepoint);

            // IDWriteTextLayout lets us measure the rendered ink before drawing.
            var layout: *win32.IDWriteTextLayout = undefined;
            {
                const hr = self.dwrite_factory.IDWriteFactory.CreateTextLayout(
                    @ptrCast(utf16_buf[0..utf16_len].ptr),
                    @intCast(utf16_len),
                    self.text_format,
                    target_width,
                    cs_y_f,
                    &layout,
                );
                if (hr < 0) fatalHr("CreateTextLayout", hr);
            }
            defer _ = layout.IUnknown.Release();

            // For ambiguous symbols, center the glyph in its single cell so
            // the center-anchored scale transform expands uniformly around
            // the cell centre. Alignment must be set BEFORE measuring so the
            // overhang values reflect the centered layout.
            if (is_ambiguous_symbol) {
                const ahr = layout.IDWriteTextFormat.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
                if (ahr < 0) fatalHr("SetTextAlignment", ahr);
                const pahr = layout.IDWriteTextFormat.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
                if (pahr < 0) fatalHr("SetParagraphAlignment", pahr);
            }

            var m: win32.DWRITE_TEXT_METRICS = undefined;
            {
                const hr = layout.GetMetrics(&m);
                if (hr < 0) fatalHr("GetMetrics", hr);
            }
            var oh: win32.DWRITE_OVERHANG_METRICS = undefined;
            {
                const hr = layout.GetOverhangMetrics(&oh);
                if (hr < 0) fatalHr("GetOverhangMetrics", hr);
            }

            // Two scale policies share the rendering setup below:
            //
            //   * Non-ambiguous (CJK real wide, Latin, fallback narrow glyphs
            //     in a single cell): only scale DOWN when natural advance
            //     exceeds the target cell width. fit_width captures advance +
            //     right ink overhang so CLIP doesn't chop overhanging strokes.
            //
            //   * Ambiguous symbols (●✶★ etc.): ink-box best-fit within the
            //     single cell, allow scale > 1 to enlarge narrow naturals so
            //     the glyph fills the cell instead of sitting tiny and
            //     left-aligned. Cap at SCALE_CAP = 2.0 so a 1-pixel glyph
            //     can't blow up into a giant blur.
            const SCALE_CAP: f32 = 2.0;
            const content_right = m.left + @max(m.width, m.widthIncludingTrailingWhitespace);
            const overhang_right = m.layoutWidth + @max(0.0, oh.right);
            const fit_width = @max(content_right, overhang_right);

            // Ink bounds via raw (signed) overhangs against the layout box;
            // negative overhang = ink inset from box edge. Same formula works
            // for LEFT and CENTER alignment because overhangs adjust to the
            // text's position within the box.
            const ink_w = m.layoutWidth + oh.left + oh.right;
            const ink_h = m.layoutHeight + oh.top + oh.bottom;
            const ink_ok = ink_w > 0 and ink_h > 0 and std.math.isFinite(ink_w) and std.math.isFinite(ink_h);

            const raw_scale: f32 = if (is_ambiguous_symbol) blk: {
                if (!ink_ok) break :blk 1.0;
                const sw = target_width / ink_w;
                const sh = cs_y_f / ink_h;
                break :blk @min(@min(sw, sh), SCALE_CAP);
            } else if (fit_width > target_width and fit_width > 0)
                target_width / fit_width
            else
                1.0;
            // Snap near-unity to 1.0 to skip a no-op transform.
            const need_scale = @abs(raw_scale - 1.0) > 0.001;
            const scale: f32 = if (need_scale) raw_scale else 1.0;

            if (need_scale and !is_ambiguous_symbol) {
                // Non-ambiguous scale-down path: expand the layout box so the
                // CLIP boundary == fit_width pre-scale, becoming target_width
                // post-scale. Ambiguous-symbol path leaves the layout box at
                // the original target_width because center alignment + center
                // anchor handle positioning without box expansion.
                const hr = layout.SetMaxWidth(fit_width);
                if (hr < 0) fatalHr("SetMaxWidth", hr);
            }

            // Invariant: every render starts from identity transform & CLEARTYPE.
            // The staging RT is reused across cache misses, so leaking state
            // between calls would corrupt subsequent glyphs.
            const identity: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
                .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0,
            } } };
            staging.render_target.SetTransform(&identity);
            staging.render_target.SetTextRenderingParams(self.rendering_params);
            staging.render_target.SetTextAntialiasMode(.CLEARTYPE);
            staging.render_target.BeginDraw();
            {
                // Opaque black background; rendering white-on-black through
                // ClearType yields per-subpixel coverage as the stored RGB
                // (white·cov + black·(1-cov) = cov). The shader decodes via
                // `c*c` (gamma 2.0) to undo D2D's gamma encode. Grayscale
                // fills R=G=B equally, so the same decode still produces
                // uniform coverage.
                const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                staging.render_target.Clear(&color);
            }

            if (need_scale) {
                // ClearType subpixel hinting assumes 1:1 horizontal mapping;
                // any fractional scale would produce colored fringes. Grayscale
                // antialiasing has no subpixel directionality.
                staging.render_target.SetTextAntialiasMode(.GRAYSCALE);

                // Three anchor strategies, chosen by glyph context:
                //   ambiguous symbol  → center anchor (cell centre stays fixed
                //     so round shapes like ● stay visually centered)
                //   single, non-ambiguous → horizontal-only (m22 = 1, dy = 0)
                //     preserves vertical fill so non-sprite tile-design glyphs
                //     (rare math / line-drawing chars outside the sprite face)
                //     still touch the top and bottom of the cell.
                //   wide, non-ambiguous → uniform + baseline anchor (CJK /
                //     emoji) so the scaled glyph shares a baseline with
                //     un-scaled Latin in adjacent cells.
                const scale_mat: win32.D2D_MATRIX_3X2_F = if (is_ambiguous_symbol) blk: {
                    const cx = target_width / 2.0;
                    const cy = cs_y_f / 2.0;
                    break :blk .{ .Anonymous = .{ .Anonymous1 = .{
                        .m11 = scale,
                        .m12 = 0,
                        .m21 = 0,
                        .m22 = scale,
                        .dx = cx * (1.0 - scale),
                        .dy = cy * (1.0 - scale),
                    } } };
                } else if (key.half == .single) .{
                    .Anonymous = .{ .Anonymous1 = .{
                        .m11 = scale,
                        .m12 = 0,
                        .m21 = 0,
                        .m22 = 1,
                        .dx = 0,
                        .dy = 0,
                    } },
                } else blk: {
                    var lm: [1]win32.DWRITE_LINE_METRICS = undefined;
                    var line_count: u32 = 0;
                    const lhr = layout.GetLineMetrics(&lm, 1, &line_count);
                    if (lhr < 0) fatalHr("GetLineMetrics", lhr);
                    const baseline: f32 = if (line_count >= 1) lm[0].baseline else 0;
                    break :blk .{ .Anonymous = .{ .Anonymous1 = .{
                        .m11 = scale,
                        .m12 = 0,
                        .m21 = 0,
                        .m22 = scale,
                        .dx = 0,
                        .dy = baseline * (1.0 - scale),
                    } } };
                };
                staging.render_target.SetTransform(&scale_mat);
            }

            // CLIP boundary semantics:
            //   non-ambiguous → CLIP at the (expanded) layout box, which the
            //                   scale-down transform shrinks back to target_w.
            //   ambiguous     → no CLIP. With scale > 1 + center alignment
            //                   the scaled ink may briefly extend past the
            //                   layout box; the staging texture acts as the
            //                   natural drawing bound.
            const draw_options: win32.D2D1_DRAW_TEXT_OPTIONS = if (is_ambiguous_symbol)
                .{} // no options
            else
                win32.D2D1_DRAW_TEXT_OPTIONS_CLIP;
            staging.render_target.DrawTextLayout(
                .{ .x = 0, .y = 0 },
                layout,
                &staging.white_brush.ID2D1Brush,
                draw_options,
            );

            // Reset before EndDraw so the next cache-miss starts clean.
            staging.render_target.SetTransform(&identity);
            if (need_scale) staging.render_target.SetTextAntialiasMode(.CLEARTYPE);

            var tag1: u64 = undefined;
            var tag2: u64 = undefined;
            const ehr = staging.render_target.EndDraw(&tag1, &tag2);
            if (ehr < 0) fatalHr("EndDraw", ehr);

            // Copy the appropriate portion from staging to atlas
            const src_left: u32 = if (key.half == .wide_right) cs.x else 0;
            const box: win32.D3D11_BOX = .{
                .left = src_left,
                .top = 0,
                .front = 0,
                .right = src_left + cs.x,
                .bottom = cs.y,
                .back = 1,
            };
            self.context.CopySubresourceRegion(
                &self.glyph_texture.obj.?.ID3D11Resource,
                0,
                coord.x,
                coord.y,
                0,
                &staging.texture.ID3D11Resource,
                0,
                &box,
            );

            return reserved.index;
        },
        .already_reserved => |index| return index,
    }
}

// Render a sprite (Block Elements / Box Drawing / Braille / Powerline /
// Geometric Shapes / Legacy Computing) into a CPU BGRA buffer, then copy
// the half indicated by `key.half` directly into the atlas slot at `coord`.
//
// Wide sprites are rasterized full-width (2*cs.x) once and the appropriate
// half is uploaded; matches the same .wide_left / .wide_right split used by
// the DirectWrite path.
fn uploadSpriteToAtlas(self: *D3d11Renderer, key: GlyphIndexCache.Key, coord: CellXY) !void {
    const cs = self.cell_size_xy;
    const sprite_cell_w: u32 = if (key.half != .single) @as(u32, cs.x) * 2 else cs.x;
    const sprite_cell_h: u32 = cs.y;

    var scratch_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch_arena.deinit();
    const arena_alloc = scratch_arena.allocator();

    const scratch = try arena_alloc.alloc(u8, sprite_cell_w * sprite_cell_h * 4);
    const metrics = sprite.buildMetrics(sprite_cell_w, sprite_cell_h);
    // Errors propagate so the dispatch site can fall back to DirectWrite for
    // any non-OOM failure. hasCodepoint already gated entry, so a false
    // return from render would mean ranges/dispatch disagree — unreachable.
    const rendered = try sprite.render(arena_alloc, key.codepoint, sprite_cell_w, sprite_cell_h, metrics, scratch);
    std.debug.assert(rendered);

    // Pick the half-cell slice of the scratch buffer that corresponds to
    // this atlas slot. The source row pitch stays sprite_cell_w*4 so
    // UpdateSubresource walks the full row and only copies cs.x*4 bytes per
    // row starting at the offset we pass via src pointer arithmetic.
    const src_offset_x: u32 = if (key.half == .wide_right) cs.x else 0;
    const src_row_pitch: u32 = sprite_cell_w * 4;
    const src_ptr: [*]const u8 = scratch.ptr + (src_offset_x * 4);

    const dst_box: win32.D3D11_BOX = .{
        .left = coord.x,
        .top = coord.y,
        .front = 0,
        .right = coord.x + cs.x,
        .bottom = coord.y + cs.y,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.glyph_texture.obj.?.ID3D11Resource,
        0,
        &dst_box,
        @ptrCast(src_ptr),
        src_row_pitch,
        0,
    );
}

// --- Swap chain ---

fn initSwapChain(self: *D3d11Renderer, hwnd: win32.HWND, width: u32, height: u32) *win32.IDXGISwapChain2 {
    const dxgi_device = queryInterface(self.device, win32.IDXGIDevice);
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
    defer _ = back_buffer.IUnknown.Release();

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

// --- Internal types ---

const ShaderCells = struct {
    count: u32 = 0,
    cell_buf: *win32.ID3D11Buffer = undefined,
    cell_view: *win32.ID3D11ShaderResourceView = undefined,

    /// Returns true when the underlying buffer was (re)created, signaling
    /// the caller that the CPU shadow must be reseeded by a forced full
    /// upload this frame.
    fn updateCount(self: *ShaderCells, device: *win32.ID3D11Device, count: u32) bool {
        if (count == self.count) return false;
        self.release();
        if (count > 0) {
            const buf_desc: win32.D3D11_BUFFER_DESC = .{
                .ByteWidth = count * @sizeOf(shader.Cell),
                // DEFAULT + UpdateSubresource: row-level partial writes,
                // unchanged rows skipped via shadow diff. Previously DYNAMIC
                // + Map(WRITE_DISCARD) forced full-buffer rewrite per frame.
                .Usage = .DEFAULT,
                .BindFlags = .{ .SHADER_RESOURCE = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{ .BUFFER_STRUCTURED = 1 },
                .StructureByteStride = @sizeOf(shader.Cell),
            };
            const hr = device.CreateBuffer(&buf_desc, null, &self.cell_buf);
            if (hr < 0) fatalHr("CreateCellBuffer", hr);

            const view_desc: win32.D3D11_SHADER_RESOURCE_VIEW_DESC = .{
                .Format = .UNKNOWN,
                .ViewDimension = ._SRV_DIMENSION_BUFFER,
                .Anonymous = .{
                    .Buffer = .{
                        .Anonymous1 = .{ .FirstElement = 0 },
                        .Anonymous2 = .{ .NumElements = count },
                    },
                },
            };
            const hr2 = device.CreateShaderResourceView(
                &self.cell_buf.ID3D11Resource,
                &view_desc,
                &self.cell_view,
            );
            if (hr2 < 0) fatalHr("CreateCellView", hr2);
        }
        self.count = count;
        return true;
    }

    fn release(self: *ShaderCells) void {
        if (self.count != 0) {
            _ = self.cell_view.IUnknown.Release();
            _ = self.cell_buf.IUnknown.Release();
            self.count = 0;
        }
    }
};

const GlyphTexture = struct {
    size: ?CellXY = null,
    obj: ?*win32.ID3D11Texture2D = null,
    view: ?*win32.ID3D11ShaderResourceView = null,

    fn updateSize(self: *GlyphTexture, device: *win32.ID3D11Device, size: CellXY) bool {
        if (self.size) |s| {
            if (s.eql(size)) return true;
            self.release();
        }

        const desc: win32.D3D11_TEXTURE2D_DESC = .{
            .Width = size.x,
            .Height = size.y,
            .MipLevels = 1,
            .ArraySize = 1,
            .Format = .B8G8R8A8_UNORM,
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .Usage = .DEFAULT,
            .BindFlags = .{ .SHADER_RESOURCE = 1 },
            .CPUAccessFlags = .{},
            .MiscFlags = .{},
        };
        var obj: *win32.ID3D11Texture2D = undefined;
        const hr = device.CreateTexture2D(&desc, null, &obj);
        if (hr < 0) fatalHr("CreateGlyphTexture", hr);
        self.obj = obj;

        var view: *win32.ID3D11ShaderResourceView = undefined;
        const hr2 = device.CreateShaderResourceView(&obj.ID3D11Resource, null, &view);
        if (hr2 < 0) fatalHr("CreateGlyphView", hr2);
        self.view = view;

        self.size = size;
        return false;
    }

    fn release(self: *GlyphTexture) void {
        if (self.view) |v| _ = v.IUnknown.Release();
        if (self.obj) |o| _ = o.IUnknown.Release();
        self.view = null;
        self.obj = null;
        self.size = null;
    }
};

const StagingTexture = struct {
    const Cached = struct {
        size: CellXY,
        texture: *win32.ID3D11Texture2D,
        render_target: *win32.ID2D1RenderTarget,
        white_brush: *win32.ID2D1SolidColorBrush,
    };
    cached: ?Cached = null,

    fn getOrCreate(
        self: *StagingTexture,
        device: *win32.ID3D11Device,
        d2d_factory: *win32.ID2D1Factory,
        size: CellXY,
    ) *Cached {
        if (self.cached) |*c| {
            if (c.size.eql(size)) return c;
            self.release();
        }

        var texture: *win32.ID3D11Texture2D = undefined;
        {
            const desc: win32.D3D11_TEXTURE2D_DESC = .{
                .Width = size.x,
                .Height = size.y,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = .B8G8R8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = .DEFAULT,
                .BindFlags = .{ .RENDER_TARGET = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{},
            };
            const hr = device.CreateTexture2D(&desc, null, &texture);
            if (hr < 0) fatalHr("CreateStagingTexture", hr);
        }

        const dxgi_surface = queryInterface(texture, win32.IDXGISurface);
        defer _ = dxgi_surface.IUnknown.Release();

        var render_target: *win32.ID2D1RenderTarget = undefined;
        {
            // IGNORE alpha mode: D2D treats the surface as opaque so it will
            // emit ClearType (it falls back to grayscale on alpha-aware
            // targets). The opaque-black clear below provides the contrast
            // needed to extract per-channel coverage from the RGB values.
            // Pin DPI to 96 so IDWriteTextLayout's DIP-based maxWidth/maxHeight
            // map 1:1 to staging-texture pixels (cell metrics are in pixels).
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .IGNORE },
                .dpiX = 96.0,
                .dpiY = 96.0,
                .usage = .{},
                .minLevel = .DEFAULT,
            };
            const hr = d2d_factory.CreateDxgiSurfaceRenderTarget(dxgi_surface, &props, &render_target);
            if (hr < 0) fatalHr("CreateDxgiSurfaceRenderTarget", hr);
        }

        // Set pixel unit mode
        const dc = queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

        var white_brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const hr = render_target.CreateSolidColorBrush(
                &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                null,
                &white_brush,
            );
            if (hr < 0) fatalHr("CreateBrush", hr);
        }

        self.cached = .{
            .size = size,
            .texture = texture,
            .render_target = render_target,
            .white_brush = white_brush,
        };
        return &self.cached.?;
    }

    fn release(self: *StagingTexture) void {
        if (self.cached) |*c| {
            _ = c.white_brush.IUnknown.Release();
            _ = c.render_target.IUnknown.Release();
            _ = c.texture.IUnknown.Release();
            self.cached = null;
        }
    }
};

// --- Helpers ---

fn compileShaderBlob(
    source: []const u8,
    entry: [*:0]const u8,
    target: [*:0]const u8,
) *win32.ID3DBlob {
    var blob: *win32.ID3DBlob = undefined;
    var error_blob: ?*win32.ID3DBlob = null;
    const hr = win32.D3DCompile(
        source.ptr,
        source.len,
        "terminal.hlsl",
        null,
        null,
        entry,
        target,
        0,
        0,
        @ptrCast(&blob),
        @ptrCast(&error_blob),
    );
    if (error_blob) |err| {
        defer _ = err.IUnknown.Release();
        if (err.GetBufferPointer()) |buf_ptr| {
            const ptr: [*]const u8 = @ptrCast(buf_ptr);
            const str = ptr[0..err.GetBufferSize()];
            log.err("shader error:\n{s}", .{str});
        }
    }
    if (hr < 0) fatalHr("D3DCompile", hr);
    return blob;
}

fn getTextureMaxCellCount(cell_size: CellXY) CellXY {
    // Cap the atlas to 4096² (≈64 MiB at BGRA8). At typical cell sizes this
    // holds ~75k glyphs, far above any realistic terminal session. Each
    // dimension is clamped to ≥2 because GlyphIndexCache requires at least
    // two nodes (head + tail) for its circular-list bookkeeping.
    const max_dim: u32 = 4096;
    const cx: u32 = @max(2, @divTrunc(max_dim, @as(u32, cell_size.x)));
    const cy: u32 = @max(2, @divTrunc(max_dim, @as(u32, cell_size.y)));
    return .{ .x = @intCast(cx), .y = @intCast(cy) };
}

fn cellPosFromIndex(index: u32, column_count: u16) CellXY {
    return .{
        .x = @intCast(index % column_count),
        .y = @intCast(@divTrunc(index, column_count)),
    };
}

fn queryInterface(obj: anytype, comptime Interface: type) *Interface {
    const iid_name = comptime blk: {
        const name = @typeName(Interface);
        const start = if (std.mem.lastIndexOfScalar(u8, name, '.')) |i| (i + 1) else 0;
        break :blk "IID_" ++ name[start..];
    };
    const iid = @field(win32, iid_name);
    var iface: *Interface = undefined;
    const hr = obj.IUnknown.QueryInterface(iid, @ptrCast(&iface));
    if (hr < 0) fatalHr("QueryInterface", hr);
    return iface;
}


fn resolveColor(c: vt.Style.Color, palette: *const vt.color.Palette, default: u24) u24 {
    return switch (c) {
        .none => default,
        .palette => |idx| rgbToU24(palette[idx]),
        .rgb => |rgb| rgbToU24(rgb),
    };
}

fn rgbToU24(rgb: vt.color.RGB) u24 {
    return @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
}

fn fatalHr(what: []const u8, hresult: win32.HRESULT) noreturn {
    std.debug.panic("{s} failed, hresult=0x{x}", .{ what, @as(u32, @bitCast(hresult)) });
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
    )) return;
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

fn lerpRgba8(a: Rgba8, b: Rgba8, t: f32) Rgba8 {
    return .{
        .r = lerpU8(a.r, b.r, t),
        .g = lerpU8(a.g, b.g, t),
        .b = lerpU8(a.b, b.b, t),
        .a = lerpU8(a.a, b.a, t),
    };
}

fn lerpU8(a: u8, b: u8, t: f32) u8 {
    const af: f32 = @floatFromInt(a);
    const bf: f32 = @floatFromInt(b);
    return @intFromFloat(af + (bf - af) * t);
}

fn oom(e: error{OutOfMemory}) noreturn {
    @panic(@errorName(e));
}
