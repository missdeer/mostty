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
