const std = @import("std");
const win32 = @import("win32").everything;

threadlocal var thread_is_panicking = false;

pub fn panicHandler(msg: []const u8, ret_addr: ?usize) noreturn {
    if (!thread_is_panicking) {
        thread_is_panicking = true;
        crashMessageBox(msg, ret_addr orelse @returnAddress());
    }
    std.debug.defaultPanic(msg, ret_addr);
}

fn crashMessageBox(msg: []const u8, ret_addr: usize) void {
    var arena_instance: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    // don't free, we're about to crash
    const arena = arena_instance.allocator();
    var allocating: std.Io.Writer.Allocating = .init(arena);
    const write_result = writeCrash(&allocating.writer, msg, ret_addr);
    const final_msg: [*:0]const u8 = blk: {
        write_result catch {
            const marker = "[TRUNCATED]";
            const buf = allocating.writer.buffer;
            if (buf.len <= marker.len) break :blk "failed to allocate memory for error";
            const max_start = buf.len - marker.len - 1;
            const start = @min(allocating.writer.end, max_start);
            @memcpy(buf[start..][0..marker.len], marker);
            buf[start + marker.len] = 0;
        };
        break :blk @ptrCast(allocating.writer.buffer.ptr);
    };
    _ = win32.MessageBoxA(null, final_msg, "Mostty Crashed", .{ .ICONHAND = 1 });
}

fn writeCrash(writer: *std.Io.Writer, msg: []const u8, ret_addr: usize) error{WriteFailed}!void {
    try writer.print("{s}\n\n", .{msg});
    try std.debug.dumpCurrentStackTraceToWriter(ret_addr, writer);
    try writer.writeByte(0);
}
