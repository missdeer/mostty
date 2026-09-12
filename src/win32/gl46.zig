//! OpenGL 4.6 renderer with an optional DirectComposition bridge.
//!
//! WGL remains the complete baseline and the font service hands pixels over
//! through CPU memory. WGL_NV_DX_interop2 adds composition presentation when
//! the current driver can establish the cross-API handoff.

const Gl46Renderer = @This();

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const Config = @import("../config.zig");
const FontService = @import("font_service.zig");
const GlyphIndexCache = @import("glyph_index_cache.zig");
const RendererCommon = @import("renderer_common.zig");
const shared = @import("shared.zig");
const types = @import("types.zig");

const bg_image = @import("d3d11/background_image.zig");
const cell_buffer = @import("d3d11/cell_buffer.zig");
const glyph_mod = @import("d3d11/glyph.zig");
const gpu = @import("d3d11/gpu.zig");
const grid = @import("d3d11/grid.zig");
const kitty_image_mod = @import("d3d11/kitty_images.zig");
const tabbar_paint = @import("d3d11/tabbar_paint.zig");
const shader_assets = @import("shader_assets.zig");
const gl = @import("gl46/loader.zig");
const interop = @import("gl46/interop.zig");

const CellXY = gpu.CellXY;
const shader = gpu.shader;
const log = std.log.scoped(.gl46);

pub const BgImageDecoded = bg_image.BgImageDecoded;
pub const RasterResult = FontService.RasterResult;
pub const scrollbarWidth = gpu.scrollbarWidth;
pub const glyph_handoff: shared.GlyphHandoff = .cpu_pixels;

const frame_count = 3;
const map_flags = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT;

pub const Presentation = enum {
    interop,
    pure_wgl,

    fn usesInterop(self: Presentation) bool {
        return self == .interop;
    }
};

const RenderPass = enum {
    grid,
    overlay,

    fn blendEnabled(self: RenderPass) bool {
        return self == .overlay;
    }

    fn begin(self: RenderPass) void {
        if (self.blendEnabled()) {
            gl.Enable(gl.BLEND);
        } else {
            gl.Disable(gl.BLEND);
        }
    }
};

pub const RuntimeFailure = struct {
    operation: []const u8,
    cause: anyerror,
};

pub const StartupError = error{
    GpuOverrideUnsupported,
    GetDcFailed,
    PixelFormatUnavailable,
    PixelFormatExtensionUnavailable,
    PixelFormatContractUnavailable,
    SetPixelFormatFailed,
    BootstrapWindowClassFailed,
    BootstrapWindowFailed,
    BootstrapContextFailed,
    BootstrapMakeCurrentFailed,
    CreateContextUnavailable,
    SwapControlUnavailable,
    CoreContextRejected,
    CoreMakeCurrentFailed,
    OpenGlModuleUnavailable,
    ProcedureTableIncomplete,
    VersionTooOld,
    SwapIntervalFailed,
    ShaderObjectFailed,
    SpirvSpecializationFailed,
    ProgramObjectFailed,
    ProgramLinkFailed,
};

pub fn startupErrorDescription(err: StartupError) []const u8 {
    return switch (err) {
        error.GpuOverrideUnsupported => "WGL cannot honor the configured GPU override",
        error.GetDcFailed => "the window device context is unavailable",
        error.PixelFormatUnavailable => "no composited RGBA pixel format is available",
        error.PixelFormatExtensionUnavailable => "WGL_ARB_pixel_format is unavailable",
        error.PixelFormatContractUnavailable => "no double-buffered alpha+sRGB composited pixel format is available",
        error.SetPixelFormatFailed => "the OpenGL pixel format was rejected",
        error.BootstrapWindowClassFailed => "the WGL bootstrap window class could not be registered",
        error.BootstrapWindowFailed => "the WGL bootstrap window could not be created",
        error.BootstrapContextFailed => "the legacy WGL bootstrap context could not be created",
        error.BootstrapMakeCurrentFailed => "the legacy WGL bootstrap context could not be activated",
        error.CreateContextUnavailable => "WGL_ARB_create_context is unavailable",
        error.SwapControlUnavailable => "WGL_EXT_swap_control is unavailable",
        error.CoreContextRejected => "the driver rejected an OpenGL 4.6 core context",
        error.CoreMakeCurrentFailed => "the OpenGL 4.6 core context could not be activated",
        error.OpenGlModuleUnavailable => "opengl32.dll is not loaded",
        error.ProcedureTableIncomplete => "the OpenGL 4.6 procedure table is incomplete",
        error.VersionTooOld => "the driver exposed an OpenGL version older than 4.6",
        error.SwapIntervalFailed => "the driver rejected swap interval 1",
        error.ShaderObjectFailed => "the driver could not create a shader object",
        error.SpirvSpecializationFailed => "the driver could not specialize the shared SPIR-V shader",
        error.ProgramObjectFailed => "the driver could not create a shader program",
        error.ProgramLinkFailed => "the driver could not link the shared SPIR-V program",
    };
}

const WglCreateContextAttribs = *const fn (
    win32.HDC,
    ?win32.HGLRC,
    [*:0]const i32,
) callconv(.winapi) ?win32.HGLRC;
const WglSwapInterval = *const fn (i32) callconv(.winapi) win32.BOOL;
const WglChoosePixelFormat = *const fn (
    win32.HDC,
    [*:0]const i32,
    ?[*]const f32,
    u32,
    [*]i32,
    *u32,
) callconv(.winapi) win32.BOOL;
const WglGetPixelFormatAttribiv = *const fn (
    win32.HDC,
    i32,
    i32,
    u32,
    [*]const i32,
    [*]i32,
) callconv(.winapi) win32.BOOL;

const ContextProcs = struct {
    create_context: WglCreateContextAttribs,
    swap_interval: WglSwapInterval,
};

const PureWglProcs = struct {
    context: ContextProcs,
    choose_pixel_format: WglChoosePixelFormat,
    get_pixel_format_attrib: WglGetPixelFormatAttribiv,
};

const WGL_CONTEXT_MAJOR_VERSION_ARB = 0x2091;
const WGL_CONTEXT_MINOR_VERSION_ARB = 0x2092;
const WGL_CONTEXT_FLAGS_ARB = 0x2094;
const WGL_CONTEXT_PROFILE_MASK_ARB = 0x9126;
const WGL_CONTEXT_CORE_PROFILE_BIT_ARB = 0x00000001;
const WGL_CONTEXT_DEBUG_BIT_ARB = 0x00000001;
const WGL_DRAW_TO_WINDOW_ARB = 0x2001;
const WGL_SUPPORT_OPENGL_ARB = 0x2010;
const WGL_DOUBLE_BUFFER_ARB = 0x2011;
const WGL_PIXEL_TYPE_ARB = 0x2013;
const WGL_COLOR_BITS_ARB = 0x2014;
const WGL_ALPHA_BITS_ARB = 0x201B;
const WGL_TYPE_RGBA_ARB = 0x202B;
const WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB = 0x20A9;

const GetPixelFormatRaw = @extern(*const fn (win32.HDC) callconv(.winapi) i32, .{ .name = "GetPixelFormat" });

const DescribePixelFormatRaw = @extern(
    *const fn (
        dc: win32.HDC,
        pixel_format: i32,
        bytes: u32,
        pfd: *win32.PIXELFORMATDESCRIPTOR,
    ) callconv(.winapi) i32,
    .{ .name = "DescribePixelFormat" },
);

const DebugStats = struct {
    rows_uploaded: u64 = 0,
    rows_skipped: u64 = 0,
};

pub const KittyImage = struct {
    texture: gl.uint,

    pub fn release(self: *KittyImage) void {
        gl.DeleteTextures(1, @ptrCast(&self.texture));
        self.* = undefined;
    }
};

pub const BackgroundImage = struct {
    texture: gl.uint = 0,
    src_w: u32 = 0,
    src_h: u32 = 0,

    pub fn loaded(self: BackgroundImage) bool {
        return self.texture != 0;
    }

    pub fn release(self: *BackgroundImage) void {
        if (self.texture != 0) gl.DeleteTextures(1, @ptrCast(&self.texture));
        self.* = .{};
    }
};

