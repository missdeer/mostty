//! D3D12 renderer backend.
//!
//! Fulfils the whole renderer facade contract, which is the precondition for
//! being selectable at all: a backend that could only draw part of the
//! picture would be a selectable broken terminal. It is nonetheless a
//! research option, not a default — only static and low-frequency correctness
//! is claimed here, and sustained-load behaviour is a later concern.
//!
//! Everything above the GPU boundary — translating terminal state into cells,
//! glyph cache policy, grid geometry, dirty ranges — is the shared source in
//! `d3d11/cell_buffer.zig`, `d3d11/glyph.zig` and friends, reached through the
//! contract in `shared.zig`. This file is only the D3D12 half.

const D3d12Renderer = @This();

const std = @import("std");
const builtin = @import("builtin");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../../config.zig");
const FontService = @import("../font_service.zig");
const GlyphIndexCache = @import("../glyph_index_cache.zig");
const RendererCommon = @import("../renderer_common.zig");
const shared = @import("../shared.zig");
const types = @import("../types.zig");

const bg_image = @import("../d3d11/background_image.zig");
const cell_buffer = @import("../d3d11/cell_buffer.zig");
const com = @import("../d3d11/com.zig");
const glyph_mod = @import("../d3d11/glyph.zig");
const gpu = @import("../d3d11/gpu.zig");
const grid = @import("../d3d11/grid.zig");
const kitty_image_mod = @import("../d3d11/kitty_images.zig");
const swap_chain_mod = @import("../d3d11/swap_chain.zig");
const tabbar_paint = @import("../d3d11/tabbar_paint.zig");
const shader_assets = @import("../shader_assets.zig");

const pipeline = @import("pipeline.zig");
const present = @import("present.zig");
const upload = @import("upload.zig");

const CellXY = gpu.CellXY;
const shader = gpu.shader;

const log = std.log.scoped(.d3d12);

pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const scrollbarWidth = gpu.scrollbarWidth;

pub const StartupError = error{
    AdapterUnavailable,
    DeviceUnavailable,
    CommandQueueUnavailable,
    CommandAllocatorUnavailable,
    CommandListUnavailable,
    FenceUnavailable,
    FenceEventUnavailable,
    BindingLayoutRejected,
    GridPipelineRejected,
    ImagePipelineRejected,
    DescriptorHeapUnavailable,
    RenderTargetHeapUnavailable,
    PresentationUnavailable,
};

pub fn startupErrorDescription(err: StartupError) []const u8 {
    return switch (err) {
        error.AdapterUnavailable => "the configured GPU adapter is unavailable to D3D12",
        error.DeviceUnavailable => "no D3D12 device supports feature level 11_0",
        error.CommandQueueUnavailable => "the D3D12 command queue could not be created",
        error.CommandAllocatorUnavailable => "a D3D12 command allocator could not be created",
        error.CommandListUnavailable => "the D3D12 command list could not be created",
        error.FenceUnavailable => "the D3D12 completion fence could not be created",
        error.FenceEventUnavailable => "the D3D12 completion event could not be created",
        error.BindingLayoutRejected => "the D3D12 resource binding layout was rejected",
        error.GridPipelineRejected => "the D3D12 grid shader pipeline was rejected",
        error.ImagePipelineRejected => "the D3D12 image shader pipeline was rejected",
        error.DescriptorHeapUnavailable => "a D3D12 shader descriptor heap is unavailable",
        error.RenderTargetHeapUnavailable => "the D3D12 render-target descriptor heap is unavailable",
        error.PresentationUnavailable => "the D3D12 presentation surface could not be attached to desktop composition",
    };
}

const debug_stats_enabled = builtin.mode == .Debug;
const DebugStats = struct {
    rows_uploaded: u64 = 0,
    rows_skipped: u64 = 0,
};

/// This backend cannot open the font service's shared surfaces — the
/// mutual-exclusion primitive they rely on has no D3D12 equivalent — so it
/// takes glyph pixels as ordinary memory instead. Same rasterizer, different
/// handoff form; see `shared.GlyphHandoff`.
pub const glyph_handoff: shared.GlyphHandoff = .cpu_pixels;

/// One inline image's GPU resource. Left in shader-readable state for its
/// whole life, so drawing never has to transition it.
pub const KittyImage = struct {
    resource: *win32.ID3D12Resource,
    owner: *D3d12Renderer,

    /// The shared cache drops images whenever the terminal stops referencing
    /// them, which can happen while submitted work is still sampling this
    /// texture. Retiring a GPU-visible resource is one of the lifecycle points
    /// that stays conservative: it is rare, so settling first costs nothing in
    /// the sustained path and is the only thing that makes the release safe.
    pub fn release(self: *KittyImage) void {
        self.owner.settleBeforeRelease();
        _ = self.resource.IUnknown.Release();
    }
};

pub const BackgroundImage = struct {
    resource: ?*win32.ID3D12Resource = null,
    src_w: u32 = 0,
    src_h: u32 = 0,

    pub fn loaded(self: BackgroundImage) bool {
        return self.resource != null;
    }

    pub fn release(self: *BackgroundImage) void {
        if (self.resource) |r| _ = r.IUnknown.Release();
        self.* = .{};
    }
};

