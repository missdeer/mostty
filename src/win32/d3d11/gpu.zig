//! Raw D3D11 / DXGI / Direct2D resource types and pure GPU-geometry helpers.
//!
//! Pure data plus self-contained method-style structs that only know their
//! own D3D resources (no renderer back-reference). Shared shader contract
//! (`shader.Cell`, `cell_attr_*`, `Rgba8`) lives here so every module that
//! builds cells agrees on the same byte layout.

const std = @import("std");
const win32 = @import("win32").everything;
const com = @import("com.zig");

const log = std.log.scoped(.d3d);

pub const CellXY = struct {
    x: u16,
    y: u16,
    pub fn eql(a: CellXY, b: CellXY) bool {
        return a.x == b.x and a.y == b.y;
    }
};

pub const Rgba8 = packed struct(u32) {
    a: u8,
    b: u8,
    g: u8,
    r: u8,
    pub fn fromU24(c: u24) Rgba8 {
        return .{
            .r = @intCast((c >> 16) & 0xFF),
            .g = @intCast((c >> 8) & 0xFF),
            .b = @intCast(c & 0xFF),
            .a = 255,
        };
    }
};

// Used only when the terminal's dynamic fg/bg colors are unset (which normally
// never happens — tab creation seeds term.colors from the active theme).
pub const fallback_fg: u24 = 0xc8c4d0;
pub const fallback_bg: u24 = 0x2a2a2a;

pub const cell_attr_underline_mask: u32 = 0x7;
pub const cell_attr_strikethrough: u32 = 1 << 3;
pub const cell_attr_overline: u32 = 1 << 4;
pub const cell_attr_color_glyph: u32 = 1 << 5;
pub const cell_attr_invisible: u32 = 1 << 6;

// Shared types with the shader
pub const shader = struct {
    pub const GridConfig = extern struct {
        cell_size: [2]u32,
        col_count: u32,
        row_count: u32,
        scrollbar_y: f32,
        scrollbar_height: f32,
        scrollbar_x: f32,
        scrollbar_width: f32,
        cells_per_row: u32,
        // Pixel y where the terminal grid begins (tab-bar band height). The
        // grid quad is drawn under a viewport offset by this much; the shader
        // subtracts it from SV_Position.y (RT-absolute) for all cell math.
        tab_bar_height: u32,
        // bit0 = background image enabled, bit1 = repeat/tile. 0 disables all
        // image sampling in the shader (zero-cost when no image configured).
        bg_image_flags: u32 = 0,
        // Multiplier on the sampled image alpha (background-image-opacity).
        bg_image_opacity: f32 = 0,
        // Fitted image rectangle in terminal-grid pixel space (origin at the
        // top-left terminal cell, below the tab bar): offset.xy, size.xy.
        bg_image_dest: [4]f32 = .{ 0, 0, 0, 0 },
    };
    pub const Cell = extern struct {
        glyph_index: u32,
        background: Rgba8,
        foreground: Rgba8,
        attrs: u32,
    };
};

pub const scrollbar_logical_width: u16 = 14;

pub fn scrollbarWidth(dpi: u32) u16 {
    return @intFromFloat(@round(@as(f32, @floatFromInt(scrollbar_logical_width)) * @as(f32, @floatFromInt(dpi)) / 96.0));
}

pub fn getTextureMaxCellCount(cell_size: CellXY) CellXY {
    // Cap the atlas to 4096² (≈64 MiB at BGRA8). At typical cell sizes this
    // holds ~75k glyphs, far above any realistic terminal session. Each
    // dimension is clamped to ≥2 because GlyphIndexCache requires at least
    // two nodes (head + tail) for its circular-list bookkeeping.
    const max_dim: u32 = 4096;
    const cx: u32 = @max(2, @divTrunc(max_dim, @as(u32, cell_size.x)));
    const cy: u32 = @max(2, @divTrunc(max_dim, @as(u32, cell_size.y)));
    return .{ .x = @intCast(cx), .y = @intCast(cy) };
}

pub fn cellPosFromIndex(index: u32, column_count: u16) CellXY {
    return .{
        .x = @intCast(index % column_count),
        .y = @intCast(@divTrunc(index, column_count)),
    };
}

pub const AtlasFrame = struct {
    cache: *@import("../glyph_index_cache.zig"),
    tex_cell_count: CellXY,
};

