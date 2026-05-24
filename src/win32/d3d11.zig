const D3d11Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphIndexCache = @import("GlyphIndexCache.zig");

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

const default_fg: u24 = 0xc8c4d0;
const default_bg: u24 = 0x2a2a2a;

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
glyph_texture: GlyphTexture = .{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
staging_texture: StagingTexture = .{},

cell_size: win32.SIZE,
cell_size_xy: CellXY,

const scrollbar_logical_width: u16 = 14;

pub fn scrollbarWidth(dpi: u32) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scrollbar_logical_width)) * @as(f32, @floatFromInt(dpi)) / 96.0));
}

fn measureCellSize(dwrite_factory: *win32.IDWriteFactory, dpi: u32) win32.SIZE {
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
        const hr = system_collection.FindFamilyName(primary_font_family, &family_index, &family_exists);
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

    const font_size_dips = fontSizeDips(dpi);
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
const primary_font_family = win32.L("Rec Mono Casual");
const font_size_pt: f32 = 13.0;

// Computes the font size to pass to CreateTextFormat. CreateTextFormat
// nominally takes DIPs (1/96 inch), and our config is in points (1/72 inch),
// so we convert pt -> DIPs (x 96/72) then apply DPI scaling for the monitor.
// Note: the staging render target runs in D2D1_UNIT_MODE_PIXELS, which makes
// the value we return coincide with physical pixels for our specific draw
// path. The name "Dips" reflects the API contract, not the eventual unit.
fn fontSizeDips(dpi: u32) f32 {
    return win32.scaleDpi(f32, font_size_pt * 96.0 / 72.0, dpi);
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

const font_fallback_families = blk: {
    // Each win32.L() runs utf8ToUtf16LeStringLiteralImpl at comptime; the
    // cumulative branch count for the whole list exceeds the default 2000.
    @setEvalBranchQuota(10000);
    break :blk [_][*:0]const u16{
        // CJK
        win32.L("LXGW WenKai Mono GB"),
        win32.L("Sarasa Mono SC"),
        win32.L("Microsoft YaHei"),
        win32.L("Noto Sans CJK SC"),
        // Nerd Font / Powerline / icons
        win32.L("Symbols Nerd Font Mono"),
        win32.L("Symbols Nerd Font"),
        // Emoji
        win32.L("Segoe UI Emoji"),
        win32.L("Noto Color Emoji"),
    };
};

fn createTextFormat(
    dwrite_factory: *win32.IDWriteFactory,
    dpi: u32,
    font_fallback: *win32.IDWriteFontFallback,
) *win32.IDWriteTextFormat {
    var text_format: *win32.IDWriteTextFormat = undefined;
    const hr = dwrite_factory.CreateTextFormat(
        primary_font_family,
        null,
        .NORMAL,
        .NORMAL,
        .NORMAL,
        fontSizeDips(dpi),
        win32.L(""),
        &text_format,
    );
    if (hr < 0) fatalHr("CreateTextFormat", hr);

    // Attach our custom fallback chain so CJK / Nerd Font / Emoji glyphs render.
    const text_format1 = queryInterface(text_format, win32.IDWriteTextFormat1);
    defer _ = text_format1.IUnknown.Release();
    const sfhr = text_format1.SetFontFallback(font_fallback);
    if (sfhr < 0) fatalHr("SetFontFallback", sfhr);

    return text_format;
}

// Custom rendering parameters so the atlas is reproducible across machines
// and aligns with the shader's gamma 2.2 decode of the ClearType mask.
// `enhanced_contrast=0` removes D2D's non-invertible contrast curve so the
// stored mask is a predictable function of coverage; `RGB` stripe and
// `NATURAL_SYMMETRIC` rendering mode pick the standard subpixel layout and
// the best horizontal subpixel positioning (experimental — can fall back
// to `NATURAL` if vertical edges look soft on a given monitor).
fn buildRenderingParams(factory: *win32.IDWriteFactory) *win32.IDWriteRenderingParams {
    var params: *win32.IDWriteRenderingParams = undefined;
    const hr = factory.CreateCustomRenderingParams(
        2.2,
        0.0,
        1.0,
        win32.DWRITE_PIXEL_GEOMETRY_RGB,
        win32.DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC,
        &params,
    );
    if (hr < 0) fatalHr("CreateCustomRenderingParams", hr);
    return params;
}

fn buildFontFallback(factory: *win32.IDWriteFactory2) *win32.IDWriteFontFallback {
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
    var family_ptrs: [font_fallback_families.len]?*const u16 = undefined;
    for (font_fallback_families, 0..) |family, i| {
        family_ptrs[i] = @ptrCast(family);
    }
    const full_range = win32.DWRITE_UNICODE_RANGE{ .first = 0, .last = 0x10FFFF };
    {
        const hr = builder.AddMapping(
            @ptrCast(&full_range),
            1,
            &family_ptrs,
            family_ptrs.len,
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
    return measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi);
}

const CellXY = struct {
    x: u16,
    y: u16,
    fn eql(a: CellXY, b: CellXY) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub fn init(dpi: u32) D3d11Renderer {
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

    const font_fallback = buildFontFallback(dwrite_factory);
    const rendering_params = buildRenderingParams(&dwrite_factory.IDWriteFactory);
    const text_format = createTextFormat(&dwrite_factory.IDWriteFactory, dpi, font_fallback);

    const cell_size = measureCellSize(&dwrite_factory.IDWriteFactory, dpi);
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
    };
}

pub fn updateDpi(self: *D3d11Renderer, dpi: u32) void {
    if (dpi == self.dpi) return;
    _ = self.text_format.IUnknown.Release();
    self.text_format = createTextFormat(&self.dwrite_factory.IDWriteFactory, dpi, self.font_fallback);
    self.dpi = dpi;

    const new_cs = measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi);
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

pub fn deinit(self: *D3d11Renderer) void {
    self.staging_texture.release();
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_texture.release();
    self.shader_cells.release();
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
    const blank_glyph = self.generateGlyph(.{ .codepoint = ' ', .half = .single });
    const bg_rgba: Rgba8 = .{
        .r = @intCast((default_bg >> 16) & 0xFF),
        .g = @intCast((default_bg >> 8) & 0xFF),
        .b = @intCast(default_bg & 0xFF),
        .a = 0,
    };

    self.shader_cells.updateCount(self.device, cell_count);
    if (cell_count > 0) {
        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.Map(
            &self.shader_cells.cell_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) fatalHr("MapCellBuffer", hr);
        defer self.context.Unmap(&self.shader_cells.cell_buf.ID3D11Resource, 0);

        const cells_out: [*]shader.Cell = @ptrCast(@alignCast(mapped.pData));

        // Tab bar in shader row 0.
        {
            var col: u32 = 0;
            while (col < shader_col) : (col += 1) {
                if (col < tab_bar.len) {
                    const tb = tab_bar[col];
                    cells_out[col] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = tb.codepoint, .half = .single }),
                        .background = tb.bg,
                        .foreground = tb.fg,
                    };
                } else {
                    cells_out[col] = .{
                        .glyph_index = blank_glyph,
                        .background = bg_rgba,
                        .foreground = bg_rgba,
                    };
                }
            }
        }

        const screen = term.screens.active;
        const palette = &term.colors.palette.current;
        var row_it = screen.pages.rowIterator(.right_down, .{ .viewport = .{} }, null);
        var screen_row: u32 = 0;
        while (row_it.next()) |row_pin| {
            defer screen_row += 1;
            if (screen_row >= term_shader_row) break;

            const page = &row_pin.node.data;
            const page_cells = page.getCells(row_pin.rowAndCell().row);
            const dst_row_offset = (screen_row + term_row_offset) * shader_col;

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

                var cell_fg: u24 = default_fg;
                var cell_bg: u24 = default_bg;

                if (cell.style_id != 0) {
                    const style = page.styles.get(page.memory, cell.style_id).*;
                    cell_fg = resolveColor(style.fg_color, palette, default_fg);
                    cell_bg = resolveColor(style.bg_color, palette, default_bg);
                    if (style.flags.inverse) {
                        const tmp = cell_fg;
                        cell_fg = cell_bg;
                        cell_bg = tmp;
                    }
                }

                switch (cell.content_tag) {
                    .bg_color_palette => cell_bg = rgbToU24(palette[cell.content.color_palette]),
                    .bg_color_rgb => {
                        const rgb = cell.content.color_rgb;
                        cell_bg = @as(u24, rgb.r) << 16 | @as(u24, rgb.g) << 8 | rgb.b;
                    },
                    else => {},
                }

                var bg = if (cell_bg == default_bg) bg_rgba else Rgba8.fromU24(cell_bg);
                var fg = Rgba8.fromU24(cell_fg);

                // Highlight selected cells (with fade)
                if (screen.selection) |sel| {
                    var cell_pin = row_pin;
                    cell_pin.x = @intCast(col);
                    if (sel.contains(screen, cell_pin)) {
                        const orig_bg = bg;
                        var sel_bg = fg;
                        sel_bg.a = 255;
                        var sel_fg = orig_bg;
                        sel_fg.a = 255;
                        bg = lerpRgba8(orig_bg, sel_bg, selection_fade);
                        fg = lerpRgba8(fg, sel_fg, selection_fade);
                    }
                }

                if (cell.wide == .wide) {
                    cells_out[dst_row_offset + col] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .wide_left }),
                        .background = bg,
                        .foreground = fg,
                    };
                    col += 1;
                    if (col < shader_col) {
                        cells_out[dst_row_offset + col] = .{
                            .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .wide_right }),
                            .background = bg,
                            .foreground = fg,
                        };
                    }
                } else {
                    cells_out[dst_row_offset + col] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = codepoint, .half = .single }),
                        .background = bg,
                        .foreground = fg,
                    };
                }
                col += 1;
            }
            // Fill remaining columns with blanks
            while (col < shader_col) : (col += 1) {
                cells_out[dst_row_offset + col] = .{
                    .glyph_index = blank_glyph,
                    .background = bg_rgba,
                    .foreground = bg_rgba,
                };
            }
        }
        // Fill remaining terminal rows with blanks (offset by tab bar row)
        while (screen_row < term_shader_row) : (screen_row += 1) {
            const dst_row_offset = (screen_row + term_row_offset) * shader_col;
            @memset(cells_out[dst_row_offset..][0..shader_col], shader.Cell{
                .glyph_index = blank_glyph,
                .background = bg_rgba,
                .foreground = bg_rgba,
            });
        }

        // Draw cursor
        if (screen.viewportIsBottom() and term.modes.get(.cursor_visible)) {
            const cx: u32 = screen.cursor.x;
            const cy: u32 = screen.cursor.y;
            if (cy < term_shader_row and cx < shader_col) {
                const idx = (cy + term_row_offset) * shader_col + cx;
                cells_out[idx].background = Rgba8.fromU24(default_fg);
                cells_out[idx].foreground = Rgba8.fromU24(default_bg);
            }
        }

        // Draw resize overlay (e.g. "80x25") in the terminal region (skip tab bar row).
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

            // Draw background box
            var by: u32 = box_y;
            while (by < box_y + box_h and by < shader_row) : (by += 1) {
                var bx: u32 = box_x;
                while (bx < box_x + box_w and bx < shader_col) : (bx += 1) {
                    cells_out[by * shader_col + bx] = .{
                        .glyph_index = self.generateGlyph(.{ .codepoint = ' ', .half = .single }),
                        .background = overlay_bg,
                        .foreground = overlay_fg,
                    };
                }
            }

            // Draw text centered
            const tx = box_x + (box_w -| text_len) / 2;
            const ty = box_y + 1;
            if (ty < shader_row) {
                for (text, 0..) |ch, i| {
                    const col = tx + @as(u32, @intCast(i));
                    if (col < shader_col) {
                        cells_out[ty * shader_col + col] = .{
                            .glyph_index = self.generateGlyph(.{ .codepoint = ch, .half = .single }),
                            .background = overlay_bg,
                            .foreground = overlay_fg,
                        };
                    }
                }
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

fn generateGlyph(self: *D3d11Renderer, key: GlyphIndexCache.Key) u32 {
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

    const cache = blk: {
        if (self.glyph_cache) |*c| break :blk c;
        self.glyph_cache = GlyphIndexCache.init(
            self.glyph_cache_arena.allocator(),
            tex_total,
        ) catch oom(error.OutOfMemory);
        break :blk &(self.glyph_cache.?);
    };

    switch (cache.reserve(self.glyph_cache_arena.allocator(), key) catch oom(error.OutOfMemory)) {
        .newly_reserved => |reserved| {
            const pos = cellPosFromIndex(reserved.index, tex_cell_count.x);
            const coord: CellXY = .{ .x = cs.x * pos.x, .y = cs.y * pos.y };

            // Render glyph to staging texture (2 cells wide to accommodate wide chars).
            const staging_size: CellXY = .{ .x = cs.x * 2, .y = cs.y };
            const staging = self.staging_texture.getOrCreate(self.device, self.d2d_factory, staging_size);

            const codepoint = key.codepoint;
            var utf8_buf: [4]u8 = undefined;
            const utf8_len = std.unicode.utf8Encode(codepoint, &utf8_buf) catch 1;

            var utf16_buf: [2]u16 = undefined;
            const utf16_len = std.unicode.utf8ToUtf16Le(&utf16_buf, utf8_buf[0..utf8_len]) catch 0;

            // Render at natural advance. Fallback glyphs that don't match the
            // cell width clip (or underfill) rather than being scaled, which
            // would destroy hinting.
            const target_width: f32 = @floatFromInt(
                if (key.half != .single) cs.x * @as(u16, 2) else cs.x,
            );

            staging.render_target.SetTextRenderingParams(self.rendering_params);
            staging.render_target.SetTextAntialiasMode(.CLEARTYPE);
            staging.render_target.BeginDraw();
            {
                // Opaque black background; rendering white-on-black through
                // ClearType yields per-subpixel coverage as the stored RGB
                // (white·cov + black·(1-cov) = cov). The shader decodes via
                // pow(2.2) to undo D2D's gamma encode.
                const color: win32.D2D_COLOR_F = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
                staging.render_target.Clear(&color);
            }
            staging.render_target.DrawText(
                @ptrCast(utf16_buf[0..utf16_len].ptr),
                @intCast(utf16_len),
                self.text_format,
                &.{
                    .left = 0,
                    .top = 0,
                    .right = target_width,
                    .bottom = @floatFromInt(cs.y),
                },
                &staging.white_brush.ID2D1Brush,
                .{},
                .NATURAL,
            );
            var tag1: u64 = undefined;
            var tag2: u64 = undefined;
            _ = staging.render_target.EndDraw(&tag1, &tag2);

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

    fn updateCount(self: *ShaderCells, device: *win32.ID3D11Device, count: u32) void {
        if (count == self.count) return;
        self.release();
        if (count > 0) {
            const buf_desc: win32.D3D11_BUFFER_DESC = .{
                .ByteWidth = count * @sizeOf(shader.Cell),
                .Usage = .DYNAMIC,
                .BindFlags = .{ .SHADER_RESOURCE = 1 },
                .CPUAccessFlags = .{ .WRITE = 1 },
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
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .IGNORE },
                .dpiX = 0,
                .dpiY = 0,
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
