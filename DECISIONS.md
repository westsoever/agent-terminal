# Ching decision log

Newest first. PLAN.md holds D1-D9 and the v3 scope note; later decisions are recorded here and folded into PLAN.md once the Phase 1 build finishes (the build agent is editing PLAN.md now).

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
