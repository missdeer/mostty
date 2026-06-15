const D3d11Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphIndexCache = @import("GlyphIndexCache.zig");
const types = @import("types.zig");
const Config = @import("../Config.zig");

const com = @import("d3d11/com.zig");
const gpu = @import("d3d11/gpu.zig");
const color = @import("d3d11/color.zig");
const emoji = @import("d3d11/emoji.zig");
const font_mod = @import("d3d11/font.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const glyph_worker_mod = @import("d3d11/glyph_worker.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");
const bg_image = @import("d3d11/background_image.zig");
const swap_chain_mod = @import("d3d11/swap_chain.zig");
const font_state = @import("d3d11/font_state.zig");
const cell_buffer = @import("d3d11/cell_buffer.zig");
const grid = @import("d3d11/grid.zig");

// Re-exported so external callers (window message handlers) stay agnostic
// to the internal module layout.
pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = glyph_worker_mod.RasterResult;

const log = std.log.scoped(.d3d);

const DXGI_STATUS_OCCLUDED = swap_chain_mod.DXGI_STATUS_OCCLUDED;

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
// Set by Present when DXGI returns DXGI_STATUS_OCCLUDED (window fully
// covered or display-mode-locked). While true, render() first sends a cheap
// Present(0, DXGI_PRESENT_TEST) probe. If the window is still occluded we
// skip the expensive draw/copy path; if it is visible again, the same call
// continues through a full redraw and a normal Present.
occluded: bool = false,

// Always-on renderer diagnostics (~24 bytes overhead). Flushed once per
// second by maybeLogDiag() at the end of render(). Promoted out of the
// Debug-only DebugStats above because the spinner-CPU investigation needs
// these in release builds too. Last-log timestamp uses GetTickCount64 (u64
// ms) to match the Window-level diagnostics in state.zig — keeping both
// flushes on one clock prevents their loglines from drifting apart.
diag_tabbar_paints: u64 = 0,
diag_rows_uploaded: u64 = 0,
diag_rows_skipped: u64 = 0,
diag_last_log_ms: u64 = 0,

// --- Persistent grid texture (Step B) ---
// Sized to the full client area; the cell pixel shader renders into this
// texture with scissor restricted to rows that actually changed this frame.
// Each frame the entire texture is CopyResource'd to the swap-chain back
// buffer (flip-model back-buffer content is undefined after Present, so
// partial redraws against the back buffer aren't possible — but the
// persistent texture lets us do partial redraws into a surface we own,
// then deliver in full via a cheap memcpy-equivalent on WARP).
//
// `grid_force_full` is set on:
//   - first frame after (re)create
//   - any GridConfigSnapshot mismatch (see snapshot field)
//   - font reload, DPI change (anywhere glyph_cache is reset)
// and cleared at the end of render() only when a draw actually ran.
//
// The resource is B8G8R8A8_UNORM; the RTV is B8G8R8A8_UNORM_SRGB. This
// mirrors the swap-chain back-buffer setup exactly so CopyResource is a
// byte-for-byte transfer with no color reinterpretation.
grid_texture: ?*win32.ID3D11Texture2D = null,
grid_rtv: ?*win32.ID3D11RenderTargetView = null,
grid_texture_size: win32.SIZE = .{ .cx = 0, .cy = 0 },
scissor_rasterizer_state: ?*win32.ID3D11RasterizerState = null,
grid_force_full: bool = true,
last_const_snapshot: grid.ConfigSnapshot = .{},

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
// Back-buffer texture retained so the persistent grid texture and tab-bar band
// can be copied into the current flip-model back buffer. Released/reacquired
// on swap-chain resize.
back_buffer_tex: ?*win32.ID3D11Texture2D = null,

// Background image (`background-image`). The texture is (re)loaded by
// reloadBackgroundImage only when the configured path changes; placement
// params are read every frame to recompute the fit rectangle. bg_image_path
// is a gpa-owned copy of the loaded path, kept so reloadConfig can detect a
// no-op. bg_sampler (linear/clamp) is lazily created on first use.
background_image: gpu.BackgroundImage = .{},
bg_image_path: []const u8 = &.{},
bg_image_opacity: f32 = 1.0,
bg_image_position: Config.BackgroundImagePosition = .center,
bg_image_fit: Config.BackgroundImageFit = .contain,
bg_image_repeat: bool = false,
bg_sampler: ?*win32.ID3D11SamplerState = null,
// Monotonically incremented every time `reloadBackgroundImage` decides to
// kick off a new async decode (or clears the image). A worker carries the
// id it was spawned with; on completion the handler ignores results whose
// id no longer matches, so a fast burst of hot-reloads doesn't paint a
// stale image. Only ever read/written from the UI thread.
bg_image_req_id: u32 = 0,

// Async DirectWrite raster worker. The struct stays `undefined` until
// `setWorkerHwnd` calls `Worker.start` and flips `glyph_worker_started`.
// Every code path that touches `glyph_worker` (submit, shutdown) must
// gate on the flag — reading any field before start is UB.
glyph_worker: glyph_worker_mod.Worker = undefined,
glyph_worker_started: bool = false,

// Monotonic counter bumped whenever the glyph cache / atlas is rebuilt
// (font reload, DPI change, atlas resize). In-flight raster jobs carry
// the value captured at submit time; results whose cache_gen no longer
// matches are dropped before touching the atlas. The slot's per-Node
// gen guards in-cache slot reuse — cache_gen covers the orthogonal case
// of the whole cache being thrown out.
cache_gen: u32 = 0,

pub fn cellSizeForDpi(self: *D3d11Renderer, dpi: u32) win32.SIZE {
    if (dpi == self.dpi) return self.cell_size;
    return font_mod.measureCellSize(&self.dwrite_factory.IDWriteFactory, dpi, self.effective_primary, self.font_size_pt);
}

pub fn tabBarHeightForDpi(self: *D3d11Renderer, dpi: u32) i32 {
    if (dpi == self.dpi) return self.tab_bar_height;
    const cs = self.cellSizeForDpi(dpi);
    return font_state.computeTabBarHeight(self.dwrite_factory, dpi, self.effective_tabbar_primary, self.tabbar_font_size_pt, @intCast(cs.cy));
}

pub fn init(dpi: u32, font_config: FontConfig) D3d11Renderer {
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
    const adapter_info = swap_chain_mod.detectAdapter(device);
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

    const eff = font_state.deriveFromConfig(dwrite_factory, font_config);
    const fmts = font_state.buildFormats(dwrite_factory, dpi, eff);

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
        .text_formats = fmts.text_formats,
        .font_fallbacks = fmts.font_fallbacks,
        .rendering_params = rendering_params,
        .cell_size = fmts.cell_size,
        .cell_size_xy = fmts.cell_size_xy,
        .dpi = dpi,
        .font_size_pt = eff.font_size_pt,
        .effective_primary = eff.primary,
        .effective_style_primaries = eff.style_primaries,
        .effective_style_specs = eff.style_specs,
        .effective_style = eff.style,
        .effective_user_fallbacks = eff.user_fallbacks,
        .effective_codepoint_maps = eff.codepoint_maps,
        .tabbar_text_format = fmts.tabbar_format,
        .tabbar_fallback = fmts.tabbar_fallback,
        .tabbar_trimming_sign = fmts.tabbar_trimming_sign,
        .effective_tabbar_primary = eff.tabbar_primary,
        .tabbar_font_size_pt = eff.tabbar_font_size_pt,
        .tab_bar_height = fmts.tab_bar_height,
        .remote_or_software_adapter = adapter_info.remote_or_software,
    };
}

