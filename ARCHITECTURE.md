# Mostty — Architecture & Workflow

A reading guide to the source tree, the runtime model, and the end-to-end data flow
of every key path. Mostty's runnable application is currently a Windows terminal
emulator that pairs Ghostty's VT state machine (`libghostty-vt`) with a hand-rolled
Win32 / D3D11 / DirectWrite shell. The macOS target builds the platform-neutral
terminal core, a native PTY/session layer, and a CoreText/Metal renderer, driven
by a Swift/AppKit application (`src/macos/app/`) through a C-ABI boundary
(`src/macos/capi.zig`); every VT-touching call runs on the main thread, and only
the background PTY reader runs off it.

Pinned versions: Zig `0.16.0`, Vulkan SDK `1.4.350.0` in CI. The Windows application requires the MSVC ABI, Windows SDK `fxc.exe`, Windows SDK `dxc.exe` with `dxil.dll` beside it (signed DXIL for D3D12; the Vulkan SDK DXC cannot sign), and Vulkan SDK `dxc.exe` / `spirv-cross.exe` / `glslangValidator.exe` / `spirv-val.exe`. The macOS core target does not discover or depend on those Windows tools. Build the Windows application with
`cmd.exe /c "D:\zig-x86_64-windows-0.16.0\zig.exe build --global-cache-dir D:\zig-cache"`.

---

## 1. Module Layout

```
src/
  mosttywindows.zig        process entry, WinMain shim, main message loop
  mosttymacos.zig          macOS static-core library entry
  terminal/Session.zig     platform-neutral VT state, stream, and effects owner
  terminal/url_hover.zig   shared viewport URL detection for Windows and macOS
  terminal/mouse_report.zig shared VT mouse-report encoding for Windows and macOS
  terminal/key_encode.zig shared xterm special-key encoding
  terminal/paste.zig       shared streaming paste framing and normalization
  SplitLayout.zig          platform-neutral split tree, pane IDs, focus and geometry
  layout_capi.zig          UI-thread-only C ABI for the shared split model
  ssh_config.zig          shared top-level SSH Host alias iterator
  input_capi.zig          allocation-free host bridge for keys, paste, SSH aliases
  macos/PtySession.zig     macOS shell process, PTY, and VT session owner
  macos/GridModel.zig      VT viewport to resolved renderer-cell conversion
  macos/CoreTextRenderer.zig CoreText rasterization and renderer resource owner
  macos/MetalBackend.zig   Metal texture upload and render-pass submission
  Cmdline.zig              startup options, including the per-process renderer override
  Config.zig               1.4 kLOC — config file parser, theme resolution, arena owner
  vendor/ghostty-sprite/   vendored Ghostty sprite face (block/box/braille/...)
  renderer/sprite.zig      shared ghostty-sprite dispatcher and alpha/BGRA output
  renderer/cell_style.zig  shared VT colors, SGR flags, explicit-background resolution
  renderer/emoji.zig       shared Unicode emoji presentation and UTF-16 encoding
  renderer/font_policy.zig shared style suppression and programming-symbol rules
  renderer/background_geometry.zig shared wallpaper fit/position geometry
  renderer/image_pixels.zig shared Kitty decoded-pixel conversion to RGBA
  renderer/image_geometry.zig shared image source crop and viewport row arithmetic
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

    # Per-tab / per-pane plumbing
    child_process.zig      ConPTY spawn, env block, reader thread per pane
    tab_mgmt.zig           Windows tab, pane and session lifecycle
    pane_native.zig        child HWNDs, per-pane surfaces and layout reflow
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
    Renderer.zig          stable facade + tagged backend union
    PaneSurface.zig       pane backend dispatch, synchronization and cache lifetime
    RendererCommon.zig    backend-independent metrics/adapter state
    FontService.zig       process-lifetime DirectWrite/D2D + font D3D11 owner
    d3d11.zig              top-level renderer struct; init / render / resize / deinit
    d3d12/renderer.zig     selectable D3D12 research renderer
    dcomp.zig              shared DXGI composition swapchain + DComp visual
    dcomp_blit.zig         shared D3D11 full-screen composition presenter
    gl46.zig               selectable OpenGL 4.6 renderer + WGL fallback
    gl46/interop.zig       optional WGL/D3D11 DirectComposition bridge
    gl46/loader.zig        checked-in zigglgen OpenGL 4.6 core bindings
    vulkan.zig             shared Vulkan renderer + presentation dispatch
    vulkan/core.zig        Vulkan device, resources, frames, WSI, external API
    vulkan/bridge.zig      Vulkan/D3D11 memory + timeline interop
    vulkan/loader.zig      checked runtime Vulkan procedure tables
    render.zig             renderWindow orchestration (state → renderer.render)
    GlyphIndexCache.zig    circular-LRU mapping (codepoint,half,style) → atlas slot
    d3d11/gpu.zig          device, shaders, const buffer, staging textures
    d3d11/swap_chain.zig   DirectComposition flip-model + adapter classification
    d3d11/grid.zig         persistent grid RTV, scissor draw, blit to back buffer
    d3d11/cell_buffer.zig  shader.Cell builder + per-row shadow-diff upload
    d3d11/font.zig         DirectWrite text formats, fallback chains, metrics
    d3d11/font_state.zig   effective font snapshot, rebuild/reassign on change
    d3d11/glyph.zig        glyph rasterization (DirectWrite + sprite + emoji)
    d3d11/emoji.zig        color-glyph detection, Segoe UI Emoji routing
    d3d11/background_image.zig   async WIC decode, fit/position geometry
    d3d11/kitty_images.zig per-pane Kitty image texture cache + draw pass
    d3d11/tabbar_paint.zig D2D tab-bar band painter
    d3d11/color.zig        palette resolution, faint dim, selection lerp
    d3d11/com.zig          tiny COM Release helpers

    # Higher-level UI features
    png_decode.zig         WIC PNG decode for Kitty f=100 payloads
    paste.zig              clipboard paste, drag-drop, bracketed-paste guard
    tooltip.zig            native TOOLTIPS_CLASS control for tab-bar hover
```

