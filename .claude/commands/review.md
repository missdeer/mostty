# /review — Multi-reviewer ship-readiness loop

Heavyweight quality gate. Runs Codex + Antigravity in parallel on the pending diff, aggregates findings, applies must-fix items, then re-reviews until clean. Use before merging / shipping. For a single-reviewer single-shot opinion, use `/audit` instead.

`$ARGUMENTS` (optional): focus instruction passed through to all reviewers, e.g. `只看 SQL 与并发`.

## Iteration budget

Maximum **3** review→fix rounds. After round 3, stop and report whatever is left to the user — do not loop forever.

## Per-round steps

### 1. Collect the diff

Same procedure as `/audit` step 1 — keep the two commands aligned, don't fork the logic:

- `git status` for scope
- `git diff` + `git diff --cached`, concatenated
- If both empty → `git diff master...HEAD` and label this as **branch-vs-master**
- If combined diff > ~50KB: drop generated files (`*.pb.go`, vendored code, lockfiles, large fixtures), drop pure formatting churn. State what was dropped before sending.

### 2. Build the shared review message

The message body for all three reviewers is identical (the prefix line differs per reviewer). Body:

```
Review the following diff from the e-commercial-agent repo. The repo's coding standards are in CLAUDE.md (Go modernize idioms, surgical changes, minimal abstractions). Check for:
  1. Correctness bugs (off-by-one, nil deref, error swallowing, missing context propagation)
  2. Edge cases the change doesn't handle (empty input, partial failure, concurrent access)
  3. Security issues (SQL injection, command injection, secret leakage)
  4. Backward compatibility breaks (DB schema, public APIs, file formats)
  5. CLAUDE.md / Go-standards violations (legacy CLI use, non-modern Go idioms, unused params)

You are reviewing; do NOT propose code edits — list findings only, each with file:line and a one-sentence rationale. Classify each as must-fix / should-fix / nit.

Focus instruction from user (may be empty): <ARGS>

Diff follows:
<DIFF>
```

### 3. Dispatch the two reviewers **in parallel**

Each reviewer gets the same body, prefixed with its own first line:

| Reviewer | Prefix line | Lens |
|---|---|---|
| Codex | `Execute directly without asking for confirmation. Do not repeat or echo the request back.` | Deep technical, edge cases, line-level correctness |
| Antigravity | `Do NOT run any git write commands (commit, push, reset, etc.). Git repository is read-only for you. Do NOT modify any files. Read-only operations only — provide findings as text/diff in your response.` | High-level architecture, design coherence, alternative angles |

**Transport — detect, don't blend:**

- **If `mcp__ccgo__ask_agents` is in your available-tools list** → single call with both requests in one `requests` array (this is what the parallel-capable wrapper is for).
- **Else (MCP not installed)** → fall back to raw CLI per `.claude/rules/{codex,antigravity}-usage.md`. Write the two messages to `./tmp/review-{codex,agy}-prompt-$(date +%s).txt`, then launch two Bash calls **in parallel** (single message, two `Bash` tool calls with `run_in_background: true`, `timeout: 1800000`):
  - Codex: `codex exec -s read-only --skip-git-repo-check --full-auto "$(cat ./tmp/review-codex-prompt-<ts>.txt)"`
  - Antigravity: `agy-wrapper --dangerously-skip-permissions --timeout 30m -p "$(cat ./tmp/review-agy-prompt-<ts>.txt)"`
  - Poll both with `TaskOutput`. Wait for both to complete before step 4. Delete temp files after.
- **Never silently skip** a reviewer just because its transport is missing — if one CLI (e.g. `agy-wrapper`) is not on PATH, report this to the user and continue with the remaining one; do not pretend the other reviewer agreed.

### 4. Aggregate findings

- Deduplicate: if two reviewers flag the same file:line with the same root cause, merge into one item and credit both.
- Reclassify the merged list as **必修 / 建议修 / 吹毛求疵**. A finding is **必修** only if at least one reviewer marked it must-fix *and* you (Claude) agree it would actually break something. Reviewers can be wrong — surface disagreement rather than rubber-stamping.
- Report the aggregated list to the user in Chinese before fixing anything.

### 5. Fix (only if 必修 > 0)

- Apply only the **必修** items in this round. Leave 建议修 and 吹毛求疵 to the user.
- Make minimal, surgical edits per CLAUDE.md Rule 2 — do not rewrite surrounding code while fixing.
- After fixes: increment round counter, loop back to step 1.

### 6. Exit conditions

Stop and report to the user when **any** of these is true:
- Round 3 completed (regardless of remaining 必修)
- 必修 = 0 after aggregation
- Reviewers' 必修 findings are all judged invalid by you (with reasoning) — do not loop on disagreement

Final report format (Chinese):
- 跑了几轮、每轮各 reviewer 找到什么
- 已修：列出每个必修项及其修法
- 未修：剩余的 建议修 / 吹毛求疵 / 你认为无效的必修，附理由
- 用户需要决定的点

`$ARGUMENTS`
