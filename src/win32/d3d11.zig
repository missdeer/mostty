const D3d11Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const win32 = @import("win32").everything;
const GlyphIndexCache = @import("glyph_index_cache.zig");
const FontService = @import("font_service.zig");
const RendererCommon = @import("renderer_common.zig");
const types = @import("types.zig");
const Config = @import("../config.zig");

const com = @import("d3d11/com.zig");
const gpu = @import("d3d11/gpu.zig");
const color = @import("d3d11/color.zig");
const emoji = @import("d3d11/emoji.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const kitty_image_mod = @import("d3d11/kitty_images.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");
const bg_image = @import("d3d11/background_image.zig");
const swap_chain_mod = @import("d3d11/swap_chain.zig");
const cell_buffer = @import("d3d11/cell_buffer.zig");
const grid = @import("d3d11/grid.zig");
const diag = @import("diag.zig");
const shader_assets = @import("shader_assets.zig");
const shared = @import("shared.zig");

// Re-exported so external callers (window message handlers) stay agnostic
// to the internal module layout.
pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;

const log = std.log.scoped(.d3d);

const DXGI_STATUS_OCCLUDED = swap_chain_mod.DXGI_STATUS_OCCLUDED;

pub const scrollbarWidth = gpu.scrollbarWidth;

const Rgba8 = gpu.Rgba8;
const CellXY = gpu.CellXY;
const shader = gpu.shader;
const ShaderCells = gpu.ShaderCells;
const GlyphTexture = gpu.GlyphTexture;
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

const DeviceSource = enum { dedicated, font_service, shared_renderer };

// D3D11 core
common: *RendererCommon,
font_service: *FontService,
device: *win32.ID3D11Device,
context: *win32.ID3D11DeviceContext,
device_source: DeviceSource,

// Shaders
vertex_shader: *win32.ID3D11VertexShader,
pixel_shader: *win32.ID3D11PixelShader,
const_buf: *win32.ID3D11Buffer,
image_pixel_shader: *win32.ID3D11PixelShader,
image_const_buf: *win32.ID3D11Buffer,
image_blend_state: *win32.ID3D11BlendState,

// DirectComposition
composition_above_children: bool = false,
dcomp_device: *win32.IDCompositionDevice = undefined,
dcomp_target: *win32.IDCompositionTarget = undefined,
dcomp_visual: *win32.IDCompositionVisual = undefined,

// Per-window state (lazily initialized)
swap_chain: ?*win32.IDXGISwapChain2 = null,
// Frame-latency waitable object (DXGI 1.3). Populated by swap_chain_mod.init
// together with `swap_chain`; consumed by prepareFrame to gate CPU frame
// work on DXGI queue availability so the 3-buffer swap chain does not add
// input latency. Closed in deinit.
frame_latency_waitable: ?win32.HANDLE = null,
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
glyph_staging_bridge: gpu.SharedTexture = .{},

stats: DebugStats = .{},
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

band_bridge: gpu.SharedTexture = .{},
// Signature of the content last painted into the band texture, plus the
// texture identity it was painted into. The band survives across frames, so a
// frame whose signature matches can skip the D2D pass. The identity check
// covers a `getOrCreate` rebuild handing back undefined pixels at a size the
// signature has seen before (e.g. resize A -> B -> A).
tabbar_sig: u64 = 0,
tabbar_sig_tex: ?*win32.ID3D11Texture2D = null,
// Render-device-local copy of the band. The flip-model back buffer is undefined
// every frame, so the strip must be re-copied even when the band content is
// unchanged — but copying from here instead of the shared texture keeps the
// keyed-mutex handoff off the steady-state path entirely.
band_local: ?*win32.ID3D11Texture2D = null,
band_local_w: u32 = 0,
band_local_h: u32 = 0,
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
kitty_images: kitty_image_mod.Cache(gpu.KittyImage) = .{},

// Monotonic counter bumped whenever the glyph cache / atlas is rebuilt
// (font reload, DPI change, atlas resize). In-flight raster jobs carry
// the value captured at submit time; results whose cache_gen no longer
// matches are dropped before touching the atlas. The slot's per-Node
// gen guards in-cache slot reuse — cache_gen covers the orthogonal case
// of the whole cache being thrown out.
cache_gen: u32 = 0,

pub const InitError = error{DeviceUnavailable};

pub fn initErrorDescription(_: InitError) []const u8 {
    return "the D3D11 renderer could not create or retain a usable device";
}

fn deviceSourceForCreateResult(hr: i32) DeviceSource {
    return if (hr >= 0) .dedicated else .font_service;
}

fn initFailure(operation: []const u8, hr: i32) InitError {
    log.err("{s} failed, hresult=0x{x}", .{ operation, @as(u32, @bitCast(hr)) });
    return error.DeviceUnavailable;
}

pub fn init(
    common: *RendererCommon,
    font_service: *FontService,
    configured_gpu: ?[]const u8,
) InitError!D3d11Renderer {
    // Create D3D11 device
    const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    var device_source: DeviceSource = .dedicated;
    const selected_adapter = if (configured_gpu) |name|
        swap_chain_mod.findHardwareAdapterByName(name) orelse
            std.debug.panic("configured GPU '{s}' was not found among hardware adapters", .{name})
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
        device_source = deviceSourceForCreateResult(hr);
        if (device_source == .font_service) {
            log.warn(
                "D3D11CreateDevice failed for {s} GPU{s}{s}, hresult=0x{x}; reusing font service device",
                .{
                    if (configured_gpu != null) "configured" else "default",
                    if (configured_gpu != null) " " else "",
                    configured_gpu orelse "",
                    @as(u32, @bitCast(hr)),
                },
            );
            const retained = font_service.retainD3d11Device();
            device = retained.device;
            context = retained.context;
        }
    }
    errdefer _ = device.IUnknown.Release();
    errdefer _ = context.IUnknown.Release();
    const removed_reason = device.GetDeviceRemovedReason();
    if (removed_reason < 0) return initFailure("GetDeviceRemovedReason", removed_reason);

    const adapter_info = swap_chain_mod.detectAdapter(device);
    log.info(
        "D3D11 device created: selection={s}, adapter='{s}', remote_or_software={}",
        .{
            if (configured_gpu != null) "explicit" else "automatic",
            adapter_info.name[0..adapter_info.name_len],
            adapter_info.remote_or_software,
        },
    );

    // Load the build-time shader assets. Runtime compilation would delay
    // startup and could silently diverge from the SPIR-V produced for future
    // backends.
    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    {
        const hr = device.CreateVertexShader(
            shader_assets.vertex.dxbc.ptr,
            shader_assets.vertex.dxbc.len,
            null,
            &vertex_shader,
        );
        if (hr < 0) return initFailure("CreateVertexShader", hr);
    }
    errdefer _ = vertex_shader.IUnknown.Release();

    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    {
        const hr = device.CreatePixelShader(
            shader_assets.pixel.dxbc.ptr,
            shader_assets.pixel.dxbc.len,
            null,
            &pixel_shader,
        );
        if (hr < 0) return initFailure("CreatePixelShader", hr);
    }
    errdefer _ = pixel_shader.IUnknown.Release();
    var image_pixel_shader: *win32.ID3D11PixelShader = undefined;
    {
        const hr = device.CreatePixelShader(
            shader_assets.image_pixel.dxbc.ptr,
            shader_assets.image_pixel.dxbc.len,
            null,
            &image_pixel_shader,
        );
        if (hr < 0) return initFailure("CreatePixelShader(image)", hr);
    }
    errdefer _ = image_pixel_shader.IUnknown.Release();

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
        if (hr < 0) return initFailure("CreateConstBuffer", hr);
    }
    errdefer _ = const_buf.IUnknown.Release();
    var image_const_buf: *win32.ID3D11Buffer = undefined;
    {
        const desc: win32.D3D11_BUFFER_DESC = .{
            .ByteWidth = std.mem.alignForward(u32, @sizeOf(kitty_image_mod.ImageConfig), 16),
            .Usage = .DYNAMIC,
            .BindFlags = .{ .CONSTANT_BUFFER = 1 },
            .CPUAccessFlags = .{ .WRITE = 1 },
            .MiscFlags = .{},
            .StructureByteStride = 0,
        };
        const hr = device.CreateBuffer(&desc, null, &image_const_buf);
        if (hr < 0) return initFailure("CreateConstBuffer(image)", hr);
    }
    errdefer _ = image_const_buf.IUnknown.Release();

    const image_blend_state = try kitty_image_mod.createBlendState(device);
    errdefer _ = image_blend_state.IUnknown.Release();

    common.remote_or_software_adapter = adapter_info.remote_or_software;

    return .{
        .common = common,
        .font_service = font_service,
        .device = device,
        .context = context,
        .device_source = device_source,
        .vertex_shader = vertex_shader,
        .pixel_shader = pixel_shader,
        .const_buf = const_buf,
        .image_pixel_shader = image_pixel_shader,
        .image_const_buf = image_const_buf,
        .image_blend_state = image_blend_state,
    };
}

