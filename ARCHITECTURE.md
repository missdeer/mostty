# Mostty — Architecture & Workflow

A reading guide to the source tree, the runtime model, and the end-to-end data flow
of every key path. Mostty is a Windows-only terminal emulator that pairs Ghostty's
VT state machine (`libghostty-vt`) with a hand-rolled Win32 / D3D11 /
DirectWrite shell.

Pinned versions: Zig `0.15.2`, Windows + MSVC ABI only. Build with
`cmd.exe /c "D:\zig-x86_64-windows-0.15.2\zig.exe build --global-cache-dir D:\zig-cache"`.

---

## 1. Module Layout

```
src/
  mosttywindows.zig        process entry, WinMain shim, main message loop
  Cmdline.zig              --ttf / --font-size parser (currently unused by main())
  Config.zig               1.4 kLOC — config file parser, theme resolution, arena owner
  vendor/ghostty-sprite/   vendored Ghostty sprite face (block/box/braille/...)
  win32/
    mostty.manifest        DPI/UAC manifest
    mostty.rc / icons      Win32 resources
    terminal.hlsl          vertex + pixel shaders (full-screen quad)

    # Process-wide state and types
    global.zig             singleton globals (gpa, config, renderer, window)
    state.zig              Window + Tab structs, render throttle, telemetry
    types.zig              TabId, WM_APP_*, TIMER_*, hit-test enums
    panic.zig / error.zig  panic handler & error utilities
    util.zig               UTF-16 conv, blur, invalidate helpers
    icons.zig              DPI-aware icon load
    window_geom.zig        WINDOWPLACEMENT math, grid-cell snapping, scrollbar
    config_watch.zig       ReadDirectoryChangesW watcher → WM_APP_CONFIG_CHANGED
    launcher.zig           launcher popup menu + ~/.ssh/config host parsing

    # Per-tab plumbing
    child_process.zig      ConPTY spawn, env block, reader thread
    vt_stream.zig          vt.Stream wrapper + Handler effects callbacks
    tab_mgmt.zig           newTab / destroyTab, terminal init, drain protocol
    tab_bar.zig            tab-bar layout + hit testing (paint is in d3d11/)

    # Window procedure (UI thread) — split by message family
    wnd/dispatch.zig       static WndProc dispatch table
    wnd/lifecycle.zig      WM_CREATE / WM_CLOSE / WM_DESTROY / WM_APP_CLOSE_TAB
    wnd/paint.zig          WM_PAINT, WM_WINDOWPOSCHANGED, WM_DPICHANGED
    wnd/keyboard.zig       WM_KEY*, WM_CHAR, WM_SYSKEY*, shortcuts
    wnd/ime.zig            IME composition position anchoring
    wnd/mouse.zig          buttons, wheel, hover, selection, URL hover, mouse-report
    wnd/misc.zig           timers, config reload, fullscreen, theme submenu, app messages

    # Renderer
    d3d11.zig              top-level renderer struct; init / render / resize / deinit
    render.zig             renderWindow orchestration (state → renderer.render)
    GlyphIndexCache.zig    circular-LRU mapping (codepoint,half,style) → atlas slot
    sprite.zig             ghostty-sprite dispatcher + z2d canvas
    d3d11/gpu.zig          device, shaders, const buffer, staging textures
    d3d11/swap_chain.zig   DirectComposition flip-model + adapter classification
    d3d11/grid.zig         persistent grid RTV, scissor draw, blit to back buffer
    d3d11/cell_buffer.zig  shader.Cell builder + per-row shadow-diff upload
    d3d11/font.zig         DirectWrite text formats, fallback chains, metrics
    d3d11/font_state.zig   effective font snapshot, rebuild/reassign on change
    d3d11/glyph.zig        glyph rasterization (DirectWrite + sprite + emoji)
    d3d11/emoji.zig        color-glyph detection, Segoe UI Emoji routing
    d3d11/background_image.zig   async WIC decode, fit/position geometry
    d3d11/tabbar_paint.zig D2D tab-bar band painter
    d3d11/color.zig        palette resolution, faint dim, selection lerp
    d3d11/com.zig          tiny COM Release helpers

    # Higher-level UI features
    paste.zig              clipboard paste, drag-drop, bracketed-paste guard
    url_hover.zig          left/right URL detection across soft-wrapped rows
    tooltip.zig            native TOOLTIPS_CLASS control for tab-bar hover
    mouse_report.zig       X10/SGR/UTF8/SGR_PIXELS mouse-report encoding
```