const PureWglSurface = struct {
    framebuffer: gl.uint = 0,
    renderbuffer: gl.uint = 0,
    width: u32 = 0,
    height: u32 = 0,

    fn begin(self: *PureWglSurface, width: u32, height: u32) void {
        if (self.framebuffer == 0) {
            gl.CreateFramebuffers(1, @ptrCast(&self.framebuffer));
            gl.CreateRenderbuffers(1, @ptrCast(&self.renderbuffer));
            if (self.framebuffer == 0 or self.renderbuffer == 0)
                fatal("pure WGL presentation surface creation failed");
        }
        if (self.width != width or self.height != height) {
            gl.NamedRenderbufferStorage(
                self.renderbuffer,
                gl.SRGB8_ALPHA8,
                @intCast(width),
                @intCast(height),
            );
            gl.NamedFramebufferRenderbuffer(
                self.framebuffer,
                gl.COLOR_ATTACHMENT0,
                gl.RENDERBUFFER,
                self.renderbuffer,
            );
            gl.NamedFramebufferDrawBuffer(self.framebuffer, gl.COLOR_ATTACHMENT0);
            gl.NamedFramebufferReadBuffer(self.framebuffer, gl.COLOR_ATTACHMENT0);
            if (gl.CheckNamedFramebufferStatus(self.framebuffer, gl.FRAMEBUFFER) != gl.FRAMEBUFFER_COMPLETE)
                fatal("pure WGL presentation framebuffer is incomplete");
            self.width = width;
            self.height = height;
        }
        gl.BindFramebuffer(gl.FRAMEBUFFER, self.framebuffer);
    }

    fn blitToWindow(self: PureWglSurface) void {
        gl.BindFramebuffer(gl.FRAMEBUFFER, 0);
        gl.BlitNamedFramebuffer(
            self.framebuffer,
            0,
            0,
            0,
            @intCast(self.width),
            @intCast(self.height),
            0,
            @intCast(self.height),
            @intCast(self.width),
            0,
            gl.COLOR_BUFFER_BIT,
            gl.NEAREST,
        );
    }

    fn release(self: *PureWglSurface) void {
        if (self.renderbuffer != 0) gl.DeleteRenderbuffers(1, @ptrCast(&self.renderbuffer));
        if (self.framebuffer != 0) gl.DeleteFramebuffers(1, @ptrCast(&self.framebuffer));
        self.* = .{};
    }
};

const MappedBuffer = struct {
    name: gl.uint = 0,
    bytes: ?[*]u8 = null,
    size: usize = 0,

    fn create(size: usize) MappedBuffer {
        var name: gl.uint = 0;
        gl.CreateBuffers(1, @ptrCast(&name));
        if (name == 0) fatal("glCreateBuffers returned zero");
        gl.NamedBufferStorage(name, @intCast(size), null, map_flags);
        const mapped = gl.MapNamedBufferRange(name, 0, @intCast(size), map_flags) orelse
            fatal("persistent buffer mapping failed");
        return .{ .name = name, .bytes = @ptrCast(mapped), .size = size };
    }

    fn release(self: *MappedBuffer) void {
        if (self.name != 0) {
            _ = gl.UnmapNamedBuffer(self.name);
            gl.DeleteBuffers(1, @ptrCast(&self.name));
        }
        self.* = .{};
    }
};

// Shared-layer state.
common: *RendererCommon,
parent: ?*Gl46Renderer = null,
failure: ?RuntimeFailure = null,
frame_pending: bool = false,
test_fail_present: bool = false,
swap_interval: ?WglSwapInterval = null,
font_service: *FontService,
shadow_cells: []shader.Cell = &.{},
glyph_cache_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator),
glyph_cache: ?GlyphIndexCache = null,
glyph_cache_cell_size: ?CellXY = null,
cache_gen: u32 = 0,
grid_force_full: bool = true,
last_const_snapshot: grid.ConfigSnapshot = .{},
// Signature of the content last painted into the tab-bar texture, plus the
// D2D target it came from. Both the CPU band and the GL texture survive across
// frames, so a matching signature skips the D2D pass and the texture upload.
tabbar_sig: u64 = 0,
tabbar_sig_rt: ?*win32.ID2D1RenderTarget = null,
stats: DebugStats = .{},
diag_rows_uploaded: u64 = 0,
diag_rows_skipped: u64 = 0,

background_image: BackgroundImage = .{},
bg_image_path: []const u8 = &.{},
bg_image_allocator: ?std.mem.Allocator = null,
bg_image_generation: u32 = 0,
bg_image_opacity: f32 = 1.0,
bg_image_position: Config.BackgroundImagePosition = .center,
bg_image_fit: Config.BackgroundImageFit = .contain,
bg_image_repeat: bool = false,
bg_image_req_id: u32 = 0,
kitty_images: kitty_image_mod.Cache(KittyImage) = .{},

// WGL/OpenGL state is created lazily once the HWND exists.
initialized: bool = false,
hwnd: ?win32.HWND = null,
dc: ?win32.HDC = null,
context: ?win32.HGLRC = null,
procs: gl.ProcTable = undefined,
interop_state: interop.State = .untried,
interop_bridge: ?interop.Bridge = null,
pure_wgl_surface: PureWglSurface = .{},
gpu_override_configured: bool = false,
presentation: Presentation,

grid_program: gl.uint = 0,
image_program: gl.uint = 0,
vao: gl.uint = 0,
sampler: gl.uint = 0,

grid_ubo: MappedBuffer = .{},
grid_ubo_stride: usize = 0,
image_ubo: MappedBuffer = .{},
image_ubo_stride: usize = 0,
image_ubo_capacity: usize = 0,

cells: MappedBuffer = .{},
cells_count: u32 = 0,
cells_stride: usize = 0,
storage_alignment: usize = 1,

atlas: gl.uint = 0,
atlas_size: ?CellXY = null,
tabbar_texture: gl.uint = 0,
tabbar_size: win32.SIZE = .{ .cx = 0, .cy = 0 },

fences: [frame_count]?*gl.sync = @splat(null),
frame_slot: usize = frame_count - 1,
last_frame_slot: ?usize = null,

pub fn init(
    common: *RendererCommon,
    font_service: *FontService,
    configured_gpu: ?[]const u8,
    presentation: Presentation,
) Gl46Renderer {
    return .{
        .common = common,
        .font_service = font_service,
        .gpu_override_configured = configured_gpu != null,
        .presentation = presentation,
    };
}

pub fn initSurface(parent: *Gl46Renderer, common: *RendererCommon) Gl46Renderer {
    var surface = init(common, parent.font_service, null, parent.presentation);
    surface.parent = parent;
    surface.cache_gen = parent.cache_gen;
    return surface;
}

pub fn deinit(self: *Gl46Renderer) void {
    if (self.initialized) {
        if (win32.wglMakeCurrent(self.dc.?, self.context.?) == 0) {
            fatal("wglMakeCurrent during teardown failed");
        }
        gl.makeProcTableCurrent(&self.procs);
        gl.Finish();
        if (self.interop_bridge) |*bridge| bridge.deinit();
        self.pure_wgl_surface.release();
        self.kitty_images.deinit(std.heap.page_allocator);
        if (self.parent == null) self.background_image.release();
        self.releaseGlyphState();

        if (self.tabbar_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.tabbar_texture));
        if (self.atlas != 0) gl.DeleteTextures(1, @ptrCast(&self.atlas));
        self.cells.release();
        self.image_ubo.release();
        self.grid_ubo.release();
        if (self.parent == null and self.sampler != 0) gl.DeleteSamplers(1, @ptrCast(&self.sampler));
        if (self.vao != 0) gl.DeleteVertexArrays(1, @ptrCast(&self.vao));
        if (self.parent == null and self.image_program != 0) gl.DeleteProgram(self.image_program);
        if (self.parent == null and self.grid_program != 0) gl.DeleteProgram(self.grid_program);
        for (&self.fences) |*fence| {
            if (fence.*) |f| gl.DeleteSync(f);
            fence.* = null;
        }

        gl.makeProcTableCurrent(null);
        _ = win32.wglMakeCurrent(null, null);
        if (self.parent == null) {
            if (self.context) |context| _ = win32.wglDeleteContext(context);
        }
        if (self.dc) |dc| {
            if (self.hwnd) |hwnd| _ = win32.ReleaseDC(hwnd, dc);
        }
    } else {
        self.kitty_images.deinit(std.heap.page_allocator);
        self.releaseGlyphState();
    }
    if (self.bg_image_allocator) |allocator| allocator.free(self.bg_image_path);
    self.* = undefined;
}

fn releaseGlyphState(self: *Gl46Renderer) void {
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    std.heap.page_allocator.free(self.shadow_cells);
    self.shadow_cells = &.{};
}

