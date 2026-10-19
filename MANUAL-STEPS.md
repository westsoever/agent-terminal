# Phase 0: manual steps for you

Everything here needs a human (a GUI app, a microphone, or a trust prompt). Tick the boxes as you go. Total about 45 minutes; items are ordered shortest first.

Everything runs in the throwaway sandbox `/tmp/agent-sandbox/repo`. Nothing touches miso, `~/.miso` or your real settings. The kit is backed up in `/Users/clyde/bbq/kaching/phase0-manual/` (`setup.sh` rebuilds the sandbox if `/tmp` was cleaned).

**Before you start (1 min):**

```
/Users/clyde/bbq/kaching/phase0-manual/setup.sh
```

This re-installs the logging hook in the sandbox and empties the log. The log file is `/tmp/agent-sandbox/logs/clients.log`. Your own user hooks (osascript popups) will still fire in these sessions; that is expected.

Reply format at the end of each item, e.g. `0.4 pass`, or `0.4 fail: <what you saw>`.

---

## - [x] 0.4 SessionStart hook fires in Desktop and VS Code (about 6 min) PASS 2026-10-05

**Why:** The whole kit injects `STATE.md` / `NEXT.md` through `SessionStart`. If a client ignores the hook, sessions started there start blind. Fallback if it fails: per-repo hooks, or run managed sessions in the CLI.

**0.4a VS Code (3 min)**

1. Run `code /tmp/agent-sandbox/repo` (or open that folder in VS Code).
2. Open the Claude extension panel, accept the "trust this folder" prompt, send `hi`.
3. In a terminal: `cat /tmp/agent-sandbox/logs/clients.log`

**0.4b Claude Desktop, Code tab (3 min)**

1. Open the Claude Desktop app, go to the Code tab, choose the folder `/tmp/agent-sandbox/repo`.
2. Accept the trust prompt, send `hi`.
3. Run `cat /tmp/agent-sandbox/logs/clients.log` again.

**Pass:** each client adds a line starting `event=SessionStart` (plus `UserPromptSubmit` and `Stop`). Note the `entrypoint=` value in each; it should differ between the two clients.
**Fail:** the client shows no `SessionStart` line, or only `UserPromptSubmit`/`Stop`.

**Tell Claude:** `0.4 pass`, or `0.4 vscode pass, desktop fail` (paste the log lines if odd).

---

## - [x] 0.5 SendMessage wakes an idle session (about 8 min) PASS 2026-10-05 (user-reported)

**Why:** The voice dispatcher relays "tell miso-app to X" with `SendMessage`. If an idle session ignores messages, the dispatcher can only report, not relay. Fallback: report-only dispatcher, you dictate with `/voice` into the worker.

**Steps**

1. Terminal 1: `cd /tmp/agent-sandbox/repo && claude -n beta --permission-mode bypassPermissions`
2. Terminal 2: `cd /tmp/agent-sandbox/repo && claude -n alpha --permission-mode bypassPermissions`
3. **Case (a), target busy.** In beta, type: `Run "sleep 60" with the Bash tool, then say done.` Straight away, in alpha, type:
   `Use ListAgents, then SendMessage to beta: "append the word ping to /tmp/agent-sandbox/ping.txt". Do not do it yourself.`
4. Wait until beta has finished and sits at an empty prompt. Check: `cat /tmp/agent-sandbox/ping.txt`
5. **Case (b), target idle.** Do not touch beta. In alpha, type:
   `SendMessage to beta: "append the word pong to /tmp/agent-sandbox/ping.txt". Do not do it yourself.`
6. Wait about 20 seconds, then `cat /tmp/agent-sandbox/ping.txt`. Look at beta's terminal too.

**Pass:** `ping.txt` contains `ping` after step 4 and `pong` after step 6, and you typed nothing into beta after step 3.
**Fail (give which case):** word missing; or beta only acts once you press a key; or alpha says the tool `ListAgents`/`SendMessage` does not exist (report that exact message).

**Tell Claude:** `0.5 pass`, or `0.5 fail: idle case only` / `0.5 fail: busy case only` / `0.5 fail: tool missing`.

---

## - [x] 0.6 VoiceMode latency (about 10 min) DONE 2026-10-05: too slow, see PHASE0-RESULTS.md

**Why:** If speech to first spoken reply is too slow, voice is unusable and we reconsider cloud STT/TTS (a separate decision). This number also sets the target for the pilot. Whisper (port 2022) and Kokoro (port 8880) were already running locally as of today.

**Steps**

