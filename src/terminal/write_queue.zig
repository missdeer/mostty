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
    // Reject known failures before allocating/copying a potentially large paste.
    // This is only a snapshot: concurrent producers still commit in lock order,
    // as before, and must recheck capacity/state after copying outside the lock.
    {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.checkEnqueue(bytes.len);
    }
    const node = try self.allocator.create(Node);
    errdefer self.allocator.destroy(node);
    node.* = .{ .bytes = try self.allocator.dupe(u8, bytes) };
    errdefer self.allocator.free(node.bytes);
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    try self.checkEnqueue(bytes.len);
    if (self.tail) |tail| tail.next = node else self.head = node;
    self.tail = node;
    self.pending += bytes.len;
    self.ready.signal(self.io);
}

// Caller holds mutex; pending includes the transaction currently being written.
fn checkEnqueue(self: *Queue, len: usize) !void {
    if (self.stopped.load(.acquire)) return error.SessionClosed;
    if (self.failed.load(.acquire)) return error.PtyWriteFailed;
    if (len > max_bytes - self.pending) return error.InputQueueFull;
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

test "allocation rejection is recoverable but transport failure remains latched" {
    const Sink = struct {
        fn write(_: *anyopaque, _: []const u8, _: *const std.atomic.Value(bool)) !usize {
            return error.BrokenPipe;
        }
    };
    var context: u8 = 0;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var queue: Queue = .{ .allocator = failing.allocator(), .io = std.testing.io, .context = &context, .write = Sink.write };
    defer queue.deinit();
    try std.testing.expectError(error.OutOfMemory, queue.enqueue("temporarily rejected"));
    try std.testing.expect(!queue.failed.load(.acquire));
    failing.fail_index = std.math.maxInt(usize);
    try queue.enqueue("accepted after allocation recovery");
    try queue.start();
    while (!queue.failed.load(.acquire)) std.Thread.yield() catch {};
    try std.testing.expectError(error.PtyWriteFailed, queue.enqueue("after broken pipe"));
}

fn testUnusedWrite(_: *anyopaque, _: []const u8, _: *const std.atomic.Value(bool)) !usize {
    unreachable;
}

test "known full stopped and failed queues reject without allocation or payload copy" {
    var context: u8 = 0;
    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var queue: Queue = .{ .allocator = counting.allocator(), .io = std.testing.io, .context = &context, .write = testUnusedWrite };
    defer queue.deinit();
    const payload = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(payload);
    @memset(payload, 'p');
    try queue.enqueue("already queued");
    const allocations = counting.alloc_index;
    const allocated_bytes = counting.allocated_bytes;
    const actual_pending = queue.pending;
    // Model capacity occupied by queued/in-flight transactions without a 64 MiB fixture.
    queue.pending = max_bytes - payload.len + 1;
    try std.testing.expectError(error.InputQueueFull, queue.enqueue(payload));
    queue.pending = actual_pending;
    queue.failed.store(true, .release);
    try std.testing.expectError(error.PtyWriteFailed, queue.enqueue(payload));
    queue.stop();
    try std.testing.expectError(error.SessionClosed, queue.enqueue(payload));
    // Empty input remains a no-op even on a closed queue.
    try queue.enqueue("");
    try std.testing.expectEqual(allocations, counting.alloc_index);
    try std.testing.expectEqual(allocated_bytes, counting.allocated_bytes);
    try std.testing.expectEqualStrings("already queued", queue.head.?.bytes);
    try std.testing.expectEqual(actual_pending, queue.pending);
}

test "node and payload OOM leave no partial paste or reserved capacity" {
    for (0..2) |fail_index| {
        var context: u8 = 0;
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var queue: Queue = .{ .allocator = failing.allocator(), .io = std.testing.io, .context = &context, .write = testUnusedWrite };
        defer queue.deinit();
        try std.testing.expectError(error.OutOfMemory, queue.enqueue("\x1b[200~complete paste\x1b[201~"));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), queue.pending);
        try std.testing.expect(queue.head == null and queue.tail == null);
        try std.testing.expect(!queue.failed.load(.acquire));
        failing.fail_index = std.math.maxInt(usize);
        try queue.enqueue("\x1b[200~complete paste\x1b[201~");
        try queue.enqueue("reply");
        try std.testing.expectEqualStrings("\x1b[200~complete paste\x1b[201~", queue.head.?.bytes);
        try std.testing.expectEqualStrings("reply", queue.head.?.next.?.bytes);
        try std.testing.expect(queue.tail.?.next == null);
    }
}