pub fn onFontStateChanged(self: *Gl46Renderer) void {
    self.cache_gen +%= 1;
    if (self.glyph_cache) |*cache| {
        cache.deinit(self.glyph_cache_arena.allocator());
        self.glyph_cache = null;
    }
    _ = self.glyph_cache_arena.reset(.free_all);
    self.glyph_cache_cell_size = null;
    self.grid_force_full = true;
}

pub fn initializeWindow(self: *Gl46Renderer, hwnd: win32.HWND) StartupError!void {
    return self.ensureInitialized(hwnd);
}

fn pixelFormatDescriptor() win32.PIXELFORMATDESCRIPTOR {
    var pfd = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
    pfd.nSize = @sizeOf(win32.PIXELFORMATDESCRIPTOR);
    pfd.nVersion = 1;
    pfd.dwFlags = .{
        .DRAW_TO_WINDOW = 1,
        .SUPPORT_OPENGL = 1,
        .DOUBLEBUFFER = 1,
        .SUPPORT_COMPOSITION = 1,
    };
    pfd.iPixelType = .RGBA;
    pfd.cColorBits = 32;
    pfd.cAlphaBits = 8;
    pfd.iLayerType = .MAIN_PLANE;
    return pfd;
}

fn setLegacyPixelFormat(dc: win32.HDC) StartupError!void {
    const pfd = pixelFormatDescriptor();
    const pixel_format = win32.ChoosePixelFormat(dc, &pfd);
    if (pixel_format == 0) return error.PixelFormatUnavailable;
    if (win32.SetPixelFormat(dc, pixel_format, &pfd) == 0) return error.SetPixelFormatFailed;
}

fn loadContextProcs() StartupError!ContextProcs {
    return .{
        .create_context = procAddress(
            WglCreateContextAttribs,
            "wglCreateContextAttribsARB",
        ) orelse return error.CreateContextUnavailable,
        .swap_interval = procAddress(
            WglSwapInterval,
            "wglSwapIntervalEXT",
        ) orelse return error.SwapControlUnavailable,
    };
}

fn loadContextProcsFromTarget(dc: win32.HDC) StartupError!ContextProcs {
    const bootstrap = win32.wglCreateContext(dc) orelse return error.BootstrapContextFailed;
    defer {
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(bootstrap);
    }
    if (win32.wglMakeCurrent(dc, bootstrap) == 0) return error.BootstrapMakeCurrentFailed;
    return loadContextProcs();
}

