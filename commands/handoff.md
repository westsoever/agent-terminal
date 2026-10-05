---
description: Write the session handoff (STATE.md + a self-contained NEXT.md) so any fresh session can continue
---

Write the handoff for this session. Work from facts (git log, git status, test output), not memory.

1. Find your state directory. It was named in the SessionStart context ("state in <dir>"): the repo's `.agent/` when the repo has a `.agent/GOAL.md`, otherwise `~/.agent/sessions/<session id>/`. Create it if missing.
2. Update `STATE.md` there. Keep the `status:` line (idle | working | blocked | done) and the sections Done, In progress, Blocked, Decisions, Assumptions made, Releases, Relayed instructions, Recommended next step. Move finished items to Done, list real blockers under Blocked (one bullet each, with what you need), record every decision with its reason and every assumption you made. Leave the automatic `ching:snapshot` block alone.
3. Rewrite `NEXT.md` as a prompt that is complete on its own, so it can be pasted into a brand-new session with no other context: goal in one line, where things stand (branch, last commit, what is done), the single next concrete step with file paths, constraints (the Autonomy policy: do not ask, decide and log), and a done-check (the repo's test command if there is one).
4. If a repo `.agent/GOAL.md` exists, run its `test_command` and put the result in STATE.md.
5. Reply with at most five lines: status, what is blocked (if anything), and the first line of NEXT.md.

Do not ask questions. Do not commit these files (they are not part of the repo).
