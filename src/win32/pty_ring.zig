const std = @import("std");
const win32 = @import("win32").everything;

// Per-tab SPSC byte ring between the PTY reader thread (producer) and the
// UI thread (consumer). Replaces the prior synchronous SendMessage hand-off
// so the reader is never gated by UI frame work. The reader copies bytes
// into the ring; the UI thread drains the whole ring per wake-up. Ring full
// blocks the reader on `wake_event` — bytes are never dropped (PTY streams
// are non-replayable).
//
// Notification is edge-triggered via the `posted` atomic bool: at most one
// WM_APP_CHILD_PROCESS_DATA is in flight per tab, set by the reader on the
// empty→non-empty transition and cleared by the UI handler before drain.

pub const RING_CAP: usize = 1 << 20; // 1 MiB ≈ 16 × 64 KB ReadFile bufs

comptime {
    // The wrap-mask in read/write paths assumes RING_CAP is a power of two.
    std.debug.assert(std.math.isPowerOfTwo(RING_CAP));
}

pub const PtyRing = struct {
    buf: []u8,
    // Monotonic unmasked counters. used = head - tail, free = cap - used.
    // Mask only when indexing buf. 64-bit usize never wraps in practice.
    head: std.atomic.Value(usize),
    tail: std.atomic.Value(usize),
    // Auto-reset event. UI thread signals after draining (so a full-ring
    // writer can resume); destroyTab signals to unblock the writer for
    // shutdown.
    wake_event: win32.HANDLE,
    // Edge-triggered wake-up guard. Reader does swap(true); if it returned
    // false, reader posts WM_APP_CHILD_PROCESS_DATA. UI handler clears to
    // false before drain so writes during drain re-arm a fresh post.
    posted: std.atomic.Value(bool),
    // Borrowed pointer to Tab.reader_stop. Re-checked at the top of every
    // write iteration and after waking from a full-ring wait.
    stop: *std.atomic.Value(bool),

    pub fn init(
        gpa: std.mem.Allocator,
        stop_flag: *std.atomic.Value(bool),
    ) error{ OutOfMemory, CreateEventFailed }!PtyRing {
        const buf = try gpa.alloc(u8, RING_CAP);
        errdefer gpa.free(buf);
        // bManualReset=FALSE → auto-reset; bInitialState=FALSE → not signaled.
        const evt = win32.CreateEventW(null, 0, 0, null) orelse return error.CreateEventFailed;
        return .{
            .buf = buf,
            .head = .init(0),
            .tail = .init(0),
            .wake_event = evt,
            .posted = .init(false),
            .stop = stop_flag,
        };
    }

    pub fn deinit(self: *PtyRing, gpa: std.mem.Allocator) void {
        win32.closeHandle(self.wake_event);
        gpa.free(self.buf);
        self.* = undefined;
    }

    // Producer (reader thread). Copies `data` into the ring, splitting at
    // wrap. Blocks on `wake_event` when the ring is full and re-checks
    // `stop` at every loop iteration. Returns false if `stop` was signaled
    // during a wait — caller should exit the reader loop.
    //
    // Memory ordering: head.store(.release) publishes the bytes; the
    // matching head.load(.acquire) in drain() synchronizes against this.
    pub fn write(self: *PtyRing, data: []const u8) bool {
        var rem = data;
        while (rem.len > 0) {
            if (self.stop.load(.acquire)) return false;
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const used = head - tail;
            std.debug.assert(used <= self.buf.len);
            const free_space = self.buf.len - used;
            if (free_space == 0) {
                _ = win32.WaitForSingleObject(self.wake_event, win32.INFINITE);
                continue; // re-check stop at loop top
            }
            const n = @min(rem.len, free_space);
            const cap = self.buf.len;
            const mask = cap - 1;
            const start = head & mask;
            const first = @min(n, cap - start);
            @memcpy(self.buf[start..][0..first], rem[0..first]);
            if (n > first) @memcpy(self.buf[0..(n - first)], rem[first..n]);
            self.head.store(head + n, .release);
            rem = rem[n..];
        }
        return true;
    }

    // Consumer (UI thread). Hands all currently-available bytes to `cb` as
    // up to two contiguous slices (wrap split), advances tail, and signals
    // `wake_event` so any full-ring writer can resume. Returns total bytes
    // drained.
    //
    // Zero-copy: the callback receives pointers directly into `self.buf`;
    // they are valid for the duration of the call (single-consumer ring,
    // tail not advanced until after both cb invocations).
    pub fn drain(self: *PtyRing, ctx: anytype, comptime cb: anytype) usize {
        const head = self.head.load(.acquire);
        const tail = self.tail.load(.monotonic);
        const used = head - tail;
        if (used == 0) return 0;
        const cap = self.buf.len;
        const mask = cap - 1;
        const start = tail & mask;
        const first = @min(used, cap - start);
        cb(ctx, self.buf[start..][0..first]);
        if (used > first) cb(ctx, self.buf[0..(used - first)]);
        self.tail.store(head, .release);
        _ = win32.SetEvent(self.wake_event);
        return used;
    }
};
