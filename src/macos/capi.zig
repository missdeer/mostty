//! C-ABI boundary over the macOS PTY session and CoreText/Metal renderer.
//!
//! The Swift/AppKit application drives the terminal exclusively through these
//! exported functions; it never sees Zig or VT internals. Every function that
//! touches VT state (`feed`, `render`, `resize`, mode/scroll/selection queries)
//! must be called from the main thread — this preserves the single-threaded VT
//! invariant the core relies on. Only `mostty_tab_read` is safe off the main
//! thread: it is a bare `read(2)` on the PTY master and never touches VT state.

const builtin = @import("builtin");
const std = @import("std");
const vt = @import("vt");

const PtySession = @import("pty_session.zig");
const CoreTextRenderer = @import("core_text_renderer.zig");
const GridModel = @import("grid_model.zig");
const Config = @import("../config.zig");
const title_mod = @import("../terminal/title.zig");
const word_selection = @import("../terminal/word_selection.zig");
const url_hover = @import("../terminal/url_hover.zig");
const mouse_report = @import("../terminal/mouse_report.zig");
const key_encode = @import("../terminal/key_encode.zig");
const mod_shift = key_encode.mod_shift;
const mod_alt = key_encode.mod_alt;
const mod_ctrl = key_encode.mod_ctrl;

comptime {
    if (builtin.os.tag != .macos) @compileError("capi is macOS-only");
}

const allocator = std.heap.c_allocator;

const SelectionInput = struct {
    start_col: u32,
    start_row: u32,
    end_col: u32,
    end_row: u32,
};

fn runtimeIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Tab = struct {
    pty: PtySession,
    renderer: CoreTextRenderer,
    exit_code: ?i32 = null,
    mouse_last_cell: ?vt.Coordinate = null,
    selection_input: ?SelectionInput = null,
};

// Process-wide configuration, loaded lazily and replaced by
// `mostty_config_reload`. Every reader runs on the main thread (tab creation and
// the host's reload path), so no lock is needed. A reload frees the arena the
// config's strings live in, so callers copy values out instead of borrowing.
var loaded_config: ?Config = null;

fn config() *Config {
    if (loaded_config == null) loaded_config = Config.loadDefault(allocator);
    return &loaded_config.?;
}

fn fontOptions(cfg: *const Config) CoreTextRenderer.FontOptions {
    return .{
        // The CoreText renderer resolves missing glyphs through the system
        // fallback chain, so only the primary `font-family` entry is used.
        .family = if (cfg.font_families.len > 0)
            cfg.font_families[0]
        else
            CoreTextRenderer.default_family,
        .family_bold = cfg.font_family_bold,
        .family_italic = cfg.font_family_italic,
        .family_bold_italic = cfg.font_family_bold_italic,
        .size = cfg.font_size_pt orelse CoreTextRenderer.default_font_size,
    };
}

fn paintOptions(cfg: *const Config) CoreTextRenderer.Paint {
    return .{
        .background_alpha = alphaFromOpacity(cfg.background_opacity),
        .selection_foreground = optionalRgba(cfg.theme.selection_foreground),
        .selection_background = optionalRgba(cfg.theme.selection_background),
        // `cursor-color` travels through the terminal's dynamic colors instead
        // (see ThemeColors.applyToNewTerminal), so an app's OSC 12 override
        // survives a config reload.
        .cursor_text = optionalRgba(cfg.theme.cursor_text),
    };
}

const alphaFromOpacity = GridModel.alphaFromOpacity;
const optionalRgba = GridModel.optionalRgba;

/// Create a terminal tab sized to fit `pixel_width` x `pixel_height` at
/// `scale`. Font, colors, launcher command, and environment all come from the
/// config. The initial grid is derived from the renderer's cell metrics so the
/// PTY, VT, and renderer agree on dimensions from the first frame. Returns null
/// on any failure (renderer, Metal, or shell spawn).
export fn mostty_tab_create(pixel_width: u32, pixel_height: u32, scale: f32) ?*Tab {
    const cfg = config();
    const launcher = if (cfg.launchers.len > 0) &cfg.launchers[0] else null;
    return createTab(pixel_width, pixel_height, scale, launcher) catch null;
}

/// The host copies launcher values when building the menu, so a config reload
/// cannot change the selected command while the menu is open.
export fn mostty_tab_create_with_launcher(pixel_width: u32, pixel_height: u32, scale: f32, command: [*:0]const u8, directory: [*:0]const u8) ?*Tab {
    const launcher: Config.Launcher = .{
        .label = "",
        .command_line = std.mem.span(command),
        .working_directory = std.mem.span(directory),
    };
    return createTab(pixel_width, pixel_height, scale, &launcher) catch null;
}

// Split out so `errdefer` runs on failure: the exported wrapper returns an
// optional, and `return null` is a normal (not error) return, which would skip
// any errdefer cleanup and leak the Tab plus its renderer resources.
fn createTab(pixel_width: u32, pixel_height: u32, scale: f32, launcher: ?*const Config.Launcher) !*Tab {
    const cfg = config();

    const tab = try allocator.create(Tab);
    errdefer allocator.destroy(tab);

    tab.renderer = try CoreTextRenderer.init(.{
        .allocator = allocator,
        .font = fontOptions(cfg),
        .paint = paintOptions(cfg),
        .scale = if (scale > 0) scale else 1,
        .pixel_width = pixel_width,
        .pixel_height = pixel_height,
    });
    errdefer tab.renderer.deinit();

    const grid = tab.renderer.gridSize();
    if (grid.cols == 0 or grid.rows == 0) return error.EmptyGrid;

    const working_directory = try initialWorkingDirectory(launcher);
    defer if (working_directory) |wd| allocator.free(wd);
    const command = try launcherCommand(launcher);
    defer if (command) |value| allocator.free(value);

    try tab.pty.init(.{
        .io = runtimeIo(),
        .terminal_allocator = allocator,
        .stream_allocator = allocator,
        .cols = @intCast(grid.cols),
        .rows = @intCast(grid.rows),
        .working_directory = working_directory,
        .command = command,
        .env = cfg.env,
        .images_enabled = cfg.images_enabled,
        .cell_width = tab.renderer.metrics.cell_width,
        .cell_height = tab.renderer.metrics.cell_height,
    });
    cfg.theme.applyToNewTerminal(tab.pty.terminal.term);
    tab.exit_code = null;
    tab.mouse_last_cell = null;
    tab.selection_input = null;
    return tab;
}

// Resolves the initial CWD for a new tab: the selected launcher's
// working_directory when set, otherwise $HOME. Returns null (inherit the
// process CWD) only when neither is available. Caller owns the returned slice.
// Propagates OOM rather than swallowing it, so a new tab never silently lands
// in the wrong directory under allocation failure.
fn initialWorkingDirectory(launcher: ?*const Config.Launcher) std.mem.Allocator.Error!?[:0]u8 {
    if (launcher) |item| {
        const wd = item.working_directory;
        if (wd.len > 0) return try allocator.dupeZ(u8, wd);
    }
    const home = std.c.getenv("HOME") orelse return null;
    const span = std.mem.span(home);
    if (span.len == 0) return null;
    return try allocator.dupeZ(u8, span);
}

// The selected launcher's command line.
// Null keeps the plain login shell. Caller owns the returned slice.
fn launcherCommand(launcher: ?*const Config.Launcher) std.mem.Allocator.Error!?[:0]u8 {
    const command_line = (launcher orelse return null).command_line;
    if (command_line.len == 0) return null;
    return try allocator.dupeZ(u8, command_line);
}

