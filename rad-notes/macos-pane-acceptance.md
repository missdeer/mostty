# macOS native pane acceptance — MOSTTY-75

Implementation uses `src/SplitLayout.zig` through `src/layout_capi.zig`.
`PaneContainer` positions persistent AppKit terminal views; no Swift split tree
or independent window per pane is created. Keyboard mappings are in README.

## Verified on the macOS development host

- `zig build --summary failures`: application bundle builds successfully.
- `zig build test --summary all`: 211/211 tests passed, no skips reported;
  includes shared layout and thin C ABI coverage.
- `bash tests/macos/interactions.sh`: 66 checks passed, including native tab
  controls, close confirmation, window teardown, and configuration watching.
- `bash tests/macos/clipboard.sh`: 119 checks passed, including key encoding,
  mouse capture, clipboard framing, file drops, and shell quoting.
- `zig build test-macos-panes --summary failures`: 36 checks passed using real
  AppKit views, Metal drawables, and four independent Python clients over PTYs.
  Covers mixed nested splits, distinct process IDs, isolated Unicode input,
  per-pane PTY rows/columns matched to actual drawable/cell sizes, divider drag
  and window resizing during output, focus, maximize/restore, tab persistence,
  screen-coordinate IME anchors, composition commit to the original pane,
  bracketed paste, selection, scroll isolation, 1x/2x backing-scale reflow,
  SGR mouse reports, oversized Kitty texture pixels and native bounds, minimum
  window size, divider clamping, refused splits while maximized, sibling
  expansion, last-pane shell exit, hidden output, and shutdown.
- `zig build test-macos-pane-config --summary failures`: 44 checks passed, the same harness plus
  watcher-driven configuration checks. It atomically changes fonts, theme,
  opacity and blur while a four-pane tab is hidden and another tab is visible;
  checks font metrics, PTY dimensions, session identity, premultiplied background
  pixels, native layer opacity and backdrop presence; then restores the original
  configuration. Run this explicit target only when temporary user-config changes
  are acceptable; do not run it concurrently with the other pane target or edit
  the config during the test. A uniquely named backup is written under
  `tmp/macos-pane-tests`; an external edit is preserved and reported as a failure.
  Original configuration restoration was independently verified with SHA-256
  `5c0175bb3e031d2657b026b6fdebe820a70f9bab6c8744231a69ab4125d80f7e`
  before and after the run.
- Antigravity static source review: one round, no actionable findings.
  Single external reviewer mode was used because Codex authored the change.
  The automated acceptance follow-up also passed one independent Antigravity
  review round with no actionable findings.
  The final acceptance-record update passed one independent Antigravity review
  round with no actionable findings.

Local logs are `tmp/MOSTTY-75-unit-tests.log`,
`tmp/macos-interaction-tests/run.log`, `tmp/MOSTTY-75-clipboard.log`, and
`tmp/macos-pane-tests/extended.log` and `tmp/macos-pane-tests/config-reload.log`.
The real-PTY harness can be rerun with the
command above from a macOS GUI login session with Metal available. It uses the
current user configuration, temporarily uses and restores the clipboard, and
stores probe output under `tmp/macos-pane-tests`.

## Final acceptance — 2026-09-11

The user confirmed that these checks passed on the current Mostty build:

- Physical cross-display scaling and the native Chinese IME candidate window.
- Split, directional focus, maximize/restore, and close through menus and
  shortcuts; divider dragging and minimum sizes.
- Pane-local Kitty clipping and desktop compositing with transparent/blurred
  backgrounds.

These are user-observed results, distinct from the automated scale, IME-anchor,
texture-pixel and native-view checks above. The agent's native UI controller
became unavailable during final interaction checks; the user confirmed that
Mostty remained responsive and completed the remaining desktop verification.

At source commit `42faa062c446e0ccaabbba56563ddf0bc77b0461`,
`zig build --summary failures` succeeded and
`zig build test-macos-panes --summary failures` passed all 36 checks with zero
failures. The initial sandboxed pane run was interrupted after macOS GUI service
errors; the successful run used access outside the sandbox. Its default-theme
warning was specific to the standalone harness; the theme was verified present
in the application bundle. The current user configuration was retained.

All outstanding MOSTTY-75 runtime acceptance items are now recorded as passed.
