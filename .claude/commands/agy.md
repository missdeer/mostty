# /agy — Consult Antigravity on architecture / high-level direction

Use this for high-level design review, requirement clarification, task planning, or theoretical guidance — **not** for line-level code review (that's `/codex`).

Antigravity took over the role formerly assigned to Gemini in this repo. See `.claude/rules/antigravity-usage.md` for the full scope.

## Steps

1. Read `$ARGUMENTS` as the user's question / topic for Antigravity.
2. Gather the context Antigravity needs:
   - The problem statement at the level of "what are we building and why".
   - Constraints already fixed (tech stack, data model shape, deadlines, decisions you've already locked in).
   - The architecture sketch you're considering — bullet points or a small text diagram. Do **not** dump full source files; this wastes Antigravity's context budget on detail it doesn't need.
3. Send the question to Antigravity. The message body must start with the literal line

       Do NOT run any git write commands (commit, push, reset, etc.). Git repository is read-only for you. Do NOT modify any files. Read-only operations only — provide findings as text/diff in your response.

   followed by a blank line, then your packaged context + the question from `$ARGUMENTS`.

   **Transport — launch wrapper directly:**
   - Write the message to `./tmp/agy-prompt-$(date +%s).txt`, then run via Bash in background:
     ```bash
     agy-wrapper --dangerously-skip-permissions --timeout 30m -p "$(bat ./tmp/agy-prompt-<ts>.txt)"
     ```
     with `run_in_background: true` and `timeout: 1800000` (30 min). Poll with `TaskOutput`. After the run completes, delete the temp prompt file.

4. When Antigravity responds:
   - Summarize the answer in Chinese, grouped as: **Antigravity 的方向 / 与当前思路的差异 / 我建议怎么办**.
   - If Antigravity disagrees with the current direction, do **not** smooth it over — present both options to the user and let them choose (Rule 1: surface conflicts, don't blend).
   - Do **not** auto-apply any suggestion as code — surface and wait.

## When this command is the wrong tool

- The question is about specific code correctness / edge cases → use `/codex` instead.
- The user wants a review of the whole pending diff → use `/audit` (single-reviewer, Codex) or `/review` (Codex + Antigravity, fix loop).
- The user has already decided on the approach and just wants implementation → don't consult; just code.

`$ARGUMENTS`