/// Re-read the config file. Returns false when it could not be read (an editor
/// mid-save holding the file), leaving the previous config in place so a
/// transient failure never resets the terminal to defaults.
export fn mostty_config_reload() bool {
    const reloaded = Config.loadDefaultChecked(allocator) catch return false;
    // Publish before freeing: Config owns an arena, and the old value must not
    // be reachable once its strings are gone.
    var previous = loaded_config;
    loaded_config = reloaded;
    if (previous) |*old| old.deinit();
    return true;
}

/// Re-apply the current config to a live tab after `mostty_config_reload`.
/// Returns true when the cell metrics changed, so the host must re-sync its
/// drawable and grid.
export fn mostty_tab_apply_config(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    const cfg = config();
    tab.renderer.paint = paintOptions(cfg);
    tab.pty.terminal.setImagesEnabled(cfg.images_enabled);
    cfg.theme.rebaseTerminal(tab.pty.terminal.term);
    return tab.renderer.reconfigure(fontOptions(cfg)) catch false;
}

/// Path of the config file the host watches for changes. Returns the byte count
/// written, or 0 when the location cannot be resolved or does not fit.
export fn mostty_config_path(buf: [*]u8, cap: usize) usize {
    const path = Config.defaultPath(allocator) orelse return 0;
    defer allocator.free(path);
    if (path.len > cap) return 0;
    @memcpy(buf[0..path.len], path);
    return path.len;
}

/// Cell background alpha as a 0..1 fraction, for the host to decide whether its
/// layer and window must be translucent.
export fn mostty_config_background_opacity() f32 {
    return std.math.clamp(config().background_opacity, 0, 1);
}

export fn mostty_config_background_blur() bool {
    return config().background_blur;
}

export fn mostty_config_maximize() bool {
    return config().maximize;
}

export fn mostty_config_fullscreen() bool {
    return config().fullscreen;
}

export fn mostty_config_confirm_close() bool {
    return config().confirm_close_surface;
}

export fn mostty_config_launcher_count() usize {
    return config().launchers.len;
}

export fn mostty_config_launcher_text(index: usize, field: u32, buf: [*]u8, cap: usize) usize {
    const cfg = config();
    if (index >= cfg.launchers.len) return 0;
    const launcher = cfg.launchers[index];
    return copyText(switch (field) {
        0 => launcher.label,
        1 => launcher.command_line,
        2 => launcher.working_directory,
        else => return 0,
    }, buf, cap);
}

fn copyText(value: []const u8, buf: [*]u8, cap: usize) usize {
    if (cap == 0) return value.len;
    if (cap < value.len) return 0;
    @memcpy(buf[0..value.len], value);
    return value.len;
}

var theme_names: ?[][]u8 = null;

export fn mostty_config_refresh_themes() usize {
    if (theme_names) |names| {
        for (names) |name| allocator.free(name);
        allocator.free(names);
    }
    theme_names = Config.listThemeNames(allocator);
    return @min(theme_names.?.len, 1024);
}

export fn mostty_config_theme_name(index: usize, buf: [*]u8, cap: usize) usize {
    const names = theme_names orelse return 0;
    if (index >= @min(names.len, 1024)) return 0;
    return copyText(names[index], buf, cap);
}

export fn mostty_config_active_theme(buf: [*]u8, cap: usize) usize {
    return copyText(config().theme_name orelse "", buf, cap);
}

export fn mostty_config_select_theme(name: [*:0]const u8) bool {
    const value = std.mem.span(name);
    var colors = Config.loadThemeColorsByName(allocator, value) orelse return false;
    const cfg = config();
    const owned = cfg.arena.?.allocator().dupe(u8, value) catch return false;
    cfg.color_overrides.applyTo(&colors);
    cfg.theme = colors;
    cfg.theme_name = owned;
    return true;
}

/// Frame interval for the host's render timer. macOS has no remote-session
/// concept, so `render-interval-remote-ms` has no effect here.
export fn mostty_config_render_interval_ms() u32 {
    return config().render_interval_local_ms;
}

/// Publish the host's mouse selection so the renderer recolors those cells with
/// `selection-background` / `selection-foreground` (inverse video when unset).
export fn mostty_tab_set_selection(
    tab_opt: ?*Tab,
    active: bool,
    start_col: u32,
    start_row: u32,
    end_col: u32,
    end_row: u32,
) void {
    const tab = tab_opt orelse return;
    const screen = tab.pty.terminal.term.screens.active;
    const input = SelectionInput{
        .start_col = start_col,
        .start_row = start_row,
        .end_col = end_col,
        .end_row = end_row,
    };
    if (!active) {
        screen.clearSelection();
        tab.selection_input = null;
        return;
    }

    // Host coordinates remain viewport-relative while output can move the
    // tracked selection into scrollback. Reuse unchanged endpoints so a
    // delayed mouse callback cannot replace the selection with a new row.
    if (screen.selection) |existing| {
        if (tab.selection_input) |previous| {
            const keep_start = input.start_col == previous.start_col and
                input.start_row == previous.start_row;
            const keep_end = input.end_col == previous.end_col and
                input.end_row == previous.end_row;
            if (keep_start and keep_end) return;
            if (keep_start or keep_end) {
                const start = if (keep_start)
                    existing.start()
                else
                    viewportPin(tab, start_col, start_row) orelse return;
                const end = if (keep_end)
                    existing.end()
                else
                    viewportPin(tab, end_col, end_row) orelse return;
                screen.select(vt.Selection.init(start, end, false)) catch return;
                tab.selection_input = input;
                return;
            }
        }
    }

    screen.clearSelection();
    tab.selection_input = null;
    const start = viewportPin(tab, start_col, start_row) orelse return;
    const end = viewportPin(tab, end_col, end_row) orelse return;
    screen.select(vt.Selection.init(start, end, false)) catch return;
    tab.selection_input = input;
}

fn viewportPin(tab: *Tab, col: u32, row: u32) ?vt.Pin {
    const term = tab.pty.terminal.term;
    if (col >= term.cols or row >= term.rows) return null;
    return term.screens.active.pages.pin(.{ .viewport = .{ .x = @intCast(col), .y = row } });
}

/// Expand the clicked cell using the same token boundaries as Windows.
export fn mostty_tab_select_word(tab_opt: ?*Tab, col: u32, row: u32) bool {
    const tab = tab_opt orelse return false;
    const screen = tab.pty.terminal.term.screens.active;
    screen.clearSelection();
    tab.selection_input = null;
    var pin = viewportPin(tab, col, row) orelse return false;
    if (pin.rowAndCell().cell.wide == .spacer_tail and pin.x > 0) pin.x -= 1;
    const sel = word_selection.selectWordCJK(pin, &word_selection.WORD_BOUNDARIES) orelse
        vt.Selection.init(pin, pin, false);
    screen.select(sel) catch return false;
    return true;
}

fn visibleSelection(tab: *Tab) ?GridModel.Selection {
    const term = tab.pty.terminal.term;
    const screen = term.screens.active;
    const sel = screen.selection orelse return null;
    const start = screen.pages.pointFromPin(.viewport, sel.topLeft(screen));
    const end = screen.pages.pointFromPin(.viewport, sel.bottomRight(screen)) orelse return null;
    if (start) |pt| {
        if (pt.viewport.y >= term.rows) return null;
    }
    return .{
        .start_col = if (start) |pt| @intCast(pt.viewport.x) else 0,
        .start_row = if (start) |pt| @intCast(pt.viewport.y) else 0,
        .end_col = if (end.viewport.y >= term.rows) term.cols - 1 else @intCast(end.viewport.x),
        .end_row = @intCast(@min(end.viewport.y, term.rows - 1)),
    };
}

