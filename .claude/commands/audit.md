# /audit — Codex review of pending changes

Send the current branch's uncommitted (or branch-vs-master) diff to Codex for a structured review.

## Steps

1. Determine the review scope (a git command, not the diff content). Codex reads the diff itself in step 3 — you do not pull it into the prompt. Here you only pick *which* git command defines the scope:
   - Run `git status` to see scope.
   - If the working tree or index has changes → scope command is `git diff HEAD` (covers staged + unstaged in one shot).
   - If the working tree is clean → scope command is `git diff master...HEAD`; tell the user this is a **branch-vs-master** review, not an uncommitted-changes review.
   - Call the chosen command `<DIFF_CMD>` and substitute it into the message below. No size-trimming needed — the diff never enters the prompt.
2. Parse `$ARGUMENTS` as optional focus instruction (e.g. `只看 SQL`, `重点看错误处理`, `忽略测试文件`). Pass it through to Codex verbatim.
3. Build the message. It must start with the literal line

       Execute directly without asking for confirmation. Do not repeat or echo the request back.

   followed by a blank line, then the request body:

   ```
   Review the pending diff in this repo. First obtain the diff yourself by running (read-only):
     <DIFF_CMD>
   Do not ask me to paste it; run the command and review its output. The repo's coding standards are in CLAUDE.md (Go modernize idioms, surgical changes, minimal abstractions). Check for:
     1. Correctness bugs (off-by-one, nil deref, error swallowing, missing context propagation)
     2. Edge cases the change doesn't handle (empty input, partial failure, concurrent access)
     3. Security issues (SQL injection, command injection, secret leakage)
     4. Backward compatibility breaks (DB schema, public APIs, file formats)
     5. CLAUDE.md / Go-standards violations (legacy CLI use, non-modern Go idioms, unused params)

   Focus instruction from user (may be empty): <ARGS>
   ```

   Codex runs in the repo root (cwd), so `<DIFF_CMD>` resolves there and `git diff` is allowed under the `read-only` sandbox.

   **Transport — detect, don't blend:**
   - **If `mcp__ccgo__ask_agents` is in your available-tools list** → call it with `agent: "codex"` and the message above.
   - **Else (MCP not installed on this machine)** → write the message to `./tmp/audit-prompt-$(date +%s).txt`, then run via Bash in background:
     ```bash
     codex exec -s read-only --skip-git-repo-check "$(bat ./tmp/audit-prompt-<ts>.txt)"
     ```
     with `run_in_background: true` and `timeout: 1800000` (30 min). Poll with `TaskOutput`. After the run completes, delete the temp prompt file.
   - **Never silently skip** the audit because MCP is missing — the CLI fallback is a first-class path.
4. Summarize Codex's findings in Chinese, grouped by severity: **必修 / 建议修 / 吹毛求疵**. For each item, cite the file:line. Do **not** auto-apply fixes — list them and wait for user direction.
5. If Codex returned an empty / "looks good" response, say so plainly. Don't invent issues to look thorough.

`$ARGUMENTS`
