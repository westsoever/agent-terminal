# Ching check-in nudges (waiting-session reminders) - design

Date: 2026-10-05 (rev 2, after a feasibility and simplicity review)
Status: draft for review. Not scheduled: it builds on Phase 1.5 and starts after Checkpoint 1.5.
Builds on: `2026-10-05-hermes-harvest-design.md` (event log, `notify.sh` budget, `ching-watch.sh`, checkpoint block).

## 1. Intent

The user wants Ching to be always on and to check in when work is waiting on them.

Agreed in conversation (2026-10-05, voice and chat):

- **Trigger:** a session is waiting on the user. A `working` session never triggers a reminder, even if the keyboard and mouse have been idle for hours.
- **Delivery:** a banner first. If the user has not reacted after about 5 minutes, Ching speaks a short note through the local voice.
- **Later, not in scope:** a notch widget that pops out on hover. It would read the same event log.

Assumption, open to correction: the spoken note happens only when the user is at the Mac (keyboard or mouse used in the last 10 minutes).

Success: each waiting spell produces at most one banner and one spoken note. Nothing is spoken to an empty room, over another session's voice, or in quiet hours. No AI calls, no daemon (D17).

## 2. What the review found, and what changed from rev 1

Checked against the code in the `phase-1.5-harvest` worktree and on the machine:

- **Wrong state source.** Rev 1 read `status:` from STATE.md, which only exists after `/handoff`. The hooks already keep a reliable `state` and `updated` time in each session's registry `meta` (`stop-check.sh` sets them at every Stop). Rev 2 uses those, and no transcript read.
- **Wrong states.** Hooks never set `idle`. At Stop a session becomes `done` (turn finished), `input` (the last line is a question) or `blocked`. Rev 1 would have missed `done`, the most common waiting case.
- **Duplicate banner.** `input` and `blocked` are urgent kinds, so `notify.sh` already pushes a banner at Stop. A second banner would be noise. Rev 2 reuses that banner as stage 1 and only adds a new banner for `done`.
- **Too many moving parts.** Rev 1 added a 60-second tick with a gate for the heavy work, three meta keys, and a custom daily cap in `notify.sh`. Rev 2 keeps the 5-minute tick, one meta key, and uses the existing budget. The spoken note lands 5 to 10 minutes after the Stop, which matches "about 5 minutes".
- **Checked and fine.** The Kokoro endpoint returns MP3 (the first request took 9.7 s, within the 30 s timeout), `afplay` exists, `ioreg` reports `HIDIdleTime` (18 s measured), and the conch file is JSON with `held` and `expires`. `install.sh` links the whole kit directory, so a new `bin/speak.sh` needs no installer change.

## 3. Design

A new check in `ching-watch.sh` and one small script, `bin/speak.sh`.

### 3.1 Waiting

A registry session (state not `ended`) is **waiting** when:

