# Global Codex Guidance

## Interaction Preferences

- Do not use `request_user_input` or any multiple-choice Q/A selection box with this user.
- If clarification is truly blocking, ask one concise plain-text question in chat.
- Otherwise make a reasonable assumption, state it briefly, and continue working.

## Test-First Reliability

- When designing a feature of non-trivial difficulty, first brainstorm a foolproof verification path that would be hard or impossible to spoof. Build that test or probe early enough that it can guide the implementation instead of merely rubber-stamping it afterward.
- Before implementing, brainstorm what the change could realistically affect, then use that list to choose the right tests.
- Verify the real way the user or downstream agent will experience the change, not just the nearest convenient check.
