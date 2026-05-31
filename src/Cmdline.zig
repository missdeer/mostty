const Cmdline = @This();

font_path: ?[]const u8 = null,
font_size: f32 = 16.0,

pub fn usage() !void {
    try std.fs.File.stderr().writeAll(
        \\Usage: Mostty [options]
        \\
        \\Font Options:
        \\  --ttf <path>              Use TrueType font at <path>
        \\  --font-size <float>       Font size (scaled by DPI, default: 16.0)
        \\
    );
}

pub fn parse(args: *std.process.ArgIterator) !Cmdline {
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
        } else if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            try Cmdline.usage();
            std.process.exit(0);
        } else errExit("unknown cmdline option '{s}'", .{arg});
    }
    return result;
}

fn errExit(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const builtin = @import("builtin");
const std = @import("std");
