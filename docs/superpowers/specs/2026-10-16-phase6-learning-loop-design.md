# Phase 6: learning loop, design spec

Status: **approved for stage 6a**, 2026-10-16 (D26, D27). The owner said yes to questions 7-10, and questions 1-6 use the recommendations as defaults. Stage 6b stays unbuilt. Implements D11 within the limits of PLAN.md section 6 (Phase 6) and the Track B inputs in `2026-10-05-hermes-harvest-design.md` section 7. D16 said Phase 6 is specified after the pilot. The pilot is still running (PLAN 2.3 metrics are not recorded), so this spec builds on the event data gathered so far plus transcripts, and it says where that data is too thin.

## 1. Goal

Ching learns how the owner works from what is already on disk and turns that into a short queue of concrete proposals the owner can accept or reject in a few seconds each. The most useful outputs, in order:

1. **Correction patterns become rule proposals** for `~/.agents/CLAUDE.md` (which `~/.claude/CLAUDE.md` links to) or a repo `AGENTS.md`.
2. **Repeated workflows become skill proposals** (`skill-<slug>.md`), which skill-creator builds only after approval.
3. A weekly **stats and habits report**, with a **blind-spot ledger** once its data exists.
4. **Lessons with decay and consolidation**, injected at SessionStart. This is built last (stage 6b) because the data for it is thin (section 3).

Calibration from the 2026-10-16 skills evaluation (figures from that evaluation, not recomputed here): 228 sessions had real human prompts (981 prompts), and about 25 of those prompts were real corrections (3-4%). Three corrections repeated: merge to main without losing work (6 or more sessions), "do it yourself, don't ask" (migrations, `.env` tokens), and "in the previous session…" (5 sessions). All three are now hand-written rules in `~/.agents/CLAUDE.md` and the miso `AGENTS.md`. Corrections are rare, so the loop must be cheap, it must run in the background, and it may only propose.

## 2. Non-goals

- Applying anything by itself. The learner never writes skills, guard, hooks, settings, `CLAUDE.md`, `AGENTS.md` or `GOAL.md`.
- A daemon, a cloud scheduler, a vector store, embeddings, or any service that leaves the machine (D12, D17).
- A profile of the owner's strengths and weaknesses in prose. D11 open question 1 (how blunt) stays open. This phase produces evidence-backed proposals, not judgments.
- Spoken output from the dispatcher (D11 open question 3 stays open).
- Changing what sessions log beyond the event fields listed in 4.3.

## 3. Data sources and what they can support

### 3.1 `~/.agent/events.jsonl` (profiled 2026-10-16)

- 3,896 lines from 2026-10-05T21:08:36Z to 2026-10-15T22:25:27Z, with events on 9 days (none on 10-08 or 10-09). 137 distinct non-empty session ids, 109 of them with `prompt` events (median 6 prompts per session, max 58).
- Kinds: `notify` 1,440, `prompt` 959, `stop_ok` 798, `context` 225, `session_start` 157, `session_end` 139, `deny` 74, `nudge_spoken` 30, `check_skipped` 22, `checkpoint` 17, `stall` 15, `stop_blocked` 9, `compact` 6, `waiting` 4, `release` 1.
- Test and sandbox share: **11 lines (0.28%)**. Four are under `/tmp` (three of them `/tmp/task9-cont-repo`), seven are under `/private/var/folders/.../T`, and none are under `/private/tmp`. Real work dominates: `~/gitall/soii` 1,687, `~/.miso` 497, `~/bbq/ching` 357, `~` 325, `~/cos` 284.
- Notify detail: 701 `done` routed to the inbox, and 474 `waiting` suppressed by quiet hours.
- `checkpoint`: 17 events from 4 sessions, all under `~/.miso`. The data holds `status`, `blocker` and `next_action` only. There is **no `not_examined`**.
- `stop_blocked`: 9, all `reason: checkpoint`, `retry: 1`, all under `~/.miso`. There are **zero test-failure blocks**, so time to green cannot be measured.
- `release`: 1 (a `gate-fail` for a missing evidence file).
- `prompt` events carry no text, by design. Correction detection must read transcripts.

