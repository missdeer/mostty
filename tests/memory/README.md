# Native memory evidence

Build both revisions with Zig 0.17.1, `-Doptimize=ReleaseFast -Dcpu=baseline`,
the same dependency manifest and native toolchain. Use one Mostty instance per
trial. Run fresh processes in **ABBA BAAB** order: base/head/head/base/head/base/
base/head, numbered 0–7. Build before timing. Keep physical window pixels, font,
DPI/scale, input, pane arrangement and checkpoints identical. Preserve the
existing `tests/bench` paired throughput/control report alongside this report.

## Collect

Windows requires PowerShell 7. Start the staged distribution so its signed
`conpty/manifest.json` identifies the actual DLL/OpenConsole version and hashes.
CI pins **1.25.261109001**, the actual version used by the preceding PRs, and
adds revision/compiler/mode/CPU/dependency hash in `build-metadata.json`.

```powershell
./tests/memory/fixture.ps1 -Case cjk-cold -Output tmp/cjk.bin
# In the target pane: cmd.exe /c type C:\absolute\path\tmp\cjk.bin
'{"action":"resources"}' | & ./dist/Mostty.exe +control --target-process 1234
./tests/memory/collect.ps1 -TargetPid 1234 -Executable ./dist/Mostty.exe `
    -Metadata tmp/base-0.json -Output tmp/memory/base-0.jsonl -Samples 60 -IntervalMs 250
