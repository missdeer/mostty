//! Detects http/https URLs at a viewport (col,row) for mouse-hover linkification.
//!
//! Scans the URL run across visually-adjacent viewport rows, regardless of the
//! row.wrap flag. Ghostty derives row.wrap from the VT printer's auto-wrap
//! (Terminal.printWrap), so output that hard-wraps at the producer side via
//! explicit LF (e.g. `bat` defaulting to character wrap) lands with wrap=false
//! even though the URL is visually one continuous string. Gating crossing on
//! wrap would miss those cases; we rely on the per-cell URL-char check to
//! terminate the walk on unrelated content (whitespace, CJK, empty cells with
//! codepoint=0). The walk is bounded to visible rows; if the URL extends into
//! scrollback or below the viewport we stop at the visible edge — the
//! underline only highlights what the user sees anyway, and the click-target
//! stays consistent with the highlight.

const std = @import("std");
const vt = @import("vt");

// Cap chosen to comfortably cover modern OAuth2 / JWT / deep-link query URLs,
// which routinely run past 1 KB. Stack frame is ~40 KiB at this size (single
// detectAt buffer of MAX_URL_LEN*2 bytes + MAX_URL_LEN*2 Pos entries) — well
// within Windows' default 1 MiB thread stack. Hit.url_buf lives in the
// Window struct (heap-resident), so the cap only affects in-flight detection.
pub const MAX_URL_LEN: usize = 4096;

const Pos = packed struct(u32) {
    row: u16,
    col: u16,

    pub fn eql(a: Pos, b: Pos) bool {
        return @as(u32, @bitCast(a)) == @as(u32, @bitCast(b));
    }
};

pub const Hit = struct {
    // Inclusive viewport-coordinate bounds. start_row <= end_row; on the start
    // row the URL begins at start_col, on the end row it ends at end_col. Rows
    // strictly between cover the full row width.
    start_row: u16,
    start_col: u16,
    end_row: u16,
    end_col: u16,
    url_len: u16,
    url_buf: [MAX_URL_LEN]u8,

    pub fn url(self: *const Hit) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    pub fn eql(a: *const Hit, b: *const Hit) bool {
        return a.start_row == b.start_row and
            a.start_col == b.start_col and
            a.end_row == b.end_row and
            a.end_col == b.end_col and
            a.url_len == b.url_len and
            std.mem.eql(u8, a.url_buf[0..a.url_len], b.url_buf[0..b.url_len]);
    }

    pub fn contains(self: *const Hit, row: u16, col: u16, last_col: u16) bool {
        if (row < self.start_row or row > self.end_row) return false;
        const lo: u16 = if (row == self.start_row) self.start_col else 0;
        const hi: u16 = if (row == self.end_row) self.end_col else last_col;
        return col >= lo and col <= hi;
    }
};

fn isUrlChar(cp: u21) bool {
    // RFC 3986 unreserved + reserved + percent. URL chars are ASCII-only; any
    // CJK / whitespace / wide-cell content terminates the run.
    if (cp > 127) return false;
    return switch (@as(u8, @intCast(cp))) {
        'a'...'z', 'A'...'Z', '0'...'9' => true,
        ':', '/', '?', '#', '[', ']', '@' => true,
        '!', '$', '&', '\'', '(', ')', '*' => true,
        '+', ',', ';', '=' => true,
        '-', '.', '_', '~', '%' => true,
        else => false,
    };
}

