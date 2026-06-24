const std = @import("std");
const win32 = @import("win32").everything;

var enabled: bool = false;
var file: ?std.fs.File = null;
var mutex: std.Thread.Mutex = .{};
var qpc_freq_hz: u64 = 0;

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
    var c: win32.LARGE_INTEGER = undefined;
    _ = win32.QueryPerformanceCounter(&c);
    return @bitCast(c.QuadPart);
}

pub fn qpcUsSince(prev: u64) u64 {
    if (qpc_freq_hz == 0) {
        var f: win32.LARGE_INTEGER = undefined;
        _ = win32.QueryPerformanceFrequency(&f);
        qpc_freq_hz = @bitCast(f.QuadPart);
    }
    const now = qpcNow();
    if (now <= prev or qpc_freq_hz == 0) return 0;
    return (now - prev) * 1_000_000 / qpc_freq_hz;
}
