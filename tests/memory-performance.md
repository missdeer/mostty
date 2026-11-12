# Memory optimization evidence

Logical resource bytes and live allocator requests are not RSS or operating
system working-set measurements. Native GPU/OS measurements must be recorded
separately, with hardware, backend, optimization mode, font, DPI and pane count.

## Glyph index allocations (#15)

Zig 0.17.1, Linux x86_64, production `GlyphIndexCache`, Debug and ReleaseFast.
Each workload fills the cache, then inserts and marks ready 128 additional keys
with frame boundaries, exercising eviction. A counting reclaiming allocator
records requests and confirms every byte is freed at teardown. Initialization
failure at each allocation and eight rebuild cycles also run with leak checks.

| Slots | Map capacity | Live requested bytes | Allocations |
| ---: | ---: | ---: | ---: |
| 32 | 64 | 3,928 | 2 |
| 3,272 | 4,096 | 328,216 | 2 |
| 83,436 | 131,072 | 9,141,016 | 2 |

Filling and eviction add zero allocations to these initialization counts.
No superseded HashMap allocations or arena growth slack remain in production.
The former synthetic arena baseline in #15 retained 22,875,660 bytes at 83,436
keys; its initial capacity was 8,009,904 bytes. These are different allocator
metrics and their difference must not be called native RSS savings.

Commands: `zig test src/win32/glyph_index_cache.zig` and the same command with
`-O ReleaseFast`. The suite is also imported by the shared/native aggregates.
Native backend font/DPI reload and pane-close unit paths run in Windows CI;
dedicated Release memory and lookup/insert latency measurements remain pending.

## Hidden render caches (#18)

The shared visibility policy asserts a 30-second warm period, no deadline reset
from repeated hidden activity, no trim during quick switches, stale-timer safety
and idempotent trimming. Windows native tests exercise rejection of a late job
whose key/slot/slot generation would otherwise alias a restored cache. macOS
native tests trim rendered content/images, keep receiving output and changing
scale/geometry while trimmed, then compare restored pixels against a full-render
oracle. Cache capacity is checked before/after trim; terminal state remains live.

Windows counters live on each `Pane` (`render_trim_count`, `render_trim_bytes`,
`render_restore_us`); macOS counters live on `CoreTextRenderer` (`trim_count`,
`trim_logical_bytes`, `restore_ns`). Byte counts are logical lower bounds and
recreation timings exclude first raster, GPU presentation and input latency.
Native 1/8/16-tab steady/peak OS/GPU memory and p95/p99 restoration measurements
remain pending; hidden fonts/wallpaper/host drawables retained on macOS must be
reported separately.

## macOS row damage (#19)

Native tests compare incremental pixels with a forced complete raster for ASCII,
CJK, emoji, combining marks, styles/decorations, old/new cursors, SGR blink,
selection, reverse video and palette changes. A single ASCII change must raster
and upload less than a full window; stable frames upload zero bytes. Failed
snapshot allocation must leave the snapshot invalid and retry completely.
Resize/scale, image/wallpaper and hidden restoration retain their existing full
paths and tests. Core and host presentation share one ordered Metal queue.

`last_rasterized_pixels`, Metal `last_upload_bytes`/`uploaded_bytes` and
`last_wait_ns`/`wait_ns` separate work reduction from storage and UI waiting.
The CPU bitmap and two Metal textures remain allocated while active. Apple
Silicon CI is native evidence; Intel/AMD managed/private storage, physical
footprint, bandwidth and p95/p99 input-to-present measurements require separate
hardware runs and are not inferred from logical upload area.

## Vulkan uploads (#20)

Uploads copy caller bytes immediately into owned staging. At most 64 closed
commands or 4 MiB trigger a batch; the remaining batch flushes before either
native or bridge frame submission. Completed size classes reuse staging and
command pools. A 64-request mock batch asserts one submit, partial timeline
completion asserts no early reuse, and device-loss submission preserves pending
ownership. Existing completion-prefix tests cover compaction and exact release.

Admission counts actual Vulkan memory requirements before allocation: ordinary
active/pending work is bounded by 16 MiB and 128 tasks. A larger single upload
(maximum 1 GiB allocation) drains preceding work and remains exclusive until
complete. It is never pooled. Idle reuse is separately capped at 8 MiB, 64 tasks,
and 256 KiB per allocation. Driver metadata is outside these byte counts.
Backpressure uses the existing bounded 10-second timeline wait; timeout enters
the renderer failure path instead of allocating additional staging. Lifecycle
retirement flushes pending commands and establishes idle/device loss before
destroying referenced images; failed submissions block further uploads/draws.

`Core.upload_stats` records request/byte counts, allocations, command pools,
submits, reuse, backpressure, peak active/allocated bytes and maximum reclamation
latency. Native cold CJK/emoji, image bursts, intentional GPU stalls, bridge and
native pixel equivalence and small-upload p95/p99 latency are **blocked** here:
the Linux workspace and hosted Windows tests do not provide an interactive
Vulkan GPU. Mock counts prove the mechanism, not hardware performance gains.

## macOS hidden timer callbacks (#21)

The production AppKit view invalidates render/blink timers immediately on
detach, ancestor hide, ordered-out/minimized window or application hide. The
PTY reader and global feed/EOF pump remain independent. Visible panes retain
their capped repeating timer so temporary drawable/command failures retry.
Resume restores the wall-clock blink phase and schedules the pending first
frame immediately; repeated visibility events and unchanged interval reloads
do not register additional timers. A window-wide scheduler was considered;
this change retains per-visible-pane scheduling to preserve existing cadence
and retry behavior while eliminating all hidden periodic render/blink work.

Native ClipboardTests counts actual run-loop callback deltas for 1/8/16 started,
detached views over 0.60 seconds (covering both periods), requires zero callbacks,
and uses a visible control to prove both timers fire. It also exercises repeated
reload, attach/unhide/order-out/close and the existing failure-retry checks.
These callback measurements are not OS wakeup, idle CPU or energy measurements.
Real PTY output/EOF fairness has separate native tests; physical Mac energy and
minimize/application-hide interaction measurements remain pending.

## Wallpaper decode ownership (#22)

All Windows backends share one lazily started, joined worker per process
renderer. There is at most one active decode, one latest pending path and one
ready result. Superseded pending/ready envelopes are freed immediately; active
WIC work checks generation between codec stages, before pixel allocation and
before publishing. Individual WIC calls are not interruptible, so close waits
for one active decode. A coalesced zero-payload notification cannot leak an
owning result after HWND destruction. Notification failure frees its result and
allows same-path retry. Clearing configuration cancels late work. Scalar-only
fit/position/opacity changes do not restart decoding; failed preparation keeps
the displayed wallpaper until a successful replacement or explicit clear.

Threaded tests exercise 100-request storms, partial progress, newest-result
selection, clear/close with active work, decode failure, notification failure,
and coalesced notifications with leak checks. Shared adapter tests cover stale
results, failed GPU preparation, setup OOM/same-path retry eligibility, scalar
changes and explicit clear. `Worker.stats()` exposes active/queued/ready counts,
coalesced requests, completed decodes, ready pixel bytes and the largest decoded
buffer. The latter excludes WIC-private scratch and pixels already taken by the
UI; it is not a process RAM peak. WIC's existing 16384-square dimension cap
still limits a returned BGRA buffer to 1 GiB. Native large-wallpaper storms,
first/final image latency, CPU and sampled OS/GPU peaks remain pending hardware
measurements; single-image loads are the control workload.