### 3.2 Session registry `~/.agent/sessions/`

There are 4,795 directories. 4,615 of them (96%) have `cwd=/private/tmp`, `source=startup`, all started on 2026-10-05, with no transcript on disk and no events. They are leftovers from the build's test runs. **The learner never counts sessions from the registry.** It reads only events and transcripts. The registry holds 18 `STATE.md` files, and 2 of them have a `not_examined:` line. Under `~` (depth 6) there are 0 review files and 1 verify file.

### 3.3 Transcripts `~/.claude/projects/*/*.jsonl` (counted 2026-10-16)

- 1,977 files. **1,584 are claude-mem observer runs** (`-Users-clyde--claude-mem-observer-sessions`) and must be excluded. The evaluation earlier the same day counted 1,579 of 1,964, and the gap is new runs since then.
- Of the other 393: 73 are headless `entrypoint: sdk-cli` runs (for example, 53 sessions under `~/.miso/workspaces/bbqos` open with the same "Classify each company below…" prompt), and 5 are in `-private-tmp-agent-sandbox-repo`. Both groups are excluded.
- With those exclusions, plus `isMeta`, sidechain, tool results, and text starting with `<`, `Caveat:` or `[Request interrupted`, this spec's recount gives **221 sessions with 947 human prompts**. The evaluation's filter gave 228 and 981. The exact filter is pinned in a test (section 7) so counts stay comparable.

### 3.4 Can the current data support each Phase 6 input?

| Input | Supported now? | Missing piece |
|---|---|---|
| Correction patterns, giving rule proposals | **Yes**, from transcripts | none |
| Skill-candidate miner | **Yes**, from transcripts (253 sessions with tool calls) | none |
| Habits (hour, weekday, correction phrases) | **Yes**: hours and days from `prompt` events, phrases from transcripts | none (event `ts` is UTC and is converted to local time) |
| Per-task-type stats | **Partly**. Stop retries, stalls and context handoffs exist per folder | a `task_type`; a test outcome event (time to green); an overturned-assumption signal |
| Blind-spot ledger | **No**. 2 `not_examined` lines exist in total | `not_examined` in the `checkpoint` event |
| Lesson records, decay, consolidation | **Thin**: 17 checkpoints from 4 sessions | more checkpoints; most sessions are not in repo mode, so no checkpoint is enforced there |

## 4. Shared contracts (land first, before any fan-out)

### 4.1 Layout

Everything the learner writes lives under `~/.agent/proposals/` (mode 0700, files 0600):

```
~/.agent/proposals/
  <kind>-<slug>.md          open proposals (kind: rule | skill | blindspot | prune | lesson)
  report-YYYY-Www.md        weekly stats report (informational, no approve step)
  archive/                  approved, rejected and snoozed proposals, moved here by the CLI
  rejected.txt              one fingerprint per line; never re-proposed
  .work/                    extracts and run logs, rebuilt every run, safe to delete
```

### 4.2 Proposal file format

Key-value header lines (the same style as `REVIEW.md`), then fixed sections:

```
id: rule-merge-main-keep-work
kind: rule
status: open                      # open | approved | rejected | snoozed:<YYYY-MM-DD>
created: <ISO8601 UTC>
component: corrections            # corrections | skills | report | blindspot | lessons
fingerprint: <sha1 of the normalised pattern>
sessions: <n>
days: <n>
target: ~/.agents/CLAUDE.md       # rule: file to change; skill: proposed skill name

## proposal
<two to five plain sentences>

## evidence
- <sid 8 chars> <YYYY-MM-DD> <cwd> "<quote, at most 300 characters, secrets redacted>"

## patch                           # rule only: unified diff against the current target
## why this is not already covered
<which existing rule or skill was checked, and why it does not cover this>
```

`proposal_write` in `bin/lib.sh` is the only writer. It refuses a path outside `~/.agent/proposals/`. It skips a fingerprint that is already in `rejected.txt` or already belongs to an open proposal, so a rerun refreshes the evidence and does not duplicate the proposal. It also redacts strings that match the existing guard credential patterns.

