# CLAUDE.md — 12-rule 

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.

## Rule 1 — Think Before Coding
State assumptions explicitly. If uncertain, ask rather than guess.
Present multiple interpretations when ambiguity exists.
Push back when a simpler approach exists.
Stop when confused. Name what's unclear.

## Rule 2 — Simplicity First
Minimum code that solves the problem. Nothing speculative.
No features beyond what was asked. No abstractions for single-use code.
Test: would a senior engineer say this is overcomplicated? If yes, simplify.

## Rule 3 — Surgical Changes
Touch only what you must. Clean up only your own mess.
Don't "improve" adjacent code, comments, or formatting.
Don't refactor what isn't broken. Match existing style.

## Rule 4 — Goal-Driven Execution
Define success criteria. Loop until verified.
Don't follow steps. Define success and iterate.
Strong success criteria let you loop independently.

## Rule 5 — Use the model only for judgment calls
Use me for: classification, drafting, summarization, extraction.
Do NOT use me for: routing, retries, deterministic transforms.
If code can answer, code answers.

## Rule 6 — Token budgets are not advisory
Per-task: 4,000 tokens. Per-session: 30,000 tokens.
If approaching budget, summarize and start fresh.
Surface the breach. Do not silently overrun.

## Rule 7 — Surface conflicts, don't average them
If two patterns contradict, pick one (more recent / more tested).
Explain why. Flag the other for cleanup.
Don't blend conflicting patterns.

## Rule 8 — Read before you write
Before adding code, read exports, immediate callers, shared utilities.
"Looks orthogonal" is dangerous. If unsure why code is structured a way, ask.

## Rule 9 — Tests verify intent, not just behavior
Tests must encode WHY behavior matters, not just WHAT it does.
A test that can't fail when business logic changes is wrong.

## Rule 10 — Checkpoint after every significant step
Summarize what was done, what's verified, what's left.
Don't continue from a state you can't describe back.
If you lose track, stop and restate.

## Rule 11 — Match the codebase's conventions, even if you disagree
Conformance > taste inside the codebase.
If you genuinely think a convention is harmful, surface it. Don't fork silently.

## Rule 12 — Fail loud
"Completed" is wrong if anything was skipped silently.
"Tests pass" is wrong if any were skipped.
Default to surfacing uncertainty, not hiding it.

# Build & run

Requires Zig `0.15.2`. Dependencies are declared in `build.zig.zon` and most are marked `lazy = true` — they're only fetched for the platform that needs them (x11/wayland/TrueType on Linux, win32 on Windows).

- `zig build` — build the `mite` executable into `zig-out/bin/`.
- `zig build run -- [args]` — build and run; everything after `--` is forwarded as cmdline args (see `src/Cmdline.zig`: `--ttf <path>`, `--font-size <float>`).
- `zig build test` — run the unit test step (compiles the same root file as the exe; there are very few tests today).
- `zig build -Doptimize=ReleaseSmall` — what the README's "less than 2 MB" Windows binary refers to.

There is no separate lint step. Cross-compile with `-Dtarget=...` as usual; the build script picks the platform entry point and resource files automatically.

## Build Command for Developer

- Use `cmd.exe /c "D:\zig-x86_64-windows-0.15.2\zig.exe build --global-cache-dir D:\zig-cache"` to build the project.
- MUST wrap the build command by `cmd.exe /c`
- Use `D:\zig-cache` as the build cache

# Architecture

Mite is a terminal emulator that wraps `libghostty-vt` (the VT parser/state machine from Ghostty, imported as the `vt` module) and provides its own windowing + rendering layer per platform. There is **no shared backend abstraction across OSes** — the entry point is chosen at build time:

