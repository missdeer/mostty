const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;

const D3d11Renderer = @import("../d3d11.zig");
const bg_image = @import("background_image.zig");
const com = @import("com.zig");
const types = @import("../types.zig");

const log = std.log.scoped(.kitty_images);

const Key = struct {
    tab_id: types.TabId,
    image_id: u32,
};

const Entry = struct {
    texture: *win32.ID3D11Texture2D,
    view: *win32.ID3D11ShaderResourceView,
    transmit_time: std.time.Instant,
    width: u32,
    height: u32,

    fn release(self: *Entry) void {
        _ = self.view.IUnknown.Release();
        _ = self.texture.IUnknown.Release();
    }
};

const Placement = struct {
    image_id: u32,
    x: i32,
    y: i32,
    z: i32,
    width: u32,
    height: u32,
    cell_offset_x: u32,
    cell_offset_y: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

pub const ImageConfig = extern struct {
    dest: [4]f32,
    source: [4]f32,
    image_size: [2]f32,
    tab_bar_height: f32,
    _pad: f32 = 0,
};

pub const Cache = struct {
    images: std.AutoHashMapUnmanaged(Key, Entry) = .{},
    placements: std.ArrayListUnmanaged(Placement) = .{},
    last_hash: u64 = 0,
    last_tab_id: types.TabId = 0,
    last_tab_valid: bool = false,

    pub fn deinit(self: *Cache, alloc: std.mem.Allocator) void {
        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.release();
        self.images.deinit(alloc);
        self.placements.deinit(alloc);
        self.* = .{};
    }

    pub fn releaseForTab(self: *Cache, alloc: std.mem.Allocator, tab_id: types.TabId) void {
        var keys_to_remove: std.ArrayListUnmanaged(Key) = .{};
        defer keys_to_remove.deinit(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.key_ptr.tab_id != tab_id) continue;
            keys_to_remove.append(alloc, kv.key_ptr.*) catch |err| {
                log.warn("leaking Kitty image during tab close after key collection failed: {s}", .{@errorName(err)});
            };
        }

        for (keys_to_remove.items) |key| {
            if (self.images.fetchRemove(key)) |removed| {
                var entry = removed.value;
                entry.release();
            }
        }
        if (self.last_tab_valid and self.last_tab_id == tab_id) {
            self.placements.clearRetainingCapacity();
            self.last_hash = 0;
            self.last_tab_valid = false;
        }
    }

    pub fn sync(
        self: *Cache,
        alloc: std.mem.Allocator,
        renderer: *D3d11Renderer,
        tab_id: types.TabId,
        term: *const vt.Terminal,
    ) bool {
        const storage = &term.screens.active.kitty_images;
        var invalidated = storage.dirty or !self.last_tab_valid or self.last_tab_id != tab_id;

        pruneRemovedImages(self, alloc, tab_id, storage, &invalidated);

        self.placements.clearRetainingCapacity();
        var virtual_seen = false;

        const top = term.screens.active.pages.getTopLeft(.viewport);
        const bot = term.screens.active.pages.getBottomRight(.viewport) orelse return invalidated;
        const top_y = term.screens.active.pages.pointFromPin(.screen, top).?.screen.y;
        const bot_y = term.screens.active.pages.pointFromPin(.screen, bot).?.screen.y;

        var it = storage.placements.iterator();
        while (it.next()) |kv| {
            const placement = kv.value_ptr;
            switch (placement.location) {
                .pin => {},
                .virtual => {
                    virtual_seen = true;
                    continue;
                },
            }
            const image = storage.imageById(kv.key_ptr.image_id) orelse continue;
            tryPreparePlacement(self, alloc, renderer, tab_id, term, top_y, bot_y, image, placement, &invalidated) catch |err| {
                log.warn("skipping Kitty image placement: {s}", .{@errorName(err)});
            };
        }

        if (virtual_seen) {
            // Virtual placeholder placement is deliberately outside this first
            // pass. Rebuild next frame if it remains present.
            invalidated = true;
        }

        std.mem.sortUnstable(Placement, self.placements.items, {}, struct {
            fn lessThan(_: void, lhs: Placement, rhs: Placement) bool {
                return lhs.z < rhs.z or (lhs.z == rhs.z and lhs.image_id < rhs.image_id);
            }
        }.lessThan);

        const new_hash = hashPlacements(tab_id, self.placements.items);
        if (new_hash != self.last_hash) invalidated = true;
        self.last_hash = new_hash;
        self.last_tab_id = tab_id;
        self.last_tab_valid = true;
        storage.dirty = false;
        return invalidated;
    }

    pub fn hasVisibleAboveTextPlacements(self: *const Cache) bool {
        for (self.placements.items) |p| {
            if (p.z >= 0) return true;
        }
        return false;
    }
};