/// Refresh URL feedback against the current viewport; inactive clears it.
export fn mostty_tab_hover_url(tab_opt: ?*Tab, active: bool, col: u32, row: u32) bool {
    const tab = tab_opt orelse return false;
    tab.renderer.hovered_url = null;
    if (!active or viewportPin(tab, col, row) == null) return false;
    tab.renderer.hovered_url = url_hover.detectAt(tab.pty.terminal.term, @intCast(col), @intCast(row));
    return tab.renderer.hovered_url != null;
}

/// Re-detect at click time so opening never uses a stale hover target.
export fn mostty_tab_url_at(tab_opt: ?*Tab, col: u32, row: u32, buf: [*]u8, cap: usize) usize {
    const tab = tab_opt orelse return 0;
    if (viewportPin(tab, col, row) == null) return 0;
    const hit = url_hover.detectAt(tab.pty.terminal.term, @intCast(col), @intCast(row)) orelse return 0;
    const url = hit.url();
    if (url.len > cap) return 0;
    @memcpy(buf[0..url.len], url);
    return url.len;
}

export fn mostty_tab_destroy(tab_opt: ?*Tab) void {
    const tab = tab_opt orelse return;
    tab.pty.deinit();
    tab.renderer.deinit();
    allocator.destroy(tab);
}

/// The Metal device the renderer draws with. The on-screen layer must adopt
/// this device so it can present the renderer's target texture.
export fn mostty_tab_metal_device(tab_opt: ?*Tab) ?*anyopaque {
    const tab = tab_opt orelse return null;
    return tab.renderer.metal.device.value;
}

/// Bare read from the PTY master, waiting up to ~50ms for data. Safe to call
/// off the main thread; never touches VT state. Returns the byte count (>0), 0
/// on EOF/hangup, -1 on error, or -2 on timeout (the caller should re-check its
/// stop flag and call again). The timeout lets a background reader shut down
/// promptly without relying on close() to interrupt a blocked read.
export fn mostty_tab_read(tab_opt: ?*Tab, buf: [*]u8, cap: usize) isize {
    const tab = tab_opt orelse return -1;
    const fd = tab.pty.master_fd;
    if (fd < 0) return 0;

    var fds = [_]std.posix.pollfd{.{
        .fd = fd,
        .events = std.posix.POLL.IN,
        .revents = 0,
    }};
    const ready = std.posix.poll(&fds, 50) catch return -1;
    if (ready == 0) return -2;
    if (fds[0].revents & std.posix.POLL.IN == 0) {
        // No data pending; a hangup/error means EOF.
        return 0;
    }
    const count = std.posix.read(fd, buf[0..cap]) catch |err| switch (err) {
        error.WouldBlock => return -2,
        error.InputOutput => return 0,
        else => return -1,
    };
    if (count == 0) return 0;
    return @intCast(count);
}

/// Feed PTY bytes into the VT state machine. Main thread only.
export fn mostty_tab_feed(tab_opt: ?*Tab, ptr: [*]const u8, len: usize) void {
    const tab = tab_opt orelse return;
    tab.pty.terminal.feed(ptr[0..len]);
}

/// Write input bytes to the PTY master.
export fn mostty_tab_write(tab_opt: ?*Tab, ptr: [*]const u8, len: usize) void {
    const tab = tab_opt orelse return;
    tab.pty.write(ptr[0..len]) catch {};
}

/// Resize the drawable and propagate the new grid to PTY + VT. Writes the
/// resulting grid dimensions to `out_cols`/`out_rows`. Returns false on failure.
export fn mostty_tab_set_surface(
    tab_opt: ?*Tab,
    pixel_width: u32,
    pixel_height: u32,
    scale: f32,
    out_cols: *u32,
    out_rows: *u32,
) bool {
    const tab = tab_opt orelse return false;
    tab.renderer.resize(pixel_width, pixel_height, if (scale > 0) scale else 1) catch return false;
    const grid = tab.renderer.gridSize();
    if (grid.cols == 0 or grid.rows == 0) return false;
    tab.pty.resize(@intCast(grid.cols), @intCast(grid.rows)) catch return false;
    tab.pty.syncPixelSize(tab.renderer.metrics.cell_width, tab.renderer.metrics.cell_height) catch return false;
    tab.selection_input = null;
    out_cols.* = grid.cols;
    out_rows.* = grid.rows;
    return true;
}

/// Render the current terminal state and return the presentable Metal texture
/// (the renderer's target). Writes the rendered grid size to out params. When
/// `cursor_on` is set the block cursor is drawn, provided DECTCEM is enabled and
/// the viewport is at the bottom (host drives blink by toggling `cursor_on`).
export fn mostty_tab_render(tab_opt: ?*Tab, cursor_on: bool, out_cols: *u32, out_rows: *u32) ?*anyopaque {
    const tab = tab_opt orelse return null;
    const term = tab.pty.terminal.term;
    const screen = term.screens.active;

    // The cursor's authoritative position is its page pin. Convert it into
    // VIEWPORT coordinates — the same space GridModel iterates — so the drawn
    // block lines up with the glyph grid. `cursor.x`/`cursor.y` are active-area
    // coordinates, which differ from the viewport when scrollback is present.
    // A null result means the cursor is scrolled out of view.
    var cursor_cell: ?CoreTextRenderer.Cursor = null;
    if (cursor_on and term.modes.get(.cursor_visible) and screen.viewportIsBottom()) {
        if (screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*)) |pt| {
            cursor_cell = .{
                .col = @intCast(pt.viewport.x),
                .row = @intCast(pt.viewport.y),
            };
        }
    }

    tab.renderer.selection = visibleSelection(tab);
    const result = tab.renderer.render(&tab.pty.terminal, cursor_cell) catch return null;
    out_cols.* = result.cols;
    out_rows.* = result.rows;
    return result.texture;
}

/// Copy the tab's display title as UTF-8 into `buf`. The shell-provided title is
/// reduced to its final path component when it looks like a path (mirroring the
/// Windows tab bar); the full title stays canonical in the terminal. Returns the
/// byte count written (never exceeding `cap`), or 0 when there is no title or the
/// reduction is empty (root / trailing separator) — the caller then keeps the
/// previous label rather than blanking the tab.
export fn mostty_tab_title(tab_opt: ?*Tab, buf: [*]u8, cap: usize) usize {
    const tab = tab_opt orelse return 0;
    const title = tab.pty.terminal.term.getTitle() orelse return 0;
    const shown = title_mod.displayTitle(title);
    if (shown.len == 0) return 0;
    const n = @min(shown.len, cap);
    @memcpy(buf[0..n], shown[0..n]);
    return n;
}

/// Poll whether the child process has exited. Returns true once it has, writing
/// the exit status to `out_code` (negative values are `-signal`).
export fn mostty_tab_poll_exit(tab_opt: ?*Tab, out_code: *i32) bool {
    const tab = tab_opt orelse return false;
    if (tab.exit_code) |code| {
        out_code.* = code;
        return true;
    }
    const exit = tab.pty.tryWait() catch {
        // Child already reaped or wait failed: treat as exited.
        tab.exit_code = 0;
        out_code.* = 0;
        return true;
    };
    const result = exit orelse return false;
    const code: i32 = switch (result) {
        .exited => |v| v,
        .signaled => |sig| -@as(i32, @intCast(@intFromEnum(sig) & 0x7fff_ffff)),
        .stopped => return false,
        .unknown => -1,
    };
    tab.exit_code = code;
    out_code.* = code;
    return true;
}

/// Cell metrics in device pixels, so the host can map mouse points to grid
/// cells and translate wheel deltas to rows.
export fn mostty_tab_cell_size(tab_opt: ?*Tab, out_w: *u32, out_h: *u32) void {
    const tab = tab_opt orelse return;
    out_w.* = tab.renderer.metrics.cell_width;
    out_h.* = tab.renderer.metrics.cell_height;
}

