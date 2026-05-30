const Config = @This();

pub const Launcher = struct {
    label: []const u8,
    command_line: []const u8,
    working_directory: []const u8, // empty = inherit parent
};

// Resolved theme/color state. Pure value type (no arena-backed pointers) so it
// survives the Config arena being freed on hot-reload, and can be copied into
// the renderer / each tab's vt color state cheaply. `palette` defaults to the
// standard xterm-256 table (vt.color.default already fills 0-15 named, 16-231
// the 6x6x6 cube, 232-255 gray ramp), so themes that only set 0-15 keep a sane
// extended palette instead of black.
pub const ThemeColors = struct {
    palette: [256]vt.color.RGB = vt.color.default,
    foreground: u24 = 0xc8c4d0,
    background: u24 = 0x2a2a2a,
    cursor_color: ?u24 = null,
    cursor_text: ?u24 = null,
    selection_background: ?u24 = null,
    selection_foreground: ?u24 = null,

    // Seed a freshly-created terminal's dynamic colors from this theme. cursor
    // is left unset when the theme has no cursor-color (renderer then inverts).
    pub fn applyToNewTerminal(self: *const ThemeColors, term: *vt.Terminal) void {
        term.colors.foreground = .init(u24ToRgb(self.foreground));
        term.colors.background = .init(u24ToRgb(self.background));
        if (self.cursor_color) |c| term.colors.cursor = .init(u24ToRgb(c));
        term.colors.palette = .init(self.palette);
    }

    // Re-baseline an existing terminal's colors on hot-reload, preserving any
    // genuine OSC override an app set at runtime.
    pub fn rebaseTerminal(self: *const ThemeColors, term: *vt.Terminal) void {
        rebaseDynamicRGB(&term.colors.foreground, u24ToRgb(self.foreground));
        rebaseDynamicRGB(&term.colors.background, u24ToRgb(self.background));
        rebaseDynamicRGB(&term.colors.cursor, if (self.cursor_color) |c| u24ToRgb(c) else null);
        term.colors.palette.changeDefault(self.palette);
    }
};

// Updates a DynamicRGB's default while preserving a real OSC override. vt's
// reset() sets override = old default, so "override == old default" (or null)
// means the app hasn't truly overridden the color and it should follow the new
// theme; a different override is a live app choice and is kept.
fn rebaseDynamicRGB(c: *vt.color.DynamicRGB, new_default: ?vt.color.RGB) void {
    const unmodified = c.override == null or
        (c.default != null and std.meta.eql(c.override.?, c.default.?));
    c.default = new_default;
    if (unmodified) c.override = null;
}

font_families: []const []const u8 = &.{},
font_size_pt: ?f32 = null,
launchers: []const Launcher = &.{},
theme: ThemeColors = .{},

arena: ?std.heap.ArenaAllocator = null,

// The default config location, %LOCALAPPDATA%/mostty/config. Returns null when
// LOCALAPPDATA is unset. Caller owns the returned slice.
pub fn defaultPath(gpa: std.mem.Allocator) ?[]const u8 {
    const localappdata = std.process.getEnvVarOwned(gpa, "LOCALAPPDATA") catch return null;
    defer gpa.free(localappdata);
    return std.fs.path.join(gpa, &.{ localappdata, "mostty", "config" }) catch oom();
}

pub fn loadDefault(gpa: std.mem.Allocator) Config {
    const path = defaultPath(gpa) orelse {
        std.log.info("config: LOCALAPPDATA unavailable; using defaults", .{});
        return .{};
    };
    defer gpa.free(path);

    return loadPath(gpa, path);
}

pub const ReloadError = error{ReadFailed};

// Like loadDefault, but distinguishes a transient read failure (config locked
// while an editor is mid-save) from "file absent", so the live-reload path can
// keep the previous config instead of clobbering it with defaults. A genuinely
// missing file still yields defaults (the user deleting the config legitimately
// means "all defaults").
pub fn loadDefaultChecked(gpa: std.mem.Allocator) ReloadError!Config {
    const path = defaultPath(gpa) orelse return .{};
    defer gpa.free(path);
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return error.ReadFailed,
    };
    defer gpa.free(bytes);
    return parse(gpa, bytes, path);
}