/// Create a pane surface without creating another GPU device or font service.
/// Immutable shaders and the UI-thread command context are retained; drawing
/// caches, textures and presentation resources start empty for this surface.
/// Dynamic constant buffers use WRITE_DISCARD, so ordered draws can share them.
pub fn initSurface(parent: *D3d11Renderer, common: *RendererCommon) D3d11Renderer {
    inline for (.{
        parent.device,
        parent.context,
        parent.vertex_shader,
        parent.pixel_shader,
        parent.const_buf,
        parent.image_pixel_shader,
        parent.image_const_buf,
        parent.image_blend_state,
    }) |object| _ = object.IUnknown.AddRef();
    return .{
        .common = common,
        .font_service = parent.font_service,
        .device = parent.device,
        .context = parent.context,
        .device_source = .shared_renderer,
        .composition_above_children = true,
        .vertex_shader = parent.vertex_shader,
        .pixel_shader = parent.pixel_shader,
        .const_buf = parent.const_buf,
        .image_pixel_shader = parent.image_pixel_shader,
        .image_const_buf = parent.image_const_buf,
        .image_blend_state = parent.image_blend_state,
    };
}

/// Synchronize retained background resources without sharing mutable pane caches.
pub fn syncSurface(self: *D3d11Renderer, parent: *D3d11Renderer) void {
    if (self.background_image.texture != parent.background_image.texture) {
        self.background_image.release();
        self.background_image = parent.background_image;
        if (self.background_image.texture) |t| _ = t.IUnknown.AddRef();
        if (self.background_image.view) |v| _ = v.IUnknown.AddRef();
        self.grid_force_full = true;
    }
    if (self.bg_image_opacity != parent.bg_image_opacity or
        self.bg_image_position != parent.bg_image_position or
        self.bg_image_fit != parent.bg_image_fit or
        self.bg_image_repeat != parent.bg_image_repeat) self.grid_force_full = true;
    self.bg_image_opacity = parent.bg_image_opacity;
    self.bg_image_position = parent.bg_image_position;
    self.bg_image_fit = parent.bg_image_fit;
    self.bg_image_repeat = parent.bg_image_repeat;
}

