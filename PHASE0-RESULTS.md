# Phase 0 results

Run on 2026-10-05, Claude Code 2.1.289, macOS. All tests ran in `/tmp/agent-sandbox` (fresh git repo, local bare remote `/tmp/agent-sandbox-remote.git`). No real repo, `~/.miso`, or real remote was touched. `~/.claude/settings.json` was backed up to `/tmp/agent-sandbox-backup/settings.json.20261005-131334` and verified unchanged afterwards (`diff` clean).

Test method: `claude -p --model haiku --permission-mode bypassPermissions --setting-sources project --settings <sandbox file> --max-budget-usd 0.30 --no-session-persistence` (helper: `/tmp/agent-sandbox/run.sh`). `--setting-sources project` keeps your user hooks (osascript popups, vscode-session-manager) and plugins out of the tests. Total spend is roughly $0.50.

## Summary table

| Item | Result | Fallback triggered (PLAN s3) |
|------|--------|------------------------------|
| 0.1 PreToolUse deny under bypass | **PASS** (hook JSON deny, hook exit 2, and `permissions.deny` all block) | none |
| 0.2 Stop hook block + loop field | **PASS** (`stop_hook_active`, per-session counter works; built-in cap observed) | none |
| 0.3 Notification `agent_needs_input` / `agent_completed` | **NOT TESTABLE headlessly: needs user** | Use `Stop` + `idle_prompt` and classify in script, unless the user test passes |
| 0.4 SessionStart in Desktop / VS Code | **NEEDS USER** (kit ready, steps below) | Per-repo `.claude/settings.json` hooks, or run managed sessions in CLI/VS Code |
| 0.5 SendMessage wakes idle session | **NEEDS USER** (docs say yes, unverified) | Dispatcher reports only; `/voice` into the worker |
| 0.6 VoiceMode (partial) | **RECORDED** (version, local services, lock path). Latency not measured | n/a |
| 0.7 Conch lock | **DESCRIBED from source, not run live.** Surprise: default is NOT "wait" | See 0.7 |
| 0.8 Browser verification harness | **PASS** via `claude -p` + chrome-devtools MCP (headless). Surprise: model self-verdict was wrong | Gate must check evidence mechanically |
| 0.9 Release token mechanics | **PASS**, with documented regex gaps; add `pre-push` backstop | Both layers recommended |
| 0.10 Supabase branching | **Free plan; branching is Pro-only** | No DB branch safety net; see 0.10 |

---

## 0.1 PreToolUse deny under bypassPermissions: PASS

Settings: `/tmp/agent-sandbox/settings-hook.json` (PreToolUse, matcher `Bash`, command `hooks/guard-json.sh`) and `/tmp/agent-sandbox/settings-permdeny.json`.

Hook stdin (logged) confirms the hook ran in bypass mode:

```
{"session_id":"...","cwd":"/private/tmp/agent-sandbox/repo","permission_mode":"bypassPermissions","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"touch /tmp/agent-sandbox/marker_json_DENYJSON"}, ...}
```

| Case | Mechanism | Command | Marker file created? | What the model saw |
|------|-----------|---------|----------------------|--------------------|
| A | hook, stdout JSON `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"..."}}`, exit 0 | `touch .../marker_json_DENYJSON` | No | `PreToolUse:Bash hook error: GUARD: blocked by json deny hook; open a PR instead` (the reason text reaches the model) |
| B | hook, stderr text + exit 2 | `touch .../marker_exit2_DENYEXIT2` | No | `PreToolUse:Bash hook error: [/tmp/agent-sandbox/hooks/guard-json.sh]: GUARD: blocked by exit2 hook` |
| C | control (hook present, non-matching command) | `touch .../marker_control` | Yes | ok |
| D | `permissions.deny: ["Bash(touch /tmp/agent-sandbox/marker_perm*)"]`, no hook | `touch .../marker_perm_x` | No | "Permission to use Bash with command ... has been denied." |
| E | control for D (other filename) | `touch .../marker_other` | Yes | ok |

Conclusion: **both layers block in bypass mode.** D1 holds. Use both: hook for logic (tokens, regex), `permissions.deny` as a cheap static layer. Not tested: hooks defined in `~/.claude/settings.json` specifically (tests used `--settings` and project files; same hook engine, but the installer test in Phase 1 should repeat this against a user-level hook).

## 0.2 Stop hook: PASS

Docs said (via claude-code-guide): `stop_hook_active`, `decision:"block"`, built-in cap of 8. All confirmed by test.