pub fn loadPath(gpa: std.mem.Allocator, path: []const u8) Config {
    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| switch (err) {
        error.FileNotFound => {
            std.log.info("config: '{s}' not found; using defaults", .{path});
            return .{};
        },
        else => {
            std.log.warn("config: read '{s}' failed: {s}; using defaults", .{ path, @errorName(err) });
            return .{};
        },
    };
    defer gpa.free(bytes);

    std.log.info("config: loaded '{s}'", .{path});
    return parse(gpa, bytes, path);
}

pub fn parse(gpa: std.mem.Allocator, source: []const u8, source_name: []const u8) Config {
    var arena = std.heap.ArenaAllocator.init(gpa);
    const a = arena.allocator();

    var families: std.ArrayListUnmanaged([]const u8) = .empty;
    var font_size_pt: ?f32 = null;
    var launchers: std.ArrayListUnmanaged(Launcher) = .empty;
    var theme: ThemeColors = .{};

    // Strip UTF-8 BOM if present (Notepad and other Windows editors add one).
    const input = if (std.mem.startsWith(u8, source, "\xEF\xBB\xBF")) source[3..] else source;

    // Phase 1: load any `theme = X` files as the color baseline first, so the
    // config's own explicit color keys (phase 2) always win regardless of line
    // order — matching Ghostty's "theme provides defaults, config overrides".
    {
        var it = std.mem.splitScalar(u8, input, '\n');
        while (it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
            const key = std.mem.trim(u8, line[0..eq], " \t");
            if (!std.mem.eql(u8, key, "theme")) continue;
            const value = std.mem.trim(u8, line[eq + 1 ..], " \t");
            applyThemeFile(gpa, &theme, value);
        }
    }

    // Phase 2: everything else. Color keys overwrite the theme baseline.
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        line_no += 1;
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse {
            std.log.warn("config: {s}:{}: missing '=' in '{s}'", .{ source_name, line_no, line });
            continue;
        };
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "theme")) {
            // Handled in phase 1.
        } else if (applyColorKey(&theme, key, value)) {
            // Recognized color key (palette/background/foreground/cursor-*/selection-*).
        } else if (isKnownUnsupportedKey(key)) {
            // Known Ghostty key with no mostty equivalent: ignore silently so
            // ported configs don't spam warnings.
        } else if (std.mem.eql(u8, key, "font-family")) {
            var vit = std.mem.splitScalar(u8, value, ',');
            while (vit.next()) |v| {
                const name = std.mem.trim(u8, v, " \t");
                if (name.len == 0) continue;
                const owned = a.dupe(u8, name) catch oom();
                families.append(a, owned) catch oom();
            }
        } else if (std.mem.eql(u8, key, "font-size")) {
            const n = std.fmt.parseFloat(f32, value) catch {
                std.log.warn("config: {s}:{}: invalid font-size '{s}'", .{ source_name, line_no, value });
                continue;
            };
            if (!(n > 0)) {
                std.log.warn("config: {s}:{}: font-size must be positive (got {d})", .{ source_name, line_no, n });
                continue;
            }
            font_size_pt = n;
        } else if (std.mem.eql(u8, key, "launcher")) {
            const launcher = parseLauncher(a, value) orelse {
                std.log.warn("config: {s}:{}: invalid launcher '{s}'", .{ source_name, line_no, value });
                continue;
            };
            launchers.append(a, launcher) catch oom();
        } else {
            std.log.warn("config: {s}:{}: unknown key '{s}'", .{ source_name, line_no, key });
        }
    }

    const families_slice = families.toOwnedSlice(a) catch oom();
    const launchers_slice = launchers.toOwnedSlice(a) catch oom();
    return .{
        .font_families = families_slice,
        .font_size_pt = font_size_pt,
        .launchers = launchers_slice,
        .theme = theme,
        .arena = arena,
    };
}

