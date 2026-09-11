const MetalBackend = @This();

const builtin = @import("builtin");
const macos = @import("apple.zig");
const objc = @import("objc.zig");

comptime {
    if (builtin.os.tag != .macos) @compileError("MetalBackend is macOS-only");
}

extern "c" fn MTLCreateSystemDefaultDevice() ?*anyopaque;

const PixelFormat = enum(c_ulong) {
    bgra8unorm = 80,
};

const LoadAction = enum(c_ulong) {
    clear = 2,
};

const StoreAction = enum(c_ulong) {
    store = 1,
};

const PrimitiveType = enum(c_ulong) {
    triangle_strip = 4,
};

const Region = extern struct {
    origin: Origin,
    size: Size,
};

const Origin = extern struct {
    x: c_ulong,
    y: c_ulong,
    z: c_ulong,
};

const Size = extern struct {
    width: c_ulong,
    height: c_ulong,
    depth: c_ulong,
};

const ClearColor = extern struct {
    red: f64,
    green: f64,
    blue: f64,
    alpha: f64,
};

const shader_source =
    \\#include <metal_stdlib>
    \\using namespace metal;
    \\struct VertexOut {
    \\    float4 position [[position]];
    \\    float2 uv;
    \\};
    \\vertex VertexOut vertexMain(uint id [[vertex_id]]) {
    \\    constexpr float2 positions[4] = {
    \\        float2(-1.0, -1.0), float2(1.0, -1.0),
    \\        float2(-1.0, 1.0), float2(1.0, 1.0)
    \\    };
    \\    constexpr float2 texcoords[4] = {
    \\        float2(0.0, 0.0), float2(1.0, 0.0),
    \\        float2(0.0, 1.0), float2(1.0, 1.0)
    \\    };
    \\    VertexOut out;
    \\    out.position = float4(positions[id], 0.0, 1.0);
    \\    out.uv = texcoords[id];
    \\    return out;
    \\}
    \\fragment float4 fragmentMain(VertexOut in [[stage_in]],
    \\                             texture2d<float> source [[texture(0)]],
    \\                             sampler source_sampler [[sampler(0)]]) {
    \\    // The CPU bitmap comes from a bottom-left-origin CoreGraphics context,
    \\    // but Metal samples with a top-left origin, so flip vertically here to
    \\    // present the terminal right-side up.
    \\    return source.sample(source_sampler, float2(in.uv.x, 1.0 - in.uv.y));
    \\}
;

device: objc.Object,
queue: objc.Object,
library: objc.Object,
pipeline: objc.Object,
sampler: objc.Object,
source: ?objc.Object = null,
target: ?objc.Object = null,
width: u32 = 0,
height: u32 = 0,

pub fn init() !MetalBackend {
    const device_id = MTLCreateSystemDefaultDevice() orelse return error.MetalUnavailable;
    const device = objc.Object.fromId(device_id);
    errdefer device.release();

    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer queue.release();

    const source_string = try macos.foundation.String.createWithBytes(shader_source, .utf8, false);
    defer source_string.release();
    var shader_error: ?*anyopaque = null;
    const library_id = device.msgSend(
        ?*anyopaque,
        objc.sel("newLibraryWithSource:options:error:"),
        .{ source_string, @as(?*anyopaque, null), &shader_error },
    ) orelse return error.MetalShaderCompilationFailed;
    if (shader_error != null) return error.MetalShaderCompilationFailed;
    const library = objc.Object.fromId(library_id);
    errdefer library.release();

    const pipeline = try createPipeline(device, library);
    errdefer pipeline.release();
    const sampler = try createSampler(device);
    errdefer sampler.release();

    return .{
        .device = device,
        .queue = queue,
        .library = library,
        .pipeline = pipeline,
        .sampler = sampler,
    };
}

