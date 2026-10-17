# Ching decision log

Newest first. PLAN.md holds D1-D9 and the v3 scope note; later decisions are recorded here and folded into PLAN.md once the Phase 1 build finishes (the build agent is editing PLAN.md now).

## D35 (2026-10-17): Ching is renamed Kaching

**Decision (user):** the kit is called Kaching, like an old cash register closing. The agent terminal (D33) already carried the name; now the whole kit does.

**What changed:** the link is `~/.claude/kaching` and install.sh writes the hooks under it; the jobs are `org.kaching.watch`, `org.kaching.learn` and `org.kaching.menubar`; the dot is `KachingBar.app`; the CLI is `kaching-proposals` and the watcher `kaching-watch.sh`; the Raycast scripts are `kaching-next.sh`, `kaching-tile.sh` and `kaching-open.sh`; environment variables are `KACHING_*`; the repo folder becomes `~/bbq/kaching`. Text that describes the past (this log, the checkpoints, dated specs and plans) keeps the old name.

**Kept working through the switch:** `~/.claude/ching` stays a second link to the kit (install.sh creates it, or points it here again), so hook entries, launchd jobs and running sessions that still use the old path keep running the same code. `bin/ching-proposals` and `bin/ching-watch.sh` are wrappers around the new names, and the guard treats `ching-proposals approve` exactly like `kaching-proposals approve`. A `CHING_*` variable still counts when its `KACHING_*` name is unset (lib.sh, the early learner checks, KachingBar). install.sh replaces the hook entries under the old link with the same entries under the new one (no hook runs twice), and replaces the `org.ching.*` jobs after their successors have loaded; `--install-menubar` replaces ChingBar.

**Not renamed, on purpose (stored data):** the `<!-- ching:checkpoint -->` and `<!-- ching:snapshot -->` blocks in STATE.md files, the `ching-learn-task:` marker the learner writes into its prompts and filters transcripts by, the `ching-learn` name on learner events, `~/.agent/defaults/ching.env`, `ching-prepush-marker` in installed pre-push hooks, and everything under `~/.agent/`. The GitHub repository keeps its name. Session names such as chingSorter or Ching01 are the owner's.

## D34 (2026-10-17): The monitor queue serves kaching: one agent at a time while it is open

**Decision (owner, through the agent terminal design, D33):** while kaching runs, the main display shows kaching plus at most one agent window: the one kaching has selected, else the head of the queue. The others keep their waiting records but stay in their cells; answering one brings the next, in the background, never taking focus. With kaching closed, the D29-D32 behaviour applies. Built as one reconcile step that every queue change runs: it works out which windows belong on the main display and moves only the difference. Also for kaching: a tabs map per session, the session id and kind in each waiting record, `queue.sh show` and `queue.sh dismiss`. Not built here: sending text into a tab (kaching's terminal/send.js) and any key layer (Raycast stays the global hotkey layer).

## D33 (2026-10-17): The agent terminal (kaching)

**Decision (user):** one keyboard-only screen for every agent, in the spirit of the Bloomberg Terminal and in the look of `ssh terminal.shop`: near-black, grey text, white for what's selected, one orange accent. Desk (queue + selected agent) and a command line of codes (IN AG FL RP PR PC) are the home screen; the wall shows every agent as tiles sized to the window; the PC view reads Paperclip, which is a source and not the backend. Replies are typed in the terminal and delivered into the agent's own Terminal.app tab; only Terminal.app sessions take replies. Numbers answer an agent's options; pre-written replies (fix it, review the code, check in on the other agents, `/merge`, commit, new worktree) sit near the home row and live in `~/.agent/terminal/keys.toml`, which the owner edits. Each session merges itself with the global `merge` skill (`~/.agents/skills/merge`); a dedicated merge agent only if parallel merges become a problem. While the terminal is open, monitor 1 holds it plus one agent window at a time (chingSorter's queue, D34+). The terminal has no AI of its own: it reads files and types what the owner chose. Design: `docs/superpowers/specs/2026-10-17-agent-terminal-design.md`.

**Found while building it:** Terminal's `do script` types into a background tab without focus, but Claude Code treats a long burst as a paste and swallows its newline, so Enter is pressed separately (a key event posted to Terminal's process, ~0.1 s window flicker, the fallback the owner accepted) and `send.js` checks that the text left the input box, retrying Enter. A menu (AskUserQuestion) is answered with the number key alone. Session names come from Claude Code's own `~/.claude/sessions/<pid>.json`, joined with Ching's `meta`.

