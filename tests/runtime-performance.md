# Runtime performance review follow-up

Review baseline: `b128d906fc5ceee9446ae634a7a1d6d6a7baf2b1` (includes PRs #5
and #6). Source: `Mostty-runtime-performance-review-b128d90.txt`, Library
`libfile_c850b77df98c819181d90a9c1711f1b4`, 84,612 bytes. The full report was
read and saved in the cloud workspace; it is not a repository dependency.

This is an incremental implementation, **not completion of the entire review**.
“Implemented” below describes code and regression coverage, not a measured
native speedup. Native CI and hardware status must be read separately. No
finding has been experimentally ruled out by this Linux environment.

## Coverage matrix

| Report item | State | Change/evidence or reason still pending |
| --- | --- | --- |
| WIO-1 Windows continuation budget | Implemented, native latency pending | Shared `drain_round` supplies one 8 ms soft deadline and rotating cursor, 2–8 ms quanta. Deterministic 16-pane test serves each pane once in four dispatches; slow-feed test prevents another turn after deadline. Original 256-byte feeds, output, backpressure, posted clear/recheck and failure fallback retained. |
| WIO-2 hidden Windows blink | Implemented, native execution pending | Reflow cancels hidden timers through `syncBlinkTimer`; stale hidden WM_TIMER returns before touching window state. Native tests exercise cancel/rearm and queued-message suppression. Wall-clock phase unchanged on restored render. |
| WIO-3 256-byte SetEvent/QPC | Pending measurement | No batching without Windows evidence of throughput versus input-tail latency. The 256-byte interruptibility and wake protocol remain unchanged. Measure with ETW as below. |
| WIO-4 / shared 4 negative Windows hover | Implemented, native execution pending | Negative detection retains cell cache; test simulates 1,000 same-cell events with one detection. Existing repaint-time revalidation and click-time live detection remain. |
| W1 background output | Implemented, native execution pending | Hidden output no longer requests foreground rendering. Title hook still requests chrome; show/reflow renders current state. Native visibility test covers tabs and maximized-away panes. |
| W1 precise visible-pane invalidation | Pending design/native proof | Broader event audit needed for font/glyph epochs, palette, cursor, selection, images, resize/DPI, exposure and recovery. Window invalidation remains conservative. No required backbuffer copy removed. |
| W2 pane atlas growth | Pending design/native proof | Slot generations, pending wide pairs, eviction, maximum capacity and backend texture recreation need all-backend native validation. No atlas capacity or CJK quality reduction. |
| W3 cold wide glyph | Pending measurement/design | Synchronous first appearance preserved. A worker change must deliver both halves together without blank first-frame placeholders or lost epoch cancellation. |
| W4 ligature hashing | Implemented | Hash a run once and derive offset keys. Shared test compares every offset/style with the original constructor and checks distinct offset identity. Both hashes and all key fields preserved. |
| W5 D3D11 waitable admission | Pending native measurement | No change to waitable policy without native input/present and device-recovery evidence. |
| M1 incremental raster/upload | Pending design/native pixels | Requires full-render pixel oracle for Unicode, ligatures, cursor, selection, reverse/palette, wallpaper and three image layers. Full bitmap remains. |
| M2 Metal queue/wait/blit | Pending ownership design/native GPU | Existing wait ensures cross-queue order and source reuse safety. No wait/clear removed; discrete-GPU resource lifetime remains unproven here. |
| M3 macOS render/blink/poll consolidation | Pending native behavior | Hidden-view render guard preserved. Timer redesign needs visibility, close, polling, cursor and SGR phase tests and idle traces. |
| M4 macOS global output pump | Pending implementation/native tests | Per-pane semaphore backpressure remains. A shared pump must keep reader completion, EOF ordering and shutdown cancellation; not implemented in this increment. |
| M5 macOS hover | Implemented, native execution pending | C bridge caches hit/miss by cell, invalidated by feed/config/resize/scroll/leave. Native detection-count test: one probe per 1,000 unchanged events. Swift removes unconditional dirty but preserves URL-to-URL cell changes and cursor ownership. Clipboard suite checks 1,000 unchanged events schedule no raster and leaving schedules removal. |
| M6 shared Metal pipeline/wallpaper | Pending design/native measurement | Sharing requires device identity, failed creation and reload ownership coverage. No new global cache or borrowed wallpaper lifetime introduced. |
| M7 unchanged font config | Implemented, native execution pending | Compare renderer-owned full font options before allocating/rebuilding/clearing. Native tests retain font/family identity and check every option; real changes and OOM path remain. |
| Shared 1 image decode/UI budget | Pending protocol design/native tests | Async decode must preserve following VT operations, anchor, alternate screen and cancellation. Current feed remains indivisible; 8 ms is not a hard upper bound for decode. |
| Shared 2 image placement rebuild | Pending measurement/cache key | Requires image/storage generation plus viewport, cell geometry, screen and placeholder dependencies; image generation alone is insufficient. |
| Shared 3 payload/transfer retention | Implemented | Release capacity over 1 MiB at completion/cancel/disable, retain small scratch, preserve active multipart data. Shared protocol test checks image insertion, fragmented FilePart bytes, cancellation, disable and small-buffer reuse. Payload limit unchanged. Continuous large images may allocate more often; native RSS/churn still needs measurement. |
| R1 Vulkan backlog scanning | Partially implemented, native execution pending | Ordered completion prefix stops at first outstanding upload. Head cursor and half-full compaction amortize movement; teardown skips already retired entries. Shared test: 1,024 stalled polls inspect 1,024 entries, not 1,048,576. Timeline values and upload submission unchanged. |
| R1 Vulkan upload batching | Pending native resource design | Per-upload staging/pool/submission remain. Reuse must respect timeline completion, atlas generation and close/device loss. |
| R2 D3D12/Vulkan image retirement | Pending ownership/native GPU | Per-image synchronous retirement retained. Last-use fence/timeline ownership and bounded outstanding memory must be proven before delayed destruction. |
| R3 D3D12 tabbar cache | Pending implementation/native pixels | Persistent GPU band needs resize/DPI/theme/font and shared FontService invalidation tests. Existing final backbuffer copy must remain. |
| R4 GL/Vulkan cell generations | Pending measurement/design | Full per-slot copy retained until row-version restoration is verified over all frame slots, resize and font recovery. |
| A1 production allocator A/B | Pending measurement | DebugAllocator retained; no claim that Release captures debug stacks. Compare reclaiming thread-safe allocators with live-allocation and cancellation regressions. |
| A2 Windows font config ownership | Pending lifetime design | Existing borrowed UTF-16 generations retained; freeing after update alone could invalidate in-flight workers/renderers. |
| Low-priority title polling, WIC factory reuse, repeated hyperlink URI comparisons | Pending measurement | No native profile establishes significance; existing title dedup, image ownership and Unicode copy behavior preserved. |

All pending rows remain open work; absence of native hardware is a verification
limit, not evidence that they have been fixed or that every implementation is
impossible. GPU and protocol redesigns deliberately remain out of this first
increment because their no-regression requirement cannot yet be established.

## Test execution and CI

New shared tests are imported by `macos_grid_tests.zig` and the existing session
root, so `zig build test` runs them on Linux, macOS and all 12 Windows build
configurations. Native additions live in already imported Windows/macOS modules
and the existing Clipboard suite. Existing assertions are retained. Linux CI
now runs both Debug and ReleaseFast; Windows and macOS inventory entry points
remain the complete inventory documented in [README.md](README.md).

Cloud Linux results and native CI results are recorded in the PR. Shared
Linux execution cannot establish Win32/AppKit/Metal behavior. macOS cross-build
is **compile-only**. Hardware-only cases (old ConPTY, Intel/AMD Metal, real
device loss, RDP, mixed DPI) remain **blocked** until those platforms run.
The administrator RDP policy utility is never part of this test plan.

Dependency recovery: Zig's HTTP client returned `HttpConnectionClosing` before
tests ran. Downloading the exact declared archives from Codeberg, GitHub and
`deps.files.ghostty.org` with curl and importing them with `zig fetch` restored
the original content-addressed dependencies. No pin/hash was changed and no
download failure was labeled a product test failure.

## Native performance acceptance still required

Use the baseline and PR SHA with identical Release mode, fonts, dimensions,
opacity/wallpaper, renderer, OS and driver. Record SHA and environment with each
trace; run cold and warm cases separately and alternate A/B order.

* Windows: 1/4/8/16 output panes, one interactive shell, background output,
  ring saturation, close during output, and hidden/restored SGR blink. ETW/WPA
  and PresentMon: main-dispatch duration, input-to-present p50/p95/p99/max,
  per-pane bytes and final screen/scrollback checksum, SetEvent/QPC samples,
  wakeups and Present count. Count title changes separately from plain output.
  `MOSTTY_DIAG=1` now includes continuation-round count and maximum dispatch
  microseconds in the existing periodic diagnostics. Compare with logging off;
  synchronous diagnostic I/O is not a zero-cost latency probe.
* Both hosts: stationary and same-cell hover over blank, 4 KiB non-URL token,
  Unicode/OSC8 URL; output/scroll/resize underneath the pointer. Verify live
  click target, cursor ownership and underline pixels.
* macOS: theme-only reload across 1/16 panes, followed by each real font option
  and scale change; inspect font creation and shaping-cache misses. Run the
  complete unit/themes/titles/panes/pane-config/clipboard/scrollbar/interactions
  inventory with its existing capability probes.
* Images: one large image then text; repeated large images; alternating sizes;
  multipart, cancellation, disable and OOM. Compare allocated capacity, native
  RSS and allocation churn as distinct metrics; verify pixels and anchors.
* Vulkan: stalled GPU/cold glyph uploads, timeline progress, repeated partial
  retirement, close and device loss. Inspect pending resources, queue submits
  and retirement scans; batching and synchronous image waits remain unchanged.

Mechanism counts above are algorithm/test evidence, not native speedup
percentages. No reduction in refresh rate, output, image limit, atlas capacity,
Unicode/ligatures/emoji, IME or accessibility is authorized by this change.