External modules: `vt` (`ghostty-vt`), `z2d` (Ghostty's 2D vector backend),
`win32` (`zigwin32`, declared `lazy = true` so test runs avoid the heavy
import).

---

## 2. Process & Threading Model

Mostty is a single-process, multi-thread program:

| Thread | Purpose | Notes |
| --- | --- | --- |
| UI thread | Win32 message loop, all D3D11/D2D rendering, all VT stream parsing, all Terminal mutation | The only thread that touches `vt.Terminal` |
| Reader thread (per tab) | Blocks in `ReadFile` on the ConPTY output pipe; `SendMessage` hands bytes to the UI thread | Spawned in `child_process.startConPtyWin32` (before `CreatePseudoConsole`), joined in `tab_mgmt.destroyTab` |
| Config-watch thread (1) | Blocks in `ReadDirectoryChangesW`, posts `WM_APP_CONFIG_CHANGED` | Detached |
| Background-image decode (transient) | WIC decode of `background-image` on hot-reload or first paint | Detached, result posted via `WM_APP_BG_IMAGE_DECODED` |

Ownership rules:

- `vt.Terminal`, the title buffer, `high_surrogate`, and all GPU upload state
  are touched only on the UI thread.
- Reader → UI hand-off is **synchronous** (`SendMessage`, not `PostMessage`).
  The handler returns a magic value (`WM_APP_CHILD_PROCESS_DATA_RESULT =
  0x1bb502b6`) so the reader can `assert` the message wasn't silently dropped
  during teardown.
- Tab close uses `reader_stop` (`std.atomic.Value(bool)`) + `CancelIoEx` to
  unblock the reader, then a drain loop (`MsgWaitForMultipleObjects` on the
  thread handle + queue) before joining and freeing the `Tab` — so any
  in-flight `SendMessage` from the reader completes against a still-valid
  `Tab`.

---

## 3. Startup & Main Loop

Entry sequence in `mosttywindows.zig`:

1. `WinMain` is `@export`-ed because `Subsystem=Windows + MSVC ABI` pulls
   libcmt's `exe_winmain.obj` startup; it delegates to `main()`.
2. `main()`:
   1. Resolves the monitor under the cursor (or explicit window-placement
      hint) and queries its DPI via `GetDpiForMonitor`.
   2. Loads icons at that DPI (`icons_mod.getIcons`).
   3. `Config.loadDefault(gpa)` reads `%LOCALAPPDATA%/Mostty/config`, parses
      it into an arena-backed `Config`, resolves the theme, and folds
      `color_overrides` back over the theme defaults.
   4. Converts the font family/codepoint-map strings to sentinel-terminated
      UTF-16 (allocations leaked into the process arena — they live for the
      whole renderer lifetime).
   5. `d3d11.init(dpi, font_config)` builds the renderer up to a point where
      cell-size is known — actual swap-chain creation is deferred to the first
      `render`.
   6. `window_geom.calcWindowPlacement` snaps a default 70%×80% rect to whole
      cells.
   7. Registers `MosttyWindow` class with `CS_DBLCLKS` (required for
      `WM_LBUTTONDBLCLK` and word selection) and creates the HWND.
   8. Kicks off the async background-image decode (so the 100+ ms WIC decode
      runs alongside `ShowWindow`, not before it).
   9. Sets DWM immersive dark mode + caption color, extends the frame, applies
      blur-behind per config.
   10. `DragAcceptFiles` + `ChangeWindowMessageFilterEx` for `WM_DROPFILES` and
       `WM_COPYGLOBALDATA` — needed when running elevated so Explorer drops
       still arrive.
   11. `ShowWindow` (maximized if configured), `SetForegroundWindow`,
       `BringWindowToTop`, then `config_watch.start(hwnd)`.
3. **Main loop** (`mosttywindows.zig:207`):
   ```
   while (true) {
     // Resolve current window. While no tabs exist, drain WM only.
     window = waitForWindowWithTabs();

     // Wait for tab process death OR window messages.
     wait = MsgWaitForMultipleObjectsEx(
              tab_process_handles, INFINITE,
              QS_ALLINPUT, {ALERTABLE, INPUTAVAILABLE});

     if (wait identifies tab i) {
       // Child process exited.
       if (!tab.closing) {
         tab.closing = true;
         PostMessage(hwnd, WM_APP_CLOSE_TAB, tab.id, 0);
       }
     }
     flushMessages(); // peek-drain the queue
   }
   ```
   The tab-list is re-snapshotted every loop iteration — tabs can close
   mid-flight, so we always look up by `TabId`, never by index across messages.

---

## 4. Win32 Message Dispatch

`wnd/dispatch.zig` exposes `WndProc` and a compile-time-deduplicated
`TABLE: [_]Entry` mapping each handled message ID to a typed
`HandlerFn = fn (hwnd, wparam, lparam) ?win32.LRESULT`. The dispatcher is
`inline for`-unrolled so it lowers to a chain of const compares (~25 entries).
A handler returning `null` falls through to `DefWindowProcW`; this is used by
IME messages, which post-process compositional state but still want OS
default routing.

Handlers by family:

- **Lifecycle** (`wnd/lifecycle.zig`): `WM_CREATE` allocates `global.window`,
  builds the system menu (Fullscreen, Theme submenu placeholder, Open
  Settings...), registers WTS session notifications, creates the tooltip
  control, and spawns the first tab. `WM_CLOSE` runs the "close window and
  all tabs?" confirmation (guarded by `confirming_close` so Alt+F4 hammering
  can't stack nested dialogs). `WM_DESTROY` tears down everything and
  `PostQuitMessage(0)`. `WM_APP_CLOSE_TAB` (custom) routes by `TabId` into
  `tab_mgmt.destroyTab`.

- **Paint** (`wnd/paint.zig`): `WM_ERASEBKGND` returns 1 (DComposition owns
  the background). `WM_PAINT` clears `render_pending`, calls `timedRender`,
  and `noteRender`. `WM_WINDOWPOSCHANGED` reflows the grid: resize the
  `vt.Terminal`, resize the ConPTY (`ResizePseudoConsole`), invalidate. DPI
  change (`WM_DPICHANGED`, `WM_GETDPISCALEDSIZE`) re-runs font/atlas/cell
  metrics.

- **Keyboard** (`wnd/keyboard.zig`): `handleShortcut` intercepts
  Ctrl+T / Ctrl+W / Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+1..9 / Ctrl+PageUp/Down
  before VT dispatch. `vkToSpecial` + `xtermModifier` + `formatSpecialKey`
  encode arrows/F-keys/Home/End/PageX/Insert/Delete using xterm CSI
  sequences (e.g. `\x1b[1;2C` for Shift+Right). Backspace = `\x7f`. Plain
  Tab falls through to `WM_CHAR`; Shift+Tab → `\x1b[Z`. `WM_CHAR` handles
  control-key suppression (so Ctrl+T isn't sent twice), UTF-16 surrogate
  reassembly via per-tab `high_surrogate`, and pushes the final UTF-8 to the
  PTY. Alt+Enter is consumed in `WM_SYSKEYDOWN` (only on the fresh press)
  and routed to `misc.toggleFullscreen`.

- **IME** (`wnd/ime.zig`): `WM_IME_STARTCOMPOSITION` and `WM_IME_COMPOSITION`
  pin the IME UI at the caret pixel via `ImmSetCompositionWindow(CFS_POINT)`;
  `WM_IME_NOTIFY` (candidate open/change) sets a `CFS_EXCLUDE` rect so the
  candidate list won't sit on top of the cell. All three return `null` to
  fall through to `DefWindowProcW`.

- **Mouse** (`wnd/mouse.zig`): the largest module — 884 LoC. Drives a small
  state machine via `Window.mouse_capture`:

  ```
  none ──┬─► selecting       (left-press inside grid, no mouse-report)
         ├─► scrollbar_drag  (left-press inside scrollbar)
         └─► mouse_report    (left/middle/right press while VT mode active)

  Each transition pairs with SetCapture(); release runs the dedicated exit:
   - selecting    → copy selection to clipboard, arm TIMER_SELECTION_FADE
   - scrollbar_drag → reset, requestRender
   - mouse_report → send SGR/X10 release report; clear mouse_report_tab_id
  ```

  Mouse-report capture pins the originating tab id (`mouse_report_tab_id`)
  so a Ctrl+Tab mid-drag doesn't steer reports into the wrong tab. The
  scroll wheel accumulates in `Window.wheel_accum` and only steps when it
  crosses `WHEEL_DELTA = 120` — hi-res wheels and precision touchpads
  deliver many sub-notch deltas per physical click, and stepping per
  message would race the viewport. URL hover detection is throttled at
  the cell level: `Window.hover_cell` remembers the last `(tab, col, row)`
  and skips `url_hover.detectAt` while the mouse stays inside that cell.

- **Misc / app messages** (`wnd/misc.zig`):
  - `WM_TIMER` dispatches by id: `TIMER_SELECTION_FADE` decays
    `Window.selection_fade`; `TIMER_CONFIG_RELOAD` debounces and runs
    `reloadConfig`; `TIMER_TEXT_BLINK` ticks SGR blink phase;
    `TIMER_RENDER_FRAME` is the render throttle (see §6).
  - `WM_APP_CHILD_PROCESS_DATA` is the reader-thread → UI hand-off:
    feeds the byte slice to `Tab.vt_stream.nextSlice`, increments the
    per-second PTY byte counter, calls `requestRender`, and **returns
    `WM_APP_CHILD_PROCESS_DATA_RESULT`**.
  - `WM_APP_CONFIG_CHANGED` arms `TIMER_CONFIG_RELOAD` so multiple
    in-burst editor saves collapse into one reload (`CONFIG_RELOAD_DEBOUNCE_MS = 150`).
  - `WM_APP_BG_IMAGE_DECODED` accepts the heap-owned decoded pixels from
    the WIC worker, applies the `req_id` staleness check, and uploads to a
    GPU texture.
  - `WM_INITMENUPOPUP` (system menu) lazily builds the theme submenu —
    bucketed by first character (0-9, A-Z, #), capped at `MAX_THEME_ITEMS
    = 1024` so Ghostty's ~460 themes fit comfortably.
  - `WM_DROPFILES` and `WM_DEVICECHANGE`/`WM_SETTINGCHANGE` (OS dark/light
    flip) plug in here.

---

## 5. Tabs, ConPTY, and the VT Stream

### 5.1 Tab lifecycle (`tab_mgmt.zig`)

`newTab`/`newTabWithLauncher`:

1. Bounds-check against `MAX_TABS = 32`.
2. Allocate `Tab` (gpa).
3. Pick the grid size (`window_geom.computeGridCellCount`).
4. `ChildProcess.startConPtyWin32`:
   - Create input pipe (PTY-read / our-write) and output pipe (our-read /
     PTY-write) with inheritable handles.
   - Spawn `readConsoleThread` (`std.Thread`) on `our_read` — it blocks in
     `ReadFile` until the PTY produces bytes or `CancelIoEx` wakes it. The
     thread is created **before** `CreatePseudoConsole` so the `errdefer
     thread.join()` chain unwinds cleanly if any later step fails.
   - `CreatePseudoConsole(size, pty_read, pty_write, 0)` → `HPCON`; close
     the PTY-side pipe ends now that the PTY owns them.
   - Build a process attribute list with
     `PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE`.
   - Merge env: `GetEnvironmentStringsW` + per-launcher `env` overrides,
     case-insensitive last-wins dedup, then force `TERM=xterm-256color`
     unless overridden.
   - `CreateProcessW(CREATE_SUSPENDED)` so the job object can be applied,
     then `ResumeThread`.
5. Allocate `vt.Terminal` (page allocator) at the chosen size and apply
   theme colors.
6. Wrap it in `vt_stream.Handler` with effects callbacks (`title_changed`,
   `write_pty`, `device_attributes`, `xtversion`, `size`).
7. Append, set active, `Window.onActiveChanged` (resets viewport, clears
   selection, drops URL hover, requests render).

`destroyTab`:

1. `tab.closing = true` (drops future reader payloads at the handler).
2. `tab.reader_stop.store(true, ...)` + `CancelIoEx(read_handle)` to unblock
   the reader.
3. **Drain loop**: `MsgWaitForMultipleObjects` on `[thread, queue]` until the
   thread handle signals; while waiting, pump messages so any in-flight
   `SendMessage` from the reader can complete. Without this drain, freeing
   the `Tab` while a reader `SendMessage` is on the UI thread queue would
   wake up against a freed `vt.Terminal`.
4. `closePty()` (closes the our-write side and `ClosePseudoConsole`s the
   `HPCON`) — this is what makes the reader's `ReadFile` return
   `ERROR_BROKEN_PIPE` once the child has consumed any in-flight output.
5. `thread.join()` the reader.
6. Close the read pipe, the job (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` kills
   any orphans the child spawned), and the process handle — in that order.
7. Deinit `vt_stream`, `term_arena`, `vt.Terminal`.
8. If the window has no tabs left, `PostMessage(WM_QUIT)`; else
   `onActiveChanged`.

### 5.2 Reader thread (`child_process.zig:readConsoleThread`)

```
loop:
  ReadFile(read, buf, 4096, &n, null)
    on ERROR_BROKEN_PIPE | ERROR_HANDLE_EOF      → exit (child died)
    on ERROR_OPERATION_ABORTED                   → exit (CancelIoEx)
  if reader_stop.load(.acquire): exit
  msg = ReadMsg{ tab_id, ptr, n }
  result = SendMessageW(hwnd, WM_APP_CHILD_PROCESS_DATA, @intFromPtr(&msg), 0)
  std.debug.assert(result == WM_APP_CHILD_PROCESS_DATA_RESULT)
```

Magic-value assertion is the contract: silent drops during teardown are
treated as a bug.

### 5.3 `vt.Stream` wrapper (`vt_stream.zig`) and effects (`tab_mgmt.zig`)

`vt_stream.zig` is a thin wrapper around `vt_mod.TerminalStream.Handler`.
Its only behavioural addition is **wide-char repair**
(`repairCursorCellForPrint`): before delegating `.print` / `.print_repeat`,
it clears stale `wide` / `spacer_tail` / `spacer_head` state on the cell
about to be overwritten, so a partial wide-char overwrite can't leave the
page in an inconsistent state.

Everything else the parser would normally side-effect on (title changes,
PTY writeback, device attributes / xtversion / size reports) is supplied as
free functions in `tab_mgmt.zig`, packed into a
`vt_mod.TerminalStream.Handler.Effects` struct at tab creation
(`tab_mgmt.zig:185`):

- **`onTitleChanged`** (`tab_mgmt.zig:33`): walks back via `@fieldParentPtr`
  to the owning `Tab`, copies into `title_buf`, refreshes the tooltip if it
  is already showing, and requests render.
- **`onWritePty`** (`tab_mgmt.zig:53`): sends parser replies (Device
  Attributes, `CSI 18 t` size reports, `xtversion`, DECRQM) straight to
  `ChildProcess.writeFlushAll`.
- **`onDeviceAttributes`**, **`onXtVersion`**, **`onSize`**: compose the
  reply payloads.

The flow per chunk of PTY bytes is:

```
ReadFile bytes
  → SendMessage(WM_APP_CHILD_PROCESS_DATA)
    → Tab.vt_stream.nextSlice(slice)
      → vt.Stream parser dispatches: print, control, CSI, OSC, DCS, ...
        → Handler effects mutate Tab.term (screen state)
        → write-PTY replies (CSI 18 t etc.) go back via ChildProcess
    → window.notePtyBytes(n)
    → window.requestRender()
  → return WM_APP_CHILD_PROCESS_DATA_RESULT to the reader
```

---

## 6. Rendering Pipeline

### 6.1 Top-level renderer (`d3d11.zig`)

The `d3d11` struct owns:

- `device`, `context` (created lazily at first `init`),
- compiled vertex/pixel shaders from `terminal.hlsl`,
- `GridConfig` constant buffer,
- `font` / `font_state` (DirectWrite text formats, cell metrics, fallback
  chains),
- `glyph_cache` (`GlyphIndexCache`) + glyph atlas texture + two D2D staging
  textures (mask for ClearType, color for emoji),
- swap chain (created on first frame via DirectComposition: an
  `IDXGISwapChain1` cast to `IDXGISwapChain2`, bound to a DComposition
  visual and pushed to the HWND),
- a persistent `grid_texture` + sRGB RTV the size of the client (see §6.4),
- shadow `shader.Cell` buffer for the per-row diff upload (§6.3),
- background-image state (CPU pixels + GPU SRV + decode req-id + worker
  thread join state).

Public entry points: `init`, `deinit`, `updateDpi`, `updateFont` (both
trigger `font_state.rebuildAndAssign` → glyph cache reset + force full
redraw), `reloadBackgroundImage`, and `render`.

### 6.2 Per-frame orchestration

`render.zig:renderWindow` is the only caller of `renderer.render`. It
reads the active `Tab.term`, computes selection/cursor state, and hands
everything to:

1. **prepareFrame** (`d3d11.zig`): client-size query; swap-chain
   create-or-resize; cheap occlusion test (`Present(0, TEST)`); ensure
   persistent grid RTV; compute grid dims and atlas size; diff
   `ConfigSnapshot` (cell metrics / scrollbar / tab-bar) against the prior
   frame; write `GridConfig` constants (cell size, counts, scrollbar,
   `bg_image_dest`).
2. **buildAndUpload** (`d3d11/cell_buffer.zig`): per-row, build a scratch
   `[]shader.Cell` from terminal screen + style + selection + cursor + URL
   hover + resize overlay, compare against `shadow_cells`, and only call
   `UpdateSubresource` for changed rows. Glyph indices come from the LRU
   cache; misses trigger DirectWrite or sprite rasterization (§6.5).
3. **drawAndCopy** (`d3d11/grid.zig`): if anything is dirty (or
   `grid_force_full` is set by font/DPI/resize), bind the grid RTV with a
   scissor rectangle covering the dirty row range, draw a full-screen
   quad as a 4-vertex triangle strip (`context.Draw(4, 0)`; the vertex
   shader generates the corners from `SV_VertexID`), then
   `CopyResource(back_buffer, grid_texture)`.
4. **paintChromeAndPresent** (`d3d11.zig`): D2D-paint the tab-bar band into
   its own offscreen target, `CopySubresourceRegion` it onto the back
   buffer's top strip, then `Present(0|1, 0)` (sync interval depends on
   the adapter classification from §6.6).

### 6.3 Cell buffer & per-row diff

```hlsl
struct Cell {
    uint  glyph_index;   // atlas slot
    Rgba8 background;    // includes opacity in alpha
    Rgba8 foreground;
    uint  attrs;         // SGR flags: underline / strike / over / invisible / color_glyph
};
StructuredBuffer<Cell> cells;
```

The CPU shadow (`shadow_cells`) is a page-allocator slice grown to `cols *
rows`. `uploadCellRow` does a `memcmp` against the row segment and skips the
`UpdateSubresource` on unchanged rows. Steady-state typing touches only the
cursor row plus any scrolled rows.

Color resolution (`d3d11/color.zig`):

- Palette / RGB resolved from `vt.Style`.
- Inverse swaps fg/bg.
- Faint dims fg in linear space via a precomputed gamma-2.2 LUT to avoid
  the "naïve halve" black-out.
- Selection fade lerps cell colors toward `selection_bg/fg` via
  premultiplied-alpha-safe lerp, driven by `Window.selection_fade`.
- Default-bg cells inherit `background_opacity` (so DWM blur and the
  background image show through), explicit-bg cells stay opaque.

### 6.4 Persistent grid texture & partial draw

The grid is drawn into a `B8G8R8A8_TYPELESS` texture with an sRGB RTV view,
which lets the shader output linear floats and the store path encode sRGB
without a separate post-pass. The full texture is `CopyResource`'d to the
back buffer each frame. The reason for the persistent texture: with the
flip-model swap chain, the back-buffer contents after `Present` are
undefined — there's no way to do a partial draw directly onto it.

Scissor (`ensureScissorRasterizerState`) is set from the dirty row range
returned by `buildAndUpload`, so the pixel shader is only invoked over the
rows that actually changed.

### 6.5 Glyph atlas, cache, rasterization

`GlyphIndexCache.zig` is a circular doubly-linked list + hashmap LRU keyed
by `(codepoint, grapheme, half, style)`. Capacity equals atlas slots
(`tex_cell_count.x * tex_cell_count.y`). Two important quirks:

- **Per-frame dampening**: a hit only promotes to MRU once per frame
  (`touched_frame` matches the renderer's `frame_id`). Without this, a
  full-screen of cells would relink the list O(cols·rows) times per frame.
- **`touch()` is unconditional**: used by `generateWidePair` to make sure
  the right half can't evict the left half when both are reserved in the
  same call.

On a miss, `glyph.zig:generateGlyph` picks a path:

- **Sprite fast path** (`hasCodepoint`): block elements, box drawing,
  braille, powerline, geometric shapes, and legacy computing symbols are
  rasterized procedurally via `sprite.zig` (which dispatches to the
  vendored Ghostty draw functions). The z2d canvas produces alpha-8;
  `sprite.zig` gamma-encodes the alpha and replicates it across BGRA so
  the shader's ClearType-decoding path (`pow(c, 2.2)`) sees a uniform
  grayscale coverage.
- **DirectWrite path** (`renderGlyphToStaging`): build an
  `IDWriteTextLayout` over the format selected by current style and
  emoji-routing rules, measure ink bounds, optionally center / scale for
  ambiguous symbols (●✶★), render to the mask staging texture for
  ClearType text or the color staging texture for COLR/CBDT emoji, then
  `copyStagingHalfToAtlas` into the slot.

Both staging textures are pinned to 96 DPI + PIXEL unit mode so DIPs map
1:1 to atlas pixels.

### 6.6 DirectWrite font selection

`font.zig` builds four `IDWriteTextFormat`s (regular/bold/italic/bi). Each
gets its own custom `IDWriteFontFallback` chain composed in this order:

```
1. font-codepoint-map entries (per-codepoint family override)
2. style-primary family (font-family-bold etc., if user set)
3. regular primary family (font-family)
4. user fallbacks (extra entries in font-family)
5. built-in Emoji (Segoe UI Emoji)
6. system fallback
```

Synthetic bold/italic via DirectWrite weight/slant kicks in only when the
real face is missing and `font_synthetic_style.*` is enabled.

Cell size comes from canonical design metrics (`designUnitsPerEm` + `M`
advance) rather than measuring a specific glyph, so weight changes don't
shift monospace alignment.

### 6.7 Tab-bar paint, background image, chrome

- **Tab bar** (`d3d11/tabbar_paint.zig`): proportional D2D painter — for
  each tab, fills a rectangle (active/hover/inactive color) and draws the
  title with the tab-bar text format, then centers `×` (close) and `+`
  (new tab). The band is painted into an offscreen 96-DPI target and
  copied onto the top strip of the back buffer. Cells start *below* the
  band: `SV_Position.y - tab_bar_height` in the pixel shader.
- **Background image**: `reloadBackgroundImage` increments
  `bg_image_req_id` to stale any in-flight worker, then detaches
  `decodeWorker` which calls `gpu.decodeBackground` (WIC), posts
  `WM_APP_BG_IMAGE_DECODED` with a heap envelope; `applyDecoded` rechecks
  `req_id` (drops stale results), then `gpu.uploadBackground`.
  `computeDest` runs each frame for fit (`none/stretch/contain/cover`) and
  position; the pixel shader composites OVER cell bg with premultiplied
  alpha, so opaque cells properly mask the image (matches Ghostty).
- **Adapter classification** (`swap_chain.zig:detectAdapter`): inspects
  vendor id + name to detect WARP / Basic Render / RDP. Hardware adapters
  use `Present(0, 0)` (async / tearing-allowed); software / remote
  adapters use `Present(1, 0)` so the producer back-pressures. This same
  classification drives the render-interval throttle (§7).

---

## 7. Render Throttle

`Window.requestRender` and `scheduleRender` (`state.zig`) implement a
soft frame cap:

- `render_interval_ms` is recomputed by `applyRenderInterval` from
  `(local_ms, remote_ms, remote_or_software_adapter)`. It picks the
  remote cap when either `SM_REMOTESESSION` is set or the boot-time
  adapter probe flagged the GPU as remote/software. Triggered at create,
  on `WM_WTSSESSION_CHANGE`, and after config reload.
- `requestRender` sets `render_pending = true` and:
  - If `now - last_render_tick_ms >= render_interval_ms`,
    `InvalidateRect` immediately.
  - Else `SetTimer(TIMER_RENDER_FRAME, delay, null)` to fire when the
    budget expires (and sets `render_timer_armed`). If `SetTimer` fails,
    we deliberately do **not** set `render_timer_armed` — that would
    freeze the renderer until the next external repaint — and instead
    fall back to immediate invalidate.
- `WM_PAINT` clears `render_pending` before calling render, so events
  *during* render still schedule the next frame.
- 1-second diagnostic flush (`logDiagnostics`) reports fps cap,
  renders/s, busy ms/s, max single-frame µs, and PTY bytes/s.

---

## 8. Configuration & Hot Reload

`Config.zig` (1.4 kLOC) owns:

- An optional `arena: ?std.heap.ArenaAllocator` from which **every** slice
  in the struct allocates (font families, theme name, launcher cmdlines,
  env entries, codepoint maps). `ThemeColors` is a pure value type
  (`?u24` per slot) so it copies safely once parsed.
- `ColorOverrides` records which fields the user explicitly set in the
  config file; on theme hot-switch, those overrides are replayed *over*
  the new theme's defaults so explicit choices survive theme changes.

Loading:

1. `loadDefault(gpa)` → `defaultPath` = `%LOCALAPPDATA%/Mostty/config`.
   Missing file or missing `LOCALAPPDATA` returns an empty default.
2. `loadDefaultChecked` is the reload variant — it distinguishes
   read-failure (`ReloadError.ReadFailed`, surfaced so the watcher can
   retry up to 3 times) from absent-file.
3. `parse` builds the struct line-by-line into the arena.

Theme resolution:

1. `resolveThemeName` parses `theme = light:A, dark:B` and picks the
   variant matching `SHOULD_SYSTEM_USES_LIGHT_THEME`. Absolute paths
   bypass.
2. `findThemeFile` searches `%LOCALAPPDATA%/Mostty/themes/<name>` then
   `<exeDir>/themes/<name>`. `build.zig` installs the bundled themes
   directory into `zig-out/bin/themes/` so the second path always works
   for an installed build.

Hot reload pipeline:

```
filesystem change
  → ReadDirectoryChangesW thread (config_watch.zig)
  → PostMessage(WM_APP_CONFIG_CHANGED)
  → arm TIMER_CONFIG_RELOAD (150 ms debounce coalesces save bursts)
  → reloadConfig:
       parse → diff against current global.config
       if font changed:   renderer.updateFont, reflow all Tab.term + ConPTY
       if theme changed:  rebase term colors, sync theme submenu check
       if blur changed:   util.applyBlurBehind
       if image changed:  renderer.reloadBackgroundImage
       on read failure:   retry up to 3× via TIMER_CONFIG_RELOAD
  → requestRender
```

`WM_SETTINGCHANGE` for `"ImmersiveColorSet"` (OS light/dark flip) also
funnels through `reloadConfig` so `light:A, dark:B` themes flip live.

---

## 9. Key Data Flows (cross-reference)

### 9.1 PTY → screen → frame

```
shell stdout
  → ConPTY pipe
  → readConsoleThread (per tab)
  → SendMessage(WM_APP_CHILD_PROCESS_DATA, &ReadMsg)
  → vt_stream.nextSlice → vt.Stream parser → Handler effects
  → mutate Tab.term
  → notePtyBytes / requestRender
  → reader unblocks (handler returns magic value)
[later, on render throttle expiry]
  → WM_PAINT
  → render.renderWindow
  → d3d11 prepareFrame → buildAndUpload → drawAndCopy → paintChromeAndPresent
```

### 9.2 Keyboard → PTY

```
WM_KEYDOWN
  → handleShortcut (Ctrl+T/W/Tab/1..9/PgUp/PgDn etc.) — consume
  → else vkToSpecial + xtermModifier → write CSI
WM_CHAR
  → drop control duplicates that KEYDOWN already handled
  → reassemble UTF-16 surrogates via per-tab high_surrogate
  → encode to UTF-8 → ChildProcess.writeFlushAll
```

### 9.3 Tab open / close

```
newTab:
  alloc Tab
  startConPtyWin32 (creates pipes → spawns readConsoleThread →
                    CreatePseudoConsole → CreateProcessW → ResumeThread)
  alloc vt.Terminal → wrap in vt_stream.Handler with tab_mgmt effects
  append, set active, onActiveChanged, requestRender

destroyTab:
  closing = true                  (handler drops further payloads)
  unhook from window.tabs         (re-entrant findById returns null)
  reader_stop.store(true) + CancelIoEx(read)
  MsgWaitForMultipleObjects drain (pump WM_SENDMESSAGE until thread signals)
  closePty()                      (close our_write + ClosePseudoConsole)
  thread.join()
  close read pipe, job, process handle
  deinit vt_stream, Terminal, arenas
  if tabs.len == 0: PostMessage(WM_QUIT)
```

### 9.4 Mouse selection

```
WM_LBUTTONDOWN (no Shift, no mouse-report)
  → mouse_capture = .selecting, SetCapture, pin selection start
WM_MOUSEMOVE (capture .selecting)
  → clamp to grid, update selection end, requestRender
WM_LBUTTONUP (capture .selecting)
  → ReleaseCapture
  → screen.selectionString → paste.copyToClipboard
  → arm TIMER_SELECTION_FADE (16 ms tick, fade over ~1 s)
```

### 9.5 Mouse-report

```
PTY enables mouse mode (SET DEC mode)
WM_LBUTTONDOWN (mouse_report.enabled(), not Shift)
  → encode (X10/SGR/UTF8/SGR_PIXELS) → write to PTY
  → mouse_capture = .mouse_report, mouse_report_tab_id = active.id
WM_MOUSEMOVE
  → if button still down, encode motion → write to PTY
WM_LBUTTONUP
  → release report → write to PTY → clear capture
```

---

## 10. Invariants & Gotchas

- **Never index tabs by position across messages.** Tabs can close
  mid-flight. Use `findById` / `findIndexById`.
- **Reader-thread `SendMessage` must return the magic value.** That's how
  we detect silent drops during teardown.
- **`tab.closing` is set together with `reader_stop` + `CancelIoEx`.**
  The drain loop pumps messages until the reader thread exits.
- **`vt.Terminal` is UI-thread-only.** No locks; the contract is enforced
  by the single-consumer hand-off.
- **`high_surrogate` is per-tab.** Switching the active tab between the
  high and low `WM_CHAR` would otherwise smear the surrogate.
- **`render_timer_armed` must not be set if `SetTimer` failed** — that
  would freeze the renderer.
- **Persistent grid RTV is required** for partial redraw because
  flip-model back-buffer contents are undefined post-`Present`.
- **Custom title-bar color is set via `DwmSetWindowAttribute`** — there's
  no separate Win32 caption control; the tab bar lives inside the same
  D3D11 client area.
- **DragAcceptFiles + ChangeWindowMessageFilterEx** are both needed when
  elevated, otherwise lower-integrity Explorer drops are silently
  rejected by UIPI.
- **Background-image decode has a request id.** Hot-reloads supersede
  in-flight workers; `applyDecoded` drops anything with a stale id.
- **`showLauncherMenu` must dupe `global.config.launchers` into a local
  arena before `TrackPopupMenu`.** That call enters a modal message loop;
  a `TIMER_CONFIG_RELOAD` firing inside it would deinit the arena backing
  `global.config.launchers` and dangle the slice we index after the menu
  returns.
- **The temp directory is `${project_root}/tmp`**, never `/tmp` (per
  `CLAUDE.md`).
- **All `zig.exe` invocations must be wrapped in `cmd.exe /c`** (per
  project memory).