### 4.3 New and extended events (emitted through `ev`, same 300-character cap)

| kind | data | producer |
|---|---|---|
| `checkpoint` (extended) | add `not_examined`, `task_type` | stop-check.sh, from the checkpoint block |
| `tests` (new) | `{outcome: pass\|fail, secs}` | stop-check.sh, after it runs the test command |
| `learn_run` (new) | `{component, scanned, candidates, proposals, outcome}` | each learner component |
| `proposal` (new) | `{id, action: approved\|rejected\|snoozed}` | `ching-proposals` |

`/handoff` and the checkpoint template gain an optional `task_type:` line (open question 3).

### 4.4 Exclusion filter `learn_filter`

One shared definition, used by every component and tested. Exclude:

- the observer project directory;
- `entrypoint == sdk-cli`;
- project directories and `cwd` under `/tmp`, `/private/tmp`, `/private/var/folders`, or matching `task*-repo`;
- the learner's own working directory `~/.agent/proposals/.work`;
- sidechain lines;
- registry-only sessions.

## 5. Components

Each component is a bash script (with `jq`, and `perl` where `jq` is too slow, as `quote-data.pl` already does). One launchd job, `org.ching.learn`, runs `bin/learn.sh`, which calls the components in order under a `mkdir` lock (the same pattern as `ching-watch.sh`).

### 5.1 Extractor `bin/learn-extract.sh` (deterministic, no model)

- **In:** transcripts changed since the last run (byte offsets kept in `.work/offsets`) and `events.jsonl` (rotated files included).
- **Out:** `.work/prompts.jsonl` holds one human prompt per line, as `{sid, ts, cwd, text≤600, prev_assistant_tail≤300}`. `.work/toolseq.jsonl` holds one session per line, as `{sid, day, cwd, tokens[]}`.
- **Token normalisation:** the tool name; for Bash, the first two non-flag words after stripping a leading `cd <dir> &&|;`; for Skill, the skill name. Consecutive duplicates are collapsed. Plumbing calls are dropped (`ToolSearch`, `TodoWrite`, task tools, browser tab-context calls).
- **Cadence:** every learner run.

### 5.2 Correction detector, giving rule proposals `bin/learn-corrections.sh`

- **In:** `.work/prompts.jsonl`, the current `~/.agents/CLAUDE.md`, and the `AGENTS.md` files of the repos seen in the events.
- **Stage 1 (deterministic prefilter):** keyword and structure hits ("don't/do not/stop", "actually", "yourself", "previous/last/other session", merge plus main, "lost", a leading "no"), plus prompts that follow an interrupt. In today's data this matches **162 of 947 prompts in 100 sessions**. That is about six times the 25 real corrections the evaluation found, so stage 1 cannot be the detector by itself.
- **Stage 2 (model):** one local `claude -p` call per run on the stage-1 snippets only. It labels each snippet `correction | not`, and for corrections a one-line normalised pattern. A deterministic clustering step then groups by pattern. A cluster becomes a proposal when it spans **3 or more sessions on 2 or more days**, the same bar as the miner.
- **Stage 3 (model, same call or a second one):** for each cluster, draft the rule text and patch, and fill "why not already covered" against the current `CLAUDE.md` and `AGENTS.md`. A cluster that an existing rule already covers is dropped and recorded in `learn_run` as `covered`.
- **Out:** `rule-<slug>.md`.
- **Cadence:** nightly. A run with no new prompts makes no model call.

### 5.3 Skill-candidate miner `bin/learn-skills.sh`