## D32 (2026-10-17): A fixed frame for waiting windows on the main display (amends D31)

**Decision (user):** a window that comes to the main display takes one fixed frame: top-left 320,70 and bottom-right 780,860 on the owner's screen, so 460 x 790 (`queue_park_frame`, default 320,70,460,790). All waiting windows share it as a stack. Going back still restores the exact cell. Found while building it: Terminal sets a window's y from the top of the display the window is on, but reports it from the top of the main display, so `queue-term.js move` corrects for that. A second display also has its own menu bar that macOS does not take off its visible frame, so the helper takes it off.

## D31 (2026-10-17): The grid is a map of where each project lives (amends D30)

**Decision (user):** moving never resizes a window, on either display, and the main display is never laid out. The grid on the second display is sized by all its agent windows, waiting ones included: a waiting window's cell stays empty while it is away, and it comes back to exactly that cell, so the layout is a visual guide to where each project is. When the count changes (a window opened or closed), each window takes the free cell nearest to where it was.

## D30 (2026-10-17): Tiling and no focus stealing for the monitor queue

**Decision (user):** a window that arrives must never take the focus from the session the owner is working in. Each display tiles its Terminal windows by count (2 side by side, 3 in columns, 4 as 2x2), so arrivals sit beside the owner's work instead of on top of it. One window per project, with its subtasks as tabs. Desktops (Spaces) stay out: windows on a hidden desktop are not moved by tiling. A window cannot be sent back to a particular desktop (no public API), so it goes to the desktop shown on its old display.

## D29 (2026-10-17): Monitor queue for waiting agents

**Decision (user):** waiting agents come to the main display, built into Ching. The owner works on the main display and parks agent Terminals on the second one. A session that finishes or needs input moves its window to the main display; prompting it sends the window back. Native macOS Spaces were considered and rejected: macOS has no supported way to move a Space to another display (yabai needs SIP partly off; AeroSpace replaces the window manager). The main display itself is the queue instead, with a "next waiting agent" hotkey (Raycast script command, `ui/raycast`). A lead agent and its workers are grouped as tabs of one window and move together.

## D28 (2026-10-17): Spot-check policy, auto-title removed, menu bar dot, overnight autonomy

**Decisions (user):**
- **Spot-check:** the owner reviewed items 1-10 of the label spot-check. Items 11-21 and policy questions A-C were left blank and are read as "keep the agent's label".
  - Merge or push instructions that carry "keep everything / don't delete progress" count as corrections, even when stated up front.
  - Re-confirming an instruction the assistant should already have acted on ("then let's merge it") is a correction.
  - Product feedback stays "not".
  - `templates/learn-prompts/corrections.md` and `~/.agent/proposals/.eval/labels.jsonl` are updated (10 items `owner_reviewed`).
  - New patterns the owner named: merge right away when asked and report after; notice when the build drifts from what was asked; build in soii-dev and sync to soiisauce on release (cos is only an install); run migrations yourself.
- **Session auto-title skill:** removed (moved to the Trash on 2026-10-17). Its SessionEnd hook caused the 2026-10-05 registry flood: each titling run was a session that triggered another.
- **Menu bar dot:** a small dot in the macOS menu bar shows whether Ching is running. Later it will show transcripts and push notifications for sessions that need input. It is a separate macOS app (`ui/menubar`), not a Claude Code mod, so D23 still holds.
- **Overnight (2026-10-17 ~01:45):** "Keep driving the sessions until everything is done. Take decisions for yourself and the other agents." The orchestrator session (ChingRollOut) made the remaining build and install calls under this.

## D27 (2026-10-16): The learner stays out of claude-mem; claude-mem is to be replaced in the long run

**Decision (user):**
- Yes to Phase 6 question 8. The learner's runs are kept out of claude-mem in two ways: `CLAUDE_MEM_INTERNAL=1` in the `org.ching.learn` job, and `~/.agent/proposals/.work` in `CLAUDE_MEM_EXCLUDED_PROJECTS` (`~/.claude-mem/settings.json`, which `install.sh` backs up first).
- Long-run direction: **replace claude-mem.** Ching's own data (events, checkpoints, transcripts, the learner's proposals and, later, lessons) should take over what claude-mem does today.

**Consequences:** nothing in Ching may come to depend on claude-mem. Its data can be read as an input while it is still installed, but never required. Replacing it is a later item, not part of stage 6a.

## D26 (2026-10-16): Build Phase 6 stage 6a now (amends D16)

