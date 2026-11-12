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