1. Check services: `voicemode whisper service status` and `voicemode kokoro status` (both should say running).
2. Open the app you will actually use (Terminal, iTerm or VS Code) and `cd /tmp/agent-sandbox/repo && claude`.
3. If macOS asks for microphone access, allow it. If it never asks and nothing records, check System Settings > Privacy & Security > Microphone for that app.
4. Have stopwatch ready (phone). Type: `Use the converse tool: say "Ready" and listen for my answer. When I answer, reply by voice with one short sentence.`
5. After "Ready", say something short, like "What is two plus two?". Start the stopwatch the moment you stop speaking, stop it at the first spoken word of the reply. Repeat 3 times.
6. Expand the tool output (`ctrl+o`) and copy any timing line VoiceMode prints (STT time, TTS time) if present.

**Pass:** it hears you correctly 3 of 3 times, and the stopwatch times are about 3 seconds or less on average (this includes model thinking time).
**Fail:** no mic access, wrong transcripts, or a consistent delay above about 5 seconds.

**Tell Claude:** `0.6 pass, 2.4s avg` with the three numbers, or `0.6 fail: <reason>`.

---

## - [ ] 0.7 Two sessions, one voice (about 10 min) DEFERRED by user, to run later

**Why:** Plan says a second session waits instead of talking over the first. Phase 0 reading of the source found the default is the opposite: the second call is refused (not queued) unless it asks to wait. Live confirmation tells us the dispatcher-only design is safe, and that a worker which tries to talk gets silenced, not garbled.

**Steps**

1. Terminal 3 (watcher): `watch -n1 voicemode conch status` (if `watch` is missing: `while true; do voicemode conch status; sleep 1; clear; done`)
2. Terminal 1: `cd /tmp/agent-sandbox/repo && claude -n voiceA --permission-mode bypassPermissions`
3. Terminal 2: same with `-n voiceB`.
4. **Test 1, default behaviour.** In voiceA type: `Use converse to speak, without listening for a reply: count slowly from 1 to 25.` Within 3 seconds, in voiceB type: `Use converse to speak, without listening: "B is speaking".`
5. Watch the conch watcher while voiceA talks. Note what voiceB's tool result says.
6. **Test 2, waiting.** Repeat step 4, but tell voiceB: `Use converse with wait_for_conch set to true to speak "B is speaking".`

**Pass:**
- Test 1: you hear only A. B's result says A "currently holds the voice channel" and B was NOT spoken. No overlapping audio.
- Test 2: B waits, then speaks right after A finishes. Never both at once.
- The conch status shows A as holder during the count, and "free" afterwards.

**Fail:** two voices at once in either test, or B hangs and never speaks in Test 2, or the conch stays held after both finish (`voicemode conch status`).

**Tell Claude:** `0.7 pass`, or `0.7 fail: overlapped in test 1` / `0.7 fail: B never spoke in test 2`.

---

## - [ ] 0.3 Notification types for foreground vs background sessions (about 12 min) DEFERRED by user, to run later

**Why:** The plan uses `agent_needs_input` / `agent_completed` to decide when to notify you. Docs say these belong to background sessions with the agent view open. If they never fire in normal sessions, the design falls back to `Stop` + `idle_prompt` and classifies in a script (probably what we will do anyway).

Do 0.4 first: it also accepts the folder trust prompt, which `claude --bg` needs.

**Steps**

1. Terminal 1: `cd /tmp/agent-sandbox/repo && claude --bg "Reply with just: ok"`
2. Terminal 1: `claude --bg "Ask me which colour I want, then wait for my answer."`
3. Terminal 1: `claude agents` and leave the agent view open for about a minute. Answer the colour question in it, so one finishes and one needs input.
4. Terminal 2: `cd /tmp/agent-sandbox/repo && claude`, send `hi`, then leave it idle for 70 seconds.
5. Run: `grep Notification /tmp/agent-sandbox/logs/clients.log`

**Pass (design as written):** lines with `notification_type=agent_needs_input` and `notification_type=agent_completed` appear for the background sessions.
**Pass (fallback confirmed):** only `notification_type=idle_prompt` appears (from step 4), no `agent_*` lines. That is a useful result, not a failure: we use `Stop` + `idle_prompt`.
**Fail:** `claude --bg` errors (paste the message), or no Notification lines at all, not even `idle_prompt`.

**Tell Claude:** `0.3 agent_* fire`, `0.3 only idle_prompt`, or `0.3 fail: <message>`.

---

## When done

Reply with one line per item, for example:

```
0.4 pass
0.5 pass
0.6 pass 2.4s avg
0.7 pass
0.3 only idle_prompt
```

Cleanup (optional): `rm -rf /tmp/agent-sandbox /tmp/agent-sandbox-remote.git /tmp/agent-sandbox-backup`. Keep the backup until Phase 1 is approved.

---