fn pruneRemovedImages(
    self: *Cache,
    alloc: std.mem.Allocator,
    tab_id: types.TabId,
    storage: *const vt.kitty.graphics.ImageStorage,
    invalidated: *bool,
) void {
    var keys_to_remove: std.ArrayListUnmanaged(Key) = .{};
    defer keys_to_remove.deinit(alloc);

    var it = self.images.iterator();
    while (it.next()) |kv| {
        if (kv.key_ptr.tab_id != tab_id) continue;
        if (storage.imageById(kv.key_ptr.image_id) != null) continue;
        keys_to_remove.append(alloc, kv.key_ptr.*) catch |err| {
            log.warn("delaying Kitty image prune after key collection failed: {s}", .{@errorName(err)});
        };
    }

    for (keys_to_remove.items) |key| {
        if (self.images.fetchRemove(key)) |removed| {
            var entry = removed.value;
            entry.release();
            invalidated.* = true;
        }
    }
}

fn tryPreparePlacement(
    self: *Cache,
    alloc: std.mem.Allocator,
    renderer: *D3d11Renderer,
    tab_id: types.TabId,
    term: *const vt.Terminal,
    top_y: u32,
    bot_y: u32,
    image: vt.kitty.graphics.Image,
    placement: *const vt.kitty.graphics.ImageStorage.Placement,
    invalidated: *bool,
) !void {
    const rect = placement.rect(image, term) orelse return;
    const img_top_y = term.screens.active.pages.pointFromPin(.screen, rect.top_left).?.screen.y;
    const img_bot_y = term.screens.active.pages.pointFromPin(.screen, rect.bottom_right).?.screen.y;
    if (img_top_y > bot_y or img_bot_y < top_y) return;

    try uploadImageIfNeeded(self, alloc, renderer, tab_id, image, invalidated);

    const dest_size = placement.pixelSize(image, term);
    if (dest_size.width == 0 or dest_size.height == 0) return;

    const source_x = @min(image.width, placement.source_x);
    const source_y = @min(image.height, placement.source_y);
    const source_width = if (placement.source_width > 0)
        @min(image.width - source_x, placement.source_width)
    else
        image.width - source_x;
    const source_height = if (placement.source_height > 0)
        @min(image.height - source_y, placement.source_height)
    else
        image.height - source_y;
    if (source_width == 0 or source_height == 0) return;

    const y_pos: i32 = @as(i32, @intCast(img_top_y)) - @as(i32, @intCast(top_y));
    try self.placements.append(alloc, .{
        .image_id = image.id,
        .x = @intCast(rect.top_left.x),
        .y = y_pos,
        .z = placement.z,
        .width = dest_size.width,
        .height = dest_size.height,
        .cell_offset_x = placement.x_offset,
        .cell_offset_y = placement.y_offset,
        .source_x = source_x,
        .source_y = source_y,
        .source_width = source_width,
        .source_height = source_height,
    });
}

fn uploadImageIfNeeded(
    self: *Cache,
    alloc: std.mem.Allocator,
    renderer: *D3d11Renderer,
    tab_id: types.TabId,
    image: vt.kitty.graphics.Image,
    invalidated: *bool,
) !void {
    const key: Key = .{ .tab_id = tab_id, .image_id = image.id };
    if (self.images.get(key)) |entry| {
        if (entry.transmit_time.order(image.transmit_time) == .eq) return;
    }

    const rgba = try imageToRgba(alloc, image);
    defer alloc.free(rgba);

    const entry = uploadTexture(renderer.device, image.width, image.height, rgba) orelse return error.UploadFailed;
    errdefer {
        var cleanup = entry;
        cleanup.release();
    }
    const gop = try self.images.getOrPut(alloc, key);
    if (gop.found_existing) gop.value_ptr.release();
    gop.value_ptr.* = .{
        .texture = entry.texture,
        .view = entry.view,
        .transmit_time = image.transmit_time,
        .width = image.width,
        .height = image.height,
    };
    invalidated.* = true;
}