export fn mostty_tab_mouse_enabled(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return mouse_report.enabled(tab.pty.terminal.term);
}

export fn mostty_tab_mouse(
    tab_opt: ?*Tab,
    action: u32,
    button: u32,
    mods: u32,
    x: i32,
    y: i32,
) void {
    const tab = tab_opt orelse return;
    const event: mouse_report.Event = .{
        .action = std.enums.fromInt(mouse_report.Action, action) orelse return,
        .button = if (button == 7) null else std.enums.fromInt(mouse_report.Button, button) orelse return,
        .mods = .{ .shift = mods & mod_shift != 0, .alt = mods & mod_alt != 0, .ctrl = mods & mod_ctrl != 0 },
        .pos = .{ .x = x, .y = y },
    };
    const term = tab.pty.terminal.term;
    var bytes: [64]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    mouse_report.encode(&writer, event, .{
        .event = term.flags.mouse_event,
        .format = term.flags.mouse_format,
        .grid = .{
            .cols = term.cols,
            .rows = term.rows,
            .cell_width = @intCast(tab.renderer.metrics.cell_width),
            .cell_height = @intCast(tab.renderer.metrics.cell_height),
        },
        .any_button_pressed = event.button != null,
        .last_cell = &tab.mouse_last_cell,
    }) catch return;
    if (writer.buffered().len > 0) tab.pty.write(writer.buffered()) catch {};
}

/// Cursor position in grid cells (column, row from the top of the viewport),
/// used to anchor the IME composition overlay and candidate window.
export fn mostty_tab_cursor(tab_opt: ?*Tab, out_col: *u32, out_row: *u32) void {
    const tab = tab_opt orelse return;
    // Convert the cursor's page pin into VIEWPORT coordinates, matching
    // mostty_tab_render, so the IME anchor and overlay cursor line up with the
    // glyph grid even when scrollback is present. Falls back to the origin when
    // the cursor is scrolled out of view.
    const screen = tab.pty.terminal.term.screens.active;
    if (screen.pages.pointFromPin(.viewport, screen.cursor.page_pin.*)) |pt| {
        out_col.* = @intCast(pt.viewport.x);
        out_row.* = @intCast(pt.viewport.y);
    } else {
        out_col.* = 0;
        out_row.* = 0;
    }
}

export fn mostty_tab_app_cursor_keys(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.cursor_keys);
}

export fn mostty_tab_app_keypad(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.keypad_keys);
}

export fn mostty_tab_bracketed_paste(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return false;
    return tab.pty.terminal.term.modes.get(.bracketed_paste);
}

/// DECTCEM: whether the text cursor should be shown.
export fn mostty_tab_cursor_visible(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return true;
    return tab.pty.terminal.term.modes.get(.cursor_visible);
}

/// Scroll the viewport by `delta_rows` (negative scrolls up into history,
/// positive scrolls down toward the active area).
export fn mostty_tab_scroll(tab_opt: ?*Tab, delta_rows: i32) void {
    const tab = tab_opt orelse return;
    tab.selection_input = null;
    tab.pty.terminal.term.scrollViewport(.{ .delta = @as(isize, delta_rows) });
}

const Scrollbar = extern struct {
    total: u64,
    offset: u64,
    visible: u64,
};

export fn mostty_tab_scrollbar(tab_opt: ?*Tab) Scrollbar {
    const tab = tab_opt orelse return .{ .total = 0, .offset = 0, .visible = 0 };
    const sb = tab.pty.terminal.term.screens.active.pages.scrollbar();
    return .{ .total = sb.total, .offset = sb.offset, .visible = sb.len };
}

export fn mostty_tab_scroll_to_row(tab_opt: ?*Tab, row: u64) void {
    const tab = tab_opt orelse return;
    tab.selection_input = null;
    const sb = mostty_tab_scrollbar(tab);
    const max_offset = sb.total -| sb.visible;
    tab.pty.terminal.term.scrollViewport(if (row >= max_offset)
        .bottom
    else
        .{ .row = @intCast(row) });
}

export fn mostty_tab_scroll_to_bottom(tab_opt: ?*Tab) void {
    const tab = tab_opt orelse return;
    tab.selection_input = null;
    tab.pty.terminal.term.scrollViewport(.{ .bottom = {} });
}

/// True when the viewport is pinned to the bottom (follow mode active).
export fn mostty_tab_at_bottom(tab_opt: ?*Tab) bool {
    const tab = tab_opt orelse return true;
    return tab.pty.terminal.term.screens.active.viewportIsBottom();
}

/// Copy the current VT selection as UTF-8. A zero capacity queries the required
/// byte count; an undersized buffer returns zero without splitting text.
export fn mostty_tab_selection_text(tab_opt: ?*Tab, buf: [*]u8, cap: usize) usize {
    const tab = tab_opt orelse return 0;
    const screen = tab.pty.terminal.term.screens.active;
    const sel = screen.selection orelse return 0;
    const text = screen.selectionString(allocator, .{ .sel = sel }) catch return 0;
    defer allocator.free(text);
    if (cap == 0) return text.len;
    if (text.len > cap) return 0;
    @memcpy(buf[0..text.len], text);
    return text.len;
}

comptime {
    _ = @import("../input_capi.zig");
}

test "bridge feeds content, renders a texture, and reports mode/selection" {
    // Exercises the full C-ABI path a Swift host drives: a live session (PTY +
    // renderer + Metal device), feeding VT bytes, rendering to a texture, mode
    // queries, and selection extraction. Feeding directly (without reading the
    // PTY) keeps the visible content deterministic.
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);

    try std.testing.expect(mostty_tab_metal_device(tab) != null);
    try std.testing.expect(mostty_tab_at_bottom(tab));
    try std.testing.expect(!mostty_tab_app_cursor_keys(tab));
    try std.testing.expect(!mostty_tab_app_keypad(tab));
    try std.testing.expect(!mostty_tab_bracketed_paste(tab));

    const line = "hello world";
    mostty_tab_feed(tab, line.ptr, line.len);

    var cols: u32 = 0;
    var rows: u32 = 0;
    const texture = mostty_tab_render(tab, true, &cols, &rows);
    try std.testing.expect(texture != null);
    try std.testing.expect(cols > 0 and rows > 0);

    var out: [64]u8 = undefined;
    mostty_tab_set_selection(tab, true, 0, 0, @intCast(line.len - 1), 0);
    const n = mostty_tab_selection_text(tab, &out, out.len);
    try std.testing.expectEqualStrings(line, out[0..n]);

    // Terminal modes drive input encoding; verify they track VT state.
    mostty_tab_feed(tab, "\x1b[?1h", 5);
    try std.testing.expect(mostty_tab_app_cursor_keys(tab));
    mostty_tab_feed(tab, "\x1b=", 2);
    try std.testing.expect(mostty_tab_app_keypad(tab));
    mostty_tab_feed(tab, "\x1b>", 2);
    try std.testing.expect(!mostty_tab_app_keypad(tab));
    mostty_tab_feed(tab, "\x1b[?2004h", 8);
    try std.testing.expect(mostty_tab_bracketed_paste(tab));
}

