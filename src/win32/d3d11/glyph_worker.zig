//! Off-UI raster worker for single-cell DirectWrite glyphs.
//!
//! UI thread submits a `RasterJob` (codepoint + style + reserved atlas slot
//! identity); worker thread rasterises into a CPU BGRA buffer via a private
//! D2D MULTI_THREADED factory + WIC bitmap render target, then PostMessages
//! a heap-owned `RasterResult` back to the UI thread.
//!
//! Stage A scope: infrastructure only. `submit` callers don't yet exist;
//! `applyGlyphResult` and the slot state machine are Stage B/C.

const std = @import("std");
const win32 = @import("win32").everything;
const com = @import("com.zig");
const gpu = @import("gpu.zig");
const emoji = @import("emoji.zig");
const sprite = @import("../sprite.zig");
const GlyphIndexCache = @import("../GlyphIndexCache.zig");
const font = @import("font.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.d3d);
const CellXY = gpu.CellXY;

const queue_cap: usize = 256;
pub const max_run_cells: usize = 12;

pub const RunSlot = struct {
    offset: u8,
    slot: u32,
    slot_gen: u32,
    key: GlyphIndexCache.Key,
};

pub const RasterJob = struct {
    key: GlyphIndexCache.Key,
    codepoint: u21,
    grapheme: []u21,
    run_text: []u8 = &.{},
    run_slots: [max_run_cells]RunSlot = undefined,
    run_slot_count: u8 = 0,
    is_wide: bool,
    is_color: bool,
    is_ambiguous: bool,
    slot: u32,
    slot_gen: u32,
    cache_gen: u32,
    cs: CellXY,
    // AddRef'd at submit, Release'd by worker after the raster completes.
    text_format: *win32.IDWriteTextFormat,
    rendering_params: *win32.IDWriteRenderingParams,
    font_features: []win32.DWRITE_FONT_FEATURE = &.{},

    pub fn destroy(self: *RasterJob, gpa: std.mem.Allocator) void {
        _ = self.text_format.IUnknown.Release();
        _ = self.rendering_params.IUnknown.Release();
        if (self.font_features.len != 0) gpa.free(self.font_features);
        if (self.grapheme.len != 0) gpa.free(self.grapheme);
        if (self.run_text.len != 0) gpa.free(self.run_text);
        gpa.destroy(self);
    }
};

pub const RasterResult = struct {
    slot: u32,
    slot_gen: u32,
    cache_gen: u32,
    key: GlyphIndexCache.Key,
    bytes: []u8,
    w: u32,
    h: u32,
    is_color: bool,
    failed: bool = false,

    pub fn deinit(self: *RasterResult, gpa: std.mem.Allocator) void {
        if (self.bytes.len != 0) gpa.free(self.bytes);
        gpa.destroy(self);
    }
};

const Kind = enum { mask, color };

const CachedRt = struct {
    size: CellXY,
    bitmap: *win32.IWICBitmap,
    rt: *win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,

    fn release(self: *CachedRt) void {
        _ = self.brush.IUnknown.Release();
        _ = self.rt.IUnknown.Release();
        _ = self.bitmap.IUnknown.Release();
    }
};

pub const Worker = struct {
    gpa: std.mem.Allocator,
    // SHARED dwrite factory is safe across threads; AddRef'd at start, Release'd at shutdown.
    dwrite_factory: *win32.IDWriteFactory2,

    hwnd: std.atomic.Value(usize) = .init(0),

    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    queue: [queue_cap]*RasterJob = undefined,
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    stop: bool = false,
    thread: ?std.Thread = null,

    pending_count: std.atomic.Value(u64) = .init(0),
    total_completed: std.atomic.Value(u64) = .init(0),

    pub fn start(self: *Worker, gpa: std.mem.Allocator, dwrite_factory: *win32.IDWriteFactory2) !void {
        self.* = .{
            .gpa = gpa,
            .dwrite_factory = dwrite_factory,
        };
        _ = dwrite_factory.IUnknown.AddRef();
        errdefer _ = dwrite_factory.IUnknown.Release();
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    pub fn setHwnd(self: *Worker, hwnd: win32.HWND) void {
        self.hwnd.store(@intFromPtr(hwnd), .release);
    }

    // UI thread. Returns false if the queue is full; caller falls back to
    // a blank-glyph placeholder (Stage C).
    pub fn submit(self: *Worker, job: *RasterJob) bool {
        self.mutex.lock();
        if (self.count == queue_cap or self.stop) {
            self.mutex.unlock();
            return false;
        }
        self.queue[self.tail] = job;
        self.tail = (self.tail + 1) % queue_cap;
        self.count += 1;
        // Bump under the mutex so the worker can never decrement before the
        // increment lands: it can't pop this job until we drop the lock.
        _ = self.pending_count.fetchAdd(1, .monotonic);
        self.mutex.unlock();
        self.cond.signal();
        return true;
    }

    pub fn shutdown(self: *Worker) void {
        if (self.thread == null) return;
        self.mutex.lock();
        self.stop = true;
        self.mutex.unlock();
        self.cond.signal();
        self.thread.?.join();
        self.thread = null;

        // pop() returns null as soon as stop is set, leaving any backlog for
        // us to destroy here — keeps shutdown bounded by the in-flight raster
        // rather than the whole queue depth.
        while (self.count > 0) {
            const job = self.queue[self.head];
            self.head = (self.head + 1) % queue_cap;
            self.count -= 1;
            _ = self.pending_count.fetchSub(1, .monotonic);
            job.destroy(self.gpa);
        }

        _ = self.dwrite_factory.IUnknown.Release();
    }

    fn pop(self: *Worker) ?*RasterJob {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.count == 0 and !self.stop) {
            self.cond.wait(&self.mutex);
        }
        if (self.stop) return null;
        const job = self.queue[self.head];
        self.head = (self.head + 1) % queue_cap;
        self.count -= 1;
        return job;
    }
};

fn run(self: *Worker) void {
    _ = win32.CoInitializeEx(null, win32.COINIT_MULTITHREADED);
    defer win32.CoUninitialize();

    var d2d_factory: *win32.ID2D1Factory = undefined;
    {
        const hr = win32.D2D1CreateFactory(
            .MULTI_THREADED,
            win32.IID_ID2D1Factory,
            null,
            @ptrCast(&d2d_factory),
        );
        if (hr < 0) com.fatalHr("D2D1CreateFactory(worker)", hr);
    }
    defer _ = d2d_factory.IUnknown.Release();

    var wic_factory: *win32.IWICImagingFactory = undefined;
    {
        const hr = win32.CoCreateInstance(
            &win32.CLSID_WICImagingFactory,
            null,
            win32.CLSCTX_INPROC_SERVER,
            win32.IID_IWICImagingFactory,
            @ptrCast(&wic_factory),
        );
        if (hr < 0) com.fatalHr("WIC factory(worker)", hr);
    }
    defer _ = wic_factory.IUnknown.Release();

    var mask_cached: ?CachedRt = null;
    var color_cached: ?CachedRt = null;
    defer {
        if (mask_cached) |*c| c.release();
        if (color_cached) |*c| c.release();
    }

    while (true) {
        const job = self.pop() orelse break;
        if (job.run_text.len != 0) {
            const hwnd_raw = self.hwnd.load(.acquire);
            if (hwnd_raw != 0) {
                rasterRunAndPostResults(
                    self.gpa,
                    hwnd_raw,
                    self.dwrite_factory,
                    d2d_factory,
                    wic_factory,
                    &mask_cached,
                    job,
                );
            }
            job.destroy(self.gpa);
            _ = self.pending_count.fetchSub(1, .monotonic);
            _ = self.total_completed.fetchAdd(1, .monotonic);
            continue;
        }

        const result = rasterToWicBuffer(
            self.gpa,
            self.dwrite_factory,
            d2d_factory,
            wic_factory,
            &mask_cached,
            &color_cached,
            job,
        );

        const hwnd_raw = self.hwnd.load(.acquire);
        if (result) |r| {
            postRasterResult(self.gpa, hwnd_raw, r);
        } else {
            postRasterFailure(self.gpa, hwnd_raw, job.slot, job.slot_gen, job.cache_gen, job.key);
        }

        job.destroy(self.gpa);
        _ = self.pending_count.fetchSub(1, .monotonic);
        _ = self.total_completed.fetchAdd(1, .monotonic);
    }
}

fn postRasterResult(gpa: std.mem.Allocator, hwnd_raw: usize, result: *RasterResult) void {
    if (hwnd_raw == 0) {
        result.deinit(gpa);
        return;
    }
    const hwnd: win32.HWND = @ptrFromInt(hwnd_raw);
    const lparam: win32.LPARAM = @bitCast(@intFromPtr(result));
    if (win32.PostMessageW(hwnd, types.WM_APP_GLYPH_READY, 0, lparam) == 0) {
        result.deinit(gpa);
    }
}

fn postRasterFailure(
    gpa: std.mem.Allocator,
    hwnd_raw: usize,
    slot: u32,
    slot_gen: u32,
    cache_gen: u32,
    key: GlyphIndexCache.Key,
) void {
    const result = gpa.create(RasterResult) catch com.oom(error.OutOfMemory);
    result.* = .{
        .slot = slot,
        .slot_gen = slot_gen,
        .cache_gen = cache_gen,
        .key = key,
        .bytes = &.{},
        .w = 0,
        .h = 0,
        .is_color = false,
        .failed = true,
    };
    postRasterResult(gpa, hwnd_raw, result);
}

fn ensureRt(
    cached: *?CachedRt,
    d2d_factory: *win32.ID2D1Factory,
    wic_factory: *win32.IWICImagingFactory,
    size: CellXY,
    kind: Kind,
) *CachedRt {
    if (cached.*) |*c| {
        if (c.size.eql(size)) return c;
        c.release();
        cached.* = null;
    }

    var bitmap: *win32.IWICBitmap = undefined;
    {
        // D2D's CreateWicBitmapRenderTarget only accepts two pairings:
        //   * 32bppPBGRA + PREMULTIPLIED  (color/emoji)
        //   * 32bppBGR   + IGNORE         (opaque mask, ClearType)
        // Picking 32bppBGRA + IGNORE returns WINCODEC_ERR_UNSUPPORTEDPIXELFORMAT
        // (0x88982F80). The mask path treats the staging texture as opaque
        // anyway — alpha is unused for ClearType coverage in BGR.
        var fmt: win32.Guid = switch (kind) {
            .mask => win32.GUID_WICPixelFormat32bppBGR,
            .color => win32.GUID_WICPixelFormat32bppPBGRA,
        };
        const hr = wic_factory.CreateBitmap(
            size.x,
            size.y,
            &fmt,
            win32.WICBitmapCacheOnLoad,
            @ptrCast(&bitmap),
        );
        if (hr < 0) com.fatalHr("WIC CreateBitmap", hr);
    }

    var rt: *win32.ID2D1RenderTarget = undefined;
    {
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
        const hr = d2d_factory.CreateWicBitmapRenderTarget(bitmap, &props, &rt);
        if (hr < 0) com.fatalHr("CreateWicBitmapRenderTarget", hr);
    }

    const dc = com.queryInterface(rt, win32.ID2D1DeviceContext);
    defer _ = dc.IUnknown.Release();
    dc.SetUnitMode(win32.D2D1_UNIT_MODE_PIXELS);

    var brush: *win32.ID2D1SolidColorBrush = undefined;
    {
        const hr = rt.CreateSolidColorBrush(
            &.{ .r = 1.0, .g = 1.0, .b = 1.0, .a = 1.0 },
            null,
            &brush,
        );
        if (hr < 0) com.fatalHr("CreateBrush(worker)", hr);
    }

    cached.* = .{
        .size = size,
        .bitmap = bitmap,
        .rt = rt,
        .brush = brush,
    };
    return &cached.*.?;
}

// Worker-thread port of glyph.zig's `renderGlyphToStaging`. Same DirectWrite
// + D2D logic; renders into a WIC bitmap and returns a heap-owned
// `RasterResult` carrying the BGRA bytes.
fn rasterToWicBuffer(
    gpa: std.mem.Allocator,
    dwrite_factory: *win32.IDWriteFactory2,
    d2d_factory: *win32.ID2D1Factory,
    wic_factory: *win32.IWICImagingFactory,
    mask_cached: *?CachedRt,
    color_cached: *?CachedRt,
    job: *RasterJob,
) ?*RasterResult {
    const cs = job.cs;
    const target_w: u16 = if (job.is_wide) cs.x * @as(u16, 2) else cs.x;
    const bmp_size: CellXY = .{ .x = target_w, .y = cs.y };
    const cached_slot = if (job.is_color) color_cached else mask_cached;
    const cached = ensureRt(cached_slot, d2d_factory, wic_factory, bmp_size, if (job.is_color) .color else .mask);

    const utf16_len_max = (1 + job.grapheme.len) * 2;
    var utf16_stack: [64]u16 = undefined;
    var utf16_heap: ?[]u16 = null;
    defer if (utf16_heap) |buf| std.heap.page_allocator.free(buf);
    const utf16_buf: []u16 = if (utf16_len_max <= utf16_stack.len)
        utf16_stack[0..utf16_len_max]
    else blk: {
        const buf = std.heap.page_allocator.alloc(u16, utf16_len_max) catch return null;
        utf16_heap = buf;
        break :blk buf;
    };
    const utf16_len = emoji.encodeUtf16Run(utf16_buf, job.codepoint, job.grapheme);

    const target_width: f32 = @floatFromInt(target_w);
    const cs_y_f: f32 = @floatFromInt(cs.y);

    var layout: *win32.IDWriteTextLayout = undefined;
    {
        const hr = dwrite_factory.IDWriteFactory.CreateTextLayout(
            @ptrCast(utf16_buf[0..utf16_len].ptr),
            @intCast(utf16_len),
            job.text_format,
            target_width,
            cs_y_f,
            &layout,
        );
        if (hr < 0) com.fatalHr("CreateTextLayout(worker)", hr);
    }
    defer _ = layout.IUnknown.Release();

    if (emoji.shouldForceEmojiFont(job.codepoint, job.grapheme)) {
        const range = win32.DWRITE_TEXT_RANGE{
            .startPosition = 0,
            .length = @intCast(utf16_len),
        };
        const hr = layout.SetFontFamilyName(font.emoji_font_family, range);
        if (hr < 0) com.fatalHr("SetFontFamilyName(emoji)", hr);
    }
    font.applyFontFeatures(&dwrite_factory.IDWriteFactory, layout, job.font_features, @intCast(utf16_len));

    if (job.is_ambiguous) {
        const ahr = layout.IDWriteTextFormat.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
        if (ahr < 0) com.fatalHr("SetTextAlignment", ahr);
        const pahr = layout.IDWriteTextFormat.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
        if (pahr < 0) com.fatalHr("SetParagraphAlignment", pahr);
    }

    var m: win32.DWRITE_TEXT_METRICS = undefined;
    {
        const hr = layout.GetMetrics(&m);
        if (hr < 0) com.fatalHr("GetMetrics", hr);
    }
    var oh: win32.DWRITE_OVERHANG_METRICS = undefined;
    {
        const hr = layout.GetOverhangMetrics(&oh);
        if (hr < 0) com.fatalHr("GetOverhangMetrics", hr);
    }

    const SCALE_CAP: f32 = 2.0;
    const content_right = m.left + @max(m.width, m.widthIncludingTrailingWhitespace);
    const overhang_right = m.layoutWidth + @max(0.0, oh.right);
    const fit_width = @max(content_right, overhang_right);

    const ink_w = m.layoutWidth + oh.left + oh.right;
    const ink_h = m.layoutHeight + oh.top + oh.bottom;
    const ink_ok = ink_w > 0 and ink_h > 0 and std.math.isFinite(ink_w) and std.math.isFinite(ink_h);

    const raw_scale: f32 = if (job.is_ambiguous) blk: {
        if (!ink_ok) break :blk 1.0;
        const sw = target_width / ink_w;
        const sh = cs_y_f / ink_h;
        break :blk @min(@min(sw, sh), SCALE_CAP);
    } else if (fit_width > target_width and fit_width > 0)
        target_width / fit_width
    else
        1.0;
    const need_scale = @abs(raw_scale - 1.0) > 0.001;
    const scale: f32 = if (need_scale) raw_scale else 1.0;

    if (need_scale and !job.is_ambiguous) {
        const hr = layout.SetMaxWidth(fit_width);
        if (hr < 0) com.fatalHr("SetMaxWidth", hr);
    }

    const identity: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
        .m11 = 1,
        .m12 = 0,
        .m21 = 0,
        .m22 = 1,
        .dx = 0,
        .dy = 0,
    } } };
    cached.rt.SetTransform(&identity);
    if (!job.is_color) cached.rt.SetTextRenderingParams(job.rendering_params);
    cached.rt.SetTextAntialiasMode(if (job.is_color) .GRAYSCALE else .CLEARTYPE);
    cached.rt.BeginDraw();
    {
        const color: win32.D2D_COLOR_F = if (job.is_color)
            .{ .r = 0, .g = 0, .b = 0, .a = 0 }
        else
            .{ .r = 0, .g = 0, .b = 0, .a = 1 };
        cached.rt.Clear(&color);
    }

    if (need_scale and !job.is_color) {
        cached.rt.SetTextAntialiasMode(.GRAYSCALE);

        const scale_mat: win32.D2D_MATRIX_3X2_F = if (job.is_ambiguous) blk: {
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
        } else if (!job.is_wide) .{
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
            if (lhr < 0) com.fatalHr("GetLineMetrics", lhr);
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
        cached.rt.SetTransform(&scale_mat);
    }

    const draw_options: win32.D2D1_DRAW_TEXT_OPTIONS = if (job.is_ambiguous)
        .{}
    else
        win32.D2D1_DRAW_TEXT_OPTIONS_CLIP;
    var color_draw_options = draw_options;
    if (job.is_color) color_draw_options.ENABLE_COLOR_FONT = 1;
    cached.rt.DrawTextLayout(
        .{ .x = 0, .y = 0 },
        layout,
        &cached.brush.ID2D1Brush,
        color_draw_options,
    );

    cached.rt.SetTransform(&identity);
    if (need_scale and !job.is_color) cached.rt.SetTextAntialiasMode(.CLEARTYPE);

    var tag1: u64 = undefined;
    var tag2: u64 = undefined;
    const ehr = cached.rt.EndDraw(&tag1, &tag2);
    if (ehr < 0) com.fatalHr("EndDraw(worker)", ehr);

    // Pull the rendered pixels off the WIC bitmap. CopyPixels with a tight
    // stride lands directly in our heap buffer.
    const stride: u32 = @as(u32, target_w) * 4;
    const byte_len: usize = @as(usize, stride) * @as(usize, cs.y);
    const bytes = gpa.alloc(u8, byte_len) catch return null;
    errdefer gpa.free(bytes);

    const rect = win32.WICRect{
        .X = 0,
        .Y = 0,
        .Width = @intCast(target_w),
        .Height = @intCast(cs.y),
    };
    const chr = cached.bitmap.IWICBitmapSource.CopyPixels(
        &rect,
        stride,
        @intCast(byte_len),
        @ptrCast(bytes.ptr),
    );
    if (chr < 0) {
        log.warn("WIC CopyPixels failed in raster worker, hresult=0x{x}", .{@as(u32, @bitCast(chr))});
        gpa.free(bytes);
        return null;
    }

    const result = gpa.create(RasterResult) catch {
        gpa.free(bytes);
        return null;
    };
    result.* = .{
        .slot = job.slot,
        .slot_gen = job.slot_gen,
        .cache_gen = job.cache_gen,
        .key = job.key,
        .bytes = bytes,
        .w = target_w,
        .h = cs.y,
        .is_color = job.is_color,
    };
    return result;
}

