const Cmdline = @This();

font_path: ?[]const u8 = null,
font_size: f32 = 16.0,
renderer: RendererSelection = .from_config,
background_opacity: ?f32 = null,
background_blur: ?bool = null,

pub const RendererSelection = union(enum) {
    from_config,
    backend: Config.RendererBackend,
    invalid: []const u8,
};

pub fn usage() !void {
    try std.Io.File.stderr().writeStreamingAll(std.Io.Threaded.global_single_threaded.io(),
        \\Usage: Mostty [options]
        \\
        \\Font Options:
        \\  --ttf <path>              Use TrueType font at <path>
        \\  --font-size <float>       Font size (scaled by DPI, default: 16.0)
        \\
        \\Renderer Options:
        \\  --renderer <backend>      Renderer backend (d3d11, d3d12, opengl,
        \\                            pure-opengl, vulkan, or native-vulkan)
        \\  --background-opacity <n> Default background opacity in [0,1]
        \\  --background-blur <bool> Enable DWM blur behind (true or false)
        \\
    );
}

pub fn parse(args: *std.process.Args.Iterator) !Cmdline {
    var result: Cmdline = .{};
    _ = args.next(); // skip program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--ttf")) {
            result.font_path = args.next() orelse errExit("--ttf requires a path argument", .{});
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const size_str = args.next() orelse errExit("--font-size requires an argument", .{});
            result.font_size = std.fmt.parseFloat(f32, size_str) catch errExit(
                "invalid --font-size '{s}'",
                .{size_str},
            );
            if (result.font_size <= 0) errExit(
                "invalid --font-size  '{d}' (must be positive)",
                .{result.font_size},
            );
            std.log.info("--font-size {d}", .{result.font_size});
        } else if (std.mem.eql(u8, arg, "--renderer")) {
            const value = args.next() orelse errExit("--renderer requires an argument", .{});
            result.renderer = parseRenderer(value);
        } else if (std.mem.eql(u8, arg, "--background-opacity")) {
            const value = args.next() orelse errExit("--background-opacity requires an argument", .{});
            result.background_opacity = parseBackgroundOpacity(value) orelse errExit(
                "invalid --background-opacity '{s}' (expected a number in [0,1])",
                .{value},
            );
        } else if (std.mem.eql(u8, arg, "--background-blur")) {
            const value = args.next() orelse errExit("--background-blur requires an argument", .{});
            result.background_blur = parseBackgroundBlur(value) orelse errExit(
                "invalid --background-blur '{s}' (expected true or false)",
                .{value},
            );
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Cmdline.usage();
            std.process.exit(0);
        } else errExit("unknown cmdline option '{s}'", .{arg});
    }
    return result;
}

pub fn applyConfigOverrides(self: Cmdline, config: *Config) void {
    config.renderer = self.rendererOr(config.renderer);
    if (self.background_opacity) |value| config.background_opacity = value;
    if (self.background_blur) |value| config.background_blur = value;
}

pub fn rendererOr(self: Cmdline, configured: Config.RendererBackend) Config.RendererBackend {
    return switch (self.renderer) {
        .from_config => configured,
        .backend => |backend| backend,
        .invalid => unreachable,
    };
}

fn parseRenderer(value: []const u8) RendererSelection {
    const backend = std.meta.stringToEnum(Config.RendererBackend, value) orelse
        return .{ .invalid = value };
    return .{ .backend = backend };
}

fn parseBackgroundOpacity(value: []const u8) ?f32 {
    const opacity = std.fmt.parseFloat(f32, value) catch return null;
    if (!std.math.isFinite(opacity) or opacity < 0.0 or opacity > 1.0) return null;
    return opacity;
}

fn parseBackgroundBlur(value: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(value, "true")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    return null;
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

test "renderer accepts exactly the configured backend names" {
    inline for (std.meta.tags(Config.RendererBackend)) |backend| {
        try std.testing.expectEqual(backend, parseRenderer(@tagName(backend)).backend);
    }
    try std.testing.expectEqualStrings("D3D11", parseRenderer("D3D11").invalid);
    try std.testing.expectEqualStrings("native_vulkan", parseRenderer("native_vulkan").invalid);
}

test "renderer command-line value overrides config and omission preserves it" {
    const configured: Config.RendererBackend = .opengl;
    try std.testing.expectEqual(configured, (Cmdline{}).rendererOr(configured));
    try std.testing.expectEqual(Config.RendererBackend.vulkan, (Cmdline{ .renderer = .{ .backend = .vulkan } }).rendererOr(configured));
}

test "window effect command-line values are validated" {
    try std.testing.expectEqual(@as(f32, 0.0), parseBackgroundOpacity("0").?);
    try std.testing.expectEqual(@as(f32, 0.75), parseBackgroundOpacity("0.75").?);
    try std.testing.expectEqual(@as(f32, 1.0), parseBackgroundOpacity("1").?);
    try std.testing.expectEqual(@as(?f32, null), parseBackgroundOpacity("-0.1"));
    try std.testing.expectEqual(@as(?f32, null), parseBackgroundOpacity("1.1"));
    try std.testing.expectEqual(@as(?f32, null), parseBackgroundOpacity("nan"));

    try std.testing.expectEqual(true, parseBackgroundBlur("true").?);
    try std.testing.expectEqual(false, parseBackgroundBlur("FALSE").?);
    try std.testing.expectEqual(@as(?bool, null), parseBackgroundBlur("1"));
}

test "window effect command-line values override config and omission preserves it" {
    var configured: Config = .{};
    const original_opacity = configured.background_opacity;
    const original_blur = configured.background_blur;
    (Cmdline{}).applyConfigOverrides(&configured);
    try std.testing.expectEqual(original_opacity, configured.background_opacity);
    try std.testing.expectEqual(original_blur, configured.background_blur);

    (Cmdline{
        .background_opacity = 1.0,
        .background_blur = false,
    }).applyConfigOverrides(&configured);
    try std.testing.expectEqual(@as(f32, 1.0), configured.background_opacity);
    try std.testing.expect(!configured.background_blur);
}

const Config = @import("config.zig");
const builtin = @import("builtin");
const std = @import("std");
