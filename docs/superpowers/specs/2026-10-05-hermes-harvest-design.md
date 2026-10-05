# Hermes harvest: design spec (Phase 1.5)

Status: **approved in conversation 2026-10-05, written spec awaiting review.**
Inputs: four Hermes Agent repos, evaluated read-only in `vendor-eval/` (gitignored); summary for humans in `ching-functions.md`.
Builds on: PLAN.md v3 (machine-wide kit, Phase 1 done, hooks installed per D13).

## 1. Intent

**What the user said.** Ching should get everything worth having from four Hermes repos, without overlapping what already exists, and become "the best thing I ever did". Hermes is used only as a source of ideas (answer to the Hermes role question). Ching becomes **the main AI operations layer for all local files** (D14). The user wants to be interrupted only when it matters. Sessions may write drafts but never send messages. Review before release is required in every repo the user works in.

**Assumptions (mine; correct them in review).**
- The pilot (Phase 2) runs on the improved kit, so the harvest goes in before it.
- The learning loop (track B) is only worth building on real data, so its ideas are recorded now and specified after the pilot.
- Bash 3.2 plus `jq` stays the implementation language, matching the existing kit and its 600-check suite.

**Success criteria.**
1. With 4-8 sessions running, the user gets a push notification only for `input`, `blocked` and `ready`, plus at most 4 non-urgent alerts a day, 09:00-21:00 only.
2. A session that stops making progress for 20 minutes while `working` is reported within 25 minutes.
3. `dash.sh --inbox` and `--next` answer "what needs me, and what next?" in one screen. `--speak` says it in two sentences.
4. No push to a protected branch, and no `gh pr merge`, without browser evidence **and** a review file for that exact commit, each with a "not examined" section.
5. Sessions cannot publish packages, cannot close other people's PRs or issues, and cannot send email or chat messages (drafts only).
6. Every hook writes a structured line to `~/.agent/events.jsonl`, the input contract for the Phase 6 learning loop.
7. Full suite green, with a separate verification agent (D10).

## 2. Decisions

| # | Decision | Source |
|---|----------|--------|
| D14 | Ching is the main AI operations layer for the user's local files. Review before release is **required by default in every repo**, including repos without `GOAL.md` (via `~/.agent/defaults/GOAL.md`). Only a human-written `review: off` in a repo `GOAL.md` disables it. Guard did **not** protect `GOAL.md` before this spec; new rule 11 (6.4) stops sessions from changing gate settings. | User, 2026-10-05 |
| D15 | Hermes is a source of ideas only. No Hermes runtime, plugin, skill, or hermes-workspace GUI runs in Ching. Claude Code remains the only engine. | User, 2026-10-05 |
| D16 | Phase 1.5 = tracks C (review hardening) and A (coordination), built before the Phase 2 pilot. Track B (learning) is recorded as Phase 6 design inputs and specified after the pilot. | User, 2026-10-05 |
| D17 | Architecture: stay in bash. Append-only event log plus a one-shot launchd job; no daemon, no cloud scheduler, no AI calls in Phase 1.5. | User, 2026-10-05 |
| D18 | Sessions may write drafts but never send email or chat messages (guard rule 10). | User, 2026-10-05 |

## 3. What is taken from each repo

All four are MIT-licensed. Adapted text carries an attribution line.

| Repo | Taken (track) | Not taken, and why |
|---|---|---|
| hermes-plugins (42-evey) | Interruption budget (A), external stall watchdog (A), U×I×R next ranking (A), token budget warnings (A), lesson records + decay + consolidation into proposals (B) | All code. It is tied to the author's Docker stack (LiteLLM, Langfuse, Qdrant, MQTT). Found: file read via `web_extract`, sandbox escape, `identity` rewrites the system prompt without approval. |
| hermes-workspace (outsourc-e) | Checkpoint contract (A), notification routing (A), context-pressure states (A), inbox lanes (A), review before release (C), approval-checklist guard gaps (C), "name the exact missing piece" rule (C) | The app. It cannot drive Claude Code. The dev server is open to the network without a password. It reads and refreshes the Claude Code keychain token. It would be a second control plane. |
| super-hermes (Cranot) | Constraint footer "examined / not examined" (C), three lens prompts: error-resilience, identity, simulation (C), blind-spot ledger (B) | The five skills. Prompt-only; their claims are self-graded. `.prism-history.md` writes to the cwd and can be used for prompt injection. |
| hermes-skill-factory (Romanescu11) | Cross-session repeated-workflow mining, proposing skills for approval (B) | All code. It fails to load on Hermes v0.20.4, and its detection is a single prompt paragraph. |

