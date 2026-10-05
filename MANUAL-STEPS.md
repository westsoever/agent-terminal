# Phase 0: manual steps for you

Everything here needs a human (a GUI app, a microphone, or a trust prompt). Tick the boxes as you go. Total about 45 minutes; items are ordered shortest first.

Everything runs in the throwaway sandbox `/tmp/agent-sandbox/repo`. Nothing touches miso, `~/.miso` or your real settings. The kit is backed up in `/Users/clyde/bbq/ching/phase0-manual/` (`setup.sh` rebuilds the sandbox if `/tmp` was cleaned).

**Before you start (1 min):**

```
/Users/clyde/bbq/ching/phase0-manual/setup.sh
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
