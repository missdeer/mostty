# Mostty Configuration

Mostty is configured through a single plain-text config file. There are no
working command-line options today; everything below lives in the config file.

## File location

```
%LOCALAPPDATA%\Mostty\config
```

The file has no extension. You can open (and create) it from the window's system
menu via **Open Settings File…**, which launches it in Notepad and creates the
file and its parent folder if missing.

## Syntax

- One `key = value` per line. Whitespace around the key and value is trimmed.
- UTF-8. A leading UTF-8 BOM (added by some Windows editors) is tolerated.
- There is **no comment syntax**. A line without `=` is reported as a warning
  and skipped, so do not use `#`/`//` comment lines.
- Unknown keys produce a warning. A small set of Ghostty keys that Mostty has no
  feature for is accepted-and-ignored silently (so a ported Ghostty config does
  not spam warnings): `split-*`, `search-*`, `window-titlebar-*`,
  `unfocused-split-fill`, `palette-generate`, `palette-harmonious`, `config-file`,
  `font-thicken`, `font-thicken-strength`, `font-shaping-break`.

## Hot reload

The file is watched live. Saving it re-applies changes without a restart:

- **Font** changes rebuild the renderer and reflow every tab.
- **Font ligature** changes repaint immediately without resizing tabs.
- **Theme/color** changes re-baseline every tab's colors (preserving any live
  `OSC 10/11/12/4` color overrides an app set at runtime).