// Parses `#RRGGBB` / `RRGGBB` into a packed 0xRRGGBB. Named X11 colors are not
// supported (theme files are all hex).
fn parseHex(value: []const u8) ?u24 {
    const v = if (std.mem.startsWith(u8, value, "#")) value[1..] else value;
    if (v.len != 6) return null;
    return std.fmt.parseInt(u24, v, 16) catch null;
}

fn u24ToRgb(c: u24) vt.color.RGB {
    return .{
        .r = @intCast((c >> 16) & 0xFF),
        .g = @intCast((c >> 8) & 0xFF),
        .b = @intCast(c & 0xFF),
    };
}

// Applies one color key to `theme`. Returns true if `key` was a recognized
// color key (even when the value was malformed — it still belongs to the color
// namespace and must not fall through to the unknown-key warning).
fn applyColorKey(theme: *ThemeColors, key: []const u8, value: []const u8) bool {
    if (std.mem.eql(u8, key, "palette")) {
        // value is `N=#hex`.
        const eq = std.mem.indexOfScalar(u8, value, '=') orelse return true;
        const idx = std.fmt.parseInt(u8, std.mem.trim(u8, value[0..eq], " \t"), 10) catch return true;
        const rgb = parseHex(std.mem.trim(u8, value[eq + 1 ..], " \t")) orelse return true;
        theme.palette[idx] = u24ToRgb(rgb);
        return true;
    }
    const dst: *?u24 = if (std.mem.eql(u8, key, "cursor-color"))
        &theme.cursor_color
    else if (std.mem.eql(u8, key, "cursor-text"))
        &theme.cursor_text
    else if (std.mem.eql(u8, key, "selection-background"))
        &theme.selection_background
    else if (std.mem.eql(u8, key, "selection-foreground"))
        &theme.selection_foreground
    else {
        // foreground/background are non-optional u24.
        if (std.mem.eql(u8, key, "foreground")) {
            if (parseHex(value)) |c| theme.foreground = c;
            return true;
        }
        if (std.mem.eql(u8, key, "background")) {
            if (parseHex(value)) |c| theme.background = c;
            return true;
        }
        return false;
    };
    if (parseHex(value)) |c| dst.* = c;
    return true;
}

// Ghostty theme/color-doc keys that mostty has no feature for. Ignored silently
// (vs the warn for genuinely unknown keys, which catches user typos).
fn isKnownUnsupportedKey(key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "split-")) return true;
    if (std.mem.startsWith(u8, key, "search-")) return true;
    if (std.mem.startsWith(u8, key, "window-titlebar-")) return true;
    return std.mem.eql(u8, key, "unfocused-split-fill") or
        std.mem.eql(u8, key, "palette-generate") or
        std.mem.eql(u8, key, "palette-harmonious") or
        std.mem.eql(u8, key, "config-file");
}

// Resolves `theme = X` to a file and folds its color keys into `theme` as the
// baseline. Handles Ghostty's `light:A, dark:B` syntax (mostty is a dark-chrome
// app, so the dark variant wins). Does NOT recurse: `theme`/`config-file` keys
// inside a theme file are ignored.
fn applyThemeFile(gpa: std.mem.Allocator, theme: *ThemeColors, value: []const u8) void {
    const name = resolveThemeName(value, systemPrefersDark());
    if (name.len == 0) return;

    const path: []const u8 = if (std.fs.path.isAbsolute(name))
        gpa.dupe(u8, name) catch oom()
    else
        findThemeFile(gpa, name) orelse {
            std.log.warn("config: theme '{s}' not found in %LOCALAPPDATA%/mostty/themes or <exe>/themes", .{name});
            return;
        };
    defer gpa.free(path);

    const bytes = std.fs.cwd().readFileAlloc(gpa, path, 64 * 1024) catch |err| {
        std.log.warn("config: theme read '{s}' failed: {s}", .{ path, @errorName(err) });
        return;
    };
    defer gpa.free(bytes);

    const input = if (std.mem.startsWith(u8, bytes, "\xEF\xBB\xBF")) bytes[3..] else bytes;
    var it = std.mem.splitScalar(u8, input, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (std.mem.eql(u8, key, "theme")) continue; // no recursion
        const v = std.mem.trim(u8, line[eq + 1 ..], " \t");
        _ = applyColorKey(theme, key, v); // ignore non-color keys silently in theme files
    }
}

