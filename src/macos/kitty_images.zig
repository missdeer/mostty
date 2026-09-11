const KittyImages = @This();

const std = @import("std");
const vt = @import("vt");
const graphics = @import("apple.zig").graphics;
const geometry = @import("../renderer/image_geometry.zig");

const Entry = struct {
    image: *graphics.Image,
    generation: u64,
    width: u32,
    height: u32,
};

const Placement = struct {
    image_id: u32,
    placement_id: u32,
    z: i32,
    x: f64,
    y: f64,
    width: u32,
    height: u32,
    source_x: u32,
    source_y: u32,
    source_width: u32,
    source_height: u32,
};

pub const Layer = enum {
    below_background,
    below_text,
    above_text,

    fn forZ(z: i32) Layer {
        return if (z < std.math.minInt(i32) / 2) .below_background else if (z < 0) .below_text else .above_text;
    }
};

images: std.AutoHashMapUnmanaged(u32, Entry) = .empty,
placements: std.ArrayListUnmanaged(Placement) = .empty,

pub fn deinit(self: *KittyImages, allocator: std.mem.Allocator) void {
    var it = self.images.valueIterator();
    while (it.next()) |entry| entry.image.release();
    self.images.deinit(allocator);
    self.placements.deinit(allocator);
    self.* = .{};
}

pub fn sync(self: *KittyImages, allocator: std.mem.Allocator, term: *vt.Terminal) !void {
    const screen = term.screens.active;
    const storage = &screen.kitty_images;
    self.placements.clearRetainingCapacity();
    // Generations are unique across screens. Prune replacements as well as
    // deletions so failed/pending decodes can never display an older image.
    var cached = self.images.iterator();
    while (cached.next()) |entry| {
        if (storage.imageById(entry.key_ptr.*)) |image| {
            if (image.generation == entry.value_ptr.generation and !image.data.isPending()) continue;
        }
        entry.value_ptr.image.release();
        self.images.removeByPtr(entry.key_ptr);
    }

    const top = screen.pages.getTopLeft(.viewport);
    const bottom = screen.pages.getBottomRight(.viewport) orelse return;
    const top_y = screen.pages.pointFromPin(.screen, top).?.screen.y;
    var virtual = false;
    var it = storage.placements.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr;
        const pin = switch (p.location) {
            .pin => |pin| pin,
            .virtual => {
                virtual = true;
                continue;
            },
        };
        if (pin.garbage) continue;
        const image = storage.imageById(entry.key_ptr.image_id) orelse continue;
        const size = p.pixelSize(image, term);
        try self.append(allocator, term, top_y, image, entry.key_ptr.placement_id.id, p.z, .{
            .top_left = pin.*,
            .offset_x = p.x_offset,
            .offset_y = p.y_offset,
            .source_x = p.source_x,
            .source_y = p.source_y,
            .source_width = p.source_width,
            .source_height = p.source_height,
            .dest_width = size.width,
            .dest_height = size.height,
        });
    }
    if (virtual) {
        var placeholders = vt.kitty.graphics.unicode.placementIterator(top, bottom);
        while (placeholders.next()) |p| {
            const image = storage.imageById(p.image_id) orelse continue;
            const placement = p.renderPlacement(storage, &image, term.width_px / term.cols, term.height_px / term.rows) catch continue;
            try self.append(allocator, term, top_y, image, p.placement_id, -1, placement);
        }
    }
    std.mem.sortUnstable(Placement, self.placements.items, {}, struct {
        fn lessThan(_: void, a: Placement, b: Placement) bool {
            if (a.z != b.z) return a.z < b.z;
            if (a.image_id != b.image_id) return a.image_id < b.image_id;
            return a.placement_id < b.placement_id;
        }
    }.lessThan);
}

fn append(self: *KittyImages, allocator: std.mem.Allocator, term: *vt.Terminal, top_y: u32, image: vt.kitty.graphics.Image, placement_id: u32, z: i32, p: vt.kitty.graphics.RenderPlacement) !void {
    if (image.data.isPending() or p.dest_width == 0 or p.dest_height == 0) return;
    const crop = geometry.sourceCrop(image.width, image.height, p.source_x, p.source_y, p.source_width, p.source_height) orelse return;
    const point = term.screens.active.pages.pointFromPin(.screen, p.top_left) orelse return;
    const x = @as(f64, @floatFromInt(p.top_left.x)) * @as(f64, @floatFromInt(term.width_px / term.cols)) + @as(f64, @floatFromInt(p.offset_x));
    const y = @as(f64, @floatFromInt(geometry.relativeRow(point.screen.y, top_y))) *
        @as(f64, @floatFromInt(term.height_px / term.rows)) + @as(f64, @floatFromInt(p.offset_y));
    if (x >= @as(f64, @floatFromInt(term.width_px)) or y >= @as(f64, @floatFromInt(term.height_px)) or
        x + @as(f64, @floatFromInt(p.dest_width)) <= 0 or y + @as(f64, @floatFromInt(p.dest_height)) <= 0) return;
    if (!self.images.contains(image.id)) {
        const rgba = try @import("../renderer/image_pixels.zig").toRgba(allocator, image);
        defer allocator.free(rgba);
        const native = try graphics.Image.createRgba(rgba, image.width, image.height);
        errdefer native.release();
        try self.images.put(allocator, image.id, .{ .image = native, .generation = image.generation, .width = image.width, .height = image.height });
    }
    try self.placements.append(allocator, .{
        .image_id = image.id,
        .placement_id = placement_id,
        .z = z,
        .x = x,
        .y = y,
        .width = p.dest_width,
        .height = p.dest_height,
        .source_x = crop.x,
        .source_y = crop.y,
        .source_width = crop.width,
        .source_height = crop.height,
    });
}

pub fn draw(self: *const KittyImages, context: *graphics.BitmapContext, layer: Layer, viewport: graphics.Rect, pixel_height: u32) void {
    const ctx = graphics.Context;
    ctx.save(context);
    defer ctx.restore(context);
    ctx.clipToRect(context, viewport);
    for (self.placements.items) |p| {
        if (Layer.forZ(p.z) != layer) continue;
        const entry = self.images.get(p.image_id) orelse continue;
        const sx = @as(f64, @floatFromInt(p.width)) / @as(f64, @floatFromInt(p.source_width));
        const sy = @as(f64, @floatFromInt(p.height)) / @as(f64, @floatFromInt(p.source_height));
        const image_width = @as(f64, @floatFromInt(entry.width)) * sx;
        const image_height = @as(f64, @floatFromInt(entry.height)) * sy;
        const top = @as(f64, @floatFromInt(pixel_height)) - p.y;
        ctx.save(context);
        defer ctx.restore(context);
        ctx.clipToRect(context, graphics.Rect.init(p.x, top - @as(f64, @floatFromInt(p.height)), p.width, p.height));
        // Clip the destination, then draw the scaled full image so source crops
        // remain exact without allocating a new CGImage for each placement.
        ctx.drawImage(context, graphics.Rect.init(p.x - @as(f64, @floatFromInt(p.source_x)) * sx, top + @as(f64, @floatFromInt(p.source_y)) * sy - image_height, image_width, image_height), entry.image);
    }
}