Stop stdin keys (observed): `background_tasks, cwd, hook_event_name, last_assistant_message, permission_mode, prompt_id, session_crons, session_id, stop_hook_active, transcript_path`. Note `last_assistant_message` is available, which can help `stop-check.sh`.

Block output: `{"decision":"block","reason":"..."}` on stdout, exit 0. The model continues with `reason` as its next instruction.

**Loop-prevention field: `stop_hook_active`.** It is `false` on the first Stop of a turn and `true` on every Stop after a block (until the model ends the turn naturally).

Test 1, hook with per-session counter file (`/tmp/agent-sandbox/retries/<session_id>`), blocking while count < 3, ignoring `stop_hook_active`:

```
block sid=49d8306f... n=1 active=false
block sid=49d8306f... n=2 active=true
block sid=49d8306f... n=3 active=true
capped sid=49d8306f... n=3 active=true     <- hook exits 0, session ends
```

A second session got its own counter file (`ebb1a404...`, value 3): counters are independent per session id.

Test 2, hook that always blocks with no cap of its own (`hooks/stop-always.sh`): the hook was invoked **9 times** (1 with `active=false`, 8 with `true`), then Claude Code ended the session itself. This matches the documented built-in cap of 8 consecutive blocks (override: `CLAUDE_CODE_STOP_HOOK_BLOCK_CAP`). The final `result` was empty. So our own cap of 3 per session id is enforceable and sits safely under the built-in cap.

Design note for `stop-check.sh`: the counter is what enforces "3 retries"; `stop_hook_active` alone would allow only 1 retry if used as the exit condition. Use the counter, and reset it when the checks pass.

## 0.3 Notification matchers: NOT TESTABLE headlessly (needs user)

- In `claude -p`, a Notification hook (matcher `""`, logging) **did not fire** for a normal short run (`logs/notification.log` never created), while SessionStart and Stop hooks did fire in the same run.
- Docs (via claude-code-guide, hooks-guide): `agent_needs_input` and `agent_completed` are for **background sessions while the agent view is open**, i.e. `claude --bg` / `claude agents`. `idle_prompt` fires about 60 s after a response; `permission_prompt` about 6 s into a permission wait. None can occur in `-p` bypass runs.
- `claude --bg` in the sandbox failed with "Workspace not trusted. Run `claude` in /private/tmp/agent-sandbox/repo once and accept the trust prompt". I did not accept it on your behalf (that writes to your Claude state).

Important implication: per the docs, `agent_needs_input` / `agent_completed` are **not** for normal foreground sessions. The plan's fallback (Stop + idle_prompt, classify in script) is probably the real design. To check, see "User steps" below.

## 0.4 and 0.5: needs user (instructions at the end)

## 0.6 VoiceMode (partial, nothing installed or changed)

- Version: `voicemode --version` gives `VoiceMode, version 8.12.0`; plugin cache dir `~/.claude/plugins/cache/voicemode/voicemode/8.12.0p0/`.
- Whisper: `voicemode whisper service status` gives "running locally", port 2022, model `ggml-large-v2.bin`, whisper.cpp v1.9.4, Core ML enabled, Metal GPU, ~3.3 GB RAM.
- Kokoro: `voicemode kokoro status` (deprecated alias of `voicemode service status kokoro`) gives "running locally", port 8880, v0.2.4.
- Both are local, so D5 (no audio leaves the machine) holds for the current install. I did not verify what other provider/URL settings `voicemode.env` contains (not read, may hold keys).
- Conch lock path: `~/.voicemode/conch` (JSON file; it was present at 13:13 and gone minutes later, so it is transient).
- Latency: not measured (needs a human speaking).

## 0.7 How the conch works (source: `voice_mode/conch.py`, `tools/converse.py`, `config.py`; read-only, no live sessions run)