fn bootstrapWndProc(
    hwnd: win32.HWND,
    message: u32,
    wparam: win32.WPARAM,
    lparam: win32.LPARAM,
) callconv(.winapi) win32.LRESULT {
    return win32.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn loadPureWglProcs() StartupError!PureWglProcs {
    const class_name = win32.L("MosttyWglBootstrap");
    const instance = win32.GetModuleHandleW(null);
    const wc = win32.WNDCLASSEXW{
        .cbSize = @sizeOf(win32.WNDCLASSEXW),
        .style = .{ .OWNDC = 1 },
        .lpfnWndProc = bootstrapWndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = null,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (win32.RegisterClassExW(&wc) == 0 and
        win32.GetLastError() != .ERROR_CLASS_ALREADY_EXISTS)
    {
        return error.BootstrapWindowClassFailed;
    }

    const hwnd = win32.CreateWindowExW(
        .{},
        class_name,
        win32.L(""),
        win32.WS_OVERLAPPED,
        0,
        0,
        1,
        1,
        null,
        null,
        instance,
        null,
    ) orelse return error.BootstrapWindowFailed;
    defer _ = win32.DestroyWindow(hwnd);

    const dc = win32.GetDC(hwnd) orelse return error.GetDcFailed;
    defer _ = win32.ReleaseDC(hwnd, dc);
    try setLegacyPixelFormat(dc);

    const bootstrap = win32.wglCreateContext(dc) orelse return error.BootstrapContextFailed;
    defer {
        _ = win32.wglMakeCurrent(null, null);
        _ = win32.wglDeleteContext(bootstrap);
    }
    if (win32.wglMakeCurrent(dc, bootstrap) == 0) return error.BootstrapMakeCurrentFailed;

    return .{
        .context = try loadContextProcs(),
        .choose_pixel_format = procAddress(
            WglChoosePixelFormat,
            "wglChoosePixelFormatARB",
        ) orelse return error.PixelFormatExtensionUnavailable,
        .get_pixel_format_attrib = procAddress(
            WglGetPixelFormatAttribiv,
            "wglGetPixelFormatAttribivARB",
        ) orelse return error.PixelFormatExtensionUnavailable,
    };
}

const pure_pixel_format_query = [_]i32{
    WGL_DRAW_TO_WINDOW_ARB,
    WGL_SUPPORT_OPENGL_ARB,
    WGL_DOUBLE_BUFFER_ARB,
    WGL_PIXEL_TYPE_ARB,
    WGL_COLOR_BITS_ARB,
    WGL_ALPHA_BITS_ARB,
    WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB,
};

fn purePixelFormatMeetsContract(
    attributes: [pure_pixel_format_query.len]i32,
    pfd: win32.PIXELFORMATDESCRIPTOR,
) bool {
    return attributes[0] != 0 and
        attributes[1] != 0 and
        attributes[2] != 0 and
        attributes[3] == WGL_TYPE_RGBA_ARB and
        attributes[4] >= 24 and
        attributes[5] >= 8 and
        attributes[6] != 0 and
        pfd.dwFlags.SUPPORT_COMPOSITION != 0;
}

fn setPurePixelFormat(dc: win32.HDC, procs: PureWglProcs) StartupError!void {
    const desired = [_:0]i32{
        WGL_DRAW_TO_WINDOW_ARB,
        1,
        WGL_SUPPORT_OPENGL_ARB,
        1,
        WGL_DOUBLE_BUFFER_ARB,
        1,
        WGL_PIXEL_TYPE_ARB,
        WGL_TYPE_RGBA_ARB,
        WGL_COLOR_BITS_ARB,
        24,
        WGL_ALPHA_BITS_ARB,
        8,
        WGL_FRAMEBUFFER_SRGB_CAPABLE_ARB,
        1,
        0,
    };
    var formats: [64]i32 = @splat(0);
    var format_count: u32 = 0;
    if (procs.choose_pixel_format(
        dc,
        &desired,
        null,
        formats.len,
        &formats,
        &format_count,
    ) == 0) return error.PixelFormatContractUnavailable;

    for (formats[0..@min(format_count, formats.len)]) |pixel_format| {
        var attributes: [pure_pixel_format_query.len]i32 = @splat(0);
        if (procs.get_pixel_format_attrib(
            dc,
            pixel_format,
            0,
            pure_pixel_format_query.len,
            &pure_pixel_format_query,
            &attributes,
        ) == 0) continue;

        var pfd = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
        if (DescribePixelFormatRaw(
            dc,
            pixel_format,
            @sizeOf(win32.PIXELFORMATDESCRIPTOR),
            &pfd,
        ) == 0) continue;
        if (!purePixelFormatMeetsContract(attributes, pfd)) continue;
        if (win32.SetPixelFormat(dc, pixel_format, &pfd) == 0)
            return error.SetPixelFormatFailed;
        log.info(
            "pure WGL pixel format {d}: color_bits={d}, alpha_bits={d}, sRGB={d}, composition={d}",
            .{ pixel_format, attributes[4], attributes[5], attributes[6], pfd.dwFlags.SUPPORT_COMPOSITION },
        );
        return;
    }
    return error.PixelFormatContractUnavailable;
}

fn ensureInitialized(self: *Gl46Renderer, hwnd: win32.HWND) StartupError!void {
    if (self.initialized) {
        if (self.hwnd != hwnd) fatal("the WGL context was asked to move to another window");
        if (!self.activate()) return error.CoreMakeCurrentFailed;
        return;
    }
    if (self.gpu_override_configured) return error.GpuOverrideUnsupported;

    const dc = win32.GetDC(hwnd) orelse return error.GetDcFailed;
    errdefer _ = win32.ReleaseDC(hwnd, dc);

    if (self.parent) |parent| {
        if (!parent.initialized) return error.CoreContextRejected;
        const format = GetPixelFormatRaw(parent.dc.?);
        var pfd = std.mem.zeroes(win32.PIXELFORMATDESCRIPTOR);
        if (format == 0 or DescribePixelFormatRaw(dc, format, @sizeOf(win32.PIXELFORMATDESCRIPTOR), &pfd) == 0) return error.PixelFormatUnavailable;
        if (GetPixelFormatRaw(dc) == 0 and win32.SetPixelFormat(dc, format, &pfd) == 0) return error.SetPixelFormatFailed;
        if (GetPixelFormatRaw(dc) != format) return error.PixelFormatContractUnavailable;
        self.hwnd = hwnd;
        self.dc = dc;
        self.context = parent.context;
        self.procs = parent.procs;
        self.swap_interval = parent.swap_interval;
        self.grid_program = parent.grid_program;
        self.image_program = parent.image_program;
        self.sampler = parent.sampler;
        self.initialized = true;
        if (!self.activate()) {
            self.initialized = false;
            return error.CoreMakeCurrentFailed;
        }
        self.initBuffers();
        log.info("pane created: id={} context=0x{x} dc=0x{x} mode={s}", .{ self.common.surface_id, @intFromPtr(self.context.?), @intFromPtr(dc), @tagName(self.presentation) });
        return;
    }

    const context_procs = switch (self.presentation) {
        .interop => blk: {
            if (GetPixelFormatRaw(dc) == 0) try setLegacyPixelFormat(dc);
            break :blk try loadContextProcsFromTarget(dc);
        },
        .pure_wgl => blk: {
            const procs = try loadPureWglProcs();
            if (GetPixelFormatRaw(dc) == 0) try setPurePixelFormat(dc, procs);
            break :blk procs.context;
        },
    };

    const context_flags: i32 = if (@import("builtin").mode == .Debug)
        WGL_CONTEXT_DEBUG_BIT_ARB
    else
        0;
    const attribs = [_:0]i32{
        WGL_CONTEXT_MAJOR_VERSION_ARB,
        4,
        WGL_CONTEXT_MINOR_VERSION_ARB,
        6,
        WGL_CONTEXT_FLAGS_ARB,
        context_flags,
        WGL_CONTEXT_PROFILE_MASK_ARB,
        WGL_CONTEXT_CORE_PROFILE_BIT_ARB,
        0,
    };
    const context = context_procs.create_context(dc, null, &attribs) orelse return error.CoreContextRejected;
    errdefer _ = win32.wglDeleteContext(context);
    if (win32.wglMakeCurrent(dc, context) == 0) return error.CoreMakeCurrentFailed;
    errdefer {
        gl.makeProcTableCurrent(null);
        _ = win32.wglMakeCurrent(null, null);
    }

    const opengl_module = win32.GetModuleHandleW(win32.L("opengl32.dll")) orelse
        return error.OpenGlModuleUnavailable;
    if (!self.procs.init(ProcLoader{ .module = opengl_module }))
        return error.ProcedureTableIncomplete;
    gl.makeProcTableCurrent(&self.procs);

    var major: gl.int = 0;
    var minor: gl.int = 0;
    gl.GetIntegerv(gl.MAJOR_VERSION, @ptrCast(&major));
    gl.GetIntegerv(gl.MINOR_VERSION, @ptrCast(&minor));
    if (major < 4 or (major == 4 and minor < 6)) {
        log.warn("driver exposed OpenGL {d}.{d}, but 4.6 is required", .{ major, minor });
        return error.VersionTooOld;
    }
    gl.Enable(gl.DEBUG_OUTPUT);
    gl.Enable(gl.DEBUG_OUTPUT_SYNCHRONOUS);
    gl.DebugMessageCallback(debugMessage, null);
    if (context_procs.swap_interval(1) == 0) return error.SwapIntervalFailed;
    gl.ClipControl(gl.UPPER_LEFT, gl.ZERO_TO_ONE);
    gl.Enable(gl.FRAMEBUFFER_SRGB);
    gl.BlendFuncSeparate(gl.ONE, gl.ONE_MINUS_SRC_ALPHA, gl.ONE, gl.ONE_MINUS_SRC_ALPHA);
    gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1);

    const grid_program = try createProgram(shader_assets.vertex.spirv, "VertexMain", shader_assets.pixel.spirv, "PixelMain");
    errdefer gl.DeleteProgram(grid_program);
    const image_program = try createProgram(shader_assets.vertex.spirv, "VertexMain", shader_assets.image_pixel.spirv, "ImagePixelMain");
    errdefer gl.DeleteProgram(image_program);

    self.grid_program = grid_program;
    self.image_program = image_program;
    self.initBuffers();
    self.hwnd = hwnd;
    self.dc = dc;
    self.context = context;
    self.swap_interval = context_procs.swap_interval;
    self.initialized = true;
    if (self.presentation.usesInterop()) {
        log.info(
            "OpenGL {d}.{d} baseline active: shared SPIR-V, swap interval 1, {d} completion slots; composition bridge {s}",
            .{ major, minor, frame_count, if (self.interop_state == .unavailable) "unavailable" else "pending" },
        );
    } else {
        log.info(
            "OpenGL {d}.{d} pure WGL presentation active: alpha+sRGB composited framebuffer, swap interval 1, {d} completion slots",
            .{ major, minor, frame_count },
        );
    }
}

fn initBuffers(self: *Gl46Renderer) void {
    var storage_alignment: gl.int = 1;
    var uniform_alignment: gl.int = 1;
    gl.GetIntegerv(gl.SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT, @ptrCast(&storage_alignment));
    gl.GetIntegerv(gl.UNIFORM_BUFFER_OFFSET_ALIGNMENT, @ptrCast(&uniform_alignment));
    self.storage_alignment = @intCast(@max(1, storage_alignment));
    self.grid_ubo_stride = alignForward(@sizeOf(shader.GridConfig), @intCast(@max(1, uniform_alignment)));
    self.image_ubo_stride = alignForward(@sizeOf(kitty_image_mod.ImageConfig), @intCast(@max(1, uniform_alignment)));
    self.grid_ubo = MappedBuffer.create(self.grid_ubo_stride * frame_count);
    self.ensureImageUboCapacity(1);

    gl.CreateVertexArrays(1, @ptrCast(&self.vao));
    gl.BindVertexArray(self.vao);
    if (self.parent == null) {
        gl.CreateSamplers(1, @ptrCast(&self.sampler));
        gl.SamplerParameteri(self.sampler, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
        gl.SamplerParameteri(self.sampler, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
        gl.SamplerParameteri(self.sampler, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.SamplerParameteri(self.sampler, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    }
    inline for (.{ 2, 3, 5 }) |unit| gl.BindSampler(unit, self.sampler);
}

fn activate(self: *Gl46Renderer) bool {
    if (!self.initialized or self.failure != null) return false;
    if (win32.wglMakeCurrent(self.dc.?, self.context.?) == 0) {
        self.recordFailure("activate pane DC", error.CoreMakeCurrentFailed);
        return false;
    }
    gl.makeProcTableCurrent(&self.procs);
    if (self.swap_interval.?(if (self.common.surface_id == 0) 1 else 0) == 0) {
        self.recordFailure("set swap interval", error.SwapIntervalFailed);
        return false;
    }
    if (gl.GetGraphicsResetStatus() != gl.NO_ERROR) {
        self.recordFailure("context reset", error.ContextLost);
        return false;
    }
    return true;
}

fn recordFailure(self: *Gl46Renderer, operation: []const u8, cause: anyerror) void {
    if (self.failure == null) self.failure = .{ .operation = operation, .cause = cause };
}

fn debugMessage(
    source: gl.@"enum",
    message_type: gl.@"enum",
    id: gl.uint,
    severity: gl.@"enum",
    length: gl.sizei,
    message: [*:0]const gl.char,
    user_param: ?*const anyopaque,
) callconv(gl.APIENTRY) void {
    _ = source;
    _ = message_type;
    _ = id;
    _ = severity;
    _ = length;
    _ = user_param;
    win32.OutputDebugStringA(message);
}

const ProcLoader = struct {
    module: win32.HINSTANCE,

    pub fn getProcAddress(self: ProcLoader, name: [*:0]const u8) ?gl.PROC {
        if (win32.wglGetProcAddress(name)) |candidate| {
            const raw = @intFromPtr(candidate);
            if (raw > 3 and raw != std.math.maxInt(usize)) return @ptrCast(candidate);
        }
        const candidate = win32.GetProcAddress(self.module, name) orelse return null;
        return @ptrCast(candidate);
    }
};

fn procAddress(comptime T: type, name: [*:0]const u8) ?T {
    const candidate = win32.wglGetProcAddress(name) orelse return null;
    const raw = @intFromPtr(candidate);
    if (raw <= 3 or raw == std.math.maxInt(usize)) return null;
    return @ptrCast(candidate);
}

fn createProgram(
    vertex_spirv: []const u8,
    vertex_entry: [*:0]const u8,
    pixel_spirv: []const u8,
    pixel_entry: [*:0]const u8,
) StartupError!gl.uint {
    const vertex = try createShader(gl.VERTEX_SHADER, vertex_spirv, vertex_entry);
    defer gl.DeleteShader(vertex);
    const pixel = try createShader(gl.FRAGMENT_SHADER, pixel_spirv, pixel_entry);
    defer gl.DeleteShader(pixel);

    const program = gl.CreateProgram();
    if (program == 0) return error.ProgramObjectFailed;
    errdefer gl.DeleteProgram(program);
    gl.AttachShader(program, vertex);
    gl.AttachShader(program, pixel);
    gl.LinkProgram(program);
    var linked: gl.int = 0;
    gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&linked));
    if (linked == 0) {
        var log_buf: [2048]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetProgramInfoLog(program, @intCast(log_buf.len), @ptrCast(&len), @ptrCast(&log_buf));
        log.err("SPIR-V program link failed: {s}", .{log_buf[0..@intCast(@max(0, len))]});
        return error.ProgramLinkFailed;
    }
    return program;
}

fn createShader(kind: gl.@"enum", spirv: []const u8, entry: [*:0]const u8) StartupError!gl.uint {
    const object = gl.CreateShader(kind);
    if (object == 0) return error.ShaderObjectFailed;
    errdefer gl.DeleteShader(object);
    var shader_name = object;
    gl.ShaderBinary(1, @ptrCast(&shader_name), gl.SHADER_BINARY_FORMAT_SPIR_V, spirv.ptr, @intCast(spirv.len));
    var unused = [_]gl.uint{0};
    gl.SpecializeShader(object, entry, 0, &unused, &unused);
    var compiled: gl.int = 0;
    gl.GetShaderiv(object, gl.COMPILE_STATUS, @ptrCast(&compiled));
    if (compiled == 0) {
        var log_buf: [2048]u8 = undefined;
        var len: gl.sizei = 0;
        gl.GetShaderInfoLog(object, @intCast(log_buf.len), @ptrCast(&len), @ptrCast(&log_buf));
        log.err("SPIR-V specialization failed: {s}", .{log_buf[0..@intCast(@max(0, len))]});
        return error.SpirvSpecializationFailed;
    }
    return object;
}

fn alignForward(value: usize, alignment: usize) usize {
    return std.mem.alignForward(usize, value, std.math.ceilPowerOfTwoAssert(usize, alignment));
}

fn fatal(message: []const u8) noreturn {
    std.debug.panic("renderer = opengl: {s}", .{message});
}

fn beginFrame(self: *Gl46Renderer) bool {
    self.frame_pending = false;
    const next = (self.frame_slot + 1) % frame_count;
    if (!self.waitForSlot(next)) return false;
    if (self.cells.bytes) |mapped| if (self.last_frame_slot) |previous| {
        const used = @as(usize, self.cells_count) * @sizeOf(shader.Cell);
        if (used != 0) {
            const src = mapped[previous * self.cells_stride ..][0..used];
            const dst = mapped[next * self.cells_stride ..][0..used];
            @memcpy(dst, src);
        }
    };
    self.frame_slot = next;
    self.last_frame_slot = next;
    return true;
}

fn waitForSlot(self: *Gl46Renderer, slot: usize) bool {
    const fence = self.fences[slot] orelse return true;
    var attempts: u32 = 0;
    while (true) : (attempts += 1) {
        const result = gl.ClientWaitSync(fence, gl.SYNC_FLUSH_COMMANDS_BIT, if (self.parent != null) 0 else 100_000_000);
        if (result == gl.ALREADY_SIGNALED or result == gl.CONDITION_SATISFIED) break;
        if (result == gl.WAIT_FAILED or attempts >= 99) {
            self.recordFailure("wait for frame completion", error.CompletionFailed);
            return false;
        }
        if (self.parent != null) {
            self.frame_pending = true;
            return false;
        }
    }
    gl.DeleteSync(fence);
    self.fences[slot] = null;
    return true;
}

fn finishFrame(self: *Gl46Renderer, path: interop.Path) void {
    if (path == .baseline)
        self.pure_wgl_surface.blitToWindow();
    self.fences[self.frame_slot] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0) orelse {
        self.recordFailure("create completion fence", error.CompletionFailed);
        return;
    };
    gl.Flush();
    if (self.test_fail_present) {
        self.test_fail_present = false;
        const rejected = switch (path) {
            .baseline => win32.SwapBuffers(@ptrFromInt(1)) == 0,
            .direct_composition => self.interop_bridge.?.presenter.surface.swap_chain.IDXGISwapChain.Present(5, 0) < 0,
        };
        self.recordFailure("diagnostic presentation", if (rejected) error.PresentFailed else error.DiagnosticNotRejected);
        return;
    }
    switch (path) {
        .baseline => if (win32.SwapBuffers(self.dc.?) == 0) {
            self.recordFailure("SwapBuffers", error.PresentFailed);
        },
        .direct_composition => self.interop_bridge.?.present() catch |err| {
            self.failInterop(err);
        },
    }
    if (gl.GetError() != gl.NO_ERROR) self.recordFailure("OpenGL frame", error.DrawFailed);
}

pub fn cellsResize(self: *Gl46Renderer, count: u32) bool {
    if (count == self.cells_count and self.cells.name != 0) return false;
    self.cells.release();
    self.cells_count = count;
    const used = @max(@sizeOf(shader.Cell), @as(usize, count) * @sizeOf(shader.Cell));
    self.cells_stride = alignForward(used, self.storage_alignment);
    self.cells = MappedBuffer.create(self.cells_stride * frame_count);
    @memset(self.cells.bytes.?[0 .. self.cells_stride * frame_count], 0);
    // buildAndUpload performs a mandatory full upload after recreation. The
    // current slice is therefore the authoritative source copied into the
    // next slot; clearing this would make unchanged rows zero on frame two.
    self.last_frame_slot = self.frame_slot;
    return true;
}

pub fn cellsUpload(self: *Gl46Renderer, first_cell: u32, cells: []const shader.Cell) void {
    const bytes = std.mem.sliceAsBytes(cells);
    const offset = self.frame_slot * self.cells_stride + @as(usize, first_cell) * @sizeOf(shader.Cell);
    @memcpy(self.cells.bytes.?[offset..][0..bytes.len], bytes);
}

pub fn atlasEnsure(self: *Gl46Renderer, tex_pixel: CellXY) bool {
    if (self.atlas_size) |size| if (size.eql(tex_pixel)) return true;
    if (self.atlas != 0) gl.DeleteTextures(1, @ptrCast(&self.atlas));
    self.atlas = createTexture(tex_pixel.x, tex_pixel.y, gl.RGBA8);
    self.atlas_size = tex_pixel;
    return false;
}

pub fn atlasWriteCpu(
    self: *Gl46Renderer,
    dst_coord: CellXY,
    region: CellXY,
    src_ptr: [*]const u8,
    src_row_pitch: u32,
) void {
    if (self.atlas == 0) return;
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, @intCast(src_row_pitch / 4));
    gl.TextureSubImage2D(
        self.atlas,
        0,
        @intCast(dst_coord.x),
        @intCast(dst_coord.y),
        @intCast(region.x),
        @intCast(region.y),
        gl.BGRA,
        gl.UNSIGNED_BYTE,
        src_ptr,
    );
    gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0);
}

