const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../../Config.zig");
const err_mod = @import("../error.zig");
const global_mod = @import("../global.zig");
const paste = @import("../paste.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const window_geom = @import("../window_geom.zig");

const Error = err_mod.Error;
const ReadMsg = types.ReadMsg;
const global = global_mod.global;

// Bounded retries when a config reload hits a transiently-locked file (editor
// mid-save). Reset to 0 on every successful reload.
var config_reload_retries: u32 = 0;
const config_reload_max_retries: u32 = 3;

pub fn onTimer(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (wparam == types.TIMER_SELECTION_FADE) {
        const window = global_mod.windowFromHwnd(hwnd);
        window.selection_fade -= 0.05;
        if (window.selection_fade <= 0) {
            window.selection_fade = 0;
            _ = win32.KillTimer(hwnd, types.TIMER_SELECTION_FADE);
            window.active().term.screens.active.clearSelection();
        }
        window.requestRender();
    }
    if (wparam == types.TIMER_CONFIG_RELOAD) {
        _ = win32.KillTimer(hwnd, types.TIMER_CONFIG_RELOAD);
        reloadConfig(hwnd);
    }
    if (wparam == types.TIMER_TEXT_BLINK) {
        const window = global_mod.windowFromHwnd(hwnd);
        window.requestRender();
    }
    return 0;
}

// The watcher thread posts this for every change to the config directory.
// Arm (or re-arm) a one-shot debounce timer rather than reloading inline:
// re-arming on each notification coalesces the burst an editor emits on save.
pub fn onAppConfigChanged(hwnd: win32.HWND, _: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    _ = win32.SetTimer(hwnd, types.TIMER_CONFIG_RELOAD, types.CONFIG_RELOAD_DEBOUNCE_MS, null);
    return 0;
}

// Windows broadcasts WM_SETTINGCHANGE for many settings; lParam names which one.
// "ImmersiveColorSet" signals a light/dark (or accent) change. Re-arm the same
// debounced reload so a `theme = light:..,dark:..` config re-picks its variant
// for the new OS mode — reloadConfig re-parses, which re-reads systemPrefersDark().
pub fn onSettingChange(hwnd: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    if (lparamEqlAscii(lparam, "ImmersiveColorSet")) {
        _ = win32.SetTimer(hwnd, types.TIMER_CONFIG_RELOAD, types.CONFIG_RELOAD_DEBOUNCE_MS, null);
    }
    return null; // let DefWindowProcW also run
}

// True if the WM_SETTINGCHANGE lParam (a wide, NUL-terminated string under the
// W message loop) equals the given ASCII name.
fn lparamEqlAscii(lparam: win32.LPARAM, ascii: []const u8) bool {
    if (lparam == 0) return false;
    const ptr: [*:0]const u16 = @ptrFromInt(@as(usize, @bitCast(lparam)));
    for (ascii, 0..) |c, i| {
        if (ptr[i] != c) return false;
    }
    return ptr[ascii.len] == 0;
}

// Re-reads the config and applies it. Launchers are read live from
// global.config so they take effect by the swap alone; font changes require
// rebuilding renderer state, reflowing every tab's grid to the new cell size,
// and a full repaint.
fn reloadConfig(hwnd: win32.HWND) void {
    const gpa = global.gpa.allocator();
    const new_cfg = Config.loadDefaultChecked(gpa) catch {
        // File unreadable (editor holds it open without read sharing). Re-arm
        // and retry shortly, keeping the previous config rather than defaults.
        // The debounce window already lets most editor saves settle first.
        if (config_reload_retries < config_reload_max_retries) {
            config_reload_retries += 1;
            _ = win32.SetTimer(hwnd, types.TIMER_CONFIG_RELOAD, types.CONFIG_RELOAD_DEBOUNCE_MS, null);
        } else {
            config_reload_retries = 0;
            std.log.warn("config: reload gave up (file busy); keeping previous config", .{});
        }
        return;
    };
    config_reload_retries = 0;

    const font_changed = !fontConfigEql(&global.config, &new_cfg);
    // Must be computed before the move below, otherwise global.config == new_cfg.
    const theme_changed = !std.meta.eql(global.config.theme, new_cfg.theme);
    if (font_changed) {
        // Leak the previous UTF-16 family list: the renderer still holds
        // pointers into it until updateFont republishes. New list lives for
        // the renderer's lifetime, same leak-by-design as startup.
        const families = util.utf16FontFamilies(gpa, new_cfg.font_families);
        const codepoint_maps = util.utf16CodepointMaps(gpa, new_cfg.font_codepoint_maps);
        global.renderer.updateFont(.{
            .families = families,
            .family_bold = util.utf16FamilyOptional(gpa, new_cfg.font_family_bold),
            .family_italic = util.utf16FamilyOptional(gpa, new_cfg.font_family_italic),
            .family_bold_italic = util.utf16FamilyOptional(gpa, new_cfg.font_family_bold_italic),
            .synthesize_bold = new_cfg.font_synthetic_style.bold,
            .synthesize_italic = new_cfg.font_synthetic_style.italic,
            .synthesize_bold_italic = new_cfg.font_synthetic_style.bold_italic,
            .style_specs = .{
                util.convertStyleSpec(gpa, new_cfg.font_style),
                util.convertStyleSpec(gpa, new_cfg.font_style_bold),
                util.convertStyleSpec(gpa, new_cfg.font_style_italic),
                util.convertStyleSpec(gpa, new_cfg.font_style_bold_italic),
            },
            .font_size_pt = new_cfg.font_size_pt,
            .codepoint_maps = codepoint_maps,
        });
    }

    // Explicit move: Config owns an arena, so publish the new value before
    // freeing the old one and never defer-deinit new_cfg.
    var old = global.config;
    global.config = new_cfg;
    old.deinit();

    if (font_changed) {
        if (global.window) |*window| {
            // Stale geometry token captured at the old cell size.
            window.bounds = null;
            const cell_count = window_geom.computeGridCellCount(hwnd, global.renderer.cell_size);
            for (window.tabs.items) |tab| {
                tab.term.resize(tab.term_arena.allocator(), cell_count.col, cell_count.row) catch |e|
                    std.debug.panic("Terminal.resize: {}", .{e});
                var resize_err: Error = undefined;
                tab.child_process.resize(&resize_err, cell_count) catch std.debug.panic("{f}", .{resize_err});
            }
            window.requestRender();
        }
    }

    if (theme_changed) {
        if (global.window) |*window| {
            for (window.tabs.items) |tab| {
                global.config.theme.rebaseTerminal(tab.term);
            }
            window.requestRender();
        }
    }
}

fn fontConfigEql(a: *const Config, b: *const Config) bool {
    if (!optF32Eql(a.font_size_pt, b.font_size_pt)) return false;
    if (a.font_families.len != b.font_families.len) return false;
    for (a.font_families, b.font_families) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    if (!std.mem.eql(u8, a.font_family_bold, b.font_family_bold)) return false;
    if (!std.mem.eql(u8, a.font_family_italic, b.font_family_italic)) return false;
    if (!std.mem.eql(u8, a.font_family_bold_italic, b.font_family_bold_italic)) return false;
    if (!std.meta.eql(a.font_synthetic_style, b.font_synthetic_style)) return false;
    if (!fontStyleEql(a.font_style, b.font_style)) return false;
    if (!fontStyleEql(a.font_style_bold, b.font_style_bold)) return false;
    if (!fontStyleEql(a.font_style_italic, b.font_style_italic)) return false;
    if (!fontStyleEql(a.font_style_bold_italic, b.font_style_bold_italic)) return false;
    if (a.font_codepoint_maps.len != b.font_codepoint_maps.len) return false;
    for (a.font_codepoint_maps, b.font_codepoint_maps) |x, y| {
        if (x.range_start != y.range_start) return false;
        if (x.range_end != y.range_end) return false;
        if (!std.mem.eql(u8, x.family, y.family)) return false;
    }
    return true;
}

fn fontStyleEql(a: Config.FontStyle, b: Config.FontStyle) bool {
    if (@as(std.meta.Tag(Config.FontStyle), a) != @as(std.meta.Tag(Config.FontStyle), b)) return false;
    return switch (a) {
        .default, .disabled => true,
        .named => |an| std.mem.eql(u8, an, b.named),
    };
}

fn optF32Eql(a: ?f32, b: ?f32) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.? == b.?;
}