- One JSON lock file `~/.voicemode/conch` holds `pid`, `agent`, `acquired` and (for holds) `expires`. Exclusive access is via a kernel file lock (`lock_exclusive`) plus the payload.
- `converse` calls `conch.try_acquire()` before speaking. Stale locks are cleared automatically: dead holder pid (checked with `psutil.pid_exists`), or older than `CONCH_LOCK_EXPIRY` (default 300 s) for an active lock, or `CONCH_HOLD_EXPIRY` (default 10 s) for a between-turns "hold".
- A FIFO waiter queue (`ConchQueue`) exists with grants (`CONCH_GRANT_TTL` 30 s); `voicemode conch status` shows it.
- **Surprise: the default does NOT wait.** `converse(..., wait_for_conch=False)` is the default. If another agent holds the conch, the call returns immediately with the text "`<agent>` currently holds the voice channel — your message was NOT spoken, and you are NOT queued." Waiting requires `wait_for_conch=true` (modes `wait` or `callback`; max wait `VOICEMODE_CONCH_TIMEOUT` 300 s; MCP wait cap 25 s). `skip_conch=true` bypasses the lock entirely.
- Consequence for the plan: a worker that accidentally calls `converse` is silently refused (good, it will not talk over the dispatcher), but it also will not queue. The dispatcher-only design (D4) is safe as is. The "second session waits" claim in plan 0.7 is only true with `wait_for_conch=true`. Not verified live.

## 0.8 Browser verification harness: PASS (with a warning)

Setup: `python3 -m http.server 8765` serving `/tmp/agent-sandbox/site/index.html` (a counter button, one `console.warn`, two `console.log`, a `fetch('/ping')` that 404s). MCP config `/tmp/agent-sandbox/mcp-devtools.json`: `npx chrome-devtools-mcp@1.9.0 --headless --isolated` (same package/version as your plugin; headless and isolated profile, so your own Chrome is untouched). Run through `claude -p --strict-mcp-config --mcp-config ...` (15 turns, $0.07, haiku).

Result: the session opened the page, clicked Increment twice, read "Count: 2", listed console and network, took a screenshot, and wrote the evidence file. Evidence: `/tmp/agent-sandbox/.agent/verify/2ea28173656277bc79de9aaf2916505c104236dd.md` and `.png` (screenshot verified by eye: "Sandbox Counter / Count: 2 / Increment"). Network listing: `GET / 200`, `GET /favicon.ico 404`, `GET /ping?n=1 404`, `GET /ping?n=2 404`.

**Surprise / design finding:** the evidence file lists `[error] Failed to load resource ... 404` console entries and 404 requests, yet its Verdict says "PASS ... No application errors" and "Console errors: No". The model rationalised its own failures. So `release-gate.sh` must **not** trust a model-written verdict. Make the gate parse the evidence file for structured fields (e.g. a machine-readable `console_errors: N` / `failed_requests: N` block copied from tool output, with a required `allowed:` list for known-benign entries like favicon) and fail on non-zero; or have the evidence template force the model to paste raw console/network lines and have the gate grep them.

Also: with `--setting-sources project` plugins are not loaded, so the harness must pass the MCP config explicitly (as done). In a normal session the plugin's `chrome-devtools` MCP is available as is. Claude-in-Chrome was not tested (it drives your real browser; not needed since DevTools MCP works headlessly).

## 0.9 Release token mechanics: PASS (with gaps)

Prototype: `/tmp/agent-sandbox/hooks/guard.sh` (v1) and `guard2.sh` (hardened); token file `repo/.agent/release-token` holding the full HEAD sha; `origin` = local bare repo only.

Live, through `claude -p` under bypass + PreToolUse hook (v1):

| Step | Command | Outcome |
|------|---------|---------|
| 1 no token | `git push origin HEAD:main` | DENIED: "no release token. Run release-gate.sh first." Remote unchanged |
| 2 token = HEAD | same | ALLOWED, pushed (`[new branch] HEAD -> main`) |
| 3 new empty commit, token stale | same | DENIED: "release token is for 954c9e1 but HEAD is 2ea2817" |
| 4 `git push --force ...` | | The model itself refused before calling the tool, so the guard was not exercised live (covered by unit test below) |
| 5 re-minted token, `cd repo && git push origin HEAD:main` | | ALLOWED, `954c9e1..2ea2817` |
| 6 `git push origin feat` | | ALLOWED (non-main unaffected) |

Unit tests of the guard script by piping hook JSON (`/tmp/agent-sandbox/unit-guard.sh [script]`):

- v1 passed 14 of 17. Misses: `git -C <dir> push origin HEAD:main`, `bash -c "git push origin HEAD:main"` (trailing quote), `HEAD:m""ain`, `HEAD:$B`.
- v2 (looser `git ... push` match, quote terminators, `--no-verify` on push denied) passed 15 of 17. **Remaining misses: shell obfuscation (`HEAD:m""ain`, `HEAD:$B`)**. A regex on the command string cannot close that.
- Second layer: a git `pre-push` hook (`.git/hooks/pre-push`, reads `<local ref> <local sha> <remote ref> <remote sha>` on stdin, compares the pushed sha to the token for `refs/heads/main`) **blocked both obfuscated forms**, because it sees resolved refs. But `git push --no-verify` bypassed it (push to the local bare remote went through with a stale token); `guard2.sh` denies `--no-verify` on a push, so the layers cover each other. (The bypass push landed in the sandbox bare remote only; I reset the sandbox repo afterwards.)

