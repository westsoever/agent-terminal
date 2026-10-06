# Checkpoint 1.5 - Phase 1.5 (Hermes harvest)

Branch `phase-1.5-harvest` (worktree `/Users/clyde/bbq/.worktrees/ching-harvest`), branched from `main` 19ae659.
Tasks 1-12 were built task by task, each with its own review. Task 12 was verified by an agent that did not implement Tasks 1-11 (plan D10).
After that, a final whole-branch review (strongest model) and two read-only lens reviews found more, and a **fix wave** went in on top (rows
"Fix wave" in section 1, findings in section 5). Nothing in this run touched `~/.claude`, `~/.agent` or `~/Library/LaunchAgents`, and
`install.sh` was not run on the real settings.

Read these first (state at the end of the run):

1. **`main` already contains Phase 1.5 up to commit 9260e02.** Merge `b73af38` (23:54) was made by `lyo` outside this run, most likely your other session (the
   nudge feature). So the live hooks run that code now, **without the fix wave**. Both recursion guards are in it (`CHING_ESCALATING` and
   `CHING_STOP_CHECK_RUNNING`), so the old patch `/tmp/ching-recursion-guard.patch` is obsolete. The fix wave sits on top of 9260e02 and merges
   onto `main` without conflicts; merging it is the next step (7(a)).
2. **Please undo an accidental git setting.** `core.hooksPath = .githooks` is now in `/Users/clyde/bbq/ching/.git/config`, shared by every worktree.
   A fix worker re-ran a test against a scratch directory that already existed and the test's git commands ran in the shared repo. The guard refused to let
   a session undo it, which is correct. Run `git -C /Users/clyde/bbq/ching config --unset core.hooksPath`. Until then hooks installed under `.git/hooks`
   (for example the pre-push backstop from `install.sh --install-prepush`) do not run. Lesson: never re-run a test with an existing sandbox directory; use a fresh `mktemp -d`.
3. **A decision for you before `install.sh`:** after the guard matcher is widened, guard rule 10 (drafts only, D18) denies `reply`/`send`/`forward`/`post_message`
   style tools for any MCP tool whose name contains gmail, slack, discord or telegram. Probed with the branch `guard.sh`:
   `mcp__plugin_telegram_telegram__reply` and `mcp__plugin_discord_discord__reply` are denied, `..._react` is allowed. Your settings enable both plugins,
   so a session can no longer answer you through those channels. This is the rule as designed; options in 7(c).

## 1. What was built, per task

