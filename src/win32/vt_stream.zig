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
