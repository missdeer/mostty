const std = @import("std");
const vt = @import("vt");

const TerminalFlags = @FieldType(vt.Terminal, "flags");
const MouseEventMode = @FieldType(TerminalFlags, "mouse_event");
const MouseFormat = @FieldType(TerminalFlags, "mouse_format");

pub const Action = enum { press, release, motion };

pub const Button = enum {
    left,
    middle,
    right,
    wheel_up,
    wheel_down,
    wheel_left,
    wheel_right,
};

pub const Mods = struct {
    shift: bool = false,
    alt: bool = false,
    ctrl: bool = false,
};

pub const Pos = struct {
    x: i32 = 0,
    y: i32 = 0,
};

pub const Grid = struct {
    cols: u16,
    rows: u16,
    cell_width: i32,
    cell_height: i32,
};

pub const Event = struct {
    action: Action,
    button: ?Button = null,
    mods: Mods = .{},
    pos: Pos = .{},
};

pub const Options = struct {
    event: MouseEventMode = .none,
    format: MouseFormat = .x10,
    grid: Grid,
    any_button_pressed: bool = false,
    last_cell: ?*?vt.Coordinate = null,
};

pub fn enabled(term: *const vt.Terminal) bool {
    return term.flags.mouse_event != .none;
}

pub fn encode(writer: *std.Io.Writer, event: Event, opts: Options) std.Io.Writer.Error!void {
    if (!shouldReport(event, opts)) return;

    if (event.action != .release and posOutOfViewport(event.pos, opts.grid)) {
        if (!eventSendsMotion(opts.event)) return;
        if (!opts.any_button_pressed) return;
    }

    const cell = posToCell(event.pos, opts.grid);
    if (event.action == .motion and opts.format != .sgr_pixels) {
        if (opts.last_cell) |last| {
            if (last.*) |last_cell| {
                if (last_cell.eql(cell)) return;
            }
        }
    }
    if (opts.last_cell) |last| last.* = cell;

    const code = buttonCode(event, opts) orelse return;
    switch (opts.format) {
        .x10 => {
            if (cell.x > 222 or cell.y > 222) return;
            try writer.writeAll("\x1b[M");
            try writer.writeByte(32 + code);
            try writer.writeByte(32 + @as(u8, @intCast(cell.x)) + 1);
            try writer.writeByte(32 + @as(u8, @intCast(cell.y)) + 1);
        },
        .utf8 => {
            try writer.writeAll("\x1b[M");
            try writer.writeByte(32 + code);

            var buf: [4]u8 = undefined;
            const x_cp: u21 = @intCast(@as(u32, cell.x) + 33);
            const y_cp: u21 = @intCast(cell.y + 33);
            const x_len = std.unicode.utf8Encode(x_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..x_len]);
            const y_len = std.unicode.utf8Encode(y_cp, &buf) catch unreachable;
            try writer.writeAll(buf[0..y_len]);
        },
        .sgr => try writer.print("\x1b[<{d};{d};{d}{c}", .{
            code,
            cell.x + 1,
            cell.y + 1,
            @as(u8, if (event.action == .release) 'm' else 'M'),
        }),
        .urxvt => try writer.print("\x1b[{d};{d};{d}M", .{
            32 + code,
            cell.x + 1,
            cell.y + 1,
        }),
        .sgr_pixels => try writer.print("\x1b[<{d};{d};{d}{c}", .{
            code,
            event.pos.x,
            event.pos.y,
            @as(u8, if (event.action == .release) 'm' else 'M'),
        }),
    }
}

fn eventSendsMotion(event: MouseEventMode) bool {
    return event == .button or event == .any;
}

fn shouldReport(event: Event, opts: Options) bool {
    return switch (opts.event) {
        .none => false,
        .x10 => event.action == .press and
            event.button != null and
            (event.button.? == .left or event.button.? == .middle or event.button.? == .right),
        .normal => event.action != .motion,
        .button => event.button != null,
        .any => true,
    };
}

fn buttonCode(event: Event, opts: Options) ?u8 {
    var acc: u8 = code: {
        if (event.button == null) break :code 3;
        if (event.action == .release and opts.format != .sgr and opts.format != .sgr_pixels) break :code 3;
        break :code switch (event.button.?) {
            .left => 0,
            .middle => 1,
            .right => 2,
            .wheel_up => 64,
            .wheel_down => 65,
            .wheel_left => 66,
            .wheel_right => 67,
        };
    };

    if (opts.event != .x10) {
        if (event.mods.shift) acc += 4;
        if (event.mods.alt) acc += 8;
        if (event.mods.ctrl) acc += 16;
    }
    if (event.action == .motion) acc += 32;
    return acc;
}

fn posOutOfViewport(pos: Pos, grid: Grid) bool {
    const width: i32 = @as(i32, grid.cols) * grid.cell_width;
    const height: i32 = @as(i32, grid.rows) * grid.cell_height;
    return pos.x < 0 or pos.y < 0 or pos.x > width or pos.y > height;
}

fn posToCell(pos: Pos, grid: Grid) vt.Coordinate {
    const max_x = @as(i32, grid.cols) * grid.cell_width - 1;
    const max_y = @as(i32, grid.rows) * grid.cell_height - 1;
    const x = @max(0, @min(pos.x, max_x));
    const y = @max(0, @min(pos.y, max_y));
    return .{
        .x = @intCast(@divTrunc(x, grid.cell_width)),
        .y = @intCast(@divTrunc(y, grid.cell_height)),
    };
}

fn testGrid() Grid {
    return .{ .cols = 80, .rows = 24, .cell_width = 10, .cell_height = 20 };
}

test "SGR reports press and release with one-based cell coordinates" {
    var data: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?vt.Coordinate = null;
    try encode(&writer, .{
        .action = .press,
        .button = .left,
        .pos = .{ .x = 21, .y = 41 },
    }, .{
        .event = .normal,
        .format = .sgr,
        .grid = testGrid(),
        .last_cell = &last,
    });
    try std.testing.expectEqualStrings("\x1b[<0;3;3M", writer.buffered());

    writer = .fixed(&data);
    try encode(&writer, .{
        .action = .release,
        .button = .left,
        .pos = .{ .x = 21, .y = 41 },
    }, .{
        .event = .normal,
        .format = .sgr,
        .grid = testGrid(),
        .last_cell = &last,
    });
    try std.testing.expectEqualStrings("\x1b[<0;3;3m", writer.buffered());
}

test "button mode reports drag motion but not hover motion" {
    var data: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    var last: ?vt.Coordinate = null;
    try encode(&writer, .{
        .action = .motion,
        .button = null,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .button,
        .format = .sgr,
        .grid = testGrid(),
        .last_cell = &last,
    });
    try std.testing.expectEqual(@as(usize, 0), writer.buffered().len);

    writer = .fixed(&data);
    try encode(&writer, .{
        .action = .motion,
        .button = .left,
        .pos = .{ .x = 10, .y = 20 },
    }, .{
        .event = .button,
        .format = .sgr,
        .grid = testGrid(),
        .any_button_pressed = true,
        .last_cell = &last,
    });
    try std.testing.expectEqualStrings("\x1b[<32;2;2M", writer.buffered());
}

test "wheel up uses xterm button 64" {
    var data: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&data);
    try encode(&writer, .{
        .action = .press,
        .button = .wheel_up,
        .pos = .{ .x = 0, .y = 0 },
    }, .{
        .event = .normal,
        .format = .sgr,
        .grid = testGrid(),
    });
    try std.testing.expectEqualStrings("\x1b[<64;1;1M", writer.buffered());
}
