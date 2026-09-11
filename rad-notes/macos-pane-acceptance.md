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
- `zig build test-macos-panes --summary failures`: 29 checks passed using real
  AppKit views, Metal drawables, and four independent Python clients over PTYs.
  Covers mixed nested splits, distinct process IDs, isolated Unicode input,
  per-pane PTY rows/columns matched to actual drawable/cell sizes, divider drag
  and window resizing during output, focus, maximize/restore, tab persistence,
  screen-coordinate IME anchors, composition commit to the original pane,
  bracketed paste, selection, scroll isolation, 1x/2x backing-scale reflow,
  SGR mouse reports, an oversized Kitty placement, shell exit and shutdown.
- Antigravity static source review: one round, no actionable findings.
  Single external reviewer mode was used because Codex authored the change.

Local logs are `tmp/MOSTTY-75-unit-tests.log`,
`tmp/macos-interaction-tests/run.log`, `tmp/MOSTTY-75-clipboard.log`, and
`tmp/macos-pane-tests/run.log`. The real-PTY harness can be rerun with the
command above from a macOS GUI login session with Metal available. It uses the
current user configuration, temporarily uses and restores the clipboard, and
stores probe output under `tmp/macos-pane-tests`.

## Acceptance still requiring verification

- Physical cross-display transitions and the appearance/location of the native
  Chinese IME candidate window after pane focus changes. Programmatic 1x/2x
  reflow and candidate-anchor tests are narrower evidence.
- Visual inspection of multi-pane Kitty clipping and transparent/blurred
  backdrop compositing. A live image transfer without failure does not prove
  all rendered pixels stay correctly clipped.
- Multi-pane font/theme hot reload with changed settings, including hidden
  tabs. Existing unit and watcher tests do not replace that runtime check.
- Final menu/keyboard interaction and divider affordance checks on the final
  rebuilt application, including last-pane close and minimum window resizing.

MOSTTY-75 must remain open until these runtime acceptance items are recorded.