test "scrollbar offsets select actual history rows and bottom restores output following" {
    const tab = mostty_tab_create(320, 160, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    const initial = mostty_tab_scrollbar(tab);
    try std.testing.expectEqual(initial.visible, initial.total);
    try std.testing.expectEqual(@as(u64, 0), initial.offset);
    try std.testing.expectEqual(@as(u64, 0), mostty_tab_scrollbar(null).total);
    mostty_tab_scroll_to_row(null, 123);
    mostty_tab_scroll_to_row(tab, std.math.maxInt(u64));
    try std.testing.expect(mostty_tab_at_bottom(tab));

    for (0..100) |i| {
        var buf: [16]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "{d:0>3}\r\n", .{i});
        mostty_tab_feed(tab, line.ptr, line.len);
    }
    var state = mostty_tab_scrollbar(tab);
    try std.testing.expectEqual(@as(u64, 101), state.total);
    try std.testing.expectEqual(state.total - state.visible, state.offset);

    for ([_]u64{ 0, (state.total - state.visible) / 2, state.total - state.visible }) |row| {
        mostty_tab_scroll_to_row(tab, row);
        state = mostty_tab_scrollbar(tab);
        try std.testing.expectEqual(row, state.offset);
        mostty_tab_set_selection(tab, true, 0, 0, 2, 0);
        var text: [16]u8 = undefined;
        const len = mostty_tab_selection_text(tab, &text, text.len);
        var expected: [16]u8 = undefined;
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "{d:0>3}", .{row}), text[0..len]);
    }
    mostty_tab_set_selection(tab, false, 0, 0, 0, 0);
    mostty_tab_scroll_to_row(tab, 20);
    mostty_tab_feed(tab, "100\r\n", 5);
    try std.testing.expectEqual(@as(u64, 20), mostty_tab_scrollbar(tab).offset);
    mostty_tab_scroll(tab, -5);
    try std.testing.expectEqual(@as(u64, 15), mostty_tab_scrollbar(tab).offset);
    mostty_tab_scroll_to_row(tab, std.math.maxInt(u64));
    try std.testing.expect(mostty_tab_at_bottom(tab));
    mostty_tab_feed(tab, "101\r\n", 5);
    state = mostty_tab_scrollbar(tab);
    try std.testing.expectEqual(state.total - state.visible, state.offset);

    mostty_tab_scroll_to_row(tab, 20);
    mostty_tab_feed(tab, "\x1b[?1049h", 8);
    state = mostty_tab_scrollbar(tab);
    try std.testing.expectEqual(state.visible, state.total);
    mostty_tab_scroll_to_row(tab, 500);
    try std.testing.expectEqual(@as(u64, 0), mostty_tab_scrollbar(tab).offset);
    mostty_tab_feed(tab, "\x1b[?1049l", 8);
    try std.testing.expectEqual(@as(u64, 20), mostty_tab_scrollbar(tab).offset);

    var cols: u32 = 0;
    var rows: u32 = 0;
    try std.testing.expect(mostty_tab_set_surface(tab, 320, 240, 1, &cols, &rows));
    state = mostty_tab_scrollbar(tab);
    try std.testing.expectEqual(@as(u64, rows), state.visible);
    try std.testing.expect(state.offset <= state.total - state.visible);
}

test "live output keeps copy anchored when the host republishes stale viewport selection" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    try tab.pty.terminal.resize(5, 4);

    const initial = "one\r\ntwo\r\nthree\r\nfour";
    mostty_tab_feed(tab, initial.ptr, initial.len);
    mostty_tab_set_selection(tab, true, 0, 1, 2, 1);

    // Follow mode scrolls the selected row into history as new output arrives.
    const update = "\r\nfive";
    mostty_tab_feed(tab, update.ptr, update.len);

    // A mouse-up callback can still carry the pre-scroll viewport coordinates.
    // It must not replace the tracked selection with the newly visible row.
    mostty_tab_set_selection(tab, true, 0, 1, 2, 1);

    var out: [16]u8 = undefined;
    const n = mostty_tab_selection_text(tab, &out, out.len);
    try std.testing.expectEqualStrings("two", out[0..n]);
    try std.testing.expectEqual(GridModel.Selection{
        .start_col = 0,
        .start_row = 0,
        .end_col = 2,
        .end_row = 0,
    }, visibleSelection(tab).?);
}

test "bridge mouse writes negotiated encodings and suppresses disabled and duplicate motion" {
    const tab = mostty_tab_create(640, 480, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    var pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&pipe));
    defer _ = std.c.close(pipe[0]);
    defer _ = std.c.close(pipe[1]);
    const original = tab.pty.master_fd;
    tab.pty.master_fd = pipe[1];
    defer tab.pty.master_fd = original;
    const flags: std.c.O = .{ .NONBLOCK = true };
    try std.testing.expect(std.c.fcntl(pipe[0], std.c.F.SETFL, @as(c_int, @bitCast(flags))) >= 0);

    const cw: i32 = @intCast(tab.renderer.metrics.cell_width);
    const ch: i32 = @intCast(tab.renderer.metrics.cell_height);
    const cases = .{
        .{ "\x1b[?1000h", @as(u32, 0), @as(u32, 0), "\x1b[M !\"" },
        .{ "\x1b[?1005h", @as(u32, 0), @as(u32, 2), "\x1b[M\"!\"" },
        .{ "\x1b[?1006h", @as(u32, 0), @as(u32, 1), "\x1b[<1;1;2M" },
        .{ "", @as(u32, 1), @as(u32, 1), "\x1b[<1;1;2m" },
        .{ "\x1b[?1002h", @as(u32, 2), @as(u32, 0), "\x1b[<32;1;2M" },
        .{ "", @as(u32, 0), @as(u32, 3), "\x1b[<64;1;2M" },
    };
    var out: [64]u8 = undefined;
    inline for (cases) |case| {
        tab.pty.terminal.feed(case[0]);
        tab.mouse_last_cell = null;
        mostty_tab_mouse(tab, case[1], case[2], 0, 1, ch + 1);
        const count = try std.posix.read(pipe[0], &out);
        try std.testing.expectEqualStrings(case[3], out[0..count]);
    }
    mostty_tab_mouse(tab, 2, 0, 0, 1, ch + 1);
    try std.testing.expectError(error.WouldBlock, std.posix.read(pipe[0], &out));
    tab.pty.terminal.feed("\x1b[?1003h\x1b[?1016h");
    mostty_tab_mouse(tab, 2, 7, mod_alt | mod_ctrl, cw + 1, ch + 1);
    var expected: [64]u8 = undefined;
    const pixel_report = try std.fmt.bufPrint(&expected, "\x1b[<59;{d};{d}M", .{ cw + 1, ch + 1 });
    const count = try std.posix.read(pipe[0], &out);
    try std.testing.expectEqualStrings(pixel_report, out[0..count]);
    tab.pty.terminal.feed("\x1b[?1003l");
    try std.testing.expect(!mostty_tab_mouse_enabled(tab));
    mostty_tab_mouse(tab, 0, 0, 0, 1, 1);
    try std.testing.expectError(error.WouldBlock, std.posix.read(pipe[0], &out));
}

test "vim receives mouse clicks and drags from the macOS bridge" {
    const command =
        "exec /usr/bin/vim -Nu NONE -i NONE -n " ++
        "-c 'set mouse=a ttymouse=sgr title' " ++
        "-c 'call setline(1, [\"alpha\", \"bravo\", \"charlie\"])' " ++
        "-c \"set titlestring=MOUSE_%{line('.')}_%{col('.')}\"";
    const tab = mostty_tab_create_with_launcher(640, 480, 1, command, "") orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    try waitForTestTitle(tab, "MOUSE_1_1");
    try std.testing.expect(mostty_tab_mouse_enabled(tab));
    const cw: i32 = @intCast(tab.renderer.metrics.cell_width);
    const ch: i32 = @intCast(tab.renderer.metrics.cell_height);
    mostty_tab_mouse(tab, 0, 0, 0, 2 * cw + 1, ch + 1);
    try waitForTestTitle(tab, "MOUSE_2_3");
    mostty_tab_mouse(tab, 2, 0, 0, 4 * cw + 1, 2 * ch + 1);
    try waitForTestTitle(tab, "MOUSE_3_5");
    mostty_tab_mouse(tab, 1, 0, 0, 4 * cw + 1, 2 * ch + 1);
}