pub const ShaderCells = struct {
    count: u32 = 0,
    cell_buf: *win32.ID3D11Buffer = undefined,
    cell_view: *win32.ID3D11ShaderResourceView = undefined,

    /// Returns true when the underlying buffer was (re)created, signaling
    /// the caller that the CPU shadow must be reseeded by a forced full
    /// upload this frame.
    pub fn updateCount(self: *ShaderCells, device: *win32.ID3D11Device, count: u32) bool {
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
            if (hr < 0) com.fatalHr("CreateCellBuffer", hr);

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
            if (hr2 < 0) com.fatalHr("CreateCellView", hr2);
        }
        self.count = count;
        return true;
    }

    pub fn release(self: *ShaderCells) void {
        if (self.count != 0) {
            _ = self.cell_view.IUnknown.Release();
            _ = self.cell_buf.IUnknown.Release();
            self.count = 0;
        }
    }
};

pub const GlyphTexture = struct {
    size: ?CellXY = null,
    obj: ?*win32.ID3D11Texture2D = null,
    view: ?*win32.ID3D11ShaderResourceView = null,

    pub fn updateSize(self: *GlyphTexture, device: *win32.ID3D11Device, size: CellXY) bool {
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
        if (hr < 0) com.fatalHr("CreateGlyphTexture", hr);
        self.obj = obj;

        var view: *win32.ID3D11ShaderResourceView = undefined;
        const hr2 = device.CreateShaderResourceView(&obj.ID3D11Resource, null, &view);
        if (hr2 < 0) com.fatalHr("CreateGlyphView", hr2);
        self.view = view;

        self.size = size;
        return false;
    }

    pub fn release(self: *GlyphTexture) void {
        if (self.view) |v| _ = v.IUnknown.Release();
        if (self.obj) |o| _ = o.IUnknown.Release();
        self.view = null;
        self.obj = null;
        self.size = null;
    }
};

// Decoded `background-image`: one static BGRA texture + SRV bound at t2. The
// shader samples it behind the cell grid (see terminal.hlsl). Source pixel
// dimensions are kept so the CPU can compute the fit/position rectangle each
// frame against the live client size.
pub const BackgroundImage = struct {
    texture: ?*win32.ID3D11Texture2D = null,
    view: ?*win32.ID3D11ShaderResourceView = null,
    src_w: u32 = 0,
    src_h: u32 = 0,

    pub fn loaded(self: BackgroundImage) bool {
        return self.view != null;
    }

    pub fn release(self: *BackgroundImage) void {
        if (self.view) |v| _ = v.IUnknown.Release();
        if (self.texture) |t| _ = t.IUnknown.Release();
        self.* = .{};
    }
};

// CPU-side decoded image. Owned by `gpa`; pixels are BGRA, stride = w*4.
// Produced by `decodeBackground` and consumed by `uploadBackground`. The two
// halves are split so the WIC decode (which can take 100ms+ for a multi-MB
// image) can run on a worker thread while only texture upload stays on the UI
// thread with the D3D device.
pub const DecodedBackground = struct {
    pixels: []u8,
    w: u32,
    h: u32,
};