fn rasterRunAndPostResults(
    gpa: std.mem.Allocator,
    hwnd_raw: usize,
    dwrite_factory: *win32.IDWriteFactory2,
    d2d_factory: *win32.ID2D1Factory,
    wic_factory: *win32.IWICImagingFactory,
    mask_cached: *?CachedRt,
    job: *RasterJob,
) void {
    std.debug.assert(job.run_text.len > 1);
    std.debug.assert(job.run_text.len <= max_run_cells);
    std.debug.assert(job.run_slot_count > 0);

    const cs = job.cs;
    const run_len_u32: u32 = @intCast(job.run_text.len);
    const target_w: u32 = @as(u32, cs.x) * run_len_u32;
    const bmp_size: CellXY = .{ .x = @intCast(target_w), .y = cs.y };
    const cached = ensureRt(mask_cached, d2d_factory, wic_factory, bmp_size, .mask);

    var utf16_stack: [max_run_cells]u16 = undefined;
    for (job.run_text, 0..) |ch, i| utf16_stack[i] = ch;
    const utf16_len: u32 = @intCast(job.run_text.len);

    const target_width: f32 = @floatFromInt(target_w);
    const cs_y_f: f32 = @floatFromInt(cs.y);

    var layout: *win32.IDWriteTextLayout = undefined;
    {
        const hr = dwrite_factory.IDWriteFactory.CreateTextLayout(
            @ptrCast(utf16_stack[0..utf16_len].ptr),
            utf16_len,
            job.text_format,
            target_width,
            cs_y_f,
            &layout,
        );
        if (hr < 0) com.fatalHr("CreateTextLayout(run worker)", hr);
    }
    defer _ = layout.IUnknown.Release();
    font.applyFontFeatures(&dwrite_factory.IDWriteFactory, layout, job.font_features, utf16_len);

    const identity: win32.D2D_MATRIX_3X2_F = .{ .Anonymous = .{ .Anonymous1 = .{
        .m11 = 1,
        .m12 = 0,
        .m21 = 0,
        .m22 = 1,
        .dx = 0,
        .dy = 0,
    } } };
    cached.rt.SetTransform(&identity);
    cached.rt.SetTextRenderingParams(job.rendering_params);
    cached.rt.SetTextAntialiasMode(.CLEARTYPE);
    cached.rt.BeginDraw();
    cached.rt.Clear(&.{ .r = 0, .g = 0, .b = 0, .a = 1 });
    cached.rt.DrawTextLayout(
        .{ .x = 0, .y = 0 },
        layout,
        &cached.brush.ID2D1Brush,
        win32.D2D1_DRAW_TEXT_OPTIONS_CLIP,
    );
    cached.rt.SetTransform(&identity);

    var tag1: u64 = undefined;
    var tag2: u64 = undefined;
    const ehr = cached.rt.EndDraw(&tag1, &tag2);
    if (ehr < 0) com.fatalHr("EndDraw(run worker)", ehr);

    const stride: u32 = @as(u32, cs.x) * 4;
    const byte_len: usize = @as(usize, stride) * @as(usize, cs.y);
    for (job.run_slots[0..job.run_slot_count], 0..) |slot, i| {
        std.debug.assert(slot.offset < job.run_text.len);
        std.debug.assert((@as(u32, slot.offset) + 1) * @as(u32, cs.x) <= target_w);

        const bytes = gpa.alloc(u8, byte_len) catch {
            postRunFailures(gpa, hwnd_raw, job, i);
            return;
        };
        errdefer gpa.free(bytes);
        const rect = win32.WICRect{
            .X = @intCast(@as(u32, slot.offset) * @as(u32, cs.x)),
            .Y = 0,
            .Width = @intCast(cs.x),
            .Height = @intCast(cs.y),
        };
        const chr = cached.bitmap.IWICBitmapSource.CopyPixels(
            &rect,
            stride,
            @intCast(byte_len),
            @ptrCast(bytes.ptr),
        );
        if (chr < 0) {
            log.warn("WIC CopyPixels failed in run raster worker, hresult=0x{x}", .{@as(u32, @bitCast(chr))});
            gpa.free(bytes);
            postRunFailures(gpa, hwnd_raw, job, i);
            return;
        }

        const result = gpa.create(RasterResult) catch {
            gpa.free(bytes);
            postRunFailures(gpa, hwnd_raw, job, i);
            return;
        };
        result.* = .{
            .slot = slot.slot,
            .slot_gen = slot.slot_gen,
            .cache_gen = job.cache_gen,
            .key = slot.key,
            .bytes = bytes,
            .w = cs.x,
            .h = cs.y,
            .is_color = false,
        };
        postRasterResult(gpa, hwnd_raw, result);
    }
}

fn postRunFailures(gpa: std.mem.Allocator, hwnd_raw: usize, job: *const RasterJob, start: usize) void {
    for (job.run_slots[start..job.run_slot_count]) |slot| {
        postRasterFailure(gpa, hwnd_raw, slot.slot, slot.slot_gen, job.cache_gen, slot.key);
    }
}
