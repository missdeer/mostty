//! Bounded ownership for wallpaper decoding: one active, newest pending,
//! and one UI-ready result. The platform adapter supplies synchronous decode
//! and non-reentrant, asynchronous notification; no result pointer is posted.
const std = @import("std");

pub const Decoded = struct { pixels: []u8, w: u32, h: u32 };
pub const Result = struct {
    req_id: u32,
    path: []u8,
    pixels: ?[]u8 = null,
    w: u32 = 0,
    h: u32 = 0,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        if (self.pixels) |pixels| allocator.free(pixels);
        allocator.free(self.path);
        allocator.destroy(self);
    }
};

pub const Guard = struct {
    context: *anyopaque,
    current: *const fn (*anyopaque) bool,
    pub fn valid(self: Guard) bool {
        return self.current(self.context);
    }
};

pub const Stats = struct {
    active: u32,
    queued: u32,
    ready: u32,
    coalesced: u64,
    decoded: u64,
    ready_pixel_bytes: usize,
    peak_decoded_buffer_bytes: usize,
};

pub const Worker = struct {
    allocator: std.mem.Allocator,
    notify_context: *anyopaque,
    notify: *const fn (*anyopaque) bool,
    decode: *const fn (std.mem.Allocator, []const u8, Guard) ?Decoded,
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    thread: ?std.Thread = null,
    stopping: bool = false,
    generation: u32 = 0,
    pending: ?*Result = null,
    ready: ?*Result = null,
    notified: bool = false,
    active: bool = false,
    coalesced: u64 = 0,
    decoded: u64 = 0,
    peak_decoded_buffer_bytes: usize = 0,
    failed_generation: ?u32 = null,

    pub fn start(self: *Worker) !void {
        std.debug.assert(self.thread == null and !self.stopping);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Takes ownership only on success. UI thread only.
    pub fn request(self: *Worker, result: *Result) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        if (self.stopping) return false;
        self.cancelLocked(result.req_id);
        self.pending = result;
        self.cond.signal(io);
        return true;
    }

    pub fn cancel(self: *Worker, generation: u32) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.cancelLocked(generation);
    }

    fn cancelLocked(self: *Worker, generation: u32) void {
        self.generation = generation;
        self.failed_generation = null;
        if (self.pending) |result| {
            self.coalesced += 1;
            result.deinit(self.allocator);
            self.pending = null;
        }
        if (self.ready) |result| {
            self.coalesced += 1;
            result.deinit(self.allocator);
            self.ready = null;
        }
        // An already queued notification may consume a newer ready result.
        // Keep its flag so reload storms cannot fill the UI message queue.
    }

    pub fn take(self: *Worker) ?*Result {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.notified = false;
        const result = self.ready;
        self.ready = null;
        return result;
    }

    pub fn retryNeeded(self: *Worker, generation: u32) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.failed_generation == generation;
    }

    pub fn stats(self: *Worker) Stats {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .active = @intFromBool(self.active),
            .queued = @intFromBool(self.pending != null),
            .ready = @intFromBool(self.ready != null),
            .coalesced = self.coalesced,
            .decoded = self.decoded,
            .ready_pixel_bytes = if (self.ready) |result| if (result.pixels) |pixels| pixels.len else 0 else 0,
            .peak_decoded_buffer_bytes = self.peak_decoded_buffer_bytes,
        };
    }

    fn stopAndDiscard(self: *Worker) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        self.stopping = true;
        self.cancelLocked(self.generation +% 1);
        self.notified = false;
        self.mutex.unlock(io);
        self.cond.signal(io);
    }

    pub fn shutdown(self: *Worker) void {
        self.stopAndDiscard();
        if (self.thread) |thread| thread.join();
        self.thread = null;
    }

    const Check = struct {
        worker: *Worker,
        generation: u32,
        fn current(context: *anyopaque) bool {
            const self: *const Check = @ptrCast(@alignCast(context));
            const io = std.Io.Threaded.global_single_threaded.io();
            self.worker.mutex.lockUncancelable(io);
            defer self.worker.mutex.unlock(io);
            return !self.worker.stopping and self.worker.generation == self.generation;
        }
    };

    fn run(self: *Worker) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (true) {
            self.mutex.lockUncancelable(io);
            while (!self.stopping and self.pending == null) self.cond.waitUncancelable(io, &self.mutex);
            if (self.stopping) {
                self.mutex.unlock(io);
                return;
            }
            const result = self.pending.?;
            self.pending = null;
            self.active = true;
            self.mutex.unlock(io);

            var check: Check = .{ .worker = self, .generation = result.req_id };
            const guard: Guard = .{ .context = &check, .current = Check.current };
            if (guard.valid()) {
                if (self.decode(self.allocator, result.path, guard)) |decoded| {
                    result.pixels = decoded.pixels;
                    result.w = decoded.w;
                    result.h = decoded.h;
                }
            }

            self.mutex.lockUncancelable(io);
            self.active = false;
            if (result.pixels) |pixels| {
                self.decoded += 1;
                self.peak_decoded_buffer_bytes = @max(self.peak_decoded_buffer_bytes, pixels.len);
            }
            if (self.stopping or result.req_id != self.generation) {
                self.coalesced += 1;
                result.deinit(self.allocator);
            } else {
                std.debug.assert(self.ready == null);
                self.ready = result;
                if (!self.notified) {
                    self.notified = true;
                    if (!self.notify(self.notify_context)) {
                        self.notified = false;
                        self.ready = null;
                        self.failed_generation = result.req_id;
                        result.deinit(self.allocator);
                    }
                }
            }
            self.mutex.unlock(io);
        }
    }
};

