# Phase 1 performance regressions

Baseline: `4651f0374a1eaea227263dd60e81594626bb0280`. The correctness
regressions in [review-regressions.md](review-regressions.md) remain required.
This change removes redundant work; it does not change VT threading, surface
scheduling, PTY drain budgets, pane atlas capacity or image placement semantics.

| Change | Mechanism evidence | Behavior protection |
| --- | --- | --- |
| macOS title deduplication | 1,000 unchanged title polls deliver one notification/refresh; 1,000 equal tab assignments cause zero refreshes | Real Unicode changes, empty-title retention, tooltip/accessibility, explicit font/theme/tab-list refresh; full interactions checks background pane titles and focus switches; existing C-ABI basename tests retained |
| Windows chrome preparation | D3D11 chrome preparation/draw keeps atlas/cache absent across a DPI change while a pane allocates its full atlas and renders cells; D3D12/GL/Vulkan native tests assert separation; PowerShell checks all four preparation paths | FontService and font epochs, tab-band invalidation, surface acquisition and recovery retained; existing GL alpha readback and pane lifecycle assertions retained |
| Image copy elision | Same-size iTerm decode needs only base64 scratch + decoder allocation and returns identical pixel pointer/hash; RGBA conversion borrows with zero allocations | Scaled cleanup assertion retained; channel conversion/alpha, OOM cleanup and malformed decoder bytes checked; macOS native readback verifies its image survives source modification |
| Input rejection precheck | Known full/stopped/failed rejection of a 1 MiB payload performs zero allocations | Existing partial-write/order/cancel tests retained; added node/payload OOM recovery, state/capacity races during unlocked allocation, concurrent producer order and atomic transactions |

The approximate 4096 x 4096 x 4 = 64 MiB atlas saving describes logical
resource size, not measured resident GPU memory. Allocation and call counts
demonstrate the mechanism; Linux execution does not measure native end-to-end
latency or user experience.

RGBA borrowing is limited to the synchronous uploader call on the UI thread.
D3D11 and OpenGL consume CPU pixels within that call. D3D12 and Vulkan copy
them into owned staging before asynchronous GPU submission. macOS retains the
necessary `CFDataCreate` copy for its cached CGImage. These backend copies stay.

The queue precheck is a snapshot under a short mutex. Allocation/copy and
transport I/O remain outside the mutex. Commit rechecks state and pending
capacity; a race after the precheck can still copy and then reject, freeing
both allocations. Concurrent transactions retain the existing commit-lock
linearization order, with per-producer order and whole-paste acceptance.
There is no reservation protocol or new invocation-start ordering guarantee.
The unchanged 64 MiB limit bounds pending bytes including the in-flight write,
not temporary copies made by arbitrarily many concurrent producers.

All tests join the existing aggregates in [README.md](README.md). The new
`titles` macOS inventory row runs without pointer injection or a Metal device.
Native GPU tests retain existing capability skips; offline contracts and
compile-only checks cannot replace actual GPU execution. Full GUI large-paste
responsiveness, Intel/AMD Metal, old system ConPTY, physical device loss,
mixed DPI and RDP/session transitions still need suitable existing hardware.
The administrator RDP policy script is not a test and is not invoked.