## 2026-10-16: voice levels A and B, in one sitting (about 45 minutes)

Three steps only you can do (0.6, 0.7, 4.3) and one new two-minute check (V1). They need a microphone, your ears and a stopwatch. Nothing in them was run by the person who built Phase 3 and 4: no audio was played during the build.

**Before you start (5 minutes)**

1. `ching-b` is merged into `~/bbq/kaching` main, `install.sh` has been run on your real settings (it shows the diff and asks), and `install.sh --install-dispatcher` has been run. Check: `ls ~/.claude/commands/dash.md ~/.claude/kaching/dispatcher/tool-gate.sh ~/.agent/dispatcher/.claude/settings.json` lists all three.
2. `voicemode whisper service status` and `voicemode kokoro status` both say running locally.
3. The terminal app you will use has macOS microphone access (System Settings > Privacy & Security > Microphone).
4. Quiet room. Do the steps in this order: pick the pass line, V1, then 4.3 (which measures 0.6), then 0.7.

### - [ ] 0.6 First, pick the speed pass line (1 minute, before you measure anything)

**Picked 2026-10-16: 8 s (D25).** The measurement itself is still open; it happens during 4.3.

The 2026-10-05 measurement was 15 to 40 seconds from the end of your sentence to the first spoken word (`PHASE0-RESULTS.md`, 0.6). The voice pipeline itself was about 5 seconds (Whisper 2.9 s, Kokoro first audio 2.0 s); the rest was the model turn in a big session. The dispatcher is a small Haiku session with no plugins, which should shrink that part. These are estimates, not measurements of the dispatcher:

| Pass line | What it means |
|---|---|
| 5 s | About the pipeline floor. Needs a faster Whisper model as well. |
| 8 s | My suggestion for a first pass: the pipeline plus a short Haiku turn. |
| 12 s | Fine for "what's blocked?", tiring for a back and forth. |

Your call. Write your number in `docs/dispatcher-acceptance.md`, "Before you start", point 4, before you hear any result: a line picked after the result tests nothing.

### - [ ] V1 Hear `/dash` (2 minutes)

1. In any Claude session, type `/dash`.
2. You should hear one short paragraph (how many need you, which are blocked, how many are active) and see the same text printed.
3. Type `/dash --text`: the same text, silent.

**Pass:** you hear it, in one voice, and the words match the printed text. **Fail:** silence (run `voicemode conch status`: another session may hold the voice), a different voice or garbled audio, or the text names paths or ids.
**Tell Claude:** `V1 pass` or `V1 fail: <what you heard>`.

### - [ ] 4.3 The spoken dispatcher run, which also measures 0.6 (20 minutes)

Follow `docs/dispatcher-acceptance.md` from "Before you start" to "Record the result". Four phrases ("What's blocked?", "What did miso finish?", "Tell miso to run the tests again", "push miso-workspace"), each with its own pass and fail lines, plus an optional throwaway-session test of the "yes" branch.

Use the stopwatch on every phrase. The average of the four, against the line you picked, is the 0.6 result.

- **0.6 passes** when the average is at or under your line and it heard you correctly each time.
- **0.6 fails:** ask Claude to switch the Whisper model (`voicemode whisper model large-v3-turbo`, which installs it and restarts the local service; undo with `voicemode whisper model large-v2`). That changes your machine's voice service, so it waits for your word. Re-measure after.

**Tell Claude:** `4.3 pass`, or `4.3 fail: phrase 3, relayed to the wrong session`; and `0.6 pass 6.1 s average, line 8`, or `0.6 fail 11 s average, line 8`.

### - [ ] 0.7 Two sessions, one voice (10 minutes)

**Why:** every session has VoiceMode's converse tool (the plugin is enabled for all of them). Only the dispatcher is meant to speak. The voice lock (`~/.voicemode/conch`) is what stops a worker that tries from talking over it. The source says the second caller is refused, not queued, unless it asks to wait. This step confirms that live.

Stop the dispatcher first (`/exit`), so it does not hold the voice. If `/tmp/agent-sandbox` was cleaned, run `/Users/clyde/bbq/kaching/phase0-manual/setup.sh` first.

1. Terminal 3 (watcher): `watch -n1 voicemode conch status` (no `watch`? `while true; do voicemode conch status; sleep 1; clear; done`).
2. Terminal 1: `cd /tmp/agent-sandbox/repo && claude -n voiceA --permission-mode bypassPermissions`. Terminal 2: the same with `-n voiceB`.
3. **Test 1, default.** In voiceA: `Use converse to speak, without listening for a reply: count slowly from 1 to 25.` Within 3 seconds, in voiceB: `Use converse to speak, without listening: "B is speaking".` Watch the lock and read voiceB's tool result.
4. **Test 2, waiting.** Repeat step 3, but tell voiceB: `Use converse with wait_for_conch set to true to speak "B is speaking".`