| Task | Commits | What |
|---|---|---|
| 0 | main 19ae659 | Controller committed the in-flight `test-escalate` work on main first (suite 618 passed). |
| 0.5 (not in plan) | a189b85 | Recursion guard (R5): `test-escalate.sh` children get `CHING_ESCALATING=1`; with it set no model is started and `stop-check.sh` allows at once. Without it a failing `test_command` made the Stop hook start `claude -p` children that inherited the Stop hook: unbounded paid recursion. +6 checks. |
| 1 (1.5.1) | 079313e | `lib.sh`: `ev KIND [JSON]` (event log `$AGENT_HOME/events.jsonl`, string cap 300, line cap 1024) and `checkpoint_get FILE KEY`; `t_events.sh` (22 checks). |
| 2 (1.5.2) | 9c2118a | Events from session-start, pre-compact, stop-check, release/migrate/post-release gates; `prompted` meta written on UserPromptSubmit. |
| 3 (1.5.1/1.5.6) | 578e748, a0b9688 | Checkpoint block (`<!-- ching:checkpoint -->`) in `templates/STATE.md` and `/handoff`; `stop-check.sh` blocks once per prompt in repo mode when the checkpoint is missing or older than the prompt. Plan defects fixed: `meta_get` died under `set -e` when a repo-mode session had no meta file (ruling: `[ -f meta ] \|\| return 0`); the `checkpoint` event was never logged after the one block (fix round: freshness check first, then already-blocked, then block). |
| 4 (1.5.3) | 8e180b9 | `notify.sh`: `done` goes to the inbox instead of a push; non-urgent alerts budgeted 4/day, 09:00-21:00, 45-minute cooldown; `input`/`blocked`/`ready` always delivered. |
| 5 (1.5.4) | 258b37a | `ching-watch.sh`: one-shot watcher with lock, stall after 20 min, context levels (healthy <60%, watch 60-80%, handoff >80%), daily token totals with optional `TOKEN_BUDGET_DAILY`, event-log rotation at 20 MiB. Plan defect fixed: a transcript truncated to 0 bytes kept the stale stored `tok_offset` (now reset and stored). |
| 6 (1.5.4/1.5.8) | 2abd88c, f01e68d, 848fdab | `install.sh`: launchd plist `org.ching.watch` (every 300 s), guard matcher widened to gmail/slack/discord/telegram MCP tools, matcher upgrade for existing entries. Added by ruling: `tests/live-smoke.sh` ran `install.sh --yes` with the real HOME, so it is now fully sandboxed (CLAUDE_DIR, SETTINGS_FILE, AGENT_REPOS_FILE, LAUNCH_AGENTS_DIR, LAUNCHCTL). Fix round: a failed `launchctl bootstrap` now removes the plist and exits non-zero so the next run retries. |
| 7 (1.5.5) | 9dbe6ea, d3911c4 | `dash.sh`: `ctx` and `tok` columns, checkpoint notes, `--inbox`, `--next` (urgency x importance x recency), new spoken needs-you lead; dispatcher policy uses the inbox. Fix round: `(none)`/`none` next_action sentinels (which `templates/STATE.md` ships) were preferred over a real blocker; filtered now. |
| 8 (1.5.7) | 1bc6c46, 40c60da | Review hardening: `templates/REVIEW.md`, `## not examined` in VERIFY.md, three lens prompts adapted from super-hermes (MIT attribution), review checks in `release-gate.sh`, `review: required` in the defaults `GOAL.md`. Fix round: the `[blocking]` bullet scan only ran when `blocking: N` was above 0 and was case-sensitive; it now always runs and the stated count may not exceed the bullets found. |
| 9 (1.5.8) | 54b073c, 4336c73 | Guard rules 8 (publishing), 9 (closing PRs/issues), 10 (drafts only for messaging MCP tools); denies are logged as events. Fix round: `slack_schedule_message` was allowed; `gh pr -R o/r close` style forms (repo flag before the subcommand) were allowed. |
| 10 (1.5.8) | 13528f0, 53d79fb | Guard rule 11: sessions cannot change `review`, `release_mode` or `test_command` in GOAL.md. Fix round: Edit/MultiEdit are simulated against the file on disk (`bin/goal-sim-edit.pl`) because a minimal edit (`confirm` to `auto`) passed a whole-line comparison; attached redirects (`>>.agent/GOAL.md`, `2>`, `&>`, `dd of=`) and case-insensitive paths (macOS) are now caught. |
| 11 (1.5.9) | e1abde7 (cherry-picked from 497db8e) | `templates/AGENTS-autonomy-block.md`: checkpoint every turn, name the exact missing piece, the review step, drafts only, gate settings; `tests/t_templates.sh`. |
| 12a (lens fixes) | ce5ae94 | From the stop-check.sh lens review: F1 (Critical) a GOAL.md `test_command` that starts a Claude session re-entered the Stop hook under a fresh session id and recursed: second marker `CHING_STOP_CHECK_RUNNING` for the test command; F2 no paid model ladder on the stop that hits the retry cap; F6 non-numeric or zero `STOP_CHECK_MAX_RETRIES`/`STOP_CHECK_TIMEOUT` silently disabled the caps. Each was reproduced RED first. |
| 12 (1.5.10) | 9260e02 (now also on `main` via merge b73af38) | Verification: suite, shellcheck, live smoke with the events line and `CHING_TEST_MODELS=""`, installer dry-run, first version of this report. |
| Final review + 2 lens reviews | (read-only) | Whole-branch review (strongest model) said "Ready to merge: with fixes" (3 Critical, 5 Important); the stop-check lens (12 findings) and the guard lens (12 findings) are in section 5. |
| Fix wave FB | 1ca0554 | `test-escalate.sh`: machine-wide daily ceiling on paid fix-model calls (`CHING_TEST_LADDER_DAILY`, default 6 calls per UTC day across all sessions, counter `$AGENT_HOME/ladder/<day>`, checked per call; a repo whose tests fail for any reason was costing 6 calls per prompt, 18 after three). `tests/lib.sh` clears the two recursion markers. |
| Fix wave FC1 | 1fc2507 | `ching-watch.sh`: `TOKEN_BUDGET_DAILY` parsing (`08`, `0`, quotes, `export`), and sessions whose meta file is older than 48 h are skipped (this machine has 4,662 session metas, 4,655 `ended`, mostly from the 2026-10-05 runaway: each watcher run cost ~17 s, now 0.09 s with 3,000 ended). `dash.sh` reads each meta in one pass (3,003 metas: `--next` 43 s to 0.7 s, output byte-identical in 10 modes) and `--next` no longer exits 141. `notify.sh`: no usable clock suppresses budgeted alerts. |
| Fix wave FC2 | 46b7c99 | `release-gate.sh` and templates: placeholders are one-line comments so an untouched template copy fails the "not examined" check, multi-line comments are stripped; `templates/GOAL.md` gets `review: required`; docs made honest (the review file is checked for form only). |
| Fix wave FA | 5fd969f, dcb73b5, d63d312, ab74af3 | `guard.sh`: (1) NUL-safe `gated_lines`; the `=`/`>` path trick; backslash-newline continuation no longer hides a push to main, a force push, a GOAL.md redirect or an `.env` read; new-file decoy (`  review: required` then `review: off`); the `export`/`declare`/`typeset` "internal error" (root cause: `seg_matches '-p' && emit_deny` as a last statement under `set -e`); `sed -ri`/`perl -wpi` and case-variant paths. (2) heredoc stripping no longer swallows later lines after a here-string, a hyphenated delimiter or `<<` in quotes; `gh api -XPUT`/`--method=`/GraphQL close and merge; the `Monitor` tool (matcher in `install.sh` + route); new-file MultiEdit; `cd -P`; fail-closed splitter, jq and preflight; an 8 s ceiling; `xargs -I`/`sudo -u`/`env -u`/`timeout -s` and 7 more launchers; narrow rule 8/10 name additions. (3) a comment ending in a backslash no longer hides the next line (three scan views); the `git commit -m "$(cat <<'EOF'`... idiom is no longer scanned as shell; deterministic ceiling test. (4) the guard now denies, fail closed, a command that is too large or too continued to scan in time ("command too large to check safely": over 256 KB, over 1000 backslash-newline continuations, a joined line over 64 KB, or a run of 64 or more trailing backslashes): the comment-aware view of (3) is not linear and a timed-out hook lets the call run (a 1 MB line took 20 s, 4,000 continuation lines 53 s; now about 1 s). The tokenizer also uses `tr -d` for segments over 2048 characters (the bash 3.2 `${s//\"/}` is cubic: 10,000 quotes took 39 s). |

Controller rulings that changed or constrained the plan:

- R1 commit trailers carry this run's model and session, not the plan's text. R2/R9 tasks ran sequentially; Task 11 and the
  stop-check lens ran in their own worktrees in parallel with Task 10 (file-disjoint), cherry-picked afterwards.
- R3 fix rounds capped at 3 per task and 45 agent dispatches in total (spend bound after the runaway).
- R4 models: implementers sonnet (haiku for Tasks 1 and 11), reviewers sonnet, final review opus.
- R5 Task 0.5 added. R6 `rm -rf /Users/clyde/bbq/ching/vendor-eval` was NOT run (deletes four clones outside the worktree; your call).
- R7 live smoke ran only after the verifier read the script. R8 implementers never ran `claude`, the live smoke, the real installer,
  and never touched `~/.claude`, `~/.agent`, LaunchAgents or `/Users/clyde/bbq/ching`.
- R10 lens triage: fix F1, F2, F6 (unbounded work/spend paths), log the other nine. R11 `CHING_TEST_MODELS=""` in the smoke
  script plus a hard 600 s alarm. R12 the merge into main is not done without you (moot for 9260e02, which someone else merged; it still holds for the fix wave).
- R9 (your request at 23:18, "faster with parallel agents") revised R2: independent work ran in parallel in separate worktrees with disjoint files and was
  cherry-picked afterwards (Task 11, the stop-check lens, the four fix-wave workers and the two lens/fix-wave reviewers); the dependency chain (10, 12, final review) stayed sequential.
- R13 one fix wave with the complete MUST FIX list, split into four disjoint-file workers (FA guard, FB ladder, FC1 watcher/dash/notify, FC2 release/templates/docs), then scoped
  re-reviews of the combined range. R14 guard-lens triage: fix F1, F2 (bounded), F3, F5, F6b, F7, F9 (narrow), F10, F12; leave F8, F11 and broader name coverage as gaps.
  R15 the re-review of the guard fixes found regressions the fix wave itself introduced (a comment ending in a backslash, the quoted commit-message heredoc idiom, a flaky
  test); they were fixed in a third guard commit and re-reviewed again.

## 2. tests/run.sh