pub fn atlasClear(self: *Gl46Renderer, dst_coord: CellXY) void {
    const cs = self.font_service.cell_size_xy;
    const row_bytes: usize = @as(usize, cs.x) * 4;
    const zeros = std.heap.page_allocator.alloc(u8, row_bytes * cs.y) catch return;
    defer std.heap.page_allocator.free(zeros);
    @memset(zeros, 0);
    self.atlasWriteCpu(dst_coord, cs, zeros.ptr, @intCast(row_bytes));
}

pub fn atlasCopyStaging(
    self: *Gl46Renderer,
    staging: *gpu.StagingTexture.Cached,
    first: ?gpu.AtlasCopy,
    second: ?gpu.AtlasCopy,
) void {
    _ = .{ self, staging, first, second };
    unreachable;
}

pub fn backgroundImageRelease(self: *Gl46Renderer) void {
    self.bg_image_generation +%= 1;
    if (self.parent == null) self.background_image.release();
}

pub fn backgroundImageUpload(self: *Gl46Renderer, decoded: gpu.DecodedBackground) void {
    self.backgroundImageRelease();
    const texture = createTexture(decoded.w, decoded.h, gl.RGBA8);
    gl.TextureSubImage2D(
        texture,
        0,
        0,
        0,
        @intCast(decoded.w),
        @intCast(decoded.h),
        gl.BGRA,
        gl.UNSIGNED_BYTE,
        decoded.pixels.ptr,
    );
    self.background_image = .{ .texture = texture, .src_w = decoded.w, .src_h = decoded.h };
}