1. meta `state` is `input` or `blocked`, or `done` with open work (the checkpoint has `blocker:` other than `none` or a `next_action:` other than `none`, or the session's `NEXT.md` is non-empty); and
2. the `updated` time is at least `WATCH_WAIT_GRACE_MINS` (default 2) ago.

`working` never waits. A new prompt or Stop changes `updated` (and `state`), so a waiting spell ends by itself and the next one starts clean. Spell identity is the `updated` value.

### 3.2 Stage 1: banner

- `input` and `blocked`: the banner already went out at Stop. The watcher sends nothing.
- `done` with open work: the watcher runs `notify.sh waiting` once per spell, with the text `<session name>: <next_action, else blocker>`, and emits a `waiting` event.

`waiting` is a new kind in `notify.sh`, **budgeted like `idle` and `stall`**: quiet hours, 4 a day, 45-minute cooldown. No special cap. The user can raise `NOTIFY_BUDGET`. A suppressed `waiting` is logged with its reason and retried on the next tick.

### 3.3 Stage 2: spoken note

For a waiting session whose `updated` is at least `WATCH_SPEAK_AFTER_MINS` (default 5) ago and whose meta `spoken_for` is not equal to the current `updated` value, speak when all hold:

- the local hour is inside the same window as banners (`NOTIFY_QUIET_END` to `NOTIFY_QUIET_START`);
- **presence:** keyboard or mouse used in the last `WATCH_PRESENT_MINS` (default 10), read from `ioreg -c IOHIDSystem` (`HIDIdleTime`, nanoseconds). Unreadable counts as absent;
- **voice free:** `~/.voicemode/conch` does not have `held` true with `expires` in the future. A missing or unparseable file counts as free;
- **no pile-up:** nothing was spoken in the last `WATCH_SPEAK_GAP_MINS` (default 10), tracked by the mtime of `~/.agent/notify/last-spoken`.

The sentence is built from the checkpoint with no AI call: `<session name> has been waiting <n> minutes: <next_action, else blocker, else "it needs your input">.` On success set `spoken_for=<updated>`, touch `last-spoken`, and emit `nudge_spoken`. If a condition fails, nothing is set and the check repeats on the next tick.

### 3.4 `bin/speak.sh`

`speak.sh "<text>"` posts to the local Kokoro service (`http://127.0.0.1:8880/v1/audio/speech`, voice `af_sky`, mp3), plays the file with `afplay`, and deletes it. 30-second overall timeout, never prompts, non-zero exit if Kokoro is down. Tests replace it with `SPEAK_CMD` and the idle read with `HID_IDLE_CMD`. Nothing leaves the machine.

## 4. Events and files

| Event | Fields | Writer |
|---|---|---|
| `waiting` | `{mins, state}` | ching-watch.sh, when it sends the `done` banner |
| `nudge_spoken` | `{mins}` | ching-watch.sh, after `speak.sh` succeeds |

| File | Change |
|---|---|
| `bin/ching-watch.sh` | waiting check, `done` banner, spoken note |
| `bin/speak.sh` | new |
| `bin/notify.sh` | `waiting` as a budgeted kind |
| `tests/t_watch.sh`, `tests/t_notify.sh`, `tests/t_speak.sh` | cases below |
| `tests/live-smoke.sh` | one manual check that `afplay` and `ioreg` work from the launchd job |

## 5. Tests

Bash, with stubs for `speak.sh`, `HID_IDLE_CMD`, the conch file and `WATCH_NOW`:

- `working` session, keyboard idle for hours: no event, banner or speech.
- `done` with a next action, 1 minute old: nothing. At 3 minutes: one `waiting` event and one banner. A second tick: no second banner.
- `done` with no open work: never nudges.
- `input` and `blocked`: no watcher banner; spoken note after 5 minutes.
- A new Stop (new `updated`) re-arms the spell. A new prompt ends it.
- A suppressed banner (quiet hours or budget) logs its reason and retries next tick.
- Spoken note: user present and conch free speaks once, and a second tick does not repeat. User away, conch held, quiet hours, an unreadable `ioreg`, or a recent `last-spoken` each skip it without setting `spoken_for`. An expired conch counts as free.
- `speak.sh`: Kokoro down returns non-zero, and the timeout is honored.

## 6. Ordering and risks

- **Ordering.** Phase 1.5 owns `ching-watch.sh` (Task 5), `notify.sh` (Task 4) and `install.sh` (Task 6). This work starts after Checkpoint 1.5 and edits two of those files.
- **Unverified.** Audio and `ioreg` from a launchd job are checked by the live-smoke step before the pilot, not assumed.
- **Nagging.** Limited by the grace period, one banner and one note per spell, the existing budget, quiet hours, the speech gap and the presence check. Tune the defaults in the pilot.
- **Voice overlap.** `speak.sh` does not take the conch, so a `converse` call that starts mid-note overlaps by one sentence at most.
- **`done` with no checkpoint.** Outside repo mode and without `/handoff` there is no checkpoint, so only a non-empty `NEXT.md` marks a `done` session as having open work.

## 7. Out of scope

The notch widget, AI-written reminder text, nudging about anything other than waiting sessions, and phone or remote delivery.