pub fn onSysCommand(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    // DefWindowProc uses the low 4 bits internally; mask before comparing.
    if ((wparam & 0xFFF0) == types.IDM_OPEN_SETTINGS) {
        openSettingsFile(hwnd);
        return 0;
    }
    return null; // delegate the rest (Move/Size/Close/...) to DefWindowProcW
}

// Opens %LOCALAPPDATA%/mostty/config in notepad.exe, creating an empty file
// (and its parent dir) first if it does not exist yet.
fn openSettingsFile(hwnd: win32.HWND) void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const path = Config.defaultPath(a) orelse {
        std.log.err("settings: LOCALAPPDATA unavailable", .{});
        return;
    };

    ensureFileExists(path) catch |err| {
        std.log.err("settings: cannot create '{s}': {s}", .{ path, @errorName(err) });
        return;
    };

    // Quote so a path with spaces reaches notepad as a single argument.
    const quoted = std.fmt.allocPrint(a, "\"{s}\"", .{path}) catch |e| util.oom(e);
    const params_w = util.utf16ZAllocConst(a, quoted) catch |e| util.oom(e);
    const result = win32.ShellExecuteW(
        hwnd,
        win32.L("open"),
        win32.L("notepad.exe"),
        params_w,
        null,
        @bitCast(win32.SW_SHOWNORMAL),
    );
    const code = if (result) |h| @intFromPtr(h) else 0;
    if (code <= 32) std.log.err("settings: ShellExecuteW failed, code={d}", .{code});
}

fn ensureFileExists(path: []const u8) !void {
    // Don't require write access to a config that already exists (it may be
    // read-only); only create one when it's actually missing.
    std.fs.cwd().access(path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);
            // truncate=false guards against clobbering if a racing writer wins.
            const f = try std.fs.cwd().createFile(path, .{ .truncate = false });
            f.close();
        },
        else => return err,
    };
}

pub fn onDropFiles(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    if (wparam == 0) return 0;
    const hdrop: win32.HDROP = @ptrFromInt(wparam);
    paste.onDropFiles(window, hdrop);
    return 0;
}

pub fn onAppChildProcessData(_: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const read_msg: *const ReadMsg = @ptrFromInt(wparam);
    // Always return the magic value, even when dropping payload.
    if (global.window == null) return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    const window = &global.window.?;
    const tab = window.findById(read_msg.tab_id) orelse return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    if (tab.closing) return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
    tab.vt_stream.nextSlice(read_msg.data[0..read_msg.len]);
    window.requestRender();
    return types.WM_APP_CHILD_PROCESS_DATA_RESULT;
}
