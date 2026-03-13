# Agent Instructions

This project uses **bd** (beads) only if it is explicitly set up and healthy for this repo.
Check first with `./scripts/beads.sh status`.

If `./scripts/beads.sh check` fails, skip Beads and continue with the task. Do not get stuck trying to bootstrap or debug Beads unless the user asked for that specifically.

## Quick Reference

```bash
./scripts/beads.sh status
./scripts/beads.sh run ready
./scripts/beads.sh run show <id>
./scripts/beads.sh run update <id> --status in_progress
./scripts/beads.sh run close <id>
```

## Landing the Plane (Session Completion)

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Only if `./scripts/beads.sh check` succeeds
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
