---
description: Pick up from NEXT.md and keep going without asking questions
---

Continue the work from the saved state.

1. Read GOAL.md (if any), STATE.md and NEXT.md from your state directory (the SessionStart context names it: the repo's `.agent/`, or `~/.agent/sessions/<session id>/`). If they are missing, say so in one line and use `git log -5` and `git status` to reconstruct where things stand, then write STATE.md and NEXT.md.
2. Check NEXT.md against reality: if the branch, commits or files it mentions have moved, correct it first and log the correction under Decisions.
3. Do the "Do now" step. When ambiguous decide by: existing repo convention, then the simplest option, then the most reversible. Log each assumption under "Assumptions made" and each decision under "Decisions". Fetch missing information yourself (docs, grep, run the command) before ever asking.
4. When that step is done and verified, update STATE.md, rewrite NEXT.md for the step after it (use /handoff), and continue with that step unless you are blocked. If blocked, set `status: blocked`, list the blocker, and stop.
5. Respect any guard denial: it names what to do instead.