fn waitForTestTitle(tab: *Tab, expected: []const u8) !void {
    var bytes: [4096]u8 = undefined;
    for (0..100) |_| {
        if (tab.pty.terminal.term.getTitle()) |title| {
            if (std.mem.eql(u8, title, expected)) return;
        }
        const count = mostty_tab_read(tab, &bytes, bytes.len);
        if (count > 0) mostty_tab_feed(tab, &bytes, @intCast(count));
        if (count == 0 or count == -1) break;
    }
    std.debug.print("expected title {s}, received {s}\n", .{ expected, tab.pty.terminal.term.getTitle() orelse "<none>" });
    const dump = try tab.pty.terminal.term.plainString(std.testing.allocator);
    defer std.testing.allocator.free(dump);
    std.debug.print("{s}\n", .{dump});
    return error.TestExpectedEqual;
}

test "selection copy unwraps soft lines and includes a wide character from its right half" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    try tab.pty.terminal.resize(6, 4);

    const cases = .{
        .{ "abcdefghi", 0, 0, 2, 1, "abcdefghi" },
        .{ "abc\r\ndef", 0, 0, 2, 1, "abc\ndef" },
        .{ "\u{4e2d}\u{6587}", 1, 0, 1, 0, "\u{4e2d}" },
        .{ "e\u{301}", 0, 0, 0, 0, "e\u{301}" },
        .{ "abcdefghi", 2, 1, 0, 0, "abcdefghi" },
    };
    inline for (cases) |case| {
        tab.pty.terminal.feed("\x1b[2J\x1b[H" ++ case[0]);
        var out: [128]u8 = undefined;
        mostty_tab_set_selection(tab, true, case[1], case[2], case[3], case[4]);
        const n = mostty_tab_selection_text(tab, &out, out.len);
        try std.testing.expectEqualStrings(case[5], out[0..n]);
    }
}

test "double click uses Windows token boundaries and VT text across wraps" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    const cases = .{
        .{ 80, "https://example.com/a-b?q=v", 10, 0, "https://example.com/a-b?q=v" },
        .{ 80, "/usr/local/my_file $HOME key:value", 8, 0, "/usr/local/my_file" },
        .{ 80, "/usr/local/my_file $HOME key:value", 19, 0, "$HOME" },
        .{ 80, "/usr/local/my_file $HOME key:value", 25, 0, "key:value" },
        .{ 80, "user@host", 1, 0, "user" },
        .{ 80, "user@host", 6, 0, "host" },
        .{ 80, "\u{4e2d}\u{6587}\u{ff0c}\u{6d4b}\u{8bd5}", 3, 0, "\u{4e2d}\u{6587}" },
        .{ 80, "\u{4e2d}\u{6587}\u{ff0c}\u{6d4b}\u{8bd5}", 7, 0, "\u{6d4b}\u{8bd5}" },
        .{ 80, "e\u{301}lan", 0, 0, "e\u{301}lan" },
        .{ 80, "a b", 0, 0, "a" },
        .{ 80, "", 0, 0, "" },
        .{ 6, "abcdefghi", 1, 1, "abcdefghi" },
        .{ 6, "abcdef\r\nghi", 5, 0, "abcdef" },
        .{ 5, "abcd\u{ff0c}z", 2, 0, "abcd" },
        .{ 5, "abcd\u{4e2d}\u{6587}", 1, 1, "abcd\u{4e2d}\u{6587}" },
    };
    inline for (cases) |case| {
        mostty_tab_set_selection(tab, false, 0, 0, 0, 0);
        tab.pty.terminal.feed("\x1b[2J\x1b[H");
        try tab.pty.terminal.resize(case[0], 4);
        tab.pty.terminal.feed(case[1]);
        try std.testing.expect(mostty_tab_select_word(tab, case[2], case[3]));
        var out: [128]u8 = undefined;
        const size = mostty_tab_selection_text(tab, &out, 0);
        try std.testing.expectEqual(case[4].len, size);
        const n = mostty_tab_selection_text(tab, &out, out.len);
        try std.testing.expectEqualStrings(case[4], out[0..n]);
        try std.testing.expect(visibleSelection(tab) != null);
    }
    try std.testing.expect(!mostty_tab_select_word(tab, 999, 0));
    var out: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_selection_text(tab, &out, out.len));
}

test "word selection includes offscreen wrapped text and clips only its highlight" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    try tab.pty.terminal.resize(6, 2);
    tab.pty.terminal.feed("abcdefghijklmnop");
    try std.testing.expect(mostty_tab_select_word(tab, 1, 0));
    var out: [64]u8 = undefined;
    const n = mostty_tab_selection_text(tab, &out, out.len);
    try std.testing.expectEqualStrings("abcdefghijklmnop", out[0..n]);
    try std.testing.expectEqual(GridModel.Selection{
        .start_col = 0,
        .start_row = 0,
        .end_col = 3,
        .end_row = 1,
    }, visibleSelection(tab).?);
    // Copy must never return a partial UTF-8/grapheme sequence on capacity failure.
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_selection_text(tab, &out, 3));
    mostty_tab_set_selection(tab, false, 0, 0, 0, 0);
    try std.testing.expect(visibleSelection(tab) == null);
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_selection_text(tab, &out, 0));
}

test "URL bridge detects wrapped URLs and refreshes the click target" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    try tab.pty.terminal.resize(12, 4);
    const url = "https://example.test/a";
    tab.pty.terminal.feed("See " ++ url ++ " end");
    try std.testing.expect(mostty_tab_hover_url(tab, true, 3, 1));
    try std.testing.expectEqualStrings(url, tab.renderer.hovered_url.?.url());
    var out: [128]u8 = undefined;
    const n = mostty_tab_url_at(tab, 3, 1, &out, out.len);
    try std.testing.expectEqualStrings(url, out[0..n]);
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_url_at(tab, 3, 1, &out, 4));
    tab.pty.terminal.feed("\x1b[2J\x1b[Hhttp://new.test/ end");
    const changed = mostty_tab_url_at(tab, 3, 0, &out, out.len);
    try std.testing.expectEqualStrings("http://new.test/", out[0..changed]);
    try std.testing.expect(!mostty_tab_hover_url(tab, false, 3, 0));
    try std.testing.expect(tab.renderer.hovered_url == null);
    try std.testing.expect(!mostty_tab_hover_url(tab, true, 999, 0));
    tab.pty.terminal.feed("\x1b[2J\x1b[Hplain text");
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_url_at(tab, 3, 0, &out, out.len));
    try std.testing.expect(!mostty_tab_hover_url(tab, true, 3, 0));
}

test "URL hover changes rendered underline pixels and clears them on leave" {
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    tab.pty.terminal.feed("http://x.test/a");
    var cols: u32 = 0;
    var rows: u32 = 0;
    try std.testing.expect(mostty_tab_render(tab, false, &cols, &rows) != null);
    const plain = try std.testing.allocator.dupe(u8, tab.renderer.pixels);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(mostty_tab_hover_url(tab, true, 2, 0));
    try std.testing.expect(mostty_tab_render(tab, false, &cols, &rows) != null);
    try std.testing.expect(!std.mem.eql(u8, plain, tab.renderer.pixels));
    try std.testing.expect(!mostty_tab_hover_url(tab, false, 0, 0));
    try std.testing.expect(mostty_tab_render(tab, false, &cols, &rows) != null);
    try std.testing.expectEqualSlices(u8, plain, tab.renderer.pixels);
}