- **Launchers** are read on demand, so they take effect immediately.
- **Env entries** apply to newly-spawned tabs. Existing tabs keep the
  environment they were started with (ConPTY's environment is fixed at spawn).

---

## Color value format

Colors are 6-digit hex: `#RRGGBB` or `RRGGBB`. Named (X11) colors are not
supported.

## Keys

### `font-family`

Comma-separated list of font family names. May be repeated; all entries
accumulate into a fallback chain (first match wins per glyph).

```
font-family = JetBrains Mono, Consolas
```

Default: `Consolas`.

### `font-size`

Font size in points. Must be a positive number.

```
font-size = 13.5
```

Default: `13.0`.

### `font-ligatures`

Whether Mostty shapes common programming-symbol runs such as `=>`, `==`, `!=`,
`->`, `&&`, and `||` through DirectWrite so fonts with ligature support can
render them as a joined glyph.

```
font-ligatures = true
font-ligatures = false
```

Default: `true`. Accepted values are `true` / `yes` / `t` / `y`,
`false` / `no` / `f` / `n`, or a non-negative integer (`0` → off, `>0` → on).

When disabled, symbol runs use the normal per-cell glyph path. This is useful
with fonts that do not provide programming ligatures, where shaping the run
would otherwise consume extra atlas slots without changing the visual result.
Hot-reloads — toggling the key triggers a repaint without resizing tabs.

### `font-feature`

Apply OpenType feature settings through DirectWrite typography. The syntax is
compatible with Ghostty's `font-feature` / CSS `font-feature-settings` shape:

```
font-feature = liga
font-feature = "calt" off
font-feature = dlig=1, ss01=1, -ss02
```

Feature names must be four-character printable ASCII tags such as `liga`,
`calt`, `dlig`, or stylistic sets like `ss01` through `ss20`. Custom tags
from specific fonts are also supported. Values default to `1`; use `off`,
`false`, `0`, or a leading `-` to disable a feature. Malformed tags (not
exactly four characters or containing non-printable characters) are skipped
with a warning. Hot-reloads rebuild the font atlas so changed features take
effect on the next repaint.

### `tabbar-font-family` / `tabbar-font-size`

Override the font used to render tab-bar titles. When unset, the tab bar
inherits `font-family`'s primary entry and `font-size` respectively.

```
tabbar-font-family = Segoe UI
tabbar-font-size   = 11
```

`tabbar-font-family` uses only the primary family — if a comma list is given,
only the first entry is taken; the terminal `font-family` chain still acts as
the fallback for codepoints the tab-bar family lacks (CJK / emoji titles).
`tabbar-font-size` must be a positive number.

Tab titles are rendered proportionally (the font's natural glyph widths, not
one glyph per terminal cell), and the tab-bar height auto-sizes to the tab-bar
font's line height so the whole glyph is visible. Tab widths and the close/new
buttons stay aligned to the terminal cell grid. Long titles are ellipsized.

### `font-family-bold` / `font-family-italic` / `font-family-bold-italic`

Single family name to use for cells with the corresponding SGR style. When
unset, the style inherits `font-family`'s primary entry and DirectWrite
synthesizes bold / oblique on top (subject to `font-synthetic-style`).

```
font-family-bold        = JetBrains Mono
font-family-italic      = Cascadia Code
font-family-bold-italic = Cascadia Code
```

Each is a single family — comma lists are not parsed here. The regular
`font-family` chain still acts as the fallback for codepoints the style-family
lacks, so a style-family covering only ASCII gracefully degrades to the main
font for CJK / icons / emoji.

### `font-style` / `font-style-bold` / `font-style-italic` / `font-style-bold-italic`

Pin a specific named face within the chosen family. Mostty looks up the face
by its **en-us** face name (case-insensitive), reads its real weight / slant /
stretch, and uses those instead of DirectWrite's synthetic defaults.

```
font-style             = SemiBold
font-style-bold        = ExtraBold
font-style-italic      = Italic
font-style-bold-italic = ExtraBold Italic
```

Special value `false` disables a slot explicitly — combined with
`font-synthetic-style = no-*` it forces those cells to render with the regular
text format instead.

```
font-style-italic = false
```

If the named face doesn't exist in the family, Mostty warns and keeps the
slot's natural attributes (synthesizing per `font-synthetic-style`).

Known limitation: only the en-us face name table is matched. Localized face
names (e.g. on a localized Windows build) are not — use the canonical en-us
name.

### `font-synthetic-style`

Controls whether DirectWrite is allowed to synthesize a style (algorithmic
bold / oblique) when the chosen family lacks a real face. Default: all three
allowed. Syntax:

```
font-synthetic-style = true                              # allow all (default)
font-synthetic-style = false                             # forbid all
font-synthetic-style = no-bold                           # forbid bold only
font-synthetic-style = no-bold, no-italic, no-bold-italic   # forbid the named slots
```

When a slot is forbidden AND its family has no real matching face, cells of
that style render with the regular text format instead (the cache also folds
them into the regular atlas slots, so no redundant rasterization).

Known limitation: only the PRIMARY family of each slot is checked. Fallback
faces inside the chain may still be per-glyph synthesized by DirectWrite —
mitigating that would require a shaping pipeline Mostty does not have.

### `font-codepoint-map`

Prefer a specific font family for one or more Unicode ranges during fallback
lookup — i.e. when the primary `font-family` doesn't cover the codepoint.
Useful for pinning the emoji font, icon-font ranges, or a CJK fallback.

```
font-codepoint-map = U+1F300-U+1F5FF=Segoe UI Emoji
font-codepoint-map = U+2500-U+257F,U+2580-U+259F=Cascadia Mono
font-codepoint-map = U+4E2D=Noto Sans CJK SC
```

Syntax: `<ranges>=<family>` where each range is `U+HEX` (single codepoint)
or `U+HEX-U+HEX` (inclusive). Bare hex without the `U+` prefix is also
accepted as a pragmatic convenience. Multiple ranges may share one family
with commas. To map different families, repeat the key. May be repeated.

Earlier entries win on overlap (DirectWrite first-match). Known limitation:
the mapping kicks in only when the primary family doesn't cover the
codepoint — if your `font-family` itself supplies a glyph for the range, that
glyph is used (the typical case where the primary is a monospace font and the
map targets emoji / icons works as expected).

### `theme`

Loads a theme file as the color baseline. The value is one of:

- a theme **name** (resolved against the theme search paths below),
- an **absolute path** to a theme file, or
- a **light/dark variant** form `light:<name>, dark:<name>` (order does not
  matter; whitespace trimmed).

```
theme = Dracula
theme = C:\Users\me\my-theme
theme = light:Rose Pine Dawn, dark:Rose Pine
```

**Variant selection.** With the `light:`/`dark:` form, Mostty picks the variant
that matches the current Windows *Apps* light/dark mode
(`HKCU\…\Themes\Personalize\AppsUseLightTheme`) and **automatically re-selects**
when you toggle Windows light/dark mode at runtime. If only one of the two is
given, that one is used.

**Theme search order** (a bare name, not an absolute path):

1. `%LOCALAPPDATA%\Mostty\themes\<name>` — your overrides.
2. `<exe directory>\themes\<name>` — the bundled themes shipped next to
   `Mostty.exe` (installed by `zig build`).

A theme file uses the exact same `key = value` color keys listed below. `theme`
and `config-file` keys inside a theme file are ignored (no recursion).

**Precedence.** Explicit color keys in your config always override the theme
file, regardless of line order; the theme file overrides the built-in defaults.
The 256-color palette is merged per index.

### `background` / `foreground`

Default window background and text colors.

```
background = #282a36
foreground = #f8f8f2
```

Defaults: `background = #2a2a2a`, `foreground = #c8c4d0`.

### `cursor-color` / `cursor-text`

`cursor-color` is the cursor block color; `cursor-text` is the color of the
glyph under the cursor.

```
cursor-color = #f8f8f2
cursor-text  = #282a36
```

Default (when unset): reverse video — the cursor uses the cell's foreground as
its block and the background as its text.

### `selection-background` / `selection-foreground`

Colors for selected text.

```
selection-background = #44475a
selection-foreground = #ffffff
```

Default (when unset): reverse video of the selected cells.

### `palette`

Overrides a single entry of the 256-color palette. The value is `N=#RRGGBB`
where `N` is `0`–`255`. Indices `0`–`15` are the standard ANSI colors; `16`–`255`
default to the standard xterm color cube and gray ramp, so you only need to set
the indices you want to change.

```
palette = 0=#21222c
palette = 1=#ff5555
palette = 200=#ff00ff
```

### `background-opacity`

Alpha of the default cell background, in `0.0`–`1.0`. `1.0` is fully opaque;
anything less lets the DWM blur-behind region show through, so the desktop
wallpaper / lower windows are visible behind unstyled cells. Cells with an
explicit `bg_color_*` (selection, OSC color cells, highlighted regions) stay
opaque so they remain readable on busy backgrounds.

```
background-opacity = 0.85
```

Default: `0.94`. Out-of-range or non-numeric values are warned and the default
is kept. Hot-reloads — the renderer reads the value live each frame.

### `background-blur`

Whether DWM blur-behind is enabled on the window. With it on (default), the
compositor honors the per-pixel alpha from `background-opacity` so the desktop
shows through translucent cells, with the soft Aero-style blur on Windows 11
builds that still support it. With it off, the blur-behind region is cancelled
and translucent pixels composite as plain black under most modern Windows
compositors — set this if you want an opaque window without changing
`background-opacity`, or if you find the blur visually distracting.

```
background-blur = true
background-blur = false
background-blur = 0          # equivalent to false
background-blur = 20         # any positive integer is treated as true
```

Default: `true`. Accepted values (case-insensitive) mirror Ghostty so a shared
Ghostty config does not warn-and-default to the wrong value:

- `true` / `yes` / `t` / `y`
- `false` / `no` / `f` / `n`
- A non-negative integer (Ghostty's macOS blur radius): `0` → off, `>0` → on.
- `macos-glass-regular` / `macos-glass-clear` (Ghostty's macOS-only glass
  enums) → on, matching Ghostty's own `BackgroundBlur.enabled()`.

Note: this is the legacy `DwmEnableBlurBehindWindow` API, not Mica / Acrylic
via `DWMWA_SYSTEMBACKDROP_TYPE`. Hot-reloads — toggling the key re-invokes
the DWM call and triggers a repaint.

### `maximize`

Whether new windows start maximized. Accepted values (case-insensitive):
`true` / `yes` / `t` / `y`, `false` / `no` / `f` / `n`, or a non-negative
integer (`0` → off, `>0` → on).

```
maximize = true
```

Default: `false`. Applied after the initial `ShowWindow`; combine with
`fullscreen = true` to have toggling fullscreen off restore the maximized
state rather than a normal-sized window.

**Hot-reload:** no (startup only). Editing the key on a running window does
not maximize/restore it — use the title-bar maximize button or `Win+Up`.

### `fullscreen`

Whether new windows start in borderless fullscreen (the same mode reached via
**Full screen** in the system menu / `Alt+Enter`).

```
fullscreen = true
```

Default: `false`. Accepted values (case-insensitive) mirror Ghostty's
`fullscreen` enum so a shared Ghostty config does not warn:

- `true` / `yes` / `t` / `y` → on
- `false` / `no` / `f` / `n` → off
- `non-native` / `non-native-visible-menu` / `non-native-padded-notch`
  (Ghostty's macOS-only variants) → on

Mostty has a single borderless mode, so every "enabled" variant collapses to
the same toggle. Unlike `background-blur`, bare integers and the
`macos-glass-*` enums are **not** accepted here — they belong to a different
Ghostty key and accepting them would silently misroute a typo.

**Hot-reload:** no (startup only). Use `Alt+Enter` or **Full screen** in the
system menu to toggle at runtime.

**Background opacity / blur in fullscreen.** Because Mostty's fullscreen is a
DWM-composited borderless popup (not exclusive / "native" fullscreen),
`background-opacity` and `background-blur` keep working unchanged — the
desktop / lower windows continue to show through translucent cells. This
differs from Ghostty on macOS, where native fullscreen forces opacity off
because the OS swaps the background for a flat gray.

### `render-interval-local-ms` / `render-interval-remote-ms`

Minimum interval (in milliseconds) between rendered frames. Mostty coalesces
render requests behind a `SetTimer`-driven cap so a burst of PTY output does
not fire one `WM_PAINT` per chunk. Two independent caps are kept because the
"right" cadence differs by session type:

- `render-interval-local-ms` — used when running on a local console with a
  hardware GPU. Default `16` (~60 FPS).
- `render-interval-remote-ms` — used when Windows reports a remote session
  (`SM_REMOTESESSION`) or the active DXGI adapter is a software renderer
  (WARP / Microsoft Basic Render Driver). Default `33` (~30 FPS), since every
  frame in an RDP session pays a per-frame encode over the wire.

```
render-interval-local-ms  = 16
render-interval-remote-ms = 33
```

Each value is a positive integer in `1..1000`. Out-of-range or non-numeric
values are warned and the default is kept. `1` is effectively "no throttle";
`1000` is 1 FPS.

The active cap is re-evaluated on every Windows session-state change
(`WM_WTSSESSION_CHANGE` — RDP connect/disconnect, console switch, lock /
unlock), so connecting over RDP to a running Mostty instance switches the
window to the remote cap without a restart. Editing these keys in the config
file also takes effect immediately via the same re-application path (no
restart needed).

### `launcher`

Defines an entry for opening a new tab with a custom command. The value is:

```
launcher = <label> | <command-line> | <working-directory>
```

- `<label>` — display name for the launcher.
- `<command-line>` — the command to run. The first and last `|` delimit the
  fields, so the command-line itself may contain literal `|` (e.g. a pipeline).
- `<working-directory>` — optional. If omitted (only one `|` present), the new
  tab inherits the parent working directory.

```
launcher = PowerShell | powershell.exe
launcher = WSL home | wsl.exe ~ | C:\Users\me
```

May be repeated to define multiple launchers.

### `env`

Inject an environment variable into every newly-spawned tab's child process.
The value is `NAME=VALUE`.

```
env = LANG=en_US.UTF-8
env = LC_CTYPE=zh_CN.UTF-8
env = COLORTERM=truecolor
```

May be repeated. Each entry is one variable; comma lists are not parsed here.

**NAME** must be printable ASCII without spaces or `=`. **VALUE** is UTF-8;
may contain `=` (everything after the first `=` is the value) and may be
empty (`env = FOO=` sets `FOO` to the empty string).

**Precedence.** Config entries replace same-named variables inherited from
the Mostty process environment. Names are compared case-insensitively to
match Windows env semantics (so `env = path=...` replaces a parent `Path`).
If multiple `env` lines share a name, the last one wins.

**`TERM`.** Mostty injects `TERM=xterm-256color` into every child by default.
An explicit `env = TERM=<value>` overrides that default.

**SSH note.** Setting `env = LANG=...` only makes `LANG` available to the
Windows-side shell. To forward it to a remote host over SSH, add `SendEnv
LANG LC_*` to `~/.ssh/config` (the remote `sshd` must accept the same names
via `AcceptEnv`, which macOS/Linux defaults usually do).

---

## Example config

Only real `key = value` lines are valid — do not add `#` comment lines.

```
font-family             = JetBrains Mono, Consolas
font-family-italic      = Cascadia Code
font-size               = 13
font-ligatures          = true
font-style              = SemiBold
font-synthetic-style    = no-italic
font-codepoint-map      = U+1F300-U+1F9FF=Segoe UI Emoji
theme                   = light:Rose Pine Dawn, dark:Rose Pine
background              = #191724
palette                 = 1 = #eb6f92
background-opacity      = 0.85
background-blur         = true
render-interval-local-ms  = 16
render-interval-remote-ms = 33
launcher                = PowerShell | powershell.exe
launcher                = WSL | wsl.exe ~
env                     = LANG=en_US.UTF-8
env                     = LC_CTYPE=zh_CN.UTF-8
```
