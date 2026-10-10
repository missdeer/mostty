//! Ordered input transport. The UI only copies/enqueues; the worker owns I/O.
const std = @import("std");
const Queue = @This();

const Node = struct { next: ?*Node = null, bytes: []u8 };
pub const max_bytes = 64 * 1024 * 1024;
allocator: std.mem.Allocator,
io: std.Io,
mutex: std.Io.Mutex = .init,
ready: std.Io.Condition = .init,
head: ?*Node = null,
tail: ?*Node = null,
pending: usize = 0,
stopped: std.atomic.Value(bool) = .init(false),
failed: std.atomic.Value(bool) = .init(false),
context: *anyopaque,
write: *const fn (*anyopaque, []const u8, *const std.atomic.Value(bool)) anyerror!usize,
thread: ?std.Thread = null,

pub fn start(self: *Queue) !void {
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn enqueue(self: *Queue, bytes: []const u8) !void {
    if (bytes.len == 0) return;
    if (bytes.len > max_bytes) return error.InputQueueFull;
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    node.* = .{ .bytes = try self.allocator.dupe(u8, bytes) };
    errdefer self.allocator.free(node.bytes);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    if (self.stopped.load(.acquire)) return error.SessionClosed;
    if (self.failed.load(.acquire)) return error.PtyWriteFailed;
    if (bytes.len > max_bytes - self.pending) return error.InputQueueFull;
    if (self.tail) |tail| tail.next = node else self.head = node;
    self.tail = node;
    self.pending += bytes.len;
    self.ready.signal(self.io);
}

pub fn stop(self: *Queue) void {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    self.stopped.store(true, .release);
    self.ready.signal(self.io);
}

// The host must first interrupt a blocking transport, or use cancellable
// nonblocking I/O. Never close/reuse its handle until after this join.
pub fn deinit(self: *Queue) void {
    self.stop();
    if (self.thread) |thread| thread.join();
    while (self.head) |node| {
        self.head = node.next;
        self.allocator.free(node.bytes);
        self.allocator.destroy(node);
    }
}

fn run(self: *Queue) void {
    while (true) {
        self.mutex.lockUncancelable(self.io);
        while (self.head == null and !self.stopped.load(.acquire)) self.ready.waitUncancelable(self.io, &self.mutex);
        if (self.stopped.load(.acquire)) {
            self.mutex.unlock(self.io);
            return;
        }
        const node = self.head.?;
        self.head = node.next;
        if (self.head == null) self.tail = null;
        self.mutex.unlock(self.io);
        var offset: usize = 0;
        while (offset < node.bytes.len and !self.stopped.load(.acquire)) {
            const n = self.write(self.context, node.bytes[offset..], &self.stopped) catch {
                self.failed.store(true, .release);
                break;
            };
            if (n == 0 or n > node.bytes.len - offset) {
                self.failed.store(true, .release);
                break;
            }
            offset += n;
        }
        self.mutex.lockUncancelable(self.io);
        self.pending -= node.bytes.len;
        self.mutex.unlock(self.io);
        self.allocator.free(node.bytes);
        self.allocator.destroy(node);
        if (self.failed.load(.acquire)) return;
    }
}

test "queued input survives partial writes in order without blocking producer" {
    const Sink = struct {
        gate: std.atomic.Value(bool) = .init(false),
        entered: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        bytes: [12]u8 = undefined,
        len: usize = 0,
        fn write(context: *anyopaque, bytes: []const u8, stop_flag: *const std.atomic.Value(bool)) !usize {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.entered.store(true, .release);
            while (!self.gate.load(.acquire)) {
                if (stop_flag.load(.acquire)) return error.Canceled;
                std.Thread.yield() catch {};
            }
            const n = @min(2, bytes.len);
            @memcpy(self.bytes[self.len..][0..n], bytes[0..n]);
            self.len += n;
            if (self.len == self.bytes.len) self.done.store(true, .release);
            return n;
        }
    };
    var sink: Sink = .{};
    var queue: Queue = .{ .allocator = std.testing.allocator, .io = std.testing.io, .context = &sink, .write = Sink.write };
    try queue.start();
    defer queue.deinit();
    try queue.enqueue("begin");
    while (!sink.entered.load(.acquire)) std.Thread.yield() catch {};
    // The consumer is stalled inside the transport, yet both calls complete.
    try queue.enqueue("text");
    try queue.enqueue("end");
    sink.gate.store(true, .release);
    while (!sink.done.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectEqualStrings("begintextend", &sink.bytes);
}

test "stopping a backpressured queue cancels it and rejects later input" {
    const Sink = struct {
        fn write(_: *anyopaque, _: []const u8, stop_flag: *const std.atomic.Value(bool)) !usize {
            while (!stop_flag.load(.acquire)) std.Thread.yield() catch {};
            return error.Canceled;
        }
    };
    var context: u8 = 0;
    var queue: Queue = .{ .allocator = std.testing.allocator, .io = std.testing.io, .context = &context, .write = Sink.write };
    try queue.start();
    defer queue.deinit();
    try queue.enqueue("pending input");
    queue.stop();
    try std.testing.expectError(error.SessionClosed, queue.enqueue("late input"));
}