fn imageToRgba(alloc: std.mem.Allocator, image: vt.kitty.graphics.Image) ![]u8 {
    const pixel_count: usize = @as(usize, image.width) * image.height;
    const out = try alloc.alloc(u8, pixel_count * 4);
    errdefer alloc.free(out);

    switch (image.format) {
        .rgba => {
            if (image.data.len != out.len) return error.InvalidData;
            @memcpy(out, image.data);
        },
        .rgb => {
            if (image.data.len != pixel_count * 3) return error.InvalidData;
            var i: usize = 0;
            while (i < pixel_count) : (i += 1) {
                out[i * 4 + 0] = image.data[i * 3 + 0];
                out[i * 4 + 1] = image.data[i * 3 + 1];
                out[i * 4 + 2] = image.data[i * 3 + 2];
                out[i * 4 + 3] = 255;
            }
        },
        .gray => {
            if (image.data.len != pixel_count) return error.InvalidData;
            for (image.data, 0..) |v, i| {
                out[i * 4 + 0] = v;
                out[i * 4 + 1] = v;
                out[i * 4 + 2] = v;
                out[i * 4 + 3] = 255;
            }
        },
        .gray_alpha => {
            if (image.data.len != pixel_count * 2) return error.InvalidData;
            var i: usize = 0;
            while (i < pixel_count) : (i += 1) {
                const gray = image.data[i * 2 + 0];
                out[i * 4 + 0] = gray;
                out[i * 4 + 1] = gray;
                out[i * 4 + 2] = gray;
                out[i * 4 + 3] = image.data[i * 2 + 1];
            }
        },
        .png => return error.InvalidData,
    }
    return out;
}

fn uploadTexture(device: *win32.ID3D11Device, width: u32, height: u32, rgba: []const u8) ?Entry {
    const desc: win32.D3D11_TEXTURE2D_DESC = .{
        .Width = width,
        .Height = height,
        .MipLevels = 1,
        .ArraySize = 1,
        .Format = .R8G8B8A8_UNORM,
        .SampleDesc = .{ .Count = 1, .Quality = 0 },
        .Usage = .DEFAULT,
        .BindFlags = .{ .SHADER_RESOURCE = 1 },
        .CPUAccessFlags = .{},
        .MiscFlags = .{},
    };
    const init_data: win32.D3D11_SUBRESOURCE_DATA = .{
        .pSysMem = @ptrCast(rgba.ptr),
        .SysMemPitch = width * 4,
        .SysMemSlicePitch = 0,
    };
    var texture: *win32.ID3D11Texture2D = undefined;
    if (device.CreateTexture2D(&desc, &init_data, &texture) < 0) return null;
    var view: *win32.ID3D11ShaderResourceView = undefined;
    if (device.CreateShaderResourceView(&texture.ID3D11Resource, null, &view) < 0) {
        _ = texture.IUnknown.Release();
        return null;
    }
    return .{
        .texture = texture,
        .view = view,
        .transmit_time = undefined,
        .width = width,
        .height = height,
    };
}

fn hashPlacements(tab_id: types.TabId, placements: []const Placement) u64 {
    var hasher = std.hash.Wyhash.init(tab_id);
    std.hash.autoHash(&hasher, placements.len);
    for (placements) |p| std.hash.autoHash(&hasher, p);
    return hasher.final();
}

pub fn createBlendState(device: *win32.ID3D11Device) *win32.ID3D11BlendState {
    var desc = std.mem.zeroes(win32.D3D11_BLEND_DESC);
    desc.RenderTarget[0] = .{
        .BlendEnable = 1,
        .SrcBlend = .ONE,
        .DestBlend = .INV_SRC_ALPHA,
        .BlendOp = .ADD,
        .SrcBlendAlpha = .ONE,
        .DestBlendAlpha = .INV_SRC_ALPHA,
        .BlendOpAlpha = .ADD,
        .RenderTargetWriteMask = @intFromEnum(win32.D3D11_COLOR_WRITE_ENABLE_ALL),
    };
    var state: *win32.ID3D11BlendState = undefined;
    const hr = device.CreateBlendState(&desc, &state);
    if (hr < 0) com.fatalHr("CreateBlendState(kitty-images)", hr);
    return state;
}

