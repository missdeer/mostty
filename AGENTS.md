# AGENTS.md — 6-rule

These rules apply to every task in this project unless explicitly overridden.
Bias: caution over speed on non-trivial work. Use judgment on trivial tasks.
Each rule ends with a ❌/✅ pair — match the pattern, not the slogan.

## Rule 0 — Modern CLI only (enforced by PreToolUse hook)
Mappings: `find`→`fd`, `grep`→`rg`, `cat`→`bat` (or Read), `ls`→`eza`, `diff`→`delta`, JSON parsing → `jq` (never `python -c "import json"`).
The hook `.claude/hooks/legacy-cli-pretool.sh` will **deny** any Bash call whose first segment-token is a legacy tool and tell you the replacement — reissue with the modern equivalent, don't retry the same command. `git grep` / `git diff` are fine.
On Windows, `fd` is backed by the Everything search index, so a filename search returns instantly even across a whole drive. Search roots are per-drive (`C:\`, `D:\`, …), not a unified `/` — pass the drive root you want, e.g. `fd -t f 'mingw32-make' 'D:\'`. Prefer reaching for `fd` first whenever you need to locate a file.
Use the built-in file-editing tools; never edit files with external tools like `perl` / `awk` / `sed`. Every file edit — including bulk renames and repeated substitutions across a file — goes through Edit / Write / NotebookEdit, so the change is reviewable as a diff.
- ❌ `find . -name "*.go" | xargs grep TODO`
- ✅ `fd -e go -x rg TODO`

## Rule 1 — Think, ask, surface conflicts
State assumptions before coding. If ambiguity materially affects behavior or scope, ask; otherwise make the smallest reasonable assumption and state it. If two patterns in the codebase contradict, pick one (more recent / more tested), say why, flag the other for cleanup; never blend them. Use the model only for judgment work (classification, drafting, summarization, extraction); for routing / retries / deterministic transforms, write code — don't ask the model.
- ❌ Picking interpretation A and producing 200 lines of code for it; or writing a retry loop by prompting the model.
- ✅ "I see two readings: A or B. Going with A because X; mention it in the result." / Retries live in a `for` loop with explicit backoff.

## Rule 2 — Minimal, surgical, conformant changes
Smallest diff that solves the stated problem. No speculative features, no abstractions for single-use code, no "improvements" to adjacent code / comments / formatting. Match the codebase's existing style even if you disagree — if you genuinely think a convention is harmful, surface it; don't fork silently. Senior-engineer test: would they call this overcomplicated or out-of-scope? If yes, simplify.
- ❌ Bug fix that also renames variables in nearby functions "while we're here", or introduces a `Strategy` interface for one caller.
- ✅ Smallest diff that fixes the bug; new abstraction only when ≥2 real call sites exist.

## Rule 3 — Read before you write
Before adding or changing code that may overlap existing behavior, inspect the relevant exports, immediate callers, and shared utilities in `libs/`. "Looks orthogonal" is dangerous — structure usually exists for a reason. Confirm a new helper has a real call site before committing it; `unusedfunc` / `unusedparams` are blocking findings, not advisories.
- ❌ Writing `parseDate()` helper and trusting nothing similar exists.
- ✅ `rg -i 'parseDate|ParseDate' libs/ tools/` first, then either reuse or add.

## Rule 4 — Goal-driven loop
Define the intended outcome up front, then iterate until it is met. Don't follow a fixed step list — strong criteria let you self-correct. For behavior changes, verify the affected behavior when practical and report the evidence; do not add extra test work when existing checks already provide sufficient coverage.
- ❌ "Done — `go build ./...` passes."
- ✅ "Criteria: import R41 into `dewu-burgeon-sales-daily` for week N. Ran `./bin/...`; row count matches source xlsx (1,234); spot-checked 3 rows against `usage.md` query."

For trivial, documentation-only, or mechanically local changes, use proportionate verification.

## Rule 5 — Report honestly: checkpoint, fail loud, tests verify intent
**Checkpoint** at meaningful milestones — what's done, what's verified, what's left; if blocked, state the blocker and continue any independent work. **Fail loud** — "completed" is wrong if anything was skipped silently; "tests pass" is wrong if any were skipped or marked `t.Skip`; surface uncertainty, don't hide it. **Tests encode intent**, not just behavior — when adding or changing a test, assert *why* the value matters (the rule), not just *what* it is right now. Add or change tests only when the change has a behavior rule that existing checks do not cover.
- ❌ "All 3 subtasks done!" when subtask 2 silently fell through to a default, or a test that just re-encodes the current return value with no link to the business rule.
- ✅ "2 of 3 done. Subtask 2 hit Y — need your call on Z before continuing." / `assert sale_price == cost * (1 + REQUIRED_MARGIN)` instead of `assert sale_price == 13.75`.

# Build & run

Requires Zig `0.16.0`, the Windows SDK shader compilers (`fxc.exe` for SM5/DXBC and `dxc.exe` with `dxil.dll` beside it for signed SM6/DXIL), and the LunarG Vulkan SDK (`dxc.exe`, `spirv-cross.exe`, `glslangValidator.exe`, and `spirv-val.exe` for SPIR-V). The two DXC installs are not interchangeable: the Vulkan SDK one emits SPIR-V but ships no `dxil.dll`, and D3D12 rejects unsigned DXIL. Those shader/SDK tools are required only for the Windows build; the macOS target links Apple frameworks instead and does not discover or depend on them. Dependencies are declared in `build.zig.zon`; `win32` is marked `lazy = true`. The build discovers the newest installed SDK versions from their standard locations or the `WindowsSdkVerBinPath` / `VULKAN_SDK` environment variables; use `-Dfxc-path=<path>`, `-Ddxil-dxc-path=<path>`, `-Ddxc-path=<path>`, `-Dspirv-cross-path=<path>`, `-Dglslang-validator-path=<path>`, or `-Dspirv-val-path=<path>` to override discovery.

- `zig build` — build the `Mostty` executable into `zig-out/bin/`.
- `zig build run -- [args]` — build and run; everything after `--` is forwarded as cmdline args (see `src/Cmdline.zig`: `--ttf <path>`, `--font-size <float>`).
- `zig build test` — run the unit test step (compiles the same root file as the exe; there are very few tests today).
- `zig build -Doptimize=ReleaseSmall` — what the README's "less than 2 MB" Windows binary refers to.

On a macOS host, `zig build` assembles a launchable `Mostty.app` into `zig-out/` (requires `swiftc` and the Apple SDK); `zig build macos-app` targets just the bundle, `zig build check-macos-session` compiles the PTY session and renderer, and `zig build test-macos-grid` runs the platform-neutral grid tests.

There is no separate lint step. The Windows build requires the MSVC ABI (`build.zig` defaults to it and fails fast on Windows-GNU).

## Platform test languages

These restrictions apply to platform-specific test scripts and their test helpers, including embedded code:

- **macOS:** use only shell, Swift, or AppleScript for tests, including those in `tests/macos/`.
- **Windows:** use only PowerShell for tests.

When migrating an existing test written in another language, preserve its coverage, update its callers, and delete the replaced files.

## Build Command for Developer

- For the Windows build, use `cmd.exe /c "D:\zig-x86_64-windows-0.16.0\zig.exe build --global-cache-dir D:\zig-cache"`.
- Use `D:\zig-cache` as the build cache.
- Invoke non-build commands directly.

# Architecture

**Mandatory: the macOS application must use Swift + AppKit only for its UI and application lifecycle. Do not import, link, or use SwiftUI, including in tests; do not introduce SwiftUI views, hosting wrappers, property wrappers, or scenes.**

Mostty is a terminal emulator that wraps `libghostty-vt` (the VT parser/state machine from Ghostty, imported as the `vt` module) and provides its own windowing + rendering layer. It targets Windows (the primary, fully-featured application) and macOS:

| Target  | Entry point             | Window/IO                           | Rendering                                     |
| ------- | ----------------------- | ----------------------------------- | --------------------------------------------- |
| Windows | `src/mosttywindows.zig` | Win32 message loop + ConPTY per tab | D3D11 (default), D3D12, OpenGL 4.6, or Vulkan |
| macOS   | `src/mosttymacos.zig`   | Swift/AppKit app + PTY per tab over a C-ABI boundary | CoreText rasterization + Metal presentation   |

The backend is picked per process by `--renderer` or `renderer =` in the config; the accepted values are `d3d11`, `d3d12`, `opengl`, `pure-opengl`, `vulkan`, and `native-vulkan` (`Config.RendererBackend`). Everything except D3D11 is an explicit research variant. All of them share one process-lifetime `FontService` (DirectWrite + Direct2D), so text layout and glyph rasterization are backend-independent, and `terminal.hlsl` is the single shader source compiled to DXBC / signed DXIL / SPIR-V.

**`ARCHITECTURE.md`** at the repo root is the single source of truth for everything else: module layout, threading model, startup sequence, message dispatch, ConPTY/VT pipeline, rendering pipeline, render throttle, hot-reload, key data flows, and invariants. Read it before any change that spans more than one module or leans on an invariant. Do not restate its contents here — the summary this section used to carry had drifted into describing a `SendMessage` PTY hand-off and a `VtHandler`/`ReadonlyHandler` pair that no longer exist.

## Temp Dir

Always use **${project_root_dir}/tmp** as the temporary directory, never use **/tmp**.