// Pure-CPU WIC decode. Does not touch D3D and does not initialize COM —
// callers handle COM init for their own apartment (the decode worker thread
// calls CoInitializeEx itself). Returns null on any failure; a bad path or
// corrupt file must never crash the terminal.
pub fn decodeBackground(gpa: std.mem.Allocator, path: []const u8) ?DecodedBackground {
    const wpath = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch {
        log.warn("background-image: failed to encode path '{s}'", .{path});
        return null;
    };
    defer gpa.free(wpath);

    var factory: *win32.IWICImagingFactory = undefined;
    if (win32.CoCreateInstance(
        &win32.CLSID_WICImagingFactory,
        null,
        win32.CLSCTX_INPROC_SERVER,
        win32.IID_IWICImagingFactory,
        @ptrCast(&factory),
    ) < 0) {
        log.warn("background-image: WIC factory unavailable", .{});
        return null;
    }
    defer _ = factory.IUnknown.Release();

    var decoder: ?*win32.IWICBitmapDecoder = null;
    if (factory.CreateDecoderFromFilename(
        wpath,
        null,
        win32.GENERIC_READ,
        win32.WICDecodeMetadataCacheOnLoad,
        &decoder,
    ) < 0) {
        log.warn("background-image: cannot open '{s}'", .{path});
        return null;
    }
    defer _ = decoder.?.IUnknown.Release();

    var frame: ?*win32.IWICBitmapFrameDecode = null;
    if (decoder.?.GetFrame(0, &frame) < 0) {
        log.warn("background-image: no frame in '{s}'", .{path});
        return null;
    }
    defer _ = frame.?.IUnknown.Release();

    var converter: ?*win32.IWICFormatConverter = null;
    if (factory.CreateFormatConverter(&converter) < 0) return null;
    defer _ = converter.?.IUnknown.Release();

    var fmt: win32.Guid = win32.GUID_WICPixelFormat32bppBGRA;
    if (converter.?.Initialize(
        &frame.?.IWICBitmapSource,
        &fmt,
        win32.WICBitmapDitherTypeNone,
        null,
        0.0,
        win32.WICBitmapPaletteTypeMedianCut,
    ) < 0) {
        log.warn("background-image: cannot convert '{s}' to BGRA", .{path});
        return null;
    }

    var w: u32 = 0;
    var h: u32 = 0;
    if (converter.?.IWICBitmapSource.GetSize(&w, &h) < 0 or w == 0 or h == 0) return null;
    // Cap to a sane texture size; D3D11 guarantees 16384² support.
    if (w > 16384 or h > 16384) {
        log.warn("background-image: '{s}' is {}x{}, too large", .{ path, w, h });
        return null;
    }

    const stride: u32 = w * 4;
    const size: usize = @as(usize, stride) * h;
    const pixels = gpa.alloc(u8, size) catch return null;
    errdefer gpa.free(pixels);
    if (converter.?.IWICBitmapSource.CopyPixels(null, stride, @intCast(size), @ptrCast(pixels.ptr)) < 0) {
        log.warn("background-image: pixel copy failed for '{s}'", .{path});
        return null;
    }

    return .{ .pixels = pixels, .w = w, .h = h };
}

// Upload a `DecodedBackground` to a GPU texture + SRV. Must run on the thread
// that owns `device`. Returns a disabled BackgroundImage on failure.
pub fn uploadBackground(
    device: *win32.ID3D11Device,
    decoded: DecodedBackground,
) BackgroundImage {
    const stride: u32 = decoded.w * 4;
    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = decoded.w,
        .Height = decoded.h,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    const init_data: win32.D3D11_SUBRESOURCE_DATA = .{
        .pSysMem = @ptrCast(decoded.pixels.ptr),
        .SysMemPitch = stride,
        .SysMemSlicePitch = 0,
    };
    var tex: *win32.ID3D11Texture2D = undefined;
    if (device.CreateTexture2D(&desc, &init_data, &tex) < 0) {
        log.warn("background-image: CreateTexture2D failed", .{});
        return .{};
    }
    var view: *win32.ID3D11ShaderResourceView = undefined;
    if (device.CreateShaderResourceView(&tex.ID3D11Resource, null, &view) < 0) {
        _ = tex.IUnknown.Release();
        return .{};
    }
    return .{ .texture = tex, .view = view, .src_w = decoded.w, .src_h = decoded.h };
}

