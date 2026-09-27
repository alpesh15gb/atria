# Memory Sync

Before compaction or ending a long session:

1. Read `.claude/STATE.md` and `.claude/TODO.md`.
2. Inspect what changed in this session.
3. Run `git status`.
4. Use targeted `git diff` only where useful.
5. Update `.claude/STATE.md` with:
   - current objective
   - implementation state
   - important files
   - blockers
   - recently completed work
   - exact next action
6. Update `.claude/TODO.md`.
7. Add durable decisions to `.claude/DECISIONS.md`.
8. Save detailed debugging/research information under `.claude/memory/`.
9. Optionally create `.claude/memory/sessions/YYYY-MM-DD.md`.
10. Keep memory concise. Do not copy the raw conversation.
11. Do not store secrets.

After this, run `/compact` if continuing the same session.