External modules: `vt` (`ghostty-vt`), `z2d` (Ghostty's 2D vector backend),
`win32` (`zigwin32`, declared `lazy = true` so test runs avoid the heavy
import).

---

## 2. Process & Threading Model

Mostty is a single-process, multi-thread program. A Windows tab owns a SplitLayout; each leaf owns a child HWND, ConPTY, TerminalSession, PTY ring and isolated drawing cache. The process FontService and GPU device/shaders are shared across pane surfaces.

| Thread | Purpose | Notes |
| --- | --- | --- |
| UI thread | Win32 message loop, all D3D11/D2D rendering, all VT stream parsing, all Terminal mutation | The only thread that touches `vt.Terminal` |
| Reader thread (per pane) | Blocks in `ReadFile` on the ConPTY output pipe; memcpy's bytes into `Pane.pty_ring` (SPSC) and `PostMessageW`s a wake-up | Spawned in `child_process.startConPtyWin32` (before `CreatePseudoConsole`), joined in `tab_mgmt.releasePane` |
| Config-watch thread (1) | Blocks in `ReadDirectoryChangesW`, posts `WM_APP_CONFIG_CHANGED` | Detached |
| Background-image decode (transient) | WIC decode of `background-image` on hot-reload or first paint | Detached, result posted via `WM_APP_BG_IMAGE_DECODED` |

Ownership rules:

- `vt.Terminal`, the title buffer, `high_surrogate`, and all GPU upload state
  are touched only on the UI thread.
- Reader → UI hand-off is **asynchronous** via a per-pane SPSC byte ring
  (`src/win32/pty_ring.zig`) plus `PostMessageW(WM_APP_CHILD_PROCESS_DATA,
  wparam=pane_id)`. The reader memcpy's `ReadFile` output into the ring;
  the UI thread drains bounded 256-byte slices for a small initial budget
  (~2 ms) and arms a short `TIMER_PTY_DRAIN` continuation while data
  remains. Continuations use a larger backlog budget (~8 ms) so the UI
  stays responsive without starving PTY throughput.
  Notification is edge-triggered via an atomic `posted` bool: at most one
  wake-up chain is in flight per pane. When the ring is full the reader
  parks on the ring's auto-reset `wake_event`; the UI thread signals that
  event on every drain.
- Pane close uses `reader_stop` (`std.atomic.Value(bool)`) + `CancelIoEx`
  (unblocks `ReadFile`) + `SetEvent(pty_ring.wake_event)` (unblocks a
  full-ring writer), then a direct `thread.join` — no UI message pump
  needed, because the reader no longer calls into the UI thread
  synchronously. Stale `WM_APP_CHILD_PROCESS_DATA` posts that race with
  teardown resolve via `findById(pane_id) → null` and drop harmlessly;
  pane IDs are monotonic and never reused.

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
      `color_overrides` back over the theme defaults. `Cmdline` then applies
      per-process renderer, background-opacity, and background-blur overrides
      before renderer capability selection.
   4. Converts the font family/codepoint-map strings to sentinel-terminated
      UTF-16 (allocations leaked into the process arena — they live for the
      whole renderer lifetime).
   5. The process-global `Renderer` is initialized in place with the selected
      backend (D3D11 by default). Its common state owns the cell metrics used
      by the rest of the application; window-bound presentation resources are
      deferred until the HWND exists.
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
   11. `ShowWindow` (maximized if configured or requested by the launcher), `SetForegroundWindow`,
       `BringWindowToTop`, then `config_watch.start(hwnd)`.
3. **Main loop**: snapshot all pane process handles, then call
   `MsgWaitForMultipleObjectsEx` for a process exit or queued messages. A signaled
   process sets that pane closing and posts `WM_APP_CLOSE_PANE` with its ID.
   The next iteration rebuilds the snapshot; message handlers resolve IDs through
   `Window.panes`, never indices retained across dispatch. The 63-pane limit
   leaves one slot for window messages in the Win32 wait set.

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
  `PostQuitMessage(0)`. `WM_APP_CLOSE_TAB` resolves a tab ID and releases all its
  panes; `WM_APP_CLOSE_PANE` resolves a pane ID and collapses only that leaf.

- **Paint** (`wnd/paint.zig`): `WM_ERASEBKGND` returns 1 (DComposition owns
  the background). `WM_PAINT` clears `render_pending`, calls `timedRender`,
  and `noteRender`. `WM_WINDOWPOSCHANGED` reflows the grid: resize the
  `vt.Terminal`, resize the ConPTY (`ResizePseudoConsole`), invalidate. DPI
  change (`WM_DPICHANGED`, `WM_GETDPISCALEDSIZE`) re-runs font/atlas/cell
  metrics.

- **Keyboard** (`wnd/keyboard.zig`): `handleShortcut` intercepts
  Ctrl+T / Ctrl+W / Ctrl+Tab / Ctrl+Shift+Tab / Ctrl+1..9 / Ctrl+PageUp/Down
  before VT dispatch. `vkToSpecial` + `keyModifiers` + shared `encodeKey`
  encode arrows/F-keys/Home/End/PageX/Insert/Delete using xterm CSI
  sequences (e.g. `\x1b[1;2C` for Shift+Right). Backspace = `\x7f`. Plain
  Tab falls through to `WM_CHAR`; Shift+Tab → `\x1b[Z`. `WM_CHAR` handles
  control-key suppression (so Ctrl+T isn't sent twice), UTF-16 surrogate
  reassembly via per-pane `high_surrogate`, and pushes the final UTF-8 to the
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

  Mouse-report capture pins the originating pane ID (`mouse_report_tab_id`)
  so a Ctrl+Tab mid-drag does not steer reports into the wrong session. The
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
    `TIMER_RENDER_FRAME` is the render throttle (see §6);
    `TIMER_PTY_DRAIN` continues bounded PTY backlog drains.
  - `WM_APP_CHILD_PROCESS_DATA` (`wparam = pane_id`) is the reader-thread →
    UI wake-up. Handler repeatedly drains at most 256 bytes from the ring
    into `Pane.session.feed` until the initial ~2 ms budget is spent,
    `SetEvent`s the ring's `wake_event` (resumes a full-ring writer), and
    — only if bytes were drained — increments the per-second PTY byte
    counter and calls `requestRender`. If data remains, it arms
    `TIMER_PTY_DRAIN`; timer continuations use an ~8 ms budget so large
    bursts yield back to the message pump without dropping to tiny
    throughput. The continuation timer is window-global and coalesced by
    `Window.pty_drain_timer_armed`; a later tab that also has backlog
    observes the already-armed timer instead of resetting its due time. If
    `SetTimer` cannot arm the continuation, the fallback
    posts another `WM_APP_CHILD_PROCESS_DATA` instead of draining
    synchronously, so a resource-exhaustion path cannot recurse on the UI
    stack. Posts for a now-closed tab resolve to `findById → null`
    and return 0.
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

### 5.1 Tab and pane lifecycle (`tab_mgmt.zig`)

A `Tab` owns the shared `SplitLayout`, its ID, and a window reference.
A heap-allocated `Pane` owns the ConPTY process, `TerminalSession`, PTY ring,
reader stop flag, child HWND and D3D11 surface. `Window.panes` is a borrowed
registry for stable-ID and HWND lookup; `Window.tabs` is the tab-bar order.
The first pane ID also seeds its tab ID, but lookup namespaces stay separate.
There are at most 32 tabs and 63 pane processes per window, leaving one slot
for messages in the Win32 process wait set. IDs increase and are never reused.

New-tab creation allocates the root layout and first pane, initializes the ring
before starting its reader, starts ConPTY, initializes the terminal session and
callbacks, then publishes the tab. The D3D11 adapter creates the child surface,
reflows its region and focuses the new pane. A split first checks minimum size,
creates the session, then publishes the new leaf; failure disposes the new
session without changing the original focus or geometry.

ConPTY creation starts the reader before `CreatePseudoConsole`. It tries
`MOSTTY_CONPTY_DLL`, the bundled `conpty/conpty.dll`, then the system API.
Each pane gets its own pipe pair, process, job and ring. Readers post the stable
pane ID to the main HWND; all terminal parsing and effects remain on the UI
thread. The main loop waits on every pane process, including hidden tabs, and
posts `WM_APP_CLOSE_PANE` when one exits.

Pane close marks it closing, releases its capture and presentation resources,
unhooks it from the registry, sets the reader stop flag, calls `CancelIoEx`,
signals the ring wake event, closes ConPTY and joins the reader. Only then are
its remaining handles, terminal session and ring released. Late PTY or glyph
messages cannot resolve the removed ID. The layout collapses the sibling into
the removed leaf’s parent. The last pane removes its tab; the last tab quits.
Whole-tab close releases each owned pane, while whole-window close repeats that
for every tab. Each manual action has a distinct confirmation message. Split, close-pane and
maximize/restore actions are also exposed in the native system menu, for cases
where another application intercepts a shortcut.

The adapter rounds rectangle edges together to partition child HWNDs without
pixel overlap. It resizes each pane’s VT and ConPTY to the same row/column pair,
subtracting that pane’s scrollbar; hidden tabs retain their sessions and update
geometry. Maximized-away panes keep their session and last size until restored.

### 5.2 Reader thread (`child_process.zig:readConsoleThread`)

```
loop:
  if reader_stop.load(.acquire): exit
  ReadFile(read, buf[65536], &n, null)
    on ERROR_BROKEN_PIPE | ERROR_HANDLE_EOF      → exit (child died)
    on ERROR_OPERATION_ABORTED                   → exit (CancelIoEx)
  if !pty_ring.write(buf[0..n]): exit            // stop tripped while ring-full
  if pty_ring.posted.swap(true, .acq_rel) == false:
    while PostMessageW(hwnd, WM_APP_CHILD_PROCESS_DATA, pane_id, 0) == 0:
      if reader_stop.load(.acquire):
        pty_ring.posted.store(false, .release); exit  // tail bytes dropped
      log warn (attempt 1, then every 100)
      Sleep(1 ms)                                // queue saturation backoff
  if reader_stop.load(.acquire): exit
```

`PtyRing.write` copies into the ring in up to two `@memcpy`s (wrap split),
then `head.store(.release)` publishes. When the ring is full it parks on
the auto-reset `wake_event` and re-checks `reader_stop` at the top of
every loop iteration. The `posted.swap` is sequenced after `write`
returns, so any observer of `posted == true` sees the published `head`
via the matching `head.load(.acquire)` in `drain`.

`PostMessageW` failure has two modes: (a) transient — the per-thread
message queue saturated at its 10 000-message limit; (b) terminal — the
window is being destroyed. Resetting `posted = false` and falling
through (an earlier reviewer suggestion) would strand the just-published
bytes with no wake-up in flight, and the reader would later deadlock on
a full ring. Retry-until-stop, with `Sleep(1 ms)` between attempts, is
the only safe option: (a) clears within a frame once the UI drains; (b)
is paired with `reader_stop` being set by `destroyTab`.

### 5.3 Terminal session and effects (`terminal/Session.zig`, `tab_mgmt.zig`)

Each Windows `Pane` owns a platform-neutral `TerminalSession`, which owns the upstream
`vt.Terminal`, its arena, and the persistent `vt.TerminalStream`. Wide-character
overwrite consistency is handled by `libghostty-vt`; Mostty does not pre-process
print actions.

The shared session owns device-attribute and xtversion responses and routes
platform effects through context callbacks. Windows supplies title changes,
PTY writeback, and size reports from `tab_mgmt.zig`:

- **`onTitleChanged`**: receives the owning `Tab` as callback context, copies
  into `title_buf`, refreshes the tooltip if it is already showing, and
  requests render.
- **`onWritePty`** (`tab_mgmt.zig:53`): sends parser replies (Device
  Attributes, `CSI 18 t` size reports, `xtversion`, DECRQM) straight to
  `ChildProcess.writeFlushAll`.
- **Shared device attributes / xtversion and Windows `onSize`**: compose the
  reply payloads.

On macOS, `PtySession` owns the shell child and PTY master around the same
`TerminalSession`. Callers write input to the PTY, pump PTY output into the VT
state, resize both sides as one operation, and explicitly reap the child. Exec
startup uses a close-on-exec handshake so a missing shell is reported to the
caller and cleaned up before initialization succeeds.

The macOS renderer reads the shared VT viewport through `GridModel`, which
resolves cell geometry, wide-cell spans, colors, and text styles without Apple
APIs. `CoreTextRenderer` selects regular, bold, and italic fonts, then shapes
each complete grapheme cluster with CoreText `CTLine` for font fallback,
emoji presentation and sequence ligatures. Each face carries a CoreText cascade
of the regular primary and all configured `font-family` fallbacks in order,
followed by system fallback. Emoji presentation uses its own configurable font
chain. Codepoint maps prepend a range-specific fallback without overriding a
covering primary face. Named CoreText faces and OpenType feature descriptors
are applied when fonts are built; style suppression uses the shared policy,
with CoreGraphics emboldening/shearing for permitted missing styles.
The renderer owns all font strings and settings across config reloads and
rebuilds the cascades on font or backing-scale changes. Adjacent programming
symbols with identical styles are shaped together when ligatures are enabled,
stopping at cursor, row and paint boundaries.
Each renderer retains up to 1024 shaped lines and their typographic metrics,
keyed by font identity and the complete UTF-16 text. Direct-mapped collisions
replace the old entry after shaping succeeds; keys longer than 128 UTF-16 units
bypass the cache. Font reloads and backing-scale changes clear cached lines
before publishing replacement fonts. Colors, clipping and cell fitting remain
dynamic, so repainting selections or blink phases reuses the same shapes.
Shaped clusters are scaled down as
needed to fit their VT cell spans, preserving color glyphs in the BGRA buffer.
The renderer submits that buffer through
`MetalBackend` to an offscreen Metal texture. Resize and backing-scale changes
replace the font metrics, pixel buffer, and Metal textures together. The later
AppKit shell owns presentation of that texture and all input/window lifecycle.
`AppDelegate` creates the window and native menus; `ContentView` lays out the
tab bar above the terminal container. Model property observers refresh native
tab buttons and swap the selected pane host; theme menus rebuild on opening.
The main window restores and autosaves its normal frame before applying the
initial maximize/fullscreen configuration, and explicitly supports native fullscreen.
Its blink timer passes the text phase separately from cursor visibility; SGR
blink hides glyphs and decorations during the off phase, preserving backgrounds.
The host takes ownership of a retained CoreText/NSFont for tab titles; config
reload replaces this font and updates the strip height. Wallpaper resources
in `macos/background_image.zig` are decoded with ImageIO on configuration
changes, cached per pane, and drawn behind the translucent terminal background.
Fit/position geometry is shared with Windows; CoreGraphics handles tiling and
image opacity. Removing or failing to decode a configured image clears it.
Path changes prepare the image and any opacity-boosted copy before replacing
the current resources; reported allocation failures preserve the old wallpaper
and its options so a later reload can retry.
Tile-design characters use the shared sprite rasterizer at exact cell dimensions.
The macOS renderer caches linear alpha masks until cell metrics change and paints
them with the resolved foreground color; Windows retains its gamma-encoded BGRA
atlas output. Grapheme clusters and ordinary text continue through font rendering.
Mouse selections are tracked by the VT screen; the bridge copies them with VT
selection formatting and clips their highlight to the viewport when rendering.
Both platforms use `terminal/word_selection.zig` for double-click token boundaries
and CJK-aware expansion.
URL hover uses the shared viewport detector. The macOS host refreshes the hit
before rendering, paints its underline through `GridModel`, and re-detects the
target on double-click before passing it to `NSWorkspace` for browser opening.
Native file drops read file URLs from the drag pasteboard and send individually
quoted paths through the same bracketed-paste framing as clipboard input.
The macOS host routes VT mouse modes through the shared mouse encoder and the
owning tab's PTY; Shift keeps host selection available. A local AppKit event
monitor pins a pressed gesture to its originating view until release, including
across tab switches. `PtySession` supplies size replies using the current VT grid
and pixel dimensions, synchronized when the bridge creates or resizes a surface.
Each macOS tab owns one shared `SplitLayout` through `layout_capi.zig` and a
registry of stable pane IDs. `pane_container.swift` applies top-left, point-unit
snapshots to persistent `MosttyTerminalView` children, rounding backing-pixel
edges. It writes divider drags back through split IDs, without duplicating the
layout algorithm. Each pane owns its PTY, renderer, input and selection state.
Maximization and tab switching detach views while their readers continue
feeding VT on the main thread. Focus notifications synchronize AppKit's first
responder with the shared active ID; shell exit closes only its owning pane.
The final pane closes the tab. Explicit tab/window closure stops all owned
readers, and closed views cannot restart sessions in late layout callbacks.
Config reload visits every pane; each resizes from its own bounds and retained
backing scale, with no cross-tab size broadcast. The native container enforces
the shared subtree minimum size and reserves a focus border around each view.

Each macOS terminal view reserves a right-side strip for a native `NSScroller`;
the Metal child surface and IME overlay share the remaining content bounds.
The scrollbar queries the active VT screen's total rows, viewport offset and
visible rows. Native dragging selects an absolute history row; the final offset
explicitly restores bottom-follow mode. Its events stay outside the terminal
mouse-reporting area, and the visible tab refreshes the indicator on render ticks.
Kitty protocol parsing and replies remain in the shared VT stream. macOS installs
an ImageIO PNG decoder when creating a PTY session. Each renderer owns decoded
CoreGraphics images keyed by VT image ID/generation and resolves placements from
the active screen's viewport, including Unicode placeholders. Images composite
below explicit cell backgrounds, below text, or above text according to z-order;
default backgrounds reveal the lowest image layer and placeholder glyphs are
suppressed. The final bitmap still uses the existing Metal presentation pass.
Replacement, deletion and screen changes prune stale cached images; tab teardown
releases all copies. Destination clipping excludes non-grid padding and the
bottom gutter.

The flow per chunk of PTY bytes is:

```
ReadFile bytes
  → PtyRing.write (memcpy into ring; blocks on wake_event when full)
  → edge-triggered PostMessage(WM_APP_CHILD_PROCESS_DATA, wparam=pane_id)
[on UI thread, later — drain coalesces multiple reader writes]
  → PtyRing.drainMax(256 B) loop, capped at ~2 ms for initial wake-ups
    or ~8 ms for TIMER_PTY_DRAIN backlog continuations
    → up to two contiguous slices passed to
       Pane.session.feed
       → vt.TerminalStream parser dispatches: print, control, CSI, OSC, DCS, ...
         → Handler effects mutate Pane.term (screen state)
         → write-PTY replies (CSI 18 t etc.) go back via ChildProcess
  → SetEvent(pty_ring.wake_event)  (resumes a full-ring writer)
  → if bytes drained > 0:
       window.notePtyBytes(n)
       window.requestRender()
  → if ring still has data: keep posted=true and arm coalesced TIMER_PTY_DRAIN
       (if SetTimer fails, PostMessage another WM_APP_CHILD_PROCESS_DATA)
    else clear posted=false and re-check for a write raced under posted=true
  → TIMER_PTY_DRAIN scans posted tabs; stale posted-with-empty-ring is cleared,
    then re-checked and re-armed if a reader raced a write under posted=true
```

### 5.4 Kitty graphics

Kitty graphics support is wired through `Pane.session` and
`libghostty-vt`'s Kitty image storage:

1. The child app writes APC sequences into ConPTY. Kitty sequences start
   with `ESC _ G` and terminate with ST (`ESC` followed by `\`). The
   bundled Microsoft Terminal ConPTY is used when available because the
   Windows inbox ConPTY can discard APC payloads before Mostty sees them.
2. The UI thread drains PTY bytes into `Pane.session.feed`. The handler
   lets `libghostty-vt` parse Kitty graphics, including direct RGB/gray
   payloads, PNG payloads decoded by `png_decode.zig`, placements, deletes,
   and ACK responses.
3. Parsed images and placements live in
   `term.screens.active.kitty_images`. They are still terminal state, so
   they follow the UI-thread-only `vt.Terminal` ownership rule.
4. `d3d11/kitty_images.zig` mirrors visible images into a renderer-side
   cache keyed by `(tab_id, image_id)`. It uploads images as individual
   `ID3D11Texture2D` + shader-resource-view pairs, prunes deleted images,
   and releases all image resources when a tab closes.
5. Placement sync happens every render. Placement hashes mark the grid dirty
   only when the visible placement set changes; visible above-text images
   force a full grid redraw for correctness with the persistent grid texture.

### 5.5 Sixel and iTerm2 images

`terminal/InlineImages.zig` intercepts Sixel DCS and iTerm2 file transfers
strings at the shared session input boundary because the pinned VT library
does not implement these image protocols. Other input continues through the
upstream stream. Interception preserves state across PTY chunks and cancels
unfinished image strings on CAN/SUB or an unrelated escape sequence. Captured
payloads and final RGBA images are bounded to 64 MiB and dimensions to 10,000
pixels. iTerm2 multipart transfers assemble file parts until `FileEnd`.

`terminal/Sixel.zig` decodes raster data and RGB/HLS palettes; iTerm2 files use
WIC on Windows and ImageIO on macOS. Resized RGBA images enter the existing
Kitty image store with implicit IDs and tracked cursor pins, so every renderer
uses its existing image upload and clipping path. The cursor advances to the
first full row below the image. VT owns scrolling, clear, and teardown.

`images-enabled` defaults to true. Startup and config reload apply it to each
session; disabling clears image storage across screens, drops new images,
and removes Sixel from the shared DA1 capability response.

---

## 6. Rendering Pipeline

### 6.1 Renderer facade and backends

The process-global `Renderer` (`Renderer.zig`) owns the selected backend and a process-lifetime
`FontService`, a backend-independent `RendererCommon` (cell size, tab-bar
height, ligature setting, and adapter classification), plus a tagged backend
union. D3D11 remains the default validated variant; D3D12, OpenGL 4.6, Vulkan
with DirectComposition, and native Vulkan are explicit research variants that
still satisfy the whole facade contract. The
font service publishes font/DPI metrics into the common state, while each
backend borrows both and keeps no authoritative font state.

`FontService` owns DirectWrite formats/fallbacks, its D2D factory, the glyph
worker, and a dedicated D3D11 device/context used for D2D-compatible font
surfaces. It is initialized before the backend and destroyed after it, so a
backend lifecycle never determines font lifetime. D2D glyph staging and the
tab-bar band use keyed shared textures: the service writes under key 0 and
hands off key 1; D3D11 imports the texture on its own device, copies the result,
then returns key 0. Atlas slots, result validation, and presentation remain
backend responsibilities.

The renderer facade gates pane support and dispatches main-window chrome.
`PaneSurface` owns the pane backend and its last synchronized font generation;
creation, synchronization, drawing, glyph delivery and teardown go through that
wrapper. HWND layout and input routing do not inspect backend-specific fields.
All six configured Windows renderer choices have pane implementations. OpenGL
and Vulkan pane creation waits for the process renderer startup gate to pass.
The process renderer must outlive its pane surfaces.

D3D11 creates the main chrome surface and one child-HWND surface per pane.
`initSurface` retains the main device, context, shaders and dynamic constant
buffers and borrows `FontService`; it does not repeat device/font initialization.
Each surface owns its cell/shadow buffers, atlas, grid texture, image cache and
swapchain. Font changes invalidate each surface before it draws again. D3D11 synchronizes
background texture references and image settings through its surface hook;
individual panes retain COM references until their next synchronization or
teardown, without sharing glyph, cell or Kitty caches. Glyph
jobs/results carry a stable surface ID as well as cache and slot generations.
The main composition target is below child windows and clears pane regions to
transparent, so a pane applies its own background opacity once.

D3D12 pane surfaces retain the process device, direct queue, root signature and
pipelines. Each has its own two-generation command allocator/list, completion
fence/event, upload arenas, descriptor heaps, cell/atlas/grid textures, Kitty
cache and DirectComposition swapchain. Pane frame admission polls completion
and presentation readiness and requests a later frame if busy; asynchronous
glyphs cancel their pending reservation for retry if no upload generation is
available. Only main chrome performs the bounded presentation wait. Lifecycle
resource retirement submits outstanding commands and drains before release.
The main composition target is below the children and clears pane rectangles;
the child presents without a per-pane vblank wait. Wallpaper textures retain
per-surface references; the process upload is submitted on the shared queue
before pane sampling, and replaced descriptors are rewritten after completion.

D3D12 errors are retained by the affected surface and handled by the window.
Recovery destroys all pane graphics state before rebuilding the shared renderer,
then recreates surfaces against the existing HWNDs and sessions. Cache and
background-request generations advance to reject pre-recovery worker results.
A failed or immediately repeated rebuild reports an error and closes without
changing renderer. Debug builds with MOSTTY_DIAG accept the diagnostic device
removal message used by the pane acceptance runner; release builds ignore it.

The `d3d11` struct owns:

- `device`, `context` (created lazily at first `init`),
- build-time vertex/pixel shader assets generated from `terminal.hlsl`,
- `GridConfig` constant buffer,
- `glyph_cache` (`GlyphIndexCache`) + glyph atlas texture + two shared staging
  imports (mask for ClearType, color for emoji),
- swap chain (created on first frame via DirectComposition: an
  `IDXGISwapChain1` cast to `IDXGISwapChain2`, bound to a DComposition
  visual and pushed to the HWND). `BufferCount = 3` so a third back
  buffer absorbs DWM composition jitter during window drag/resize —
  the 2-buffer FLIP configuration stalled the CPU producer when DWM's
  hold on a presented buffer spiked. `SetMaximumFrameLatency(1)` caps
  the queued-frame depth so the extra buffer does not translate into
  an extra frame of input latency. The `GetFrameLatencyWaitableObject`
  handle is cached in `frame_latency_waitable` and consumed by
  `prepareFrame`,
- a persistent `grid_texture` + sRGB RTV the size of the client (see §6.4),
- shadow `shader.Cell` buffer for the per-row diff upload (§6.3),
- background-image state (CPU pixels + GPU SRV + decode req-id + worker
  thread join state).

The facade exposes `init`, `deinit`, `updateDpi`, `updateFont` (both rebuild the
font service state, then reset the active backend glyph cache and force a full redraw),
`reloadBackgroundImage`, and `render`, and dispatches them to the active
backend.

The shader build graph treats `terminal.hlsl` as the single source of truth.
For each runtime entry point it produces four assets: an SM5/DXBC asset with
the Windows SDK `fxc` for D3D11, a signed SM6/DXIL asset with the Windows SDK
`dxc` for D3D12, raw Vulkan SPIR-V from the Vulkan SDK `dxc`, and an OpenGL
SPIR-V asset normalized through SPIRV-Cross and glslang into OpenGL's combined
sampled-image form. The
two DirectX targets are not interchangeable — D3D11 rejects SM6 and D3D12
rejects SM5 — and they share a container format, so `shader_assets.zig` checks
each container's parts rather than its magic. DXIL must be signed: D3D12 refuses
unsigned bytecode outside developer mode, so the build requires `dxil.dll`
beside the DXIL compiler and a test asserts the container digest is non-zero.
DXC output passes Vulkan 1.0 validation before normalization; each final asset
passes OpenGL 4.5 validation. Any failed stage stops the build.
D3D11 consumes DXBC, D3D12 consumes signed DXIL, Vulkan consumes the raw
SPIR-V, and OpenGL 4.6 specializes the normalized SPIR-V assets directly. Explicit bindings keep constant buffers, structured
cells, textures, and the sampler in one collision-free cross-backend contract.

The OpenGL renderer creates one process-owned WGL 4.6 core context and uses
checked-in zigglgen bindings. Main chrome and panes have stable class-owned DCs
with the same pixel format. Every render, asynchronous upload and destruction
activates its target DC; programs, sampler and FontService are borrowed from the
process renderer. Panes own their VAOs, mapped buffers, atlas and image caches,
frame fences and presentation targets. Their frame-slot checks are nonblocking,
and their WGL swap interval is zero; main chrome provides process pacing. It reuses the shared
cell/glyph/image builders and the font service's CPU-pixel handoff. Persistent
mapped frame data is split across three completion-fenced slots; missing
4.6/SPIR-V and a configured `gpu` override are reported by the real-window
startup capability gate. RDP is not rejected preemptively: a session whose
display-driver policy exposes the required OpenGL capabilities continues on
OpenGL.
If the actual gate fails, startup offers a user-confirmed D3D11 fallback for
that process; declining exits without changing the configured backend. D3D12
uses the same real-window gate for device, pipeline, descriptor, and
DirectComposition-surface creation failures, so every non-D3D11 backend has
the same explicit policy rather than silently changing renderers.

The `native-vulkan` choice loads `vulkan-1.dll` at runtime, requires Vulkan
1.3 dynamic rendering, synchronization2, timeline semaphores, and a Win32
surface whose composite-alpha modes preserve the configured window effects.
When the configuration is fully opaque (`background-opacity = 1` and
`background-blur = false`), an opaque-only surface is accepted; otherwise a
non-opaque composite-alpha mode remains mandatory.
It uses three frame slots with per-frame acquisition semaphores, per-swapchain-image
presentation semaphores, and a timeline for frame-resource reuse. Acquisition
waits and the initial image layout transition share the color-attachment stage;
presentation signals cover the final layout transition. Present
selection prefers present-wait mailbox, then timeline-gated mailbox, then
FIFO; the active tier is logged. Resize, out-of-date, and suboptimal results
rebuild the swapchain without changing renderer identity. A runtime failure gets one coordinated rebuild of the shared core and all pane
resources, retaining the HWNDs and sessions. Failed or immediately repeated
recovery reports an error and closes without switching renderer.

The `vulkan` choice uses that same device, frame-resource, descriptor, shader,
grid, image, and tab-bar core but does not create a Win32 Vulkan surface or
swapchain. Three legacy D3D11 shared textures on the Vulkan adapter are
imported as external Vulkan images. A D3D11 shared fence is permanently
imported as a Vulkan timeline semaphore: Vulkan waits for the preceding D3D11
release, renders and signals ready; D3D11 waits ready, blits the completed
texture, then signals release. Queue-family ownership barriers bracket each
Vulkan render. Resize drains both APIs before replacing the shared images.
There is no CPU frame copy and bridge failure never selects native WSI.

Vulkan panes borrow the process instance, device, queue, sampler and pipelines.
Each owns its surface/swapchain or imported D3D bridge frames, command/descriptor
pools, cell/uniform buffers, timeline, upload retirements and drawing caches.
Background images are borrowed from the process renderer and synchronized by
resource generation; font/glyph results retain pane and cache-generation guards.
Transient upload buffers and command pools are retained until timeline completion
instead of waiting for the whole queue after every glyph. Pane frame and image
acquisition checks are nonblocking and deferred work requests a later paint.
The D3D bridge shares its presentation device/shaders and drains D3D work before
releasing imported images, including after an interrupted presentation.

Native WSI retires per-image presentation semaphores with the swapchain, and
uses negotiated present-wait IDs even when another presentation tier is selected.
Aborted acquisitions are consumed before their semaphore is destroyed. The tested
native driver provided present-wait; legacy retirement without that extension
retains the existing device-idle fallback and was not exercised in this matrix.
Debug diagnostic failures exercise reconstruction, not physical GPU resets.

DirectComposition lifecycle is split by responsibility. `dcomp.Surface` owns
the three-buffer composition swapchain, frame-latency handle, DComp device,
target, and visual. D3D12 passes its command queue directly to that surface.
`dcomp_blit.Presenter` adds a D3D11 device and shared full-screen shaders; both
OpenGL and Vulkan use it to feed a completed cross-API image into the surface.
WGL registration remains in `gl46/interop.zig`, while Vulkan external memory,
timeline synchronization, and adapter-LUID matching remain in
`vulkan/bridge.zig`.

The `opengl` presentation choice first attempts an optional
`WGL_NV_DX_interop2` bridge. The bridge uses a multithread-capable D3D11 device,
registers its render target with GL, copies completed frames into a flip-model
composition swap chain, and binds that chain to the window's DirectComposition
tree. A main-window capability failure selects the ordinary WGL path with an explicit
log; panes inherit that choice. Active bridges share one D3D11 device/context and
blit shaders while retaining separate swapchains and registered GL targets.
Pane presentation readiness is polled without adding blocking waits. The main
composition target is below children and clears their regions. A reported runtime
failure rebuilds the shared OpenGL context and every pane surface while retaining
HWNDs and sessions; an already-negotiated baseline WGL choice survives recovery.
Failure to activate a context during teardown stops explicitly instead of issuing
GL destruction against the wrong context. Physical context loss is not covered by
the diagnostic presentation-failure acceptance run.

The `pure-opengl` choice shares all rendering code but uses a normally
DWM-redirected HWND and presents with `SwapBuffers`. A hidden class-owned
bootstrap window loads `WGL_ARB_pixel_format` before the real window's
immutable pixel format is set; selection and read-back validation require
double buffering, RGBA with at least 8 alpha bits, sRGB, and
`PFD_SUPPORT_COMPOSITION`. Frames are drawn into an OpenGL-owned sRGB
renderbuffer, then vertically blitted into the window framebuffer to reconcile
the row orientation that the interop path normally corrects when D3D reads the
shared texture. It never creates the D3D11 interoperability bridge. Main-window drawing clips
child HWNDs so swapping the chrome surface does not overwrite pane pixels. Terminal
and font ownership are identical across both choices; glyph and tab-bar pixels
retain the M5a CPU handoff. Observed vendor results live in
`rad-notes/opengl-interop-matrix.md`.

### 6.2 Per-frame orchestration

`render.zig:renderWindow` dispatches main chrome through `Renderer` and paints
every visible pane through `PaneSurface`, with
its own terminal, selection, hover and focused-cursor state. Hidden sessions
continue consuming PTY output. All selected Windows backends use the pane facade after startup. A pane frame runs:

1. **prepareFrame** (`d3d11.zig`): client-size query; swap-chain
   create-or-resize; cheap occlusion test (`Present(0, TEST)`);
   `WaitForSingleObjectEx` (100 ms on main chrome, nonblocking on pane surfaces) to gate
   CPU frame production on DXGI queue availability (placed after the
   OCCLUDED gate so hidden windows don't stall; bounded timeout so a
   stuck waitable — GPU TDR mid-recovery, DWM hiccup — can't freeze
   the message pump); ensure persistent grid RTV; compute grid dims
   and atlas size; diff `ConfigSnapshot` (cell metrics / scrollbar /
   tab-bar) against the prior frame; write `GridConfig` constants
   (cell size, counts, scrollbar, `bg_image_dest`).
2. **Kitty image sync** (`d3d11/kitty_images.zig`): mirror the active
   pane's Kitty image storage into D3D textures, prune deleted image IDs,
   sort visible placements by z-order, and mark the grid for full redraw
   when image placement state changes.
3. **buildAndUpload** (`d3d11/cell_buffer.zig`): per-row, build a scratch
   `[]shader.Cell` from terminal screen + style + selection + cursor + URL
   hover + resize overlay, compare against `shadow_cells`, and only call
   `UpdateSubresource` for changed rows. Glyph indices come from the LRU
   cache; misses trigger DirectWrite or sprite rasterization (§6.5).
4. **drawAndCopy** (`d3d11/grid.zig`): if anything is dirty (or
   `grid_force_full` is set by font/DPI/resize), bind the grid RTV with a
   scissor rectangle covering the dirty row range, draw a full-screen
   quad as a 4-vertex triangle strip (`context.Draw(4, 0)`; the vertex
   shader generates the corners from `SV_VertexID`), then
   `CopyResource(back_buffer, grid_texture)`.
5. **paintChromeAndPresent** (`d3d11.zig`): D2D-paint the tab-bar band into
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

Kitty images share the persistent grid texture. The text/background pass
updates the grid first, then `kitty_images.draw` overlays above-text
placements into the same grid RTV using a dedicated pixel shader,
premultiplied-alpha blend state, per-placement scissor, and SRV slot `t3`.
The completed grid texture is then copied to the swap-chain back buffer.

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
  ambiguous symbols (●✶★), render on the font service device to the mask
  staging texture for ClearType text or the color staging texture for
  COLR/CBDT emoji, then import the keyed shared surface on the backend device
  and copy the required half into the atlas slot.

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

- **Tab bar** (`d3d11/tabbar_paint.zig`): proportional D2D painter with
  equal-width tabs filling the client width, a rounded inactive track and
  selected pill, centered titles, leading Ctrl+1…9 hints, a trailing close
  glyph on hover, and a separate circular new-tab button. Narrow windows
  reserve the new-tab button and keep the selected tab in the visible range.
  Layout and hit testing use the same column boundaries. The band is painted
  into an offscreen 96-DPI target owned by the
  font service, imported through the keyed shared-texture bridge, and copied
  onto the top strip of the back buffer. Cells start *below* the band:
  `SV_Position.y - tab_bar_height` in the pixel shader.
- **macOS tab bar** (`app_shell.swift`): AppKit allocates equal widths to
  AppKit buttons that draw their own backgrounds, titles, ⌘1…9 hints and
  control glyphs. AppKit retains button actions, accessibility and the
  new-tab launcher's native context menu. Title observation invalidates the
  painter without changing tab widths; this chrome is separate from Metal.
  Hidden close glyphs do not intercept pointer clicks. Each accessible tab
  exposes selection via Press and an independent Close Tab custom action,
  so closing does not require mouse hover or a visible close glyph.
- **Background image**: `reloadBackgroundImage` increments
  `bg_image_req_id` to stale any in-flight worker, then detaches
  `decodeWorker` which calls `gpu.decodeBackground` (WIC), posts
  `WM_APP_BG_IMAGE_DECODED` with a heap envelope; `applyDecoded` rechecks
  `req_id` (drops stale results), then `gpu.uploadBackground`.
  `computeDest` runs each frame for fit (`none/stretch/contain/cover`) and
  position; the pixel shader composites OVER cell bg with premultiplied
  alpha, so opaque cells properly mask the image (matches Ghostty).
- **Adapter/session classification** (`swap_chain.zig:detectAdapter`,
  cached `Window.remote_session`): inspects vendor id + name to detect WARP /
  Basic Render / RDP, and reuses the cached Windows remote-session bit before
  presenting. Local hardware uses `Present(0, 0)` (async / tearing-allowed);
  software adapters or active RDP sessions use `Present(1, 0)` so the producer
  back-pressures. This same classification drives the render-interval
  throttle (§7).

---

## 7. Render Throttle

`Window.requestRender` and `scheduleRender` (`state.zig`) implement a
soft frame cap:

- `render_interval_ms` is recomputed by `applyRenderInterval` from
  `(local_ms, remote_ms, remote_or_software_adapter)`. It picks the
  remote cap when either `SM_REMOTESESSION` is set or the boot-time
  adapter probe flagged the GPU as remote/software. Triggered at create,
  on `WM_WTSSESSION_CHANGE`, and after config reload; the same call refreshes
  `Window.remote_session` for the renderer's Present policy. Defaults are
  16 ms local and 50 ms remote.
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
       if font changed:   renderer.updateFont, reflow all Pane.term + ConPTY
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
      → PtyRing.write (memcpy, blocks on wake_event if full)
      → edge-triggered PostMessage(WM_APP_CHILD_PROCESS_DATA, pane_id)
[UI thread, asynchronously]
  → onAppChildProcessData
      → drainMax(256 B) loop → TerminalSession.feed (up to two contiguous slices)
      → SetEvent(pty_ring.wake_event)
      → notePtyBytes / requestRender (only if bytes > 0)
      → arm TIMER_PTY_DRAIN or clear/re-check pty_ring.posted
[later, on render throttle expiry]
  → WM_PAINT
  → render.renderWindow
  → d3d11 prepareFrame → buildAndUpload → drawAndCopy → paintChromeAndPresent
```

### 9.2 Keyboard → PTY

Both hosts map native events to `terminal/key_encode.zig`. The macOS C-ABI
is implemented by `input_capi.zig`; Windows retains normal cursor sequences
while macOS passes the live application-cursor mode. Clipboard normalization
and bracketed-paste framing use `terminal/paste.zig`: Windows supplies decoded
UTF-16 codepoints to its streaming state, and macOS encodes UTF-8 into a
caller-owned buffer before writing. File-drop quoting remains platform-specific;
macOS leaves newlines in quoted file paths intact as before.

SSH menus share the borrowing alias iterator in `ssh_config.zig`. The macOS
bridge returns offsets into Swift's input buffer, with no Zig allocation to
release. File reads and shell quoting remain native. Interaction tests link
the real `input_capi.zig` object alongside their window/PTY test doubles.

The renderers share baseline cell colors, SGR flags and blink/invisible text
visibility rules through `renderer/cell_style.zig`. Blink timers, faint,
terminal-wide reverse handling, selection, cursor,
glyph shaping and GPU attribute packing retain their host behavior. Kitty
image uploaders share RGBA conversion and source-crop arithmetic, while
placement visibility, ordering, Unicode placeholders and native image-resource
lifetimes remain in the existing platform pipelines.

```
WM_KEYDOWN
  → handleShortcut (Ctrl+T/W/Tab/1..9/PgUp/PgDn etc.) — consume
  → else vkToSpecial + keyModifiers + shared encodeKey → write CSI
WM_CHAR
  → drop control duplicates that KEYDOWN already handled
  → reassemble UTF-16 surrogates via per-pane high_surrogate
  → encode to UTF-8 → ChildProcess.writeFlushAll
```

### 9.3 Tab, pane and session commands

Windows split commands update `SplitLayout`; `Ctrl+Shift+D` splits left/right and `Ctrl+Shift+E` splits up/down. `Ctrl+Alt+Arrow` follows physical pane geometry without wrapping. `Ctrl+Shift+Enter` maximizes/restores the focused pane while retaining every session. `Ctrl+Shift+W` closes one pane; only the last pane closes its tab. Divider capture stores a split ID, and child HWND input, IME and capture are resolved through the pane registry. All six renderer choices support this layout, subject to their driver capabilities, and are never silently replaced.

### 9.4 Tab open / close

```
newTab: allocate tab layout → create first pane session → publish tab → reflow
splitActive: check minimum → create pane session → publish split → reflow/focus
destroyPane: remove native surface and registry entry → stop and join reader
             → free session → collapse layout → remove empty tab
destroyTab: release all owned panes → remove tab
```

See §5.1 for failure handling and teardown ordering.

### 9.5 Mouse selection

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

### 9.6 Mouse-report

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
  mid-flight. Use `findById` for pane IDs and `findTabIndexById` for tab IDs.
- **While the per-pane ring is non-empty, a `WM_APP_CHILD_PROCESS_DATA`
  post is either in flight or about to be sent.** The reader maintains
  this via an edge-triggered `posted.swap(true, .acq_rel)` after every
  successful `PtyRing.write` (which itself did `head.store(.release)`).
  If `PostMessageW` fails it is retried in a `Sleep(1 ms)` loop until it
  succeeds or `reader_stop` is observed; only on stop does the reader
  reset `posted = false` and exit (the ring's tail bytes are dropped
  intentionally, matching the close-time tail-output semantics).
  Resetting `posted = false` and falling through would leak bytes with
  no wake-up coming.
- **The UI handler drains PTY data in bounded batches.** If the ring still
  has data after a batch, it keeps `pty_ring.posted = true` and arms a
  coalesced window-global timer continuation; if `SetTimer` fails, it posts
  another `WM_APP_CHILD_PROCESS_DATA` and returns to the message pump rather
  than draining synchronously. Otherwise it clears `posted = false` and
  immediately re-checks the ring. That clear is `seq_cst` so the re-check
  cannot be reordered before it. The final re-check covers the race where the
  reader wrote while `posted` was still true and therefore did not post its
  own wake-up. Timer backlog scans also clear `posted` when they observe
  `posted == true` but no ring data, then run the same re-check/re-arm closure
  so an inconsistent stale flag cannot suppress a raced reader wake-up.
- **`tab.closing` is set together with `reader_stop` + `CancelIoEx` +
  `SetEvent(pty_ring.wake_event)` + `closePty()`, in that order, BEFORE
  `thread.join`.** The two wake calls cover the reader's two visible
  park points (`ReadFile` and `WaitForSingleObject` on a full ring);
  `closePty` closes the race window where the reader is between its
  loop-top stop-check and the `ReadFile` syscall — `CancelIoEx` is a
  no-op there, but a closed PTY makes `ReadFile` return `BROKEN_PIPE`
  on entry. The startup `errdefer` chain in `startConPtyWin32` uses the
  same trio for the same reason.
- **`PtyRing` lifetime: initialize after the pane field-default block, and
  deinitialize only after the reader joins.** The reader borrows the ring inside
  a heap-allocated `Pane` whose address never changes.
- **`vt.Terminal` is UI-thread-only.** No locks; the contract is enforced
  by the single-consumer ring drain.
- **`high_surrogate` is per-pane.** Switching the active tab between the
  high and low `WM_CHAR` would otherwise smear the surrogate.
- **`render_timer_armed` must not be set if `SetTimer` failed** — that
  would freeze the renderer.
- **Persistent grid RTV is required** for partial redraw because
  flip-model back-buffer contents are undefined post-`Present`.
- **Swap chain is 3-buffer FLIP + `MaxFrameLatency = 1` + waitable-gated.**
  The three components go together: dropping to 2 buffers reintroduces
  drag-time stutter; dropping the latency cap or the waitable wait adds
  input lag from queued frames. Main chrome waits at most 100 ms; pane surfaces
  use a nonblocking probe so per-pane waits cannot accumulate on the UI thread.
- **DComposition tree lifetime is tied to `swap_chain`.** `dcomp_visual`,
  `dcomp_target`, `dcomp_device`, and `swap_chain` are all created together
  in `swap_chain.init` and left `undefined` until then. `deinit` gates the
  four `Release()` calls on `swap_chain != null` so a renderer that never
  rendered doesn't touch undefined memory; `frame_latency_waitable`'s
  `CloseHandle` is guarded by its own optional.
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
