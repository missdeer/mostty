const std = @import("std");
const win32 = @import("win32").everything;

const d3d11 = @import("d3d11.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const state = @import("state.zig");

const GridPos = types.GridPos;

pub const WindowPlacementOptions = struct {
    left: ?i32 = null,
    top: ?i32 = null,
    width: ?u32 = null,
    height: ?u32 = null,
};

pub const WindowPlacement = struct {
    dpi: util.XY(u32),
    size: win32.SIZE,
    pos: win32.POINT,
    pub fn default(opt: WindowPlacementOptions) WindowPlacement {
        return .{
            .dpi = .{ .x = 96, .y = 96 },
            .pos = .{
                .x = if (opt.left) |left| left else win32.CW_USEDEFAULT,
                .y = if (opt.top) |top| top else win32.CW_USEDEFAULT,
            },
            .size = .{ .cx = win32.CW_USEDEFAULT, .cy = win32.CW_USEDEFAULT },
        };
    }
};

pub fn calcWindowPlacement(
    maybe_monitor: ?win32.HMONITOR,
    dpi: u32,
    cell_size: win32.SIZE,
    opt: WindowPlacementOptions,
) WindowPlacement {
    var result = WindowPlacement.default(opt);

    const monitor = maybe_monitor orelse return result;

    const work_rect: win32.RECT = blk: {
        var info: win32.MONITORINFO = undefined;
        info.cbSize = @sizeOf(win32.MONITORINFO);
        if (0 == win32.GetMonitorInfoW(monitor, &info)) {
            std.log.warn("GetMonitorInfo failed, error={f}", .{win32.GetLastError()});
            return result;
        }
        break :blk info.rcWork;
    };

    const work_size: win32.SIZE = .{
        .cx = work_rect.right - work_rect.left,
        .cy = work_rect.bottom - work_rect.top,
    };
    std.log.debug(
        "monitor work topleft={},{} size={}x{}",
        .{ work_rect.left, work_rect.top, work_size.cx, work_size.cy },
    );

    const wanted_size: win32.SIZE = .{
        .cx = win32.scaleDpi(i32, @as(i32, @intCast(opt.width orelse 900)), result.dpi.x),
        .cy = win32.scaleDpi(i32, @as(i32, @intCast(opt.height orelse 700)), result.dpi.y),
    };
    const bounding_size: win32.SIZE = .{
        .cx = @min(wanted_size.cx, work_size.cx),
        .cy = @min(wanted_size.cy, work_size.cy),
    };
    const bouding_rect: win32.RECT = util.rectIntFromSize(.{
        .left = work_rect.left + @divTrunc(work_size.cx - bounding_size.cx, 2),
        .top = work_rect.top + @divTrunc(work_size.cy - bounding_size.cy, 2),
        .width = bounding_size.cx,
        .height = bounding_size.cy,
    });
    const adjusted_rect: win32.RECT = calcWindowRect(
        dpi,
        bouding_rect,
        null,
        cell_size,
    );
    result.pos = .{
        .x = if (opt.left) |left| left else adjusted_rect.left,
        .y = if (opt.top) |top| top else adjusted_rect.top,
    };
    result.size = .{
        .cx = adjusted_rect.right - adjusted_rect.left,
        .cy = adjusted_rect.bottom - adjusted_rect.top,
    };
    return result;
}

pub fn calcWindowRect(
    dpi: u32,
    bounding_rect: win32.RECT,
    maybe_edge: ?win32.WPARAM,
    cell_size: win32.SIZE,
) win32.RECT {
    const client_inset = util.getClientInset(dpi);
    const scrollbar_px: i32 = d3d11.scrollbarWidth(dpi);
    // Reserve one cell row for the tab bar before snapping.
    const tabbar_h: i32 = cell_size.cy;
    const bounding_client_size: win32.SIZE = .{
        .cx = (bounding_rect.right - bounding_rect.left) - client_inset.cx,
        .cy = (bounding_rect.bottom - bounding_rect.top) - client_inset.cy,
    };
    const grid_cy = @max(0, bounding_client_size.cy - tabbar_h);
    const trim: win32.SIZE = .{
        .cx = @mod(@max(bounding_client_size.cx - scrollbar_px, 0), cell_size.cx),
        .cy = @mod(grid_cy, cell_size.cy),
    };
    const Adjustment = enum { low, high, both };
    const adjustments: util.XY(Adjustment) = if (maybe_edge) |edge| switch (edge) {
        win32.WMSZ_LEFT => .{ .x = .low, .y = .both },
        win32.WMSZ_RIGHT => .{ .x = .high, .y = .both },
        win32.WMSZ_TOP => .{ .x = .both, .y = .low },
        win32.WMSZ_TOPLEFT => .{ .x = .low, .y = .low },
        win32.WMSZ_TOPRIGHT => .{ .x = .high, .y = .low },
        win32.WMSZ_BOTTOM => .{ .x = .both, .y = .high },
        win32.WMSZ_BOTTOMLEFT => .{ .x = .low, .y = .high },
        win32.WMSZ_BOTTOMRIGHT => .{ .x = .high, .y = .high },
        else => .{ .x = .both, .y = .both },
    } else .{ .x = .both, .y = .both };

    return .{
        .left = bounding_rect.left + switch (adjustments.x) {
            .low => trim.cx,
            .high => 0,
            .both => @divTrunc(trim.cx, 2),
        },
        .top = bounding_rect.top + switch (adjustments.y) {
            .low => trim.cy,
            .high => 0,
            .both => @divTrunc(trim.cy, 2),
        },
        .right = bounding_rect.right - switch (adjustments.x) {
            .low => 0,
            .high => trim.cx,
            .both => @divTrunc(trim.cx + 1, 2),
        },
        .bottom = bounding_rect.bottom - switch (adjustments.y) {
            .low => 0,
            .high => trim.cy,
            .both => @divTrunc(trim.cy + 1, 2),
        },
    };
}

pub fn computeGridCellCount(hwnd: win32.HWND, cs: win32.SIZE) GridPos {
    const client_size = win32.getClientSize(hwnd);
    const sb_px: i32 = d3d11.scrollbarWidth(win32.dpiFromHwnd(hwnd));
    const grid_w = client_size.cx -| sb_px;
    const grid_h = @max(0, client_size.cy - cs.cy); // reserve one row for tab bar
    return .{
        .col = @intCast(@max(1, @divTrunc(grid_w, cs.cx))),
        .row = @intCast(@max(1, @divTrunc(grid_h, cs.cy))),
    };
}

pub fn scrollbarDragTo(tab: *state.Tab, track_top: f32, win_h: f32, track_height: f32) void {
    const screen = tab.term.screens.active;
    const sb = screen.pages.scrollbar();
    if (sb.total <= sb.len) return;
    const max_offset = sb.total - sb.len;
    const scrollable = win_h - track_height;
    if (scrollable <= 0) return;
    const ratio = std.math.clamp(track_top / scrollable, 0.0, 1.0);
    const target_row: usize = @intFromFloat(ratio * @as(f32, @floatFromInt(max_offset)));
    screen.scroll(.{ .row = target_row });
}