// --- Shared-layer state (mirrors the other backend field for field) ---
common: *RendererCommon,
font_service: *FontService,
shadow_cells: []shader.Cell = &.{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
cache_gen: u32 = 0,
grid_force_full: bool = true,
last_const_snapshot: grid.ConfigSnapshot = .{},
// Signature of the content last painted into the CPU band, plus the D2D target
// it came from. The band pixels survive across frames, so a matching signature
// skips the D2D pass; the staging copy still runs because each frame gets a
// fresh back buffer and a fresh upload-arena allocation.
tabbar_sig: u64 = 0,
tabbar_sig_rt: ?*win32.ID2D1RenderTarget = null,
stats: DebugStats = .{},
diag_rows_uploaded: u64 = 0,
diag_rows_skipped: u64 = 0,

background_image: BackgroundImage = .{},
bg_image_path: []const u8 = &.{},
bg_image_opacity: f32 = 1.0,
bg_image_position: Config.BackgroundImagePosition = .center,
bg_image_fit: Config.BackgroundImageFit = .contain,
bg_image_repeat: bool = false,
bg_image_req_id: u32 = 0,
kitty_images: kitty_image_mod.Cache(KittyImage) = .{},

// --- D3D12 device and explicit synchronization ---
device: *win32.ID3D12Device,
queue: *win32.ID3D12CommandQueue,
command_allocators: [upload.Ring.generations]*win32.ID3D12CommandAllocator,
command_list: *win32.ID3D12GraphicsCommandList,
fence: *win32.ID3D12Fence,
fence_event: win32.HANDLE,
fence_value: u64 = 0,
/// True while `command_list` is open. Uploads triggered outside a frame (an
/// async glyph landing, say) accumulate in the same list and are carried by
/// the next present.
recording: bool = false,
/// True while a generation is held. A batch spans everything recorded between
/// two presents, which may be several submissions if a resource has to be
/// retired part-way through; it passes the throttle decision exactly once.
batch_open: bool = false,

root_signature: *win32.ID3D12RootSignature,
pso_grid: *win32.ID3D12PipelineState,
pso_inline_image: *win32.ID3D12PipelineState,
/// One shader-visible descriptor heap per generation. The GPU reads
/// descriptors when the work runs, so a single heap rewritten every frame
/// would be read by the previous frame's still-running work — the same hazard
/// as staged bytes, and equally invisible on screen.
descriptor_heaps: [upload.Ring.generations]pipeline.Descriptors,
render_targets: pipeline.RenderTargets,
/// One staging arena per generation, plus the bookkeeping that decides which
/// generation may be handed out.
arenas: [upload.Ring.generations]upload.Arena = @splat(.{}),
ring: upload.Ring = .{},

surface: ?present.Surface = null,
occluded: bool = false,

grid_target: upload.Tracked = .{},
grid_size: win32.SIZE = .{ .cx = 0, .cy = 0 },
back_buffer: upload.Tracked = .{},

cells: upload.Tracked = .{},
cells_count: u32 = 0,
atlas: upload.Tracked = .{},
atlas_size: ?CellXY = null,

pub fn init(
    common: *RendererCommon,
    font_service: *FontService,
    configured_gpu: ?[]const u8,
) StartupError!D3d12Renderer {
    const selected_adapter = if (configured_gpu) |name|
        swap_chain_mod.findHardwareAdapterByName(name) orelse return error.AdapterUnavailable
    else
        null;
    defer if (selected_adapter) |a| {
        _ = a.IUnknown.Release();
    };

    var device: *win32.ID3D12Device = undefined;
    {
        const hr = win32.D3D12CreateDevice(
            if (selected_adapter) |a| @ptrCast(a) else null,
            .@"11_0",
            win32.IID_ID3D12Device,
            @ptrCast(&device),
        );
        if (hr < 0) return error.DeviceUnavailable;
    }
    errdefer _ = device.IUnknown.Release();

    var queue: *win32.ID3D12CommandQueue = undefined;
    {
        const desc = win32.D3D12_COMMAND_QUEUE_DESC{
            .Type = .DIRECT,
            .Priority = 0,
            .Flags = .{},
            .NodeMask = 0,
        };
        const hr = device.CreateCommandQueue(&desc, win32.IID_ID3D12CommandQueue, @ptrCast(&queue));
        if (hr < 0) return error.CommandQueueUnavailable;
    }
    errdefer _ = queue.IUnknown.Release();

    // One allocator per generation. An allocator may only be reset once the
    // GPU is done with everything recorded from it, so sharing a single one
    // across generations would force a full wait every frame — the very thing
    // the generation ring exists to remove.
    var command_allocators: [upload.Ring.generations]*win32.ID3D12CommandAllocator = undefined;
    var command_allocator_count: usize = 0;
    errdefer for (command_allocators[0..command_allocator_count]) |allocator| {
        _ = allocator.IUnknown.Release();
    };
    for (&command_allocators) |*slot| {
        const hr = device.CreateCommandAllocator(
            .DIRECT,
            win32.IID_ID3D12CommandAllocator,
            @ptrCast(slot),
        );
        if (hr < 0) return error.CommandAllocatorUnavailable;
        command_allocator_count += 1;
    }

    var command_list: *win32.ID3D12GraphicsCommandList = undefined;
    {
        const hr = device.CreateCommandList(
            0,
            .DIRECT,
            command_allocators[0],
            null,
            win32.IID_ID3D12GraphicsCommandList,
            @ptrCast(&command_list),
        );
        if (hr < 0) return error.CommandListUnavailable;
        // Created open; close it so the first `beginRecording` starts from a
        // known state like every later frame does.
        if (command_list.Close() < 0) {
            _ = command_list.IUnknown.Release();
            return error.CommandListUnavailable;
        }
    }
    errdefer _ = command_list.IUnknown.Release();

    var fence: *win32.ID3D12Fence = undefined;
    {
        const hr = device.CreateFence(0, .{}, win32.IID_ID3D12Fence, @ptrCast(&fence));
        if (hr < 0) return error.FenceUnavailable;
    }
    errdefer _ = fence.IUnknown.Release();
    const fence_event = win32.CreateEventW(null, 0, 0, null) orelse return error.FenceEventUnavailable;
    errdefer _ = win32.CloseHandle(fence_event);

    const root_signature = pipeline.createRootSignature(device) catch return error.BindingLayoutRejected;
    errdefer _ = root_signature.IUnknown.Release();
    const pso_grid = pipeline.createPipeline(
        device,
        root_signature,
        shader_assets.pixel.dxil,
        .opaque_write,
    ) catch return error.GridPipelineRejected;
    errdefer _ = pso_grid.IUnknown.Release();
    const pso_inline_image = pipeline.createPipeline(
        device,
        root_signature,
        shader_assets.image_pixel.dxil,
        .premultiplied_over,
    ) catch return error.ImagePipelineRejected;
    errdefer _ = pso_inline_image.IUnknown.Release();
    var descriptor_heaps: [upload.Ring.generations]pipeline.Descriptors = undefined;
    var descriptor_heap_count: usize = 0;
    errdefer for (descriptor_heaps[0..descriptor_heap_count]) |*heap| heap.release();
    for (&descriptor_heaps) |*slot| {
        slot.* = pipeline.Descriptors.init(device, pipeline.initial_table_count) catch
            return error.DescriptorHeapUnavailable;
        descriptor_heap_count += 1;
    }
    const render_targets = pipeline.RenderTargets.init(device) catch return error.RenderTargetHeapUnavailable;

    // The other backend classifies the adapter for its present policy; do the
    // same so the shared throttle decision sees identical inputs.
    common.remote_or_software_adapter = detectRemoteOrSoftware(selected_adapter);
    log.info(
        "D3D12 device created (research backend): selection={s}, remote_or_software={}",
        .{ if (configured_gpu != null) "explicit" else "automatic", common.remote_or_software_adapter },
    );

    return .{
        .common = common,
        .font_service = font_service,
        .device = device,
        .queue = queue,
        .command_allocators = command_allocators,
        .command_list = command_list,
        .fence = fence,
        .fence_event = fence_event,
        .root_signature = root_signature,
        .pso_grid = pso_grid,
        .pso_inline_image = pso_inline_image,
        .descriptor_heaps = descriptor_heaps,
        .render_targets = render_targets,
    };
}

pub fn initializeWindow(self: *D3d12Renderer, hwnd: win32.HWND) StartupError!void {
    if (self.surface != null) return;
    const size = win32.getClientSize(hwnd);
    if (size.cx <= 0 or size.cy <= 0) return error.PresentationUnavailable;
    self.surface = present.Surface.init(
        &self.queue.IUnknown,
        null,
        hwnd,
        @intCast(size.cx),
        @intCast(size.cy),
        pipeline.render_target_format,
    ) catch return error.PresentationUnavailable;
}

fn fatal(what: []const u8, hr: i32) noreturn {
    std.debug.panic("renderer = d3d12: {s} failed (hresult=0x{x})", .{ what, @as(u32, @bitCast(hr)) });
}

fn detectRemoteOrSoftware(adapter: ?*win32.IDXGIAdapter1) bool {
    const a = adapter orelse return false;
    var desc: win32.DXGI_ADAPTER_DESC1 = undefined;
    if (a.GetDesc1(&desc) < 0) return false;
    const software_flag: u32 = @bitCast(win32.DXGI_ADAPTER_FLAG_SOFTWARE);
    return desc.Flags & software_flag != 0;
}

pub fn deinit(self: *D3d12Renderer) void {
    self.waitForGpu();
    if (self.recording) {
        _ = self.command_list.Close();
        self.recording = false;
    }
    // End the batch before anything is retired: the releases below settle as
    // they go, and an open batch would have them reopen a command list that is
    // about to be released.
    self.batch_open = false;

    self.kitty_images.deinit(std.heap.page_allocator);
    if (self.glyph_cache) |*c| {
        c.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};

    self.background_image.release();
    self.atlas.release();
    self.cells.release();
    self.back_buffer.release();
    self.grid_target.release();
    for (&self.arenas) |*a| a.deinit();

    self.render_targets.release();
    for (&self.descriptor_heaps) |*d| d.release();
    _ = self.pso_inline_image.IUnknown.Release();
    _ = self.pso_grid.IUnknown.Release();
    _ = self.root_signature.IUnknown.Release();

    if (self.surface) |*s| s.deinit();
    self.surface = null;

    _ = win32.CloseHandle(self.fence_event);
    _ = self.fence.IUnknown.Release();
    _ = self.command_list.IUnknown.Release();
    for (self.command_allocators) |a| _ = a.IUnknown.Release();
    _ = self.queue.IUnknown.Release();
    _ = self.device.IUnknown.Release();
    self.* = undefined;
}

pub fn onFontStateChanged(self: *D3d12Renderer) void {
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
    self.grid_force_full = true;
}

// --- Explicit synchronization ---

/// How long the presentation gate is allowed to hold a frame up. Matches the
/// other backend: it is a best-effort gate on DXGI queue availability, so a
/// DWM hiccup must not be able to freeze the message pump.
const presentation_gate_ms: u32 = 100;
/// How long the completion signal is allowed to take before we call the GPU
/// wedged. Unlike the gate above this is a correctness wait, so it is generous
/// and fatal rather than short and best-effort.
const completion_wait_ms: u32 = 10_000;

fn commandAllocator(self: *D3d12Renderer) *win32.ID3D12CommandAllocator {
    return self.command_allocators[self.ring.cursor];
}

fn arena(self: *D3d12Renderer) *upload.Arena {
    return &self.arenas[self.ring.cursor];
}

fn descriptors(self: *D3d12Renderer) *pipeline.Descriptors {
    return &self.descriptor_heaps[self.ring.cursor];
}

/// Take ownership of a generation for a new submission batch.
///
/// Every batch passes through here before anything is recorded into it, which
/// is what keeps the throttle decision below the only one on the frame path:
/// work arriving between frames — an async glyph landing, say — joins a batch
/// that has already been let through rather than opening an ungated one.
fn beginBatch(self: *D3d12Renderer) void {
    if (self.batch_open) {
        self.beginRecording();
        return;
    }
    self.awaitNextGeneration();
    self.ring.advance();
    if (!self.ring.currentIsSafe(self.fence.GetCompletedValue())) std.debug.panic(
        "renderer = d3d12: staging generation {d} was handed out while the GPU may still " ++
            "be reading it",
        .{self.ring.cursor},
    );
    if (self.commandAllocator().Reset() < 0) fatal("CommandAllocator.Reset", 0);
    self.arena().recycle();
    self.batch_open = true;
    self.beginRecording();
}

/// The single throttle decision.
///
/// Presentation readiness and the completion of the generation about to be
/// reused are solved together, before any ownership is taken. Deciding them in
/// two places would either serialize two conditions that can progress at once
/// or leave a hidden idle wait in one of them, and that stacked delay is what
/// this backend has to avoid to stay level with the other one.
fn awaitNextGeneration(self: *D3d12Renderer) void {
    const owed = self.ring.blocking();
    var handles: [2]win32.HANDLE = undefined;
    var count: u32 = 0;
    if (self.surface) |*s| {
        handles[count] = s.frame_latency_waitable;
        count += 1;
    }
    const armed = if (owed) |value| self.armCompletion(value) else false;
    if (armed) {
        handles[count] = self.fence_event;
        count += 1;
    }
    if (count == 0) return;

    // One wait for both conditions: whichever is slower sets the cost, and
    // neither is observed behind the other.
    _ = win32.WaitForMultipleObjects(count, &handles, 1, presentation_gate_ms);

    // The presentation gate is best-effort and is now done with either way.
    // The completion signal is not: handing this generation out early is the
    // corruption this backend exists to avoid, so it gets the rest of the
    // budget. In the ordinary case where the GPU is the slower of the two,
    // the wait above already covered most of it.
    if (owed) |value| self.awaitCompletion(value);
}

/// Block until the fence has reached `value`.
///
/// One event serves every wait site here, so a wake is not by itself proof
/// that this value was reached — an earlier registration for a lower value can
/// signal the same event. The fence is therefore rechecked rather than
/// trusted, which keeps this correct locally instead of depending on no other
/// site ever leaving a registration outstanding.
fn awaitCompletion(self: *D3d12Renderer, value: u64) void {
    while (self.fence.GetCompletedValue() < value) {
        if (!self.armCompletion(value)) return;
        // Bounded so a wedged GPU surfaces as a hang we can see rather than an
        // unkillable message pump.
        if (win32.WaitForSingleObject(self.fence_event, completion_wait_ms) != .NO_ERROR) {
            fatal("WaitForSingleObject(fence)", 0);
        }
    }
}

/// Arm the completion event for `value`, reporting whether a wait is needed.
///
/// The event is reset first because it is auto-reset: an earlier arming whose
/// signal nobody consumed would otherwise let the next wait return at once,
/// which reads as "the GPU is done" when it is not.
fn armCompletion(self: *D3d12Renderer, value: u64) bool {
    if (self.fence.GetCompletedValue() >= value) return false;
    _ = win32.ResetEvent(self.fence_event);
    if (self.fence.SetEventOnCompletion(value, self.fence_event) < 0) {
        fatal("SetEventOnCompletion", 0);
    }
    return true;
}

fn beginRecording(self: *D3d12Renderer) void {
    if (self.recording) return;
    if (self.command_list.Reset(self.commandAllocator(), null) < 0) fatal("CommandList.Reset", 0);
    self.recording = true;
}

/// Close and submit whatever is recorded, binding this generation to a new
/// completion value.
///
/// It does not wait. The wait belongs to the single decision point that hands
/// the generation out again, which is what lets the CPU record the next frame
/// while the GPU is still reading this one.
fn submit(self: *D3d12Renderer) void {
    if (!self.recording) return;
    if (self.command_list.Close() < 0) fatal("CommandList.Close", 0);
    self.recording = false;

    var lists = [_]?*win32.ID3D12CommandList{@ptrCast(self.command_list)};
    self.queue.ExecuteCommandLists(lists.len, &lists);
    self.signalCompletion();
}

/// Make it safe to release a resource that recorded work may reference.
///
/// A D3D12 command list does not keep the resources it names alive, so
/// waiting on the fence is not enough on its own: anything already recorded
/// but not yet submitted would execute against freed memory. Submitting first
/// and only then waiting is what closes that window.
///
/// This is one of the lifecycle points kept deliberately conservative: it
/// retires GPU-visible resources and is rare, so a full wait costs nothing in
/// the sustained path. The batch stays open across it — it has already passed
/// the throttle decision and must not take it a second time.
fn settleBeforeRelease(self: *D3d12Renderer) void {
    self.submit();
    self.waitForGpu();
    if (!self.batch_open) return;
    // Everything staged in this generation has now executed, so the arena can
    // be handed back and the allocator reset without leaving the batch.
    if (self.commandAllocator().Reset() < 0) fatal("CommandAllocator.Reset", 0);
    self.arena().recycle();
    self.beginRecording();
}

fn signalCompletion(self: *D3d12Renderer) void {
    self.fence_value += 1;
    if (self.queue.Signal(self.fence, self.fence_value) < 0) fatal("Queue.Signal", 0);
    self.ring.bind(self.fence_value);
}

/// Block until the queue has drained. Reserved for lifecycle points that
/// retire or replace GPU-visible resources.
fn waitForGpu(self: *D3d12Renderer) void {
    self.signalCompletion();
    self.awaitCompletion(self.fence_value);
}

fn reserve(self: *D3d12Renderer, len: u64, alignment: u64) upload.Arena.Reservation {
    return self.arena().reserve(self.device, len, alignment) catch |err| {
        std.debug.panic("renderer = d3d12: upload staging failed ({s})", .{@errorName(err)});
    };
}

// --- Shared-layer GPU contract ---

pub fn cellsResize(self: *D3d12Renderer, count: u32) bool {
    if (count == self.cells_count and self.cells.resource != null) return false;
    self.settleBeforeRelease();
    self.cells.release();
    self.cells_count = count;
    if (count == 0) {
        // The table stays bound even with no cells, and D3D12 requires every
        // descriptor it covers to be valid — a stale one would point at the
        // buffer just released.
        self.refreshSharedDescriptors();
        return true;
    }

    const bytes: u64 = @as(u64, count) * @sizeOf(shader.Cell);
    var resource: *win32.ID3D12Resource = undefined;
    const props = upload.heapProps(.DEFAULT);
    const desc = upload.bufferDesc(bytes);
    if (self.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        win32.D3D12_RESOURCE_STATE_COPY_DEST,
        null,
        win32.IID_ID3D12Resource,
        @ptrCast(&resource),
    ) < 0) fatal("CreateCommittedResource(cells)", 0);
    self.cells = .{ .resource = resource, .state = win32.D3D12_RESOURCE_STATE_COPY_DEST };

    self.refreshSharedDescriptors();
    return true;
}