test "config colors decide the rendered defaults and palette entries" {
    // MOSTTY-58 acceptance: `background` / `foreground` / `palette` must change
    // what the terminal draws. Tab creation seeds the VT from the config theme,
    // so this asserts that composition rather than the hard-coded fallbacks.
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);

    var cfg = Config.parse(allocator,
        \\background = 102040
        \\foreground = e0d0a0
        \\palette = 1=ff8800
        \\
    , "test");
    defer cfg.deinit();
    cfg.theme.applyToNewTerminal(tab.pty.terminal.term);

    const content = "A\x1b[31mB";
    mostty_tab_feed(tab, content.ptr, content.len);

    var frame = try GridModel.build(allocator, tab.pty.terminal.term, .{
        .metrics = tab.renderer.metrics,
        .pixel_width = tab.renderer.pixel_width,
        .pixel_height = tab.renderer.contentHeight(),
    });
    defer frame.deinit();

    var background = GridModel.Rgba.fromRgb(0x10, 0x20, 0x40);
    background.a = alphaFromOpacity(cfg.background_opacity);
    try std.testing.expectEqual(background, frame.background);
    const plain = frameCell(frame, 0, 0);
    try std.testing.expectEqual(GridModel.Rgba.fromRgb(0xe0, 0xd0, 0xa0), plain.style.foreground);
    try std.testing.expectEqual(background, plain.style.background);
    // SGR 31 is palette slot 1, so it must resolve through the configured value.
    try std.testing.expectEqual(
        GridModel.Rgba.fromRgb(0xff, 0x88, 0x00),
        frameCell(frame, 1, 0).style.foreground,
    );
}

fn frameCell(frame: GridModel.Frame, col: u16, row: u16) GridModel.Cell {
    for (frame.cells) |cell| {
        if (cell.col == col and cell.row == row) return cell;
    }
    unreachable;
}

test "omitted macOS settings reach the renderer and host from Config defaults" {
    const defaults: Config = .{};
    for ([_][]const u8{ "", "font-family =\nfont-size = invalid\nbackground-opacity = invalid\n" }) |source| {
        var cfg = Config.parse(allocator, source, "test");
        defer cfg.deinit();
        const font = fontOptions(&cfg);
        try std.testing.expectEqual(defaults.font_size_pt, @as(?f32, font.size));
        try std.testing.expectEqualStrings(defaults.font_families[0], font.family);
        try std.testing.expectEqualStrings(defaults.font_family_bold, font.family_bold);
        try std.testing.expectEqualStrings(defaults.font_family_italic, font.family_italic);
        try std.testing.expectEqualStrings(defaults.font_family_bold_italic, font.family_bold_italic);
        const paint = paintOptions(&cfg);
        try std.testing.expectEqual(alphaFromOpacity(defaults.background_opacity), paint.background_alpha);
        try std.testing.expectEqual(optionalRgba(cfg.theme.selection_background), paint.selection_background);
        try std.testing.expectEqual(optionalRgba(cfg.theme.selection_foreground), paint.selection_foreground);
        try std.testing.expectEqual(optionalRgba(cfg.theme.cursor_text), paint.cursor_text);

        const previous = loaded_config;
        loaded_config = cfg;
        defer loaded_config = previous;
        try std.testing.expectEqual(defaults.background_opacity, mostty_config_background_opacity());
        try std.testing.expectEqual(defaults.background_blur, mostty_config_background_blur());
        try std.testing.expectEqual(defaults.maximize, mostty_config_maximize());
        try std.testing.expectEqual(defaults.fullscreen, mostty_config_fullscreen());
        try std.testing.expectEqual(defaults.render_interval_local_ms, mostty_config_render_interval_ms());
    }
}

test "font keys reach the renderer, and their absence falls back to the platform default" {
    // MOSTTY-58: `font-family` / `font-size` must decide what the renderer
    // builds. The rule when a key is absent is the documented macOS default, not
    // a literal duplicated in the host layer.
    var configured = Config.parse(allocator,
        \\font-family = Iosevka, Ignored Fallback
        \\font-family-bold = Iosevka Heavy
        \\font-size = 17.5
        \\
    , "test");
    defer configured.deinit();
    const options = fontOptions(&configured);
    try std.testing.expectEqualStrings("Iosevka", options.family);
    try std.testing.expectEqualStrings("Iosevka Heavy", options.family_bold);
    try std.testing.expectEqual(@as(f32, 17.5), options.size);
    // Unset per-style families stay empty so the renderer synthesizes them.
    try std.testing.expectEqual(@as(usize, 0), options.family_italic.len);

    var empty = Config.parse(allocator, "", "test");
    defer empty.deinit();
    const defaults = fontOptions(&empty);
    try std.testing.expectEqualStrings((Config{}).font_families[0], defaults.family);
    try std.testing.expectEqual((Config{}).font_size_pt.?, defaults.size);
}

test "default config reaches a real renderer's font and pixel alpha" {
    var cfg = Config.parse(allocator, "", "test");
    defer cfg.deinit();
    const previous = loaded_config;
    loaded_config = cfg;
    defer loaded_config = previous;
    const tab = try createTab(320, 96, 1, null);
    defer mostty_tab_destroy(tab);
    try std.testing.expectEqual((Config{}).font_size_pt.?, tab.renderer.font_size);
    try std.testing.expectEqualStrings((Config{}).font_families[0], tab.renderer.families.names[0]);
    _ = try tab.renderer.render(&tab.pty.terminal, null);
    // A blank terminal has no foreground ink, so every pixel carries the
    // configured background alpha, including the reserved bottom gutter.
    const alpha = alphaFromOpacity((Config{}).background_opacity);
    var index: usize = 3;
    while (index < tab.renderer.pixels.len) : (index += 4) {
        try std.testing.expectEqual(alpha, tab.renderer.pixels[index]);
    }
}

test "background-opacity and selection colors reach the renderer's paint options" {
    var cfg = Config.parse(allocator,
        \\background-opacity = 0.8
        \\selection-background = 205020
        \\selection-foreground = ffffff
        \\
    , "test");
    defer cfg.deinit();
    const paint = paintOptions(&cfg);
    // 0.8 of full opacity, rounded to the 8-bit channel the renderer writes.
    try std.testing.expectEqual(@as(u8, 204), paint.background_alpha);
    try std.testing.expectEqual(GridModel.Rgba.fromRgb(0x20, 0x50, 0x20), paint.selection_background.?);
    try std.testing.expectEqual(GridModel.Rgba.fromRgb(0xff, 0xff, 0xff), paint.selection_foreground.?);

    // `cursor-text` is a pure paint value, while `cursor-color` deliberately is
    // not: it is seeded into the terminal so OSC 12 can still override it.
    var cursor_cfg = Config.parse(allocator,
        \\cursor-color = ff0000
        \\cursor-text = 00ff00
        \\
    , "test");
    defer cursor_cfg.deinit();
    try std.testing.expectEqual(
        GridModel.Rgba.fromRgb(0x00, 0xff, 0x00),
        paintOptions(&cursor_cfg).cursor_text.?,
    );

    // The default config is nearly opaque but not fully, and leaves the
    // selection colors unset so the renderer falls back to inverse video.
    var defaults = Config.parse(allocator, "", "test");
    defer defaults.deinit();
    const default_paint = paintOptions(&defaults);
    try std.testing.expectEqual(alphaFromOpacity(defaults.background_opacity), default_paint.background_alpha);
    try std.testing.expectEqual(@as(?GridModel.Rgba, null), default_paint.selection_background);
    try std.testing.expectEqual(@as(?GridModel.Rgba, null), default_paint.selection_foreground);
    try std.testing.expectEqual(@as(?GridModel.Rgba, null), default_paint.cursor_text);
}