pub fn updateDpi(self: *D3d11Renderer, dpi: u32) void {
    if (dpi == self.dpi) return;
    // DPI alone doesn't change effective font config (family bindings,
    // style synthesis, code-point maps); only the DPI-dependent formats
    // and metrics need rebuilding.
    font_state.rebuildAndAssign(self, dpi, font_state.snapshotFromRenderer(self));
}

// Re-applies font configuration at runtime (config hot-reload). The caller
// owns the lifetime of the [*:0]u16 strings in `font_config` (same contract
// as `init`); the renderer keeps pointers into them via
// `effective_primary`/`effective_user_fallbacks`.
pub fn updateFont(self: *D3d11Renderer, font_config: FontConfig) void {
    const eff = font_state.deriveFromConfig(self.dwrite_factory, font_config);
    font_state.rebuildAndAssign(self, self.dpi, eff);
}

pub fn deinit(self: *D3d11Renderer) void {
    if (self.glyph_worker_started) {
        self.glyph_worker.shutdown();
        // The worker thread is joined; no new WM_APP_GLYPH_READY can be
        // posted. Drain any results that were posted before shutdown ran
        // but never dispatched (e.g. a renderer teardown that beats the
        // message loop to the punch), otherwise each one leaks its
        // heap-owned `RasterResult` + bytes.
        drainGlyphReadyQueue(self.glyph_worker.gpa);
    }
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
    if (self.back_buffer_tex) |bb| _ = bb.IUnknown.Release();
    self.back_buffer_tex = null;
    // Step B persistent grid: release RTV before its underlying texture
    // (RTV holds a ref on the resource), then release the texture and
    // the rasterizer state.
    if (self.grid_rtv) |rtv| _ = rtv.IUnknown.Release();
    self.grid_rtv = null;
    if (self.grid_texture) |t| _ = t.IUnknown.Release();
    self.grid_texture = null;
    if (self.scissor_rasterizer_state) |rs| _ = rs.IUnknown.Release();
    self.scissor_rasterizer_state = null;
    self.background_image.release();
    if (self.bg_sampler) |s| _ = s.IUnknown.Release();
    self.bg_sampler = null;
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

// Frame-prepared state passed between the 4 render phases. Captures what
// `prepareFrame` derived from window size + terminal state + DPI, so
// subsequent phases don't recompute it.
const PreparedFrame = struct {
    swap_chain: *win32.IDXGISwapChain2,
    client_w: u32,
    client_h: u32,
    cs: CellXY,
    shader_col: u32,
    tab_bar_h: u32,
    term_pixel_h: u32,
    term_shader_row: u32,
    atlas: gpu.AtlasFrame,
    tex_cell_count: CellXY,
};

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
    url_highlight: ?types.UrlHighlight,
) void {
    // Phase 1: client size, swap-chain (re)create + resize, occlusion test,
    // ensure grid texture + scissor rasterizer state, compute grid dims,
    // atlas setup, scrollbar geometry, snapshot diff, const-buffer write.
    // Returns null on early-out (zero size, still occluded, oversize cap).
    const prepared = prepareFrame(self, hwnd, term, mouse_in_scrollbar) orelse return;

    // Phase 2: terminal -> shader.Cell translation + per-row shadow diff
    // upload + resize overlay. Returns the dirty row range used by phase 3.
    const cell_count = prepared.shader_col * prepared.term_shader_row;
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
    if (build.has_blink) {
        _ = win32.SetTimer(hwnd, types.TIMER_TEXT_BLINK, 250, null);
    } else {
        _ = win32.KillTimer(hwnd, types.TIMER_TEXT_BLINK);
    }

    // Phase 3: persistent grid draw decision + back-buffer delivery.
    swap_chain_mod.acquireBackBufferTexture(self, prepared.swap_chain);
    grid.drawAndCopy(self, .{
        .client_w = prepared.client_w,
        .client_h = prepared.client_h,
        .tab_bar_h = prepared.tab_bar_h,
        .term_pixel_h = prepared.term_pixel_h,
        .cell_h = prepared.cs.y,
        .term_shader_row = prepared.term_shader_row,
        .cell_count = cell_count,
        .dirty_min_row = build.dirty_min_row,
        .dirty_max_row = build.dirty_max_row,
        .resizing = resizing,
    });

    // Phase 4: tab-bar band paint + Present + occlusion state + diag.
    paintChromeAndPresent(self, prepared, tabbar);
    self.maybeLogDiag(prepared.client_w, prepared.client_h, prepared.shader_col, prepared.term_shader_row);
}

