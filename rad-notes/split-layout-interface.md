# Shared native pane layout

`src/SplitLayout.zig` owns the split tree and focus for one tab. It has no
dependency on Win32, AppKit, a renderer, a PTY or libghostty-vt. Windows calls it
directly; the macOS task (MOSTTY-75) can wrap the same methods in a thin C ABI.
The native adapters own sessions and views, keyed by `PaneId`, and must never
recreate them just because geometry or visibility changed.

## Ownership and identity

Construct with `SplitLayout.init(allocator, first_id)` and destroy exactly once
with `deinit`. The model owns its tree allocations; the host owns sessions and
views. All calls run on the UI thread. A C bridge should own an opaque layout
handle and translate errors without exposing Zig pointers to tree nodes.

`PaneId` and `SplitId` are `u32`. Zero is not a valid pane ID. The host supplies
strictly increasing pane IDs, including across closes; Windows should allocate
them across the entire window so asynchronous session messages are unambiguous.
The model generates never-reused split IDs. A divider capture retains its
`SplitId`; `drag` returns false after that split has collapsed. IDs are not
array indices or native window addresses.

`split(target, new_id, axis)` preserves the original pane on the left/top and
places the new pane on the right/bottom, selects it, and exits maximization.
Both children start at an equal ratio, constrained by minimum sizes. Failed
splits leave the model unchanged, including on allocation failure. Splitting
while maximized tests the pane's underlying restored region, not the expanded
view. The host should call `canSplit` before creating a session/view, then call
`split` to publish its identity only after that session exists; the latter
rechecks geometry and may still fail, in which case the host destroys its
unpublished session. This keeps callbacks from observing a focused ID without
an owning session, and preserves focus/maximization on failure.

`close(id)` removes only that leaf and collapses its parent into the sibling.
Closing the focused pane selects the first leaf of the surviving sibling and
exits maximization. Closing another pane preserves focus; one remaining pane
always exits maximization. Closing the last pane leaves an empty model, with
`count == 0` and `active == null`; the host then closes the tab and destroys the
model. Closing a whole tab or window is a host operation over all its sessions.

## Geometry and interaction

Call `setBounds(rect, leaf_minimum, divider_width)` after size, font or scale
changes. `Rect` and `Size` use `f64` fields and C-compatible struct layouts;
coordinates and minimum sizes must use the same host unit (pixels on Windows,
points or backing pixels chosen consistently on macOS). Invalid non-finite
geometry, negative extents/gaps and non-positive minima are rejected.

`minimumSize()` includes all nested minima and divider widths. Use it to
constrain interactive host resizing. Forced smaller bounds still partition
without negative rectangles; the saved ratios survive and are restored when
space returns. Native adapters should round rectangle edges, deriving the
width/height from those rounded edges, to avoid gaps or overlap from independent
rounding. Each adapter subtracts its own terminal padding and scrollbar before
computing and applying that pane's VT/PTY dimensions.

`paneRect(id)` returns visible geometry or null for a hidden/unknown pane.
`writePanes(output)` emits visible panes in tree order and returns the required
count, even for an empty or undersized output buffer. `count` includes hidden
panes. Keep the session/view map independent of this visible snapshot: switching
tabs and maximizing hide views, not sessions.

`hitDivider(x, y)` returns a split identity, axis and divider rectangle.
`drag(id, position)` takes the divider's leading edge on that axis and clamps
against both subtrees' minima. Hosts retain the pointer-to-divider offset for
the duration of native mouse capture. Dragging never changes focus.

`focus(id)` selects an existing pane. `focusDirection(direction)` chooses the
nearest pane sharing a perpendicular span; ties prefer the nearest center,
then tree order. There is no wrapping at an outer edge. Directional navigation
while maximized uses the saved tree and displays the newly focused pane.
`toggleMaximize()` changes visibility without changing the tree or ratios.

The explicit enum values are `Axis.columns = 0`, `Axis.rows = 1`, and
`Direction.left/right/up/down = 0/1/2/3`. A C bridge must validate integer enum
inputs before conversion and use the same model methods for all decisions.

## Verification

`zig build test-layout` is included in `zig build test`. It covers four mixed
panes, directional focus, subtree minimum clamping, forced-small geometry,
ratio restoration, maximize/focus restoration, close collapse, stale divider
IDs, failed operations, pane ID reuse and allocation rollback. Cross-compiling
this test target verifies portability; it does not replace platform runtime
acceptance.
