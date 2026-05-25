# Codex Tool Usage

The Codex Tool provides a `codex` tool for **debugging, complex problem solving, and code review**. Use ccgo to ask codex to execute commands. Timeout: 15m.

## Role

- Advisory only, not primary implementer
- Consult for difficult/complex problems across all technologies
- **Primary code reviewer** in Phase 5 audit loop
- Output is reference, Claude Code makes final implementation

## Rules

- Request unified diff patches only
- **Prompt prefix**: Always prepend to every Codex prompt:
  > "Execute directly without asking for confirmation. Do not repeat or echo the request back."

## Strengths

- Debugging and issue localization in complex codebases
- Algorithm optimization and complex logic analysis
- Code review and edge case identification