pub fn kittyImageUpload(
    self: *Gl46Renderer,
    width: u32,
    height: u32,
    rgba: []const u8,
) ?KittyImage {
    _ = self;
    const texture = createTexture(width, height, gl.RGBA8);
    gl.TextureSubImage2D(
        texture,
        0,
        0,
        0,
        @intCast(width),
        @intCast(height),
        gl.RGBA,
        gl.UNSIGNED_BYTE,
        rgba.ptr,
    );
    return .{ .texture = texture };
}

fn createTexture(width: u32, height: u32, internal_format: gl.@"enum") gl.uint {
    var texture: gl.uint = 0;
    gl.CreateTextures(gl.TEXTURE_2D, 1, @ptrCast(&texture));
    if (texture == 0) fatal("glCreateTextures returned zero");
    gl.TextureStorage2D(texture, 1, internal_format, @intCast(width), @intCast(height));
    gl.TextureParameteri(texture, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TextureParameteri(texture, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.TextureParameteri(texture, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    return texture;
}

pub fn render(
    self: *Gl46Renderer,
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
    _ = remote_session;
    self.ensureInitialized(hwnd) catch |err| {
        self.recordFailure("initialize surface", err);
        return;
    };
    const prepared = self.prepareFrame(hwnd, term, mouse_in_scrollbar) orelse return;

    if (self.kitty_images.sync(std.heap.page_allocator, self, tab_id, term)) {
        self.grid_force_full = true;
    }
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

    const presentation = self.beginPresentation(hwnd, prepared.client_w, prepared.client_h) orelse return;
    self.drawFrame(prepared, tabbar);
    self.finishFrame(presentation);
}

fn enableBaseline(self: *Gl46Renderer) void {
    const hwnd = self.hwnd.?;
    const style = win32.GetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE);
    const no_redirection: isize = @intCast(@as(u32, @bitCast(win32.WINDOW_EX_STYLE{ .NOREDIRECTIONBITMAP = 1 })));
    if (style & no_redirection != 0) {
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_EXSTYLE, style & ~no_redirection);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{ .DRAWFRAME = 1, .NOMOVE = 1, .NOSIZE = 1, .NOZORDER = 1, .NOACTIVATE = 1 });
    }
}

fn beginPresentation(self: *Gl46Renderer, hwnd: win32.HWND, width: u32, height: u32) ?interop.Path {
    if (!self.presentation.usesInterop()) {
        self.pure_wgl_surface.begin(width, height);
        return .baseline;
    }
    if (self.interop_state == .untried) {
        if (self.parent) |parent| {
            if (parent.interop_state != .active) self.interop_state = .unavailable;
        }
        if (self.interop_state == .untried) {
            const parent_bridge: ?*interop.Bridge = if (self.parent) |parent| &parent.interop_bridge.? else null;
            self.interop_bridge = interop.Bridge.init(hwnd, width, height, parent_bridge) catch |err| {
                if (self.parent != null) {
                    self.recordFailure("create pane interop bridge", err);
                    return null;
                }
                self.interop_state = .unavailable;
                log.warn("DirectComposition bridge unavailable ({s}); using baseline WGL presentation", .{@errorName(err)});
                self.enableBaseline();
                self.pure_wgl_surface.begin(width, height);
                return .baseline;
            };
            self.interop_state = .active;
            log.info("WGL_NV_DX_interop2 DirectComposition bridge active: surface={} device=0x{x}", .{ self.common.surface_id, @intFromPtr(self.interop_bridge.?.presenter.device) });
        }
    }
    if (self.interop_state.path() == .direct_composition) {
        self.interop_bridge.?.begin(width, height) catch |err| {
            if (err == error.FrameBusy) {
                self.frame_pending = true;
                return null;
            }
            self.failInterop(err);
            return null;
        };
    } else {
        self.enableBaseline();
        self.pure_wgl_surface.begin(width, height);
    }
    return self.interop_state.path();
}

test "pure WGL presentation never selects the interoperability bridge" {
    try std.testing.expect(!Presentation.pure_wgl.usesInterop());
    try std.testing.expect(Presentation.interop.usesInterop());
}

test "OpenGL grid replaces stale pixels before overlays blend" {
    try std.testing.expect(!RenderPass.grid.blendEnabled());
    try std.testing.expect(RenderPass.overlay.blendEnabled());
}

test "pure WGL pixel format contract requires alpha sRGB and DWM composition" {
    var pfd = pixelFormatDescriptor();
    const valid = [_]i32{ 1, 1, 1, WGL_TYPE_RGBA_ARB, 24, 8, 1 };
    try std.testing.expect(purePixelFormatMeetsContract(valid, pfd));

    var missing_srgb = valid;
    missing_srgb[6] = 0;
    try std.testing.expect(!purePixelFormatMeetsContract(missing_srgb, pfd));

    var missing_alpha = valid;
    missing_alpha[5] = 0;
    try std.testing.expect(!purePixelFormatMeetsContract(missing_alpha, pfd));

    var insufficient_rgb = valid;
    insufficient_rgb[4] = 16;
    try std.testing.expect(!purePixelFormatMeetsContract(insufficient_rgb, pfd));

    pfd.dwFlags.SUPPORT_COMPOSITION = 0;
    try std.testing.expect(!purePixelFormatMeetsContract(valid, pfd));
}

fn failInterop(self: *Gl46Renderer, err: anyerror) void {
    self.recordFailure("interop presentation", err);
}

pub fn renderChrome(self: *Gl46Renderer, hwnd: win32.HWND, term: *vt.Terminal, tabbar: types.TabBarDraw, background: u24, opacity: f32, remote_session: bool, pane_rects: []const win32.RECT) void {
    _ = remote_session;
    self.ensureInitialized(hwnd) catch |err| {
        self.recordFailure("initialize chrome", err);
        return;
    };
    const prepared = self.prepareFrame(hwnd, term, false) orelse return;
    const path = self.beginPresentation(hwnd, prepared.client_w, prepared.client_h) orelse return;
    gl.Disable(gl.SCISSOR_TEST);
    gl.ClearColor(
        std.math.pow(f32, @as(f32, @floatFromInt((background >> 16) & 0xff)) / 255, 2.2) * opacity,
        std.math.pow(f32, @as(f32, @floatFromInt((background >> 8) & 0xff)) / 255, 2.2) * opacity,
        std.math.pow(f32, @as(f32, @floatFromInt(background & 0xff)) / 255, 2.2) * opacity,
        opacity,
    );
    gl.Clear(gl.COLOR_BUFFER_BIT);
    gl.Enable(gl.SCISSOR_TEST);
    gl.ClearColor(0, 0, 0, 0);
    for (pane_rects) |rect| {
        gl.Scissor(rect.left, @as(gl.int, @intCast(prepared.client_h)) - rect.bottom, rect.right - rect.left, rect.bottom - rect.top);
        gl.Clear(gl.COLOR_BUFFER_BIT);
    }
    gl.Disable(gl.SCISSOR_TEST);
    gl.BindVertexArray(self.vao);
    gl.Viewport(0, 0, @intCast(prepared.client_w), @intCast(prepared.client_h));
    gl.UseProgram(self.image_program);
    RenderPass.overlay.begin();
    self.drawTabBar(prepared, tabbar, 0);
    self.finishFrame(path);
}