- **In:** `.work/toolseq.jsonl` and the installed skill names (32 entries in `~/.claude/skills` today, plus plugin skills from the listing).
- **Deterministic part:** count the 3-6-step sequences with at least 2 distinct tokens and keep those seen in 3 or more sessions on 2 or more days. A trial on today's data shows this bar is far too loose by itself. The raw rule gave **321** qualifying sequences from 253 sessions and 21,043 tool calls. After `cd` stripping, plumbing removal and dropping pure Read/Edit/Grep/Glob/Write sequences, 225 remained, and **185** after keeping only maximal sequences. The top ones are generic edit-test loops (`Write > bun test > Write`, 15 sessions on 7 days) and browser driving. These are habits, not skills.
- **Model part:** one `claude -p` call takes the top candidates by sessions × length, each with the human prompt that preceded the sequence in each session. It keeps only those with a nameable, repeatable intent that no existing skill covers, and writes at most `LEARN_SKILL_MAX` proposals per run (open question 6).
- **Out:** `skill-<slug>.md`, with a draft `SKILL.md` description in `## proposal`.
- **Cadence:** weekly (Sunday run).

### 5.4 Weekly report and blind-spot ledger `bin/learn-report.sh` (deterministic, no model)

- **In:** `events.jsonl` and `.work/prompts.jsonl`.
- **Report (`report-YYYY-Www.md`):** sessions and prompts per folder; prompt hours and weekdays in local time; stop retries, stalls, context handoffs and denies per folder; notification delivered or suppressed by reason; and, once the 4.3 fields exist, time to green and retries per `task_type`. A week-on-week change is reported only when both weeks have data.
- **Blind-spot ledger:** `not_examined` items from `checkpoint` events and `STATE.md` files are normalised by lower-casing and stripping paths and commit ids. An item seen in 3 or more checkpoints across 2 or more sessions becomes `blindspot-<slug>.md`, proposing a review lens line or a VERIFY.md prompt. This produces nothing until the extended `checkpoint` event has run for a while (section 3.4).
- **Cadence:** weekly.

### 5.5 Lessons, decay and consolidation `bin/learn-lessons.sh` (stage 6b)

- **Lesson record** (a JSON line inside `lesson-<slug>.md`): `{task_type, what_worked, what_failed, do_differently, quality 1-10, tags[], evidence[]}`. These are drafted by `claude -p` from a session's checkpoints and `STATE.md` decisions when the session has at least one checkpoint.
- **Decay:** `score = importance × e^(−0.693·days/14)`. A recurrence resets `days` and adds 1 to importance. Approved lessons below 0.1 produce a `prune-<slug>.md` proposal. Nothing is deleted automatically.
- **Consolidation:** monthly, 3-5 facts of 15 words or fewer, each scored 1-10. Facts at 5 or above are kept, under a size cap (open question 4).
- **Retrieval:** approved lessons live in `~/.agent/profile/lessons.jsonl`, written only by `ching-proposals approve`. `session-start.sh` injects the top 3 by score, and only when a lesson tag matches a keyword in that folder's `GOAL.md` or `NEXT.md`. With no keyword hit, nothing is injected (this fixes the upstream every-entry-scores bug).
- **Cadence:** nightly drafting, monthly consolidation. Build this only after the owner confirms open question 5.

### 5.6 The model call

- `bin/learn.sh` runs `claude -p --model "$LEARN_MODEL" --tools "" --output-format json` with `cwd ~/.agent/proposals/.work`. The prompt and snippets go in on stdin, and JSON comes out on stdout. The model has **no tools**, so it cannot write files. The bash wrapper validates the JSON and calls `proposal_write`.
- The job sets `CHING_LEARNER=1` in its environment. `guard.sh` treats that as learner mode and denies any write outside `~/.agent/proposals/` and any Skill, MCP or network tool (a second layer, in case `--tools ""` is ever loosened).
- Input size is capped by `LEARN_MAX_SNIPPETS`. A run that hits the cap logs `learn_run{outcome: truncated}`.
- The learner's own transcript and events are excluded by `learn_filter` (4.4).

## 6. Approval flow

