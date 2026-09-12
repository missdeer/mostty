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

## Pane facade migration — MOSTTY-77

Revalidated on September 12, 2026 after completing pane creation, synchronization,
drawing, glyph delivery and teardown dispatch through PaneSurface, and capability
and chrome dispatch through Renderer. This remains a D3D11 acceptance result;
MOSTTY-78 through MOSTTY-81 track the remaining backends and combined acceptance.

- Prescribed Zig 0.16.0 application build passed with D:/zig-cache.
- Full tests: 45/45 steps succeeded; 248/250 tests passed. The two skips are
  the macOS config-path test in two Windows roots. New facade tests ran against
  real D3D11 resources, verifying shared device/context/shaders/FontService,
  distinct cell buffers and atlases, per-pane glyph rejection, lazy font
  invalidation, retained wallpaper references, image removal and scalar updates.
- Full native runner: tools/pane-acceptance.ps1, run ID
  e2a2808dc6264fd4825979ca9c9a6332, status pass. Four distinct shell PIDs,
  matching ConPTY/VT sizes before and after font reload, all input/capture/IME
  assertions, layout/session retention, output during resize and close actions passed.
- Captures four-panes.png and font-theme-transparency.png were visually inspected.
  Both connected monitors were 96 DPI; a physical mixed-DPI transition was unavailable.
- Local evidence: tmp/MOSTTY-77-tests.log, tmp/MOSTTY-77-build.log,
  tmp/MOSTTY-77-runtime.log and
  tmp/pane-acceptance/result-e2a2808dc6264fd4825979ca9c9a6332.json.

## D3D12 native panes — MOSTTY-78

Verified on September 12, 2026. The D3D12 row in the earlier MOSTTY-74 matrix
is historical: D3D12 now supports native panes; OpenGL and Vulkan remain pending.

- Build and full tests used Zig 0.16.0 and D:/zig-cache: 45/45 test steps,
  250/252 tests passed. Both skips are the macOS config-path test in Windows
  test roots. Real D3D12 sharing, per-pane command/cache separation, busy-frame
  deferral and isolated device-removal tests all executed.
- Full native command: tools/pane-acceptance.ps1 -Renderer d3d12 -TestRecovery.
  Run 7001699b2b174e93b6dfb82926adf8f8 passed, with four different shell PIDs
  and logged D3D12 surfaces sharing one device and queue. Mixed nested layout,
  divider drag, direction/click focus, maximize/restore, tab retention, IME,
  mouse reports/capture, Unicode paste, selection, scrolling, sustained output
  during resize, matching ConPTY/VT dimensions and closing all passed.
- Live device removal rebuilt the shared D3D12 device in the same process.
  Shell PIDs and child HWNDs were unchanged; 564,590 sampled text-region pixels
  had zero differences after rasterization settled. The initial immediate
  capture had pending glyphs, so acceptance now compares settled before/after
  captures instead of treating session survival as visual correctness.
- All four panes displayed different colors with the same Kitty image ID;
  deleting in one pane preserved the others. Wallpaper replacement and removal
  were checked through actual pixels in all four panes. The wallpaper test uses
  transparent default backgrounds, consistent with cells compositing over it.
- Font/theme/transparency updates passed. Recovery, Kitty and wallpaper captures
  were inspected. Both attached monitors were 96 DPI; physical mixed-DPI moves
  and RDP recovery were not executed or counted as passes.
- Focused D3D11 regression: tools/pane-acceptance.ps1 -Renderer d3d11 -CloseOnly,
  run 0f7f035c812840069e4bd3c904c628b2, passed split/direction focus and independent
  shell, pane, tab and window closure. This does not claim a new full D3D11 run.
- Logs and captures are preserved in tmp/MOSTTY-78-evidence. Failed exploratory
  runs were not counted as passes; they exposed a PID-file completion race and
  an incorrect opaque-background setting in the wallpaper test, both corrected.

## OpenGL native panes — MOSTTY-79

Verified on September 12, 2026. Both OpenGL rows in the original MOSTTY-74
matrix are historical: opengl and pure-opengl now support native panes.
Vulkan variants remain pending under MOSTTY-80.

- Prescribed Zig 0.16.0 build and D:/zig-cache tests passed: 45/45 steps,
  251/253 tests. The two skips are macOS config-path checks in Windows roots.
  Real WGL/DC tests exercised both modes, including shared context/programs,
  distinct DCs/buffers/atlases, glyph isolation, child teardown, context rebuild
  and preservation of a negotiated baseline choice. Unsupported driver gates
  explicitly skip the GPU test; neither mode was skipped on this host.