fn testResult(id: u32, path: []const u8) !*Result {
    const result = try std.testing.allocator.create(Result);
    errdefer std.testing.allocator.destroy(result);
    result.* = .{ .req_id = id, .path = try std.testing.allocator.dupe(u8, path) };
    return result;
}

fn testWait(semaphore: *std.Io.Semaphore) !void {
    try semaphore.waitTimeout(std.Io.Threaded.global_single_threaded.io(), .{
        .duration = .{ .raw = .fromSeconds(10), .clock = .awake },
    });
}

test "wallpaper storms retain only the newest pending request and close joins the active decode" {
    const Harness = struct {
        var started: std.Io.Semaphore = .{};
        var proceed: std.Io.Semaphore = .{};
        var posted: std.Io.Semaphore = .{};
        fn decode(allocator: std.mem.Allocator, _: []const u8, _: Guard) ?Decoded {
            const io = std.Io.Threaded.global_single_threaded.io();
            started.post(io);
            proceed.waitUncancelable(io);
            return .{ .pixels = allocator.dupe(u8, &.{ 1, 2, 3, 255 }) catch return null, .w = 1, .h = 1 };
        }
        fn notify(_: *anyopaque) bool {
            posted.post(std.Io.Threaded.global_single_threaded.io());
            return true;
        }
    };
    const io = std.Io.Threaded.global_single_threaded.io();
    var context: u8 = 0;
    var worker: Worker = .{ .allocator = std.testing.allocator, .notify_context = &context, .notify = Harness.notify, .decode = Harness.decode };
    try worker.start();
    defer {
        Harness.proceed.post(io);
        worker.shutdown();
    }
    try std.testing.expect(worker.request(try testResult(1, "first")));
    try testWait(&Harness.started);
    for (2..101) |id| try std.testing.expect(worker.request(try testResult(@intCast(id), "latest")));
    var stats = worker.stats();
    try std.testing.expectEqual(@as(u32, 1), stats.active);
    try std.testing.expectEqual(@as(u32, 1), stats.queued);
    try std.testing.expectEqual(@as(u64, 98), stats.coalesced);
    Harness.proceed.post(io);
    try testWait(&Harness.started);
    Harness.proceed.post(io);
    try testWait(&Harness.posted);
    const latest = worker.take().?;
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 100), latest.req_id);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 255 }, latest.pixels.?);
    try std.testing.expect(worker.take() == null);
    try std.testing.expect(worker.request(try testResult(101, "closing")));
    try testWait(&Harness.started);
    try std.testing.expect(worker.request(try testResult(102, "cancelled")));
    worker.stopAndDiscard();
    Harness.proceed.post(io);
    worker.shutdown();
    stats = worker.stats();
    try std.testing.expectEqual(@as(u32, 0), stats.active + stats.queued + stats.ready);
    try std.testing.expectEqual(@as(usize, 4), stats.peak_decoded_buffer_bytes);
}

