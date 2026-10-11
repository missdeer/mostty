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
| M1 incremental raster/upload | Partially implemented | Renderer retains frame-cell capacity between equal-sized frames, releasing it on successful surface resize. 1,000 changing Unicode/styled frames match owned frame results with zero storage allocations after warmup; failed growth preserves storage and can retry. Full raster and upload remain: they need a full-render pixel oracle covering cursor, selection, reverse/palette, wallpaper and all image layers. |
| M2 Metal queue/wait/blit | Pending ownership design/native GPU | Existing wait ensures cross-queue order and source reuse safety. No wait/clear removed; discrete-GPU resource lifetime remains unproven here. |
| M3 macOS render/blink/poll consolidation | Partially implemented | Existing raster traversal records visible SGR blink. Host toggles phase but requests a frame only for a visible blinking element (focused DECTCEM cursor at viewport bottom or SGR text). Restore explicitly dirties the view. Native pixel assertions and host tests cover no-blink, cursor-hidden, unfocused SGR, detach/restore. Timer wakeups and PTY polling remain: replacing polling needs cancellable readiness/close tests; event-driven frame timers need native cadence/recovery evidence. |
| M4 macOS global output pump | Implemented, native execution/latency pending | One main-thread pump rotates sources under an 8 ms soft deadline and 2–8 ms per-source quantum. 256-byte feeds preserve stream order; eight in-flight chunks per pane stay bounded until consumed/cancelled. EOF queues behind bytes. Production-pump tests cover 16-pane fairness, yielding, exact byte order, EOF, partial-chunk slot ownership, cancellation and late delivery. Image decode can still exceed the soft bound; native input-tail/throughput A/B remains required. |
| M5 macOS hover | Implemented, native execution pending | C bridge caches hit/miss by cell, invalidated by feed/config/resize/scroll/leave. Native detection-count test: one probe per 1,000 unchanged events. Swift removes unconditional dirty but preserves URL-to-URL cell changes and cursor ownership. Clipboard suite checks 1,000 unchanged events schedule no raster and leaving schedules removal. |
| M6 shared Metal pipeline/wallpaper | Pending design/native measurement | Sharing requires device identity, failed creation and reload ownership coverage. No new global cache or borrowed wallpaper lifetime introduced. |
| M7 unchanged font config | Implemented, native execution pending | Compare renderer-owned full font options before allocating/rebuilding/clearing. Native tests retain font/family identity and check every option; real changes and OOM path remain. |
| Shared 1 image decode/UI budget | Pending protocol design/native tests | Async decode must preserve following VT operations, anchor, alternate screen and cancellation. Current feed remains indivisible; 8 ms is not a hard upper bound for decode. |
| Shared 2 image placement rebuild | Pending measurement/cache key | Requires image/storage generation plus viewport, cell geometry, screen and placeholder dependencies; image generation alone is insufficient. |
| Shared 3 payload/transfer retention | Implemented | Release capacity over 1 MiB at completion/cancel/disable, retain small scratch, preserve active multipart data. Shared protocol test checks image insertion, fragmented FilePart bytes, cancellation, disable and small-buffer reuse. Payload limit unchanged. Continuous large images may allocate more often; native RSS/churn still needs measurement. |
| R1 Vulkan backlog scanning | Partially implemented, native execution pending | Ordered completion prefix stops at first outstanding upload. Head cursor and half-full compaction amortize movement; teardown skips already retired entries. Shared test: 1,024 stalled polls inspect 1,024 entries, not 1,048,576. Timeline values and upload submission unchanged. |
| R1 Vulkan upload batching | Pending native resource design | Per-upload staging/pool/submission remain. Reuse must respect timeline completion, atlas generation and close/device loss. |
| R2 D3D12/Vulkan image retirement | Pending ownership/native GPU | Per-image synchronous retirement retained. Last-use fence/timeline ownership and bounded outstanding memory must be proven before delayed destruction. |
| R3 D3D12 tabbar cache | Partially implemented | CPU band owns a cached WIC pixel snapshot; every painter clears before drawing, invalidating it. Native test checks 1,000 unchanged reads perform one CopyPixels and checks pixels after clear/resize. Per-frame staging/upload remains; a persistent GPU band still needs resource-state, resize/DPI/theme/font and device-recovery coverage. Existing final backbuffer copy remains. |
| R4 GL/Vulkan cell generations | Pending measurement/design | Full per-slot copy retained until row-version restoration is verified over all frame slots, resize and font recovery. |
| A1 production allocator A/B | Pending measurement | DebugAllocator retained; no claim that Release captures debug stacks. Compare reclaiming thread-safe allocators with live-allocation and cancellation regressions. |
| A2 Windows font config ownership | Pending lifetime design | Existing borrowed UTF-16 generations retained; freeing after update alone could invalidate in-flight workers/renderers. |
| Low-priority title polling, WIC factory reuse, repeated hyperlink URI comparisons | Pending measurement | No native profile establishes significance; existing title dedup, image ownership and Unicode copy behavior preserved. |

