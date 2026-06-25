const std = @import("std");
const win32 = @import("win32").everything;
const state = @import("state.zig");

var enabled: bool = false;
var file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};

pub fn isEnabled() bool {
    return enabled;
}

pub fn init() void {
    if (std.process.hasEnvVarConstant("MOSTTY_DIAG") == false) return;
    enabled = true;

    const path = "tmp\\mostty-diag.log";
    if (std.fs.path.dirname(path)) |dir| {
        std.fs.cwd().makePath(dir) catch return;
    }
    file = std.fs.cwd().createFile(path, .{ .truncate = true }) catch return;
    log(.info, .diag, "diag enabled: {s}", .{path});
}

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!enabled) return;
    const f = file orelse return;

    mutex.lock();
    defer mutex.unlock();

    const level_txt = comptime level.asText();
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(
        &buf,
        "[{}] " ++ level_txt ++ " " ++ prefix ++ format ++ "\n",
        .{win32.GetTickCount64()} ++ args,
    ) catch return;
    f.writeAll(line) catch return;
}

pub fn qpcNow() u64 {
    return state.qpcNow();
}

pub fn qpcUsSince(prev: u64) u64 {
    return state.qpcUsSince(prev);
}