## 4. Shared contracts

### 4.1 Event log: `~/.agent/events.jsonl`

- Mode 0600, append-only, local only. The path can be overridden through `AGENT_HOME`.
- One JSON object per line: `{"ts":"<ISO8601 UTC>","sid":"<session id>","name":"<display name>","cwd":"<path>","kind":"<kind>","data":{...}}`.
- Written only by `ev KIND DATA_JSON` in `bin/lib.sh`. It builds the line with `jq -nc`, truncates any string in `data` to 300 characters, keeps the whole line under 1 KB, and does one `>>` append. If `jq` fails or the file is not writable, `ev` returns 0 silently.
- Kinds and producers:

| kind | data | producer |
|---|---|---|
| `session_start` | `{source}` | session-start.sh |
| `prompt` | `{}` | session-start.sh touch |
| `session_end` | `{}` | session-start.sh end |
| `compact` | `{trigger}` | pre-compact.sh |
| `stop_ok` | `{}` | stop-check.sh |
| `stop_blocked` | `{retry, reason:"tests"\|"checkpoint"}` | stop-check.sh |
| `checkpoint` | `{status, blocker, next_action}` | stop-check.sh, when it parses a fresh block |
| `deny` | `{rule, tool}` | guard.sh, after the decision is printed |
| `notify` | `{kind, outcome:"delivered"\|"suppressed", reason}` | notify.sh |
| `stall` | `{idle_mins}` | ching-watch.sh |
| `context` | `{level, pct}`, only when the level changes | ching-watch.sh |
| `tokens` | `{day_total, budget, crossed}`, only when crossing 80% or 100% | ching-watch.sh |
| `release` / `migrate` | `{sha, outcome}` | release-gate.sh, post-release.sh, migrate-gate.sh |

- Rotation: `ching-watch.sh` renames the file to `events-YYYYMMDD-HHMMSS.jsonl` when it is over 20 MB. Rotated files are kept, since Phase 6 reads them.

### 4.2 Checkpoint block in STATE.md

The top `status:` line stays where `dash.sh` already reads it. Its values become `idle | working | input | blocked | done`. `/handoff` writes this block, followed by the existing sections:

```
<!-- ching:checkpoint -->
result: <one line: what this turn achieved>
blocker: none | <the exact missing piece: a file, a credential, a decision>
next_action: <one line>
files_changed: <n>
examined: <what this work covered>
not_examined: <what it deliberately did not check>
<!-- /ching:checkpoint -->
```

- Parsing is done by `checkpoint_get FILE KEY` in `lib.sh`: the first `key:` line between the markers.
- **Fresh** means the STATE.md mtime is at or after the session's last `prompt` time, which is the `prompted` key in the meta file, written by `session-start.sh touch`.
- **Enforcement:** only in repo mode (`GOAL.md` present). `stop-check.sh` blocks **once per prompt** with reason "update the checkpoint (/handoff)" when the block is missing or stale. It records `checkpoint_blocked_for=<prompted>` in meta so the next Stop passes, and it respects `stop_hook_active`. Outside repo mode it never blocks.
- `dash.sh` prefers the checkpoint `blocker:` over the first bullet under `## Blocked`, and falls back to that bullet when there is no block.

## 5. Track A: coordination

### 5.1 notify.sh: routing and interruption budget

- **Urgent kinds** (`input`, `blocked`, `ready`) are always delivered and never counted against the budget.
- **`done`** is not pushed. It is logged as `notify{done, suppressed, routed-to-inbox}` and appears in `dash.sh --inbox` under *finished*. `NOTIFY_PUSH_DONE=1` restores the push.
- **Budgeted kinds** (`idle`, `stall`, `handoff`, `tokens`, and any unknown kind) are delivered only when all of the following hold:
  - the local hour is between `NOTIFY_QUIET_END` (9) and `NOTIFY_QUIET_START` (21);
  - fewer than `NOTIFY_BUDGET` (4) have been delivered today, counted in `~/.agent/notify/budget-YYYY-MM-DD` (a corrupt file counts as 0);
  - at least `NOTIFY_COOLDOWN_MINS` (45) have passed since this session's last budgeted alert.
  Otherwise the alert is logged as suppressed, with the reason.