// Extracts the effective theme name from a `theme` value. For Ghostty's variant
// form `light:A, dark:B` (order-independent) it picks the variant matching the
// OS light/dark mode (`prefer_dark`), falling back to the other variant if only
// one is given. A segment is only treated as a variant when it exactly starts
// with `light:`/`dark:`, so a plain Windows path like `C:\themes\x` is never
// mis-parsed.
fn resolveThemeName(value: []const u8, prefer_dark: bool) []const u8 {
    var dark: ?[]const u8 = null;
    var light: ?[]const u8 = null;
    var any_variant = false;
    var it = std.mem.splitScalar(u8, value, ',');
    while (it.next()) |seg| {
        const s = std.mem.trim(u8, seg, " \t");
        if (std.mem.startsWith(u8, s, "dark:")) {
            dark = std.mem.trim(u8, s["dark:".len..], " \t");
            any_variant = true;
        } else if (std.mem.startsWith(u8, s, "light:")) {
            light = std.mem.trim(u8, s["light:".len..], " \t");
            any_variant = true;
        }
    }
    if (!any_variant) return value;
    return if (prefer_dark) (dark orelse light orelse value) else (light orelse dark orelse value);
}

// Whether Windows is in dark mode (apps use dark theme). Reads HKCU
// Themes\Personalize\AppsUseLightTheme (DWORD: 1 = light, 0 = dark). Defaults to
// dark when the value is missing/unreadable, matching mostty's dark chrome.
fn systemPrefersDark() bool {
    var data: u32 = 0;
    var size: u32 = @sizeOf(u32);
    const rc = win32.RegGetValueW(
        win32.HKEY_CURRENT_USER,
        win32.L("Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"),
        win32.L("AppsUseLightTheme"),
        win32.RRF_RT_REG_DWORD,
        null,
        &data,
        &size,
    );
    if (@intFromEnum(rc) != 0) return true; // missing/unreadable -> assume dark
    return data == 0;
}