All pending rows remain open work; absence of native hardware is a verification
limit, not evidence that they have been fixed or that every implementation is
impossible. GPU and protocol redesigns deliberately remain out of this first
increment because their no-regression requirement cannot yet be established.

## Remaining work: concrete gates and smallest next step

These are **not experimentally excluded**. The hosted Windows inventory runs
its offline PowerShell checks but reports the interactive renderer/backend,
tabbar/close-redraw, mixed-DPI/RDP and real device-loss cases blocked. macOS CI
runs the AppKit inventory on its available Apple GPU; it reports Intel/AMD GPU
coverage blocked. Linux cross-compilation cannot replace either missing surface.

| Remaining item | Why the present checks do not establish no regression | Smallest next step |
| --- | --- | --- |
| WIO-3 / W5 | Ring callbacks still signal after advancing tail; QPC currently bounds every 256-byte feed. A larger batch changes both writer wake latency and input admission. Waitable presentation can similarly defer a ready pane. Unit arithmetic cannot establish p99 input latency. | Use existing continuation duration/byte diagnostics plus ETW/PresentMon on 1/4/16 panes; compare wake batching separately from the present policy, including a saturated ring and close. |
| W1 visible-pane invalidation | Font-worker results, configuration, exposure, recovery and user interactions still enter window-level invalidation. There is no complete per-pane content/paint generation covering all those writers. Deleting redundant-looking Present/backbuffer copies before adding those generations can expose stale surfaces. | Add a per-pane invalidation trace and event matrix; run font/selection/image/exposure/resize/recovery cases on the interactive Windows runner before switching rendering to that matrix. |
| W2 / W3 | Atlas slots encode glyph positions and pending wide pairs; resizing an atlas requires invalidating/rebuilding backend resources as well as preserving slot generations. Moving cold wide glyphs to the worker additionally changes first-frame completeness. Existing hosted tests do not exercise all renderer/font-epoch/eviction combinations interactively. | Prototype growth behind an explicit experiment, preserve the current maximum and test cold CJK/emoji plus eviction and delayed worker results on every backend; collect memory and first-visible-frame pixels. |
| M1 remaining / M2 | CoreText composites wallpaper, backgrounds, cursor, selection and image layers into one reused bitmap. Metal uploads that bitmap with `replaceRegion`; Zig then waits before Swift's separate queue blits. Removing the wait, even after unifying queues, does not by itself protect the CPU-written texture from an earlier GPU reader. | Build a full-render versus incremental pixel oracle for every layer; separately add bounded texture generations with explicit completion ownership and stress both unified/discrete GPUs before removing any wait. |
| M3 remaining | PTY read polls every 50 ms so shutdown can join it. The render timer also detects drawable changes. Replacing either with blocking/event-only behavior changes cancellation or restore discovery. | Add a wake descriptor and a close-while-blocked test before blocking reads; audit resize/restore/device failure events before retiring the render timer. The blink-frame reduction in this PR does not claim fewer timer wakeups. |
| M6 | Per-renderer Metal pipeline creation is tied to the renderer's device; wallpaper pixels/render objects have reload and deinit ownership. A global borrowed object would need device/config identity and reference-counted lifetimes, not just a path key. | Measure startup/reload across 1/16 panes, then introduce a device-owned cache with failure/reload/close tests if its cost is material. |
| Shared async image decode | The same feed can decode an image and execute following VT bytes. A worker completion arriving after scroll/alternate-screen/delete cannot simply insert at the current cursor. | First define an ordered pending-operation/anchor token and cancellation model, with DCS/OSC completion followed by scroll, alternate screen and delete; only then offload decode. Current soft deadlines explicitly exclude a hard bound on decode. |
| Shared image placement cache | Image pixel generation does not describe viewport scroll, placeholder cells, cell geometry or active screen. Both renderers rebuild placements using these live inputs. | Add counters and a complete placement dependency key, then compare cached versus uncached placement lists during scroll, resize, placeholder edits and alternate-screen transitions. |
| R1 batching / R2 retirement | Current upload resources have per-submit lifetime; D3D12 image release may flush an open command list, and Vulkan release waits through the latest timeline. A deferred destructor must include references in unsubmitted commands and cap retained bytes. | Extend generation ownership tests to open-list references, failed submits and device loss; then use a bounded staging/retirement queue and run both native Vulkan and interop acceptance on a GPU runner. The prefix mock only proves collection bookkeeping. |
| R3 remaining | WIC snapshot reuse is covered, but avoiding staging requires a new persistent GPU texture and state transitions. Resize A→B→A and device recreation must invalidate its upload state independently of the shared CPU band. | Add the persistent texture plus resize/recovery pixel checks on the interactive D3D12 runner; preserve the final per-backbuffer copy. |
| R4 | Each ring slot currently receives a complete previous generation before row differences. A dirty-row-only copy can resurrect an older row when a slot returns after several frames. | Measure copied bytes first; test row-version catch-up over every slot, resize second frame, font change and recovery before replacing full copies. |
| A1 / A2 | Allocator names are not performance evidence. UTF-16 font options are borrowed by font objects/workers, so freeing the old config immediately can invalidate live readers. | Run allocator A/B on native output/image/reload workloads with retained/live-byte counters; model font-option generations and worker acknowledgements before reclaiming retired strings. |
| Title polling / PNG WIC factory / hyperlink URI comparisons | Existing dedup/ownership checks remain, and no native trace ranks these below the confirmed scheduling/render work. | Count calls and allocated/copied bytes in the corresponding workload before adding persistent caches or changing comparison/ownership rules. |

## Test execution and CI

Follow-up behavioral coverage uses the production clear/recheck helper with
controlled producer interleavings, and the actual Windows continuation dispatcher
with a controlled clock, real PTY rings and terminal sessions. It checks skipping
closed/idle panes, rearming the unvisited tail, and consuming it next round. A
hidden-pane test sends ordinary bytes and OSC 2 through the real window data
handler: both drain, only the title requests chrome. macOS hover tests invoke
config, surface and all scroll entry points. The Vulkan collector's production
retire/compact path is shared with a resource-destructor mock checking exactly-once
release across partial progress, compaction, append, and teardown. This does not
replace native GPU lifetime validation.

Blink gating must not remove render recovery: every pre-submit failure keeps
the frame dirty and retries on the existing capped render timer, even with a
hidden cursor and no SGR blink. The AppKit regression invokes the production
render tick with a nil bridge result, then a real Metal texture plus failed
presentation admission, then successful submission; it checks one attempt per
tick and no further work after recovery. The presentation allocation boundary
is injected; the test does not claim a physical GPU fault was induced.

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