pub const StagingTexture = struct {
    pub const Kind = enum { mask, color };

    pub const Cached = struct {
        size: CellXY,
        texture: *win32.ID3D11Texture2D,
        mutex: *win32.IDXGIKeyedMutex,
        render_target: *win32.ID2D1RenderTarget,
        white_brush: *win32.ID2D1SolidColorBrush,
    };
    mask_cached: ?Cached = null,
    color_cached: ?Cached = null,

    pub fn getOrCreate(
        self: *StagingTexture,
        device: *win32.ID3D11Device,
        d2d_factory: *win32.ID2D1Factory,
        size: CellXY,
        kind: Kind,
    ) *Cached {
        const cached = switch (kind) {
            .mask => &self.mask_cached,
            .color => &self.color_cached,
        };
        if (cached.*) |*c| {
            if (c.size.eql(size)) return c;
            releaseCached(cached);
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
                .MiscFlags = .{ .SHARED_KEYEDMUTEX = 1 },
            };
            const hr = device.CreateTexture2D(&desc, null, &texture);
            if (hr < 0) com.fatalHr("CreateStagingTexture", hr);
        }

        const dxgi_surface = com.queryInterface(texture, win32.IDXGISurface);
        defer _ = dxgi_surface.IUnknown.Release();
        const mutex = com.queryInterface(texture, win32.IDXGIKeyedMutex);

        var render_target: *win32.ID2D1RenderTarget = undefined;
        {
            // Mask staging uses IGNORE alpha: D2D treats the surface as
            // opaque so it emits ClearType (it falls back to grayscale on
            // alpha-aware targets). Color glyph staging uses premultiplied
            // alpha so emoji bitmaps keep transparency for shader blending.
            // Pin DPI to 96 so IDWriteTextLayout's DIP-based maxWidth/maxHeight
            // map 1:1 to staging-texture pixels (cell metrics are in pixels).
            const alpha_mode: win32.D2D1_ALPHA_MODE = switch (kind) {
                .mask => .IGNORE,
                .color => .PREMULTIPLIED,
            };
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = alpha_mode },
                .dpiX = 96.0,
                .dpiY = 96.0,
                .usage = .{},
                .minLevel = .DEFAULT,
            };
            const hr = d2d_factory.CreateDxgiSurfaceRenderTarget(dxgi_surface, &props, &render_target);
            if (hr < 0) com.fatalHr("CreateDxgiSurfaceRenderTarget", hr);
        }

        // Set pixel unit mode
        const dc = com.queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

        var white_brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const hr = render_target.CreateSolidColorBrush(
                &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                null,
                &white_brush,
            );
            if (hr < 0) com.fatalHr("CreateBrush", hr);
        }

        cached.* = .{
            .size = size,
            .texture = texture,
            .mutex = mutex,
            .render_target = render_target,
            .white_brush = white_brush,
        };
        return &cached.*.?;
    }

    pub fn release(self: *StagingTexture) void {
        releaseCached(&self.mask_cached);
        releaseCached(&self.color_cached);
    }

    fn releaseCached(cached: *?Cached) void {
        if (cached.*) |*c| {
            _ = c.white_brush.IUnknown.Release();
            _ = c.render_target.IUnknown.Release();
            _ = c.mutex.IUnknown.Release();
            _ = c.texture.IUnknown.Release();
            cached.* = null;
        }
    }
};

// Offscreen target for the tab-bar band. The band is drawn with DirectWrite/D2D
// at proportional positions (independent of the terminal cell grid) and copied
// onto the back buffer's top strip via CopySubresourceRegion. Opaque (IGNORE)
// alpha so ClearType behaves and the strip composites solidly under DComp.
// Pinned to 96 DPI + PIXELS unit mode like StagingTexture, so the tab-bar text
// format's already-DPI-scaled font size maps 1:1 to physical pixels.
pub const BandTexture = struct {
    pub const Cached = struct {
        width: u32,
        height: u32,
        texture: *win32.ID3D11Texture2D,
        mutex: *win32.IDXGIKeyedMutex,
        render_target: *win32.ID2D1RenderTarget,
        brush: *win32.ID2D1SolidColorBrush,
    };
    cached: ?Cached = null,

    pub fn getOrCreate(
        self: *BandTexture,
        device: *win32.ID3D11Device,
        d2d_factory: *win32.ID2D1Factory,
        width: u32,
        height: u32,
    ) *Cached {
        if (self.cached) |*c| {
            if (c.width == width and c.height == height) return c;
            releaseCached(&self.cached);
        }

        var texture: *win32.ID3D11Texture2D = undefined;
        {
            const desc: win32.D3D11_TEXTURE2D_DESC = .{
                .Width = width,
                .Height = height,
                .MipLevels = 1,
                .ArraySize = 1,
                .Format = .B8G8R8A8_UNORM,
                .SampleDesc = .{ .Count = 1, .Quality = 0 },
                .Usage = .DEFAULT,
                .BindFlags = .{ .RENDER_TARGET = 1 },
                .CPUAccessFlags = .{},
                .MiscFlags = .{ .SHARED_KEYEDMUTEX = 1 },
            };
            const hr = device.CreateTexture2D(&desc, null, &texture);
            if (hr < 0) com.fatalHr("CreateBandTexture", hr);
        }

        const dxgi_surface = com.queryInterface(texture, win32.IDXGISurface);
        defer _ = dxgi_surface.IUnknown.Release();
        const mutex = com.queryInterface(texture, win32.IDXGIKeyedMutex);

        var render_target: *win32.ID2D1RenderTarget = undefined;
        {
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .IGNORE },
                .dpiX = 96.0,
                .dpiY = 96.0,
                .usage = .{},
                .minLevel = .DEFAULT,
            };
            const hr = d2d_factory.CreateDxgiSurfaceRenderTarget(dxgi_surface, &props, &render_target);
            if (hr < 0) com.fatalHr("CreateBandRenderTarget", hr);
        }

        const dc = com.queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const hr = render_target.CreateSolidColorBrush(
                &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                null,
                &brush,
            );
            if (hr < 0) com.fatalHr("CreateBandBrush", hr);
        }

        self.cached = .{
            .width = width,
            .height = height,
            .texture = texture,
            .mutex = mutex,
            .render_target = render_target,
            .brush = brush,
        };
        return &self.cached.?;
    }

    pub fn release(self: *BandTexture) void {
        releaseCached(&self.cached);
    }

    fn releaseCached(cached: *?Cached) void {
        if (cached.*) |*c| {
            _ = c.brush.IUnknown.Release();
            _ = c.render_target.IUnknown.Release();
            _ = c.mutex.IUnknown.Release();
            _ = c.texture.IUnknown.Release();
            cached.* = null;
        }
    }
};

