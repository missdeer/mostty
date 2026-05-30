# mostty Configuration

mostty is configured through a single plain-text config file. There are no
working command-line options today; everything below lives in the config file.

## File location

```
%LOCALAPPDATA%\mostty\config
```

The file has no extension. You can open (and create) it from the window's system
menu via **Open Settings File…**, which launches it in Notepad and creates the
file and its parent folder if missing.

## Syntax

- One `key = value` per line. Whitespace around the key and value is trimmed.
- UTF-8. A leading UTF-8 BOM (added by some Windows editors) is tolerated.
- There is **no comment syntax**. A line without `=` is reported as a warning
  and skipped, so do not use `#`/`//` comment lines.
- Unknown keys produce a warning. A small set of Ghostty keys that mostty has no
  feature for is accepted-and-ignored silently (so a ported Ghostty config does
  not spam warnings): `split-*`, `search-*`, `window-titlebar-*`,
  `unfocused-split-fill`, `palette-generate`, `palette-harmonious`, `config-file`.

## Hot reload

The file is watched live. Saving it re-applies changes without a restart:

- **Font** changes rebuild the renderer and reflow every tab.
- **Theme/color** changes re-baseline every tab's colors (preserving any live
  `OSC 10/11/12/4` color overrides an app set at runtime).
- **Launchers** are read on demand, so they take effect immediately.

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

**Variant selection.** With the `light:`/`dark:` form, mostty picks the variant
that matches the current Windows *Apps* light/dark mode
(`HKCU\…\Themes\Personalize\AppsUseLightTheme`) and **automatically re-selects**
when you toggle Windows light/dark mode at runtime. If only one of the two is
given, that one is used.

**Theme search order** (a bare name, not an absolute path):

1. `%LOCALAPPDATA%\mostty\themes\<name>` — your overrides.
2. `<exe directory>\themes\<name>` — the bundled themes shipped next to
   `mostty.exe` (installed by `zig build`).

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

---

## Example config

Only real `key = value` lines are valid — do not add `#` comment lines.

```
font-family = JetBrains Mono, Consolas
font-size = 13
theme = light:Rose Pine Dawn, dark:Rose Pine
background = #191724
palette = 1 = #eb6f92
launcher = PowerShell | powershell.exe
launcher = WSL | wsl.exe ~
```