- The existing `idle` suppression (`NOTIFY_IDLE_SUPPRESS`) stays and is checked first.
- The old blanket "Session finished" popup is still removed only with `install.sh --replace-popup`. The PLAN question 6 is unchanged.

### 5.2 ching-watch.sh: launchd job, every 5 minutes

- **Installation.** `install.sh` writes `~/Library/LaunchAgents/org.ching.watch.plist` (`StartInterval` 300, `RunAtLoad` true, stdout and stderr to `~/.agent/watch.log`) and loads it with `launchctl bootstrap gui/$UID`. Running it again is idempotent: if the plist is unchanged, nothing happens. `--uninstall` boots it out and removes the plist. `LAUNCHCTL` and `LAUNCH_AGENTS_DIR` env vars let the tests use a stub.
- **Run.** It takes a lock with `mkdir ~/.agent/watch.lock`. If the lock is held and less than 10 minutes old, it exits 0; an older lock is treated as stale and replaced. It then iterates the registry sessions whose state is not `ended`.
  1. **Stall.** If `state=working`, the transcript mtime is more than `WATCH_STALL_MINS` (20) ago, and `stalled_at` is unset: set `stalled_at` in meta, emit `stall`, and run `notify.sh stall`. Any newer transcript write clears `stalled_at`.
  2. **Context.** Read the transcript from the saved `ctx_offset` (byte offset in meta). Take the last assistant `message.usage` and compute `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`, divided by the window. The window is 1,000,000 if the model id contains `[1m]`, otherwise 200,000. Levels: `healthy` < 60%, `watch` 60-80%, `handoff` > 80%; `?` when there is no usage yet. Store `ctx_level` and `ctx_pct` in meta, and emit `context` on a change. At `handoff`, run `notify.sh` with kind `handoff`, which is budgeted.
  3. **Tokens.** Over the same incremental read, add `output_tokens + input_tokens + cache_creation_input_tokens` for each assistant message dated today. Cache reads are excluded because they are cheap. The total goes into `~/.agent/tokens/YYYY-MM-DD` as `sid total` lines. If `TOKEN_BUDGET_DAILY` is set (in `~/.agent/defaults/ching.env`), emit `tokens` and run `notify.sh tokens` once when the machine-wide total crosses 80% and once at 100%.
  4. Rotate `events.jsonl` if it is over 20 MB.
- **Robustness.** Malformed lines are skipped. A missing transcript means the session is skipped. If a transcript has shrunk (truncated or replaced), the offset is reset to 0. `WATCH_NOW` fakes the time in tests.

### 5.3 dash.sh: columns, `--inbox`, `--next`, `--speak`

