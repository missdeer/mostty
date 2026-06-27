---
name: update-vt
description: Update the libghostty-vt (ghostty) dependency to a newer upstream commit. Use when the user asks to bump/update libghostty-vt or the ghostty dependency, compare the pinned commit against upstream, assess impact on mostty, and rebuild. Covers the whole runbook — diff analysis, impact gating against mostty's vt API surface, build.zig.zon update, build + smoke test.
---

# Update libghostty-vt

mostty consumes only the `ghostty-vt` module of the `ghostty` dependency. That
module is the upstream repo's `src/terminal/` tree. Everything outside
`src/terminal/` (macOS, GTK, libghostty C-ABI, renderer, etc.) is irrelevant to
mostty even though it lives in the same repo and shows up in the commit range.

The dependency is pinned in `build.zig.zon` under `.ghostty` (`url` = git commit,
`hash` = Zig package hash).

## Goal

Bump `.ghostty` from the current pinned commit to a newer one (default: upstream
`main` HEAD), **only after** confirming the change set doesn't break mostty's
actual `vt` API usage. Produce a `PLAN.md`, update the dep, build, smoke test.

## Environment gotchas (this repo / this harness)

- `cmd.exe` is **not** on PATH in the bash tool. Ignore AGENTS.md's
  `cmd.exe /c "..."` build wrapper here and call the zig exe directly:
  `"D:/zig-x86_64-windows-0.15.2/zig.exe" build --global-cache-dir D:/zig-cache`
- Setting `.hash = ""` in `build.zig.zon` makes `zig build` **panic** ("Bad
  @dependencies source") instead of printing the expected hash. Do **not** blank
  the hash. Use `zig fetch --save` (below), which computes and writes it.
- `gh api ... --jq` chokes on `\.` in regexes ("invalid escape sequence"). Use a
  character class `[.]` instead, e.g. `test("terminal/(Terminal|Screen)[.]zig")`.
- Use `${project_root}/tmp` for any scratch files, never `/tmp`.

## Steps

### 1. Identify current and target commits

```bash
# Current pinned commit: read `.ghostty.url` in build.zig.zon (the part after '#').
# Latest upstream HEAD + its date:
gh api repos/ghostty-org/ghostty/commits/main --jq '.sha + " " + .commit.committer.date'
# Date of the currently pinned commit (sanity-check the gap):
gh api repos/ghostty-org/ghostty/commits/<CURRENT_SHA> --jq '.commit.committer.date'
```

If the user named a specific target commit, use that instead of `main` HEAD.

### 2. Diff, scoped to the vt module

Only `src/terminal/` matters. Get per-file stats:

```bash
gh api repos/ghostty-org/ghostty/compare/<CURRENT>...<TARGET> \
  --jq '.files[] | select(.filename | test("src/terminal/")) | "\(.status)\t+\(.additions)\t-\(.deletions)\t\(.filename)"'
```

Pull patches for the files that define mostty's API surface (see step 3):

```bash
gh api repos/ghostty-org/ghostty/compare/<CURRENT>...<TARGET> \
  --jq '.files[] | select(.filename | test("terminal/(Terminal|Screen|PageList|stream_terminal|main|lib)[.]zig")) | "=== \(.filename) ===\n" + .patch'
```

Also confirm the build wiring didn't change in a way that affects the module:

```bash
# ghostty's own build.zig changing would mean the ghostty-vt module definition
# changed (new deps / C sources). build.zig.zon-only changes are usually just
# lazy theme-pack hashes, irrelevant to vt.
gh api repos/ghostty-org/ghostty/compare/<CURRENT>...<TARGET> \
  --jq '.files[] | select(.filename | test("^build[.]zig$|^src/simd")) | .filename'
```

### 3. Impact-gate against mostty's real vt usage

Enumerate what mostty actually touches, then check each changed export against it:

```bash
# rg, not grep (repo Rule 0). Scope to source only.
```
Grep `src/**/*.zig` for `\bvt\.[A-Za-z_][A-Za-z0-9_.]*`.

As of the last update mostty used: `vt.Terminal` (`.init`, `.flags`),
`vt.TerminalStream.Handler` + `.Effects`, `vt.Cell`, `vt.Selection` (`.init`),
`vt.Pin`, `vt.Coordinate`, `vt.Style.Color`, `vt.color.*`, `vt.Stream` /
`vt.ReadonlyHandler`. Re-derive this list each run — don't trust this snapshot.

Classify every non-trivial change as one of:

- **Additive** — new field with a default, new method, new export. Safe.
  - Critical pattern: mostty builds `Effects` as
    `var e: vt.TerminalStream.Handler.Effects = .readonly; e.foo = ...;`
    (see `src/win32/tab_mgmt.zig`). A new `Effects` field is safe **iff** the
    `.readonly` preset gives it a default. Verify that in the diff.
  - `Terminal.init` takes named options (`.cols/.rows/.default_modes`); a new
    `Terminal` struct field with a default does not break it.
- **Bug fix** — e.g. resize/saturation fixes in `PageList.zig`, pin-leak fixes
  in `Screen.select`. Usually a net win for mostty (resize, selection).
- **Potentially breaking** — signature change, removed/renamed export, an enum
  tag that gained a payload (e.g. `SemanticClick.click_events`). For each, `rg`
  the mostty tree for the symbol. If unreferenced, it's a non-issue; record that.

Stop and surface to the user if any breaking change is actually referenced by
mostty — don't paper over it.

### 4. Write PLAN.md

Record: version delta (commit+date), scoped file-stat table, per-item impact
verdict tied to the API list, build/smoke steps, success criteria. `PLAN.md` at
repo root is an untracked scratch doc — overwriting a stale/DONE plan is fine,
but say so.

### 5. Update the dependency

Do **not** hand-edit the hash. Let zig fetch compute it:

```bash
"D:/zig-x86_64-windows-0.15.2/zig.exe" fetch --global-cache-dir D:/zig-cache \
  --save=ghostty "git+https://github.com/ghostty-org/ghostty#<TARGET>"
```

This rewrites `.ghostty.url` and `.ghostty.hash` in `build.zig.zon`. A
`overwriting existing dependency named 'ghostty'` warning is expected.

### 6. Build + smoke test

```bash
"D:/zig-x86_64-windows-0.15.2/zig.exe" build --global-cache-dir D:/zig-cache
```

Clean build (no output) = pass. Then verify the binary is fresh and starts:

```bash
ls -la --time-style=+%H:%M:%S zig-out/bin/Mostty.exe
( ./zig-out/bin/Mostty.exe & MPID=$!; sleep 4; \
  if kill -0 $MPID 2>/dev/null; then echo "RUNNING ok"; kill $MPID; \
  else wait $MPID; echo "EXITED early code=$?"; fi )
```

Mostty is a GUI Win32 app: a headless launch only proves it reaches the message
loop (D3D11 device created, config loaded, no early crash). Pre-existing
warnings like missing `background-image` or `unimplemented mode: 9001` are not
regressions. Tell the user that full interactive regression (resize, multi-tab,
selection) needs a manual pass.

## Success criteria

- `build.zig.zon` `.ghostty` points at the target commit with a valid hash.
- Every changed vt export is classified; nothing breaking is referenced by
  mostty (or the user has been told about it).
- `zig build` is clean and `Mostty.exe` starts without crashing.
- `PLAN.md` reflects the actual delta and verdict.

## Rollback

`git checkout build.zig.zon` restores the previous pin; rebuild to revert.