fn prepareFrame(
    self: *D3d11Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    mouse_in_scrollbar: bool,
) ?PreparedFrame {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);
    if (client_w == 0 or client_h == 0) return null;

    // Lazy swap chain init
    if (self.swap_chain == null) {
        self.swap_chain = swap_chain_mod.init(self, hwnd, client_w, client_h);
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
            // The retained back buffer is stale once the swap chain resizes;
            // drop it so acquireBackBufferTexture reacquires the new one.
            if (self.back_buffer_tex) |bb| {
                _ = bb.IUnknown.Release();
                self.back_buffer_tex = null;
            }
            // Persistent grid texture is sized to the client area; resize
            // invalidates it. Release RTV before texture (RTV holds the ref).
            // grid.ensureTexture below recreates at the new size and sets
            // grid_force_full on (re)create.
            if (self.grid_rtv) |rtv| {
                _ = rtv.IUnknown.Release();
                self.grid_rtv = null;
            }
            if (self.grid_texture) |t| {
                _ = t.IUnknown.Release();
                self.grid_texture = null;
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

    // If the window is fully covered, don't spend CPU rebuilding cells,
    // repainting the grid, copying textures, or drawing the tab bar. A TEST
    // present only probes visibility and does not submit a frame; once it
    // succeeds, fall through and continue this same frame so the restored
    // window updates immediately.
    if (self.occluded) {
        const hr = swap_chain.IDXGISwapChain.Present(0, win32.DXGI_PRESENT_TEST);
        if (hr == DXGI_STATUS_OCCLUDED) {
            self.grid_force_full = true;
            return null;
        } else if (hr >= 0) {
            self.occluded = false;
            self.grid_force_full = true;
        } else {
            fatalHr("Present(TEST)", hr);
        }
    }

    // Persistent grid texture + scissor rasterizer state. Both are safe to
    // call every frame — they early-return when up to date.
    grid.ensureTexture(self, client_w, client_h);
    _ = grid.ensureScissorRasterizerState(self);

    const cs = self.cell_size_xy;
    const sb_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w: u32 = client_w -| sb_px;
    const shader_col: u32 = @divTrunc(grid_w + cs.x - 1, cs.x);
    // The tab bar is a separate pixel band at the top (height tab_bar_h),
    // painted via D2D after the grid. The cell grid is terminal-only and
    // the grid quad is drawn under a viewport offset by tab_bar_h; the
    // shader subtracts tab_bar_h from SV_Position.y.
    const tab_bar_h: u32 = @intCast(@max(0, self.tab_bar_height));
    const term_pixel_h: u32 = client_h -| tab_bar_h;
    const term_shader_row: u32 = @divTrunc(term_pixel_h + cs.y - 1, cs.y);

    // Defensive cap matching the per-row scratch capacity in cell_buffer.
    // Must come before `shader_cells.updateCount` / `ensureShadowCapacity`:
    // those mutate GPU buffer and CPU shadow; bailing out after either
    // would leave shadow allocated but un-seeded, and a later in-range
    // frame with unchanged `cell_count` would diff against undefined bytes
    // and silently skip uploads. `render.zig` already gates `total_cols`,
    // but we keep this as a localized safety net.
    if (shader_col > cell_buffer.max_shader_col) return null;

    // Hoist per-frame atlas setup out of the per-cell loop; the cache /
    // texture state is identical for every cell in a single frame. Also
    // produces `tex_cell_count` needed by the const-buffer below.
    const atlas = glyph_mod.setupGlyphAtlas(self);
    const tex_cell_count = atlas.tex_cell_count;

    // Compute scrollbar geometry once so both the const-buffer write and
    // the ConfigSnapshot compare see the same values. Coordinates are
    // RT-absolute: the grid sits below the tab-bar band so the scrollbar's
    // y origin is the band height.
    var sb_geom: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    {
        const sb = term.screens.active.pages.scrollbar();
        const show_scrollbar = sb.total > sb.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
        if (show_scrollbar) {
            const sb_origin_y: f32 = @floatFromInt(tab_bar_h);
            const win_h: f32 = @floatFromInt(client_h -| tab_bar_h);
            const min_track_height: f32 = 20.0;
            const track_height = @max(min_track_height, @as(f32, @floatFromInt(sb.len)) / @as(f32, @floatFromInt(sb.total)) * win_h);
            const max_offset = sb.total - sb.len;
            const track_y = sb_origin_y + @as(f32, @floatFromInt(sb.offset)) / @as(f32, @floatFromInt(max_offset)) * (win_h - track_height);
            sb_geom = .{
                .x = @floatFromInt(grid_w),
                .y = track_y,
                .w = @floatFromInt(sb_px),
                .h = track_height,
            };
        }
    }

    // Compare every const-buffer field that does NOT flow through per-cell
    // uploads against last frame's snapshot. Any mismatch means pixels in
    // the grid texture could be stale outside the row-dirty rect (e.g.
    // scrollbar moved without any cell change). Force a full redraw.
    const new_snapshot: grid.ConfigSnapshot = .{
        .cell_w = cs.x,
        .cell_h = cs.y,
        .col_count = shader_col,
        .row_count = term_shader_row,
        .cells_per_row = tex_cell_count.x,
        .tab_bar_height = tab_bar_h,
        .scrollbar_x = sb_geom.x,
        .scrollbar_y = sb_geom.y,
        .scrollbar_width = sb_geom.w,
        .scrollbar_height = sb_geom.h,
    };
    if (!new_snapshot.eql(self.last_const_snapshot)) {
        self.grid_force_full = true;
        self.last_const_snapshot = new_snapshot;
    }

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
        config.scrollbar_x = sb_geom.x;
        config.scrollbar_width = sb_geom.w;
        config.scrollbar_y = sb_geom.y;
        config.scrollbar_height = sb_geom.h;

        // Background image: bit0 = enabled, bit1 = repeat. The fit rect is
        // computed against the cell-grid extent so it lines up exactly
        // with the shader's terminal-space pixel coordinates (origin below
        // the tab bar).
        var bg_flags: u32 = 0;
        var bg_dest: [4]f32 = .{ 0, 0, 0, 0 };
        if (self.background_image.loaded()) {
            bg_flags |= 1;
            if (self.bg_image_repeat) bg_flags |= 2;
            const container_w_f: f32 = @floatFromInt(shader_col * cs.x);
            const container_h_f: f32 = @floatFromInt(term_shader_row * cs.y);
            bg_dest = bg_image.computeDest(self, container_w_f, container_h_f);
        }
        config.bg_image_flags = bg_flags;
        config.bg_image_opacity = self.bg_image_opacity;
        config.bg_image_dest = bg_dest;
    }

    return .{
        .swap_chain = swap_chain,
        .client_w = client_w,
        .client_h = client_h,
        .cs = cs,
        .shader_col = shader_col,
        .tab_bar_h = tab_bar_h,
        .term_pixel_h = term_pixel_h,
        .term_shader_row = term_shader_row,
        .atlas = atlas,
        .tex_cell_count = tex_cell_count,
    };
}