pub fn draw(
    self: *D3d11Renderer,
    inputs: struct {
        client_w: u32,
        client_h: u32,
        tab_bar_h: u32,
        term_pixel_h: u32,
        cell_w: u16,
        cell_h: u16,
    },
) void {
    if (!self.kitty_images.hasVisibleAboveTextPlacements()) return;

    var target_views = [_]?*win32.ID3D11RenderTargetView{self.grid_rtv.?};
    self.context.OMSetRenderTargets(target_views.len, &target_views, null);

    var viewport = win32.D3D11_VIEWPORT{
        .TopLeftX = 0,
        .TopLeftY = @floatFromInt(inputs.tab_bar_h),
        .Width = @floatFromInt(inputs.client_w),
        .Height = @floatFromInt(inputs.term_pixel_h),
        .MinDepth = 0.0,
        .MaxDepth = 0.0,
    };
    self.context.RSSetViewports(1, @ptrCast(&viewport));
    self.context.RSSetState(self.scissor_rasterizer_state.?);
    self.context.OMSetBlendState(self.image_blend_state, null, 0xffffffff);

    const sampler = bg_image.ensureSampler(self);
    self.context.PSSetSamplers(0, 1, @ptrCast(@constCast(&sampler)));
    self.context.VSSetShader(self.vertex_shader, null, 0);
    self.context.PSSetShader(self.image_pixel_shader, null, 0);

    for (self.kitty_images.placements.items) |p| {
        if (p.z < 0) continue;
        const key: Key = .{ .tab_id = self.kitty_images.last_tab_id, .image_id = p.image_id };
        const image = self.kitty_images.images.get(key) orelse continue;

        const dest_x_i: i64 = @as(i64, p.x) * inputs.cell_w + p.cell_offset_x;
        const dest_y_i: i64 = @as(i64, p.y) * inputs.cell_h + p.cell_offset_y;
        const dest_w_i: i64 = p.width;
        const dest_h_i: i64 = p.height;
        const left = std.math.clamp(dest_x_i, 0, @as(i64, inputs.client_w));
        const top = std.math.clamp(dest_y_i, 0, @as(i64, inputs.term_pixel_h));
        const right = std.math.clamp(dest_x_i + dest_w_i, 0, @as(i64, inputs.client_w));
        const bottom = std.math.clamp(dest_y_i + dest_h_i, 0, @as(i64, inputs.term_pixel_h));
        if (right <= left or bottom <= top) continue;

        const scissor: win32.RECT = .{
            .left = @intCast(left),
            .top = @intCast(@as(i64, inputs.tab_bar_h) + top),
            .right = @intCast(right),
            .bottom = @intCast(@as(i64, inputs.tab_bar_h) + bottom),
        };
        self.context.RSSetScissorRects(1, @ptrCast(&scissor));

        var mapped: win32.D3D11_MAPPED_SUBRESOURCE = undefined;
        const hr = self.context.Map(
            &self.image_const_buf.ID3D11Resource,
            0,
            .WRITE_DISCARD,
            0,
            &mapped,
        );
        if (hr < 0) continue;
        const config: *ImageConfig = @ptrCast(@alignCast(mapped.pData));
        config.* = .{
            .dest = .{
                @floatFromInt(dest_x_i),
                @floatFromInt(dest_y_i),
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
                @floatFromInt(image.width),
                @floatFromInt(image.height),
            },
            .tab_bar_height = @floatFromInt(inputs.tab_bar_h),
        };
        self.context.Unmap(&self.image_const_buf.ID3D11Resource, 0);

        self.context.PSSetConstantBuffers(0, 1, @ptrCast(@constCast(&self.image_const_buf)));
        var resource = [_]?*win32.ID3D11ShaderResourceView{image.view};
        self.context.PSSetShaderResources(3, resource.len, &resource);
        self.context.Draw(4, 0);
    }

    var null_resource = [_]?*win32.ID3D11ShaderResourceView{null};
    self.context.PSSetShaderResources(3, null_resource.len, &null_resource);
    self.context.OMSetBlendState(null, null, 0xffffffff);
}
