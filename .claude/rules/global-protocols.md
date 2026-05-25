# Global Protocols

Strict system constraints for all actions.

## Language
- **Tool/model interaction**: English
- **User-facing responses**: Chinese

## Multi-turn Conversations
If a tool returns `SESSION_ID`, record it and decide whether to continue the conversation in subsequent calls. Codex/Gemini sessions may be interrupted; continue the same session if needed response was not received.

## Sandbox Safety
Codex/Gemini must never write to the filesystem. Request `unified diff patch` output only.

## Code Sovereignty
External model output is only logical reference. Final code **must be refactored** to remove redundancy and meet production standards.

## Style Definition
Minimal, efficient, no redundancy. Follow **no comments/docs unless necessary**.

## Scope Discipline
Only make requirement-scoped changes. Do not impact unrelated existing functionality.