```

macOS requires a GUI login session and Apple Events permission. Exactly one
running instance with the target bundle ID is required; unavailable or ambiguous
automation is blocked. `resource data of terminals` exposes per-pane JSON.

```sh
swiftc tests/memory/fixture.swift -o tmp/memory-fixture
tmp/memory-fixture tests/memory/workloads.json cjk-cold tmp/cjk.bin
# In the target pane: /bin/cat /absolute/path/tmp/cjk.bin
swiftc tests/memory/collect.swift -framework AppKit -framework Metal -o tmp/memory-collect
tmp/memory-collect 1234 tmp/base-0.json tmp/memory/base-0.jsonl 60 250
python3 tests/memory/report.py tmp/memory tmp/memory-report
```

The final command is portable Linux artifact analysis. Native code uses
PowerShell/Swift. Preserve fixture `.json` sidecars (SHA-256/byte count). CI
compares Windows/macOS fixture bytes and samples each collector's own process;
this smoke explicitly blocks Mostty/GPU/latency/energy claims.

Metadata example: replace placeholders with actual build/resource API output.
Compiler mode/CPU use the running app's spelling, not CI matrix display labels.

```json
{
  "commit": "FULL_GIT_COMMIT", "compiler": "0.17.1", "mode": "release_fast",
  "target_cpu": "ACTUAL_CPU_MODEL", "backend": "d3d11", "presentation": null, "font": "ACTUAL_FONT",
  "font_size_pt": 13, "dpi": 96, "window_pixels": [960, 640], "panes": 1,
  "dependencies": "SHA256_OF_BUILD_ZIG_ZON", "conpty_version": "1.25.261109001",
  "input_sha256": "SHA256_FROM_FIXTURE_SIDECAR", "scenario": "cjk-cold",
  "phase": "steady", "side": "base", "trial": 0, "run_group": "PHYSICAL_HOST_EXPERIMENT",
  "steady_samples": 20, "warmup_seconds": 3, "related_pids": []
}
```

On macOS use `coretext-metal`, `conpty_version: "not-applicable"`, and raster DPI
`72 * backing_scale` (not physical monitor PPI). CoreText records configured
family/fallbacks; fallback resolution needs native pixel checks. Window pixels
include content/chrome, while `surface_pixels` describes the pane bitmap.
Use presentation `metal` on macOS, null on D3D11/D3D12, and the actual API
presentation value on Vulkan/OpenGL. Keep these variants in distinct run groups.
Collectors add OS/CPU/GPU/driver information, cadence, PID scope and probe time.
Windows records the executable hash. Mostty includes in-process conpty.dll;
OpenConsole/shell are excluded. Supply `related_pids` to sample them separately.

## Checkpoints and controls

Use the fixture catalog plus existing automation/config/GUI tools. Each stable
checkpoint is its own eight-trial group. Finish input before steady samples.
Record fresh Release idle with zero warmup and warmed idle separately. Sampling
starts after hardware metadata gathering; launch-to-first-frame peaks are not
captured. Report the actual observation window.

| Issue | Target/checkpoints | Control | Deterministic evidence |
|---|---|---|---|
| #14 | cjk-cold/emoji-combining; 1/8/16 splits and separately visited background tabs | ascii-control, idle-control | atlas slots/extent, hit/miss/eviction, VT checksum and native pixel oracle |
| #15 | cache-churn, font/DPI reload, pane close | stable ASCII | live allocator requests, zero glyph arena retention, free/rebuild tests |
| #16 | large-images, background disable, re-enable/new image | small-image-control | primed image snapshot then zero VT/renderer copies |
| #17 | scrollback plateau, main/alternate images, zero/small/large budgets | short ASCII, small image | page estimates, separate screen image bytes, ordered final content |
| #18 | visit 1/8/16 tabs, hide 31 s, restore; enlarge/shrink checkpoints | switch back within 30 s | actual trimmed state, zero tracked transient resources, preserved VT/restoration oracle |
| #19 | one-cell/cursor/selection changes and Unicode | full damage, stable no-op | raster/upload area and wait counters, full-render pixel oracle |
| #20 | cold glyph/image bursts; native/bridge GPU stalls | one small upload per frame | actual allocation/task/pool bounds, partial timeline/error tests |
| #21 | 1/8/16 background tabs, detach/minimize/hide/close | visible blinking pane | actual callback counts, hidden PTY/EOF, OS wakeups separately |
| #22 | rapid large-wallpaper reload, clear/close during decode | ordinary single load | active/queued/ready ≤1, ownership/notification tests, newest displayed image |

For lifecycle phases include raw pre-action app data in `precondition_app`.
`images-disabled` requires primed renderer images and zero screen/renderer
copies afterwards. `trimmed` requires explicit `target_panes` string IDs and a
primed cache; each target must reach trimmed state. `panes-closed` requires
`closed_panes` previously present and now absent. Keep another pane alive:
process exit or unavailable API is not proof of zero held resources. Wallpaper
configuration remains independent of terminal `images-enabled`.

The same fixture generators produce `wallpaper-control` (256² BMP),
`wallpaper-large-red` and `wallpaper-large-blue` (4096² BMP). Generate files
before timing, alternate their absolute paths in the isolated test config using
the existing reload tools, then clear the path or close while decode is active.
The control loads one small file once. Preserve the config/path-change timing,
both fixture sidecars, final displayed color and first/final-image timing.

## Interpret

Raw JSONL and results.json retain every sample. OS metrics, logical categories,
requested allocations and GPU counters have separate tables. Paired OS ratios
are report-only; sampled peaks are not true allocation peaks. VT resident bytes
are upstream estimates. Glyph requests omit allocator page rounding. Unknown
presentation/driver resources are null. CoreText/font internals are excluded.
Metal currentAllocatedSize has device scope, is deduplicated by registry ID and
overlaps unified-memory footprint. Never add it or logical textures to OS RAM.
Unavailable/localized Windows GPU counters are null/blocked. Largest completed
WIC buffer excludes codec scratch and UI-taken pixels; it is not decode RSS.

The analyzer rejects mismatched conditions, missing samples, VT/SGR drift,
cleanup and budget violations. VT hashes exclude final GPU pixels, selection
and cursor blink: preserve native pixel-oracle artifacts. OS noise has no hard
threshold. Optional external `input_to_present_ns` arrays plus a precise,
identical `latency_source` (clock/event/endpoint/hardware) produce p95/p99/n.
Collector probe_ns is overhead, never presentation latency.

Release Mostty comparisons, physical Windows GPU/native-bridge stalls,
Intel/AMD Mac behavior, input-to-present and energy remain **blocked/pending
until those hardware runs are supplied**. Hosted smoke/shared tests and static
capacity reductions do not establish those gains.
