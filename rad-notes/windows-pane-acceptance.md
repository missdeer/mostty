# Windows native split-pane acceptance — MOSTTY-74

Verified on September 11, 2026 with Zig 0.16.0 and the required D:/zig-cache.
The default D3D11 implementation uses child HWNDs; the other renderer variants
retain their existing single-surface implementation and explicitly reject splits.
The shared layout interface is documented in [split-layout-interface.md](split-layout-interface.md).

## Reproduction and evidence

- Build: the project-prescribed Windows build command completed successfully.
- Full tests: 45/45 build steps succeeded; 244/246 tests passed. The two skips
  are the same macOS Application Support config-path test included in two
  Windows test roots; no pane tests were skipped.
- Shared layout: five tests cover mixed nested splits, directional focus,
  subtree minima, clamped divider ratios, tiny forced bounds, maximize/restore,
  collapse, stale split IDs, invalid inputs and allocation rollback.
- Shared layout tests also cross-compiled for aarch64-macos; this is portability
  evidence, not a macOS native integration run (that work belongs to MOSTTY-75).
- Native run: `tools/pane-acceptance.ps1` passed with run ID
  `0ec217f1cf20441bba85f99b118e746b`. Its result is retained locally at
  `tmp/pane-acceptance/result-0ec217f1cf20441bba85f99b118e746b.json`,
  alongside diagnostic logs and screen captures. The runner uses its own
  profile and restores the clipboard after its clipboard tests.
- Focused checks are available with `-ImeOnly` and `-CloseOnly`. Each run
  retains a distinct result file, so a focused result does not stand in for
  the complete native acceptance run.

| Requirement | Evidence |
| --- | --- |
| Four mixed-direction native panes and independent shells | Four child HWNDs and four distinct shell PIDs; unique environment markers round-tripped through each shell. |
| Split, direction/click focus and divider dragging | Real keyboard/mouse actions created the panes and moved focus; divider drag changed geometry without changing focus. |
| Session retention on maximize/restore and tab switches | The visible HWND set returned unchanged, with the existing sessions retained. |
| Sustained output and responsive resizing | All four shells emitted repeated output during twelve window resizes; the GUI answered each response probe within 500 ms. |
| Independent VT and ConPTY sizes | Console-reported sizes matched the application's VT sizes: two panes at 41×14, two at 60×14. |
| Font/theme reload and transparency | Font reload produced 13×28 pixel cells and matching console/VT grids of 31×11 and 46×11; captures showed the changed colors and transparent/blurred pane backgrounds. |
| IME input and local anchoring | One letter plus Space produced a successful local composition anchor and an IME result event; only the target pane received committed input. Candidate content is deliberately not asserted. |
| Mouse reporting and capture | SGR press/release bytes arrived only in the clicked pane, including release after a tab switch during capture. |
| Clipboard and selection | Exact bracketed Unicode paste arrived only in the focused pane; selection copied the expected pane-local test text; the original clipboard was restored in the successful run. |
| Scrolling | Five wheel notches moved only the hovered pane by fifteen history rows without changing keyboard focus. |
| Independent exit and close semantics | One shell exited without closing the others; close-pane, close-tab and whole-window confirmations affected only their intended scope and completed without hanging. Closing the original root pane did not invalidate the retained tab ID. |
| Stable asynchronous identities | Registry tests reject removed pane HWNDs/IDs; glyph-result tests reject identical slot/key generations from another surface. |
| Resource sharing | A real D3D11 test verifies shared device/context/shaders/font service while pane cell buffers and atlas textures remain distinct. |
| DPI | Grid tests verify equivalent pane dimensions at 96/144/192 DPI; the native run moved intact panes between both attached monitors. Both monitors were 96 DPI, so a physical mixed-DPI transition was unavailable. |

The desktop's Feishu installation intercepts Ctrl+Shift+W globally; a standard
Windows text-box probe confirmed that Mostty never receives that chord there.
The native system menu exposes the same close-pane command, and the close test
uses that command. Split and maximize/restore commands are also in that menu.

## Renderer coverage

Each research backend was tested in an isolated process using
`tools/pane-backend-acceptance.ps1 -Renderer <name>`. On this NVIDIA GeForce
RTX 4060 Ti host, all five initialized, displayed a single session, showed the
explicit D3D11 split restriction, retained their requested renderer, and exited
with code 0. Results live under `tmp/pane-backend-<name>/result.json`.

| Backend | Multi-pane resources and tested behavior |
| --- | --- |
| d3d11 | Shared font/device/shader infrastructure with separate HWND composition swapchains and pane caches; full native acceptance above. |
| d3d12 | Existing command-queue/descriptor/frame ownership remains one surface; single-session compatibility and explicit split restriction passed. |
| opengl | Existing WGL context and optional D3D interop presenter remain one surface; compatibility and explicit split restriction passed. |
| pure-opengl | Existing class-owned DC, WGL context and SwapBuffers path remain one surface; compatibility and explicit split restriction passed. |
| vulkan | Existing Vulkan frame resources and D3D11 bridge remain one surface; compatibility and explicit split restriction passed. |
| native-vulkan | Existing Win32 WSI surface/swapchain remains one surface; opaque startup, compatibility and explicit split restriction passed. |

Research-backend multi-pane rendering is not claimed or silently emulated with
D3D11. No physical mixed-DPI desktop, RDP multi-pane matrix, or macOS native
pane interaction was tested in this Windows run.