fn cellCodepoint(cell: vt.Cell) ?u21 {
    if (cell.wide == .spacer_tail or cell.wide == .spacer_head) return null;
    return switch (cell.content_tag) {
        .codepoint, .codepoint_grapheme => cell.content.codepoint,
        else => null,
    };
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn viewRowCells(screen: anytype, vrow: u16, cols: u16) ?[]vt.Cell {
    const pin = screen.pages.pin(.{ .viewport = .{ .x = 0, .y = vrow } }) orelse return null;
    const rac = pin.rowAndCell();
    const all_cells = pin.node.data.getCells(rac.row);
    if (all_cells.len < cols) return null;
    return all_cells[0..cols];
}

/// Returns the URL hit covering `viewport_col` on `viewport_row`, or null.
pub fn detectAt(term: *vt.Terminal, viewport_col: u16, viewport_row: u16) ?Hit {
    const cols: u16 = std.math.cast(u16, term.cols) orelse return null;
    const rows: u16 = std.math.cast(u16, term.rows) orelse return null;
    if (viewport_col >= cols or viewport_row >= rows) return null;

    const screen = term.screens.active;

    // Cheap reject: clicked cell must yield a URL-char codepoint. Done once,
    // result reused by the right-walk's first iteration.
    const start_cells = viewRowCells(screen, viewport_row, cols) orelse return null;
    const click_cp = cellCodepoint(start_cells[viewport_col]) orelse return null;
    if (click_cp == 0 or click_cp > 127 or !isUrlChar(click_cp)) return null;

    // Single buffer with a fixed center index: the right walk grows toward
    // higher indices, the left walk grows toward lower indices. SLAB on each
    // side bounds each direction to one full URL's worth — same total reach
    // as the previous two-buffer scheme at roughly a third of the stack
    // footprint and no merge step.
    const SLAB: usize = MAX_URL_LEN;
    var bytes: [SLAB * 2]u8 = undefined;
    var pos: [SLAB * 2]Pos = undefined;
    const CENTER: usize = SLAB;

    // Seed with the clicked cell at CENTER.
    bytes[CENTER] = @intCast(click_cp);
    pos[CENTER] = .{ .row = viewport_row, .col = viewport_col };
    var right_end: usize = CENTER + 1; // exclusive
    var left_start: usize = CENTER; // inclusive

    // Walk RIGHT from the cell after the click. At a row boundary, cross to
    // the next viewport row unconditionally — i.e. we do NOT gate on the
    // row.wrap soft-wrap flag. Tools that print long URLs may emit hard
    // newlines at the terminal width (e.g. `bat` defaults to character-wrap),
    // and some PTY bridges don't propagate the soft-wrap signal at all. Both
    // produce visually-wrapped URLs with wrap=false. The URL-char check at
    // the first cell of the next row naturally terminates the walk on
    // unrelated content, so crossing eagerly costs little while covering
    // both soft- and hard-wrapped URLs.
    //
    // right_truncated is set when the run was still in URL chars at the
    // moment we ran out of buffer — used downstream to reject silent
    // truncation (a wrongly-shortened host would ShellExecute a different
    // site).
    var right_truncated = false;
    {
        var r: u16 = viewport_row;
        var c: u16 = viewport_col + 1;
        var cells: []vt.Cell = start_cells;
        right: while (true) {
            if (c >= cols) {
                if (r + 1 >= rows) break :right;
                r += 1;
                c = 0;
                cells = viewRowCells(screen, r, cols) orelse break :right;
            }
            // Single codepoint lookup per cell — no redundant cellIsUrlChar
            // call, since the work is the same.
            const cp = cellCodepoint(cells[c]) orelse break :right;
            if (cp == 0 or cp > 127 or !isUrlChar(cp)) break :right;
            if (right_end >= bytes.len) {
                right_truncated = true;
                break :right;
            }
            bytes[right_end] = @intCast(cp);
            pos[right_end] = .{ .row = r, .col = c };
            right_end += 1;
            c += 1;
        }
    }

    // Walk LEFT, writing into descending slots. Crosses row boundaries
    // unconditionally for the same reason as the right walk.
    //
    // The row slice is cached and only refreshed when we actually cross to a
    // new row — without this, viewRowCells (which walks pages.pin's linked
    // list) would fire per cell, so a long URL on a session with deep
    // scrollback would do thousands of page-list traversals per detectAt call.
    {
        var r: u16 = viewport_row;
        var c: u16 = viewport_col;
        var cells: []vt.Cell = start_cells;
        left: while (true) {
            if (c > 0) {
                c -= 1;
            } else {
                if (r == 0) break :left;
                r -= 1;
                c = cols - 1;
                cells = viewRowCells(screen, r, cols) orelse break :left;
            }
            const cp = cellCodepoint(cells[c]) orelse break :left;
            if (cp == 0 or cp > 127 or !isUrlChar(cp)) break :left;
            if (left_start == 0) break :left;
            left_start -= 1;
            bytes[left_start] = @intCast(cp);
            pos[left_start] = .{ .row = r, .col = c };
        }
    }

    const run = bytes[left_start..right_end];
    const clicked_idx: usize = CENTER - left_start;
    if (run.len < "http://".len) return null;

    // Locate the LAST scheme occurrence (across http:// and https://) at or
    // before the clicked position. Comparing absolute positions across both
    // schemes prevents a later http:// from masking an earlier https:// (or
    // vice versa) — e.g. `http://a=https://b` clicked inside the https URL.
    var scheme_at: ?usize = null;
    for ([_][]const u8{ "https://", "http://" }) |scheme| {
        var search_start: usize = 0;
        while (indexOfIgnoreCase(run[search_start..], scheme)) |rel| {
            const abs = search_start + rel;
            if (abs > clicked_idx) break;
            if (scheme_at == null or abs > scheme_at.?) scheme_at = abs;
            search_start = abs + 1;
        }
    }
    const url_start = scheme_at orelse return null;

    var url_end = run.len; // exclusive

    while (url_end > url_start) {
        const last = run[url_end - 1];
        if (last == '.' or last == ',' or last == ';' or last == ':' or last == '!' or last == '?') {
            url_end -= 1;
        } else break;
    }
    while (url_end > url_start) {
        const last = run[url_end - 1];
        if (last != ')' and last != ']') break;
        const slice = run[url_start..url_end];
        const open: u8 = if (last == ')') '(' else '[';
        const opens = std.mem.count(u8, slice, &[_]u8{open});
        const closes = std.mem.count(u8, slice, &[_]u8{last});
        if (closes <= opens) break;
        url_end -= 1;
    }

    const url_len = url_end - url_start;
    // Require at least scheme + one host char. Determine which scheme matched
    // so `http://x` (8 chars) is accepted while `https://` alone is rejected.
    const scheme_len: usize = if (url_len >= "https://".len and
        std.ascii.eqlIgnoreCase(run[url_start .. url_start + "https://".len], "https://"))
        "https://".len
    else
        "http://".len;
    if (url_len <= scheme_len) return null;
    if (clicked_idx < url_start or clicked_idx >= url_end) return null;

    // Reject silently-truncated URLs: when the right walk stopped because the
    // buffer was full while still seeing URL chars, the URL extends past what
    // we captured. Trimming can mask this — e.g. captured `https://x.com,` and
    // trimmed the `,`, so url_end < run.len, but the real URL continued past
    // the comma. Be conservative: any right truncation rejects the hit, since
    // opening a host-shortened prefix could send the user to a different site.
    if (right_truncated) return null;
    // Hit.url_buf is MAX_URL_LEN bytes. The capture buffer is 2× that, so
    // url_len can legitimately exceed MAX_URL_LEN; reject rather than memcpy
    // past the destination.
    if (url_len > MAX_URL_LEN) return null;

    // url_start / url_end index into `run`, which is the slice
    // bytes[left_start..right_end]. Position lookups must use the absolute
    // index in the underlying buffer.
    const start_pos = pos[left_start + url_start];
    const end_pos = pos[left_start + url_end - 1];
    var hit: Hit = .{
        .start_row = start_pos.row,
        .start_col = start_pos.col,
        .end_row = end_pos.row,
        .end_col = end_pos.col,
        .url_len = @intCast(url_len),
        .url_buf = undefined,
    };
    @memcpy(hit.url_buf[0..url_len], run[url_start..url_end]);
    return hit;
}