1. **Surfacing.** `dash.sh --inbox` gains a fourth lane, **PROPOSALS**, which lists the open proposals as `kind id: first sentence (sessions/days)`. `dash.sh --speak` adds at most "N proposals waiting." Proposals never push a notification. They are not urgent, and the budget is already busy (474 `waiting` suppressed by quiet hours).
2. **Review.** `ching-proposals list`, `show <id>` (the full file, with the patch coloured), and `diff <id>` (for a rule: the patch against the live target).
3. **Decide.**
   - `approve <id>` for a **rule** shows the patch and asks for the confirmation code (item 4), then applies it with `patch`, the human having confirmed.
   - `approve <id>` for a **skill** writes nothing into `~/.claude/skills`. It prints the exact prompt to start a skill-creator session, with the proposal as input.
   - `approve <id>` for a **lesson** appends it to `~/.agent/profile/lessons.jsonl`.
   - `reject <id> [reason]` adds the fingerprint to `rejected.txt`.
   - `snooze <id> <days>` hides the proposal until that date.
   Every decision moves the file to `archive/` and emits a `proposal` event.
4. **Only a human can approve.** `approve` refuses unless stdin and stdout are a TTY (the Bash tool in a session is not). `guard.sh` also denies `ching-proposals approve` from any session, the same pattern as the release `--approve`.
   *Changed in stage 6a (verifier finding):* those two checks did not hold. A pty wrapper (`script -q /dev/null` with a delayed `y` piped in) passed the TTY check, and the guard's token match missed `xargs`, a variable, `$(...)`, backticks, `appr${x}ove`, perl `exec` and a wrapper script. The defence now sits in `ching-proposals` itself, in three layers: (a) it refuses when a Claude Code session started it, by the variables a session sets (`CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`, `CLAUDE_PID`, `AI_AGENT` and others) and by a `claude` process anywhere up the parent chain, which catches a session that unset them; (b) the TTY check; (c) for every kind, it shows a random 4-character code and reads it back from `/dev/tty` after flushing typeahead, so a blind answer cannot pass. The guard became a cheap allowlist: a session may only call `ching-proposals` directly as `list`, `show`, `diff`, `reject`, `snooze` or `help`, or name it as data for a reader (grep, cat, git, shellcheck and the like). Residual risk: a session that detaches a process from its own tree (double fork, launchd, a tmux server), clears the variables, then reads the code off the screen and types it back. That is deliberate circumvention, not an over-eager session, and such a session could as well edit the target by hand.
5. **Feedback.** The weekly report shows the approve and reject counts per component. A component with only rejections for 4 weeks is flagged in the report, so the owner can turn it off (`LEARN_DISABLE=<component>`).

## 7. Safety boundaries

- The learner writes only under `~/.agent/proposals/`. This is enforced three ways: `proposal_write` checks the path, the model has no tools, and guard learner mode denies other writes.
- No edits to `~/.claude/skills`, `~/.claude/settings*.json`, `guard.sh`, hooks, `~/.agents/CLAUDE.md`, any `AGENTS.md`, or `GOAL.md` gate lines, except through the owner running `approve` at a TTY.
- Local only. The single model call is a local `claude -p` (the same subscription and engine as every session, D15). Nothing is sent to any other service. Quotes are capped at 300 characters and redacted.
- Fail quiet. A learner failure logs a `learn_run` event and `~/.agent/proposals/.work/learn.log`, and never touches hooks or sessions. `ching-watch.sh` is unchanged.
- Cost is bounded. There is no model call when nothing is new. There is one call per component per run, with capped input.
- Wipe. `rm -rf ~/.agent/proposals ~/.agent/profile` removes all learned state, and the next run rebuilds `.work/` from the source data.

## 8. Test plan

TDD in the existing harness (`tests/run.sh`, sandboxed `HOME`, `AGENT_HOME`, `CLAUDE_DIR`). A `claude` stub returns canned JSON. New test files: `t_proposals.sh`, `t_learn_extract.sh`, `t_learn_corrections.sh`, `t_learn_skills.sh`, `t_learn_report.sh`, plus extensions to `t_guard.sh`, `t_dash.sh`, `t_stop.sh` and `t_install.sh`.

