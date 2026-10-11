# Runtime performance comparisons

`Runtime benchmarks` is an additional pull-request workflow, not a replacement
for any unit or acceptance test. It runs base and PR **on the same hosted runner**
on Linux, macOS and Windows. There are no credentials persisted by checkout,
no secrets, no `pull_request_target`, and no extra repository is downloaded.

Each side uses the PR's identical benchmark sources and build recipe overlaid
on a detached worktree of the recorded commit. Dependency manifests must match
byte-for-byte. Both executables are built once in ReleaseFast with baseline CPU
features before measurement starts. Compilation time is not a sample. The
native fixtures are appended inside their owning modules so they call the
actual private production paths, without exposing application APIs for tests.
The hover and hash-counter insertion points must match exactly once or setup
fails. Counter instrumentation is identical on both sides on all platforms;
timings include its writes and are not uninstrumented application timings.

Run `BENCH_BASE=<commit> bash tests/bench/run.sh` on Linux/macOS, or set
`BENCH_BASE` then run `tests/bench/run.ps1` on Windows, in a checkout with Zig
0.16.0 and its normal platform prerequisites. Use a fresh `tmp/runtime-bench`
directory/worktree registry for a new comparison, or set `BENCH_OUTPUT` to
another relative path under `tmp/`. On Linux, run
`python3 tests/bench/report.py tmp/runtime-bench tmp/benchmark-report` to analyze
one run; the CI report job analyzes all three platform artifacts. Python is
used only in the Linux analysis job; platform runners use shell or PowerShell.

## Workloads and boundaries

| Case | Equal input on both sides | Measured production boundary |
| --- | --- | --- |
| `ligature_keys` | 5,000 varied 32-byte runs, all 32 output keys | API microbenchmark only; does not guard production callers. No work-count claim or gate. |
| `windows_ligature_runs` | 5,000 varied 32-cell cached runs | Actual production `generateRun`, all output slot indices checked. A test-only counter inside `Key.initRun` observes real hash pairs; identical instrumentation is overlaid on base. Does not measure DirectWrite shaping or cold rasterization. |
| `viewport_frames` | 100 builds of the same 120×40 Unicode/styled viewport | Real grid builders; base owns/frees frames, PR uses the renderer's retained-storage API. Same geometry and cell checksums. |
| `multipart_scratch` | Four >1 MiB FileParts, each superseded by a new header | Real session/parser replacement path; includes repeated-large-transfer allocation churn as well as idle retained capacity. |
| `plain_output_control` | 256 KiB of ordinary terminal output | Unchanged bulk VT path, final terminal text checksum. |
| `small_sixel_control` | 100 small Sixel images | Real decode/insertion path, all images/placements and pixel checksums verified; checks the small-payload tradeoff. |
| `macos_font_config` | 32 identical font configurations | Real CoreText renderer reconfigure, metrics checked on each call; creation/Metal setup excluded from timing. |
| `windows_hover` | 10,000 same-cell events over a 4 KiB non-URL token | Real `updateUrlHover`, Win32 pane lookup and terminal content; detection wrapper counts actual probes on both versions. |
| `windows_output_total` | Eight real PTY rings/sessions, 128 KiB each | Actual continuation dispatcher with QPC, timers and parser; every byte consumed and final terminal text checksums compared. Actual dispatch count reported separately from first-all-progress round. No reader threads or interactive keyboard timing. |
| `windows_dispatch` | Dispatches needed to consume the identical stream above | Per-dispatch duration distribution, recorded in memory and printed after timing. Work per dispatch intentionally differs; interpret alongside total throughput. |
| `windows_all_panes_progress` | Same eight panes | Time until every pane has advanced at least once, observed at dispatch boundaries; `calls` records round count, not keyboard latency. |
| `windows_saturated_*` | Eight full 1 MiB PTY rings/sessions | The same three dispatch/total/fairness measures with 8× the small-load input, to exercise the shared deadline. Both scenarios are retained; inspect actual round counts and maximum dispatch duration before claiming the budget was exercised. |

The macOS allocator is the application's C allocator and Windows uses its
production global DebugAllocator. Linux uses `smp_allocator` as a shared-core
measurement, not as a substitute for native allocator behavior. Allocation
tracking wraps the same allocator on both sides. Retained-byte figures describe
owned frame/scratch storage; they do **not** measure OS RSS, CoreText internal
allocations or GPU memory. Font allocation counts cover renderer-owned data.
Allocation/retention fields are instrumented only for viewport, multipart and
font cases; zero placeholders in other raw rows mean unmeasured, not zero cost.

## Sampling, gates, and honest interpretation

Order is ABBA BAAB (four process trials per revision). Every executable warms
each case three times, then records 15 samples: normally 60 measured samples
per revision/case. Dispatch samples also retain every individual dispatch.
Artifacts include original logs, commit/OS/CPU/Zig/mode/input metadata, raw
machine-readable samples, n, median, p95, min/max, MAD, units/second, per-trial
ratios, allocator counts, retained bytes and checksums. Timed results are used
and checked, with optimization barriers at key/cell boundaries.

Output equality, sample completeness, identical units and deterministic budgets
are hard gates: warm frame/font allocations stay zero, same-cell hover probes
stay one, superseded scratch stays below 1 MiB, actual production run hashing
stays once per run. A normal Windows unit test also calls `generateRun` for all
four styles and verifies every cached slot and the real hash counter. Existing
fairness and protocol tests remain mandatory too.

Wall-clock is **report-only**. The report labels a change as repeatable only
when all four paired trial medians agree on direction and the median ratio's
distance from one exceeds three times observed noise (pair MAD or normalized
sample MAD). This is a review heuristic, not a confidence interval. Otherwise
it says no clear change. Every case, including regressions and unclear results,
is reported; retain raw samples and repeat before choosing a future CI timing
threshold. No arbitrary percentage fails a build on a noisy hosted runner.

GPU submission/lifetime, display quality, physical-device recovery, actual
input-to-present p99, Intel/AMD Mac behavior and power/wakeup counts still need
their native/hardware acceptance and measurements. These benchmarks make no
claim about them.