pub fn cellsUpload(self: *D3d12Renderer, first_cell: u32, cells: []const shader.Cell) void {
    const resource = self.cells.resource orelse return;
    self.beginBatch();
    self.cells.moveTo(self.command_list, win32.D3D12_RESOURCE_STATE_COPY_DEST);

    const bytes = std.mem.sliceAsBytes(cells);
    const res = self.reserve(bytes.len, 4);
    @memcpy(res.bytes, bytes);
    self.command_list.CopyBufferRegion(
        resource,
        @as(u64, first_cell) * @sizeOf(shader.Cell),
        self.arena().buffer.?,
        res.offset,
        bytes.len,
    );
}

pub fn atlasEnsure(self: *D3d12Renderer, tex_pixel: CellXY) bool {
    if (self.atlas_size) |s| {
        if (s.eql(tex_pixel)) return true;
    }
    self.settleBeforeRelease();
    self.atlas.release();

    var resource: *win32.ID3D12Resource = undefined;
    const props = upload.heapProps(.DEFAULT);
    const desc = upload.texture2dDesc(.B8G8R8A8_UNORM, tex_pixel.x, tex_pixel.y, .{});
    if (self.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        win32.D3D12_RESOURCE_STATE_COPY_DEST,
        null,
        win32.IID_ID3D12Resource,
        @ptrCast(&resource),
    ) < 0) fatal("CreateCommittedResource(glyph atlas)", 0);
    self.atlas = .{ .resource = resource, .state = win32.D3D12_RESOURCE_STATE_COPY_DEST };
    self.atlas_size = tex_pixel;

    self.refreshSharedDescriptors();
    return false;
}