fn paintChromeAndPresent(self: *D3d11Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw) void {
    // Tab-bar band: paint proportionally into the offscreen band texture,
    // then copy it onto the back buffer's top strip. Mirrors the
    // glyph-staging pattern (D2D EndDraw flushes before the D3D copy reads
    // the texture).
    if (prepared.tab_bar_h > 0) {
        self.diag_tabbar_paints += 1;
        const band = self.band_texture.getOrCreate(self.device, self.d2d_factory, prepared.client_w, prepared.tab_bar_h);
        tabbar_paint.paint(
            band.render_target,
            band.brush,
            &self.dwrite_factory.IDWriteFactory,
            self.tabbar_text_format,
            self.tabbar_trimming_sign,
            tabbar,
            prepared.cs.x,
            prepared.tab_bar_h,
        );
        // Unbind the RTV so the back buffer can be a CopySubresourceRegion dest.
        self.context.OMSetRenderTargets(0, null, null);
        if (self.back_buffer_tex) |bb| {
            const copy_h = @min(prepared.tab_bar_h, prepared.client_h);
            const src_box = win32.D3D11_BOX{
                .left = 0,
                .top = 0,
                .front = 0,
                .right = prepared.client_w,
                .bottom = copy_h,
                .back = 1,
            };
            self.context.CopySubresourceRegion(&bb.ID3D11Resource, 0, 0, 0, 0, &band.texture.ID3D11Resource, 0, &src_box);
        }
    }

    // Local hardware: Present(0,0). SetTimer caps producer rate; DXGI
    // offloads rasterization to TPP workers without blocking the UI
    // thread, and a sync-interval would just stack with the 16ms cap.
    //
    // Remote/software (RDP w/o RemoteFX → WARP): Present(1,0). Software
    // rasterization can't sustain 60fps anyway, so the "halve FPS" concern
    // from the local path doesn't apply. Critically, the SetTimer cap only
    // bounds paint frequency; with WARP each frame still costs real CPU on
    // worker threads, and uncapped producer rate piles up workers (~30%
    // CPU during spinner animation). Present(1) makes DXGI wait for the
    // previous frame's workers before returning, naturally back-pressuring
    // producer rate to actual consumer throughput.
    //
    // OCCLUDED is handled by the cheap early TEST probe in prepareFrame.
    // This final Present always submits the frame.
    const sync_interval: u32 = if (self.remote_or_software_adapter) 1 else 0;
    const hr = prepared.swap_chain.IDXGISwapChain.Present(sync_interval, 0);
    if (hr == DXGI_STATUS_OCCLUDED) {
        self.occluded = true;
    } else if (hr >= 0) {
        self.occluded = false;
    } else {
        fatalHr("Present", hr);
    }
}