/// One cell-sized region to lift out of a font-service surface: where to read
/// from within it, and which atlas slot receives it.
pub const AtlasCopy = struct {
    src_left: u32,
    dst: CellXY,
};

// D3D11's GPU resource for one Kitty inline image. The cache around it is
// backend-agnostic and only requires `release`.
pub const KittyImage = struct {
    texture: *win32.ID3D11Texture2D,
    view: *win32.ID3D11ShaderResourceView,

    pub fn release(self: *KittyImage) void {
        _ = self.view.IUnknown.Release();
        _ = self.texture.IUnknown.Release();
    }
};

// CPU-addressable twin of `BandTexture`, for a backend that cannot open the
// font service's shared surfaces. Same D2D target properties (B8G8R8A8_UNORM,
// IGNORE alpha, 96 DPI, pixel unit mode) so the tab-bar band rasterizes
// identically; only the destination differs — a WIC bitmap instead of a
// DXGI surface — and the caller copies the bytes out itself.
//
// This is the same mechanism the async glyph worker already uses, not a
// GPU readback: D2D renders straight into memory.
pub const CpuBandTexture = struct {
    pub const Cached = struct {
        width: u32,
        height: u32,
        bitmap: *win32.IWICBitmap,
        render_target: *win32.ID2D1RenderTarget,
        brush: *win32.ID2D1SolidColorBrush,
        // Destination for CopyPixels. Owned here so the consumer never has to
        // manage a buffer whose size is tied to this target's dimensions.
        pixels: []u8,

        pub fn stride(self: *const Cached) u32 {
            return self.width * 4;
        }

        /// Pull the freshly drawn band out of the WIC bitmap. Call after the
        /// D2D EndDraw that produced it.
        pub fn readPixels(self: *Cached) []const u8 {
            const s = self.stride();
            const hr = self.bitmap.IWICBitmapSource.CopyPixels(
                null,
                s,
                @intCast(self.pixels.len),
                @ptrCast(self.pixels.ptr),
            );
            if (hr < 0) com.fatalHr("CopyPixels(cpu band)", hr);

            // The pixel format's fourth byte is padding, not alpha, and its
            // contents are undefined. These bytes go on to be presented
            // through a premultiplied-alpha surface, where undefined padding
            // reads as transparency — so state the band's opacity explicitly
            // rather than inheriting whatever the imaging layer left behind.
            var i: usize = 3;
            while (i < self.pixels.len) : (i += 4) self.pixels[i] = 0xFF;
            return self.pixels;
        }
    };
    cached: ?Cached = null,

    pub fn getOrCreate(
        self: *CpuBandTexture,
        d2d_factory: *win32.ID2D1Factory,
        wic_factory: *win32.IWICImagingFactory,
        width: u32,
        height: u32,
    ) *Cached {
        if (self.cached) |*c| {
            if (c.width == width and c.height == height) return c;
            releaseCached(&self.cached);
        }

        var bitmap: *win32.IWICBitmap = undefined;
        {
            // 32bppBGR + IGNORE is the pairing D2D accepts for an opaque
            // ClearType target; 32bppBGRA + IGNORE is rejected outright.
            var fmt: win32.Guid = win32.GUID_WICPixelFormat32bppBGR;
            const hr = wic_factory.CreateBitmap(
                width,
                height,
                &fmt,
                win32.WICBitmapCacheOnLoad,
                @ptrCast(&bitmap),
            );
            if (hr < 0) com.fatalHr("WIC CreateBitmap(cpu band)", hr);
        }

        var render_target: *win32.ID2D1RenderTarget = undefined;
        {
            const props = win32.D2D1_RENDER_TARGET_PROPERTIES{
                .type = .DEFAULT,
                .pixelFormat = .{ .format = .B8G8R8A8_UNORM, .alphaMode = .IGNORE },
                .dpiX = 96.0,
                .dpiY = 96.0,
                .usage = .{},
                .minLevel = .DEFAULT,
            };
            const hr = d2d_factory.CreateWicBitmapRenderTarget(bitmap, &props, &render_target);
            if (hr < 0) com.fatalHr("CreateWicBitmapRenderTarget(cpu band)", hr);
        }

        const dc = com.queryInterface(render_target, win32.ID2D1DeviceContext);
        defer _ = dc.IUnknown.Release();
        dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

        var brush: *win32.ID2D1SolidColorBrush = undefined;
        {
            const hr = render_target.CreateSolidColorBrush(
                &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
                null,
                &brush,
            );
            if (hr < 0) com.fatalHr("CreateBrush(cpu band)", hr);
        }

        const pixels = std.heap.page_allocator.alloc(u8, @as(usize, width) * height * 4) catch
            com.oom(error.OutOfMemory);

        self.cached = .{
            .width = width,
            .height = height,
            .bitmap = bitmap,
            .render_target = render_target,
            .brush = brush,
            .pixels = pixels,
        };
        return &self.cached.?;
    }

    pub fn release(self: *CpuBandTexture) void {
        releaseCached(&self.cached);
    }

    fn releaseCached(cached: *?Cached) void {
        if (cached.*) |*c| {
            std.heap.page_allocator.free(c.pixels);
            _ = c.brush.IUnknown.Release();
            _ = c.render_target.IUnknown.Release();
            _ = c.bitmap.IUnknown.Release();
            cached.* = null;
        }
    }
};

