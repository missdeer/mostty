# Test inventory

Use Zig **0.16.0**. Run commands from the repository root. Logs distinguish
`pass`, `fail`, `blocked`, `skipped`, and `compile-only`; a green build does not
claim that blocked hardware scenarios passed. Zig summaries retain individual
skipped counts (for example the macOS-only config-path test on other hosts).

| Suite | Entry point | CI / requirements |
| --- | --- | --- |
| Shared layout | `zig build test-layout -Dcore-only` | Linux, Windows, macOS |
| Shared terminal/session/images | `zig build test-core -Dcore-only` | Linux, Windows, macOS |
| Grid, input, config, paste, selection, rendering helpers, write queue | `zig build test-macos-grid -Dcore-only` | Linux, Windows, macOS; no Apple frameworks |
| All host unit suites | `zig build test --summary all` | Both native build workflows; Windows executes all 12 build configurations |
| Cross-platform semantic analysis | `zig build check-macos-session -Dtarget=aarch64-macos` or `x86_64-macos` | Compile-only on Linux; never a native test pass |
| Bundled themes | `swift tests/macos/bundle-themes.swift zig-out/Mostty.app` | macOS inventory |
| Title notification / refresh / accessibility | `bash tests/macos/interactions.sh --titles-only` | macOS AppKit; no Metal, GUI session or pointer injection requirement |
| Native panes / real PTY / Metal | `zig build test-macos-panes` | macOS desktop + Metal |
| Pane configuration reload | `zig build test-macos-pane-config` | Same; temporarily changes and restores user config |
| Clipboard | `bash tests/macos/clipboard.sh` | macOS desktop; restores clipboard |
| Interactions | `bash tests/macos/interactions.sh` | macOS desktop + pointer injection permission |
| Scrollbar | `bash tests/macos/scrollbar.sh` | macOS desktop + Metal + existing pointer injection permission; exercises native tracking with real system events |
| Shader scalar contracts | `pwsh -File tools/shader-contract-tests.ps1` | Windows inventory; also runnable with PowerShell on Linux; offline math, not GPU execution |
| Chrome resource separation | `pwsh -File tools/chrome-resource-contract-tests.ps1` | Windows inventory; also runnable on Linux; source contracts, not GPU execution. Native resource assertions run in Windows unit tests |
| Acceptance summary contract | `pwsh -File tools/pane-matrix-summary-test.ps1` | Windows inventory; requires jq; also runnable on Linux |
| Vulkan report/recovery contract | `pwsh -File tools/vulkan-acceptance.ps1 self-test` | Windows inventory |
| CI baseline result contract | `pwsh -File tools/ci-result-test.ps1` | Windows inventory; validates pass/fail/blocked mappings and rejects missing/mismatched evidence |
| First launcher failure | `pwsh -File tools/startup-failure.ps1` | Windows GUI inventory |
| D3D11 pane acceptance | `pwsh -File tools/pane-acceptance.ps1` | Windows GUI; invoked by matrix |
| Research backend acceptance | `pwsh -File tools/pane-backend-acceptance.ps1 -Renderer <backend>` | Windows GUI + matching drivers; invoked for all five variants by matrix |
| Six backend matrix | `pwsh -File tools/pane-matrix-acceptance.ps1` | Windows GUI, shader SDKs, jq, Python for existing probe helpers; `-Zig` overrides executable, `-SkipBuild` reuses built binary |
| Tab bar | `pwsh -File tools/tabbar-acceptance.ps1` | Windows GUI inventory |
| D3D11 close/redraw | `pwsh -File tools/d3d11-close-redraw.ps1` | Windows GUI inventory; captures real screen pixels |
| Vulkan / GL / D3D11 local acceptance | `pwsh -File tools/vulkan-acceptance.ps1 run -Session local -Renderer <backend>` | Windows GUI inventory |
| RDP and session recovery | `vulkan-acceptance.ps1 recovery-start`, `recovery-complete`, `report` | Dedicated operator-controlled RDP/session transition; blocked on hosted CI |
| Font/emoji/URL reference files | `tests/*.txt` | Manual visual fixtures, not executable tests |

`tests/macos/ci.sh` runs every macOS entry above and writes
`tmp/ci-macos/results.tsv` plus individual logs. Read-only probes mark missing
GUI/Metal or pointer permission as **blocked**. They do not modify TCC.
Unavailable GUI suites are still compiled, with separate **compile-only** rows;
the three shell entry points also accept `--compile-only` for this purpose.

`tools/ci-tests.ps1` runs non-GUI Windows contracts and records GUI requirements
as **blocked**. `-Gui` runs the full local GUI inventory serially. To use it in
Actions, set repository variable `MOSTTY_WINDOWS_GUI_RUNNER` to the label of an
**existing**, appropriately configured interactive runner and dispatch Windows
build with `gui=true`. No runner or permissions are provisioned by this workflow.
Use an isolated runner profile: existing acceptance scripts temporarily change
config, clipboard, window placement and pointer state. Existing legacy probe
helpers remain Python/C#; new Windows tests are PowerShell only.

Both workflows upload `tmp/` test evidence even on failure. The six-backend
matrix stores executable SHA256, source commit, helper hashes and per-case
status. Matrix wrappers invoke both pane acceptance entry points; they are not
separate duplicate runs. Backend unsupported/partial results are never counted
as a complete matrix pass.

Still requires dedicated validation: Intel/AMD Metal, pre-24H2 system ConPTY
(without bundled ConPTY), real device removal, RDP reconnect/session-switch,
and physical mixed-DPI monitors. Native pipe tests verify the drain/cancel
algorithms, not the old operating system implementation. Queue tests verify
ordered partial writes and cancellation; full GUI responsiveness under a large
paste must also be observed on the dedicated platforms.

`tools/rdp-h264-policy.ps1` is an administrator policy utility, **not a test**.
It is intentionally absent from all test runners and must not be executed by CI.