pub fn syncSurface(self: *Gl46Renderer, parent: *Gl46Renderer) void {
    if (self.bg_image_generation != parent.bg_image_generation or self.background_image.texture != parent.background_image.texture) {
        self.background_image = parent.background_image;
        self.bg_image_generation = parent.bg_image_generation;
        self.grid_force_full = true;
    }
    if (self.bg_image_opacity != parent.bg_image_opacity or self.bg_image_position != parent.bg_image_position or self.bg_image_fit != parent.bg_image_fit or self.bg_image_repeat != parent.bg_image_repeat) self.grid_force_full = true;
    self.bg_image_opacity = parent.bg_image_opacity;
    self.bg_image_position = parent.bg_image_position;
    self.bg_image_fit = parent.bg_image_fit;
    self.bg_image_repeat = parent.bg_image_repeat;
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
    self: *Gl46Renderer,
    hwnd: win32.HWND,
    term: *vt.Terminal,
    mouse_in_scrollbar: bool,
) ?PreparedFrame {
    const sz = win32.getClientSize(hwnd);
    const client_w: u32 = @intCast(sz.cx);
    const client_h: u32 = @intCast(sz.cy);
    if (client_w == 0 or client_h == 0) return null;
    if (!self.beginFrame()) return null;

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
    const sb = term.screens.active.pages.scrollbar();
    const show = sb.total > sb.len and (!term.screens.active.viewportIsBottom() or mouse_in_scrollbar);
    if (show) {
        const origin_y: f32 = @floatFromInt(tab_bar_h);
        const win_h: f32 = @floatFromInt(client_h -| tab_bar_h);
        const track_h = @max(20.0, @as(f32, @floatFromInt(sb.len)) /
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

fn drawFrame(self: *Gl46Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw) void {
    gl.BindVertexArray(self.vao);
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);

    const grid_offset = self.frame_slot * self.grid_ubo_stride;
    @memcpy(
        self.grid_ubo.bytes.?[grid_offset..][0..@sizeOf(shader.GridConfig)],
        std.mem.asBytes(&prepared.config),
    );
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);
    gl.BindBufferRange(
        gl.UNIFORM_BUFFER,
        0,
        self.grid_ubo.name,
        @intCast(grid_offset),
        @sizeOf(shader.GridConfig),
    );
    gl.BindBufferRange(
        gl.SHADER_STORAGE_BUFFER,
        1,
        self.cells.name,
        @intCast(self.frame_slot * self.cells_stride),
        @intCast(@as(usize, self.cells_count) * @sizeOf(shader.Cell)),
    );
    gl.BindTextureUnit(2, self.atlas);
    gl.BindTextureUnit(3, self.background_image.texture);
    gl.Viewport(0, @intCast(prepared.tab_bar_h), @intCast(prepared.client_w), @intCast(prepared.term_pixel_h));
    gl.UseProgram(self.grid_program);
    RenderPass.grid.begin();
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);

    RenderPass.overlay.begin();
    const visible_images = self.countVisiblePlacements();
    self.ensureImageUboCapacity(visible_images + 1);
    var config_index: usize = 0;
    gl.Viewport(0, 0, @intCast(prepared.client_w), @intCast(prepared.client_h));
    gl.UseProgram(self.image_program);
    for (self.kitty_images.placements.items) |placement| {
        if (placement.z < 0) continue;
        const entry = self.kitty_images.images.get(.{
            .tab_id = self.kitty_images.last_tab_id,
            .image_id = placement.image_id,
        }) orelse continue;
        var config: kitty_image_mod.ImageConfig = .{
            .dest = .{
                @floatFromInt(@as(i64, placement.x) * prepared.cs.x + placement.cell_offset_x),
                @floatFromInt(@as(i64, placement.y) * prepared.cs.y + placement.cell_offset_y),
                @floatFromInt(placement.width),
                @floatFromInt(placement.height),
            },
            .source = .{
                @floatFromInt(placement.source_x),
                @floatFromInt(placement.source_y),
                @floatFromInt(placement.source_width),
                @floatFromInt(placement.source_height),
            },
            .image_size = .{ @floatFromInt(entry.width), @floatFromInt(entry.height) },
            .tab_bar_height = @floatFromInt(prepared.tab_bar_h),
        };
        self.drawImageConfig(config_index, &config, entry.image.texture);
        config_index += 1;
    }

    self.drawTabBar(prepared, tabbar, config_index);
    self.grid_force_full = false;
}

fn drawTabBar(self: *Gl46Renderer, prepared: PreparedFrame, tabbar: types.TabBarDraw, config_index: usize) void {
    if (prepared.tab_bar_h != 0) {
        const band = self.font_service.cpuBand(prepared.client_w, prepared.tab_bar_h);
        self.ensureTabbarTexture(prepared.client_w, prepared.tab_bar_h);
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
            const pixels = band.readPixels();
            gl.TextureSubImage2D(
                self.tabbar_texture,
                0,
                0,
                0,
                @intCast(prepared.client_w),
                @intCast(prepared.tab_bar_h),
                gl.BGRA,
                gl.UNSIGNED_BYTE,
                pixels.ptr,
            );
            self.tabbar_sig = sig;
            self.tabbar_sig_rt = band.render_target;
        }
        var config: kitty_image_mod.ImageConfig = .{
            .dest = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .source = .{ 0, 0, @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .image_size = .{ @floatFromInt(prepared.client_w), @floatFromInt(prepared.tab_bar_h) },
            .tab_bar_height = 0,
        };
        self.drawImageConfig(config_index, &config, self.tabbar_texture);
    }
}

fn countVisiblePlacements(self: *Gl46Renderer) usize {
    var count: usize = 0;
    for (self.kitty_images.placements.items) |placement| {
        if (placement.z >= 0) count += 1;
    }
    return count;
}

fn ensureImageUboCapacity(self: *Gl46Renderer, wanted: usize) void {
    if (wanted <= self.image_ubo_capacity) return;
    self.image_ubo.release();
    self.image_ubo_capacity = wanted;
    self.image_ubo = MappedBuffer.create(self.image_ubo_stride * wanted * frame_count);
}

fn drawImageConfig(
    self: *Gl46Renderer,
    index: usize,
    config: *const kitty_image_mod.ImageConfig,
    texture: gl.uint,
) void {
    const offset = (self.frame_slot * self.image_ubo_capacity + index) * self.image_ubo_stride;
    @memcpy(
        self.image_ubo.bytes.?[offset..][0..@sizeOf(kitty_image_mod.ImageConfig)],
        std.mem.asBytes(config),
    );
    gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT);
    gl.BindBufferRange(
        gl.UNIFORM_BUFFER,
        0,
        self.image_ubo.name,
        @intCast(offset),
        @sizeOf(kitty_image_mod.ImageConfig),
    );
    gl.BindTextureUnit(5, texture);
    gl.DrawArrays(gl.TRIANGLE_STRIP, 0, 4);
}

fn ensureTabbarTexture(self: *Gl46Renderer, width: u32, height: u32) void {
    if (self.tabbar_texture != 0 and
        self.tabbar_size.cx == @as(i32, @intCast(width)) and
        self.tabbar_size.cy == @as(i32, @intCast(height))) return;
    if (self.tabbar_texture != 0) gl.DeleteTextures(1, @ptrCast(&self.tabbar_texture));
    self.tabbar_texture = createTexture(width, height, gl.RGBA8);
    self.tabbar_size = .{ .cx = @intCast(width), .cy = @intCast(height) };
    // Fresh texture contents are undefined; force the next frame to repaint and
    // re-upload even if the band signature happens to repeat (resize A -> B -> A).
    self.tabbar_sig_rt = null;
}

pub fn applyGlyphResult(self: *Gl46Renderer, result: *RasterResult) bool {
    if (!self.initialized) return false;
    if (!self.activate()) return false;
    return glyph_mod.applyRasterResult(self, result);
}

pub fn reloadBackgroundImage(
    self: *Gl46Renderer,
    gpa: std.mem.Allocator,
    cfg: *const Config,
    hwnd: win32.HWND,
) void {
    self.ensureInitialized(hwnd) catch |err| {
        self.recordFailure("initialize surface", err);
        return;
    };
    self.bg_image_allocator = gpa;
    bg_image.reload(self, gpa, cfg, hwnd);
}

pub fn applyDecodedBackgroundImage(self: *Gl46Renderer, result: *const BgImageDecoded) void {
    if (!self.initialized) return;
    if (!self.activate()) return;
    bg_image.applyDecoded(self, result);
}

pub fn releaseKittyImagesForTab(self: *Gl46Renderer, tab_id: types.TabId) void {
    if (self.initialized and !self.activate()) return;
    self.kitty_images.releaseForTab(std.heap.page_allocator, tab_id);
}

test "OpenGL consumes the shared SPIR-V shader contract" {
    try std.testing.expectEqual(@as(u8, 4), gl.info.version_major);
    try std.testing.expectEqual(@as(u8, 6), gl.info.version_minor);
    try std.testing.expectEqual(shared.GlyphHandoff.cpu_pixels, glyph_handoff);
    inline for (.{ shader_assets.vertex, shader_assets.pixel, shader_assets.image_pixel }) |asset| {
        try std.testing.expectEqualSlices(u8, &.{ 0x03, 0x02, 0x23, 0x07 }, asset.spirv[0..4]);
    }
}