pub fn deinit(self: *MetalBackend) void {
    if (self.source) |resource| resource.release();
    if (self.target) |resource| resource.release();
    self.sampler.release();
    self.pipeline.release();
    self.library.release();
    self.queue.release();
    self.device.release();
    self.* = undefined;
}

pub fn resize(self: *MetalBackend, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.InvalidDrawableSize;
    if (self.width == width and self.height == height) return;

    const source = try createTexture(self.device, width, height, 1);
    errdefer source.release();
    const target = try createTexture(self.device, width, height, 4 | 1);
    errdefer target.release();

    if (self.source) |old| old.release();
    if (self.target) |old| old.release();
    self.source = source;
    self.target = target;
    self.width = width;
    self.height = height;
}

pub fn render(self: *MetalBackend, pixels: []const u8) !void {
    const source = self.source orelse return error.DrawableNotConfigured;
    const target = self.target orelse return error.DrawableNotConfigured;
    const expected = try stdMathMul(@as(usize, self.width), @as(usize, self.height), 4);
    if (pixels.len != expected) return error.InvalidPixelBuffer;

    source.msgSend(
        void,
        objc.sel("replaceRegion:mipmapLevel:withBytes:bytesPerRow:"),
        .{
            Region{
                .origin = .{ .x = 0, .y = 0, .z = 0 },
                .size = .{ .width = self.width, .height = self.height, .depth = 1 },
            },
            @as(c_ulong, 0),
            @as(*const anyopaque, @ptrCast(pixels.ptr)),
            @as(c_ulong, self.width * 4),
        },
    );

    const command_buffer = self.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    const descriptor_class = objc.getClass("MTLRenderPassDescriptor") orelse return error.MetalUnavailable;
    const descriptor = descriptor_class.msgSend(objc.Object, objc.sel("renderPassDescriptor"), .{});
    const attachments = objc.Object.fromId(descriptor.getProperty(?*anyopaque, "colorAttachments").?);
    const attachment = attachments.msgSend(
        objc.Object,
        objc.sel("objectAtIndexedSubscript:"),
        .{@as(c_ulong, 0)},
    );
    attachment.setProperty("loadAction", @intFromEnum(LoadAction.clear));
    attachment.setProperty("storeAction", @intFromEnum(StoreAction.store));
    attachment.setProperty("texture", target.value);
    attachment.setProperty("clearColor", ClearColor{ .red = 0, .green = 0, .blue = 0, .alpha = 1 });

    const encoder = command_buffer.msgSend(
        objc.Object,
        objc.sel("renderCommandEncoderWithDescriptor:"),
        .{descriptor.value},
    );
    encoder.msgSend(void, objc.sel("setRenderPipelineState:"), .{self.pipeline.value});
    encoder.msgSend(
        void,
        objc.sel("setFragmentTexture:atIndex:"),
        .{ source.value, @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("setFragmentSamplerState:atIndex:"),
        .{ self.sampler.value, @as(c_ulong, 0) },
    );
    encoder.msgSend(
        void,
        objc.sel("drawPrimitives:vertexStart:vertexCount:"),
        .{ @intFromEnum(PrimitiveType.triangle_strip), @as(c_ulong, 0), @as(c_ulong, 4) },
    );
    encoder.msgSend(void, objc.sel("endEncoding"), .{});
    command_buffer.msgSend(void, objc.sel("commit"), .{});
    command_buffer.msgSend(void, objc.sel("waitUntilCompleted"), .{});
    if (command_buffer.getProperty(c_ulong, "status") == 5) return error.MetalCommandFailed;
}

pub fn texture(self: *const MetalBackend) ?*anyopaque {
    return if (self.target) |target| target.value else null;
}

fn createPipeline(device: objc.Object, library: objc.Object) !objc.Object {
    const vertex_name = try macos.foundation.String.createWithBytes("vertexMain", .utf8, false);
    defer vertex_name.release();
    const fragment_name = try macos.foundation.String.createWithBytes("fragmentMain", .utf8, false);
    defer fragment_name.release();
    const vertex_id = library.msgSend(
        ?*anyopaque,
        objc.sel("newFunctionWithName:"),
        .{vertex_name},
    ) orelse return error.MetalShaderFunctionMissing;
    const vertex = objc.Object.fromId(vertex_id);
    defer vertex.release();
    const fragment_id = library.msgSend(
        ?*anyopaque,
        objc.sel("newFunctionWithName:"),
        .{fragment_name},
    ) orelse return error.MetalShaderFunctionMissing;
    const fragment = objc.Object.fromId(fragment_id);
    defer fragment.release();

    const descriptor_class = objc.getClass("MTLRenderPipelineDescriptor") orelse return error.MetalUnavailable;
    const descriptor = descriptor_class.msgSend(objc.Object, objc.sel("alloc"), .{})
        .msgSend(objc.Object, objc.sel("init"), .{});
    defer descriptor.release();
    descriptor.setProperty("vertexFunction", vertex);
    descriptor.setProperty("fragmentFunction", fragment);
    const attachments = objc.Object.fromId(descriptor.getProperty(?*anyopaque, "colorAttachments").?);
    const attachment = attachments.msgSend(
        objc.Object,
        objc.sel("objectAtIndexedSubscript:"),
        .{@as(c_ulong, 0)},
    );
    attachment.setProperty("pixelFormat", @intFromEnum(PixelFormat.bgra8unorm));

    var pipeline_error: ?*anyopaque = null;
    const pipeline_id = device.msgSend(
        ?*anyopaque,
        objc.sel("newRenderPipelineStateWithDescriptor:error:"),
        .{ descriptor, &pipeline_error },
    ) orelse return error.MetalPipelineCreationFailed;
    if (pipeline_error != null) return error.MetalPipelineCreationFailed;
    return objc.Object.fromId(pipeline_id);
}

fn createSampler(device: objc.Object) !objc.Object {
    const descriptor_class = objc.getClass("MTLSamplerDescriptor") orelse return error.MetalUnavailable;
    const descriptor = descriptor_class.msgSend(objc.Object, objc.sel("alloc"), .{})
        .msgSend(objc.Object, objc.sel("init"), .{});
    defer descriptor.release();
    descriptor.setProperty("minFilter", @as(c_ulong, 0));
    descriptor.setProperty("magFilter", @as(c_ulong, 0));
    const sampler_id = device.msgSend(
        ?*anyopaque,
        objc.sel("newSamplerStateWithDescriptor:"),
        .{descriptor},
    ) orelse return error.MetalSamplerCreationFailed;
    return objc.Object.fromId(sampler_id);
}

fn createTexture(device: objc.Object, width: u32, height: u32, usage: c_ulong) !objc.Object {
    const descriptor_class = objc.getClass("MTLTextureDescriptor") orelse return error.MetalUnavailable;
    const descriptor = descriptor_class.msgSend(objc.Object, objc.sel("alloc"), .{})
        .msgSend(objc.Object, objc.sel("init"), .{});
    defer descriptor.release();
    descriptor.setProperty("pixelFormat", @intFromEnum(PixelFormat.bgra8unorm));
    descriptor.setProperty("width", @as(c_ulong, width));
    descriptor.setProperty("height", @as(c_ulong, height));
    descriptor.setProperty("usage", usage);
    descriptor.setProperty("resourceOptions", @as(c_ulong, 0));
    const texture_id = device.msgSend(
        ?*anyopaque,
        objc.sel("newTextureWithDescriptor:"),
        .{descriptor},
    ) orelse return error.MetalTextureCreationFailed;
    return objc.Object.fromId(texture_id);
}

fn stdMathMul(a: usize, b: usize, c: usize) !usize {
    const ab = @import("std").math.mul(usize, a, b) catch return error.InvalidDrawableSize;
    return @import("std").math.mul(usize, ab, c) catch return error.InvalidDrawableSize;
}