pub fn atlasWriteCpu(
    self: *D3d12Renderer,
    dst_coord: CellXY,
    region: CellXY,
    src_ptr: [*]const u8,
    src_row_pitch: u32,
) void {
    const resource = self.atlas.resource orelse return;
    self.beginBatch();
    self.atlas.moveTo(self.command_list, win32.D3D12_RESOURCE_STATE_COPY_DEST);

    // D3D12 requires each staged row to start on a 256-byte boundary, so the
    // caller's rows are repacked rather than copied wholesale.
    const dst_pitch: u32 = @intCast(upload.alignUp(@as(u64, region.x) * 4, upload.texture_row_alignment));
    const total: u64 = @as(u64, dst_pitch) * region.y;
    const res = self.reserve(total, upload.texture_placement_alignment);
    const row_bytes: usize = @as(usize, region.x) * 4;
    var y: u32 = 0;
    while (y < region.y) : (y += 1) {
        const src = src_ptr[y * src_row_pitch ..][0..row_bytes];
        @memcpy(res.bytes[y * dst_pitch ..][0..row_bytes], src);
    }

    const src_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = self.arena().buffer.?,
        .Type = .PLACED_FOOTPRINT,
        .Anonymous = .{ .PlacedFootprint = .{
            .Offset = res.offset,
            .Footprint = .{
                .Format = .B8G8R8A8_UNORM,
                .Width = region.x,
                .Height = region.y,
                .Depth = 1,
                .RowPitch = dst_pitch,
            },
        } },
    };
    const dst_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = resource,
        .Type = .SUBRESOURCE_INDEX,
        .Anonymous = .{ .SubresourceIndex = 0 },
    };
    self.command_list.CopyTextureRegion(&dst_loc, dst_coord.x, dst_coord.y, 0, &src_loc, null);
}

pub fn atlasClear(self: *D3d12Renderer, dst_coord: CellXY) void {
    const cs = self.font_service.cell_size_xy;
    const row_bytes: usize = @as(usize, cs.x) * 4;
    const zeros = std.heap.page_allocator.alloc(u8, row_bytes * cs.y) catch return;
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    self.atlasWriteCpu(dst_coord, cs, zeros.ptr, @intCast(row_bytes));
}