test "commit rechecks concurrent stop failure and capacity after unlocked allocation" {
    const BlockingAllocator = struct {
        backing: std.mem.Allocator,
        calls: usize = 0,
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.calls += 1;
            if (self.calls == 2) {
                self.entered.store(true, .release);
                while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            }
            return self.backing.rawAlloc(len, alignment, ra);
        }
        fn free(ctx: *anyopaque, bytes: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.backing.rawFree(bytes, alignment, ra);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .free = free, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap } };
        }
    };
    const Producer = struct {
        queue: *Queue,
        result: ?anyerror = null,
        fn run(self: *@This()) void {
            self.queue.enqueue("whole paste") catch |err| {
                self.result = err;
            };
        }
    };
    for ([_]anyerror{ error.SessionClosed, error.PtyWriteFailed, error.InputQueueFull }) |expected| {
        var context: u8 = 0;
        var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var blocking: BlockingAllocator = .{ .backing = counting.allocator() };
        var queue: Queue = .{ .allocator = blocking.allocator(), .io = std.testing.io, .context = &context, .write = testUnusedWrite };
        defer queue.deinit();
        var producer: Producer = .{ .queue = &queue };
        const thread = try std.Thread.spawn(.{}, Producer.run, .{&producer});
        while (!blocking.entered.load(.acquire)) std.Thread.yield() catch {};
        // These operations must complete while the producer's allocation is stalled.
        queue.mutex.lockUncancelable(queue.io);
        switch (expected) {
            error.SessionClosed => queue.stopped.store(true, .release),
            error.PtyWriteFailed => queue.failed.store(true, .release),
            error.InputQueueFull => queue.pending = max_bytes,
            else => unreachable,
        }
        queue.mutex.unlock(queue.io);
        blocking.release.store(true, .release);
        thread.join();
        try std.testing.expectEqual(expected, producer.result.?);
        try std.testing.expect(queue.head == null and queue.tail == null);
        try std.testing.expectEqual(counting.allocated_bytes, counting.freed_bytes);
        try std.testing.expectEqual(@as(usize, if (expected == error.InputQueueFull) max_bytes else 0), queue.pending);
    }
}

test "concurrent producers preserve each producer order and whole transactions" {
    const Producer = struct {
        queue: *Queue,
        id: u8,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            for (0..32) |sequence| {
                const transaction = [_]u8{ self.id, @intCast(sequence), self.id, @intCast(sequence) };
                self.queue.enqueue(&transaction) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var context: u8 = 0;
    var queue: Queue = .{ .allocator = std.testing.allocator, .io = std.testing.io, .context = &context, .write = testUnusedWrite };
    defer queue.deinit();
    var a: Producer = .{ .queue = &queue, .id = 0 };
    var b: Producer = .{ .queue = &queue, .id = 1 };
    const first = try std.Thread.spawn(.{}, Producer.run, .{&a});
    const second = std.Thread.spawn(.{}, Producer.run, .{&b}) catch |err| {
        first.join();
        return err;
    };
    first.join();
    second.join();
    try std.testing.expect(a.failure == null and b.failure == null);
    var counts = [_]u8{ 0, 0 };
    var node = queue.head;
    while (node) |current| : (node = current.next) {
        try std.testing.expectEqual(@as(usize, 4), current.bytes.len);
        const id = current.bytes[0];
        try std.testing.expect(id < counts.len);
        try std.testing.expectEqualSlices(u8, &.{ id, counts[id], id, counts[id] }, current.bytes);
        counts[id] += 1;
    }
    try std.testing.expectEqualSlices(u8, &.{ 32, 32 }, &counts);
    try std.testing.expectEqual(@as(usize, 64 * 4), queue.pending);
}
