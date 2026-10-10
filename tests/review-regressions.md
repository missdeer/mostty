# Review regression coverage

Review baseline: `e107fb0f33ed4a66a46633dd67c9ad409921e038`.
The table maps each of the 17 findings to the production change and its regression
test. A unit test or compile check does not establish the hardware behavior in
the last column. See [the full suite inventory](README.md) for execution commands.

| # | Finding and fix | Regression evidence | Remaining platform coverage |
| --- | --- | --- | --- |
| 1 | Session-owned allocations now use a reclaiming allocator instead of a pane-lifetime arena. | `session.zig`: repeated image replacement checks live allocation bytes before teardown. `inline_images.zig`: decoder scratch and original pixels are freed while the result remains live. | Real image workloads and long-session RSS observation. |
| 2 | Both hosts enqueue ordered input to a cancellable writer worker; paste is one transaction. | `write_queue.zig`: stalled consumer, partial writes, byte ordering and cancellation. Native macOS PTY tests: delayed reader plus SHA256 of 64 KiB, resize, teardown. Windows pipe test: cancel and join with no consumer. | Interactive responsiveness during large paste on both hosts. |
| 3 | Windows stops publishing output but continues draining until ConPTY closes, then joins the reader. | `child_process.zig`: drains 2 MiB through a bounded pipe with publication stopped and no UI consumer. | Pre-24H2 system ConPTY fallback on an actual old Windows installation. |
| 4 | Metal upload textures use the platform storage default; render targets use private storage. | Native `metal_backend.zig`: create upload/target, render and resize. Pane tests perform Metal readback. | Intel/AMD physical Mac; arm64 execution cannot validate a discrete GPU. |
| 5 | Font sizes must be finite and within 1–256 points; native pixel metrics have a nonzero representable range. | `config.zig`: invalid, nonfinite, boundary and tiny metric cases. | Original platform crash was not reproduced; extreme font/DPI rendering remains a visual check. |
| 6 | A failed first launcher aborts Windows window creation with controlled exit 1; empty-window close posts quit. | `startup-failure.ps1`: isolated invalid launcher, bounded exit wait and diagnostic assertion. | Requires Windows GUI runner; hosted inventory records blocked. |
| 7 | Legacy hosts do not advertise or mutate Kitty keyboard negotiation flags. | `session.zig`: all supported negotiation forms leave flags zero and produce no capability reply. | Physical key combinations in terminal applications. |
| 8 | SGR pixel coordinates are one-based and captured releases clamp inside the viewport. | `mouse_report.zig`: origin, edges and captured outside releases; macOS bridge reporting tests. | Physical pointer integration. |
| 9 | Windows wheel accumulation preserves delta magnitude and high-resolution remainders. | `mouse_report.zig`: multiple notches, fractional steps and direction reversal. | Real high-resolution wheel hardware. |
| 10 | macOS PTY masters set checked `FD_CLOEXEC` and nonblocking flags. | `pty_session.zig`: flag assertions and a second shell checking that the first master was not inherited. | No additional hardware requirement. |
| 11 | Windows shader scrollbar boundary uses actual pane pixels; all renderers retain the boundary for hidden thumbs. | `shader-contract-tests.ps1`: evaluates the shader boundary at three nonuniform widths and checks all four renderer paths. | GPU pixels compared to hit testing at mixed DPI. |
| 12 | Windows text shader returns premultiplied RGB without multiplying coverage a second time. | `shader-contract-tests.ps1`: four scalar alpha/coverage cases evaluated from the actual HLSL expression. | GPU visual comparison on transparent windows. |
| 13 | WIC pixel allocation is explicitly freed when optional copy returns null. | `d3d11/gpu.zig`: injected copy failure repeatedly returns allocation bytes to zero. | Unit test injects failure rather than provoking a real WIC decoder failure. |
| 14 | macOS cursor cell matching includes both columns occupied by a wide glyph. | `grid_model.zig`: wide-cell containment checks leading, trailing and outside columns. | Visual cursor rendering at a wide-glyph tail. |
| 15 | macOS reverse-screen swaps effective default frame/cell colors and restores them. | `grid_model.zig`: reverse mode on/off verifies frame and default-cell colors. | Visual comparison with styled text and transparency. |
| 16 | Windows validates all UTF-16 before encoding/enqueuing bracketed paste. | `paste.zig`: malformed input after a long valid prefix emits no opening marker; valid non-BMP input retains normalization and framing. | Native clipboard integration. |
| 17 | Background pane redraws do not update the global cursor; only the owning pane clears it on exit/close. | `InteractionTests.swift`: sibling redraw preserves hand cursor. `ClipboardTests.swift`: leave URL and close hovered tab restore arrow. | Multi-pane physical pointer behavior. |

CI additionally classifies Vulkan `VK_ERROR_INCOMPATIBLE_DRIVER` as a missing API
capability. Other instance initialization errors still fail; a unit test verifies
that allocation/initialization errors cannot be hidden as a capability skip.

Dedicated hardware cases remain **blocked**, not passed. The old-system ConPTY,
Intel/AMD Metal, real GPU recovery, RDP, and mixed-DPI requirements are not fulfilled
by hosted CI, shader arithmetic, or cross-compilation.
