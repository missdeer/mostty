//! Proportional tab-bar painter. Draws the tab-bar band into an offscreen D2D
//! render target (opaque) using DirectWrite, so titles render with the tab-bar
//! font's natural advances (not the terminal cell grid). The renderer copies
//! the result onto the back buffer's top strip. Tab widths and the close/new
//! buttons stay column-based; only the title text is proportional.

const std = @import("std");
const win32 = @import("win32").everything;
const com = @import("com.zig");
const types = @import("../types.zig");

// sRGB-byte color (matches the back buffer's stored bytes after the raw copy;
// the band RT is UNORM so D2D writes these values straight through). Opaque.
fn colorF(c: u24) win32.D2D_COLOR_F {
    return .{
        .r = @as(f32, @floatFromInt((c >> 16) & 0xFF)) / 255.0,
        .g = @as(f32, @floatFromInt((c >> 8) & 0xFF)) / 255.0,
        .b = @as(f32, @floatFromInt(c & 0xFF)) / 255.0,
        .a = 1.0,
    };
}

// Lenient UTF-8 -> UTF-16 into `buf`; invalid bytes become '?'. Returns the
// written slice (clamped to buf capacity). Titles come from OSC and may not be
// valid UTF-8, so never fail.
fn toUtf16(buf: []u16, s: []const u8) []const u16 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n + 2 <= buf.len) {
        const seq_len = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            buf[n] = '?';
            n += 1;
            i += 1;
            continue;
        };
        if (i + seq_len > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + seq_len]) catch {
            buf[n] = '?';
            n += 1;
            i += seq_len;
            continue;
        };
        if (cp <= 0xFFFF) {
            buf[n] = @intCast(cp);
            n += 1;
        } else {
            const c = cp - 0x10000;
            buf[n] = @intCast(0xD800 + (c >> 10));
            buf[n + 1] = @intCast(0xDC00 + (c & 0x3FF));
            n += 2;
        }
        i += seq_len;
    }
    return buf[0..n];
}

// Draws a single character centered in [x, x+w) x [0, h) (used for the close
// 'x' and new-tab '+'). Borrows the shared brush, setting its color first.
fn drawCenteredChar(
    rt: *win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    dwrite_factory: *win32.IDWriteFactory,
    format: *win32.IDWriteTextFormat,
    ch: u16,
    x: f32,
    w: f32,
    h: f32,
    fg: u24,
) void {
    var str = [_:0]u16{ch};
    var layout: *win32.IDWriteTextLayout = undefined;
    if (dwrite_factory.CreateTextLayout(&str, 1, format, w, h, &layout) < 0) return;
    defer _ = layout.IUnknown.Release();
    _ = layout.IDWriteTextFormat.SetTextAlignment(win32.DWRITE_TEXT_ALIGNMENT_CENTER);
    _ = layout.IDWriteTextFormat.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    brush.SetColor(&colorF(fg));
    rt.DrawTextLayout(.{ .x = x, .y = 0 }, layout, &brush.ID2D1Brush, .{});
}

// Paints the whole tab-bar band into `rt` (assumed sized client_w x band_h).
// `cell_w` is the terminal cell width in pixels (tab columns are cell_w wide).
pub fn paint(
    rt: *win32.ID2D1RenderTarget,
    brush: *win32.ID2D1SolidColorBrush,
    dwrite_factory: *win32.IDWriteFactory,
    format: *win32.IDWriteTextFormat,
    // Ellipsis sign cached by the renderer (bound to `format`); may be null.
    sign: ?*win32.IDWriteInlineObject,
    draw: types.TabBarDraw,
    cell_w: u32,
    band_h: u32,
) void {
    const cw: f32 = @floatFromInt(cell_w);
    const bh: f32 = @floatFromInt(band_h);

    const trimming = win32.DWRITE_TRIMMING{
        .granularity = win32.DWRITE_TRIMMING_GRANULARITY_CHARACTER,
        .delimiter = 0,
        .delimiterCount = 0,
    };

    rt.BeginDraw();
    rt.Clear(&colorF(types.tab_bar_bg));

    for (draw.tabs) |t| {
        const x0: f32 = @floatFromInt(t.col_start * cell_w);
        const x1: f32 = @floatFromInt(t.col_end * cell_w);
        const bg: u24 = if (t.active) types.tab_active_bg else if (t.hovered) types.tab_hover_bg else types.tab_bar_bg;
        const fg: u24 = if (t.active) types.tab_active_fg else types.tab_bar_fg;

        // Tab background.
        brush.SetColor(&colorF(bg));
        rt.FillRectangle(&.{ .left = x0, .top = 0, .right = x1, .bottom = bh }, &brush.ID2D1Brush);

        // Title box: one column of left padding, ending one column before the
        // close 'x' (matching the old cell layout's reserved " x").
        const title_x0: f32 = @floatFromInt((t.col_start + 1) * cell_w);
        const title_end_col: u32 = if (t.close_col > t.col_start + 1) t.close_col - 1 else t.col_start + 1;
        const title_x1: f32 = @floatFromInt(title_end_col * cell_w);
        const max_w = title_x1 - title_x0;
        if (max_w > 0) {
            var u16_buf: [512]u16 = undefined;
            var placeholder: [16]u8 = undefined;
            const text: []const u8 = if (t.title.len > 0)
                t.title
            else
                std.fmt.bufPrint(&placeholder, "tab {d}", .{t.tab_number}) catch placeholder[0..0];
            const u16_title = toUtf16(&u16_buf, text);

            var layout: *win32.IDWriteTextLayout = undefined;
            if (dwrite_factory.CreateTextLayout(@ptrCast(u16_title.ptr), @intCast(u16_title.len), format, max_w, bh, &layout) >= 0) {
                defer _ = layout.IUnknown.Release();
                _ = layout.IDWriteTextFormat.SetTrimming(&trimming, sign);
                _ = layout.IDWriteTextFormat.SetParagraphAlignment(win32.DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
                brush.SetColor(&colorF(fg));
                rt.DrawTextLayout(.{ .x = title_x0, .y = 0 }, layout, &brush.ID2D1Brush, win32.D2D1_DRAW_TEXT_OPTIONS_CLIP);
            }
        }

        // Close 'x'.
        const close_fg: u24 = if (t.close_hovered) types.close_hover_fg else fg;
        drawCenteredChar(rt, brush, dwrite_factory, format, 'x', @floatFromInt(t.close_col * cell_w), cw, bh, close_fg);
    }

    if (draw.new_tab_col) |c| {
        const fg: u24 = if (draw.new_tab_hovered) types.new_tab_hover_fg else types.new_tab_button_fg;
        drawCenteredChar(rt, brush, dwrite_factory, format, '+', @floatFromInt(c * cell_w), cw, bh, fg);
    }

    var tag1: u64 = undefined;
    var tag2: u64 = undefined;
    if (rt.EndDraw(&tag1, &tag2) < 0) com.fatalHr("tabbar EndDraw", -1);
}
