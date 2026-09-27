# Install

Copy this kit into the root of your project.

Expected structure:

```text
your-project/
├── CLAUDE.md
├── FRESH_SESSION_RECOVERY.md
├── PRE_COMPACT.md
├── SAFE_SHELL_GUIDE.md
└── .claude/
    ├── STATE.md
    ├── TODO.md
    ├── DECISIONS.md
    ├── commands/
    │   ├── memory-sync.md
    │   └── recover-fresh.md
    └── memory/
        ├── architecture.md
        ├── bugs.md
        ├── research.md
        └── sessions/
```

If you already have `CLAUDE.md`, merge these rules into it rather than overwriting your existing project-specific instructions.

## Normal workflow

Before the session becomes very large:

1. Use `PRE_COMPACT.md`.
2. Run `/compact`.

For important work, keep `.claude/STATE.md` and `.claude/TODO.md` updated continuously.

## If you already hit the 128k error

Try `/compact` once.

If it also fails:

1. Exit Claude Code.
2. Start a new session with `claude`.
3. Do not use `--continue` or resume the oversized session.
4. Paste `FRESH_SESSION_RECOVERY.md`.
5. Continue from filesystem state.
