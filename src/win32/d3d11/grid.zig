//! Persistent grid texture lifecycle + the per-frame draw-and-copy phase
//! that submits to it.
//!
//! "Step B" persistent grid: a client-area-sized B8G8R8A8 RTV we own. The
//! cell pixel shader renders here every frame with scissor restricted to
//! the dirty row range; the whole texture then CopyResource's onto the
//! flip-model back buffer (whose contents are undefined after each Present,
//! so partial redraws can't target it directly).
//!
//! Owns:
//!   * `grid_texture` / `grid_rtv` lifetime + size invalidation.
//!   * `scissor_rasterizer_state` (ScissorEnable=TRUE pipeline state).
//!   * `GridConfigSnapshot` — every const-buffer field that does NOT flow
//!     through per-cell uploads. Frame-to-frame mismatch sets
//!     `grid_force_full` so stale grid pixels outside the dirty rows get
//!     redrawn (e.g. scrollbar moved without any cell change).

const std = @import("std");
const win32 = @import("win32").everything;
const D3d11Renderer = @import("../d3d11.zig");
const com = @import("com.zig");
const kitty_images = @import("kitty_images.zig");
const bg_image = @import("background_image.zig");

// Compared frame-to-frame in render(); any mismatch sets
// `grid_force_full=true` so the persistent grid texture is fully redrawn
// this frame.
//
// What's deliberately NOT here: theme/opacity/background-color changes
// flow into per-cell uploads (blank cells re-upload when eff_bg changes),
// so the per-row dirty path already covers them. Glyph atlas LRU eviction
// during steady rendering doesn't invalidate already-baked grid pixels.
pub const ConfigSnapshot = struct {
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    col_count: u32 = 0,
    row_count: u32 = 0,
    cells_per_row: u16 = 0,
    tab_bar_height: u32 = 0,
    scrollbar_x: f32 = 0,
    scrollbar_y: f32 = 0,
    scrollbar_width: f32 = 0,
    scrollbar_height: f32 = 0,

    pub fn eql(a: ConfigSnapshot, b: ConfigSnapshot) bool {
        return std.meta.eql(a, b);
    }
};

/// Create the persistent grid texture (B8G8R8A8_TYPELESS) and its sRGB RTV.
/// Uses an sRGB RTV so the GPU does linear→sRGB encoding on store, then
/// CopyResource transfers the encoded bytes to the swap-chain back buffer
/// without gamma reinterpretation.
pub fn ensureTexture(self: *D3d11Renderer, width: u32, height: u32) void {
    if (self.grid_texture != null and
        self.grid_texture_size.cx == @as(i32, @intCast(width)) and
        self.grid_texture_size.cy == @as(i32, @intCast(height)))
    {
        return;
    }
    // Release RTV before the underlying texture (RTV holds a ref on the resource).
    if (self.grid_rtv) |rtv| {
        _ = rtv.IUnknown.Release();
        self.grid_rtv = null;
    }
    if (self.grid_texture) |t| {
        _ = t.IUnknown.Release();
        self.grid_texture = null;
    }
    // Resource is TYPELESS so we can create an `_SRGB` RTV view on it.
    // CreateTexture2D with format `B8G8R8A8_UNORM` would refuse a
    // `B8G8R8A8_UNORM_SRGB` RTV (E_INVALIDARG = 0x80070057) — D3D11
    // requires the view format to be in the same typeless family as the
    // resource format. The swap-chain back buffer gets away with
    // UNORM-resource + _SRGB-RTV only because DXGI flip-model internally
    // creates the back buffers as TYPELESS as a special concession; that
    // concession doesn't extend to user-created textures.
    //
    // CopyResource(back_buffer:UNORM, grid:TYPELESS) is allowed: both
    // formats are in the BGRA8 type group, satisfying the
    // "same-type-group" compatibility rule.
    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .B8G8R8A8_TYPELESS,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .RENDER_TARGET = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    var tex: *win32.ID3D11Texture2D = undefined;
    {
        const hr = self.device.CreateTexture2D(&desc, null, &tex);
        if (hr < 0) com.fatalHr("CreateTexture2D(grid)", hr);
    }
    var rtv: *win32.ID3D11RenderTargetView = undefined;
    {
        const rtv_desc: win32.D3D11_RENDER_TARGET_VIEW_DESC = .{
            .Format = .B8G8R8A8_UNORM_SRGB,
            .ViewDimension = .TEXTURE2D,
            .Anonymous = .{ .Texture2D = .{ .MipSlice = 0 } },
        };
        const hr = self.device.CreateRenderTargetView(&tex.ID3D11Resource, &rtv_desc, &rtv);
        if (hr < 0) com.fatalHr("CreateRenderTargetView(grid)", hr);
    }
    self.grid_texture = tex;
    self.grid_rtv = rtv;
    self.grid_texture_size = .{ .cx = @intCast(width), .cy = @intCast(height) };
    // Fresh texture content is undefined; the next render must cover every
    // pixel inside the visible client area, not just the dirty row range.
    self.grid_force_full = true;
}