- **Filter:** fixture transcripts for an observer run, an `sdk-cli` run, a `/private/tmp` sandbox, an `isMeta` line, a sidechain, a tool result and a `<command-name>` prompt are all excluded. A plain CLI prompt is counted.
- **Extractor:** offsets are incremental, a shrunk transcript resets to 0, malformed lines are skipped, and the `cd` strip and plumbing drop work.
- **Corrections:** with a stub classifier, a pattern in 3 sessions on 2 days gives one `rule-*.md`; 3 sessions on 1 day gives none; a pattern covered by the fixture `CLAUDE.md` gives none and logs `covered`; a rejected fingerprint is never re-proposed; two runs give one file.
- **Miner:** a 4-step sequence in 3 sessions on 2 days gives one candidate; a subsequence with the same session set is not listed separately; a sequence matching an installed skill name is dropped; output is capped at `LEARN_SKILL_MAX`.
- **Report:** UTC to local hour conversion; no week-on-week line when the prior week is empty; the blind-spot threshold.
- **Decay:** the score halves at 14 days; a recurrence boosts it; below 0.1 gives a `prune-*` proposal, and the lesson file is untouched.
- **Safety:** `proposal_write` refuses `../` and absolute paths outside the root; guard in learner mode denies Write, Edit, Bash redirects outside proposals, Skill and MCP tools; `approve` exits non-zero without a TTY, under a session (its variables or a claude parent), or without the code typed back, and so does each of the verifier's bypasses; guard lets a session call `ching-proposals` only as list, show, diff, reject, snooze or help.
- **Inbox:** the PROPOSALS lane lists open items, hides snoozed and archived ones, and says "(nothing)" when empty.
- **Live smoke (verifier only):** a real `claude -p --tools ""` run over a fixture `.work/` in a sandboxed `HOME`. Snapshot mtimes under the sandbox `~/.claude` and `~/.agents` before and after; nothing may change outside `proposals/`.
- **Real-data check (verifier, read-only):** run `learn-extract.sh` and `learn-report.sh` with `AGENT_HOME` pointing at a copy of the real data, and compare against the section 3 counts. A difference must be explained by data added since 2026-10-16.

## 9. Build split (D10)

**Step 0, contracts (one agent, serial, lands first):** `proposal_write` and `learn_filter` in `lib.sh`; the proposal format with a `templates/PROPOSAL.md` example; fixture transcripts and the `claude` stub in `tests/fixtures/learn/`; `t_proposals.sh`. Everything after this codes against these.

**Then four parallel implementers on disjoint files:**

| Agent | Files | Depends on |
|---|---|---|
| A: extractor and report | `bin/learn-extract.sh`, `bin/learn-report.sh`, their tests | contracts |
| B: corrections | `bin/learn-corrections.sh`, `templates/learn-prompts/corrections.md`, tests | contracts, A's `.work` format (from fixtures) |
| C: skills miner | `bin/learn-skills.sh`, `templates/learn-prompts/skills.md`, tests | contracts, A's `.work` format (from fixtures) |
| D: plumbing | `bin/learn.sh`, `bin/ching-proposals`, `dash.sh` lane, `guard.sh` learner mode and the approve deny, `install.sh` `org.ching.learn` plist, tests | contracts |

**Sequenced after the other in-flight work:** the `checkpoint` and `tests` event fields in `stop-check.sh`, plus `/handoff`. Other sessions edit ching code in separate worktrees, so this lands as a small follow-up on top of their merges, not in parallel with them.

**Stage 6b (after open question 5):** `bin/learn-lessons.sh` and the `session-start.sh` injection.

**Verifier (a separate agent, which grades none of its own work):** full suite plus shellcheck; the live smoke and real-data check from section 8; the error-resilience lens over guard learner mode, `proposal_write` and `ching-proposals approve`; and a report listing what was not examined.

## 10. Open questions for the owner

Recommendations added 2026-10-16 (evening) by the orchestrator session after reading this spec, D11/D12/D15/D16/D24, PLAN section 7, `bin/metrics.sh`, the live `events.jsonl` (now 878 KB, events on 10-12 to 10-16) and the claude-mem 13.40.0 code. They take into account the owner's decisions from the same evening: the 0.6 voice pass line is 8 s, no `/voice` fallback (the owner dictates with Wispr Flow), and nothing is released for now ("keep building"). Each is a recommendation, not a decision, until the owner says yes.

