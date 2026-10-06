# Parallel Claude sessions + voice: spec and step-by-step plan

Status: **DRAFT v2 for review** (v2 applies your first review: agents may push to production through a release gate, and may create and apply migrations; see D8, D9 and section 5.2). Nothing in this document has been built yet. Source material: `parallel-claude-workflow.md` (your original), plus what I found on your machine and in the docs on 2026-10-05.

> **v3 scope change (from the user):** the kit manages the **whole computer**, not just miso, miso-app and miso-workspace. Any open Claude session, in any repo or plain folder (including `~`), is in scope. Consequences built in Phase 1: global state in `~/.agent/` (sessions registry, per-session `STATE.md`/`NEXT.md`, optional defaults; override with `AGENT_HOME`); a repo's own `.agent/` is an optional override that is active only when it contains a `GOAL.md`; hooks and `guard.sh` work in any cwd with no git repo or `GOAL.md` assumed; `dash.sh` discovers sessions machine-wide (registry + `~/.claude/projects` transcripts + `git worktree list`), `~/.agent-repos` is an optional extra; the release gate and migrate gate stay per repo and are opt-in by a repo `GOAL.md` (elsewhere `guard.sh` still denies pushes to the default branch without a token); the dispatcher manages all sessions, not a fixed list. D6 and Phase 2 are adjusted below; everything else is unchanged.

> **v4 (2026-10-05): Hermes harvest.** Four Hermes Agent repos were evaluated (read-only, nothing installed). Ching takes ideas only, and Claude Code stays the only engine (D15). A new **Phase 1.5** goes in before the pilot: coordination upgrades (event log, notification routing and budget, stall/context/token watcher, `dash.sh --inbox/--next`) and review hardening (review before every release, "not examined" footer, guard rules 8-11). The learning-loop ideas are recorded for **Phase 6**. Full design: `docs/superpowers/specs/2026-10-05-hermes-harvest-design.md`; plain-language summary: `ching-functions.md`. Ching is now the main AI operations layer for all local files (D14).

How to use this file: read sections 1-5 (the design), correct anything wrong, then we work through section 6 one phase at a time. Every phase ends with a **checkpoint**: I show you results and stop until you say go.

---

## 1. Goal and success criteria

Run 4-8 Claude Code sessions across **miso** (`~/bbq/miso`, local app), **miso-app** (`~/bbq/miso-app`, hosted app) and **miso-workspace** (`~/.miso`, the spaces), and:

1. Stop re-reading context. A new or resumed session already knows the goal, what is done, and what is next.
2. Get long autonomous runs with few questions. Sessions decide, log assumptions, log decisions and keep going.
3. Know the state of everything at a glance, and be told only when a session is **done** or **truly blocked**.
4. **Talk to the sessions.** At the Mac, hands busy: ask "what's blocked?" and hear the answer; say "tell miso-app to ..." and have it relayed.

Success is measured in the pilot (section 7), not by whether the scripts exist.

## 2. Decisions already made

| # | Decision | Source |
|---|----------|--------|
| D1 | Keep `bypassPermissions` as the default and add **hard guardrails** (deny hooks) instead of switching to stricter modes. | You, in chat |
| D2 | Voice is **at the Mac first**. Phone comes later. | You, in chat |
| D3 | VoiceMode (`mbailey/voicemode`) is the voice engine. Native `/voice` stays as a fallback. | You pointed me to it; my recommendation |
| D4 | Voice runs on **one dispatcher session only**. Worker sessions stay silent. | My recommendation, pending your OK |
| D5 | Speech-to-text and text-to-speech run **locally** (Whisper.cpp + Kokoro). No audio leaves the machine. | My recommendation, pending your OK |
| D6 | ~~Pilot repo is miso.~~ **Superseded (v3):** machine-wide is the default. The pilot is a couple of real sessions in different folders (a repo, a worktree, a non-repo folder). Per-repo `.agent/GOAL.md` is an optional override; the release and migrate gates are opted into per repo, miso-workspace last. | User, v3 scope change |
| D7 | The **director loop** (`claude -p` rewriting NEXT.md) is deferred until the pilot shows a gap. | My recommendation, pending your OK |
| D8 | Agents **can push to production** (`main`), but only through the **release gate** (section 5.2): tests green, change verified in the real app, evidence recorded for that exact commit. | Your review comment; gate design is mine |
| D9 | Agents **can create, apply and follow up on migrations** against the shared Supabase project, only through the numbered-file ledger runner (section 5.3). "Update" means a new numbered file. | Your review comment; guardrails are mine |
| D10-D13 | Split big phases across parallel agents with a separate verifier (D10); Ching is a learning system (D11, Phase 6); mem0 excluded (D12); Checkpoint 1 approved and hooks installed (D13). Full text in `DECISIONS.md`. | User |
| D14 | Ching is the **main AI operations layer for all local files**. Review before release is required by default in every repo, with or without `GOAL.md`; only a human-written `review: off` disables it. | User, v4 |
| D15 | Hermes repos are **a source of ideas only**. No Hermes runtime, plugin, skill or GUI runs in Ching. | User, v4 |
| D16 | Phase 1.5 (coordination + review hardening) is built **before** the pilot; the learning-loop ideas wait for Phase 6 and real pilot data. | User, v4 |
| D17 | Stay in bash: an append-only event log (`~/.agent/events.jsonl`) plus a one-shot launchd watcher. No daemon, no cloud scheduler, no AI calls in Phase 1.5. | User, v4 |
| D18 | Sessions may write **drafts only**. They never send email or chat messages (guard rule 10). | User, v4 |
| D20-D22 | Sessions never push `v*` release tags (rule 8). The pilot-affecting gaps are fixed before the pilot. miso opts in first, in the `ching-pilot` worktree. Details in `DECISIONS.md`. | User, 2026-10-06 |
| D23 | Ching is **not** ported to a Claude Code mod. Enforcement stays in bash, settings hooks and launchd; a read-only `ching-ui` mod may follow the pilot. Details in `DECISIONS.md`. | User, 2026-10-06 |