/// Unreachable for this backend: it declares `cpu_pixels`, so the shared
/// glyph path never takes the shared-surface branch. Present only so the
/// contract surface is identical for both backends.
pub fn atlasCopyStaging(
    self: *D3d12Renderer,
    staging: *gpu.StagingTexture.Cached,
    first: ?gpu.AtlasCopy,
    second: ?gpu.AtlasCopy,
) void {
    _ = .{ self, staging, first, second };
    unreachable;
}

/// Drop the background image and re-point every t2 descriptor at nothing.
/// Leaving them addressing a released resource is exactly the kind of stale
/// descriptor D3D12 will happily sample from.
pub fn backgroundImageRelease(self: *D3d12Renderer) void {
    if (!self.background_image.loaded()) return;
    self.settleBeforeRelease();
    self.background_image.release();
    self.refreshSharedDescriptors();
}

pub fn backgroundImageUpload(self: *D3d12Renderer, decoded: gpu.DecodedBackground) void {
    self.backgroundImageRelease();
    const resource = self.uploadTexture(
        .B8G8R8A8_UNORM,
        decoded.w,
        decoded.h,
        decoded.pixels,
        decoded.w * 4,
    ) orelse {
        log.warn("background-image: D3D12 upload failed", .{});
        return;
    };
    self.background_image = .{ .resource = resource, .src_w = decoded.w, .src_h = decoded.h };
    self.refreshSharedDescriptors();
}

pub fn kittyImageUpload(
    self: *D3d12Renderer,
    width: u32,
    height: u32,
    rgba: []const u8,
) ?KittyImage {
    const resource = self.uploadTexture(.R8G8B8A8_UNORM, width, height, rgba, width * 4) orelse
        return null;
    return .{ .resource = resource, .owner = self };
}

/// Create a texture, stage its pixels and leave it shader-readable.
fn uploadTexture(
    self: *D3d12Renderer,
    format: win32.DXGI_FORMAT,
    width: u32,
    height: u32,
    pixels: []const u8,
    src_pitch: u32,
) ?*win32.ID3D12Resource {
    var resource: *win32.ID3D12Resource = undefined;
    const props = upload.heapProps(.DEFAULT);
    const desc = upload.texture2dDesc(format, width, height, .{});
    if (self.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        win32.D3D12_RESOURCE_STATE_COPY_DEST,
        null,
        win32.IID_ID3D12Resource,
        @ptrCast(&resource),
    ) < 0) return null;

    self.beginBatch();
    const dst_pitch: u32 = @intCast(upload.alignUp(@as(u64, width) * 4, upload.texture_row_alignment));
    const res = self.reserve(@as(u64, dst_pitch) * height, upload.texture_placement_alignment);
    const row_bytes: usize = @as(usize, width) * 4;
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        @memcpy(res.bytes[y * dst_pitch ..][0..row_bytes], pixels[y * src_pitch ..][0..row_bytes]);
    }

    const src_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = self.arena().buffer.?,
        .Type = .PLACED_FOOTPRINT,
        .Anonymous = .{ .PlacedFootprint = .{
            .Offset = res.offset,
            .Footprint = .{
                .Format = format,
                .Width = width,
                .Height = height,
                .Depth = 1,
                .RowPitch = dst_pitch,
            },
        } },
    };
    const dst_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = resource,
        .Type = .SUBRESOURCE_INDEX,
        .Anonymous = .{ .SubresourceIndex = 0 },
    };
    self.command_list.CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, null);

    var barrier = [_]win32.D3D12_RESOURCE_BARRIER{upload.transition(
        resource,
        win32.D3D12_RESOURCE_STATE_COPY_DEST,
        win32.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,
    )};
    self.command_list.ResourceBarrier(barrier.len, &barrier);
    return resource;
}

// --- Facade contract ---

pub fn render(
    self: *D3d12Renderer,
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
    const prepared = self.prepareFrame(hwnd, term, mouse_in_scrollbar) orelse return;

    const cell_count = prepared.shader_col * prepared.term_shader_row;
    if (self.kitty_images.sync(std.heap.page_allocator, self, tab_id, term)) {
        self.grid_force_full = true;
    }
    const inline_images_present = self.kitty_images.hasVisibleAboveTextPlacements();

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

    self.drawAndPresent(prepared, tabbar, remote_session, .{
        .cell_count = cell_count,
        .dirty_min_row = build.dirty_min_row,
        .dirty_max_row = build.dirty_max_row,
        .resizing = resizing,
        .inline_images_present = inline_images_present,
    });
}

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