// Searches the theme name under %LOCALAPPDATA%/mostty/themes then <exeDir>/themes.
// Returns the first existing path (caller owns it) or null.
fn findThemeFile(gpa: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (std.process.getEnvVarOwned(gpa, "LOCALAPPDATA")) |lad| {
        defer gpa.free(lad);
        const p = std.fs.path.join(gpa, &.{ lad, "mostty", "themes", name }) catch oom();
        if (fileExists(p)) return p;
        gpa.free(p);
    } else |_| {}

    if (exeDir(gpa)) |dir| {
        defer gpa.free(dir);
        const p = std.fs.path.join(gpa, &.{ dir, "themes", name }) catch oom();
        if (fileExists(p)) return p;
        gpa.free(p);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

// Directory containing the running executable (caller owns the slice).
fn exeDir(gpa: std.mem.Allocator) ?[]const u8 {
    var buf: [std.os.windows.PATH_MAX_WIDE:0]u16 = undefined;
    const len = win32.GetModuleFileNameW(null, &buf, buf.len);
    if (len == 0 or len >= buf.len) return null;
    const full = std.unicode.utf16LeToUtf8Alloc(gpa, buf[0..len]) catch return null;
    defer gpa.free(full);
    const dir = std.fs.path.dirname(full) orelse return null;
    return gpa.dupe(u8, dir) catch oom();
}

fn parseLauncher(a: std.mem.Allocator, value: []const u8) ?Launcher {
    // Split with first-and-last '|' semantics so the middle (command-line)
    // segment may contain literal '|' (common in shell pipelines).
    const first = std.mem.indexOfScalar(u8, value, '|') orelse return null;
    const last = std.mem.lastIndexOfScalar(u8, value, '|').?;
    const label = std.mem.trim(u8, value[0..first], " \t");
    const cmd_slice = if (first == last) value[first + 1 ..] else value[first + 1 .. last];
    const cwd_slice = if (first == last) value[0..0] else value[last + 1 ..];
    const command_line = std.mem.trim(u8, cmd_slice, " \t");
    const working_directory = std.mem.trim(u8, cwd_slice, " \t");

    if (label.len == 0 or command_line.len == 0) return null;
    if (!std.unicode.utf8ValidateSlice(label)) return null;
    if (!std.unicode.utf8ValidateSlice(command_line)) return null;
    if (!std.unicode.utf8ValidateSlice(working_directory)) return null;

    return .{
        .label = a.dupe(u8, label) catch oom(),
        .command_line = a.dupe(u8, command_line) catch oom(),
        .working_directory = a.dupe(u8, working_directory) catch oom(),
    };
}

pub fn deinit(self: *Config) void {
    if (self.arena) |*a| a.deinit();
    self.* = undefined;
}

fn oom() noreturn {
    @panic("OOM in config loader");
}

test "parseHex accepts #RRGGBB and RRGGBB, rejects bad length" {
    try std.testing.expectEqual(@as(?u24, 0x282a36), parseHex("#282a36"));
    try std.testing.expectEqual(@as(?u24, 0xff5555), parseHex("ff5555"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("#fff"));
    try std.testing.expectEqual(@as(?u24, null), parseHex("nothex"));
}

test "u24ToRgb keeps channel order (not a bitcast)" {
    const rgb = u24ToRgb(0x112233);
    try std.testing.expectEqual(@as(u8, 0x11), rgb.r);
    try std.testing.expectEqual(@as(u8, 0x22), rgb.g);
    try std.testing.expectEqual(@as(u8, 0x33), rgb.b);
}

test "resolveThemeName picks variant by mode, leaves plain paths alone" {
    // Order-independent; picks the variant matching the mode.
    try std.testing.expectEqualStrings("Dracula", resolveThemeName("light:GitHub, dark:Dracula", true));
    try std.testing.expectEqualStrings("GitHub", resolveThemeName("light:GitHub, dark:Dracula", false));
    try std.testing.expectEqualStrings("Dracula", resolveThemeName("dark:Dracula, light:GitHub", true));
    // Non-variant values pass through untouched regardless of mode.
    try std.testing.expectEqualStrings("Nord", resolveThemeName("Nord", true));
    try std.testing.expectEqualStrings("C:\\themes\\x", resolveThemeName("C:\\themes\\x", false));
    // Only one variant given: fall back to it.
    try std.testing.expectEqualStrings("OnlyLight", resolveThemeName("light:OnlyLight", true));
    try std.testing.expectEqualStrings("OnlyDark", resolveThemeName("dark:OnlyDark", false));
}

test "parse reads color keys into theme" {
    const src =
        \\background = #000000
        \\foreground = #abcdef
        \\palette = 1=#ff5555
        \\palette = 200=#102030
        \\cursor-color = #112233
        \\selection-background = #445566
        \\split-divider-color = #999999
    ;
    var cfg = parse(std.testing.allocator, src, "test");
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u24, 0x000000), cfg.theme.background);
    try std.testing.expectEqual(@as(u24, 0xabcdef), cfg.theme.foreground);
    try std.testing.expectEqual(u24ToRgb(0xff5555), cfg.theme.palette[1]);
    try std.testing.expectEqual(u24ToRgb(0x102030), cfg.theme.palette[200]);
    try std.testing.expectEqual(@as(?u24, 0x112233), cfg.theme.cursor_color);
    try std.testing.expectEqual(@as(?u24, 0x445566), cfg.theme.selection_background);
    // Index not set by the theme keeps the standard xterm cube (non-zero).
    try std.testing.expectEqual(vt.color.default[16], cfg.theme.palette[16]);
}

const std = @import("std");
const vt = @import("vt");
const win32 = @import("win32").everything;