// --- Narrow GPU contract consumed by the backend-agnostic shared layer ---
//
// Everything above this line is D3D11's own business. These are the only
// operations `cell_buffer`, `glyph` and `background_image` need from a
// backend, so those modules are written against this contract instead of
// against D3D11 — the same source then serves both backends and cannot drift
// between them.

/// How the font service hands rasterized glyphs to this backend. D3D11 can
/// open the font service's shared surfaces because both live on the same
/// graphics API; D3D12 cannot, and takes CPU pixels instead.
pub const glyph_handoff: shared.GlyphHandoff = .shared_surface;

pub fn atlasEnsure(self: *D3d11Renderer, tex_pixel: CellXY) bool {
    return self.glyph_texture.updateSize(self.device, tex_pixel);
}

pub fn atlasWriteCpu(
    self: *D3d11Renderer,
    dst_coord: CellXY,
    region: CellXY,
    src_ptr: [*]const u8,
    src_row_pitch: u32,
) void {
    const dst_box: win32.D3D11_BOX = .{
        .left = dst_coord.x,
        .top = dst_coord.y,
        .front = 0,
        .right = dst_coord.x + region.x,
        .bottom = dst_coord.y + region.y,
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

/// Blank one atlas slot. Used when a rasterization fails: leaving the
/// evicted occupant's pixels behind would render a plausible-looking but
/// wrong character, which is harder to notice than a blank.
pub fn atlasClear(self: *D3d11Renderer, dst_coord: CellXY) void {
    const cs = self.font_service.cell_size_xy;
    const row_bytes: usize = @as(usize, cs.x) * 4;
    const zeros = std.heap.page_allocator.alloc(u8, row_bytes * cs.y) catch return;
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    self.atlasWriteCpu(dst_coord, cs, zeros.ptr, @intCast(row_bytes));
}

/// Copy up to two cell-sized regions out of one font-service surface.
///
/// Both halves are taken under a single read acquisition on purpose. The
/// handoff alternates keys — releasing hands the surface back to the font
/// service — so acquiring twice in a row would block forever waiting for a
/// writer that has not run. Wide glyphs need both halves from one surface,
/// which is why this takes a pair rather than being called twice.
pub fn atlasCopyStaging(
    self: *D3d11Renderer,
    staging: *gpu.StagingTexture.Cached,
    first: ?gpu.AtlasCopy,
    second: ?gpu.AtlasCopy,
) void {
    if (first == null and second == null) return;
    const cs = self.font_service.cell_size_xy;
    const imported = self.glyph_staging_bridge.acquireRead(self.device, staging.texture);
    defer self.glyph_staging_bridge.releaseRead();

    for ([_]?gpu.AtlasCopy{ first, second }) |maybe| {
        const copy = maybe orelse continue;
        const box: win32.D3D11_BOX = .{
            .left = copy.src_left,
            .top = 0,
            .front = 0,
            .right = copy.src_left + cs.x,
            .bottom = cs.y,
            .back = 1,
        };
        self.context.CopySubresourceRegion(
            &self.glyph_texture.obj.?.ID3D11Resource,
            0,
            copy.dst.x,
            copy.dst.y,
            0,
            &imported.ID3D11Resource,
            0,
            &box,
        );
    }
}

pub fn cellsResize(self: *D3d11Renderer, count: u32) bool {
    return self.shader_cells.updateCount(self.device, count);
}

pub fn cellsUpload(self: *D3d11Renderer, first_cell: u32, cells: []const shader.Cell) void {
    const cell_bytes: u32 = @sizeOf(shader.Cell);
    const box: win32.D3D11_BOX = .{
        .left = first_cell * cell_bytes,
        .right = (first_cell + @as(u32, @intCast(cells.len))) * cell_bytes,
        .top = 0,
        .bottom = 1,
        .front = 0,
        .back = 1,
    };
    self.context.UpdateSubresource(
        &self.shader_cells.cell_buf.ID3D11Resource,
        0,
        &box,
        @ptrCast(cells.ptr),
        0,
        0,
    );
}

pub fn backgroundImageRelease(self: *D3d11Renderer) void {
    self.background_image.release();
}

pub fn backgroundImageUpload(self: *D3d11Renderer, decoded: gpu.DecodedBackground) void {
    self.background_image.release();
    self.background_image = gpu.uploadBackground(self.device, decoded);
}

pub fn kittyImageUpload(
    self: *D3d11Renderer,
    width: u32,
    height: u32,
    rgba: []const u8,
) ?gpu.KittyImage {
    return kitty_image_mod.uploadTexture(self.device, width, height, rgba);
}

pub fn onFontStateChanged(self: *D3d11Renderer) void {
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
    self.grid_force_full = true;
}

pub fn deinit(self: *D3d11Renderer) void {
    if (comptime debug_stats_enabled) {
        const total = self.stats.rows_uploaded + self.stats.rows_skipped;
        const skip_pct: f64 = if (total == 0) 0.0 else @as(f64, @floatFromInt(self.stats.rows_skipped)) / @as(f64, @floatFromInt(total)) * 100.0;
        log.info("uploadCellRow stats: uploaded={d} skipped={d} ({d:.1}% skipped)", .{ self.stats.rows_uploaded, self.stats.rows_skipped, skip_pct });
    }
    self.glyph_staging_bridge.release();
    self.band_bridge.release();
    if (self.band_local) |t| _ = t.IUnknown.Release();
    self.kitty_images.deinit(std.heap.page_allocator);
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_texture.release();
    self.shader_cells.release();
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};
    // Clear all D3D state and flush before releasing the swap chain, otherwise
    // DXGI keeps the window surface and GDI can't draw to it. The retained
    // path delegates this mutation to FontService so the shared-context
    // ownership is explicit; its D3D state is not used concurrently.
    switch (self.device_source) {
        .dedicated, .shared_renderer => {
            self.context.ClearState();
            self.context.Flush();
        },
        .font_service => self.font_service.resetRetainedD3d11Context(),
    }
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
    // DirectComposition tree + swap chain share a lifecycle: all four are
    // created together in swap_chain_mod.init and left `undefined` until then.
    // Release in reverse-creation order (visual → target → device → swap
    // chain), gated on swap_chain being non-null so a renderer that never
    // rendered doesn't touch undefined memory.
    if (self.swap_chain) |sc| {
        _ = self.dcomp_visual.IUnknown.Release();
        _ = self.dcomp_target.IUnknown.Release();
        _ = self.dcomp_device.IUnknown.Release();
        _ = sc.IUnknown.Release();
    }
    if (self.frame_latency_waitable) |h| {
        _ = win32.CloseHandle(h);
        self.frame_latency_waitable = null;
    }
    _ = self.const_buf.IUnknown.Release();
    _ = self.image_blend_state.IUnknown.Release();
    _ = self.image_const_buf.IUnknown.Release();
    _ = self.image_pixel_shader.IUnknown.Release();
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
) void {
    const diag_on = diag.isEnabled();
    const t0 = if (diag_on) diag.qpcNow() else 0;

    // Phase 1: client size, swap-chain (re)create + resize, occlusion test,
    // ensure grid texture + scissor rasterizer state, compute grid dims,
    // atlas setup, scrollbar geometry, snapshot diff, const-buffer write.
    // Returns null on early-out (zero size, still occluded, oversize cap).
    const prepared = prepareFrame(self, hwnd, term, mouse_in_scrollbar) orelse {
        if (diag_on) {
            const total_us = diag.qpcUsSince(t0);
            if (total_us >= 2_000) std.log.info("render skip: prepare_us={}", .{total_us});
        }
        return;
    };
    const prepare_us = if (diag_on) diag.qpcUsSince(t0) else 0;

    // Phase 2: terminal -> shader.Cell translation + per-row shadow diff
    // upload + resize overlay. Returns the dirty row range used by phase 3.
    const cell_count = prepared.shader_col * prepared.term_shader_row;
    const build_t0 = if (diag_on) diag.qpcNow() else 0;
    if (self.kitty_images.sync(
        std.heap.page_allocator,
        self,
        tab_id,
        term,
    )) {
        self.grid_force_full = true;
    }
    const kitty_images_present = self.kitty_images.hasVisibleAboveTextPlacements();
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
    const build_us = if (diag_on) diag.qpcUsSince(build_t0) else 0;
    self.common.syncBlinkTimer(hwnd, build.has_blink);

    // Phase 3: persistent grid draw decision + back-buffer delivery.
    const grid_t0 = if (diag_on) diag.qpcNow() else 0;
    swap_chain_mod.acquireBackBufferTexture(self, prepared.swap_chain);
    grid.drawAndCopy(self, .{
        .client_w = prepared.client_w,
        .client_h = prepared.client_h,
        .tab_bar_h = prepared.tab_bar_h,
        .term_pixel_h = prepared.term_pixel_h,
        .cell_w = prepared.cs.x,
        .cell_h = prepared.cs.y,
        .term_shader_row = prepared.term_shader_row,
        .cell_count = cell_count,
        .dirty_min_row = build.dirty_min_row,
        .dirty_max_row = build.dirty_max_row,
        .resizing = resizing,
        .kitty_images_present = kitty_images_present,
    });
    const grid_us = if (diag_on) diag.qpcUsSince(grid_t0) else 0;

    // Phase 4: tab-bar band paint + Present + occlusion state + diag.
    const present_t0 = if (diag_on) diag.qpcNow() else 0;
    paintChromeAndPresent(self, prepared, tabbar, remote_session);
    const present_us = if (diag_on) diag.qpcUsSince(present_t0) else 0;
    if (diag_on) {
        const total_us = diag.qpcUsSince(t0);
        if (total_us >= 8_000 or build_us >= 4_000 or present_us >= 4_000) {
            std.log.info(
                "render frame: total_us={} prepare_us={} build_us={} grid_us={} present_us={} cells={} dirty={?}-{?}",
                .{
                    total_us,
                    prepare_us,
                    build_us,
                    grid_us,
                    present_us,
                    cell_count,
                    build.dirty_min_row,
                    build.dirty_max_row,
                },
            );
        }
    }
    self.maybeLogDiag(prepared.client_w, prepared.client_h, prepared.shader_col, prepared.term_shader_row);
}

pub fn renderChrome(self: *D3d11Renderer, hwnd: win32.HWND, term: *vt.Terminal, tabbar: types.TabBarDraw, background: u24, opacity: f32, remote_session: bool, pane_rects: []const win32.RECT) void {
    const prepared = prepareFrame(self, hwnd, term, false) orelse return;
    const rgba = [4]f32{
        std.math.pow(f32, @as(f32, @floatFromInt((background >> 16) & 0xff)) / 255, 2.2) * opacity,
        std.math.pow(f32, @as(f32, @floatFromInt((background >> 8) & 0xff)) / 255, 2.2) * opacity,
        std.math.pow(f32, @as(f32, @floatFromInt(background & 0xff)) / 255, 2.2) * opacity,
        opacity,
    };
    self.context.ClearRenderTargetView(self.grid_rtv.?, &rgba[0]);
    // Child surfaces supply their own alpha. Leaving parent pixels underneath
    // would apply background opacity twice and make split panes more opaque.
    const context1 = com.queryInterface(self.context, win32.ID3D11DeviceContext1);
    defer _ = context1.IUnknown.Release();
    const transparent = [4]f32{ 0, 0, 0, 0 };
    if (pane_rects.len > 0) context1.ClearView(&self.grid_rtv.?.ID3D11View, &transparent[0], pane_rects.ptr, @intCast(pane_rects.len));
    self.context.OMSetRenderTargets(0, null, null);
    swap_chain_mod.acquireBackBufferTexture(self, prepared.swap_chain);
    self.context.CopyResource(&self.back_buffer_tex.?.ID3D11Resource, &self.grid_texture.?.ID3D11Resource);
    paintChromeAndPresent(self, prepared, tabbar, remote_session);
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

    // Gate frame production on DXGI queue availability. Combined with
    // MaxFrameLatency=1 (set in swap_chain_mod.init), this caps queued-frame
    // depth at 1 so the 3-buffer swap chain absorbs DWM composition jitter
    // during drag/resize without adding input latency. Placed after the
    // OCCLUDED gate so a hidden window doesn't stall here.
    //
    // Bounded timeout (not INFINITE) so a stuck waitable in a pathological
    // state (GPU TDR mid-recovery, DWM hiccup) doesn't freeze the UI thread's
    // message pump. On timeout or failure, proceed with the frame — the queue
    // gate is best-effort, not a correctness invariant.
    if (self.frame_latency_waitable) |h| {
        _ = win32.WaitForSingleObjectEx(h, if (self.common.surface_id == 0) 100 else 0, 0);
    }

    // Persistent grid texture + scissor rasterizer state. Both are safe to
    // call every frame — they early-return when up to date.
    grid.ensureTexture(self, client_w, client_h);
    _ = grid.ensureScissorRasterizerState(self);

    const cs = self.font_service.cell_size_xy;
    const sb_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w: u32 = client_w -| sb_px;
    const shader_col: u32 = @divTrunc(grid_w + cs.x - 1, cs.x);
    // The tab bar is a separate pixel band at the top (height tab_bar_h),
    // painted via D2D after the grid. The cell grid is terminal-only and
    // the grid quad is drawn under a viewport offset by tab_bar_h; the
    // shader subtracts tab_bar_h from SV_Position.y.
    const tab_bar_h: u32 = @intCast(@max(0, self.common.tab_bar_height));
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

// Render-device-local band copy, (re)created on size change. A rebuild drops
// the paint signature so the next frame repaints and refills it — a fresh
// texture's contents are undefined.
fn bandLocal(self: *D3d11Renderer, width: u32, height: u32) *win32.ID3D11Texture2D {
    if (self.band_local) |t| {
        if (self.band_local_w == width and self.band_local_h == height) return t;
        _ = t.IUnknown.Release();
        self.band_local = null;
    }
    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    var texture: *win32.ID3D11Texture2D = undefined;
    const hr = self.device.CreateTexture2D(&desc, null, &texture);
    if (hr < 0) fatalHr("CreateBandLocalTexture", hr);
    self.band_local = texture;
    self.band_local_w = width;
    self.band_local_h = height;
    self.tabbar_sig_tex = null;
    return texture;
}

fn paintChromeAndPresent(self: *D3d11Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw, remote_session: bool) void {
    // Tab-bar band: paint proportionally into the offscreen band texture,
    // then copy it onto the back buffer's top strip. Mirrors the
    // glyph-staging pattern (D2D EndDraw flushes before the D3D copy reads
    // the texture).
    if (prepared.tab_bar_h > 0) {
        const band = self.font_service.band_texture.getOrCreate(
            self.font_service.device,
            self.font_service.d2d_factory,
            prepared.client_w,
            prepared.tab_bar_h,
        );
        const local = self.bandLocal(prepared.client_w, prepared.tab_bar_h);
        const sig = tabbar_paint.signature(tabbar, self.cache_gen, prepared.cs.x, prepared.client_w, prepared.tab_bar_h);
        const reusable = self.tabbar_sig_tex == band.texture and self.tabbar_sig == sig;
        if (!reusable) {
            gpu.acquireFontWrite(band.mutex);
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
            gpu.releaseFontWrite(band.mutex);
            const imported_band = self.band_bridge.acquireRead(self.device, band.texture);
            defer self.band_bridge.releaseRead();
            self.context.CopyResource(&local.ID3D11Resource, &imported_band.ID3D11Resource);
            self.tabbar_sig = sig;
            self.tabbar_sig_tex = band.texture;
            self.diag_tabbar_paints += 1;
        }
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
            self.context.CopySubresourceRegion(&bb.ID3D11Resource, 0, 0, 0, 0, &local.ID3D11Resource, 0, &src_box);
        }
    }

    // Local hardware: Present(0,0). SetTimer caps producer rate; DXGI
    // offloads rasterization to TPP workers without blocking the UI
    // thread, and a sync-interval would just stack with the 16ms cap.
    //
    // Remote/software (RDP session or RDP w/o RemoteFX -> WARP):
    // Present(1,0). Software rasterization can't sustain 60fps anyway, so
    // the "halve FPS" concern from the local path doesn't apply. Critically,
    // the SetTimer cap only bounds paint frequency; with WARP each frame
    // still costs real CPU on worker threads, and uncapped producer rate piles
    // up workers (~30% CPU during spinner animation). On RDP with a hardware
    // adapter, each frame still pays encode/transport cost, so use the same
    // back-pressure policy whenever SM_REMOTESESSION is set.
    //
    // OCCLUDED is handled by the cheap early TEST probe in prepareFrame.
    // This final Present always submits the frame.
    const sync_interval: u32 = if (self.common.remote_or_software_adapter or remote_session) 1 else 0;
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

// Called by the WM_APP_GLYPH_READY handler. Validates the result against
// the renderer-level `cache_gen` (covers full cache rebuilds) and the
// cache's per-slot `gen` (covers in-cache slot reuse) before uploading the
// BGRA bytes into the atlas slot's pixel rectangle. Failed worker results
// cancel their pending reservation so the next render can retry. Returns
// true iff renderer/cache state changed and the dispatcher should request a
// render. The caller still owns `result` and frees it after we return.
pub fn applyGlyphResult(self: *D3d11Renderer, result: *RasterResult) bool {
    return glyph_mod.applyRasterResult(self, result);
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

pub fn releaseKittyImagesForTab(self: *D3d11Renderer, tab_id: types.TabId) void {
    self.kitty_images.releaseForTab(std.heap.page_allocator, tab_id);
    self.grid_force_full = true;
}

test "D3D11 accepts every generated DirectX shader asset" {
    var device: *win32.ID3D11Device = undefined;
    var context: *win32.ID3D11DeviceContext = undefined;
    const levels = [_]win32.D3D_FEATURE_LEVEL{.@"11_0"};
    const hr = win32.D3D11CreateDevice(
        null,
        .WARP,
        null,
        .{},
        &levels,
        levels.len,
        win32.D3D11_SDK_VERSION,
        &device,
        null,
        &context,
    );
    try std.testing.expect(hr >= 0);
    defer _ = context.IUnknown.Release();
    defer _ = device.IUnknown.Release();

    var vertex_shader: *win32.ID3D11VertexShader = undefined;
    const vertex_hr = device.CreateVertexShader(
        shader_assets.vertex.dxbc.ptr,
        shader_assets.vertex.dxbc.len,
        null,
        &vertex_shader,
    );
    try std.testing.expect(vertex_hr >= 0);
    defer _ = vertex_shader.IUnknown.Release();

    var pixel_shader: *win32.ID3D11PixelShader = undefined;
    const pixel_hr = device.CreatePixelShader(
        shader_assets.pixel.dxbc.ptr,
        shader_assets.pixel.dxbc.len,
        null,
        &pixel_shader,
    );
    try std.testing.expect(pixel_hr >= 0);
    defer _ = pixel_shader.IUnknown.Release();

    var image_pixel_shader: *win32.ID3D11PixelShader = undefined;
    const image_pixel_hr = device.CreatePixelShader(
        shader_assets.image_pixel.dxbc.ptr,
        shader_assets.image_pixel.dxbc.len,
        null,
        &image_pixel_shader,
    );
    try std.testing.expect(image_pixel_hr >= 0);
    defer _ = image_pixel_shader.IUnknown.Release();
}

test "a failed second D3D11 device creation retains the font service device" {
    try std.testing.expectEqual(DeviceSource.dedicated, deviceSourceForCreateResult(0));
    try std.testing.expectEqual(DeviceSource.font_service, deviceSourceForCreateResult(-1));
}

test "a glyph failure from another pane cannot cancel this pane's pending slot" {
    const allocator = std.testing.allocator;
    var common: RendererCommon = undefined;
    common.surface_id = 8;
    var renderer: D3d11Renderer = undefined;
    renderer.common = &common;
    renderer.cache_gen = 1;
    renderer.glyph_cache = try GlyphIndexCache.init(allocator, 2);
    defer renderer.glyph_cache.?.deinit(allocator);
    const key: GlyphIndexCache.Key = .init('x', &.{}, .single, .regular);
    const reserved = (try renderer.glyph_cache.?.reserve(allocator, key)).newly_reserved_pending;
    var result: RasterResult = .{
        .surface_id = 7,
        .slot = reserved.index,
        .slot_gen = reserved.slot_gen,
        .cache_gen = renderer.cache_gen,
        .key = key,
        .bytes = &.{},
        .w = 0,
        .h = 0,
        .is_color = false,
        .failed = true,
    };
    try std.testing.expect(!renderer.applyGlyphResult(&result));
    try std.testing.expect((try renderer.glyph_cache.?.reserve(allocator, key)) == .already_pending);
    result.surface_id = common.surface_id;
    try std.testing.expect(renderer.applyGlyphResult(&result));
    try std.testing.expect((try renderer.glyph_cache.?.reserve(allocator, key)) == .newly_reserved_pending);
}

test "pane surfaces share GPU infrastructure and own separate drawing resources" {
    var common: RendererCommon = undefined;
    var fonts = FontService.init(&common, 96, .{}, true, null);
    defer fonts.deinit();
    var parent = try D3d11Renderer.init(&common, &fonts, null);
    defer parent.deinit();
    var pane_common = common;
    pane_common.surface_id = 1;
    pane_common.tab_bar_height = 0;
    var pane = D3d11Renderer.initSurface(&parent, &pane_common);
    defer pane.deinit();
    try std.testing.expect(pane.device == parent.device);
    try std.testing.expect(pane.context == parent.context);
    try std.testing.expect(pane.font_service == parent.font_service);
    try std.testing.expect(pane.vertex_shader == parent.vertex_shader);
    try std.testing.expect(pane.common != parent.common);
    try std.testing.expect(pane.cellsResize(4));
    try std.testing.expect(parent.cellsResize(4));
    try std.testing.expect(pane.shader_cells.cell_buf != parent.shader_cells.cell_buf);
    _ = pane.atlasEnsure(.{ .x = 32, .y = 32 });
    _ = parent.atlasEnsure(.{ .x = 32, .y = 32 });
    try std.testing.expect(pane.glyph_texture.obj != null);
    try std.testing.expect(parent.glyph_texture.obj != null);
    try std.testing.expect(pane.glyph_texture.obj != parent.glyph_texture.obj);
    try std.testing.expectEqual(@as(i32, 0), pane.common.tab_bar_height);
    try std.testing.expect(parent.common.tab_bar_height > 0);
}