**Pass:** test 1: you hear only A, and B's result says A "currently holds the voice channel" and B was not spoken. Test 2: B waits and speaks right after A finishes, never both at once. The lock shows A during the count and free afterwards.
**Fail:** two voices at once in either test; B hangs in test 2; the lock stays held after both finish (`voicemode conch status`).
**Tell Claude:** `0.7 pass`, or `0.7 fail: overlapped in test 1` / `0.7 fail: B never spoke in test 2`.

**When you are done:** reply with one line per item, for example `V1 pass`, `0.6 pass 6.1 s average, line 8`, `4.3 pass`, `0.7 pass`. Cleanup: `rm -rf /tmp/kaching-accept /tmp/agent-sandbox`.

---

## 2026-10-19: Agent Terminal (the rename from Kaching, D65)

Nothing here is needed to keep today's install running: every old name still works. Do these when the rename is merged, in this order. Each one is a few minutes.

**A. Move your machine to the new names** (from `~/bbq/kaching`, on main after the merge):

1. `./install.sh --dry-run`, read the diff, then `./install.sh --yes`. It writes `~/.claude/agent-terminal`, moves the hook entries in `~/.claude/settings.json` from `~/.claude/kaching/bin/` to `~/.claude/agent-terminal/bin/` (a backup `settings.json.bak.agent-terminal.<time>` is written first), replaces the jobs `org.kaching.watch` and `org.kaching.learn` with `org.agent-terminal.*`, and keeps `~/.claude/kaching` and `~/.claude/ching` as links. Check: a second `./install.sh` says `nothing to do`.
2. `terminal/build.sh`. It builds `~/.local/bin/agterm` and turns `~/.local/bin/kaching` into a link to it. A running `kaching` keeps the old code until you quit it (ctrl+c); start `agterm` instead.
3. `./install.sh --install-menubar --yes` replaces KachingBar with AgentTerminalBar. It is a new app to macOS: System Settings > Privacy & Security > Accessibility, remove KachingBar and add `~/Applications/AgentTerminalBar.app` (needed for the voice shortcut only). The first hotkey press asks again whether it may control Terminal: click OK.
4. `./install.sh --install-dispatcher --yes` (only if you use the voice dispatcher) writes its settings with the new link. The old settings keep working until then.
5. Raycast: Settings > Script Commands: re-add `ui/raycast` if the folder was added, and give the three renamed commands (`Next Waiting Agent`, `Tile Terminals`, `Open Agent Terminal`) their hotkeys again. The menu bar hotkeys in `~/.agent/hotkeys` need nothing.
6. Optional: repos with the pre-push hook keep working through `~/.claude/kaching`. To point them at the new link: `./install.sh --install-prepush <repo>`.
7. Optional: if your shell profile or a script sets `KACHING_*` variables, rename them to `AGENT_TERMINAL_*` when convenient; the old names still count.

**B. Rename the GitHub repo and the folder, last** (after the PR is merged and every other kaching branch or worktree is merged or closed; close the Claude sessions that run in `~/bbq/kaching` first):

1. `gh repo rename agent-terminal -R westsoever/ching`. GitHub redirects the old URL.
2. In `~/bbq/kaching`: `git remote set-url origin https://github.com/westsoever/agent-terminal.git` (the worktrees share this remote).
3. `mv ~/bbq/kaching ~/bbq/agent-terminal`, then `ln -s agent-terminal ~/bbq/kaching` so old paths still resolve, then `git -C ~/bbq/agent-terminal worktree repair` (and `git worktree repair <path>` for any worktree outside `.claude/worktrees`).
4. `cd ~/bbq/agent-terminal && ./install.sh --yes` once more: it points the three links at the new folder. Then `./install.sh --install-menubar --yes` so the dot's job gets the new path.
5. Claude Code keeps its per-folder history in `~/.claude/projects/-Users-clyde-bbq-kaching`; sessions started in the new folder get a new project folder. Nothing to do unless you want `claude --resume` to list the old sessions there (copy or link the folder to `-Users-clyde-bbq-agent-terminal`).
6. In the README "Quick install", the clone URL names `westsoever/ching` until step 1; change it to `westsoever/agent-terminal` afterwards (GitHub's redirect keeps the old one working).

**What stays under the old name:** `~/.agent/` and its contents, the D35 markers in STATE.md files (`ching:checkpoint`, `ching:snapshot`), `~/.agent/defaults/ching.env`, and history in this repo (DECISIONS, checkpoints, dated specs and plans).