test "opacity maps onto the full alpha range and clamps out-of-range values" {
    try std.testing.expectEqual(@as(u8, 255), alphaFromOpacity(1));
    try std.testing.expectEqual(@as(u8, 0), alphaFromOpacity(0));
    try std.testing.expectEqual(@as(u8, 255), alphaFromOpacity(2));
    try std.testing.expectEqual(@as(u8, 0), alphaFromOpacity(-1));
}

test "launcherCommand replaces the login shell only when a command line is set" {
    // A launcher with an empty command-line segment still contributes its
    // working directory, so it must not be mistaken for "run nothing".
    for ([_][]const u8{ "", "launcher = Shell | | /usr\n" }) |source| {
        var cfg = Config.parse(allocator, source, "test");
        defer cfg.deinit();
        const launcher = if (cfg.launchers.len > 0) &cfg.launchers[0] else null;
        try std.testing.expectEqual(@as(?[:0]u8, null), try launcherCommand(launcher));
    }

    var cfg = Config.parse(allocator, "launcher = Shell | htop -d 5 | /usr\n", "test");
    defer cfg.deinit();
    const command = try launcherCommand(&cfg.launchers[0]) orelse return error.TestUnexpectedResult;
    defer allocator.free(command);
    try std.testing.expectEqualStrings("htop -d 5", command);
}

test "initialWorkingDirectory uses the first launcher's directory when set" {
    // MOSTTY-51: a configured launcher directory wins over $HOME.
    var cfg = Config.parse(allocator, "launcher = My Shell | /bin/zsh | /usr\n", "test");
    defer cfg.deinit();
    const wd = try initialWorkingDirectory(&cfg.launchers[0]) orelse return error.TestUnexpectedResult;
    defer allocator.free(wd);
    try std.testing.expectEqualStrings("/usr", wd);
}

test "initialWorkingDirectory falls back to $HOME without a configured directory" {
    // No launcher, and a launcher with an empty directory, both resolve to $HOME.
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.SkipZigTest);
    if (home.len == 0) return error.SkipZigTest;
    for ([_][]const u8{ "", "launcher = My Shell | /bin/zsh |\n" }) |src| {
        var cfg = Config.parse(allocator, src, "test");
        defer cfg.deinit();
        const launcher = if (cfg.launchers.len > 0) &cfg.launchers[0] else null;
        const wd = try initialWorkingDirectory(launcher) orelse return error.TestUnexpectedResult;
        defer allocator.free(wd);
        try std.testing.expectEqualStrings(home, wd);
    }
}

test "launcher menu exposes each configured choice and uses its command and directory" {
    var cfg = Config.parse(allocator, "launcher = First | echo first | /usr\nlauncher = Second | echo second | /var\nconfirm-close-surface = false\n", "test");
    defer cfg.deinit();
    const previous = loaded_config;
    loaded_config = cfg;
    defer loaded_config = previous;
    try std.testing.expect(!mostty_config_confirm_close());
    try std.testing.expectEqual(@as(usize, 2), mostty_config_launcher_count());
    var buf: [64]u8 = undefined;
    const n = mostty_config_launcher_text(1, 0, &buf, buf.len);
    try std.testing.expectEqualStrings("Second", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 6), mostty_config_launcher_text(1, 0, &buf, 0));
    try std.testing.expectEqual(@as(usize, 0), mostty_config_launcher_text(1, 0, &buf, 1));
    try std.testing.expectEqual(@as(usize, 0), mostty_config_launcher_text(2, 0, &buf, buf.len));
    const command = (try launcherCommand(&cfg.launchers[1])).?;
    defer allocator.free(command);
    const directory = (try initialWorkingDirectory(&cfg.launchers[1])).?;
    defer allocator.free(directory);
    try std.testing.expectEqualStrings("echo second", command);
    try std.testing.expectEqualStrings("/var", directory);
}

test "launcher bridge starts the chosen command in its directory and reports natural exit" {
    const tab = mostty_tab_create_with_launcher(640, 240, 1, "printf 'launcher-ok:'; pwd", "/usr") orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);
    var buffer: [4096]u8 = undefined;
    var eof = false;
    for (0..200) |_| {
        const n = mostty_tab_read(tab, &buffer, buffer.len);
        if (n == -2) continue;
        if (n <= 0) {
            eof = true;
            break;
        }
        mostty_tab_feed(tab, &buffer, @intCast(n));
    }
    try std.testing.expect(eof);
    const contents = try tab.pty.terminal.term.plainString(allocator);
    defer allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "launcher-ok:/usr") != null);
    _ = try tab.pty.wait();
    var code: i32 = undefined;
    try std.testing.expect(mostty_tab_poll_exit(tab, &code));
}

test "theme choice rebases all sessions while preserving explicit config and OSC colors" {
    const previous = loaded_config;
    loaded_config = Config.parse(allocator, "foreground = #010203\n", "test");
    defer {
        loaded_config.?.deinit();
        loaded_config = previous;
    }
    const first = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(first);
    const second = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(second);
    const osc = "\x1b]11;#778899\x07";
    mostty_tab_feed(second, osc.ptr, osc.len);
    const path = try std.Io.Dir.cwd().realPathFileAlloc(runtimeIo(), "tests/macos/interaction-theme", allocator);
    defer allocator.free(path);
    try std.testing.expect(mostty_config_select_theme(path));
    for ([_]*Tab{ first, second }) |tab| {
        _ = mostty_tab_apply_config(tab);
        try std.testing.expectEqual(Config.u24ToRgb(0x010203), tab.pty.terminal.term.colors.foreground.get().?);
        try std.testing.expectEqual(Config.u24ToRgb(0xbb2200), tab.pty.terminal.term.colors.palette.current[1]);
        try std.testing.expectEqual(optionalRgba(0x345678), tab.renderer.paint.selection_background);
    }
    try std.testing.expectEqual(Config.u24ToRgb(0x123456), first.pty.terminal.term.colors.background.get().?);
    try std.testing.expectEqual(Config.u24ToRgb(0x778899), second.pty.terminal.term.colors.background.get().?);
    const before = config().theme;
    try std.testing.expect(!mostty_config_select_theme("/MOSTTY-61-nonexistent-theme"));
    try std.testing.expectEqualDeep(before, config().theme);
}

test "mostty_tab_title mirrors the Windows path-basename rule" {
    // The tab must read as the current directory name, not the whole path: an
    // OSC-2 path title is reduced to its final component (Windows parity), a
    // non-path title passes through, and a filesystem root reduces to empty so
    // the caller keeps the previous label instead of blanking the tab.
    const tab = mostty_tab_create(320, 96, 1) orelse return error.TabCreateFailed;
    defer mostty_tab_destroy(tab);

    var buf: [256]u8 = undefined;

    const path_title = "\x1b]2;/Users/foo/Development/mostty\x07";
    mostty_tab_feed(tab, path_title.ptr, path_title.len);
    const n_path = mostty_tab_title(tab, &buf, buf.len);
    try std.testing.expectEqualStrings("mostty", buf[0..n_path]);

    const prog_title = "\x1b]2;node\x07";
    mostty_tab_feed(tab, prog_title.ptr, prog_title.len);
    const n_prog = mostty_tab_title(tab, &buf, buf.len);
    try std.testing.expectEqualStrings("node", buf[0..n_prog]);

    const root_title = "\x1b]2;/\x07";
    mostty_tab_feed(tab, root_title.ptr, root_title.len);
    try std.testing.expectEqual(@as(usize, 0), mostty_tab_title(tab, &buf, buf.len));
}
