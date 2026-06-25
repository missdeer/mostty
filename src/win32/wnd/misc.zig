const std = @import("std");
const win32 = @import("win32").everything;

const Config = @import("../../Config.zig");
const d3d11 = @import("../d3d11.zig");
const diag = @import("../diag.zig");
const err_mod = @import("../error.zig");
const global_mod = @import("../global.zig");
const paste = @import("../paste.zig");
const state = @import("../state.zig");
const types = @import("../types.zig");
const util = @import("../util.zig");
const window_geom = @import("../window_geom.zig");

const Error = err_mod.Error;
const Tab = state.Tab;
const TabId = types.TabId;
const Window = state.Window;
const global = global_mod.global;

const PTY_DRAIN_CHUNK_BYTES: usize = 256;
const PTY_DRAIN_INITIAL_BUDGET_US: u64 = 2_000;
const PTY_DRAIN_BACKLOG_BUDGET_US: u64 = 8_000;
const PTY_DRAIN_CONTINUATION_MS: u32 = 1;

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
    if (wparam == types.TIMER_RENDER_FRAME) {
        const window = global_mod.windowFromHwnd(hwnd);
        _ = win32.KillTimer(hwnd, types.TIMER_RENDER_FRAME);
        window.render_timer_armed = false;
        if (window.render_pending) {
            win32.invalidateHwnd(hwnd);
        }
    }
    if (wparam == types.TIMER_PTY_DRAIN) {
        const window = global_mod.windowFromHwnd(hwnd);
        _ = win32.KillTimer(hwnd, types.TIMER_PTY_DRAIN);
        window.pty_drain_timer_armed = false;
        drainPendingPtyTabs();
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
    const blur_changed = global.config.background_blur != new_cfg.background_blur;
    const ligatures_changed = global.config.font_ligatures != new_cfg.font_ligatures;
    const image_changed = !std.mem.eql(u8, global.config.background_image, new_cfg.background_image) or
        global.config.background_image_opacity != new_cfg.background_image_opacity or
        global.config.background_image_position != new_cfg.background_image_position or
        global.config.background_image_fit != new_cfg.background_image_fit or
        global.config.background_image_repeat != new_cfg.background_image_repeat;
    if (font_changed) {
        // Leak the previous UTF-16 family list: the renderer still holds
        // pointers into it until updateFont republishes. New list lives for
        // the renderer's lifetime, same leak-by-design as startup.
        const families = util.utf16FontFamilies(gpa, new_cfg.font_families);
        const codepoint_maps = util.utf16CodepointMaps(gpa, new_cfg.font_codepoint_maps);
        const font_features = util.dwriteFontFeatures(gpa, new_cfg.font_features);
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
            .font_features = font_features,
            .codepoint_maps = codepoint_maps,
            .tabbar_family = util.utf16FamilyOptional(gpa, new_cfg.tabbar_font_family),
            .tabbar_font_size_pt = new_cfg.tabbar_font_size_pt,
        });
    }

    // Explicit move: Config owns an arena, so publish the new value before
    // freeing the old one and never defer-deinit new_cfg.
    var old = global.config;
    global.config = new_cfg;
    old.deinit();
    global.renderer.font_ligatures = global.config.font_ligatures;

    // render-interval-*-ms may have changed; re-apply against the current
    // session state. No-op when the effective interval is unchanged.
    if (global.window) |*window| {
        window.applyRenderInterval(
            global.config.render_interval_local_ms,
            global.config.render_interval_remote_ms,
            global.renderer.remote_or_software_adapter,
        );
    }

    if (font_changed) {
        if (global.window) |*window| {
            // Stale geometry token captured at the old cell size.
            window.bounds = null;
            // Skip the PTY/Terminal resize loop while iconic for the same
            // reason as onWindowPosChanged: the client area is 0x0 so the
            // grid would be 1x1, which destabilizes ConPTY. The next
            // WM_WINDOWPOSCHANGED on restore re-syncs to the real grid.
            const iconic = win32.IsIconic(hwnd) != 0;
            if (!iconic) {
                const cell_count = window_geom.computeGridCellCount(hwnd, global.renderer.cell_size);
                for (window.tabs.items) |tab| {
                    if (tab.closing) continue;
                    if (tab.term.cols == cell_count.col and tab.term.rows == cell_count.row) continue;
                    tab.term.resize(tab.term_arena.allocator(), cell_count.col, cell_count.row) catch |e|
                        std.debug.panic("Terminal.resize: {}", .{e});
                    var resize_err: Error = undefined;
                    tab.child_process.resize(&resize_err, cell_count) catch |e| switch (e) {
                        error.Closed => {
                            tab.closing = true;
                            _ = win32.PostMessageW(hwnd, types.WM_APP_CLOSE_TAB, tab.id, 0);
                        },
                        error.Error => std.debug.panic("{f}", .{resize_err}),
                    };
                }
            }
            window.requestRender();
        }
    }

    if (theme_changed) {
        if (global.window) |*window| {
            for (window.tabs.items) |tab| {
                global.config.theme.rebaseTerminal(tab.term);
            }
            // Config file is the stronger signal than any prior session pick:
            // resync the menu's check mark to whatever the file declares now.
            setActiveThemeName(window, global.config.theme_name);
            window.requestRender();
        }
    }

    if (blur_changed) {
        util.applyBlurBehind(hwnd, global.config.background_blur);
        if (global.window) |*window| window.requestRender();
    }

    if (ligatures_changed) {
        if (global.window) |*window| window.requestRender();
    }

    // Reload unconditionally (no "image_changed" gate around the call):
    // comparing old vs new *config* would miss the retry case where a
    // previous reload failed pre-spawn — `bg_image_path` is stale relative
    // to the just-published config, and the renderer is the only state
    // that knows. The reload is a cheap eql + scalar copy when nothing has
    // changed. The repaint is still gated: an async path swap triggers its
    // own requestRender from the WM_APP_BG_IMAGE_DECODED handler.
    global.renderer.reloadBackgroundImage(gpa, &global.config, hwnd);
    if (image_changed) {
        if (global.window) |*window| window.requestRender();
    }
}

