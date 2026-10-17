# Kaching

Kaching keeps track of every Claude Code session on this Mac. It runs as a set of bash hooks plus one launchd job, in any folder, repo or not. It does four jobs:

- **Remembers where each session is.** Every session gets a `STATE.md` and `NEXT.md`, which are injected when the session starts. A fresh or resumed session knows the goal, what's done and what's next without you re-explaining.
- **Shows everything at a glance.** One command lists every session, what it's doing, how full its context is, and what needs you.
- **Interrupts you only when it matters.** Blocked and waiting-for-input sessions notify you right away. Everything else waits in an inbox, under a daily budget and outside quiet hours.
- **Stops the dangerous things.** A guard hook blocks force-pushes, destructive deletes, reading secrets, outbound messages, and sessions editing their own hooks or settings. Plain pushes and merges to `main` stay allowed (D24).

It also checks the repos for work you could lose, can talk (a voice dispatcher, see below), and records events for the pilot metrics and the planned learning loop (Phase 6).

Claude Code stays the only engine. Kaching doesn't run models of its own, except an optional Haiku/Sonnet step when a stop check fails (`test-escalate.sh`).

## Install, update, remove

```sh
cd ~/bbq/kaching
./install.sh --dry-run      # shows the settings.json and launchd diff, changes nothing
./install.sh                # asks before applying; --yes applies without asking
./install.sh --install-dispatcher --yes   # optional: the voice dispatcher's own folder
./install.sh --install-menubar --yes      # optional: the menu bar dot (builds ~/Applications/KachingBar.app)
./install.sh --uninstall    # removes Kaching's hook entries, the launchd jobs and the menu bar dot
```

`install.sh` is idempotent. It backs up `~/.claude/settings.json` before writing and only adds entries; it never removes your own hooks. A second run should say `nothing to do`.

What it installs:
- **The links:** `~/.claude/kaching`, pointing to this folder, and `~/.claude/ching`, its name before D35.
- **The hooks:** SessionStart, UserPromptSubmit, Stop, PreCompact, Notification, SessionEnd, and the PreToolUse guard.
- **The slash commands:** `/handoff`, `/next` and `/dash`.
- **The launchd job:** `org.kaching.watch`, which runs `bin/kaching-watch.sh` every 5 minutes.

After pulling new commits, run `./install.sh --dry-run` to see whether anything needs reapplying. Most changes need nothing, because the hooks point at this folder.

**Second Mac:** clone this repo to `~/bbq/kaching` and run `./install.sh`. State in `~/.agent/` is per machine and isn't synced.

**Upgrading from Ching (D35):** after the folder moved to `~/bbq/kaching` (with `~/bbq/ching` left as a symlink to it), run `./install.sh` once, then `./install.sh --install-menubar --yes` if you use the dot. The first replaces the hook entries under `~/.claude/ching/bin/` with the same ones under `~/.claude/kaching/bin/` and the `org.ching.*` jobs with `org.kaching.*`; the second replaces ChingBar with KachingBar. `~/.claude/ching` stays as a second link, so sessions that started before keep working. In Raycast, re-add `~/bbq/kaching/ui/raycast` if the old folder was added, and give the renamed commands their hotkeys again.

## Daily use

### See what's going on

| Command | What you get |
|---|---|
| `~/.claude/kaching/bin/dash.sh` | One line per session: state, age, context (● healthy, ◐ watch, ○ hand off now), today's tokens, folder, blocker. Ends with a `sync:` line when a repo needs attention, and warns above 5 active sessions. |
| `dash.sh --inbox` | **NEEDS YOU**: blocked or waiting for input. **READY**: release gate passed (only with the push gate on). **FINISHED**: done since you last looked; looking marks them as seen. **SYNC**: repos with work you could lose. |
| `dash.sh --next` | The top 5 sessions to attend to (urgency × importance × recency), each with its next action. |
| `dash.sh --speak` | The short spoken summary. |
| `dash.sh --counts` | A few `key=value` lines (sessions, needs, proposals) for the menu bar dot. Reads only Kaching's own session records, so it is fast. |
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

`bin/sync-check.sh` runs from the watcher every 6 hours, or on demand. For every repo Kaching has seen, it reports:
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

## Menu bar dot

A small dot in the menu bar at the top of the screen shows whether Kaching is running.

| Dot | Meaning |
|---|---|
| green | Kaching is running: the watcher has checked in within the last 11 minutes. |
| amber | Kaching is running and at least one session needs you (blocked or waiting for your input, the same sessions as NEEDS YOU in `dash.sh --inbox`). |
| grey ring | Kaching isn't running: the watcher isn't installed or hasn't checked in for over 11 minutes. Right after the Mac wakes from sleep it can be grey for a few minutes until the watcher's next run. |