| Target  | Entry point             | Window/IO                                                                  | Rendering             |
| ------- | ----------------------- | -------------------------------------------------------------------------- | --------------------- |
| Windows | `src/mitewindows.zig`   | Win32 message loop + ConPTY per tab                                        | D3D11 + DirectWrite   |
| Linux   | `src/mite.zig`          | X11 or Wayland selected at startup from `XDG_SESSION_TYPE`; `poll(2)` loop | X11 RENDER / Wayland  |

`build.zig` switches on `target.result.os.tag` to pick the root source file, the Win32 manifest/resource, and which dependencies to import. Linux build is `single_threaded = true`; Windows is multi-threaded because each tab has a dedicated `std.Thread` reading from its ConPTY.

## Linux side (`src/mite.zig`, `src/x11.zig`, `src/wayland.zig`)

- A single `Backend` struct holds an `IoPinned` (pinned IO buffers — pointers into these are kept by the X11/Wayland source readers, so the struct **must not move** after init) plus a tagged-union `Specific` for the X11 or Wayland state.
- Backend dispatch uses Zig's `inline else` on the union so each platform's `drain`/`render`/`setTitle` methods are called without a vtable.
- The main loop is one `poll(2)` on `[backend_fd, pty_master_fd]`. Damage is batched: after marking damage, the loop defers the actual `render` until either the FDs go idle or `render_deadline_ns` (8 ms, ~120 fps) has elapsed. Don't render synchronously on every PTY chunk — it tanks throughput.
- `os/linux.zig` opens `/dev/ptmx` and forks the shell directly (no `posix_openpt`/`forkpty` wrappers). The font path comes from running `fc-match` as a subprocess (`src/posix/fontconfig.zig`) when `--ttf` isn't given.

## Windows side (`src/mitewindows.zig`, `src/win32/d3d11.zig`)

- Multi-tab from the start: `Window.tabs` is a list of `*Tab`, each owning its own `vt.Terminal`, `vt.Stream(VtHandler)`, `ChildProcess` (ConPTY) and reader thread. Tab IDs (`TabId`) are stable; never index tabs by position across messages because tabs can close mid-flight.
- The main loop is `MsgWaitForMultipleObjectsEx` over `{all tab process handles, message queue}`. Child-process-exited fires before WM_APP_CLOSE_TAB drains, so tabs always go through `closing = true` first and the reader thread's `reader_stop` flag is set together with `CancelIoEx`.
- Reader threads ship PTY bytes to the UI thread via `SendMessage(WM_APP_CHILD_PROCESS_DATA, ...)`. The WndProc returns the magic value `WM_APP_CHILD_PROCESS_DATA_RESULT` so the reader can assert the message was actually handled (and not silently dropped, e.g. during teardown).
- Surrogate state for `WM_CHAR` (`Tab.high_surrogate`) is **per tab**, not global — keyboard shortcuts can switch the active tab between the high and low surrogate arriving.
- Rendering is a single full-screen triangle in HLSL (`src/win32/terminal.hlsl`); the CPU uploads a `StructuredBuffer<Cell>` plus a glyph atlas texture. `GlyphIndexCache.zig` is an LRU mapping `(codepoint, half)` → atlas slot; when `reserve` evicts, the renderer must re-rasterize into the freed slot.
- Window chrome: custom tab bar painted into the top cell row of the same D3D11 surface, plus DWM dark-mode/blur-behind. The "title bar" color is set via `DwmSetWindowAttribute` — there's no separate Win32 title bar control.

## Shared

- `Cmdline.zig` is used by both entry points.
- `vt` (libghostty-vt) drives terminal state. Mite wires its own `Stream` handler (`TitleHandler` on Linux, `VtHandler` on Windows) on top of `vt.ReadonlyHandler` to intercept `window_title` actions; everything else falls through to the readonly handler.
- `TERM` is forced to `xterm-256color` (see `mite.setTermEnv` on Linux; Windows sets the child env directly when spawning the ConPTY).

## Temp Dir

Always use **${project_root_dir}/tmp** as the temporary directory, never use **/tmp**.