fn fontConfigEql(a: *const Config, b: *const Config) bool {
    if (!optF32Eql(a.font_size_pt, b.font_size_pt)) return false;
    if (!optF32Eql(a.tabbar_font_size_pt, b.tabbar_font_size_pt)) return false;
    if (!std.mem.eql(u8, a.tabbar_font_family, b.tabbar_font_family)) return false;
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
    if (a.font_features.len != b.font_features.len) return false;
    for (a.font_features, b.font_features) |x, y| {
        if (x.tag != y.tag) return false;
        if (x.value != y.value) return false;
    }
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
    const masked = wparam & 0xFFF0;
    if (masked == types.IDM_OPEN_SETTINGS) {
        openSettingsFile(hwnd);
        return 0;
    }
    if (masked == types.IDM_TOGGLE_FULLSCREEN) {
        toggleFullscreen(hwnd);
        return 0;
    }
    if (masked >= types.IDM_THEME_BASE and masked < types.IDM_THEME_END) {
        applyThemePickById(hwnd, masked);
        return 0;
    }
    return null; // delegate the rest (Move/Size/Close/...) to DefWindowProcW
}

// Borderless-fullscreen toggle (the Raymond Chen recipe). Going in we save
// GWL_STYLE + WINDOWPLACEMENT, strip WS_OVERLAPPEDWINDOW, add WS_POPUP, and
// size to the monitor's rcMonitor — covering the taskbar so the shell auto-
// hides it. Coming back out we restore both, then SWP_FRAMECHANGED forces
// WM_NCCALCSIZE so the non-client area redraws. WM_WINDOWPOSCHANGED naturally
// fires from both SetWindowPos calls, so the existing handler re-syncs the
// grid + ConPTY size without explicit plumbing here.
pub fn toggleFullscreen(hwnd: win32.HWND) void {
    const window = global_mod.windowFromHwnd(hwnd);

    if (window.fullscreen_saved_style != null and window.fullscreen_saved_placement != null) {
        const style_bits = window.fullscreen_saved_style.?;
        const placement = window.fullscreen_saved_placement.?;
        _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, @as(isize, @bitCast(@as(usize, style_bits))));
        _ = win32.SetWindowPlacement(hwnd, &placement);
        _ = win32.SetWindowPos(hwnd, null, 0, 0, 0, 0, .{
            .NOMOVE = 1,
            .NOSIZE = 1,
            .NOZORDER = 1,
            .NOOWNERZORDER = 1,
            .DRAWFRAME = 1, // == SWP_FRAMECHANGED
        });
        window.fullscreen_saved_style = null;
        window.fullscreen_saved_placement = null;
        if (win32.GetSystemMenu(hwnd, win32.FALSE)) |menu| {
            _ = win32.CheckMenuItem(menu, @intCast(types.IDM_TOGGLE_FULLSCREEN), 0); // MF_BYCOMMAND | MF_UNCHECKED
        }
        return;
    }

    var placement: win32.WINDOWPLACEMENT = std.mem.zeroes(win32.WINDOWPLACEMENT);
    placement.length = @sizeOf(win32.WINDOWPLACEMENT);
    if (0 == win32.GetWindowPlacement(hwnd, &placement)) {
        std.log.warn("GetWindowPlacement failed, error={f}", .{win32.GetLastError()});
        return;
    }

    const monitor = win32.MonitorFromWindow(hwnd, win32.MONITOR_DEFAULTTONEAREST) orelse {
        std.log.warn("MonitorFromWindow failed, error={f}", .{win32.GetLastError()});
        return;
    };
    var mi: win32.MONITORINFO = undefined;
    mi.cbSize = @sizeOf(win32.MONITORINFO);
    if (0 == win32.GetMonitorInfoW(monitor, &mi)) {
        std.log.warn("GetMonitorInfo failed, error={f}", .{win32.GetLastError()});
        return;
    }

    const orig_style: u32 = @bitCast(@as(u32, @truncate(@as(usize, @bitCast(win32.GetWindowLongPtrW(hwnd, win32.GWL_STYLE))))));
    const ws_overlapped: u32 = @bitCast(win32.WS_OVERLAPPEDWINDOW);
    const ws_popup: u32 = @bitCast(win32.WS_POPUP);
    // Preserve WS_SYSMENU so Alt+Space still opens the system menu (and from
    // there the user can toggle Full screen back off without the keyboard
    // shortcut). Clear WS_MAXIMIZE / WS_MINIMIZE so the WM doesn't treat the
    // popup as a maximized window and reconstrain it to rcWork.
    const ws_sysmenu: u32 = @bitCast(win32.WS_SYSMENU);
    const ws_maximize: u32 = @bitCast(win32.WS_MAXIMIZE);
    const ws_minimize: u32 = @bitCast(win32.WS_MINIMIZE);
    const new_style: u32 = (orig_style & ~(ws_overlapped | ws_maximize | ws_minimize)) | ws_popup | ws_sysmenu;

    window.fullscreen_saved_style = orig_style;
    window.fullscreen_saved_placement = placement;

    _ = win32.SetWindowLongPtrW(hwnd, win32.GWL_STYLE, @as(isize, @bitCast(@as(usize, new_style))));
    _ = win32.SetWindowPos(
        hwnd,
        null, // HWND_TOP
        mi.rcMonitor.left,
        mi.rcMonitor.top,
        mi.rcMonitor.right - mi.rcMonitor.left,
        mi.rcMonitor.bottom - mi.rcMonitor.top,
        .{ .NOOWNERZORDER = 1, .DRAWFRAME = 1 }, // DRAWFRAME == SWP_FRAMECHANGED
    );
    if (win32.GetSystemMenu(hwnd, win32.FALSE)) |menu| {
        _ = win32.CheckMenuItem(menu, @intCast(types.IDM_TOGGLE_FULLSCREEN), 8); // MF_BYCOMMAND | MF_CHECKED
    }
}