Click it for the menu: a status line ("Kaching running · 3 sessions · 1 needs you"), when the watcher last ran, **Open inbox** (a Terminal window with `dash.sh --inbox`), **Proposals waiting: N** when the learner has open proposals, and **Quit**. The dot checks again every 12 seconds; each check reads a few small files and takes well under a second.

**Install:** `./install.sh --install-menubar --yes`. It needs the Xcode command line tools (`swiftc`), builds `~/Applications/KachingBar.app` and adds the login job `org.kaching.menubar`, which starts the dot at login and restarts it if it crashes. **Quit** from the menu keeps it off until your next login. Running the command again after a pull rebuilds the app only when its code changed. `./install.sh --uninstall` removes both.

**Coming later:** reading back the transcript of a conversation from the menu (the greyed-out "Transcripts (coming soon)" item), and notifications from the dot for sessions that need your input.

## Monitor queue: waiting agents come to your main screen

Hand a task to an agent, put its Terminal window on your second display, and forget about it. When the session finishes its turn or needs your input, its window moves to the main display (the one with the menu bar). When you prompt it, the window goes back to where it was. So if your main display shows only your own windows, every agent is busy.

- **Next waiting agent:** `bin/queue.sh next` brings the oldest waiting window to the front with the waiting tab selected. Each press after that shows the next one, wrapping around. Bind it to a hotkey with Raycast: Extensions > Script Commands > Add Directories > `~/bbq/kaching/ui/raycast`, then give **Next Waiting Agent** a hotkey. It shows "Ching01 (2 more waiting)" as a small message.
- **A lead agent and its workers:** open the workers as tabs of the lead's window (Cmd+T, or Window > Merge All Windows). The window moves as one: it comes over when any of its tabs waits and goes back once none does. `next` selects the tab that is waiting.
- **Tiling:** your second display is a grid sized by the agent windows that live there: two side by side, three in columns, four as a 2x2 grid, more in a larger grid. A waiting window keeps its cell: while it is on the main display its cell stays empty, and when you answer it goes back to exactly that cell, so each project keeps its place on the screen. Going back to its cell restores the window's exact size, and the main display is never laid out. The grid only changes when a window is opened or closed, and then every window takes the free cell nearest to where it was. It re-lays out when a session starts and on demand with **Tile Terminals** (same Raycast folder; `bin/queue.sh tile`). Windows on a desktop you aren't viewing, and minimised ones, are left alone.
- **Where a waiting window goes:** a fixed frame on the main display, 690 x 948 with its top-left corner at 320,70 from the display's top-left corner (what the screenshot crosshair shows). Every waiting window gets the same frame, a stack you go through with **Next Waiting Agent**. Change it with `queue_park_frame=X,Y,W,H` in `~/.agent/config`, or `queue_park_frame=off` to keep each window's own size.
- **Focus:** a window that comes over never takes the focus or jumps in front of what you're typing in. Only the **Next Waiting Agent** hotkey brings one to the front.
- **What brings a window over:** its own session finishing, asking you something, being blocked, or a release ready, while kaching is closed. The idle reminder never moves a window, and nothing that started waiting while kaching was open comes over later as a batch. A window already on the main display is never moved.
- **Only Terminal.app.** A session inside VS Code or Cursor has no window of its own to move, so it is left alone.
- **Status:** `bin/queue.sh status` lists the waiting tabs. State is in `~/.agent/queue/`.
- **With kaching open** (the agent terminal, D37): no window moves on its own. kaching's waiting list is the inbox; a window that is on the main display stays there until you drag it back.
- **Dragging by hand** (D38): drag an agent window from the second display onto the main one and it takes the park frame, with its grid cell kept empty; drag it back and it snaps into exactly that cell. Any other window you drag onto the second display joins the grid. The menu bar dot watches for this (twice a second, no permission needed); `KACHING_BAR_DRAGS=off` in its environment turns it off.
- **Files kaching reads:** `~/.agent/queue/tabs/<session id>` holds `tty window_id tab_index name` for every Terminal session (written at session start and on each prompt, removed at the end). `~/.agent/queue/waiting/<tty>` holds `epoch session_id kind name` (kind is done, input, blocked, ready or idle).
- **Settings** in `~/.agent/config`: `queue=off` turns it off; `queue_tile=off` keeps the queue but not the tiling; `queue_main_display=DELL` picks the main display by part of its name instead of the menu bar display.

## Agent terminal: every agent from the keyboard

`kaching` is one screen for all your agents, run entirely from the keyboard (design: `docs/superpowers/specs/2026-10-17-agent-terminal-design.md`, D33). It has no AI of its own: it reads the session records and types into the agent's own Terminal tab what you chose, so the agent does the work.