- **New columns:** `ctx` (`●` healthy, `◐` watch, `○` handoff, `?`) and `tok` (today's tokens for the session, for example `1.2M`).
- **`--inbox`** groups sessions into three lanes:
  - **needs you:** `input` and `blocked`, with the blocker shown;
  - **ready:** the release gate passed in `confirm` mode and is waiting for `--approve`, read from the `ready` notify events;
  - **finished:** `done` since the last `--inbox` run, tracked in `~/.agent/inbox.seen`.
- **`--next`** lists the top 5 by score = U × I × R:
  - U (urgency): blocked 10, input 9, stalled 8, ctx handoff 7, working 4, idle 2.
  - I (importance): repo mode 3, plain folder 1.
  - R (recency): `max(0.2, 1 - age_hours/24)`.
  - Each line ends with the checkpoint `next_action`.
- **`--speak`** uses inbox wording, at most two sentences, and the >5 active-sessions warning is kept. Example: "Two need you. miso-app is blocked: needs the Supabase token."

### 5.4 Dispatcher policy

Finished sessions are not announced unprompted. "What finished?" is answered from the inbox. Everything else in `dispatcher/AGENTS.md` is unchanged.

## 6. Track C: review hardening

### 6.1 Constraint footer in release evidence

`templates/VERIFY.md` gains a required `## not examined` section. `release-gate.sh` rejects the release when that section has under 10 non-blank characters, by the same mechanical check as `none_reason`.

### 6.2 Review before release (required everywhere, D14)

- **Policy.** Before running `release-gate.sh`, the session dispatches a **fresh read-only reviewer subagent**. It gives the subagent `git diff <base>...HEAD` and the three lens prompts, and the subagent writes `.agent/review/<full sha>.md`. In a repo without `GOAL.md` the path is `~/.agent/sessions/<sid>/review/<sha>.md`. Release-gate looks in the same state dir it already uses for evidence.
- **Format** (new template `templates/REVIEW.md`):

```
commit: <full sha>
reviewer: subagent
lenses: error-resilience, identity, simulation
blocking: <n>

## findings
- [blocking] <file:line> <what> 
  resolved: <commit or explanation>      # required under every [blocking] item when blocking > 0
- [note] <file:line> <what>

## not examined
<what this review did not check>
```

- **Gate checks** (mechanical), with a rejection reason that names the fix:
  - `commit:` equals HEAD;
  - the file mtime is at or after the HEAD commit time;
  - `## not examined` has 10 or more characters;
  - if `blocking:` > 0, every `[blocking]` bullet is followed by a `resolved:` line.
- **Limit, stated honestly:** the gate cannot prove that a different agent wrote the file. Like the browser evidence, it is enforced by policy plus mechanical checks.
- **Configuration.** `review: required` is added to `templates/GOAL.md` and written into `~/.agent/defaults/GOAL.md` by `install.sh` if absent. Release-gate treats a missing key as `required`. Only `review: off` in a repo `GOAL.md` skips the checks; the gate then prints "review skipped by GOAL.md".

### 6.3 Lens prompts

- `templates/review-lenses/error-resilience.md`, `identity.md` and `simulation.md`, adapted from super-hermes `skills/prism-scan/references/`, with MIT attribution. Hermes-specific calls are removed.
- Each lens ends with an instruction to fill `## not examined`.
- **First use, part of the build verification:** run error-resilience over `bin/guard.sh` and `bin/stop-check.sh` to find fail-open paths. Findings are fixed or logged.

### 6.4 New guard rules

Same deny JSON as existing rules, failing closed. Each denial carries a "do this instead" reason.

| Rule | Denied | Still allowed | Reason given |
|---|---|---|---|
| 8 Publishing | `npm publish`, `bun publish`, `pnpm publish`, `yarn npm publish`; `gh release create\|delete\|edit`; `gh repo delete`; `gh repo edit --visibility`; `gh repo create --public` | `npm pack`, `gh release view\|list`, `gh repo view` | "publishing is the user's call: prepare it, then notify ready" |
| 9 Closing others' items | `gh pr close`, `gh issue close`, `gh issue delete`, and `gh api` PATCH/POST setting `state=closed` | `gh pr comment`, `gh issue comment`, `gh pr view` | "comment with your reasoning and notify instead" |
| 10 Sending | MCP tools whose name matches `send_message`, `reply`, `forward`, `post_message`, `send_email` across Gmail, Slack, Discord, Telegram | `create_draft`, `update_draft`, read tools | "write a draft and notify; sending is the user's call (D18)" |
| 11 Gate settings | Edit, Write or MultiEdit of any `GOAL.md` under `.agent/` or `~/.agent/defaults/` whose new text adds or changes a `review:`, `release_mode:` or `test_command:` line; any Bash write (redirect, `sed -i`, `tee`, `cp`, `mv`) to those paths | Edits to the goal paragraph, scope and definition of done | "gate settings are the user's: put the proposed change in STATE.md and notify" |

- `install.sh` widens `GUARD_MATCHER` to include `mcp__.*([Gg]mail\|[Ss]lack\|[Dd]iscord\|[Tt]elegram).*`.
- Service control (`launchctl`, `brew services`) is **not** denied, because the installer itself uses `launchctl`.

### 6.5 Autonomy block and handoff

- `templates/AGENTS-autonomy-block.md` gains the following:
  - write the checkpoint block at the end of every turn;
  - a blocker must name the exact missing piece;
  - shipping step 3½: run the reviewer subagent with the lenses and write the review file;
  - drafts only, never send.
- `commands/handoff.md` writes the checkpoint block and keeps everything else.

## 7. Track B: recorded for Phase 6 (not built in 1.5)

These are design inputs for the D11 learning-loop spec, written after the pilot. Every part writes only to `~/.agent/proposals/`; nothing applies itself.

1. **Signals:** `events.jsonl` (all kinds above), plus transcripts and STATE.md decisions and assumptions.
2. **Lesson records** (hermes-plugins `learner`): `{task_type, what_worked, what_failed, do_differently, quality, tags, evidence}`. Retrieval requires a keyword hit; this fixes the upstream bug where every entry scored above 0. The top 3 for the GOAL.md keywords are injected at SessionStart.
3. **Decay** (`memory-adaptive`): `score = importance × e^(−0.693·days/14)`. A recurrence boosts the score. Entries below 0.1 are proposed for pruning, never auto-deleted.
4. **Consolidation** (`memory-consolidate`): extract 3-5 facts of 15 words or fewer, tagged, scored 1-10; keep those scoring 5 or more, under a size cap. All local; the model call is a local `claude -p` started by launchd.
5. **Per-task-type stats** (`delegation-score`): stop retries, time to green, and overturned assumptions per task type.
6. **Habits from transcripts** (`habits`, derived rather than self-reported): hour, weekday, correction phrases, and a frustration signal.
7. **Blind-spot ledger** (super-hermes): recurring `not_examined` items across checkpoints and reviews.
8. **Skill-candidate miner** (skill-factory, with the prompt rules borrowed from Hermes's own `agent/background_review.py`):
   - normalise tool calls to tokens, then count 3-6-step sequences;
   - a candidate needs 3 or more sessions on 2 or more days, and must not already be covered by an existing skill;
   - each candidate becomes `~/.agent/proposals/skill-<slug>.md` with its evidence;
   - after approval, skill-creator builds it.
9. **Self-modification limit:** guard denies the learner writes to `~/.claude/skills`, `guard.sh` and settings.

## 8. Files touched

| File | Change |
|---|---|
| `bin/lib.sh` | add `ev`, `checkpoint_get` |
| `bin/session-start.sh`, `pre-compact.sh`, `post-release.sh`, `migrate-gate.sh` | emit events; `touch` also writes `prompted` to meta |
| `bin/stop-check.sh` | events; checkpoint block-once rule. **Another session currently has uncommitted edits here (test-escalate work); the plan must sequence after them or rebase onto them.** |
| `bin/notify.sh` | routing, budget, quiet hours, cooldown, events |
| `bin/ching-watch.sh` | **new** |
| `bin/dash.sh` | columns, `--inbox`, `--next`, `--speak` wording |
| `bin/release-gate.sh` | `not examined` check, review checks, `review:` setting, events |
| `bin/guard.sh` | rules 8-11, deny events |
| `install.sh` | launchd plist, wider guard matcher, defaults `GOAL.md` `review: required` |
| `templates/` | STATE.md checkpoint, VERIFY.md `not examined`, REVIEW.md (new), review-lenses/ (new), GOAL.md `review:`, autonomy block |
| `commands/handoff.md`, `dispatcher/AGENTS.md` | checkpoint; inbox wording |
| `tests/` | `t_events.sh`, `t_watch.sh` (new); extend `t_notify`, `t_dash`, `t_guard`, `t_release`, `t_stop`, `t_session`, `t_install`; `live-smoke.sh` checks events |
| `.gitignore` | `vendor-eval/` |

## 9. Error handling

- Observing never breaks working. `ev` and `ching-watch.sh` failures are silent to hooks; `ching-watch.sh` logs to `~/.agent/watch.log`.
- Guard stays fail-closed. Its event is written after the decision, so a logging error can never change the decision.
- `stop-check.sh` blocks at most once per prompt for a checkpoint and keeps its 3-retry cap for tests. It never loops.
- Release-gate rejections always name the missing file or field and the command that produces it.

## 10. Testing

- TDD in the existing harness (`tests/run.sh`, sandboxed `HOME`, `AGENT_HOME` and `CLAUDE_DIR`, notifications dry-run). New behaviour gets a failing test first.
- Fixture transcripts with `usage` blocks; `WATCH_NOW` and `DASH_NOW` for time; a `launchctl` stub.
- Each guard rule gets deny cases **and** allow cases: comments, drafts, `npm pack`, view commands.
- `live-smoke.sh`: a real `claude -p` session produces `session_start`, `prompt` and `stop_*` lines in `events.jsonl`.
- Per D10, the work is split across parallel implementer agents on disjoint files after the contracts (`lib.sh`) land. A separate verification agent runs the suite plus shellcheck and reviews; the implementers do not grade their own work.

## 11. Out of scope

Running Hermes or any of the four repos. A GUI. Cloud schedulers. Any AI call in Phase 1.5. Track B implementation. Service-control guard rules. Phone or remote notification channels.
