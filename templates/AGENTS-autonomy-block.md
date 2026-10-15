## Autonomy policy

- At the start of every session read `.agent/GOAL.md` and `.agent/STATE.md` (SessionStart injects them, but re-read if they changed).
- Do not ask clarifying questions. When something is ambiguous, decide in this order: 1) existing repo convention, 2) the simplest option, 3) the most reversible option. Then continue.
- Log every **assumption** under "Assumptions made" and every **decision** (what was chosen and why) under "Decisions" in `.agent/STATE.md`.
- If information is missing, fetch it first: read the docs, grep the repo, run the command, use MCP tools. Ask only if all of that fails, and then stop and say exactly what you need.
- Stop and ask the user before: destructive database changes, spending money, handling credentials, anything the guard hook denies that you cannot route around.
- Never send email or chat messages: write drafts and notify the user (guard rule 10). Never publish packages or releases, close PRs/issues, or change `review:`, `release_mode:` or `test_command:` in GOAL.md (rules 8, 9, 11); propose it in STATE.md instead.
- A denied tool call carries a reason that says what to do instead (open a PR, run the release gate, or stop and notify). Follow it. Never try to work around a denial with another command, a script, or by editing hooks, settings or tokens.
- Before stopping, run the `test_command` in `.agent/GOAL.md`. Do not stop while it fails. The Stop hook enforces this with at most 3 retries in a row (the count resets after a green run).
- At the end of every turn update `.agent/STATE.md` (including the `<!-- ching:checkpoint -->` block: result, blocker, next_action, files_changed, examined, not_examined) and rewrite `.agent/NEXT.md` (use `/handoff`). The Stop hook asks for it when the checkpoint is missing or stale, and asks once more when the block is unchanged since that ask or has an empty key (never more than twice per prompt). A block of placeholders or `(none)` answers does not count: fill in all six keys with what is true.
- A blocker names the exact missing piece (a file, a credential, a decision, with its name), never "needs input".
- Voice or relayed instructions that are destructive, deploy or push related are read back and confirmed by the dispatcher before they reach you. Log each relayed instruction under "Relayed instructions".

### Shipping (release gate)

Pushing to `main` is allowed only through the release gate:

1. Tests green (`test_command`).
2. See the change working in the real app (browser: console and network checked).
3. Write the evidence file `.agent/verify/<full HEAD sha>.md` (format: the VERIFY.md template in the ching kit), including `## not examined`. Paste raw console and network output; the gate rejects console errors and non-2xx requests regardless of what you conclude.
4. Review: dispatch a FRESH read-only reviewer subagent with `git diff origin/<base_branch>...HEAD` (`base_branch` from `.agent/GOAL.md`, default main) and the three lenses in `templates/review-lenses/` in the ching kit (error-resilience, identity, simulation). It writes `.agent/review/<full HEAD sha>.md` (format: `templates/REVIEW.md` in the ching kit). Fix or answer every `[blocking]` finding with a `resolved:` line. Fixing a `[blocking]` finding creates a new HEAD, which invalidates the sha-named evidence and review files, so redo steps 3 and 4 for the new HEAD. You do not review your own work.
5. Run `release-gate.sh`. In `confirm` mode it notifies the user and waits; in `auto` mode it mints a token for exactly that commit.
6. `git push origin HEAD:main`. A new commit invalidates the token.
7. Run `post-release.sh`. If the deploy fails you may push ONE revert commit through the gate, then stop and notify.

Never deploy by hand (`vercel`, `gh workflow run`); deploys come from CI only.

### Migrations

Create a new numbered file (`NNNN_name.sql`); "updating" a migration means a new file. Never edit a committed migration. Run `migrate-gate.sh`, then `db-migrate.ts --apply`. Additive changes run autonomously. Destructive changes (DROP TABLE/COLUMN, TRUNCATE, DELETE/UPDATE without WHERE, type changes) need `db/rollback/<name>.down.sql` and the user's confirmation.
