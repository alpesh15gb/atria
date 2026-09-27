# Claude Code Project Instructions

This project uses filesystem-backed persistent memory.

## Hard model limit

The backend model is `Atria-Dawn-Preview`.

Hard context/input limit: **128,000 tokens**.

Never assume the model can safely use all 128k tokens.

Target normal active context: **80k-95k tokens maximum**.

Leave substantial headroom for:
- tool results
- shell output
- file reads
- system/tool instructions
- the next user message
- model output

If context appears large, save durable state and compact or restart before continuing.

## Persistent memory

Use these files as durable project memory:

- `.claude/STATE.md` — concise current project state
- `.claude/TODO.md` — authoritative task list
- `.claude/DECISIONS.md` — durable architectural/implementation decisions
- `.claude/memory/architecture.md` — architecture details
- `.claude/memory/bugs.md` — debugging discoveries
- `.claude/memory/research.md` — research notes
- `.claude/memory/sessions/` — optional chronological checkpoints

These files may collectively become much larger than 128k tokens.

Never load the entire memory store into context.

Read only relevant files or sections.

## Start or resume

For a fresh Claude Code session:

1. Read `CLAUDE.md`.
2. Read `.claude/STATE.md`.
3. Read `.claude/TODO.md`.
4. Run `git status`.
5. Read `.claude/DECISIONS.md` only if relevant.
6. Inspect source files related to the exact current task.
7. Search `.claude/memory/` only when historical detail is needed.

Do not reload the previous Claude conversation just to recover state.

Prefer a fresh session reconstructed from filesystem state.

## Context discipline

Avoid commands that can dump large amounts of text into context.

Avoid:
- `cat` on large files
- unrestricted recursive grep
- huge test logs
- huge build logs
- large `docker logs`
- `git log -p` over long history
- printing whole JSON/database dumps
- reading entire generated files unnecessarily

Prefer:
- `head`
- `tail`
- targeted `grep`
- `rg` with paths/limits
- specific line ranges
- `git diff --stat`
- `git diff -- path/to/file`
- `git log -10 --oneline`
- focused tests
- quiet test modes
- summarized tool output

Examples:

```bash
tail -n 100 app.log
git diff --stat
git diff -- src/path/file.ts
git log -10 --oneline
rg "error" src/ | head -100
```

When a command may produce large output, constrain it before running.

## STATE.md rules

Keep `.claude/STATE.md` concise.

It should contain:
- current objective
- current implementation state
- important files
- active blockers/issues
- recently completed work
- exact next action
- commands needed to resume

Do not store raw transcripts.

## TODO.md rules

Treat `.claude/TODO.md` as the authoritative durable task list.

Mark completed work.
Add newly discovered work.
Remove stale work.

## DECISIONS.md rules

Record decisions that would be expensive or risky to rediscover:
- architecture
- library/framework choices
- API conventions
- database/schema decisions
- compatibility constraints
- provider/model behavior
- important tradeoffs

Include the reason when useful.

## Before compaction

Before `/compact`:

1. Run the memory sync procedure in `.claude/commands/memory-sync.md`.
2. Update `STATE.md`.
3. Update `TODO.md`.
4. Update `DECISIONS.md` when needed.
5. Save detailed discoveries under `.claude/memory/`.
6. Run `git status`.
7. Inspect `git diff` when useful.
8. Record the exact next action.
9. Then run `/compact`.

Do this early. Do not wait until the request is near 128k.

## If context-window errors begin

If you receive an error like:

`Input exceeds context window ... limit 128000`

Do not continue adding messages or tool output to that session.

Try `/compact` once.

If `/compact` also fails:

1. Exit Claude Code.
2. Start a fresh session with `claude`.
3. Do NOT use `claude -c`, `claude --continue`, or resume the oversized conversation.
4. Run the recovery prompt from `FRESH_SESSION_RECOVERY.md`.
5. Reconstruct state from the filesystem and Git.

## Memory safety

Never store:
- API keys
- passwords
- access tokens
- private credentials

Store environment-variable names or references instead.

## Truthfulness

Do not store guesses as confirmed facts.

Label uncertain items and include how to verify them.