// Rebuilds the Theme submenu when it's about to be displayed. Other popups
// (the OS-provided system commands, and the per-letter group submenus we
// populate eagerly below) fall through to DefWindowProc.
//
// The Theme menu is grouped by first character (0-9, A-Z, #) because a single
// flat list of 400+ themes is unusable. Draining items via DeleteMenu on the
// parent also destroys each child group submenu (MSDN: DeleteMenu frees the
// handle to a submenu attached via MF_POPUP), so old groups don't leak across
// rebuilds.
pub fn onInitMenuPopup(_: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global.window orelse return null;
    const sub = window.theme_submenu orelse return null;
    const menu: win32.HMENU = @ptrFromInt(wparam);
    if (menu != sub) return null;

    while (true) {
        const count = win32.GetMenuItemCount(menu);
        if (count <= 0) break;
        _ = win32.DeleteMenu(menu, 0, win32.MF_BYPOSITION);
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const gpa = global.gpa.allocator();
    const names = Config.listThemeNames(gpa);
    defer {
        for (names) |n| gpa.free(n);
        gpa.free(names);
    }

    if (names.len == 0) {
        _ = win32.AppendMenuW(menu, .{ .GRAYED = 1 }, 0, win32.L("(no themes found)"));
        return 0;
    }

    // 28 buckets: 0="0-9", 1..26="A".."Z", 27="#" (everything else).
    const bucket_count = 28;
    var buckets: [bucket_count]std.ArrayListUnmanaged([]const u8) = @splat(.empty);
    for (names) |name| {
        buckets[bucketFor(name)].append(a, name) catch |e| util.oom(e);
    }

    var next_id: usize = types.IDM_THEME_BASE;
    var truncated_at: ?usize = null;
    var idx: usize = 0;
    while (idx < bucket_count) : (idx += 1) {
        const items = buckets[idx].items;
        if (items.len == 0) continue;

        const group = win32.CreatePopupMenu() orelse {
            std.log.err("CreatePopupMenu (theme group) failed, error={f}", .{win32.GetLastError()});
            continue;
        };
        var group_has_active = false;

        for (items) |name| {
            if (next_id >= types.IDM_THEME_END) {
                truncated_at = truncated_at orelse names.len;
                break;
            }
            const label_w = util.utf16ZAllocConst(a, name) catch |e| util.oom(e);
            const checked = matchesActive(window.active_theme_name, name);
            if (checked) group_has_active = true;
            const flags: win32.MENU_ITEM_FLAGS = .{ .CHECKED = if (checked) 1 else 0 };
            _ = win32.AppendMenuW(group, flags, next_id, label_w);
            next_id += 0x10;
        }

        const group_label_w = util.utf16ZAllocConst(a, bucketLabel(idx)) catch |e| util.oom(e);
        // Parent-letter check mark helps users spot the active group without
        // expanding every submenu. POPUP attaches the group as a child.
        const parent_flags: win32.MENU_ITEM_FLAGS = .{
            .POPUP = 1,
            .CHECKED = if (group_has_active) 1 else 0,
        };
        _ = win32.AppendMenuW(menu, parent_flags, @intFromPtr(group), group_label_w);

        if (truncated_at != null) break;
    }

    if (truncated_at) |total| {
        std.log.warn("theme submenu: id range exhausted at {}/{} themes", .{ types.MAX_THEME_ITEMS, total });
    }
    return 0;
}

// GetMenuStringW(MF_BYCOMMAND) does not recurse into child submenus, so walk
// the tree ourselves. Returns the number of UTF-16 units written (excluding
// NUL), or 0 if the id isn't present anywhere under `root`.
fn findMenuItemText(root: win32.HMENU, id: i32, buf: [*:0]u16, cap: i32) i32 {
    const direct = win32.GetMenuStringW(root, @bitCast(id), buf, cap, win32.MF_BYCOMMAND);
    if (direct > 0) return direct;
    const count = win32.GetMenuItemCount(root);
    if (count <= 0) return 0;
    var i: i32 = 0;
    while (i < count) : (i += 1) {
        const child = win32.GetSubMenu(root, i) orelse continue;
        const got = findMenuItemText(child, id, buf, cap);
        if (got > 0) return got;
    }
    return 0;
}

fn matchesActive(active: ?[]const u8, name: []const u8) bool {
    const cur = active orelse return false;
    return std.ascii.eqlIgnoreCase(cur, name);
}

fn bucketFor(name: []const u8) usize {
    if (name.len == 0) return 27;
    const c = name[0];
    if (c >= '0' and c <= '9') return 0;
    if (c >= 'A' and c <= 'Z') return 1 + (c - 'A');
    if (c >= 'a' and c <= 'z') return 1 + (c - 'a');
    return 27;
}

fn bucketLabel(idx: usize) []const u8 {
    const letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    return switch (idx) {
        0 => "0-9",
        27 => "#",
        else => letters[idx - 1 .. idx],
    };
}

// Resolves the picked menu item back to its theme name via the menu itself
// (avoids index-drift races if the themes dir changed between popup and click).
// Theme items live in per-letter sub-submenus, so search recursively —
// GetMenuStringW(MF_BYCOMMAND) only searches the menu it was given, not its
// descendants.
fn applyThemePickById(hwnd: win32.HWND, id: usize) void {
    const window = global_mod.windowFromHwnd(hwnd);
    const sub = window.theme_submenu orelse return;

    var buf: [260:0]u16 = undefined;
    const written = findMenuItemText(sub, @intCast(id), &buf, buf.len);
    if (written <= 0) {
        std.log.warn("theme pick: menu lookup for id=0x{x} failed", .{id});
        return;
    }

    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const name_u8 = std.unicode.utf16LeToUtf8Alloc(a, buf[0..@intCast(written)]) catch |e| {
        std.log.warn("theme pick: utf16->utf8 failed: {s}", .{@errorName(e)});
        return;
    };

    const gpa = global.gpa.allocator();
    var new_theme = Config.loadThemeColorsByName(gpa, name_u8) orelse return;
    global.config.color_overrides.applyTo(&new_theme);
    global.config.theme = new_theme;

    for (window.tabs.items) |tab| {
        global.config.theme.rebaseTerminal(tab.term);
    }
    setActiveThemeName(window, name_u8);
    window.requestRender();
}

// Replaces window.active_theme_name with a fresh gpa-owned copy. Null name
// clears it.
fn setActiveThemeName(window: *Window, name: ?[]const u8) void {
    const gpa = global.gpa.allocator();
    if (window.active_theme_name) |old| gpa.free(old);
    window.active_theme_name = null;
    if (name) |n| {
        window.active_theme_name = gpa.dupe(u8, n) catch null;
    }
}

// Opens %LOCALAPPDATA%/Mostty/config in notepad.exe, creating an empty file
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

// WTS posts this whenever the session changes state (RDP connect/disconnect,
// console connect/disconnect, lock/unlock, etc). We don't care which event
// fired — we just re-poll SM_REMOTESESSION and let applyRenderInterval pick
// the right cap. Cheap; runs only on session transitions, not per frame.
pub fn onWtsSessionChange(hwnd: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    const window = global_mod.windowFromHwnd(hwnd);
    std.log.info("WTS session change event: {}", .{wparam});
    window.applyRenderInterval(
        global.config.render_interval_local_ms,
        global.config.render_interval_remote_ms,
        global.renderer.remote_or_software_adapter,
    );
    return 0;
}

pub fn onAppChildProcessData(_: win32.HWND, wparam: win32.WPARAM, _: win32.LPARAM) ?win32.LRESULT {
    if (global.window == null) return 0;
    const window = &global.window.?;
    const tab_id: TabId = @intCast(wparam);
    const tab = window.findById(tab_id) orelse return 0;
    drainPtyTab(window, tab, PTY_DRAIN_INITIAL_BUDGET_US);
    return 0;
}

fn drainPtyTab(window: *Window, tab: *Tab, budget_us: u64) void {
    if (tab.closing) {
        tab.pty_ring.posted.store(false, .release);
        // closeTabByIndex sets closing=true and PostMessages WM_APP_CLOSE_TAB;
        // until destroyTab runs, the reader is still alive and producing.
        // Drain anyway (no-op cb) to keep tail advanced — drain() internally
        // SetEvents wake_event, so a full-ring reader resumes — but skip
        // vt_stream so we don't mutate state that destroyTab is about to
        // tear down.
        _ = tab.pty_ring.drain({}, struct {
            fn cb(_: void, _: []const u8) void {}
        }.cb);
        return;
    }
    var byte_count: usize = 0;
    var chunk_count: usize = 0;
    const Ctx = struct { tab: *Tab, n: *usize };
    var ctx = Ctx{ .tab = tab, .n = &byte_count };
    const t0 = diag.qpcNow();
    while (true) {
        const before = byte_count;
        _ = tab.pty_ring.drainMax(PTY_DRAIN_CHUNK_BYTES, &ctx, struct {
            fn cb(c: *Ctx, slice: []const u8) void {
                c.tab.vt_stream.nextSlice(slice);
                c.n.* += slice.len;
            }
        }.cb);
        if (byte_count == before) break;
        chunk_count += 1;
        if (diag.qpcUsSince(t0) >= budget_us) break;
    }
    const drain_us = diag.qpcUsSince(t0);
    if (byte_count > 0) {
        if (drain_us >= 2_000) {
            std.log.info("pty drain: tab={} bytes={} chunks={} us={}", .{ tab.id, byte_count, chunk_count, drain_us });
        }
        window.notePtyBytes(@intCast(byte_count));
        window.requestRender();
    }
    schedulePtyDrainContinuation(window, tab);
}

fn schedulePtyDrainContinuation(window: *Window, tab: *Tab) void {
    if (tab.pty_ring.hasData()) {
        // Keep posted=true: this handler consumed only a bounded batch, so the
        // continuation timer represents the still-pending tail bytes.
        tab.pty_ring.posted.store(true, .release);
        armPtyDrainContinuation(window, tab);
        return;
    }

    // No tail left from this wake-up. Clear the edge-trigger guard, then
    // re-check for the race where the reader wrote while posted was still true
    // and therefore did not post its own wake-up. The clear must be seq_cst:
    // the following hasData() loads must not move before this store.
    tab.pty_ring.posted.store(false, .seq_cst);
    if (!tab.pty_ring.hasData()) return;
    if (tab.pty_ring.posted.swap(true, .acq_rel)) return;
    armPtyDrainContinuation(window, tab);
}

fn armPtyDrainContinuation(window: *Window, tab: *Tab) void {
    if (window.pty_drain_timer_armed) return;
    if (win32.SetTimer(window.hwnd, types.TIMER_PTY_DRAIN, PTY_DRAIN_CONTINUATION_MS, null) != 0) {
        window.pty_drain_timer_armed = true;
        return;
    }

    std.log.warn(
        "SetTimer(PTY_DRAIN continuation) failed (tab {}): {f}",
        .{ tab.id, win32.GetLastError() },
    );
    if (win32.PostMessageW(window.hwnd, types.WM_APP_CHILD_PROCESS_DATA, tab.id, 0) == 0) {
        std.log.warn(
            "PostMessageW(PTY_DRAIN continuation) failed (tab {}): {f}",
            .{ tab.id, win32.GetLastError() },
        );
    }
}

fn drainPendingPtyTabs() void {
    if (global.window == null) return;
    const window = &global.window.?;
    for (window.tabs.items) |tab| {
        if (tab.closing) continue;
        if (!tab.pty_ring.posted.load(.acquire)) continue;
        if (!tab.pty_ring.hasData()) {
            // Match schedulePtyDrainContinuation: clear, then re-check with a
            // StoreLoad barrier so a raced reader write cannot be stranded.
            tab.pty_ring.posted.store(false, .seq_cst);
            if (!tab.pty_ring.hasData()) continue;
            if (tab.pty_ring.posted.swap(true, .acq_rel)) continue;
            armPtyDrainContinuation(window, tab);
            continue;
        }
        drainPtyTab(window, tab, PTY_DRAIN_BACKLOG_BUDGET_US);
    }
}

// PostMessage'd by the background-image decode worker. lParam owns a
// `BgImageDecoded` heap struct (path + pixels). The renderer applies it if
// the request id still matches the latest reload; either way we free here.
pub fn onAppBgImageDecoded(_: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const result: *d3d11.BgImageDecoded = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const gpa = global.gpa.allocator();
    defer result.deinit(gpa);
    global.renderer.applyDecodedBackgroundImage(result);
    if (global.window) |*window| window.requestRender();
    return 0;
}

// PostMessage'd by the glyph raster worker once a cell glyph has been rendered
// into a CPU BGRA buffer. lParam owns a `RasterResult` heap struct; the
// renderer validates generation + slot identity and uploads to the atlas.
// On a successful upload, kick a repaint so the next frame's row diff swaps
// the placeholder glyph_index for the real slot.
pub fn onAppGlyphReady(_: win32.HWND, _: win32.WPARAM, lparam: win32.LPARAM) ?win32.LRESULT {
    const result: *d3d11.RasterResult = @ptrFromInt(@as(usize, @bitCast(lparam)));
    const gpa = global.gpa.allocator();
    defer result.deinit(gpa);
    const uploaded = global.renderer.applyGlyphResult(result);
    if (uploaded) {
        if (global.window) |*window| window.requestRender();
    }
    return 0;
}