test "notification failure frees pixels and permits a same-path retry" {
    const Harness = struct {
        var posted: std.Io.Semaphore = .{};
        fn decode(allocator: std.mem.Allocator, _: []const u8, guard: Guard) ?Decoded {
            if (!guard.valid()) return null;
            return .{ .pixels = allocator.dupe(u8, &.{ 1, 2, 3, 4 }) catch return null, .w = 1, .h = 1 };
        }
        fn notify(_: *anyopaque) bool {
            posted.post(std.Io.Threaded.global_single_threaded.io());
            return false;
        }
    };
    var context: u8 = 0;
    var worker: Worker = .{ .allocator = std.testing.allocator, .notify_context = &context, .notify = Harness.notify, .decode = Harness.decode };
    try worker.start();
    defer worker.shutdown();
    try std.testing.expect(worker.request(try testResult(1, "same")));
    try testWait(&Harness.posted);
    try std.testing.expect(worker.retryNeeded(1));
    try std.testing.expectEqual(@as(u32, 0), worker.stats().ready);
    try std.testing.expect(worker.request(try testResult(2, "same")));
    try testWait(&Harness.posted);
    try std.testing.expect(worker.retryNeeded(2));
    worker.cancel(3);
    try std.testing.expect(!worker.retryNeeded(2));
}

fn testReady(worker: *Worker) !void {
    const io = std.Io.Threaded.global_single_threaded.io();
    const deadline = std.Io.Timestamp.now(io, .awake).nanoseconds + 10_000_000_000;
    while (worker.stats().ready == 0) {
        if (std.Io.Timestamp.now(io, .awake).nanoseconds >= deadline) return error.Timeout;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}

test "one queued notification delivers the newest result and clear cannot resurrect a ready image" {
    const Harness = struct {
        var notifications: std.atomic.Value(u32) = .init(0);
        fn decode(allocator: std.mem.Allocator, path: []const u8, guard: Guard) ?Decoded {
            if (!guard.valid() or path[0] == '!') return null;
            return .{ .pixels = allocator.dupe(u8, path[0..1]) catch return null, .w = 1, .h = 1 };
        }
        fn notify(_: *anyopaque) bool {
            _ = notifications.fetchAdd(1, .monotonic);
            return true;
        }
    };
    var context: u8 = 0;
    var worker: Worker = .{ .allocator = std.testing.allocator, .notify_context = &context, .notify = Harness.notify, .decode = Harness.decode };
    try worker.start();
    defer worker.shutdown();
    try std.testing.expect(worker.request(try testResult(1, "old")));
    try testReady(&worker);
    try std.testing.expect(worker.request(try testResult(2, "new")));
    try testReady(&worker);
    try std.testing.expectEqual(@as(u32, 1), Harness.notifications.load(.monotonic));
    const latest = worker.take().?;
    defer latest.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 2), latest.req_id);
    try std.testing.expectEqualSlices(u8, "n", latest.pixels.?);
    try std.testing.expect(worker.request(try testResult(3, "!failure")));
    try testReady(&worker);
    const failed = worker.take().?;
    defer failed.deinit(std.testing.allocator);
    try std.testing.expect(failed.pixels == null);
    try std.testing.expect(worker.request(try testResult(4, "clear")));
    try testReady(&worker);
    worker.cancel(5);
    try std.testing.expect(worker.take() == null);
    try std.testing.expectEqual(@as(usize, 0), worker.stats().ready_pixel_bytes);
}
