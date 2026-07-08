const std = @import("std");
const vt_mod = @import("vt");

pub const Stream = vt_mod.Stream(Handler);

pub const Handler = struct {
    inner: vt_mod.TerminalStream.Handler,

    pub fn init(terminal: *vt_mod.Terminal, effects: vt_mod.TerminalStream.Handler.Effects) Handler {
        var inner = vt_mod.TerminalStream.Handler.init(terminal);
        inner.effects = effects;
        return .{ .inner = inner };
    }

    pub fn deinit(self: *Handler) void {
        self.inner.deinit();
    }

    pub fn vt(
        self: *Handler,
        comptime action: vt_mod.StreamAction.Tag,
        value: vt_mod.StreamAction.Value(action),
    ) void {
        switch (action) {
            .print => {
                repairCursorCellForPrint(self.inner.terminal);
                self.inner.vt(action, value);
            },
            .print_repeat => {
                const c = self.inner.terminal.previous_char orelse return;
                const count = @max(value, 1);
                for (0..count) |_| {
                    repairCursorCellForPrint(self.inner.terminal);
                    self.inner.vt(.print, .{ .cp = c });
                }
            },
            else => self.inner.vt(action, value),
        }
    }
};

fn repairCursorCellForPrint(term: *vt_mod.Terminal) void {
    const screen = term.screens.active;
    const cursor = &screen.cursor;
    const page = &cursor.page_pin.node.data;
    const row = cursor.page_row;
    const cells = page.getCells(row);
    const x = cursor.x;

    switch (cells[x].wide) {
        .narrow => {},
        .wide => {
            // Ghostty clears the spacer tail before overwriting this wide head.
            // In Debug builds, that can trip page integrity before the head is
            // replaced, so make the pair narrow before clearing it.
            cells[x].wide = .narrow;
            clearWrappedSpacerHead(screen, x);
            if (x + 1 < cells.len) {
                screen.clearCells(page, row, cells[x .. x + 2]);
            } else {
                screen.clearCells(page, row, cells[x .. x + 1]);
            }
        },
        .spacer_tail => {
            if (x == 0) return;
            cells[x].wide = .narrow;
            clearWrappedSpacerHead(screen, x);
            screen.clearCells(page, row, cells[x - 1 .. x + 1]);
        },
        .spacer_head => {
            cells[x].wide = .narrow;
        },
    }
}

fn clearWrappedSpacerHead(screen: *vt_mod.Screen, cursor_x: usize) void {
    if (screen.cursor.y == 0 or cursor_x > 1) return;
    const head_cell = screen.cursorCellEndOfPrev();
    if (head_cell.wide == .spacer_head) head_cell.wide = .narrow;
}

test "print over wide head repairs before delegating" {
    const alloc = std.testing.allocator;
    var term = try vt_mod.Terminal.init(alloc, .{ .cols = 5, .rows = 2 });
    defer term.deinit(alloc);

    var stream = Stream.initAlloc(alloc, Handler.init(&term, .readonly));
    defer stream.deinit();

    try term.print(0x4E2D);
    term.setCursorPos(1, 1);
    stream.nextSlice("x");

    const str = try term.plainString(alloc);
    defer alloc.free(str);
    try std.testing.expectEqualStrings("x", str);
}

test "print over spacer tail repairs before delegating" {
    const alloc = std.testing.allocator;
    var term = try vt_mod.Terminal.init(alloc, .{ .cols = 5, .rows = 2 });
    defer term.deinit(alloc);

    var stream = Stream.initAlloc(alloc, Handler.init(&term, .readonly));
    defer stream.deinit();

    try term.print(0x4E2D);
    term.setCursorPos(1, 2);
    stream.nextSlice("x");

    const str = try term.plainString(alloc);
    defer alloc.free(str);
    try std.testing.expectEqualStrings(" x", str);
}

test "kitty graphics APC delegates to Ghostty and emits ACK" {
    const alloc = std.testing.allocator;
    var term = try vt_mod.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.width_px = 100;
    term.height_px = 100;

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *vt_mod.TerminalStream.Handler, data: [:0]const u8) void {
            if (written) |old| std.testing.allocator.free(old);
            written = std.testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| alloc.free(old);

    var effects: vt_mod.TerminalStream.Handler.Effects = .readonly;
    effects.write_pty = S.writePty;
    var stream = Stream.initAlloc(alloc, Handler.init(&term, effects));
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=t,t=d,f=24,i=1,s=1,v=2,c=10,r=1;////////\x1b\\");

    try std.testing.expectEqualStrings("\x1b_Gi=1;OK\x1b\\", S.written.?);
    const storage = &term.screens.active.kitty_images;
    const img = storage.imageById(1).?;
    try std.testing.expectEqual(.rgb, img.format);
}

test "kitty graphics APC transmit-and-display creates placement" {
    const alloc = std.testing.allocator;
    var term = try vt_mod.Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer term.deinit(alloc);
    term.width_px = 100;
    term.height_px = 100;

    const S = struct {
        var written: ?[]const u8 = null;
        fn writePty(_: *vt_mod.TerminalStream.Handler, data: [:0]const u8) void {
            if (written) |old| std.testing.allocator.free(old);
            written = std.testing.allocator.dupe(u8, data) catch @panic("OOM");
        }
    };
    S.written = null;
    defer if (S.written) |old| alloc.free(old);

    var effects: vt_mod.TerminalStream.Handler.Effects = .readonly;
    effects.write_pty = S.writePty;
    var stream = Stream.initAlloc(alloc, Handler.init(&term, effects));
    defer stream.deinit();

    stream.nextSlice("\x1b_Ga=T,t=d,f=24,i=41001,s=1,v=1,c=2,r=1;/wAA\x1b\\");

    try std.testing.expectEqualStrings("\x1b_Gi=41001;OK\x1b\\", S.written.?);
    const storage = &term.screens.active.kitty_images;
    const img = storage.imageById(41001).?;
    try std.testing.expectEqual(.rgb, img.format);
    try std.testing.expectEqual(@as(usize, 1), storage.placements.count());
    var it = storage.placements.iterator();
    const placement = it.next().?.value_ptr;
    try std.testing.expectEqual(@as(u32, 2), placement.columns);
    try std.testing.expectEqual(@as(u32, 1), placement.rows);
    try std.testing.expect(placement.location == .pin);
}