/// Lazily create the rasterizer state with ScissorEnable=TRUE. Reused
/// across frames (device-lifetime). All other fields are D3D11 defaults.
pub fn ensureScissorRasterizerState(self: *D3d11Renderer) *win32.ID3D11RasterizerState {
    if (self.scissor_rasterizer_state) |rs| return rs;
    const desc: win32.D3D11_RASTERIZER_DESC = .{
        .FillMode = .SOLID,
        .CullMode = .NONE,
        .FrontCounterClockwise = 0,
        .DepthBias = 0,
        .DepthBiasClamp = 0,
        .SlopeScaledDepthBias = 0,
        .DepthClipEnable = 1,
        .ScissorEnable = 1,
        .MultisampleEnable = 0,
        .AntialiasedLineEnable = 0,
    };
    var rs: *win32.ID3D11RasterizerState = undefined;
    const hr = self.device.CreateRasterizerState(&desc, &rs);
    if (hr < 0) com.fatalHr("CreateRasterizerState(scissor)", hr);
    self.scissor_rasterizer_state = rs;
    return rs;
}

pub const DrawInputs = struct {
    client_w: u32,
    client_h: u32,
    tab_bar_h: u32,
    term_pixel_h: u32,
    cell_w: u16,
    cell_h: u16,
    term_shader_row: u32,
    cell_count: u32,
    dirty_min_row: ?u32,
    dirty_max_row: ?u32,
    resizing: bool,
    kitty_images_present: bool,
};