Recommendation: ship both. `guard.sh` (PreToolUse, token + force + `--no-verify` + deploy commands) and a `pre-push` hook per repo (miso already has `.githooks/`; set `core.hooksPath`). Add a deny for `git config core.hooksPath` / `rm .githooks` style edits, otherwise the agent can disable the backstop. Neither stops an agent that writes a script file that pushes; `permissions.deny` can't either. That residual risk should be accepted explicitly or covered by GitHub branch protection (not tested, out of scope).

## 0.10 Supabase branching (read-only): Free plan, not available

- `list_organizations`: one org, TechBBQ. `get_organization`: `"plan":"free","tier":"tier_free"`.
- `list_projects`: `zackBBQ` (eu-central-1, ACTIVE_HEALTHY, Postgres 17) and `zwirn` (INACTIVE).
- `list_branches` on zackBBQ: `{"branches":[]}` (no error, but also not conclusive on its own).
- Supabase docs (`search_docs`, "Deployment & Branching"): "Branching ... requires the Pro Plan." Branching compute is also billed outside the Pro compute credits.

Conclusion: your org is on the Free plan, so DB branching is **not** available without upgrading to Pro. The "test a migration on a branch first" safety net in 5.3 is out unless you upgrade. Related caution (from docs knowledge, not checked in the dashboard): Free-plan projects do not get point-in-time recovery, so the rollback-file requirement for destructive migrations carries more weight. Nothing was created.

---

## User steps (0.3, 0.4, 0.5)

Ready-made logging hook: `/tmp/agent-sandbox/hooks/log-client.sh` (logs event name, `CLAUDE_CODE_ENTRYPOINT`, `TERM_PROGRAM`, whether VS Code, session id, `source`, `notification_type`; whitelisted env vars only, no token leakage). Config already in place at `/tmp/agent-sandbox/repo/.claude/settings.json` (copy: `/tmp/agent-sandbox/settings-sessionstart-log.json`) with SessionStart, UserPromptSubmit, Notification, Stop. Log file: `/tmp/agent-sandbox/logs/clients.log`.

**0.4 (one step per client):** open the folder `/tmp/agent-sandbox/repo` in (a) the Claude Desktop Code tab and (b) VS Code with the Claude extension, accept the trust prompt, send one message like "hi". Then run `cat /tmp/agent-sandbox/logs/clients.log`. PASS for a client = a `SessionStart` line whose `entrypoint` identifies it. This tests project-level hooks; if it passes, also repeat once with a user-level hook before relying on `~/.claude/settings.json` hooks in that client (or just add the install to settings in Phase 1 and re-check).

**0.3 (same folder):** in a terminal, `cd /tmp/agent-sandbox/repo && claude --bg "Reply with just: ok"` (after trusting the folder once, from 0.4 or `claude` interactively), then open `claude agents` and leave the agent view open, and start a second background session that asks a question and waits (e.g. "Ask me which colour I want, then wait"). Check `clients.log` for `event=Notification` lines with `notification_type=agent_completed` / `agent_needs_input`. Also leave one plain foreground `claude` session idle for about 70 s to see `idle_prompt`. If `agent_*` types never appear for foreground sessions, that confirms the fallback: Stop + `idle_prompt`.

**0.5:** start two sessions in `/tmp/agent-sandbox/repo`, name them (`claude -n alpha`, `claude -n beta`). In alpha: ask it to `ListAgents` and `SendMessage` "append the word ping to /tmp/agent-sandbox/work.txt" to beta (a) while beta is mid-task (e.g. beta is running `sleep 60` via Bash) and (b) after beta is idle at its prompt. PASS = `work.txt` gains `ping` in both cases without you touching beta. Docs claim an idle session "starts a new turn with the message"; this is unverified on this machine.

## Files left in /tmp (all disposable)

`/tmp/agent-sandbox/` (repo, hooks, settings files, logs, `run.sh`, `unit-guard.sh`, evidence), `/tmp/agent-sandbox-remote.git`, `/tmp/agent-sandbox-backup/`. The HTTP server was stopped; the chrome-devtools-mcp processes seen in `pgrep` were not killed because some may belong to other live sessions.