1. **Cadence and time.** Is a nightly run (corrections) and a weekly run (skills, report) right? At what local hour? D11 asked "daily or weekly".

   **Recommendation:** yes to nightly plus weekly. Run nightly at **05:30 local**, and the weekly run on **Monday at 05:30**, covering the Monday-Sunday week that just ended. The prompt events show work often runs to 02:00-04:00 local and almost nothing between 05:00 and 07:00, so 05:30 catches the whole working day. It also finishes before the 07:00 Apple Notes sync. launchd runs a missed calendar job when the Mac wakes, so sleep does not lose a run. *Would change my mind:* the owner wanting the report on Friday afternoon to plan the next week.

2. **Model.** Which model for `LEARN_MODEL`? D11 says a cheaper model. Should there be a per-run token cap on top of the snippet cap?

   **Recommendation:** use two settings. `LEARN_MODEL_CLASSIFY=haiku` for stage 2, the yes/no "is this a correction" labels on about 160 short snippets. `LEARN_MODEL_DRAFT=sonnet` for stage 3 and the skills pass, which run only on a handful of clusters and where the wording of a rule the owner will read matters. Also add a **daily token cap**, `LEARN_TOKEN_CAP`, starting at 200k tokens and read from the `--output-format json` usage. When the cap is hit, the component skips and logs `learn_run{outcome: capped}`. The learner runs on the same subscription as real work, so it must never eat into a working day's quota. *Would change my mind:* if Haiku scores below about 80% precision on the labelled set from question 7, move classification to Sonnet too.

3. **Task type.** Should sessions write `task_type:` in the checkpoint, should the learner classify it afterwards, or both? Without it, per-task-type stats stay per folder.

   **Recommendation:** the learner classifies it afterwards, from a fixed list of about seven types: build, fix, research, merge/sync, ops/config, writing, data. Sessions may still write an optional `task_type:` line, and when present it wins, but it is not required. Only 17 checkpoints from 4 sessions exist so far, and most sessions do not run in repo mode, so a required field would leave most sessions unlabelled and add friction to every checkpoint. *Would change my mind:* the learner's labels disagreeing often with the session's own when both exist (spot-check in the first weekly report).

4. **Rule target.** When a correction pattern shows up in only one repo, propose it for that repo's `AGENTS.md` or for the global `~/.agents/CLAUDE.md`? And what size cap for consolidated lessons?

   **Recommendation:** propose it for **that repo's `AGENTS.md`** when all evidence comes from one repo. Propose it for the global `~/.agents/CLAUDE.md` when it spans 2 or more repos, or appears in non-repo folders such as `~`. A rule that only ever bit in one place should not cost context in every session. If the target repo has a public remote or a public release copy (soii ships to the public soiisauce), the proposal says so in its header, because approving it publishes the rule. Lessons cap (only matters if 6b is ever built): at most **30 consolidated facts** in the store, at most **3 injected** per session, each 15 words or fewer, so about 60 words of added context. *Would change my mind:* the owner preferring one global file to keep everything in one place.

5. **Lessons at SessionStart.** With corrections at 3-4%, is extra injected context worth it, or should stage 6b stay unbuilt until the report shows a need?

   **Recommendation:** **keep 6b unbuilt.** The three repeated corrections are already hand-written rules, and rule proposals (5.2) cover the same need more cheaply and visibly. Build 6b only when the weekly report shows a clear signal: a pattern recurring in 3 or more sessions *after* its rule was approved (rules are not enough), or 3 or more recurring blind-spot items. *Would change my mind:* either of those signals appearing.

6. **Skill proposals per week** (`LEARN_SKILL_MAX`): what cap? The trial produced 185 maximal candidates before the model pass.

   **Recommendation:** **3 a week.** Each approved skill costs a skill-creator session, and the skills evaluation found about ten installed skills the owner never uses, so the risk is too many skills, not too few. The 4-weeks-of-rejections flag in section 6 then turns the miner off if it only produces noise. *Would change my mind:* raise to 5 if more than half the proposals are approved over the first month.