- **Install:** `terminal/build.sh` builds it into `~/.local/bin/kaching` (needs Go: `brew install go`). Then add **Open Agent Terminal** (`ui/raycast/kaching-open.sh`, same Raycast folder as above) and give it a hotkey: it brings kaching forward, or opens it filling the main display.
- **The desk:** left, every live agent by name: WAITING (oldest first), WORKING, IDLE. Right, the selected agent: its last message, its numbered options, the files it mentioned (lettered), the reply line. An orange frame means it waits for you.
- **Keys:** `k`/`j` move down/up, `space` jumps to the next waiting agent, `1`-`9` answer its option (a menu gets the key, a list in its message gets the number and Enter), `r` opens the reply box (Enter sends; Option+Enter, ctrl+J or `\` then Enter for a new line; Option+key types your layout's character, e.g. Option+L = @; `@` suggests the agent's files and a leading `/` its commands, Tab takes one; ctrl+V pastes a clipboard image as a saved PNG path; ctrl+G edits in $EDITOR; Esc or ctrl+C keeps a draft per agent), `o` then a letter opens a file it mentioned, `g` brings up its own Terminal window, `x` takes a waiting agent off the waiting list without answering, `W` shows the wall (`z` zooms one tile), `/` opens the command line, `?` shows every key.
- **Pre-written replies:** `f` fix it, `d` review the code, `s` check in on the other agents, and behind the space bar `space m` `/merge`, `space c` commit, `space w` new worktree. All keys and texts live in `~/.agent/terminal/keys.toml` (written on first run); edit and save, the terminal reloads it.
- **Command line codes:** `IN` the desk, `AG` the wall, `FL` every file agents mentioned (Enter opens), `RP` the sync check, `PR` the learner's proposals (Enter shows, `a` approve with its typed code, `x` reject, `z` snooze 7 days), `PC` Paperclip issues that need you and running ones with their cost (`r` posts a comment, Enter opens the issue), `A3` the third agent, or the start of an agent's name. `QUIT` or ctrl+c leaves.
- **Delivery:** text goes in through Terminal scripting without taking focus; Enter and menu answers are key presses, so the agent's window flashes to the front for a tenth of a second. The status line says "✓ <agent> is on it" once the session reacts. Sessions outside Terminal.app (Desktop, VS Code) are listed but can't be typed into.
- **Windows stay where they are (D37):** opening, quitting or reloading kaching never moves, resizes or closes a Terminal window. kaching is the inbox, so while it runs no window needs to come over to say it waits. `~/.agent/terminal/open` only tells the rest of Kaching that it runs and which agent is selected.

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

- **Level A:** `/dash` says the status aloud through VoiceMode, using local Whisper and Kokoro, so no audio leaves the Mac. Dictation into a session is done with Wispr Flow, your own app outside Kaching; Claude Code's `/voice` is not used (D25).
- **Level B, the dispatcher:** start it with `~/.claude/kaching/dispatcher/launch.sh`. It's a slim Haiku session that only:
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
| `~/.agent/watch.heartbeat` | Rewritten by every watcher run; the menu bar dot reads its time |
| `~/Applications/KachingBar.app`, `~/.agent/menubar.log` | The menu bar dot (optional) and its output |
| `~/.agent/dispatcher/` | The dispatcher's own settings and MCP config |
| `~/.agent/proposals/` | Phase 6 output, when it is built. Proposals only, never applied automatically. |
| `~/.agent-repos` | Extra repos for `dash.sh` and the sync check |

## Checking it works

```sh
cd ~/bbq/kaching
bash tests/run.sh                  # full suite (run it from here, not from a /tmp checkout)
bash tests/live-watch.sh           # read-only: launchd job loaded, events flowing
bash tests/live-smoke.sh           # daytime only: section 4 makes sound, 0-2 call claude -p
./install.sh --dry-run             # "nothing to do" means settings match this checkout
```

shellcheck runs inside the suite (`t_lint`). If it isn't on your PATH, the suite looks for it in `/tmp/sc-venv`.

## The learning loop (Phase 6): how Kaching learns and improves

Being built (D26). The idea: Kaching watches how you work with Claude across every session on this Mac, and over time makes Claude work more the way you want, without you repeating yourself. It **learns from what's already on disk** (your chats in `~/.claude/projects`, Kaching's own event log `~/.agent/events.jsonl`, and session checkpoints) and **only ever proposes**. Nothing changes until you approve it.

**What it learns and what it gives you:**

| It notices | It proposes | How often |
|---|---|---|
| Corrections you keep repeating ("do it yourself", "don't lose work when merging"), seen in 3+ sessions on 2+ days | A **new rule**, as a ready-made patch: for `~/.agents/CLAUDE.md` when it shows up in several places, or for one repo's `AGENTS.md` when it only happens there | nightly, 05:30 |
| Workflows you repeat by hand (the same chain of steps in several sessions) | A **new skill** idea with a draft description; approving it gives you the prompt to build it with skill-creator. At most 3 a week | weekly, Monday 05:30 |
| Your working patterns: sessions and prompts per folder, the hours and weekdays you work, stop retries, stalls, context handoffs, blocked commands, notifications | A **weekly report**, `~/.agent/proposals/report-YYYY-Www.md` | weekly |
| Things sessions keep listing as "not examined" when they finish | A **blind spot**: a review step to add so it stops being skipped (once enough checkpoints exist) | weekly |

**How you use it:** `dash.sh --inbox` shows open proposals in a PROPOSALS lane, and `/dash` can say "N proposals waiting". `kaching-proposals list` / `show <id>` / `diff <id>` let you read them. `approve <id>` shows what will change, then asks you to type back a short code it shows (one line, once). It works only in your own terminal window: it refuses when a Claude Code session started it, including Claude Code's `!` prompt, and a session may only run `list`, `show`, `diff`, `reject` and `snooze`. `reject <id>` makes sure it's never proposed again. `snooze <id> <days>` hides it for a while. The weekly report shows which kinds of proposal you approve and which you reject, so a part that only produces noise can be switched off (`LEARN_DISABLE`).

**What it will not do:**
- It never edits rules, skills, settings, hooks or the guard by itself.
- It never sends anything off the Mac: the model call is a local `claude -p` on your subscription, with no tools and a daily token cap.
- It never notifies you about proposals.
- It never reads sandbox or test sessions.

The guard has a learner mode that blocks any write outside `~/.agent/proposals/`. Deleting `~/.agent/proposals/` wipes everything it has learned.

**Not yet:** lessons injected at session start (stage 6b) stay unbuilt until the weekly report shows that rules alone aren't enough. It stays out of claude-mem, and in the long run Kaching's own memory is meant to replace claude-mem (D27).

### The label spot-check (you, about 10 minutes, once)

The learner has to tell a **correction** from an ordinary prompt:

- **correction:** you're unhappy with *how Claude worked* and steer it, e.g. "why do I have to do this manually, just apply it" or "don't lose anyone's work when you merge";
- **not:** a new request, a question, an answer, or feedback on *the thing being built*, e.g. "this number looks wrong" or "add a button".

An agent sorted 263 of your past prompts into those two piles. Your check of about 20 of them becomes the answer key the detector is tested against (`bin/learn-eval.sh`), and your answers to three policy questions go into the labelling rules in `templates/learn-prompts/corrections.md`.

- **Where:** `~/.agent/proposals/.eval/spot-check.md`. It sits next to `labels.jsonl` (all 263 items) and a `README.md` with the full explanation. These files stay on this Mac and never go into a repo, because they're your own words.
- **Each item:** ask yourself "when I wrote this, was I correcting how Claude worked?" Write `ok` if the label matches your gut, otherwise `correction` or `not`, plus a few words if the pattern is described wrongly. Gut calls are fine; there are no wrong answers.
- **Policy questions A-C** cover whole groups of prompts: is product feedback a correction (currently no); is an up-front "keep everything intact" a correction when it repeats a standing rule (currently yes); is pointing Claude at a previous session's work a correction (currently no).
- **How to hand it back:** reply in a Claude session in one line (`A no, B yes, C no. 3 not, 6 correction, others ok`), or fill in the "owner:" lines in the file and say "spot-check done".

## Status and what's left

On 2026-10-16:
- Phases 0–1.6 are built and installed.
- Of the pilot (Phase 2), tasks 2.1, 2.2 and the sync check (2.7) are done.
- Voice levels A and B (Phases 3–4) are built.
- Rollout 5.3 is done; 5.1/5.2 were dropped by D24.

`PLAN.md` §6 has the boxes. The open work:

- **Needs you, in one sitting.** `MANUAL-STEPS.md`, "2026-10-16", about 45 minutes:
  - the speed pass line is picked: 8 s (D25);
  - hear `/dash`;
  - run the spoken dispatcher test (4.3), which also measures 0.6;
  - run the two-voices test (0.7).
- **Pilot (2.3–2.6):** a few days of normal use, then review `bin/metrics.sh` together and tune the notification budget, stall threshold and context levels.
- **Phase 6, the learning loop:** stage 6a is being built now (D26; spec in `docs/superpowers/specs/2026-10-16-phase6-learning-loop-design.md`, questions answered). Waiting on you: the label spot-check above.
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
- `kaching-functions.md`: plain-language tour of what Kaching borrowed and why.
- `docs/`: voice, dispatcher acceptance, live checks, specs and plans.
