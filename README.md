# Ching

Ching keeps track of every Claude Code session on this Mac. It runs as a set of bash hooks plus one launchd job, in any folder, repo or not. It does four jobs:

- **Remembers where each session is.** Every session gets a `STATE.md` and `NEXT.md`, which are injected when the session starts. A fresh or resumed session knows the goal, what's done and what's next without you re-explaining.
- **Shows everything at a glance.** One command lists every session, what it's doing, how full its context is, and what needs you.
- **Interrupts you only when it matters.** Blocked and waiting-for-input sessions notify you right away. Everything else waits in an inbox, under a daily budget and outside quiet hours.
- **Stops the dangerous things.** A guard hook blocks force-pushes, destructive deletes, reading secrets, outbound messages, and sessions editing their own hooks or settings. Plain pushes and merges to `main` stay allowed (D24).

It also checks the repos for work you could lose, can talk (a voice dispatcher, see below), and records events for the pilot metrics and the planned learning loop (Phase 6).

Claude Code stays the only engine. Ching doesn't run models of its own, except an optional Haiku/Sonnet step when a stop check fails (`test-escalate.sh`).

## Install, update, remove

```sh
cd ~/bbq/ching
./install.sh --dry-run      # shows the settings.json and launchd diff, changes nothing
./install.sh                # asks before applying; --yes applies without asking
./install.sh --install-dispatcher --yes   # optional: the voice dispatcher's own folder
./install.sh --uninstall    # removes Ching's hook entries and the launchd job
```

`install.sh` is idempotent. It backs up `~/.claude/settings.json` before writing and only adds entries; it never removes your own hooks. A second run should say `nothing to do`.

What it installs:
- **The link:** `~/.claude/ching`, pointing to this folder.
- **The hooks:** SessionStart, UserPromptSubmit, Stop, PreCompact, Notification, SessionEnd, and the PreToolUse guard.
- **The slash commands:** `/handoff`, `/next` and `/dash`.
- **The launchd job:** `org.ching.watch`, which runs `bin/ching-watch.sh` every 5 minutes.

After pulling new commits, run `./install.sh --dry-run` to see whether anything needs reapplying. Most changes need nothing, because the hooks point at this folder.

**Second Mac:** clone this repo to `~/bbq/ching` and run `./install.sh`. State in `~/.agent/` is per machine and isn't synced.

## Daily use

### See what's going on

| Command | What you get |
|---|---|
| `~/.claude/ching/bin/dash.sh` | One line per session: state, age, context (● healthy, ◐ watch, ○ hand off now), today's tokens, folder, blocker. Ends with a `sync:` line when a repo needs attention, and warns above 5 active sessions. |
| `dash.sh --inbox` | **NEEDS YOU**: blocked or waiting for input. **READY**: release gate passed (only with the push gate on). **FINISHED**: done since you last looked; looking marks them as seen. **SYNC**: repos with work you could lose. |
| `dash.sh --next` | The top 5 sessions to attend to (urgency × importance × recency), each with its next action. |
| `dash.sh --speak` | The short spoken summary. |
| `/dash` | The same from inside any session. It speaks by default; `/dash --text`, `--inbox` and `--next` print instead. |

### Hand over and pick up

- **`/handoff`:** writes the session's `STATE.md` checkpoint and a self-contained `NEXT.md` from facts (git, tests), so any fresh session can continue. Run it before `/clear`, or when the watcher says context is above 80%.
- **`/next`:** in a new session, reads `GOAL.md`/`STATE.md`/`NEXT.md`, checks them against the repo, and carries on without asking.

State lives in the repo's `.agent/` when the repo has a `.agent/GOAL.md`. Otherwise it's in `~/.agent/sessions/<session id>/`. The SessionStart message names the folder.

### Notifications

| Kind | When it reaches you |
|---|---|
| `input`, `blocked`, `ready` | Always, immediately. |
| `done` | Not pushed. It goes to the inbox (`NOTIFY_PUSH_DONE=1` restores the push). |
| Everything else (waiting, stall, handoff, tokens, sync) | Only 09:00–21:00, at most 4 a day, and 45 minutes apart per session. Suppressed ones are logged and show in the inbox. |

The watcher also detects stalled sessions (no progress for 20 minutes) and context pressure. It gives sessions waiting on you one banner and, once you're at the Mac, one spoken note through the local Kokoro voice.

### The sync check: work you could lose

`bin/sync-check.sh` runs from the watcher every 6 hours, or on demand. For every repo Ching has seen, it reports:
- unpushed commits;
- commits you're behind on;
- uncommitted files;
- worktrees whose branch is already merged;
- old stashes.

Each finding comes with its age. It is **read-only**: it only fetches, and never pushes, pulls, merges or deletes.

Where you see it:
- **The dash views:** the `sync:` line in `dash.sh` and the SYNC lane in `dash.sh --inbox`.
- **The full snapshot:** `~/.agent/sync-check.md`.
- **A notification:** at most one banner a day, and only when something is older than 24 hours. Being behind origin alone doesn't trigger it; `SYNC_BANNER_INCLUDE_BEHIND=1` changes that.

To add a repo it hasn't seen yet, list it in `~/.agent-repos`, one path per line.

### Pilot metrics

`bin/metrics.sh [--days N | --day YYYY-MM-DD] [--json]` builds the PLAN section 7 scoreboard from the event log:
- sessions, and questions they asked you;
- notifications delivered vs suppressed;
- stalls and handoffs;
- release-gate results.

Test and sandbox sessions are left out. The footer says which numbers are exact and which are proxies.

## The guard

`bin/guard.sh` runs before Bash, file and selected MCP tool calls in every session, including `bypassPermissions` sessions. A denial tells the session what to do instead.

