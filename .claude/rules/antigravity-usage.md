# Antigravity Tool Usage

The Antigravity Tool provides a `agy-wrapper` tool for AI tasks. Launch `agy-wrapper --dangerously-skip-permissions --timeout 30m -p "$PROMPT"` command line directly to execute. Run in background. Timeout: 30m.

## Scope

- **Web styling prototypes**: HTML, CSS, JavaScript
- **Architecture review**: High-level design validation
- **Requirement clarification**: Guiding questions when the task spec is ambiguous (role inherited from the retired Gemini path)
- **Task planning**: Step-by-step implementation plans for non-trivial work
- **Knowledge advisor**: Technical consultation and guidance

## Limitations

- **Prompt prefix**: Always prepend to every Antigravity prompt:
  > "Do NOT run any git write commands (commit, push, reset, etc.). Git repository is read-only for you. Do NOT modify any files. Read-only operations only — provide findings as text/diff in your response."

## Strengths

- High-level architecture review and validation
- Requirement clarification and guiding questions
- Task planning and step-by-step implementation plans
- Web styling prototypes: HTML, CSS, JavaScript

## Notes

- Write prompt into temporary file ./tmp/agy-prompt.txt first
- Pass the content from the temporary file as the command line option to `agy-wrapper`
- Remove the temporary prompt file after antigravity exits