- Interop run: tools/pane-acceptance.ps1 -Renderer opengl -TestRecovery,
  75048041f9bc4ffd96ac507ffe8075f7, passed. Logs confirmed four pane DCs sharing
  one WGL context and all active bridges sharing one D3D11 presentation device.
- Pure run: tools/pane-acceptance.ps1 -Renderer pure-opengl -TestRecovery,
  a70e6da003454326b2108192a516f8a3, passed. It shared one context across four
  distinct DCs and created no interoperability bridge.
- Both runs passed mixed nested splits, direction/click focus, divider drag,
  maximize/restore, tab retention, IME, mouse reporting/capture, Unicode paste,
  selection, scrolling, sustained output during resizing, ConPTY/VT size
  agreement, font/theme updates and pane/tab/window closure.
- Diagnostic presentation failures rebuilt graphics without replacing shell
  PIDs or pane HWNDs. Each run compared 564,590 settled text-region pixels with
  zero differences. This exercises rejected presentation calls and coordinated
  reconstruction, not physical driver resets or irrecoverably lost contexts.
- Same-ID Kitty images remained independent, and wallpaper replacement/removal
  reached all four panes. Transparency and image captures were inspected.
- Static review identified inverted Y coordinates in main-surface scissor
  cutouts. An asymmetric GPU alpha-readback test failed before the fix
  (expected transparent alpha 0, observed 255) and passed after converting
  Win32 coordinates to the OpenGL lower-left origin.
- Both monitors were 96 DPI; physical mixed-DPI movement, RDP recovery and
  live interop-unavailable hardware were not executed or counted as passes.
- Focused D3D11 and D3D12 split/focus/closure regressions passed with run IDs
  dc87ac2b0ad7449d949091a3ee499ece and e58b77239cc349c3b47d73e0f90246c1.
- Final evidence is preserved under tmp/MOSTTY-79-evidence, with separate
  opengl and pure-opengl results, diagnostic logs and captures.

## Vulkan native panes — MOSTTY-80

Verified on September 12, 2026. Both Vulkan rows in the original MOSTTY-74
matrix are historical; all six configured Windows renderer choices now have
native pane implementations. Combined final acceptance remains MOSTTY-81.

- Zig 0.16.0 with D:/zig-cache: build passed; 45/45 test steps succeeded,
  253/255 tests passed. Both skips are macOS config-path tests on Windows.
  GPU tests exercised shared device/queue/pipeline/font infrastructure,
  independent pane frames and presentation, per-image WSI semaphores,
  upload retention/collection and nonblocking frame readiness.
- Vulkan bridge run daa7789abd9549bf838bf4f0963b016a passed four-pane acceptance
  and synchronization validation, sharing one Vulkan device/queue and one
  D3D11 presentation device. Native WSI run a25015192681421197c6c23205a36b48
  passed using present_wait_mailbox and alpha composition on this NVIDIA driver.
- Both used tools/pane-acceptance.ps1 -Renderer <mode> -TestRecovery
  -VulkanValidation. Mixed nested layout, input/IME/capture, maximize/restore,
  tab retention, output/resize, ConPTY/VT sizes, font/theme/transparency,
  Kitty isolation, wallpaper replacement/removal and closure checks passed.
- Diagnostic recovery retained shell PIDs and pane HWNDs; each mode compared
  564,590 settled text-region pixels with zero differences. This tests reported
  presentation failure and reconstruction, not physical device loss or RDP.
- Validation output is captured through process pipes across instance rebuilds,
  avoiding the layer file logger's truncation during recovery. Both recorded
  synchronization validation active for the original and rebuilt instances,
  with zero errors in the successful runs.
- The first native validation run found an acquire-to-layout transition
  WRITE_AFTER_READ hazard. Its source stage was corrected to match the acquire
  semaphore wait, and a recorded-barrier regression covers first use and reuse.
  That failed run is retained and is not counted as passing evidence.
- Four-backend split/focus/closure regressions passed: D3D11
  f027bb53e3d54602b66f36f354a8dd4d; D3D12 e5e3bba4853840f8adab5f7e918eca08;
  OpenGL fdedce22d1954643b6aab604592b6e7c; pure OpenGL
  41cc086caa0d457fb5a6e91d2c7dd391.
- Both monitors were 96 DPI. Mixed-DPI hardware, RDP, physical device loss,
  opaque-only native WSI and native WSI without present-wait were not tested
  or counted as passes. The runner marks native alpha limitations explicitly.
- Evidence is preserved under tmp/MOSTTY-80-evidence with separate mode logs,
  validation output, result files and inspected captures.