7. **Evaluation labels.** Is the list of about 25 real corrections from today's evaluation saved anywhere? It would be the recall test for stage 1 and the precision test for stage 2.

   **Recommendation:** it is **not saved as labels.** The evaluation's working file (`/tmp/prompts_probe.pkl`) is gone. Only two things survive. The 64 prompts its broad filter flagged are printed in a tool result of session `97885970` (`~/.claude/projects/-Users-clyde/97885970-fc83-4d00-aa63-1ab7d39d92e5.jsonl`). The judgment of about 25 real corrections and three clusters exists only as prose. Rebuild it in step 0: one agent labels the union of those 64 and today's 162 stage-1 hits; the owner spot-checks about 20 of them (about 10 minutes); the result is stored at `~/.agent/proposals/.eval/labels.jsonl`, outside the ching repo, because those are the owner's own prompts and ching is pushed to GitHub. The repo's tests keep using synthetic fixtures. A built-in recall check: the three known clusters (merge without losing work, do it yourself, previous session) must come back, and be dropped as `covered`, since they are already rules. *Would change my mind:* the owner not wanting to spend the 10 minutes, in which case the agent's labels alone are a weaker but usable baseline.

8. **claude-mem and the learner.** claude-mem starts an observer run per session (1,584 so far). Should the learner's own `claude -p` run be kept out of claude-mem, and if so, how?

   **Recommendation:** **yes, keep it out**, in two layers. First, the launchd job sets `CLAUDE_MEM_INTERNAL=1`. claude-mem 13.40.0's should-observe check returns false when that is set, which is how claude-mem keeps its own observer runs out (checked in the plugin code on 2026-10-16). Second, add `~/.agent/proposals/.work` to `CLAUDE_MEM_EXCLUDED_PROJECTS` in `~/.claude-mem/settings.json`, as a backstop in case the internal flag changes in a later claude-mem version. Otherwise every nightly run would add an observer run, and the learner would later read claude-mem notes about itself. Add a live-smoke check that no new `observer-sessions` entry appears after a learner run. *Would change my mind:* nothing likely; the only cost is one settings line, which the owner should approve since it is outside ching.

9. **Timing.** Build stage 6a (corrections, miner, report) now, before the pilot's section 7 metrics exist, or wait for Checkpoint 2 as D16 says?

   **Recommendation:** **build 6a now**, recorded as a new decision that amends D16, because the owner said "keep building". The original reason to wait was to design on real data. 6a reads transcripts, and there are already 221 real sessions with 947 prompts, so that data exists. The pilot metrics measure the session kit, not the learner. 6a only writes proposals, so building early risks time, not damage. The extended `checkpoint`/`tests` events also need weeks of data before the blind-spot ledger and per-task stats work, so they should start collecting early. Order: step 0 contracts → A (extractor and report) and D (plumbing) → B (corrections) → C (skills miner) last, since its trial was the weakest (185 generic candidates). *Would change my mind:* the pilot review (2.3) showing that the event schema must change, in which case do the event extensions after that review.

10. **Registry cleanup.** Can the 4,615 empty `/private/tmp` registry entries from 2026-10-05 be deleted? This is outside Phase 6, but they would mislead any future reader of the registry.

   **Recommendation:** **yes, but archive, don't `rm`.** Select only directories whose `cwd` is `/private/tmp`, that started on 2026-10-05, and that have no transcript and no events (a grep tonight found 4,628 with `/private/tmp` in their meta out of 4,805, so the exact filter matters). Pack them into one dated tarball under `~/.agent/archive/`, then remove them. Also find and fix the source: some test from the 2026-10-05 build wrote into the real `~/.agent/sessions` instead of a sandboxed `AGENT_HOME`, and a test should now assert that the suite leaves the real registry untouched. *Would change my mind:* any of them turning out to have a `STATE.md` or a transcript, in which case it is kept.

**Where the owner really has to choose:** 9 (it overrides the owner's own D16), 10 (it deletes files), 8 (it touches claude-mem's settings, which is outside ching), and 7 (only if the owner is willing to spend about 10 minutes spot-checking labels). The others are tuning values with sensible defaults that the weekly report can correct.