fn prepareFrame(
    self: *D3d12Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    mouse_in_scrollbar: bool,
) ?PreparedFrame {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);
    if (client_w == 0 or client_h == 0) return null;

    if (self.surface == null) {
        self.surface = present.Surface.init(
            &self.queue.IUnknown,
            null,
            hwnd,
            client_w,
            client_h,
            pipeline.render_target_format,
        ) catch |err|
            std.debug.panic(
                "renderer = d3d12: presentation surface could not be attached to desktop " ++
                    "composition ({s}); the backend cannot complete a first frame",
                .{@errorName(err)},
            );
    }
    const surface = &self.surface.?;

    const surface_size = surface.size() orelse std.debug.panic(
        "renderer = d3d12: presentation surface size is unreadable; the grid would be " ++
            "copied into a back buffer of unknown extent",
        .{},
    );
    {
        const current = surface_size;
        if (current.w != client_w or current.h != client_h) {
            // Every view onto the old buffers has to be gone before DXGI will
            // resize, and the GPU has to be done with them first.
            // Submit rather than discard: glyph and image uploads recorded
            // between frames are already reflected in the tracked resource
            // states, so dropping them would leave those states describing
            // barriers the GPU never saw.
            self.settleBeforeRelease();
            self.back_buffer.release();
            self.grid_target.release();
            self.grid_size = .{ .cx = 0, .cy = 0 };
            surface.resize(client_w, client_h) catch |err| std.debug.panic(
                "renderer = d3d12: presentation surface resize failed ({s})",
                .{@errorName(err)},
            );
        }
    }

    if (self.occluded) {
        const hr = surface.swap_chain.IDXGISwapChain.Present(0, win32.DXGI_PRESENT_TEST);
        if (hr == present.DXGI_STATUS_OCCLUDED) {
            self.grid_force_full = true;
            return null;
        }
        if (hr < 0) std.debug.panic(
            "renderer = d3d12: occlusion probe failed (hresult=0x{x}); the backend can no " ++
                "longer meet its baseline and recovery is out of scope",
            .{@as(u32, @bitCast(hr))},
        );
        self.occluded = false;
        self.grid_force_full = true;
    }

    // Take the generation for this frame. The presentation-latency gate lives
    // inside that decision now, together with the completion signal, so the
    // frame is held up once by whichever of the two is slower rather than
    // twice in a row.
    self.beginBatch();

    self.ensureGridTarget(client_w, client_h);

    const cs = self.font_service.cell_size_xy;
    const sb_px: u32 = scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w: u32 = client_w -| sb_px;
    const shader_col: u32 = @divTrunc(grid_w + cs.x - 1, cs.x);
    const tab_bar_h: u32 = @intCast(@max(0, self.common.tab_bar_height));
    const term_pixel_h: u32 = client_h -| tab_bar_h;
    const term_shader_row: u32 = @divTrunc(term_pixel_h + cs.y - 1, cs.y);
    if (shader_col > cell_buffer.max_shader_col) return null;

    const atlas = glyph_mod.setupGlyphAtlas(self);
    const tex_cell_count = atlas.tex_cell_count;

    var sb_geom: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 0, .y = 0, .w = 0, .h = 0 };
    {
        const sb = term.screens.active.pages.scrollbar();
        const show = sb.total > sb.len and
            (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
        if (show) {
            const origin_y: f32 = @floatFromInt(tab_bar_h);
            const win_h: f32 = @floatFromInt(client_h -| tab_bar_h);
            const min_track: f32 = 20.0;
            const track_h = @max(min_track, @as(f32, @floatFromInt(sb.len)) /
                @as(f32, @floatFromInt(sb.total)) * win_h);
            const max_offset = sb.total - sb.len;
            const track_y = origin_y + @as(f32, @floatFromInt(sb.offset)) /
                @as(f32, @floatFromInt(max_offset)) * (win_h - track_h);
            sb_geom = .{
                .x = @floatFromInt(grid_w),
                .y = track_y,
                .w = @floatFromInt(sb_px),
                .h = track_h,
            };
        }
    }

    const snapshot: grid.ConfigSnapshot = .{
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
    if (!snapshot.eql(self.last_const_snapshot)) {
        self.grid_force_full = true;
        self.last_const_snapshot = snapshot;
    }

    var config: shader.GridConfig = .{
        .cell_size = .{ cs.x, cs.y },
        .col_count = shader_col,
        .row_count = term_shader_row,
        .scrollbar_y = sb_geom.y,
        .scrollbar_height = sb_geom.h,
        .scrollbar_x = sb_geom.x,
        .scrollbar_width = sb_geom.w,
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

/// The grid is drawn into a texture we own rather than straight into the back
/// buffer, because flip-model back-buffer contents are undefined after each
/// present and partial redraws would have nothing valid to build on.
fn ensureGridTarget(self: *D3d12Renderer, width: u32, height: u32) void {
    if (self.grid_target.resource != null and
        self.grid_size.cx == @as(i32, @intCast(width)) and
        self.grid_size.cy == @as(i32, @intCast(height)))
    {
        return;
    }
    self.settleBeforeRelease();
    self.grid_target.release();

    var resource: *win32.ID3D12Resource = undefined;
    const props = upload.heapProps(.DEFAULT);
    const desc = upload.texture2dDesc(
        pipeline.grid_resource_format,
        width,
        height,
        .{ .ALLOW_RENDER_TARGET = 1 },
    );
    if (self.device.CreateCommittedResource(
        &props,
        .{},
        &desc,
        win32.D3D12_RESOURCE_STATE_RENDER_TARGET,
        null,
        win32.IID_ID3D12Resource,
        @ptrCast(&resource),
    ) < 0) fatal("CreateCommittedResource(grid)", 0);
    self.grid_target = .{
        .resource = resource,
        .state = win32.D3D12_RESOURCE_STATE_RENDER_TARGET,
    };
    self.grid_size = .{ .cx = @intCast(width), .cy = @intCast(height) };

    const rtv_desc = win32.D3D12_RENDER_TARGET_VIEW_DESC{
        .Format = pipeline.render_target_view_format,
        .ViewDimension = .TEXTURE2D,
        .Anonymous = .{ .Texture2D = .{ .MipSlice = 0, .PlaneSlice = 0 } },
    };
    self.device.CreateRenderTargetView(resource, &rtv_desc, self.render_targets.cpu());
    // Fresh contents are undefined, so the next frame has to cover every
    // pixel rather than just the dirty rows.
    self.grid_force_full = true;
}

const DrawInputs = struct {
    cell_count: u32,
    dirty_min_row: ?u32,
    dirty_max_row: ?u32,
    resizing: bool,
    inline_images_present: bool,
};

fn drawAndPresent(
    self: *D3d12Renderer,
    prepared: PreparedFrame,
    tabbar: types.TabBarDraw,
    remote_session: bool,
    in: DrawInputs,
) void {
    const surface = &self.surface.?;
    self.beginBatch();
    const list = self.command_list;

    // Descriptor growth retires the old heap, so it has to happen before any
    // pipeline state is set: it submits and reopens the command list.
    self.ensureDescriptorCapacity(self.countVisiblePlacements());

    // Uploads recorded during cell building must finish before the shader
    // reads them; these two transitions are what make that ordering explicit
    // rather than a driver's problem.
    self.cells.moveTo(list, win32.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);
    self.atlas.moveTo(list, win32.D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE);

    const full_redraw = self.grid_force_full or in.resizing or
        (in.inline_images_present and in.dirty_min_row != null);
    const do_draw = full_redraw or in.dirty_min_row != null;

    if (do_draw) {
        self.grid_target.moveTo(list, win32.D3D12_RESOURCE_STATE_RENDER_TARGET);
        const rtv = self.render_targets.cpu();
        list.OMSetRenderTargets(1, &rtv, win32.FALSE, null);

        var heaps = [_]?*win32.ID3D12DescriptorHeap{self.descriptors().heap};
        list.SetDescriptorHeaps(heaps.len, &heaps);
        list.SetGraphicsRootSignature(self.root_signature);
        var config = prepared.config;
        const config_bytes = std.mem.asBytes(&config);
        const config_res = self.reserve(config_bytes.len, upload.constant_buffer_alignment);
        @memcpy(config_res.bytes, config_bytes);
        list.SetGraphicsRootConstantBufferView(
            0,
            self.arena().buffer.?.GetGPUVirtualAddress() + config_res.offset,
        );
        list.SetGraphicsRootDescriptorTable(1, self.descriptors().gpu(0));
        list.SetPipelineState(self.pso_grid);
        list.IASetPrimitiveTopology(._PRIMITIVE_TOPOLOGY_TRIANGLESTRIP);

        // Viewport offsets the grid below the tab-bar band; the shader
        // subtracts the same offset when mapping pixels to cells.
        var viewport = [_]win32.D3D12_VIEWPORT{.{
            .TopLeftX = 0,
            .TopLeftY = @floatFromInt(prepared.tab_bar_h),
            .Width = @floatFromInt(prepared.client_w),
            .Height = @floatFromInt(prepared.term_pixel_h),
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        }};
        list.RSSetViewports(1, &viewport);

        var scissor = [_]win32.RECT{if (full_redraw) .{
            .left = 0,
            .top = 0,
            .right = @intCast(prepared.client_w),
            .bottom = @intCast(prepared.client_h),
        } else blk: {
            const last_row = prepared.term_shader_row -| 1;
            const lo = @min(in.dirty_min_row.?, last_row);
            const hi = @min(in.dirty_max_row.?, last_row);
            break :blk .{
                .left = 0,
                .top = @intCast(prepared.tab_bar_h + lo * prepared.cs.y),
                .right = @intCast(prepared.client_w),
                .bottom = @intCast(@min(
                    prepared.tab_bar_h + (hi + 1) * prepared.cs.y,
                    prepared.client_h,
                )),
            };
        }};
        list.RSSetScissorRects(1, &scissor);

        // No clear: the shader writes every pixel inside the scissor,
        // including blank cells' background, and outside it the texture still
        // holds last frame's correct pixels.
        list.DrawInstanced(4, 1, 0, 0);

        if (in.inline_images_present) self.drawInlineImages(prepared);
        self.grid_force_full = false;
    }

    const back_buffer = surface.getBuffer(win32.ID3D12Resource) orelse {
        // Submit what was recorded so the list does not carry into the next
        // frame, then stop: without a back buffer this backend cannot present
        // at all, and quietly dropping frames forever is precisely the
        // partially-capable state that must not be allowed to persist.
        self.submit();
        std.debug.panic(
            "renderer = d3d12: the swap chain yielded no back buffer; the backend can no " ++
                "longer meet its baseline and recovery is out of scope",
            .{},
        );
    };
    self.back_buffer.release();
    self.back_buffer = .{
        .resource = back_buffer,
        .state = win32.D3D12_RESOURCE_STATE_PRESENT,
    };

    self.grid_target.moveTo(list, win32.D3D12_RESOURCE_STATE_COPY_SOURCE);
    self.back_buffer.moveTo(list, win32.D3D12_RESOURCE_STATE_COPY_DEST);
    list.CopyResource(back_buffer, self.grid_target.resource.?);

    self.copyTabBarBand(prepared, tabbar);

    self.back_buffer.moveTo(list, win32.D3D12_RESOURCE_STATE_PRESENT);
    // Submit without waiting, and end the batch here: the next one takes the
    // other generation and passes the throttle decision on its way in, so the
    // CPU can build the next frame while the GPU is still reading this one.
    self.submit();
    self.batch_open = false;

    const sync_interval: u32 = if (self.common.remote_or_software_adapter or remote_session) 1 else 0;
    const hr = surface.swap_chain.IDXGISwapChain.Present(sync_interval, 0);
    if (hr == present.DXGI_STATUS_OCCLUDED) {
        self.occluded = true;
    } else if (hr < 0) {
        // Device removal and presentation failure are outside this slice's
        // recovery scope. Carrying on would leave a backend that was asked
        // for by name running in a state it cannot draw from, which is worse
        // than stopping: a comparison study would record its output as this
        // backend's real behaviour.
        std.debug.panic(
            "renderer = d3d12: Present failed (hresult=0x{x}); the backend can no longer " ++
                "meet its baseline and recovery is out of scope",
            .{@as(u32, @bitCast(hr))},
        );
    }
}

/// Placements that will actually be drawn this frame. Counted before any
/// staging so descriptor and upload capacity can both be sized exactly.
fn countVisiblePlacements(self: *D3d12Renderer) u32 {
    var n: u32 = 0;
    for (self.kitty_images.placements.items) |p| {
        if (p.z >= 0) n += 1;
    }
    return n;
}

/// Grow the descriptor heap so every placement can have its own table.
///
/// Sharing one table between placements is not an option — the GPU reads
/// descriptors when the work runs, so all of them would sample whichever
/// image was written last — and silently dropping placements past a fixed
/// limit would make real terminal content disappear.
fn ensureDescriptorCapacity(self: *D3d12Renderer, placements: u32) void {
    const wanted = 1 + placements;
    if (wanted <= self.descriptors().table_count) return;
    // Every generation's heap is replaced together so they stay
    // interchangeable, which the settle below also makes safe: no submitted
    // work can still be reading the heaps being released.
    self.settleBeforeRelease();
    for (&self.descriptor_heaps) |*d| {
        d.release();
        d.* = pipeline.Descriptors.init(self.device, wanted) catch |err| std.debug.panic(
            "renderer = d3d12: descriptor heap for {d} inline images unavailable ({s})",
            .{ placements, @errorName(err) },
        );
    }
    self.refreshSharedDescriptors();
}

/// (Re)write the descriptors every table shares, in every generation. Slot 3
/// is filled with a null view so the table is complete even when nothing is
/// bound there: D3D12 requires every descriptor a bound table covers to be
/// initialized, whether or not the shader ends up reading it.
///
/// This rewrites heaps other generations own, so it settles first: a heap that
/// submitted work may still be reading must not be written by the CPU. Every
/// caller reaches here because a shared resource was just replaced, which is
/// rare enough that the wait does not touch the sustained path.
fn refreshSharedDescriptors(self: *D3d12Renderer) void {
    self.settleBeforeRelease();
    const cell_view = win32.D3D12_SHADER_RESOURCE_VIEW_DESC{
        .Format = .UNKNOWN,
        .ViewDimension = .BUFFER,
        .Shader4ComponentMapping = win32.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
        .Anonymous = .{ .Buffer = .{
            .FirstElement = 0,
            .NumElements = @max(1, self.cells_count),
            .StructureByteStride = @sizeOf(shader.Cell),
            .Flags = .{},
        } },
    };
    const texture_view = win32.D3D12_SHADER_RESOURCE_VIEW_DESC{
        .Format = .B8G8R8A8_UNORM,
        .ViewDimension = .TEXTURE2D,
        .Shader4ComponentMapping = win32.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
        .Anonymous = .{ .Texture2D = .{
            .MostDetailedMip = 0,
            .MipLevels = 1,
            .PlaneSlice = 0,
            .ResourceMinLODClamp = 0,
        } },
    };
    const inline_view = win32.D3D12_SHADER_RESOURCE_VIEW_DESC{
        .Format = .R8G8B8A8_UNORM,
        .ViewDimension = .TEXTURE2D,
        .Shader4ComponentMapping = win32.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
        .Anonymous = .{ .Texture2D = .{
            .MostDetailedMip = 0,
            .MipLevels = 1,
            .PlaneSlice = 0,
            .ResourceMinLODClamp = 0,
        } },
    };
    for (self.descriptor_heaps) |heap| {
        var table: u32 = 0;
        while (table < heap.table_count) : (table += 1) {
            self.device.CreateShaderResourceView(self.cells.resource, &cell_view, heap.cpu(table, 0));
            self.device.CreateShaderResourceView(self.atlas.resource, &texture_view, heap.cpu(table, 1));
            self.device.CreateShaderResourceView(self.background_image.resource, &texture_view, heap.cpu(table, 2));
            self.device.CreateShaderResourceView(null, &inline_view, heap.cpu(table, 3));
        }
    }
}

/// Paint the tab bar into ordinary memory and stage it onto the back buffer.
///
/// The font service owns this drawing for both backends; only the destination
/// differs. The band texture persists across frames, so the D2D pass is skipped
/// whenever the content signature is unchanged.
fn copyTabBarBand(self: *D3d12Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw) void {
    if (prepared.tab_bar_h == 0) return;
    const band = self.font_service.cpuBand(prepared.client_w, prepared.tab_bar_h);
    const sig = tabbar_paint.signature(tabbar, self.cache_gen, prepared.cs.x, prepared.client_w, prepared.tab_bar_h);
    if (self.tabbar_sig_rt != band.render_target or self.tabbar_sig != sig) {
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
        self.tabbar_sig = sig;
        self.tabbar_sig_rt = band.render_target;
    }
    const pixels = band.readPixels();

    const copy_h = @min(prepared.tab_bar_h, prepared.client_h);
    const dst_pitch: u32 = @intCast(upload.alignUp(
        @as(u64, prepared.client_w) * 4,
        upload.texture_row_alignment,
    ));
    const res = self.reserve(@as(u64, dst_pitch) * copy_h, upload.texture_placement_alignment);
    const row_bytes: usize = @as(usize, prepared.client_w) * 4;
    var y: u32 = 0;
    while (y < copy_h) : (y += 1) {
        @memcpy(res.bytes[y * dst_pitch ..][0..row_bytes], pixels[y * band.stride() ..][0..row_bytes]);
    }

    const src_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = self.arena().buffer.?,
        .Type = .PLACED_FOOTPRINT,
        .Anonymous = .{ .PlacedFootprint = .{
            .Offset = res.offset,
            .Footprint = .{
                .Format = pipeline.render_target_format,
                .Width = prepared.client_w,
                .Height = copy_h,
                .Depth = 1,
                .RowPitch = dst_pitch,
            },
        } },
    };
    const dst_loc = win32.D3D12_TEXTURE_COPY_LOCATION{
        .pResource = self.back_buffer.resource.?,
        .Type = .SUBRESOURCE_INDEX,
        .Anonymous = .{ .SubresourceIndex = 0 },
    };
    self.command_list.CopyTextureRegion(&dst_loc, 0, 0, 0, &src_loc, null);
}

fn drawInlineImages(self: *D3d12Renderer, prepared: PreparedFrame) void {
    const list = self.command_list;
    list.SetPipelineState(self.pso_inline_image);

    var table: u32 = 1;
    for (self.kitty_images.placements.items) |p| {
        if (p.z < 0) continue;
        std.debug.assert(table < self.descriptors().table_count);
        const entry = self.kitty_images.images.get(.{
            .tab_id = self.kitty_images.last_tab_id,
            .image_id = p.image_id,
        }) orelse continue;

        const dest_x: i64 = @as(i64, p.x) * prepared.cs.x + p.cell_offset_x;
        const dest_y: i64 = @as(i64, p.y) * prepared.cs.y + p.cell_offset_y;
        const left = std.math.clamp(dest_x, 0, @as(i64, prepared.client_w));
        const top = std.math.clamp(dest_y, 0, @as(i64, prepared.term_pixel_h));
        const right = std.math.clamp(dest_x + @as(i64, p.width), 0, @as(i64, prepared.client_w));
        const bottom = std.math.clamp(dest_y + @as(i64, p.height), 0, @as(i64, prepared.term_pixel_h));
        if (right <= left or bottom <= top) continue;

        // Each placement gets its own descriptor table: the GPU reads
        // descriptors when the work runs, so rewriting one table between
        // draws would make every placement sample the last image.
        const view = win32.D3D12_SHADER_RESOURCE_VIEW_DESC{
            .Format = .R8G8B8A8_UNORM,
            .ViewDimension = .TEXTURE2D,
            .Shader4ComponentMapping = win32.D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING,
            .Anonymous = .{ .Texture2D = .{
                .MostDetailedMip = 0,
                .MipLevels = 1,
                .PlaneSlice = 0,
                .ResourceMinLODClamp = 0,
            } },
        };
        self.device.CreateShaderResourceView(
            entry.image.resource,
            &view,
            self.descriptors().cpu(table, 3),
        );

        var config: kitty_image_mod.ImageConfig = .{
            .dest = .{
                @floatFromInt(dest_x),
                @floatFromInt(dest_y),
                @floatFromInt(p.width),
                @floatFromInt(p.height),
            },
            .source = .{
                @floatFromInt(p.source_x),
                @floatFromInt(p.source_y),
                @floatFromInt(p.source_width),
                @floatFromInt(p.source_height),
            },
            .image_size = .{
                @floatFromInt(entry.width),
                @floatFromInt(entry.height),
            },
            .tab_bar_height = @floatFromInt(prepared.tab_bar_h),
        };
        const bytes = std.mem.asBytes(&config);
        const res = self.reserve(bytes.len, upload.constant_buffer_alignment);
        @memcpy(res.bytes, bytes);

        var scissor = [_]win32.RECT{.{
            .left = @intCast(left),
            .top = @intCast(@as(i64, prepared.tab_bar_h) + top),
            .right = @intCast(right),
            .bottom = @intCast(@as(i64, prepared.tab_bar_h) + bottom),
        }};
        list.RSSetScissorRects(1, &scissor);
        list.SetGraphicsRootConstantBufferView(
            0,
            self.arena().buffer.?.GetGPUVirtualAddress() + res.offset,
        );
        list.SetGraphicsRootDescriptorTable(1, self.descriptors().gpu(table));
        list.DrawInstanced(4, 1, 0, 0);
        table += 1;
    }
}

pub fn applyGlyphResult(self: *D3d12Renderer, result: *RasterResult) bool {
    return glyph_mod.applyRasterResult(self, result);
}

pub fn reloadBackgroundImage(
    self: *D3d12Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    bg_image.reload(self, gpa, cfg, hwnd);
}

pub fn applyDecodedBackgroundImage(self: *D3d12Renderer, result: *const BgImageDecoded) void {
    bg_image.applyDecoded(self, result);
}

pub fn releaseKittyImagesForTab(self: *D3d12Renderer, tab_id: types.TabId) void {
    // Each image settles as it is retired, so there is nothing to wait for
    // here when the tab owns none.
    self.kitty_images.releaseForTab(std.heap.page_allocator, tab_id);
}

test "each generation owns its own submission-scoped state" {
    // The full-idle wait this backend used to take every frame protected more
    // than staged bytes: a command allocator may only be reset once the GPU is
    // done with everything recorded from it. Sharing one allocator across
    // generations would silently bring that wait back — the picture would stay
    // correct and only the latency would regress — so the two counts have to
    // move together.
    // Shader-visible descriptors belong to the same class: the GPU reads them
    // when the work runs, so one heap rewritten every frame would be read by
    // the previous frame's work and sample the wrong texture.
    const allocators = @typeInfo(@FieldType(D3d12Renderer, "command_allocators")).array.len;
    const arenas = @typeInfo(@FieldType(D3d12Renderer, "arenas")).array.len;
    const heaps = @typeInfo(@FieldType(D3d12Renderer, "descriptor_heaps")).array.len;
    try std.testing.expectEqual(@as(usize, upload.Ring.generations), allocators);
    try std.testing.expectEqual(@as(usize, upload.Ring.generations), arenas);
    try std.testing.expectEqual(@as(usize, upload.Ring.generations), heaps);

    // Fewer than two leaves nothing for the CPU to record into while the GPU
    // reads the other, which is the same as having no pipelining at all.
    try std.testing.expect(upload.Ring.generations >= 2);
}

comptime {
    _ = cell_buffer;
    _ = tabbar_paint;
    _ = present;
}