Items marked "pending your OK" are the ones to challenge when you review.

## 3. What is known and what is not

**Verified by me (on your machine or in the repo):**

- `AGENTS.md` is the real instruction file in all three repos; `CLAUDE.md` is a symlink to it. Edit `AGENTS.md` only.
- You already have `~/.claude/vscode-session-manager-hook.sh` on Stop, PreToolUse, UserPromptSubmit and Notification(idle_prompt), plus a blanket "Session finished" popup (`osascript`) on every Stop. New hooks must coexist with these.
- A push to `miso-workspace` `main` triggers a deploy workflow in `miso-app`, which deploys to production. The three repos are chained.
- You already have six worktrees in `~/bbq/.worktrees/`, `.remember/` folders, claude-mem, and `plans/` in miso.
- `jq`, `brew`, `tmux`, `gh`, `node`, `claude` 2.1.289 are installed. `terminal-notifier` is **not**.
- VoiceMode: MIT, last pushed 2026-10-01, plugin install via `claude plugin marketplace add mbailey/voicemode`. It provides a `converse` tool (speak + listen). A lock file (`~/.voicemode/conch`) lets only one session speak at a time. In shared `voicemode serve` mode that lock does not work (open issue #521), so we use the per-session launcher, never `serve`.

**From the Claude Code docs:**

- `/voice` is speech-to-text dictation only. It works in CLI, Desktop Code tab and VS Code. No spoken replies, not scriptable.
- `Notification` matchers `agent_needs_input` and `agent_completed` exist.
- `Stop` hook blocks with `{"decision":"block","reason":"..."}` or exit code 2.
- `ListAgents` / `SendMessage` can send **text messages** between sessions on one machine.
- Telegram/Discord channels take text only, not voice notes.

**NOT documented, so tested in Phase 0 before anything depends on it:**

| Unknown | Why it matters | Fallback if it fails |
|---------|----------------|----------------------|
| Do `PreToolUse` deny hooks fire under `bypassPermissions`? | The whole guardrail design (D1) rests on it. | Use `permissions.deny` rules (also tested), plus git `pre-push` hooks (miso already has `.githooks/`). |
| Do `~/.claude/settings.json` hooks fire in **Desktop Code-tab** sessions? | Original doc assumes Desktop, CLI and VS Code share them. | Run managed sessions in VS Code/CLI, or add per-repo `.claude/settings.json` hooks. |
| Does `SendMessage` wake an **idle** session, or only reach a busy one? | The dispatcher relay (D4) depends on it. | Dispatcher only reports; you dictate into the worker with `/voice`. |
| Do `agent_needs_input` / `agent_completed` fire for normal foreground sessions? | Notification design. | Use `Stop` + `idle_prompt` and classify in the script. |
| Does the VoiceMode plugin work in Desktop app and VS Code, and how fast is local Whisper + Kokoro? | Voice is unusable if latency is bad. | Use OpenAI cloud STT/TTS as an explicit, separate decision. |

## 4. Changes from your original document

| Original | Change | Reason |
|----------|--------|--------|
| Autonomy policy goes in `CLAUDE.md` | Goes in **`AGENTS.md`** | `CLAUDE.md` is a symlink in all three repos. |
| `.agent/` committed, only `.retries` ignored | **Whole `.agent/` gitignored**, per worktree | `STATE.md` rewritten every turn would pollute PRs and conflict across worktrees. miso has PR-format rules. |
| Retry counter is `.agent/.retries` | Counter **keyed by session id** | Two sessions in one checkout would share one counter. |
| Stop hook "check done criteria" | Same, plus honour the loop-prevention field verified in Phase 0 | Avoid infinite Stop loops. |
| PreCompact "save state to STATE.md" | Hook writes a **snapshot** (branch, git status, diff stat, time); the model writes the narrative via the policy | A command hook cannot make the model write prose. |
| Notification: push for needs-input and completed | Same, and **replace** the existing blanket "Session finished" popup | Today every Stop pops a notification. |
| "Never use Bypass permissions" | Overridden by D1; **guardrails are mandatory** and tested | Your default is bypass; the doc's own advice would be ignored. |
| Director loop + `dash.sh` | `dash.sh` kept, director deferred (D7) | Sessions already rewrite their own `NEXT.md`. |
| "Ask before destructive/irreversible actions" (no carve-out for shipping) | Pushing to production and applying migrations are **allowed through gates**, not asked about each time (D8, D9). Only destructive database changes still stop for you. | You want agents that can ship. The gates replace per-action questions with checks. |
| Log "Assumptions made" | Also log **Decisions** (what was chosen and why) and **Releases** (commit, evidence, outcome) in `STATE.md` | Your review edit; releases need an audit trail. |
| Autonomy policy forbids questions | Add: voice instructions that are destructive, deploy or push related are **read back and confirmed** | Speech-to-text mishears; sessions run in bypass. |

## 5. Architecture

```
~/bbq/ching/                  source of truth (local git repo; remote only if you ask, never technobbq)
  install.sh                  idempotent: backs up settings.json, merges hooks with jq, symlinks scripts
  bin/
    session-start.sh          injects .agent/STATE.md + NEXT.md (additionalContext)
    pre-compact.sh            writes a state snapshot
    stop-check.sh             runs GOAL.md test command; block + reason, max 3 retries per session id
    notify.sh                 terminal-notifier, repo name in title, click activates Claude app
    guard.sh                  PreToolUse deny rules (section 5.1)
    release-gate.sh           runs tests + checks verification evidence, mints a one-commit release token (5.2)
    post-release.sh           watches the deploy run, reports result, flags failure (5.2)
    migrate-gate.sh           dry run + migration lint before `db-migrate.ts --apply` is allowed (5.3)
    dash.sh                   one line per session; --speak, --inbox (needs you / ready / finished), --next (ranked)  [v4]
    ching-watch.sh            launchd every 5 min, one-shot: stall, context pressure, token totals, log rotation  [v4]
    lib.sh                    shared helpers, incl. ev (event log) and checkpoint_get  [v4]
  commands/handoff.md next.md installed to ~/.claude/commands/
  templates/                  GOAL.md STATE.md NEXT.md VERIFY.md REVIEW.md review-lenses/, AGENTS.md autonomy block, gitignore lines
  dispatcher/AGENTS.md        policy for the voice dispatcher session
  tests/                      shell tests run in a throwaway repo

~/.agent-repos                list of repos; worktrees discovered with `git worktree list`
<repo>/.agent/                GOAL.md STATE.md NEXT.md verify/ review/ (gitignored, per worktree)
~/.agent/                     sessions/<id>/ (meta, STATE.md, NEXT.md), events.jsonl, notify/, tokens/, defaults/  [v3/v4]
```

**Coexistence rule:** `install.sh` only *adds* hook entries. It never edits or removes `vscode-session-manager-hook.sh`. The one thing it removes is the blanket `osascript` "Session finished" popup, replaced by `notify.sh`, and only after you confirm.

**Voice path (Mac):**

```
you speak -> VoiceMode (local Whisper) -> dispatcher session
dispatcher: runs dash.sh, reads STATE.md files, answers aloud (local Kokoro)
dispatcher: "tell miso-app to X" -> read back if risky -> SendMessage -> worker session
worker: acts on it under its own guardrails, updates STATE.md, notifies on done/blocked
```

Workers never load VoiceMode. Only the dispatcher does, so there is one voice and no mic contention.

### 5.1 Guardrails (deny list v2)

Enforced by `guard.sh` as a `PreToolUse` hook, applies to every session. **Please confirm or edit this list.**

1. `rm -rf` on anything outside the current repo or a `/tmp` path.
2. `git push --force` / `--force-with-lease` / `+refs` on any branch.
3. A push to `main` **without a valid release token** for the exact commit being pushed (section 5.2). With a token, the push is allowed.
4. `vercel deploy` (any form), `bunx vercel ...`, and `gh workflow run`. This matches miso-app's own `AGENTS.md`: deploys come from CI only. Rolling back means pushing a revert commit through the gate.
5. Reading or printing `.env*` contents into the session (credentials). Scripts that read `.env` themselves, such as `db-migrate.ts`, are fine.
6. Supabase MCP `apply_migration`, `execute_sql` with anything other than read-only SQL, and Management API DDL. They bypass the ledger (this is miso's own rule). Migrations go through section 5.3.
7. Editing a migration file that is already committed, and `db-migrate.ts --record-only`. The runner refuses edited applied files anyway; `--record-only` needs human judgment.

8. *(v4)* Publishing: `npm`/`bun`/`pnpm`/`yarn` publish, `gh release create|delete|edit`, `gh repo delete`, `gh repo edit --visibility`, `gh repo create --public`, and *(D20)* pushing `v*` release tags.
9. *(v4)* Closing other people's items: `gh pr close`, `gh issue close|delete`, `gh api` calls that set `state=closed`. Commenting stays allowed.
10. *(v4, D18)* Sending: MCP send/reply/forward/post tools for Gmail, Slack, Discord and Telegram. Drafts stay allowed.
11. *(v4)* Gate settings: sessions may not add or change `review:`, `release_mode:` or `test_command:` in any `GOAL.md` (repo `.agent/` or `~/.agent/defaults/`).

A denied call returns a reason that tells the session what to do instead (open a PR, run the gate, or stop and notify).

### 5.2 Release path: how new work is tested and shipped (D8)

Your question was how to evaluate new tests and see them working in the app. My take: **tests prove the code, the running app proves the change, and a push to production needs both, recorded against the exact commit.** The CI that exists today is the last net, not the first.

What exists today (read from the repos):

| Repo | Gate in CI | What a push to `main` does |
|------|-----------|-----------------------------|
| miso | lint, format check, registry validate, typecheck, `bun test` (`ci.yml`, on pull requests and on pushes to `main`) | Nothing ships. miso is an npm package (`miso-dto`): a release is a **`v*` tag push** (or `workflow_dispatch` with an existing tag), which runs `release.yml`: `verify` (the same checks plus `bun pm pack` and a tarball inspection for `dist/` and secrets), then `publish`, which waits for the `release` environment's required reviewer and publishes to npm with OIDC trusted publishing (tag must equal `package.json` version; a `-` in the version publishes to `next`, otherwise `latest`). The reviewer approval is the only human gate. *(read 2026-10-06, Phase 2.4)* |
| miso-app | `bun run build`, `typecheck`, `bun test app`, then a smoke test of `/api/config` after deploy | Deploys to production. A pull request builds a **preview that uses the real data**. |
| miso-workspace | `bun test packages` (local) | Triggers miso-app's Deploy, which moves `spaces.lock`, runs miso-app's gate, deploys. No pull request, no preview. |

**miso differs from the steps below (found in Phase 2.4):** a push to `main` is not a release, so the token flow in steps 4-5 gates only the merge. The release itself is a tag push, and `guard.sh` does not deny `git push origin v*` or `--tags` (probed 2026-10-06; rule 8 denies `gh release create` and package publishing commands, not tags). What stops a bad publish is the `release` environment's required reviewer on GitHub. **Decided 2026-10-06 (D20):** guard rule 8 denies pushing `v*` tags (and `--tags`, `--follow-tags`, tag-pushing config). A session prepares the tag locally and notifies; the user pushes it, and the `release` environment reviewer still approves the publish.

The steps a session follows before shipping:

1. **Tests green locally**, using the repo's own commands from `GOAL.md` (miso: lint, format:check, typecheck, test; miso-app: build, typecheck, test; miso-workspace: test). The Stop hook already refuses to end while they fail.
2. **See it working in the real app.** The session drives the app in a browser (Chrome DevTools MCP or Claude in Chrome, both installed): open the changed view, exercise it, check console and network for errors, take a screenshot. Where:
   - miso: local dev server (`bun run dev`).
   - miso-app: local dev server; for spaces changes, `SPACES_ROOT=~/.miso bun run dev` shows uncommitted spaces in the real hosted app (documented in miso-app's `AGENTS.md`). The PR preview is used for a final read-only look.
   - miso-workspace: there is no preview, so verification is the miso-app local run with `SPACES_ROOT`.
   - **Write actions are never exercised on a preview** (it uses real data, and the repo rule says so). Write paths are proven by tests and the local run.
3. **Evidence file.** The session writes `.agent/verify/<commit-sha>.md`: what it exercised, URLs, screenshot paths, "no console errors", or "no UI surface" with the reason.
3b. *(v4)* **Evidence also has a `## not examined` section** (at least 10 characters): what the verification deliberately did not check.
3c. *(v4, D14)* **Review.** A fresh read-only reviewer subagent reads the diff with three lenses (`templates/review-lenses/`: error-resilience, identity, simulation) and writes `.agent/review/<commit-sha>.md`: `blocking: <n>`, findings, a `resolved:` line under every blocking finding, and `## not examined`. Required in every repo unless its `GOAL.md` says `review: off` (only the user can write that, guard rule 11).
4. **`release-gate.sh`** checks: clean tree, up to date with `origin/main`, test command passes, evidence file exists for this exact `HEAD`, and *(v4)* the review file is valid for this `HEAD`. If all pass it writes a token valid for that one commit.
5. **`guard.sh` allows `git push origin HEAD:main`** only when the token matches `HEAD`. A new commit invalidates the token.
6. **`post-release.sh`** watches the deploy run (`gh run watch`), reports the result into `STATE.md` under **Releases**, and sends a notification. If CI fails or the smoke test fails, the session may push **one revert commit** (it still passes the gate's clean-tree and token checks), then stops and notifies you.

Release mode per repo, set in `GOAL.md`: `auto` (gate passes, push) or `confirm` (gate passes, notify "ready to push", wait for you). Recommended: **`confirm` for the first release in each repo, then `auto`.**

### 5.3 Migrations (D9)

Facts from miso's `.agents/rules/migrations.md` and `scripts/db-migrate.ts`: there is **one shared Supabase project and no staging**, so applying a migration changes the live database. The runner tracks a ledger, runs each file in one transaction, and refuses to run if an applied file was edited. So:

- **Create:** a session writes the next numbered file `db/migrations/NNNN_name.sql` (RLS on every table, explicit grants, no `anon`, no top-level BEGIN/COMMIT; this is already miso's rule).
- **Update:** "update a migration" means a **new numbered file** that alters the earlier one. Editing an applied file is denied (guardrail 7).
- **Run:** `migrate-gate.sh` runs the dry run, checks that the pending list is exactly the files this session created, lints them (RLS, grants, no `anon`, no top-level transaction), and runs the migration tests. Only then is `bun scripts/db-migrate.ts --apply` allowed.
- **Additive changes** (new table, new column, new index, new policy) run autonomously.
- **Destructive changes** (`DROP TABLE`, `DROP COLUMN`, `TRUNCATE`, `DELETE` or `UPDATE` without `WHERE`, narrowing a type) are blocked until a `db/rollback/<name>.down.sql` exists **and you confirm**. Everything is logged in `STATE.md`.
- **Credential:** the runner needs `SUPABASE_ACCESS_TOKEN`, a personal access token with manage rights in the zackBBQ org. That is a broad credential, so sessions never print it (guardrail 5), and I'd like your view on whether to issue a narrower one if Supabase offers it.
- **Possible safety net:** a Supabase database branch to test a migration before the shared project. I have not checked whether your plan has branching or what it costs; Phase 0 checks this read-only, and creating a branch is something I'd ask you about first.

## 6. Step-by-step plan

Order matters. Each phase has a **checkpoint**; I stop there.

### Phase 0: Verify assumptions (throwaway only, no real repos touched)

Work in `/tmp/agent-sandbox` (a fresh git repo). Back up `~/.claude/settings.json` first.

- [ ] **0.1** Test a `PreToolUse` deny hook under `claude -p --permission-mode bypassPermissions`. Also test `permissions.deny` rules in bypass mode.
- [ ] **0.2** Test `Stop` hook JSON: block with reason, find the exact loop-prevention field, confirm the 3-retry cap works.
- [ ] **0.3** Test `Notification` matchers `agent_needs_input` and `agent_completed` in a normal foreground session.
- [ ] **0.4** *(You do one step)* Start one Desktop Code-tab session and one VS Code session in the sandbox. A logging `SessionStart` hook records whether it fired in each.
- [ ] **0.5** *(You do one step)* With two sessions running, send a `SendMessage` from one to the other while the target is (a) busy and (b) idle. Record whether the idle one wakes and acts.
- [ ] **0.6** Install VoiceMode with local Whisper + Kokoro (pin the version, install `ffmpeg portaudio` via brew, `uv` if missing). Measure time from end-of-speech to first spoken word. Confirm macOS mic permission for the app you run it in.
- [ ] **0.7** Start two sessions that both call `converse`. Confirm the second waits instead of talking over the first.
- [ ] **0.8** Browser verification harness: in the sandbox, serve a tiny page, have a session open it with Chrome DevTools MCP, exercise it, read console/network, take a screenshot, and write an evidence file. Confirms the "see it working" step in 5.2 before it is relied on.
- [ ] **0.9** Release token mechanics: in the sandbox with a local bare remote standing in for `origin`, confirm `guard.sh` denies a push to `main` with no token, allows it with a token for `HEAD`, and denies it again after a new commit.
- [ ] **0.10** *Read-only:* check whether your Supabase plan offers database branching (list branches / project details). Nothing is created.

**Checkpoint 0:** a results table (pass/fail per item, with evidence). Anything that fails switches that part of the design to its fallback in section 3. You approve before Phase 1.

### Phase 1: Build the core kit (still no real repos)

- [ ] **1.1** Create the project structure from section 5. Version it with a **local** `git init` in `ching` (see question 3). No GitHub remote is created in this step.
- [ ] **1.2** `brew install terminal-notifier`; write `notify.sh`; find the Claude app bundle id for click-to-activate.
- [ ] **1.3** Write `session-start.sh`, `pre-compact.sh`, `stop-check.sh`, `guard.sh`, using the schemas confirmed in Phase 0.
- [ ] **1.4** Write `handoff.md` and `next.md` slash commands.
- [ ] **1.5** Write templates: `GOAL.md`, `STATE.md`, `NEXT.md`, the `AGENTS.md` autonomy block, gitignore lines.
- [ ] **1.6** Write `dash.sh` (including `--speak`) and the `~/.agent-repos` format.
- [ ] **1.7** Write `release-gate.sh`, `post-release.sh` and the verification-evidence template (5.2), and `migrate-gate.sh` with its migration lint (5.3). Add `release_mode` and the per-repo test command to the `GOAL.md` template.
- [ ] **1.8** Write `install.sh`: idempotent, backs up `settings.json`, shows a diff before applying.
- [ ] **1.9** Tests in a throwaway repo: SessionStart injects, Stop retries then ends, notification shows repo name, each guardrail denies, the release token flow (no token, valid token, stale token), a destructive migration is blocked while an additive one passes, running `install.sh` twice changes nothing.

**Checkpoint 1:** test output plus the exact `settings.json` diff. You approve before `install.sh` touches your real settings. **Done: approved, hooks installed (D13, `CHECKPOINT-1.md`).**

### Phase 1.5: Hermes harvest (v4; design in `docs/superpowers/specs/2026-10-05-hermes-harvest-design.md`)

Built per D10: the shared contracts land first, then parallel implementers on disjoint files, then a separate verifier. TDD in the existing harness. The detailed task list lives in the implementation plan under `docs/superpowers/plans/`.

- [x] **1.5.1** Contracts: `ev` and `checkpoint_get` in `lib.sh`; checkpoint block in `templates/STATE.md` and `/handoff`; `t_events.sh`.
- [x] **1.5.2** Events from every hook and gate (session-start, pre-compact, stop-check, guard after its decision, release/migrate/post-release).
- [x] **1.5.3** `notify.sh`: `done` goes to the inbox instead of a push; budget of 4 non-urgent alerts a day, 09:00-21:00, 45-minute cooldown; `input`/`blocked`/`ready` always delivered.
- [x] **1.5.4** `ching-watch.sh` + launchd plist via `install.sh`: stall after 20 minutes, context levels (healthy under 60%, watch, handoff over 80%), daily token totals with optional `TOKEN_BUDGET_DAILY`, event-log rotation.
- [x] **1.5.5** `dash.sh`: `ctx` and `tok` columns, `--inbox`, `--next` (U×I×R), new `--speak` wording; dispatcher policy uses the inbox.
- [x] **1.5.6** `stop-check.sh`: in repo mode, block once per prompt when the checkpoint is missing or stale. (Sequence after the in-flight `test-escalate` edits to this file.)
- [x] **1.5.7** Review hardening: `## not examined` in VERIFY.md, `templates/REVIEW.md`, three lens prompts, review checks in `release-gate.sh`, `review: required` in the defaults `GOAL.md`.
- [x] **1.5.8** Guard rules 8-11 with deny and allow tests; wider guard matcher in `install.sh`.
- [x] **1.5.9** Autonomy block: checkpoint every turn, name the exact missing piece, the review step, drafts only.
- [x] **1.5.10** Verification agent: full suite plus shellcheck, `live-smoke.sh` shows events, and the error-resilience lens run over `guard.sh` and `stop-check.sh` (findings fixed or logged).

**Checkpoint 1.5:** test output, the `settings.json` and launchd diff, and the lens findings. You approve before `install.sh` re-runs on your real settings. Report: CHECKPOINT-1.5.md.

### Phase 1.6: Check-in nudges (spec and plan in `docs/superpowers/`; D19)

- [x] **1.6.1** `speak.sh`: say a sentence through the local Kokoro service.
- [x] **1.6.2** `notify.sh`: the budgeted `waiting` kind.
- [x] **1.6.3** `ching-watch.sh`: detect waiting sessions and send the banner for finished sessions with open work.
- [x] **1.6.4** `ching-watch.sh`: one spoken note per waiting spell (presence, voice lock, quiet hours, speech gap).
- [ ] **1.6.5** Live smoke section, docs, and the real-machine check from launchd. (real-machine check from launchd pending)

**Checkpoint 1.6:** test output, the `ching-watch.sh` diff and the real-machine check. You approve before `nudge` merges into `main`.

### Phase 2: Pilot on a couple of real sessions across different folders (2-3 days of real use)

- [x] **2.1** Run `install.sh` on your real `~/.claude/settings.json` (machine-wide from this point; no per-repo setup is needed for hooks, state, notifications, `dash.sh` or the guardrails). *Done 2026-10-06 10:01 after the user chose "install as designed" (rule 10 denies Telegram/Discord/Gmail/Slack reply and send tools for sessions). Backup `~/.claude/settings.json.bak.ching.20261006-100147`; launchd job `org.ching.watch` loaded; a second run changed nothing; the watcher logged `context` events.*
- [ ] **2.2** *(prepared 2026-10-06: miso opted in through the worktree `~/bbq/.worktrees/miso-ching-pilot`, branch `ching-pilot`, `release_mode: confirm`. miso's `bun test` has failed on main since 2026-10-02 (7 local-registry tests), so the first pilot task there is getting CI green. First task done locally 2026-10-06: the failing tests came from the root `overrides: { zod: ^4.4.3 }` forcing zod 4 onto shadcn, which needs zod 3 (`deepPartial`); dropping the override gives shadcn its own zod 3.25.76 and leaves everything else on zod 4.4.3. Commit 70b0869 on `ching-pilot` (not pushed; the full miso gate is green, 2612 tests). It still has to reach main through a normal feature branch and PR, since `ching-pilot` is never pushed. Pilot folders picked 2026-10-06: the miso worktree above, plus `~/bbq/bbqos` (plain repo on main, not opted in, so it exercises the machine-wide hooks without a `GOAL.md`). No real non-repo working folder exists on this machine (the AIW shared drive is a git repo), so the third slot stays open until real non-repo work comes up.)* Pick two or three real sessions in different folders (for example one repo, one worktree, one non-repo folder). Optionally, in one repo on a branch: add the autonomy block to `AGENTS.md`, add gitignore lines, write `.agent/GOAL.md` with the real test command (from `package.json`) to opt that repo into the Stop check and the release/migrate gates.
- [ ] **2.3** Work normally with those sessions. Record the three metrics in section 7.
- [ ] **2.4** Read miso's `release.yml` and fill in its release path in 5.2 *(done 2026-10-06; it is a tag-triggered npm publish, see 5.2)*. Run the browser verification step for real on one change *(open: needs a real change)*.
- [ ] **2.5** If a migration is needed during the pilot, run it through `migrate-gate.sh` with you watching the first one.
- [ ] **2.6** *(v4)* Tune the notification budget, stall threshold and context levels from what the pilot shows (`notify` and `stall` events). The first real release goes through the review step with you watching.

**Checkpoint 2:** metrics review. We tune `GOAL.md` and the policy before adding anything.

### Phase 3: Voice, level A (dictate + spoken status)

- [ ] **3.1** Add `mcp__voicemode__converse` and the plugin's tool name to the permission allowlist.
- [ ] **3.2** Make `dash.sh --speak` available as a command the dispatcher (and you) can run.
- [ ] **3.3** Document the `/voice` push-to-talk fallback for dictating into the focused worker.

**Checkpoint 3:** you try it for a day; tell me what feels slow or wrong.

### Phase 4: Voice, level B (dispatcher session)

Runs only if Phase 0.5 passed. If it failed, the dispatcher is status-only and relay stays manual via `/voice`.

- [ ] **4.1** Create the dispatcher: `dispatcher/AGENTS.md` (short spoken replies, never edits code, read back and confirm destructive/deploy/push instructions, refuses to relay anything the guardrails would deny).
- [ ] **4.2** Give it only: `dash.sh`, file reads of `STATE.md`, `ListAgents`, `SendMessage`, `converse`.
- [ ] **4.3** Acceptance test, spoken: "What's blocked?", "What did miso finish?", "Tell miso to run the tests again", and a risky one ("push miso-workspace") that must be read back and refused or confirmed.

**Checkpoint 4:** you try the four acceptance phrases and judge.

### Phase 5: Roll out to the other repos

- [ ] **5.1** miso-app (guardrails 3 and 4 and the release gate must already be active and tested). `release_mode: confirm` for the first release, you watch it land, then switch to `auto`.
- [ ] **5.2** miso-workspace, last. Add the `spaces.lock` / deploy-chain note to its `GOAL.md` so sessions know a push releases to production with no preview. Same `confirm`-then-`auto` rule.
- [ ] **5.3** Add a cap reminder to `dash.sh`: warn when more than 5 sessions are active.

**Checkpoint 5:** a week of metrics across all three.

### Phase 6: Learning loop (D11), specified after the pilot

Gets its own spec once the pilot has produced real `events.jsonl` data. The design inputs harvested in v4 (spec section 7):
- lesson records `{task_type, what_worked, what_failed, do_differently, quality}`, with keyword-gated retrieval and the top 3 injected at SessionStart;
- decay scoring `importance × e^(−0.693·days/14)`; pruning is proposed, never automatic;
- consolidation into short scored facts under a size cap;
- per-task-type stats (stop retries, time to green, overturned assumptions) and habits derived from transcripts;
- a blind-spot ledger built from recurring `not_examined` lines;
- a skill-candidate miner: repeated 3-6-step workflows across 3 or more sessions on 2 or more days become `~/.agent/proposals/skill-<slug>.md`, which you approve and skill-creator builds.

Everything writes only to `~/.agent/proposals/`. The model call is a local `claude -p` started by launchd. It never writes skills, guard or settings by itself.

### Later (not scheduled)

- Phone voice via VoiceMode Connect (routes audio through voicemode.dev's cloud; needs your explicit decision).
- ~~Director loop~~: replaced by the Phase 6 learning loop (D11).
- Cloud sessions for long migrations. Hooks may not fire there; test first.
- `ching-ui` Claude Code mod (D23), only if the pilot shows visibility or notification as the weak spot: read-only pane for `dash.sh --inbox`/`--next`, status-line entry, toasts for other sessions' events. Never enforcement.

## 7. How we judge it (pilot metrics, from your original doc)

1. Times a session stopped to ask you something.
2. Logged assumptions you had to overturn.
3. Minutes per handoff (switching to a session and being productive).

Coordination-specific (v4, read from `events.jsonl`): notifications delivered vs suppressed per day; stalls detected, and how many were real; `/handoff` runs triggered by the context watcher; review findings marked blocking per release.

Voice-specific: end-of-speech to first spoken word (target to be set from Phase 0.6, not guessed now); mishears that led to a wrong instruction being relayed (target: zero reaching a worker unconfirmed).

Reading the results: too many questions means a vague `GOAL.md` or a missing test command. Confident wrong choices means tightening the decision policy and done-criteria.

## 8. Risks

| Risk | Mitigation |
|------|------------|
| Guardrails don't fire in bypass mode | Phase 0.1 tests it before anything else; fallback layers named in section 3. |
| A bad change reaches production | Release gate (tests + browser verification + evidence tied to the commit), CI gate and smoke test as the second net, one-revert rule, `confirm` mode for the first release per repo. |
| Preview deployments use real data | Previews are looked at read-only; write paths are proven by tests and the local run. |
| A migration changes the live shared database (no staging) | Ledger runner only, migration lint, additive-only autonomy, destructive changes need your confirmation and a rollback file. |
| Broad Supabase access token | Never printed into a session; narrower token if Supabase offers one (open question). |
| Deploy-chain accident (miso-workspace push goes to production) | Same release gate, rolled out last, tested before use. |
| Mis-heard voice command executed | Read-back rule for risky instructions, guardrails as backstop, and `STATE.md` logs every relayed instruction. |
| Third-party code with mic access (VoiceMode) | Pin the version, review the plugin's `plugin.json` and MCP launcher before install, local services only. |
| Editing your `settings.json` breaks existing hooks | Backup first, additive-only merge, diff shown before applying, idempotent installer. |
| `.agent/` state diverges between worktrees | State is per worktree by design; `dash.sh` lists each worktree separately. |
| Event log holds paths and one-line summaries | Local only, mode 0600, strings capped at 300 characters, never sent anywhere; you can delete it at any time. |
| A session forges a review file | Mechanical checks (commit, mtime, blocking items resolved, not-examined section) plus policy; same honest limit as the browser evidence. Verified in the pilot by you watching the first release. |
| Notification budget hides something important | `input`, `blocked` and `ready` bypass the budget; every suppressed alert is logged and shown in `dash.sh --inbox`. |
| A session switches off review | Guard rule 11 denies session edits to `review:`, `release_mode:` and `test_command:`. |
| Token cost of parallel sessions | Cap about 4-5 active sessions; strongest model for planning/review, cheaper model for well-specified execution. |

## 9. Questions for your review

1. **D4/D5/D6/D7:** are you happy with voice on the dispatcher only, local-only audio, miso as pilot, and the director deferred?
2. **Guardrail list (5.1) and release gate (5.2):** anything to add or remove? Do you want `confirm` for the first release per repo, then `auto`, or `auto` from day one?
3. **Where does the kit live?** It is personal tooling, not product code. Options: (a) local `git init` in `ching` only, no remote (recommended: history and rollback, nothing published); (b) a **private** repo under `westsoever/` for backup and a second machine, created only when you say so; (c) no git at all, `install.sh` copies from the folder. `gh` is already signed in as `westsoever`, so (b) needs no setup. It will not go under `technobbq/`.
4. **Supabase access (5.3):** is a narrower token than the current personal access token possible for you, and does your plan include database branching?
5. **Notification click:** should clicking a notification focus the Claude Desktop app, or VS Code?
6. **The "Session finished" popup:** OK to remove it once `notify.sh` replaces it? (v4: `done` no longer pushes at all, so the popup would be the only "finished" signal left.)
7. *(v4)* **Daily token budget:** set `TOKEN_BUDGET_DAILY` (alerts at 80% and 100%), or leave it unset and only show the `tok` column?