// 1Hz flush of the renderer-side diagnostic counters into std.log.info.
// Lives next to the counters rather than in state.zig because state.zig
// cannot import d3d11.zig without a circular dependency. Skipped on the
// very first call (no prior tick to diff against). Includes grid + client
// dims so "rows/s uploaded" has a denominator (e.g. 18/(30*24) = 2.5% of
// available rows actually changed per second).
fn maybeLogDiag(self: *D3d11Renderer, client_w: u32, client_h: u32, cols: u32, rows: u32) void {
    const now = win32.GetTickCount64();
    if (self.diag_last_log_ms == 0) {
        self.diag_last_log_ms = now;
        return;
    }
    if (now - self.diag_last_log_ms < 1000) return;
    log.info(
        "renderer stats: {}x{} grid ({}x{} px), {} tabbar paint(s)/s, {} row(s)/s uploaded, {} row(s)/s skipped",
        .{
            cols,
            rows,
            client_w,
            client_h,
            self.diag_tabbar_paints,
            self.diag_rows_uploaded,
            self.diag_rows_skipped,
        },
    );
    self.diag_last_log_ms = now;
    self.diag_tabbar_paints = 0;
    self.diag_rows_uploaded = 0;
    self.diag_rows_skipped = 0;
}

// Starts the glyph raster worker thread and binds its result-delivery HWND.
// Called once from mosttywindows.zig after CreateWindowExW returns — the
// renderer is at its final address by then, so the thread can safely capture
// `&self.glyph_worker`. No glyph jobs can be submitted before this point;
// `submit` callsites live behind the per-frame render path that only runs
// after the window exists.
pub fn setWorkerHwnd(self: *D3d11Renderer, gpa: std.mem.Allocator, hwnd: win32.HWND) void {
    self.glyph_worker.start(gpa, self.dwrite_factory) catch |e| {
        log.warn("glyph raster worker spawn failed: {s}; falling back to UI-thread raster", .{@errorName(e)});
        return;
    };
    self.glyph_worker_started = true;
    self.glyph_worker.setHwnd(hwnd);
}