/// Step B draw-scope decision and submission. Decides full-vs-dirty-strip
/// scissor, binds the persistent grid RTV + SRVs + samplers, draws the
/// full-screen quad, then CopyResource's the grid texture onto the
/// already-acquired back buffer.
///
/// `grid_force_full` is cleared only when an actual Draw runs — skipped
/// frames must not drop the flag, otherwise the next non-skipped frame
/// misses the full redraw it needed.
pub fn drawAndCopy(self: *D3d11Renderer, in: DrawInputs) void {
    // Draw decision:
    //   - grid_force_full → full client-area scissor; redraw everything
    //   - dirty_min_row != null → scissor to that row strip only
    //   - else → no row content changed, no const-buffer change; skip
    //     Draw entirely. The persistent grid texture still holds the
    //     correct image from the previous render(); the CopyResource below
    //     delivers it to the freshly-rotated back buffer.
    const full_redraw = self.grid_force_full or in.resizing or (in.kitty_images_present and in.dirty_min_row != null);
    const have_row_dirty = in.dirty_min_row != null;
    const do_draw = full_redraw or have_row_dirty;

    if (do_draw) {
        // Bind the persistent grid texture as the draw target. Unlike the
        // back buffer (rotated after each Present, contents undefined),
        // the grid texture is owned by us and retains pixels across
        // frames — that's what makes the scissor optimization safe.
        var target_views = [_]?*win32.ID3D11RenderTargetView{self.grid_rtv.?};
        self.context.OMSetRenderTargets(target_views.len, &target_views, null);

        // Compute scissor rect. When full_redraw, cover the entire client
        // area; otherwise restrict to the dirty row strip (in RT-absolute
        // pixel coords, including the tab-bar offset since the viewport
        // below is also tab-bar-offset and the rasterizer applies viewport
        // first, then scissor). right/bottom are exclusive per D3D11 spec;
        // clamp bottom to client_h defensively.
        const scissor: win32.RECT = if (full_redraw) .{
            .left = 0,
            .top = 0,
            .right = @intCast(in.client_w),
            .bottom = @intCast(in.client_h),
        } else blk: {
            const last_row = in.term_shader_row -| 1;
            const lo = @min(in.dirty_min_row.?, last_row);
            const hi = @min(in.dirty_max_row.?, last_row);
            const y0_u: u32 = in.tab_bar_h + lo * in.cell_h;
            const y1_u: u32 = @min(in.tab_bar_h + (hi + 1) * in.cell_h, in.client_h);
            break :blk .{
                .left = 0,
                .top = @intCast(y0_u),
                .right = @intCast(in.client_w),
                .bottom = @intCast(y1_u),
            };
        };
        self.context.RSSetState(self.scissor_rasterizer_state.?);
        self.context.RSSetScissorRects(1, @ptrCast(&scissor));

        // Offset the grid below the tab-bar band. Set every frame from the
        // current size + tab_bar_h: a font/DPI/config reload can change
        // tab_bar_h without a swap-chain resize (stale-viewport bug
        // otherwise).
        var viewport = win32.D3D11_VIEWPORT{
            .TopLeftX = 0,
            .TopLeftY = @floatFromInt(in.tab_bar_h),
            .Width = @floatFromInt(in.client_w),
            .Height = @floatFromInt(in.term_pixel_h),
            .MinDepth = 0.0,
            .MaxDepth = 0.0,
        };
        self.context.RSSetViewports(1, @ptrCast(&viewport));

        self.context.PSSetConstantBuffers(0, 1, @ptrCast(@constCast(&self.const_buf)));
        var resources = [_]?*win32.ID3D11ShaderResourceView{
            if (in.cell_count > 0) self.shader_cells.cell_view else null,
            self.glyph_texture.view,
            // t2: background image. Null when none configured — the
            // shader gates all sampling on bg_image_flags so the null
            // bind is inert.
            self.background_image.view,
        };
        self.context.PSSetShaderResources(0, resources.len, &resources);
        if (self.background_image.loaded()) {
            const sampler = bg_image.ensureSampler(self);
            self.context.PSSetSamplers(0, 1, @ptrCast(@constCast(&sampler)));
        }
        self.context.VSSetShader(self.vertex_shader, null, 0);
        self.context.PSSetShader(self.pixel_shader, null, 0);
        // ClearRenderTargetView is intentionally NOT called here: the
        // cell shader writes every pixel inside the scissor rect
        // (background color even for blank cells). Outside the scissor
        // the persistent grid texture retains the previous frame's
        // correct pixels. First frame after (re)create has
        // grid_force_full=true → scissor = full client area → shader
        // covers everything. ClearRenderTargetView ignores scissor and
        // would wipe valid regions.
        self.context.Draw(4, 0);

        // Clear the force-full flag only now that a redraw actually ran.
        self.grid_force_full = false;
    }

    if (do_draw) {
        kitty_images.draw(self, .{
            .client_w = in.client_w,
            .client_h = in.client_h,
            .tab_bar_h = in.tab_bar_h,
            .term_pixel_h = in.term_pixel_h,
            .cell_w = in.cell_w,
            .cell_h = in.cell_h,
        });
    }

    // Deliver the grid texture to the back buffer. Always runs — flip-model
    // gave us a fresh undefined back buffer; the grid texture (whether
    // updated above or unchanged from last frame) is the correct image.
    // Unbind RTVs first: CopyResource forbids src or dst being currently
    // bound as an RTV / SRV in the immediate context.
    self.context.OMSetRenderTargets(0, null, null);
    if (self.back_buffer_tex) |bb| {
        self.context.CopyResource(
            &bb.ID3D11Resource,
            &self.grid_texture.?.ID3D11Resource,
        );
    }
}
