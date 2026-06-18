# /audit — Codex review of pending changes

Send the current branch's uncommitted (or branch-vs-master) diff to Codex for a structured review.

## Steps

1. Collect the diff:
   - Run `git status` to see scope.
   - Run `git diff` (unstaged) and `git diff --cached` (staged); concatenate.
   - If both are empty, fall back to `git diff master...HEAD` and tell the user this is a **branch-vs-master** review, not an uncommitted-changes review.
   - If the combined diff is larger than ~50KB, prioritize: drop generated files (`*.pb.go`, vendored code, lockfiles), drop pure formatting churn. State what you dropped before calling Codex.
2. Parse `$ARGUMENTS` as optional focus instruction (e.g. `只看 SQL`, `重点看错误处理`, `忽略测试文件`). Pass it through to Codex verbatim.
3. Build the message. It must start with the literal line

       Execute directly without asking for confirmation. Do not repeat or echo the request back.

   followed by a blank line, then the request body:

   ```
   Review the following diff from the e-commercial-agent repo. The repo's coding standards are in CLAUDE.md (Go modernize idioms, surgical changes, minimal abstractions). Check for:
     1. Correctness bugs (off-by-one, nil deref, error swallowing, missing context propagation)
     2. Edge cases the change doesn't handle (empty input, partial failure, concurrent access)
     3. Security issues (SQL injection, command injection, secret leakage)
     4. Backward compatibility breaks (DB schema, public APIs, file formats)
     5. CLAUDE.md / Go-standards violations (legacy CLI use, non-modern Go idioms, unused params)

   Focus instruction from user (may be empty): <ARGS>

   Diff follows:
   <DIFF>
   ```

   **Transport — detect, don't blend:**
   - **If `mcp__ccgo__ask_agents` is in your available-tools list** → call it with `agent: "codex"` and the message above.
   - **Else (MCP not installed on this machine)** → write the message to `./tmp/audit-prompt-$(date +%s).txt`, then run via Bash in background:
     ```bash
     codex exec -s read-only --skip-git-repo-check --full-auto "$(cat ./tmp/audit-prompt-<ts>.txt)"
     ```
     with `run_in_background: true` and `timeout: 1800000` (30 min). Poll with `TaskOutput`. After the run completes, delete the temp prompt file.
   - **Never silently skip** the audit because MCP is missing — the CLI fallback is a first-class path.
4. Summarize Codex's findings in Chinese, grouped by severity: **必修 / 建议修 / 吹毛求疵**. For each item, cite the file:line. Do **not** auto-apply fixes — list them and wait for user direction.
5. If Codex returned an empty / "looks good" response, say so plainly. Don't invent issues to look thorough.

`$ARGUMENTS`