pub fn acquireFontWrite(mutex: *win32.IDXGIKeyedMutex) void {
    const hr = mutex.AcquireSync(0, win32.INFINITE);
    if (hr != 0) com.fatalHr("AcquireSync(font write)", hr);
}

pub fn releaseFontWrite(mutex: *win32.IDXGIKeyedMutex) void {
    const hr = mutex.ReleaseSync(1);
    if (hr != 0) com.fatalHr("ReleaseSync(font write)", hr);
}

// Backend-side view of one font-service texture. Normally the backend imports
// it on a distinct D3D11 device; recovery may import it on the retained font
// device itself. The source is AddRef'd so a DPI/size rebuild cannot invalidate
// the identity while the imported view is still cached. Key 1 belongs to the
// consumer; releasing key 0 hands the surface back to the font service for its
// next D2D draw.
pub const SharedTexture = struct {
    source: ?*win32.ID3D11Texture2D = null,
    imported: ?*win32.ID3D11Texture2D = null,
    mutex: ?*win32.IDXGIKeyedMutex = null,

    pub fn acquireRead(
        self: *SharedTexture,
        device: *win32.ID3D11Device,
        source: *win32.ID3D11Texture2D,
    ) *win32.ID3D11Texture2D {
        if (self.source != source) self.open(device, source);
        const hr = self.mutex.?.AcquireSync(1, win32.INFINITE);
        if (hr != 0) com.fatalHr("AcquireSync(font read)", hr);
        return self.imported.?;
    }

    pub fn releaseRead(self: *SharedTexture) void {
        const hr = self.mutex.?.ReleaseSync(0);
        if (hr != 0) com.fatalHr("ReleaseSync(font read)", hr);
    }

    pub fn release(self: *SharedTexture) void {
        if (self.mutex) |mutex| _ = mutex.IUnknown.Release();
        if (self.imported) |texture| _ = texture.IUnknown.Release();
        if (self.source) |source| _ = source.IUnknown.Release();
        self.* = .{};
    }

    fn open(self: *SharedTexture, device: *win32.ID3D11Device, source: *win32.ID3D11Texture2D) void {
        self.release();

        const resource = com.queryInterface(source, win32.IDXGIResource);
        defer _ = resource.IUnknown.Release();
        var handle: ?win32.HANDLE = null;
        const handle_hr = resource.GetSharedHandle(&handle);
        if (handle_hr < 0) com.fatalHr("GetSharedHandle(font texture)", handle_hr);

        var imported: *win32.ID3D11Texture2D = undefined;
        const open_hr = device.OpenSharedResource(handle, win32.IID_ID3D11Texture2D, @ptrCast(&imported));
        if (open_hr < 0) com.fatalHr("OpenSharedResource(font texture)", open_hr);
        const mutex = com.queryInterface(imported, win32.IDXGIKeyedMutex);

        _ = source.IUnknown.AddRef();
        self.* = .{
            .source = source,
            .imported = imported,
            .mutex = mutex,
        };
    }
};