// Called by the WM_APP_GLYPH_READY handler. Validates the result against
// the renderer-level `cache_gen` (covers full cache rebuilds) and the
// cache's per-slot `gen` (covers in-cache slot reuse) before uploading the
// BGRA bytes into the atlas slot's pixel rectangle. Returns true iff the
// upload happened, so the dispatcher knows whether to requestRender. The
// caller still owns `result` and frees it after we return.
pub fn applyGlyphResult(self: *D3d11Renderer, result: *RasterResult) bool {
    if (result.cache_gen != self.cache_gen) return false;
    if (self.glyph_cache == null) return false;
    const cache = &self.glyph_cache.?;
    if (!cache.markReady(result.slot, result.slot_gen, result.key)) return false;

    const cs = self.cell_size_xy;
    const tex_cell_count = gpu.getTextureMaxCellCount(cs);
    const pos = gpu.cellPosFromIndex(result.slot, tex_cell_count.x);
    const dst_x: u32 = @as(u32, cs.x) * pos.x;
    const dst_y: u32 = @as(u32, cs.y) * pos.y;
    const dst_box: win32.D3D11_BOX = .{
        .left = dst_x,
        .top = dst_y,
        .front = 0,
        .right = dst_x + result.w,
        .bottom = dst_y + result.h,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.glyph_texture.obj.?.ID3D11Resource,
        0,
        &dst_box,
        @ptrCast(result.bytes.ptr),
        result.w * 4,
        0,
    );
    return true;
}

// Pop every WM_APP_GLYPH_READY still sitting in the calling thread's queue
// and free its `RasterResult`. Hwnd-agnostic on purpose: PeekMessage with
// hwnd=null picks up messages for any window owned by this thread, which is
// what we want after the renderer's window has already torn down. The
// message-ID filter guarantees we don't accidentally drain other WM_APPs
// (BG_IMAGE_DECODED, etc) that have their own ownership rules.
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

pub fn reloadBackgroundImage(
    self: *D3d11Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    bg_image.reload(self, gpa, cfg, hwnd);
}

pub fn applyDecodedBackgroundImage(self: *D3d11Renderer, result: *const BgImageDecoded) void {
    bg_image.applyDecoded(self, result);
}
