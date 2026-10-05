# Open items after the 15:00 session limit (2026-10-05)

Source: the Claude Code transcripts under `~/.claude/projects/`. Session limit hit at 15:11 (bbqos vault) and 15:19 (Ching planning), Copenhagen time. Resets 16:40.

Nothing was lost. Everything below is work that stopped waiting for a step.

## 1. miso company budget (migration 0068)

- Migration `0068_company_budget.sql` is committed in the worktree `/Users/clyde/bbq/.worktrees/miso-company-budget`, branch `company-budget`. Rollback file and test (7 pass) are there too.
- Dry run on 2026-10-05 (evening): 66 applied, 1 pending (0068), 0 edited, 0 missing. The migration is additive: new tables and `app.budget_import`.
- **Not applied.** `guard.sh` denies `--apply` without a token from `migrate-gate.sh`, and also blocks the agent from running that script. Run it yourself.
- The ibtikar workspace change (budget view) is committed locally in `~/.miso`, not pushed. It must go out only after 0068 is applied, because pushing auto-deploys and Approve fails until the tables exist.
- Open decision: `send-audience-0067` is unmerged. If it merges after 0068 is applied, 0067 applies out of order. Check with its owner, or hold 0068 until 0067 is in.
- After apply: upload the real workbook on the hosted app, check the totals, push the view to `main`. `~/.miso` main is ahead 2, behind 7, so pull first.

## 2. bbqos vault sync

- Your last message, "pull merge to origin/main without deleting any progress", never ran. `main` is ahead 9, behind 1.
- `00-Inbox/2026-10-05-way-forward-options.md` is saved but untracked.
- `tasks-db` shows 17 active projects with about 95 open items. Time-sensitive: `novolytics` (NNF window closing, nothing since 2026-09-18). Approval gates: `org-briefs` (27), `invitation-engine` (16), `contacts-consolidation` (6).

## 3. CVR company lookup

- First 100 Danish-marker names done: 76 found, 24 empty. Results in `02-Projects/cvr-company-lookup/results/web_dk_first100.tsv`.
- About 1,500 Danish-marker names and 9,474 "other" names are not run.
- Web search cost about 2.1k Haiku tokens per company, so the full run costs more than the 18M estimate.
- Web search numbers are unverified. cvrapi.dk is more reliable on exact ApS/A/S names but allows 50 lookups a day.
- Open question: cvrapi.dk first, then web search on the rest (recommended), or web search on everything?

## 4. Ching Phase 1.5 (Hermes harvest)

- Spec and plan are committed (`e8499b1`, `da52747`): 12 tasks, TDD, D10 waves. A build session was started this evening.
- `tests/t_escalate.sh` and `tests/t_stop.sh` showed uncommitted changes earlier this evening; the tree is clean again now.
- The Ching repo has no git remote, so nothing here can be pushed.
- Deferred from Phase 0: voice tests 0.7 and 0.3.

## Way forward

1. Run the migrate gate, apply 0068, then push the miso workspace change (item 1). This unblocks the budget feature.
2. Answer the CVR question, then let the vault session continue.
3. Pull and merge the bbqos vault (item 2), then decide on parking the 17 stale projects.
4. Let the Ching build session finish before touching the two test files.

## Status at 22:05 (user decisions)

- Item 1 (miso 0068): being applied and pushed from another session in `~/.miso`. Do not apply from here, to avoid a double run.
- Item 2 (bbqos vault): being pulled and merged in a different workspace.
- Item 3 (CVR): the only open item. The user will start it overnight, once they know how much session limit is left. The cvrapi.dk-first vs web-search question is still unanswered.
- Item 4 (Ching build): running in a separate session.