test "three completion slots keep mapped frame data isolated" {
    try std.testing.expectEqual(@as(usize, 3), frame_count);
    var slot: usize = frame_count - 1;
    const expected = [_]usize{ 0, 1, 2, 0, 1, 2 };
    for (expected) |next| {
        slot = (slot + 1) % frame_count;
        try std.testing.expectEqual(next, slot);
    }
    try std.testing.expect(@sizeOf(shader.GridConfig) <= 256);
    try std.testing.expect(@sizeOf(kitty_image_mod.ImageConfig) <= 256);
}

test "OpenGL panes share context and programs but own DCs buffers and glyph caches" {
    const Windows = struct {
        fn create(parent: ?win32.HWND) !win32.HWND {
            const name = win32.L("MosttyGlPaneTest");
            const wc: win32.WNDCLASSEXW = .{
                .cbSize = @sizeOf(win32.WNDCLASSEXW),
                .style = .{ .OWNDC = 1 },
                .lpfnWndProc = bootstrapWndProc,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = win32.GetModuleHandleW(null),
                .hIcon = null,
                .hCursor = null,
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = name,
                .hIconSm = null,
            };
            if (win32.RegisterClassExW(&wc) == 0 and win32.GetLastError() != .ERROR_CLASS_ALREADY_EXISTS) return error.TestWindowUnavailable;
            return win32.CreateWindowExW(.{}, name, win32.L(""), .{ .CHILD = if (parent != null) 1 else 0 }, 0, 0, 200, 160, parent, null, wc.hInstance, null) orelse error.TestWindowUnavailable;
        }
    };
    inline for (.{ Presentation.interop, .pure_wgl }) |mode| {
        const hwnd = try Windows.create(null);
        defer _ = win32.DestroyWindow(hwnd);
        const ah = try Windows.create(hwnd);
        defer _ = win32.DestroyWindow(ah);
        const bh = try Windows.create(hwnd);
        defer _ = win32.DestroyWindow(bh);
        var common: RendererCommon = undefined;
        var fonts = FontService.init(&common, 96, .{}, true, null);
        defer fonts.deinit();
        var parent = init(&common, &fonts, null, mode);
        defer parent.deinit();
        parent.initializeWindow(hwnd) catch |err| switch (err) {
            error.CreateContextUnavailable,
            error.CoreContextRejected,
            error.VersionTooOld,
            error.PixelFormatExtensionUnavailable,
            error.PixelFormatContractUnavailable,
            error.SwapControlUnavailable,
            error.BootstrapContextFailed,
            => {
                log.warn("OpenGL pane GPU test unavailable on this driver: {s}", .{@errorName(err)});
                return error.SkipZigTest;
            },
            else => return err,
        };
        var ac = common;
        ac.surface_id = 1;
        ac.tab_bar_height = 0;
        var bc = ac;
        bc.surface_id = 2;
        var a = initSurface(&parent, &ac);
        defer a.deinit();
        var b = initSurface(&parent, &bc);
        defer b.deinit();
        try a.initializeWindow(ah);
        try b.initializeWindow(bh);
        try std.testing.expect(a.context == parent.context and b.context == parent.context);
        try std.testing.expect(a.dc != b.dc and a.dc != parent.dc);
        try std.testing.expect(a.grid_program == parent.grid_program and b.image_program == parent.image_program);
        try std.testing.expect(a.font_service == &fonts and b.font_service == &fonts);
        try std.testing.expect(a.grid_ubo.name != b.grid_ubo.name);
        try std.testing.expect(a.vao != b.vao);
        try std.testing.expect(a.activate());
        try std.testing.expect(a.cellsResize(4));
        _ = a.atlasEnsure(.{ .x = 32, .y = 32 });
        try std.testing.expect(b.activate());
        try std.testing.expect(b.cellsResize(4));
        _ = b.atlasEnsure(.{ .x = 32, .y = 32 });
        try std.testing.expect(a.cells.name != b.cells.name and a.atlas != b.atlas);
        a.glyph_cache = try GlyphIndexCache.init(a.glyph_cache_arena.allocator(), 2);
        b.glyph_cache = try GlyphIndexCache.init(b.glyph_cache_arena.allocator(), 2);
        const key: GlyphIndexCache.Key = .init('x', &.{}, .single, .regular);
        const slot = (try a.glyph_cache.?.reserve(a.glyph_cache_arena.allocator(), key)).newly_reserved_pending;
        _ = try b.glyph_cache.?.reserve(b.glyph_cache_arena.allocator(), key);
        var result: RasterResult = .{ .surface_id = 1, .slot = slot.index, .slot_gen = slot.slot_gen, .cache_gen = a.cache_gen, .key = key, .bytes = &.{}, .w = 0, .h = 0, .is_color = false, .failed = true };
        try std.testing.expect(!b.applyGlyphResult(&result));
        try std.testing.expect((try b.glyph_cache.?.reserve(b.glyph_cache_arena.allocator(), key)) == .already_pending);
        try std.testing.expect(a.applyGlyphResult(&result));
        try std.testing.expect(win32.wglGetCurrentDC() == a.dc);
        try std.testing.expect(parent.activate());
        var pixels = [_]u8{ 0, 64, 128, 255 };
        parent.backgroundImageUpload(.{ .pixels = &pixels, .w = 1, .h = 1 });
        a.syncSurface(&parent);
        b.syncSurface(&parent);
        try std.testing.expect(a.background_image.texture == parent.background_image.texture and b.background_image.texture != 0);
        parent.backgroundImageRelease();
        a.syncSurface(&parent);
        b.syncSurface(&parent);
        try std.testing.expect(!a.background_image.loaded() and !b.background_image.loaded());
        // Destroying one child must leave the borrowed context and programs usable.
        var transient_common = ac;
        transient_common.surface_id = 3;
        var transient = initSurface(&parent, &transient_common);
        try transient.initializeWindow(ah);
        transient.deinit();
        try std.testing.expect(parent.activate());
        try std.testing.expect(gl.IsProgram(parent.grid_program) == gl.TRUE);
        if (mode == .pure_wgl) {
            var hook_context: u8 = 0;
            var session: @import("../terminal/Session.zig") = undefined;
            try session.init(.{ .io = std.Io.Threaded.global_single_threaded.io(), .terminal_allocator = std.testing.allocator, .stream_allocator = std.testing.allocator, .cols = 8, .rows = 4, .hooks = .{ .context = &hook_context } });
            defer session.deinit();
            common.tab_bar_height = 0;
            const hole = win32.RECT{ .left = 0, .top = 10, .right = 100, .bottom = 50 };
            parent.renderChrome(hwnd, session.term, .{ .tabs = &.{}, .new_tab_col = null, .new_tab_hovered = false }, 0xffffff, 1, false, &.{hole});
            try std.testing.expect(parent.failure == null);
            gl.BindFramebuffer(gl.READ_FRAMEBUFFER, parent.pure_wgl_surface.framebuffer);
            var inside: [4]u8 = undefined;
            var outside: [4]u8 = undefined;
            const height = win32.getClientSize(hwnd).cy;
            // Readback uses lower-left coordinates; the requested pane hole is near the top.
            gl.ReadPixels(10, height - 20, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &inside);
            gl.ReadPixels(10, 20, 1, 1, gl.RGBA, gl.UNSIGNED_BYTE, &outside);
            try std.testing.expectEqual(@as(u8, 0), inside[3]);
            try std.testing.expectEqual(@as(u8, 255), outside[3]);
            gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0);
        }
    }
    const recovery_hwnd = try Windows.create(null);
    defer _ = win32.DestroyWindow(recovery_hwnd);
    var facade: @import("renderer.zig") = undefined;
    try facade.init(96, .{}, true, null, .opengl, false);
    defer facade.deinit();
    try std.testing.expect(facade.initializeWindow(recovery_hwnd, null) == null);
    facade.backend.?.opengl.interop_state = .unavailable;
    const old_request: u32 = 19;
    const new_generation: u32 = 43;
    facade.backend.?.opengl.bg_image_req_id = old_request;
    try std.testing.expect(facade.recoverOpenGL(recovery_hwnd, null, new_generation));
    try std.testing.expectEqual(interop.State.unavailable, facade.backend.?.opengl.interop_state);
    try std.testing.expectEqual(old_request + 1, facade.backend.?.opengl.bg_image_req_id);
    try std.testing.expectEqual(new_generation, facade.backend.?.opengl.cache_gen);
    try std.testing.expect(facade.backend.?.opengl.activate());
    try std.testing.expect(!facade.recoverOpenGL(recovery_hwnd, null, new_generation + 1));
}
