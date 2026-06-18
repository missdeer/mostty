# /codex — Consult Codex on a specific question

Use this to get Codex's deep-technical / edge-case opinion on something concrete in the current task.

## Steps

1. Read `$ARGUMENTS` as the user's question / topic for Codex.
2. Gather the minimum self-contained context Codex needs to answer:
   - The task goal (1–2 sentences from the current conversation).
   - Relevant code: paste the exact function(s) / diff hunk(s) being discussed, not whole files. If a recent uncommitted change is relevant, include `git diff` for those files only.
   - Any constraint the user has already stated (chosen library, schema, deadline, etc.).
3. Send the question to Codex. The message body must start with the literal line

       Execute directly without asking for confirmation. Do not repeat or echo the request back.

   followed by a blank line, then your packaged context + the question from `$ARGUMENTS`.

   **Transport — detect, don't blend:**
   - **If `mcp__ccgo__ask_agents` is in your available-tools list** → call it with `agent: "codex"` and the message above.
   - **Else (MCP not installed on this machine)** → write the message to `./tmp/codex-prompt-$(date +%s).txt`, then run via Bash in background:
     ```bash
     codex exec -s read-only --skip-git-repo-check --full-auto "$(cat ./tmp/codex-prompt-<ts>.txt)"
     ```
     with `run_in_background: true` and `timeout: 1800000` (30 min). Poll with `TaskOutput`. After the run completes, delete the temp prompt file.
   - **Never silently skip** consultation because MCP is missing — the CLI fallback is a first-class path.
4. When Codex responds:
   - Summarize the answer in Chinese, grouped as: **结论 / 关键理由 / 你需要决定的点**.
   - Do **not** auto-apply any fix Codex suggests — surface it and wait for the user.
   - If Codex flagged something that contradicts a decision already made in this conversation, say so explicitly (Rule 1: surface conflicts, don't blend).

## When this command is the wrong tool

- The question is purely architectural / high-level → use `/gemini` instead.
- The user wants a review of the whole pending diff → use `/audit` instead.
- The question is trivial (one-liner you can answer from `rg` in 10 seconds) → just answer it.

`$ARGUMENTS`