**Always denied:**
- force pushes and deleting protected branches;
- `v*` tag pushes and `--no-verify`;
- `rm -rf` outside the current repo or `/tmp`, and recursive deletes with unresolved variables;
- reading `.env` files;
- Supabase writes outside the migration ledger;
- publishing packages;
- `vercel` and `gh workflow run`;
- closing other people's issues or PRs;
- outbound Gmail/Slack/Discord/Telegram sends;
- edits to hooks, settings, tokens, `~/.agent/config` and the gate fields in `GOAL.md`.

Git aliases, `-c alias.` and npm/pnpm/yarn abbreviations are resolved first, so they can't sneak past.

**The push switch (D24).** `push_gate` in `~/.agent/config` is **off by default**: agents push and merge to `main` freely. To require the release gate again, write `push_gate=on` there. Sessions can't edit that file; you have to.

**Optional per-repo gates.** These apply when the repo has `.agent/GOAL.md`; copy `templates/GOAL.md` to start one:
- **`test_command`:** `stop-check.sh` runs it before a session may stop. It blocks up to 3 times while it fails, then lets the session end and tells you.
- **`release_mode` / `review`:** used by `release-gate.sh` only when `push_gate=on`.
- **Migrations:** `migrate-gate.sh` lints migrations, letting additive ones through and blocking destructive ones.

Only you change `test_command`, `release_mode` and `review`.

To check the guard is live, ask a session to force-push in a throwaway repo under `/tmp`. It must be denied.

## Voice

Status: **built and gate-tested, never heard.** No audio has been played yet. Your first run is in `MANUAL-STEPS.md` under "2026-10-16".

- **Level A:** `/dash` says the status aloud through VoiceMode, using local Whisper and Kokoro, so no audio leaves the Mac. `docs/voice.md` covers Claude Code's built-in `/voice` dictation as a fallback. That one sends audio to Anthropic, which goes against D5, so whether to use it is your call.
- **Level B, the dispatcher:** start it with `~/.claude/ching/dispatcher/launch.sh`. It's a slim Haiku session that only:
  - reads status (`dash.sh`) and session `STATE.md`/`NEXT.md`;
  - lists sessions and relays messages to them;
  - logs each relay;
  - speaks.

  Everything else is denied by `dispatcher/tool-gate.sh`, and it refuses to start if that gate is missing. It reads risky instructions back before relaying them. Acceptance test: `docs/dispatcher-acceptance.md`.

## Where things live

| Path | What |
|---|---|
| `~/.agent/sessions/<id>/` | Per-session `meta`, `STATE.md`, `NEXT.md` |
| `~/.agent/events.jsonl` | The event log: one line per hook, gate, notification and sync result. Mode 0600, local only, rotated at 20 MiB. |
| `~/.agent/sync-check.md` | Latest sync snapshot |
| `~/.agent/config` | Machine switches (`push_gate`) |
| `~/.agent/notify.log`, `watch.log` | Delivery log and watcher errors. An empty `watch.log` means no errors. |
| `~/.agent/dispatcher/` | The dispatcher's own settings and MCP config |
| `~/.agent/proposals/` | Phase 6 output, when it is built. Proposals only, never applied automatically. |
| `~/.agent-repos` | Extra repos for `dash.sh` and the sync check |

## Checking it works

```sh
cd ~/bbq/ching
bash tests/run.sh                  # full suite (run it from here, not from a /tmp checkout)
bash tests/live-watch.sh           # read-only: launchd job loaded, events flowing
bash tests/live-smoke.sh           # daytime only: section 4 makes sound, 0-2 call claude -p
./install.sh --dry-run             # "nothing to do" means settings match this checkout
```

shellcheck runs inside the suite (`t_lint`). If it isn't on your PATH, the suite looks for it in `/tmp/sc-venv`.

## Status and what's left

On 2026-10-16:
- Phases 0–1.6 are built and installed.
- Of the pilot (Phase 2), tasks 2.1, 2.2 and the sync check (2.7) are done.
- Voice levels A and B (Phases 3–4) are built.
- Rollout 5.3 is done; 5.1/5.2 were dropped by D24.

`PLAN.md` §6 has the boxes. The open work:

- **Needs you, in one sitting.** `MANUAL-STEPS.md`, "2026-10-16", about 45 minutes:
  - pick the voice speed pass line;
  - hear `/dash`;
  - run the spoken dispatcher test (4.3), which also measures 0.6;
  - run the two-voices test (0.7).
- **Pilot (2.3–2.6):** a few days of normal use, then review `bin/metrics.sh` together and tune the notification budget, stall threshold and context levels.
- **Phase 6, the learning loop:** spec drafted in `docs/superpowers/specs/2026-10-16-phase6-learning-loop-design.md`, with 10 questions for you. Building waits for pilot data (D16).
- **Known gaps:**
  - the guard doesn't see an alias written straight into a git config file, or `git $var`;
  - `reset`/`rebase`/`--amend` on `main` aren't blocked, only force-pushing the result is;
  - F10 and F11 are still open (CHECKPOINT-1.5 §6);
  - `core.hooksPath` in this repo points at a missing `.githooks`, so no git hook runs here.

## Map of the docs

- `PLAN.md`: design and the step-by-step plan with checkboxes.
- `DECISIONS.md`: decisions D10 onward, newest first (D1–D9 are in `PLAN.md`).
- `PHASE0-RESULTS.md`: what was tested before building.
- `CHECKPOINT-1.md`, `CHECKPOINT-1.5.md`: review reports.
- `MANUAL-STEPS.md`: steps only you can do.
- `ching-functions.md`: plain-language tour of what Ching borrowed and why.
- `docs/`: voice, dispatcher acceptance, live checks, specs and plans.