**Decision (user):** yes to Phase 6 question 9. Stage 6a is built now, before the pilot metrics: the contracts, the extractor and report, the correction detector, the skills miner and the plumbing. The reason to wait (design on real data) no longer holds, because 6a reads transcripts and 221 real sessions already exist. Stage 6b (lessons) stays unbuilt (question 5).

**Defaults for questions 1-6:** the spec's recommendations are used as starting values, and the weekly report can correct them:
- nightly run at 05:30, weekly run on Monday at 05:30;
- `LEARN_MODEL_CLASSIFY=haiku`, `LEARN_MODEL_DRAFT=sonnet`, `LEARN_TOKEN_CAP=200000`;
- the learner assigns `task_type`, and a session's own line wins when present;
- rule target: a single repo's `AGENTS.md`, or global when the pattern spans 2+ places;
- `LEARN_SKILL_MAX=3`.

**Question 7:** the labelled set is rebuilt during step 0, and the owner spot-checks about 20 labels. **Question 10:** done the same evening. The 4,615 empty `/private/tmp` registry entries from 2026-10-05 were moved to `~/.agent/archive/registry-private-tmp-2026-10-05/`, with a tarball next to it: 18 MB on disk, 0.9 MB of content. The test that wrote them still has to be found and fixed.

## D25 (2026-10-16): Voice pass line 8 s; no `/voice` fallback

**Decision (user):**
- The 0.6 speed pass line is **8 seconds** from the end of the sentence to the first spoken word, picked before any dispatcher measurement.
- Claude Code's `/voice` is **not** used as a fallback. The user dictates with Wispr Flow, their own tool outside Ching.

**Consequences:** `docs/voice.md` keeps the `/voice` notes for reference only, marked unused. D3's "native `/voice` stays as a fallback" no longer holds. Ching does not install, configure or depend on Wispr Flow. Like `/voice`, Wispr Flow transcribes off the machine, so D5 (local audio) covers only Ching's own voice path: VoiceMode, `/dash` and the dispatcher.

## D24 (2026-10-16): Guard on, push rule off

**Decision (user):** The guard is reinstalled with every protection except the push-to-main release token. On 2026-10-10 the user had removed `guard.sh` from `~/.claude/settings.json` entirely, because rule 3 (a push to main needs a release token, plus `--approve` in `confirm` mode) blocked the automatic commits, pushes and merges they want. That removal also switched off every other protection for six days.

**How it works:** `push_gate` in `~/.agent/config` (`push_gate=on|off`), **default off**. Only exactly `on` (case-insensitive) re-enables the token check for plain pushes to main or the default branch, `gh pr merge` and the API merge calls. No `GOAL.md` `release_mode` overrides it. The following stay denied either way:
- force pushes;
- deleting protected branches;
- `v*` tag pushes and `--no-verify`;
- `rm -rf` outside the repo and `/tmp`;
- `.env` reads and Supabase writes;
- publishing;
- outbound send tools;
- edits to hooks, settings, tokens, `GOAL.md` gate fields and the config file itself.

`release-gate.sh`, `post-release.sh` and `migrate-gate.sh` stay available for manual use. `templates/pre-push` reads the same switch.

**Consequences:** Phase 5.1/5.2 (the `confirm`-then-`auto` rollout to miso-app and miso-workspace) is dropped. `~/.miso/.agent/GOAL.md` still says `release_mode: confirm`; it no longer blocks anything. Reinstalled 2026-10-16 01:28; backup `~/.claude/settings.json.bak.ching.20261016-012816`. A live probe from a real session showed a plain push to main allowed and a force push denied.

## D23 (2026-10-06): Ching is not ported to a Claude Code mod

