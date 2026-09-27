# Fresh Session Recovery

Use this when the previous Claude session hit the 128k context limit.

1. Start Claude Code with:
   `claude`

2. Do NOT use:
   - `claude -c`
   - `claude --continue`
   - resume of the oversized session

3. Read:
   - `CLAUDE.md`
   - `.claude/STATE.md`
   - `.claude/TODO.md`

4. Run:
   - `git status`

5. Read `.claude/DECISIONS.md` only if relevant.

6. Inspect only the source files related to the exact next action.

7. Search `.claude/memory/` only if additional historical detail is needed.

8. Continue from filesystem state rather than conversation history.