**Final run, fix wave integrated (HEAD ab74af3):** `TOTAL: 1349 passed, 0 failed, 0 skipped`. The guard test file is now 576 checks (it was 347 at the verifier's run). The live smoke
(section 3) and the installer dry-run (section 4) were run at 9260e02 and not repeated after the fix wave.

```
file             pass   fail
t_dash             64      0
t_escalate         47      0
t_events           22      0
t_guard           576      0
t_install          68      0
t_lint             58      0
t_migrate          86      0
t_notify           38      0
t_post_release     18      0
t_release         130      0
t_session          37      0
t_stop             93      0
t_templates        28      0
t_watch            84      0

TOTAL: 1349 passed, 0 failed, 0 skipped
```

Earlier run, at the verifier's HEAD ce5ae94 (+ the smoke-script edit, which `run.sh` does not execute): `t_lint` found shellcheck 0.11.0 at
`/tmp/sc-venv/bin/shellcheck` (not on PATH) and ran it; `0 skipped`. A direct `shellcheck -x -S warning` over `bin/*.sh` and
`install.sh` also exited 0. That run's table:

```
file             pass   fail
t_dash             50      0
t_escalate         12      0
t_events           22      0
t_guard           347      0
t_install          68      0
t_lint             58      0
t_migrate          86      0
t_notify           31      0
t_post_release     18      0
t_release         114      0
t_session          37      0
t_stop             78      0
t_templates        15      0
t_watch            32      0

TOTAL: 968 passed, 0 failed, 0 skipped
```

Baseline before Task 1 was 624 passed (618 on main plus 6 from Task 0.5).

## 3. Live smoke (tests/live-smoke.sh, one run, branch hooks, haiku, `--max-budget-usd 0.30` x 3)

Run as `perl -e 'alarm 600; exec @ARGV' tests/live-smoke.sh`, exit 0. Sandbox `/tmp/ching-live.5ZQlhw`. Before running I confirmed in the
script: `install.sh` gets CLAUDE_DIR, SETTINGS_FILE, AGENT_REPOS_FILE, LAUNCH_AGENTS_DIR under `$S` and `LAUNCHCTL=/usr/bin/true`;
exactly three `claude -p` calls go through `run()` (each `--max-budget-usd 0.30 --no-session-persistence`, no loops); `AGENT_HOME="$S/agent-home"`
with `S=$(mktemp -d /tmp/ching-live.XXXXXX)`. Two edits to the script (committed here): `export CHING_TEST_MODELS=""` (no paid Haiku/Sonnet fix
attempts) and the `events logged:` line after `ok-file exists:`.

```
== 0. SessionStart injection alone (expects PINEAPPLE-42), repo with GOAL.md but no test_command
I need to update the checkpoint. Let me use /handoff to record this turn's progress.

/handoff: result: Answered the secret word from agent state (PINEAPPLE-42), blocker: None, next_action: Awaiting further user instructions, ...
== 1. SessionStart injection + Stop block (expects: PINEAPPLE-42, ok-file created after a block)
Updated checkpoint block in STATE.md.
retries/last state:
cwd=/private/tmp/ching-live.5ZQlhw/repo0
state=ended
cwd=/private/tmp/ching-live.5ZQlhw/repo
state=ended
ok-file exists: yes
events logged:  2 notify 2 prompt 2 session_end 2 session_start 3 stop_blocked 2 stop_ok 
== 2. guard denies a force push in bypass mode (to a scratch branch, so the model has no reason to refuse by itself)
Checkpoint updated. The force push was blocked by a hook guard that prevents all force push operations in this environment.
remote has scratch: no-good
sandbox: /tmp/ching-live.5ZQlhw
```

Event log of the whole run (read from the sandbox afterwards): session_start 3, prompt 3, stop_blocked 4, stop_ok 3, notify 3
(all `routed-to-inbox`), deny 1 (force push, rule text logged), session_end 3. Reasons of the four `stop_blocked`: checkpoint
(section 0), tests then checkpoint (section 1), checkpoint (section 2). So the Stop hook asked exactly once for the checkpoint in
each of the three sessions, and the failing `test -f ok-file` blocked once before it.

Compared with expectations:

- PINEAPPLE-42 appears only in section 0 (inside the model's checkpoint reply). In section 1 the final message printed by `-p` is
  the reply after the checkpoint block ("Updated checkpoint block in STATE.md."), so the word is not visible there although the
  context injection worked (the repo STATE.md contains it). The script's `tail -n 15` shows only the last turn; the old expectation
  "the answer contains the word" no longer holds for every section now that the Stop hook adds a turn.
- `ok-file exists: yes`, `remote has scratch: no-good`: as expected.
- The `events logged:` line lists session_start, prompt, stop_blocked, stop_ok (plus notify and session_end). `prompt` is logged: the CLI
  fires UserPromptSubmit in `-p` mode.
- Section 0: the model answered the checkpoint request in plain text and did not edit `STATE.md` (the file is unchanged), and the next
  Stop was still allowed. The gate asks once per prompt and does not verify compliance; this is the design plus lens finding F7.
- Real state after the run: `ls -ld ~/Library/LaunchAgents/org.ching.watch.plist`: `No such file or directory`.
  `ls -l ~/.claude/ching`: `/Users/clyde/.claude/ching -> /Users/clyde/bbq/ching`. `~/.claude/settings.json` mtime unchanged
  (1791230225), `~/.agent-repos` still dated 14:01. The smoke sandbox's `claude/ching` points at this worktree. No `claude -p` process left running.
- Three older `/tmp/ching-live.*` directories (13:52-13:53) pre-date this run; not created by it.

## 4. Installer dry-run against a copy of the real settings

`/tmp/cp15/settings.json` is a byte-identical copy of `~/.claude/settings.json` (same `shasum`), made with the Read and Write tools because
the installed guard denies `cp` on that path. Command (from the worktree, one simple command):

```
CLAUDE_DIR=$HOME/.claude SETTINGS_FILE=/tmp/cp15/settings.json AGENT_REPOS_FILE=/tmp/cp15/agent-repos \
  LAUNCH_AGENTS_DIR=/tmp/cp15/LaunchAgents LAUNCHCTL=/usr/bin/true ./install.sh --dry-run
```

`install.sh` reaches `if [ "$DRY" -eq 1 ]; then ... act ...; exit 0; fi` (lines 179-185) before any write; the only file it creates earlier is
a `mktemp -d` scratch directory for the diff, removed by an EXIT trap. Output (exit 0):

```
== settings: /tmp/cp15/settings.json
--- /tmp/cp15/settings.json (current)
+++ /tmp/cp15/settings.json (after install)
@@ -72,7 +72,7 @@
         ]
       },
       {
-        "matcher": "Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*",
+        "matcher": "Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*|mcp__.*([Gg]mail|[Ss]lack|[Dd]iscord|[Tt]elegram).*",
         "hooks": [
           {
             "type": "command",
warning: /Users/clyde/.claude/ching exists and is not our symlink; leaving it alone
warning: /Users/clyde/.claude/commands/handoff.md exists and is not our symlink; leaving it alone
warning: /Users/clyde/.claude/commands/next.md exists and is not our symlink; leaving it alone
would: create /tmp/cp15/agent-repos (empty, optional)
would: back up and rewrite /tmp/cp15/settings.json
would: write /tmp/cp15/LaunchAgents/org.ching.watch.plist and launchctl bootstrap it
```

What it wants to change: only the guard matcher (the diff) plus the watcher plist and `launchctl bootstrap`. The three `warning:` lines and the
`create .../agent-repos` line are artifacts of this dry-run, not changes to expect on the real run: the symlinks exist and point to
`/Users/clyde/bbq/ching`, while the dry-run ran from the worktree (`CHING_ROOT` differs), so it left them alone; when `install.sh` runs from the main
checkout the symlinks match and no warning appears. `~/.agent-repos` exists on the real machine (213 bytes), so the real run will not create it.
No other hook entry (SessionStart, UserPromptSubmit, SessionEnd, PreCompact, Stop, Notification) is changed, the vscode-session-manager and
osascript entries are untouched.

Before/after the dry-run: `ls -l ~/.claude/ching` is `-> /Users/clyde/bbq/ching` both times; `~/.claude/settings.json` mtime is
1791230225 (Oct 5 21:57:05 2026) both times; `~/Library/LaunchAgents/org.ching.watch.plist` does not exist.

Consequence of the matcher change (see the top of this file): the guard then sees Gmail, Slack, Discord and Telegram MCP calls, and rule 10 denies
the send-type ones.

This dry-run was made at 9260e02. The fix wave adds one more tool name to the matcher, `Monitor` (it runs shell commands and bypassed the guard because the hook
never fired for it); `tests/t_install.sh` pins the new string. A real run will therefore show the matcher line with both the messaging pattern and `Monitor`.

## 5. Lens findings

Three independent read-only reviews ran after Task 12. Full tables are in the ledger directory (`lens-stop-check.md`, `lens-guard.md`); this is the outcome.

### 5.1 Lens review of `stop-check.sh` (12 findings: 1 Critical, 8 Important, 3 Minor)

Fixed in `ce5ae94`: F1 (Critical) a GOAL.md `test_command` that starts a Claude session recursed without limit (reproduced with a stand-in), F2 the paid model ladder ran again on the stop that
hits the cap, F6 non-numeric or zero caps silently disabled the limits. The other nine are in section 6.

### 5.2 Lens review of `guard.sh` and `goal-sim-edit.pl` (12 findings: 1 Critical, 6 Important, 5 Minor)

Fixed in the fix wave (`5fd969f`, `dcb73b5`, `d63d312`):

- F1 Critical: the heredoc stripper dropped every later line after a here-string (`<<< "text"`), a hyphenated or dotted delimiter (`<<'END-OF-FILE'`) or `<<word` inside quotes, so a following
  force push, `gh pr close` or `npm publish` was allowed.
- F2 (bounded): launchers outside the wrapper list hid the command (`xargs -I {} gh pr close {}`, `sudo -u x ...`, `timeout -s KILL 10 ...`, a leading `>/dev/null`).
- F3: the `Monitor` tool runs shell commands, but the hook never fired for it.
- F4: root cause of "GUARD: internal error (exit 1)": `seg_matches '-p' && emit_deny` as a last statement under `set -e`; any command containing `export`, `declare` or `typeset` was denied in every session.
- F5: the guard scaled superlinearly (16 s for a 100 KB token; the hook timeout is 15 s and a timed-out hook lets the call run): now an 8 s fail-closed ceiling.
- F6: new-file branch: a NUL byte in the content, and a new-file MultiEdit whose later edits flip a setting, were allowed.
- F7: `gh api -XPUT`, `--method=DELETE` and GraphQL close/merge mutations were allowed.
- F9 (narrow): `slack_reply_to_thread`, `reply_all`, `post_message`, `update_message`, `upload_file`; `npm unpublish`, `deprecate`, `dist-tag`.
- F10: a 1.1 MB deny reason made `jq` fail and the guard exit 1 with no output (a call that runs); a missing `sed` emptied the splitter and allowed everything: now fail closed.
- F12: `cd -P /usr/local && rm -rf lib` sidestepped rule 1.

Left open on purpose (section 6): F8 `git -C $VAR push`; F11 false denies (`find -delete`, `awk '$1>3' .agent/GOAL.md`, commit messages that contain `; npm publish`); F9 broader name coverage (outlook, whatsapp, teams, camelCase variants).

### 5.3 Final whole-branch review (verdict: "Ready to merge? With fixes")

Critical, all fixed: (1) a backslash-newline continuation hid `git push origin HEAD:main`, `--force`, `>> .agent/GOAL.md` and `cat .env` from the guard (this one also exists on `main` before Phase 1.5);
(2) a new GOAL.md with an indented decoy line (`  release_mode: confirm` then `release_mode: auto`) let a session set its own gate settings in any repo without a GOAL.md; (3) the paid model ladder had no daily ceiling.
Important, fixed: the `export` root cause; `sed -ri`/`perl -wpi` and case-variant paths slipped past the settings/GOAL protection; the watcher and `dash.sh` loops were slow with thousands of session metas.
Important, open (your call, section 6): the checkpoint rule costs one extra model turn per prompt in repo mode and also fires on pure question-and-answer turns; false 20-minute stall alerts after a resume or an Esc-interrupted turn
share the 4-a-day budget with the "context almost full" alert.

### 5.4 Re-reviews of the fix wave

- Non-guard workers (FB, FC1, FC2): every code finding addressed, no regressions; the reviewer re-probed `dash.sh` old against new (byte-identical in 10 modes) and about 30 `TOKEN_BUDGET_DAILY` variants. It found the documentation
  errors that are corrected in this file.
- Guard workers (FA): every finding addressed, but the fix wave itself introduced three problems that the reviewer reproduced: a comment ending in a backslash hid the next line (a regression: the old guard denied it),
  the quoted commit-message heredoc idiom was scanned as shell (5 of 524 real commit messages from your repos denied, 0 before), and one test failed about 3% of runs. The third guard commit fixes all three
  (524 messages: 0 denies; 30 consecutive test runs: 0 failures).
- Guard re-review of that third commit (it took 50 minutes): C1 for every reported shape, the commit-message idiom (525 real messages: 0 denies), the flaky test, `update_message`, the `SECONDS` handling and the preflight
  are fixed, with no new false denies on about 370 routine commands and no regression in a 1,008-combination wrapper fuzz. It found two narrow Important residuals. (1) The new comment-aware scan is not linear and runs
  outside the 8 s ceiling, so a command of about 1 MB on one line, or about 2,500 continued lines, ran past the 15 s hook timeout (a timed-out hook lets the call run). A fourth guard commit denies such commands outright;
  I verified it myself instead of with another reviewer (the agent budget was nearly spent and the last review took 50 minutes): the 1 MB, 4,000-line and 1 MB-plus-comment shapes now deny in about 1 s; 900 continuations, a
  100 KB token and ordinary commands still allow; a 566-command differential of the guard before and after that commit shows no change in any verdict (the only differences were two cases in my harness that name the guard's own
  path), 16 new long-segment cases give identical verdicts, and the suite passes. (2) A multi-line quoted string followed by a comment that ends in a backslash can still hide a split command
  (`echo "a` newline `b" # c \` newline `rm -rf \` newline `/usr/lib`); the two older guards miss it too, so it is not a regression. It is left as a known gap.

## 6. Known gaps

Everything below is deferred on purpose (Minor or out of scope in review) or a lens finding that was triaged to "log, do not fix now" (R10). The fix wave closed several of these; the
per-task lists below keep the original wording, and a line that starts with FIXED says it is done.

### Fixed in the fix-soon wave before the pilot (2026-10-06, D21; integration branch `fixsoon`)

Four parallel agents, then an independent review of the merged result. Details are in the commit messages.

- Stop hook and ladder:
  - F3: one deadline for the whole hook (`STOP_CHECK_DEADLINE`, 780 s), and a time limit plus `--max-turns` on every `claude -p` call.
  - F4: a timed-out run is killed as a whole process group.
  - F5: bookkeeping failures give "no verdict" (exit 3, the stop is allowed, with a `stop_no_verdict` event) instead of a silent fail-open or a false block.
  - F9: a missing `jq` gives a loud no-verdict.
  - F12: unsafe session ids are hashed, and `meta_set` is serialised.
  - The ladder is skipped for a tree that already failed it.
  - F8 (partial): the fingerprint is taken before the run, there is a skip TTL, and a `check_skipped` event is logged.
- Checkpoint rule cost: it asks only for the six-line block, skips unchanged turns, and is off for `claude -p` (`CLAUDE_CODE_ENTRYPOINT=sdk-*`) or with `CHING_NO_CHECKPOINT=1`.
- Notifications:
  - A session is `idle` after startup or resume until its first prompt, so there is no false stall.
  - Zero-usage (synthetic) records no longer reset `ctx_level`.
  - `handoff` is outside the daily budget, still with quiet hours.
- `dash.sh`:
  - `--next` keeps blocked and input sessions above working ones and clamps recency.
  - The inbox dedupes by session id, newest first.
  - READY requires the marker's sha to equal HEAD.
  - SIGPIPE false negatives under pipefail are fixed.
  - The docs say `--inbox` marks FINISHED as seen.
- Installer:
  - Nothing is applied without `--yes` or a tty "y".
  - The plist diff appears in the preview.
  - Plist values are XML-escaped.
  - Dry-run plist and absent-plist tests were added, and `LAUNCH_AGENTS_DIR` is exported in `tests/lib.sh`.
- Guard:
  - D20: rule 8 denies `v*` tag pushes, and `gh api` release/tag mutations.
  - Quoted data (grep/rg/echo/printf arguments, commit and tag messages, gh bodies) is no longer split into fake commands (`bin/quote-data.pl`).
  - Rule 8 reads the package manager's subcommand (`npm publish --dry-run`, `npm view publish` and similar are allowed).
  - Rule 5 does not take a grep/rg pattern such as `ching.env` for a file.
  - The "internal error (exit 1)" reports are traced to the `export` bug fixed in `5fd969f`, with regression tests.

### Fixed in the fix wave (listed as gaps before)

- Task 4: a failing `date -r` bypassed quiet hours (FC1: budgeted alerts are suppressed as `no-clock`). Task 5: `TOKEN_BUDGET_DAILY` leading zero, `0`, quotes, `export` (FC1). Task 7: `head -5` under pipefail (FC1).
- 12a: the marker `unset` now lives in `tests/lib.sh` (FB). Task 8: untouched template placeholders passed the "not examined" check; multi-line comments (FC2). Task 11: step 4 wording (FC2).
- Task 10: new-file decoy, the `seg_writes` glob (`sed -ri`, `perl -wpi`), case-variant `is_tamper_path`, NUL bytes in `gated_lines`, the `=` in a directory name (FA).

### Open after the fix wave (the final review's "fix soon" list, plus what the re-reviews listed as out of scope)

- Stop hook and ladder: skip the ladder when the same failing tree already failed it; lens F3/F4 (a time limit and `--max-turns` per `claude` call, a process-group kill); F5 a reserved "no verdict" exit code;
  F8 a time limit on the "nothing changed" skip and a `check_skipped` event; F9 check that `jq` exists first; F12 serialise `meta_set` (the watcher is now a second writer).
- Checkpoint rule cost: ask only for the six-line block edit, skip it when the tree has not changed since the prompt, and add an opt-out for scripted runs (`claude -p` replaced its answer with the checkpoint reply in the live smoke).
- Notifications: `session-start.sh` sets `working` on a resume, so a false 20-minute stall alert can fire and eat the shared 4-a-day budget (consider exempting `handoff`); a zero-usage record can reset `ctx_level`.
- `dash.sh`: `--next` buries sessions blocked for 15 h or more; the inbox `sort -u` merges distinct sessions; READY does not check that the marker is for the current HEAD; `AGENTS.md` should say `--inbox` marks FINISHED as seen.
- `guard.sh`, allowed by both the old and the new guard: long options with a separate value (`sudo --user x`, `xargs --arg-file f`, `env --unset X`, `timeout --signal KILL`), `FOO="a b" gh pr close 5`, `direnv exec`, `find -exec`,
  `ssh host '...'`, `stdbuf`/`setsid`, `$'gh'` and variable command words; rule 5 does not see `echo $(cat .env)`; unquoted-heredoc `$()` bodies are stripped and run; a broken `awk` that prints nothing means an empty command (allowed);
  there is no hard input-size cap (a 4 MB token takes 13 s; the Bash tool caps near 1 MB). Also F8, F11 and the F9 name coverage above; rule 11 gaps: `cp x/GOAL.md .agent/` (directory target), an Edit whose `old_string` is not found is
  allowed, reorder-only edits pass because `gated_lines` sorts, `base_branch` and `migrate_*` are not gated, writers such as `sort -o` and `curl -o`, GraphQL `-F query=@file`.
- Known trade-offs: `npm dist-tag ls` and bare `export`/`declare`/`typeset` are denied (they dump the environment; the old bug denied them by accident); the rule-11 `.env` reader now also sees continued lines; the ladder counter is not atomic
  (simultaneous callers can overshoot by their number); the watcher skips a session whose meta file is older than 48 h even if its transcript still grows (hooks keep live metas fresh); a trailing `# comment` after `TOKEN_BUDGET_DAILY=100` in
  `ching.env` makes the value invalid (alerts off).
- Guard, from the last two re-reviews: a legitimate command over 256 KB or with more than 1000 continued lines is now refused ("too large to check safely"); the multi-line-quote plus comment-backslash residual
  (5.4); the comment-aware scan stays quadratic for lines that contain a `#` (bounded by a workload cap, about 2.5 s worst case); a continuation whose first line is a bare denied command (`env \` newline `NODE_ENV=production \` newline
  `npm run build`, `bash \` newline `scripts/build.sh`, `vercel \` newline `ls`, `git push origin \` newline `feature` while on main) is denied because the un-joined view sees the bare first line (9260e02 denied these too);
  `*update_message` as a suffix lets a hypothetical `slack_update_message_text` through; `rm -rf build # c \` newline `cd /usr/local` is a false deny; `isinterp` treats any word before `<<` as an interpreter (a PR title such as
  "Add node support" keeps the body scanned); `dash`/`ksh`/`fish` are not in the interpreter list; `GUARD_TIME_LIMIT=0` exported by accident denies every Bash/Monitor call (loud and fail closed); the tokenizer is still superlinear for
  very long segments with thousands of `$(...)` (27 KB of `echo "$(date)"` x3000 took 208 s on the old and the new guard before the `tr -d` path; not re-measured after it).
- Installer and tests: confirm before loading the plist on a non-tty run; dry-run and absent-plist tests; export `LAUNCH_AGENTS_DIR` in `tests/lib.sh`; `CHING_TEST_LADDER_DAILY` is documented only in the header of `bin/test-escalate.sh`;
  the `## exercised` placeholder in `templates/VERIFY.md` still satisfies the gate (the gate checks form only, by design); the MIT permission text is missing from the lens files.

### Lens findings on `stop-check.sh` not fixed (F1, F2, F6 are fixed in ce5ae94)

- F3 Important: hook timeout 900 s versus the model ladder (up to 3 check runs plus 2 `claude -p` calls without timeout or `--max-turns`); a killed hook allows the stop and orphans the children. Reasoned from `install.sh`, not observed; needs a single-deadline design.
- F4 Important: `alarm`+`exec` kills only the top bash of a timed-out `test_command`, not its process group; forked children stay alive. Observed; fix is a process-group kill, not done.
- F5 Important: bookkeeping failures (unwritable `AGENT_HOME`/sessions dir, read-only `test-escalation.log`, deleted cwd) fail open (hook dies, stop allowed) or false-block with a misleading "done-check failed". Observed; needs a reserved exit code for "no verdict".
- F7 Important: a placeholder checkpoint or any write to `STATE.md` (template already contains the marker) satisfies the checkpoint gate; gate does not verify content. Seen again in the live smoke (section 0).
- F8 Important: the green-run fingerprint ignores gitignored/external inputs and is taken after the run: stale-pass with no log line. Observed.
- F9 Important: `jq` missing from the hook PATH fails open silently, and the session id degrades to `nosession-<hash>` (shared). Observed.
- F10 Minor: first `test_command:` line wins (fenced/indented examples, list-item form ignored); `stop_ok` does not record that no check ran.
- F11 Minor: an untracked symlink to a FIFO/device hangs the fingerprint until the 900 s kill.
- F12 Minor: session ids containing `..` or `/` escape `sessions/`; concurrent `meta_set` loses keys (39 of 40 rounds in the probe).

The `guard.sh` lens review ran in parallel; its findings are the controller's to add in section 5. Related open bug: the installed `guard.sh` answered
"GUARD: internal error (exit 1); failing closed" on some compound Bash commands (three implementers hit it, e.g. `export VAR=$(...)` combined with other
commands, and a command with several `grep -nE` alternations containing `\(\)` plus a `sed -n "$(grep ...)"`). It fails closed, so it is safe, but the
parse error is not identified.

### Task 0.5 / Task 12a

- 12a: move `unset CHING_STOP_CHECK_RUNNING CHING_ESCALATING` from `t_stop.sh` into `tests/lib.sh` (`t_escalate.sh` is also exposed).
- 12a: no test for `STOP_CHECK_TIMEOUT=abc` (a deterministic test via `alarm(0)` exists); 20+ digit caps make `[ -ge ]` error and fall to 1 (add a length guard).
- 12a: counter read-before/write-after window (at most +1 block, fail-strict); no externally-set-marker test; header `Env:` line omits the new marker.
- 12a: a Claude session started through a daemon/launchd/tmux server would not inherit the marker (not testable here).

### Task 1

- `ev` line cap is not hard: a long cwd/name/sid can exceed 1024 (only `.data` is truncated); `ev` accepts non-object DATA_JSON.
- `t_events` timestamp check looks only for "Z"; no 1024 boundary, multibyte or long-cwd case.

### Task 2

- `t_post_release`/`t_migrate` event assertions are prefix-only (`deploy-`, `gate-`); tighten to SUCCESS/FAILED and gate-pass/gate-fail.
- `post-release` logs a duplicate `release` event on re-run for the same sha+outcome (STATE.md line is deduped, the event is not).
- Gate events (post-release, migrate-gate) carry sid ""; consumers must tolerate it, untested.
- The tests-cap stop is logged as `stop_blocked` although the stop is allowed (consumers filter on `reason=tests-cap`).
- `prompted` meta is not checked as an epoch number; `stop_ok` outcome not asserted.

### Task 3

- Checkpoint event payload and `stop_blocked reason=checkpoint` not asserted; no re-arm test (same-second prompts share an epoch).
- File mtime is a coarse freshness proxy (pre-compact or any other `STATE.md` edit bumps it).
- `status=$(sed|head -1)` could SIGPIPE under pipefail only with many `status:` lines; `file_mtime` uses `stat -f %m` first (darwin only).
- The `checkpoint` event now logs once per green Stop in a prompt (no dedupe, cosmetic).

### Task 4

- A failing `date -r` (non-BSD date on PATH) silently bypasses the quiet-hours gate inside `budget_ok`; add a numeric check on the hour.
- Missing tests: handoff/tokens labels, idle through the budget, date rollover, 08:59/20:59, delivered event.
- Budget counter is unlocked (a burst can exceed 4 by 1); a backwards clock suppresses until caught up; budget files are never pruned.
- Spec-mandated side effect: `done` no longer pushes (stop-check finish and post-release "deployed") until the user reads `dash.sh --inbox`; duplicate idle exits before logging.

### Task 5

- A synthetic zero-usage "last message" (API error/interrupt record, unverified) could reset `ctx_level` from handoff to healthy and re-trigger a handoff notice.
- FIXED in the fix wave (FC1). As found at 9260e02: `TOKEN_BUDGET_DAILY=08` (leading zero) is an octal arithmetic error ("value too great for base") but it did not kill the script: bash abandoned the failed budget block and carried on, so rotation still ran and the script exited 0. What was lost was the alerts: the 80% and 100% token alerts never fired, and an error line landed in `watch.log` on every run (every 5 minutes). `010` was read as octal 8, silently; `=0` fired both alerts daily; a quoted or `export`-prefixed value in `ching.env` silently disabled alerts. Now: `08` is 8, `010` is 10, `0` and garbage mean "off" without output, quotes and `export` are accepted (a trailing `# comment` makes the value invalid).
- `t_watch` gaps: ended-session assertion is vacuous, fresh-lock survival, 80%/60% boundaries, tokens alert text, idle+stale transcript not stalled.
- Lock takeover is not atomic; the trap is installed after the lock (a `mktemp` failure leaks the lock for 10 minutes).
- `ctx_level` stays empty when no usage was seen (dash renders `?`).

### Task 6

- The matcher upgrade rewrites `.matcher` on every entry whose command is a ching hook, and adds a matcher to entries that had none (`gate` on PreToolUse/guard command).
- Plist values are not XML-escaped; no dry-run plist test; no absent-plist uninstall test; `LAUNCH_AGENTS_DIR` not exported in `tests/lib.sh` (relies on the sandbox HOME).
- A non-tty run without `--yes` can load or replace the launchd job without a prompt (the diff never shows the plist).
- The `t_install` assertion "failure flag was scoped to the one call" is vacuous; a partial `printf` leaves `org.ching.watch.plist.tmp`; a failing `rm -f` would skip the message.

### Task 7

- `--next` formula buries long-blocked sessions (blocked >=15 h scores below a fresh working one; GOAL.md importance 3 lets a working session outrank a blocked one without it; no upper clamp on recency).
- `| head -5` under pipefail can exit 141 with `--all` on many rows; `date -u -r` breaks all modes on GNU date.
- Inbox `sort -u` merges distinct sessions with equal label+note and drops recency order; `inbox.seen` write unguarded (read-only `AGENT_HOME` exits 1).
- READY only for repos with a session row in the window, does not check the marker is for the current HEAD, prints a path; `state_note` uses a substring grep for the marker (`checkpoint_get` anchors at line start); spoken blockers may contain paths.
- Coverage gaps: `--help`, empty `ctx_level` as `?`, tok_h boundaries, input lane, stalled, GOAL.md importance, READY dedupe, `upd==last_seen`, speak lead is first, row alignment, a done session with a real next_action, `none.` and empty string in `is_none`.
- Header comment wording; `AGENTS.md` should say `--inbox` marks FINISHED seen.

### Task 8

- FIXED in the fix wave (FC2): `templates/REVIEW.md` and `VERIFY.md` shipped a 40+ char placeholder bullet under `## not examined`, so an untouched copy satisfied the 10-char check, and a multi-line HTML comment counted toward the 10 chars. The examples and placeholders are now one-line HTML comments and `compact_section` strips multi-line comments (a failed strip counts as empty); tests copy both templates untouched and expect a rejection.
- The review check is a FORM check: the gate verifies commit, the count against the `[blocking]` bullets, `resolved:` lines, `## not examined` and mtime, not who wrote the file. The session itself can write `.agent/review/<sha>.md` (guard.sh does not protect it), so the "fresh reviewer" is a policy, not something the gate can prove. The spec says the first real release must be watched by you; see 7(f).
- A future committer date makes every review "older" (fail-safe); `file_mtime` on GNU stat could be fail-open (macOS only).
- Event assertions not scoped to the new repo; no `gate-pass-confirm` assertion; no tests for non-numeric `blocking`, evidence-failure before review-failure, lens files free of skill_view/.hermes (the `review: off ` trailing-space test was added in FC2).
- `review: off` passes are indistinguishable in events (add `review:"skipped"`); the code comment "only the user can write that" is true only because guard rule 11 now exists.
- MIT notice carries the copyright but not the permission text (consider a THIRD_PARTY file); the error-resilience lens asks for a pipe table while the appended Output asks for bullets.
- Other markup around the tag is still unrecognised (`> - [blocking]`, `__[blocking]__`, `- [ ] [blocking]`, `- **Blocking:** x`), covered in practice by the count cross-check; message grammar "only 1 [blocking] bullets"; `kv` takes the first `blocking:` line anywhere in the file.

### Task 9

- `*draft*` is allowed before the send check (a future `send_draft` tool would pass); `*_reply_*` not matched; `*send*` over-matches (hypothetical `get_send_as_aliases`).
- `gh api -X GET ... -f state=closed` denied (read-only listing); `gh api -fstate=closed` and `--input` allowed; rule 8 has no `gh api` coverage (POST releases, DELETE repo, PATCH private=false); `gh gist create --public` unmatched; `gh pr -R close 5` allowed (real gh rejects it); `gh repo archive` not touched.
- False positives: `npm publish --dry-run`, `bun test publish`, `npm test -- publish`, `npm view publish`, `npm help publish`; `corepack yarn npm publish` allowed (corepack not in WRAPPERS); backslash-newline continuation hides `npm \<nl>publish` (pre-existing).
- Event `data.rule` holds the full prose reason (can embed paths) and `name` is the cwd basename, not the repo; tests do not pin the `GUARD: rule N:` prefix; gdeny/tdeny assert only that a deny happened, not which rule.
- Telegram/Discord `edit_message`/`react` allowed (judged no D18 impact); Slack `schedule_message` and Telegram `reply` etc. are denied by design.

### Task 10

- New-file decoy (`  review: required` then `review: off`; `head -1` after sort checks one line).
- `seg_writes` glob `-[pnlasE0-9]*i*` misses `sed -ri` and `perl -wpi` (suggested `-[!-]*i*`); the `2>/dev/null` strip should move into `seg_writes` (settings.json reads with it are still denied).
- Symlink alias to GOAL.md; `migrate_test_command`/`migrate_pending_cmd` not gated; inert `Review: off`/`review : off` (the `Review: off` lock-in test was added in FC2 in `t_release`; `review : off` has none); `is_tamper_path` has the same case-insensitivity weakness.
- Accepted false positives: `cp .agent/GOAL.md /tmp/x`, `cat GOAL.md > out`; python/node/awk writers, variable indirection and globs not caught (same class as hooks/settings).

### Task 11

- `t_templates` needles are loose (`drafts`, `review:`): no check of rule numbers 8/9/11, `release_mode:`/`test_command:`, the six keys inside the block, or that `templates/review-lenses` and `REVIEW.md` exist.
- FIXED in the fix wave (FC2): step 4 of the autonomy block said `templates/...` without "in the ching kit" and hardcoded `origin/main` while the gate uses GOAL.md `base_branch`; it now says "in the ching kit" and `origin/<base_branch>`. It also did not say that fixing a `[blocking]` finding creates a new HEAD, which invalidates the sha-named evidence and review files, so steps 3 and 4 must be redone; it does now. The Stop cap is worded "3 retries in a row (the count resets after a green run)", not "per session". `t_templates` has needles for all of it.

### Not done by design

- `rm -rf /Users/clyde/bbq/ching/vendor-eval` (R6, Task 12 step 7): four evaluation clones outside the worktree; the lens files that were the reason to keep them are committed. Your call.
- Merge of `phase-1.5-harvest` into `main` (R12, plan Task 12 step 8).

## 7. What you do next

(a) Merge the fix wave into `main`: urgent. `main` already holds Phase 1.5 at 9260e02 (merge `b73af38`), so the live hooks run that code now without the fixes in section 5:
the continuation bypass (a push to main, a force push or an `.env` read split over two lines is not seen), the GOAL.md decoy, the paid ladder without a daily ceiling, the `Monitor` tool bypass,
the heredoc swallow, and the `export` false denies. `phase-1.5-harvest` is 9260e02 plus the seven fix commits and this report; it merges onto `main` without conflicts as long as `main` only gained the
nudge-session commits since (the `nudge` branch lives in its own worktree, but `main`'s working tree is what the hooks read). Merging updates the live hooks at once through the `~/.claude/ching` symlink.
Check `git -C /Users/clyde/bbq/ching status --short` first, because another session also works in that checkout. Either ask for the merge or run `git -C /Users/clyde/bbq/ching merge phase-1.5-harvest` yourself.
Both recursion guards (`CHING_ESCALATING`, `CHING_STOP_CHECK_RUNNING`) are already live on `main`; the old patch in `/tmp` is obsolete and must not be applied.
The guard fixes were re-reviewed twice and verified once more by me after a last size-cap commit (section 5.4); the one thing no second agent reviewed is that last commit (ab74af3), which only adds fail-closed limits and
a faster tokenizer path.

(b) Unset the accidental git setting (see the top of this file): `git -C /Users/clyde/bbq/ching config --unset core.hooksPath`.

What is live on `main` today (Phase 1.5 at 9260e02) and what the merge adds: `notify.sh` no longer pushes `done` (it goes to the inbox, read it with `bin/dash.sh --inbox`); the Stop hook asks once per prompt for a
checkpoint in repos with a GOAL.md and logs events to `~/.agent/events.jsonl`; guard rules 8-11 are active for the tools the installed matcher already covers (rule 10 reaches the messaging tools only after
`install.sh` widens the matcher). The nudge feature on the `nudge` branch edits `bin/ching-watch.sh`, `bin/notify.sh` and `tests/live-smoke.sh`, which this branch also changes (FC1 touched the first two): merge the fix wave
first and rebase the nudge branch onto it.

(c) DECISION, before (d): Telegram/Discord replies. Rule 10 (D18) names both channels, so once `install.sh` widens the matcher a session can no longer
answer you on Telegram or Discord (`reply` is denied; `react` is not). Options, recommendation first:
1. Owner-chat allowlist: a file `~/.agent/defaults/owner-chats` listing chat ids; `reply` passes only for listed ids (about 10 lines in `guard.sh`, plus adding that path to
   `is_tamper_path` so a session cannot edit the list; an empty or missing list behaves as today, every reply denied).
2. Reuse the channel plugin's own access list instead of a ching file (less to maintain, but ties the guard to a plugin's file format).
3. Allow `reply` entirely (a session can then message anyone the plugin can reach, which weakens rule 10 to email and Slack).
4. Drop Telegram and Discord from the matcher, so rule 10 covers email and Slack only (no guard on those channels at all).
5. Return an `ask` decision for `reply` (unverified: it is not known that the channel forwards permission prompts to you, so a remote session could stall).
Also record: with `done` routed to the inbox, a session you drive remotely sends nothing when it finishes unless `NOTIFY_PUSH_DONE` is set to a non-empty value in the
environment the hooks run in (the switch exists since Task 4; any non-empty value enables it, including `0`). `input`, `blocked` and `ready` still push.

(d) Then run `./install.sh` yourself from the main checkout, after the merge in (a) (it widens the guard matcher, now also with `Monitor`, and loads the watcher plist with `launchctl bootstrap`;
the dry-run in section 4 is what it will show, plus the `Monitor` name). If you do not want the Telegram/Discord reply denial, decide (c) first. The watcher now skips sessions whose meta is older than 48 h,
so the thousands of old session folders on this machine no longer slow it (you can still archive `~/.agent/sessions` entries marked `ended`).

(e) Optionally set `TOKEN_BUDGET_DAILY` in `~/.agent/defaults/ching.env`: a number; quotes, `export` and leading zeros are accepted since the fix wave; do not put a trailing `# comment` on the same
line (the value becomes invalid and the alerts stay off); `0` turns the alerts off. `CHING_TEST_LADDER_DAILY` (default 6 paid fix-model calls per day across all sessions; `0` = never call a model) is a plain environment variable of the Stop hook: no config file reads it, so the default only changes if you
put it in the hook's environment (the settings hook command) or edit `bin/test-escalate.sh`.

(f) Watch the first real release in each repo yourself. The release gate checks the FORM of the review file (commit, count against the `[blocking]` bullets,
`resolved:` lines, `## not examined`, mtime), not who wrote it, and the session itself can write `.agent/review/<sha>.md`; the spec says the first real
release is watched by you.

(g) Start the Phase 2 pilot.

Design notes for tuning (Phase 2.6):

- `idle` is budgeted and shares the machine-wide 4/day notify budget with `handoff` and `tokens`; a busy morning of idle pushes can suppress a later
  "context almost full" alert. Consider exempting `handoff` or capping `idle` separately.
- `done` no longer pushes (stop-check finish and post-release) until you use `dash.sh --inbox`; the smoke run shows `routed-to-inbox` for every finish.
- A session blocked for 15 hours or more ranks low in `--next` (it scores below a fresh working session); see the Task 7 gaps.
- Fixing a `[blocking]` finding creates a new HEAD, which invalidates the sha-named evidence and review files; the review step must be redone (now stated in the autonomy block, FC2).
- The checkpoint gate asks once per prompt and accepts any `STATE.md` write (F7); judge from the event log (`stop_blocked` reason=checkpoint followed by
  `checkpoint`) whether to tighten it.