**Decision (user, accepting the orchestrator's recommendation):** Ching stays bash, settings command hooks and launchd. It is not rewritten as a Claude Code mod (a function-hooks plugin, TypeScript, in-session). A mod may come later only as a read-only UI layer on top, after the Phase 2 pilot.

**Why:**
- Most of Ching runs outside any session: the launchd watcher, `events.jsonl`, `dash.sh`, the session registry, git `pre-push`, the release and migrate gates, the voice dispatcher. A mod lives only while a session runs, so a port would leave two codebases.
- `guard.sh` as a `PreToolUse` command hook is verified under `bypassPermissions` (Phase 0) and covered by the test suite and the Checkpoint 1.5 differential probe. A mod's `tool.call` deny under bypass is untested, and a mod hook that throws is skipped (the call goes ahead), which is the wrong failure mode for a deny list.
- A port would undo D17 (stay in bash) and the guard hardening, and changing the substrate mid-pilot would spoil the pilot metrics.
- Mods are new (Claude Code 2.1.29x) and the API is large and likely to change; the bash scripts and settings hooks are stable.

**How to apply:**
- Enforcement (guard, gates, Stop check, watcher) never moves into a mod.
- If the pilot shows visibility or notification as the weak spot, build a `ching-ui` mod that only reads `~/.agent/` and `events.jsonl`: a pane for `dash.sh --inbox`/`--next`, a status-line entry (goal, Stop retries, release token), toasts for other sessions' blocked/done events (could replace `notify.sh` popups), possibly a `prompt.compose` hook re-injecting `STATE.md`/`NEXT.md` each turn, and `$.audio.speak` as an option for Phase 3 spoken status. If the mod breaks, only the view is lost.

## D20-D22 (2026-10-06): before the pilot

**Decisions (user, choosing the orchestrator's recommended option for each question):**

- **D20:** Sessions may create a `v*` release tag but never push it. Guard rule 8 now denies pushing `v*` tags, `--tags`, `--follow-tags` and config that pushes tags, in every repo. The GitHub `release` environment reviewer stays as the second gate for miso.
- **D21:** Before the pilot, fix the gaps from CHECKPOINT-1.5 section 6 that would hurt real sessions. These are the stop-check items F3, F4, F5, F8 (partial), F9 and F12, the ladder skip, the cheaper checkpoint rule, the false stall on resume, the zero-usage context reset, the `dash.sh` ranking, inbox and READY issues, the installer prompt on a non-tty run, and the rule 5 and rule 8 false positives on grep patterns. Everything else stays logged until the pilot shows it matters.
- **D22:** miso is the first repo to opt in. The opt-in is the worktree `~/bbq/.worktrees/miso-ching-pilot` on branch `ching-pilot` (autonomy block and gitignore lines committed there, `.agent/GOAL.md` with `release_mode: confirm`), not the user's main miso checkout.

## D19 (2026-10-05): Check-in nudges for waiting sessions

**Decision (user):** Ching reminds the user when a session is waiting on them: a banner first, then one spoken note after about 5 minutes. The notch widget that opens on hover is deferred. It is built by extending the existing one-shot watcher, `ching-watch.sh`, and stays within D17 (no daemon, no AI calls).

**Why:** The stall watcher watches sessions, not the user. Nothing noticed a finished session sitting in front of a user who had looked away.

**How to apply:**
- Waiting means `input`, `blocked`, or `done` with open work (a checkpoint blocker or next action that is not a "none" value, or a non-empty `NEXT.md`). A working session never nudges.
- Keyboard and mouse idle time only gates the voice, never the banner.
- The banner uses the shared alert budget (quiet hours, 4 a day, 45-minute cooldown). The spoken note is outside that budget. It is bounded by once per waiting spell, a 10-minute gap between notes, quiet hours, and the user being at the Mac, and it stays silent while VoiceMode is in use.
- Spec and plan: `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`, `docs/superpowers/plans/2026-10-05-ching-nudge.md`.

## D14-D18 (2026-10-05): Hermes harvest (Phase 1.5)

**Decisions (user, in the brainstorming session that evaluated four Hermes Agent repos):**

- **D14:** Ching is the main AI operations layer for all local files. Review before release is required by default in every repo; only a human-written `review: off` in `GOAL.md` disables it (guard rule 11 stops sessions from changing gate settings).
- **D15:** super-hermes, hermes-workspace, hermes-plugins and hermes-skill-factory are a source of ideas only. Nothing from them is installed or run. Claude Code stays the only engine.
- **D16:** Phase 1.5 (coordination + review hardening) is built before the Phase 2 pilot. The learning-loop ideas are recorded for Phase 6 and specified after the pilot.
- **D17:** Stay in bash: an append-only `~/.agent/events.jsonl` plus a one-shot launchd watcher. No daemon, no cloud scheduler, no AI calls in Phase 1.5.
- **D18:** Sessions write drafts only. They never send email or chat messages (guard rule 10).
- Notification policy confirmed: only `input`, `blocked` and `ready` always reach the user; at most 4 other alerts a day, 09:00-21:00, 45-minute cooldown; `done` goes to `dash.sh --inbox`.

Why, and what was rejected: `docs/superpowers/specs/2026-10-05-hermes-harvest-design.md` section 3. Plain summary: `ching-functions.md`.

## D13 (2026-10-05): Checkpoint 1 approved; hooks installed on the real settings

**Decision (user, "go ahead", following the orchestrator's recommendation):** install the kit's hooks into `~/.claude/settings.json`.

- Installed without `--replace-popup`: the old "Session finished" popup stays, so each stop notifies twice until the user opts in.
- `gh pr merge` is allowed only with a valid release token for the local HEAD and `--match-head-commit <that sha>`. Anything else is denied (guard.sh, tests in t_release.sh).
- The git pre-push hook stays off; it is installed per repo with `install.sh --install-prepush <repo>`.
- Result: 7 new hook entries, 602 checks green, existing `vscode-session-manager-hook.sh` and `auto_title_sessions.py` entries untouched. Backups: `~/.claude/settings.json.bak.ching.20261005-140153` and `/tmp/agent-sandbox-backup/settings.pre-install.*.json`. Undo with `install.sh --uninstall`.
- Not yet verified: that hooks fire from the real settings file in Desktop and VS Code, and how already-open sessions pick them up (MANUAL-STEPS.md 0.4).

## D12 (2026-10-05): mem0 is not included

**Decision (user):** Do not include mem0, now or later. It is the wrong tool: its defaults send data to OpenAI (LLM and embeddings), it needs a vector database and a separate service, and running it locally means standing up Ollama and Qdrant. The user expected a lightweight harness around Claude, which it is not. If it cannot run locally without that extra stack, it stays out.

**What I checked (README summary only, not the code):** Apache-2.0, very active (pushed 2026-10-05, 66k stars). Three modes: library, self-hosted Docker server, hosted cloud. Defaults: OpenAI `gpt-5-mini` plus `text-embedding-3-small`, Qdrant. Ollama is supported through config. A `.claude-plugin` directory exists; I did not inspect it. Telemetry defaults were not stated in what I read.

**Still open:** the user is looking for other tools for the "mirror me and learn my decisions" job. Requirements to judge any candidate against: runs fully local with no cloud calls by default, no extra always-on service if avoidable, readable and editable storage, works alongside claude-mem, and proposes decisions for approval rather than acting on them. Ching's profile storage (D11) stays backend-agnostic so a tool can be added or dropped later.

## D11 (2026-10-05): Ching is a learning system, not just a voice interface

**Decision (user):** Ching must not be only a voice model or a session manager. It is a place of learning and adapting that improves itself. It understands how the user works, what they are good at, and what they lack. It keeps track of that and keeps improving the way they work, so their output is as high as possible.

**What this adds to the design (proposed, not yet built; needs the user's review):**

- A **profile** in `~/.agent/profile/`: working patterns (when and how sessions run, which kinds of task finish fast or stall), strengths, gaps, and recurring friction. Plain markdown and JSONL, so the user can read, edit and delete it.
- **Signals** come from data the kit already has: session transcripts and registry, `STATE.md` logs (assumptions, decisions, releases), Stop-hook retries, questions asked, overturned assumptions, minutes per handoff. These are the three pilot metrics in PLAN.md section 7, kept continuously instead of for one pilot.
- A **review loop** (daily or weekly, run on a cheaper model) that reads the signals, updates the profile, and proposes concrete changes: a rule for `AGENTS.md`, a hook tweak, a `GOAL.md` template fix, a task split. Proposals are written to `~/.agent/proposals/` and shown to the user.
- **Self-improvement is gated.** Ching proposes changes to its own scripts, policy and the user's `AGENTS.md`; the user approves them. It does not rewrite its own guardrails or `guard.sh` on its own.
- **Local only.** The profile never leaves the machine and is never sent to a service. The user can inspect it, correct it ("that's wrong") and wipe it.
- This replaces the old "director loop deferred" idea (D7) with something broader. It stays out of Phase 1 and gets its own phase after the machine-wide kit is working (Phase 6 in PLAN.md).

**Open questions for the user:** how blunt should "what I'm lacking" be, how often should the review run, and should the profile feed back into the dispatcher's spoken answers.

## D10 (2026-10-05): Split work across multiple agents from the start

**Decision (user, after the orchestrator's admission):** Large phases are not given to one big agent. They are split into several agents working in parallel on independent parts, with a separate verification step.

**Why:** Phase 0 took about 12 minutes and Phase 1 as one agent writing nine scripts plus tests was slow. The orchestrator should have split it at the start.

**How to apply:**
- Split by independent unit: for example hooks, gates, `dash.sh`, installer, tests, docs each get their own agent when they do not share files.
- Define the shared interface first (file formats, JSON schemas, paths such as `~/.agent/`), then fan out.
- A separate verification agent runs the tests and reviews the result; the implementer does not grade its own work.
- The currently running Phase 1 agent is not restarted. Phases after it follow this rule.
