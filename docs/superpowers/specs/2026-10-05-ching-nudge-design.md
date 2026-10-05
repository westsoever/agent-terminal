# Ching check-in nudges (waiting-session reminders) - design

Date: 2026-10-05
Status: draft for review. Not scheduled yet: it builds on Phase 1.5 and must wait for the Phase 1.5 build to finish.
Builds on: `2026-10-05-hermes-harvest-design.md` (events, `notify.sh` budget, `ching-watch.sh`, checkpoint block).

## 1. Intent

The user wants Ching to be always on and to check in when work is waiting on them.

Agreed in conversation (2026-10-05, voice and chat):

- **Trigger:** a session is idle or waiting on the user with work still open. A `working` session never triggers a reminder, even if the keyboard and mouse have been idle for hours.
- **Delivery:** a banner first. If the user has not reacted after about 5 minutes, Ching speaks a short note through the local voice.
- **Later, not in scope:** a notch widget that pops out on hover. It would read the same event log.

Assumption made by the author, open to correction in review: the spoken follow-up happens only when the user is at the Mac (keyboard or mouse used in the last 10 minutes). Otherwise the nudge stays banner-only.

Success: a session that finishes a turn and sits waiting produces one banner, then at most one spoken note, per waiting spell. Nothing is spoken to an empty room, over another session's voice, or at night. No AI calls, no daemon (D17).

## 2. Design

The nudge is a new check inside `ching-watch.sh`, plus one small script, `bin/speak.sh`.

### 2.1 "Waiting" definition

A registry session (state not `ended`) is **waiting** when all hold:

1. its `status:` is `idle`, `input` or `blocked`;
2. there is open work: the checkpoint block has `blocker:` other than `none`, or `next_action:` that is non-empty and not `none`, or the session's `NEXT.md` is non-empty;
3. the transcript mtime is at least `WATCH_WAIT_GRACE_MINS` (default 2) ago. This avoids a banner at the end of every turn while the user is still reading.

`done` and `working` sessions are never waiting. A newer transcript write (a new prompt or turn) ends the waiting spell and clears `wait_since`, `nudged_at` and `spoken_at` in the session meta.

### 2.2 Stage 1: banner

When a session becomes waiting and `wait_since` is unset: set `wait_since=<now>`, emit a `waiting` event `{mins, blocker}`, run `notify.sh waiting`, and set `nudged_at`. The banner text is `<session name>: <blocker, else next_action>`.

`notify.sh` change: `waiting` is a new budgeted kind with two differences from `idle` and `stall`. It is exempt from the 45-minute cooldown, because the once-per-spell rule already limits it. It has its own daily cap, `WATCH_NUDGE_MAX` (default 10), counted in `~/.agent/notify/nudge-YYYY-MM-DD`. Quiet hours (`NOTIFY_QUIET_START` / `NOTIFY_QUIET_END`) apply. A suppressed nudge is logged with its reason and does not set `nudged_at`, so it is retried on the next tick while the spell lasts.

### 2.3 Stage 2: spoken note

When a session is waiting, `nudged_at` is set, `spoken_at` is unset, and `WATCH_SPEAK_AFTER_MINS` (default 5) have passed since `nudged_at`, speak only if all of these hold:

- **Presence:** the user used the keyboard or mouse in the last `WATCH_PRESENT_MINS` (default 10). Read with `ioreg -c IOHIDSystem` (`HIDIdleTime`, nanoseconds). If the value cannot be read, treat the user as absent.
- **Voice free:** the VoiceMode conch is not held. `~/.voicemode/conch` is JSON with `held` and `expires`; it is held when `held` is true and `expires` is in the future. A missing or unparseable file counts as free.
- **Quiet hours** do not apply.
- Nobody has been spoken to in the last `WATCH_SPEAK_GAP_MINS` (default 10), tracked in `~/.agent/notify/last-spoken`. This stops several waiting sessions from talking back to back.

The note is one sentence, built from the checkpoint with no AI call: `<session name> has been waiting <n> minutes: <blocker, else next_action>.` On success set `spoken_at` and emit `nudge_spoken`. If any condition fails, nothing is set, so the check repeats on the next tick, and it gives up when the spell ends.

### 2.4 `bin/speak.sh`

`speak.sh "<text>"` posts the text to the local Kokoro service (`http://127.0.0.1:8880/v1/audio/speech`, voice `af_sky`, mp3), writes the audio to a temp file and plays it with `afplay`, then deletes the file. It has a 30-second overall timeout, never prompts, and exits non-zero if Kokoro is down. Tests replace it with `SPEAK_CMD`, and `HID_IDLE_CMD` replaces the `ioreg` read. Nothing leaves the machine.

### 2.5 Tick rate

The Phase 1.5 watcher runs every 300 seconds (`StartInterval` 300). Stage 2 needs a finer tick, so this change sets `StartInterval` to 60 and gates the existing stall, context, token and rotation work to run only when at least 300 seconds have passed since `~/.agent/watch.heavy`. The nudge checks read only meta files, STATE.md and one `ioreg` call, so a 60-second tick is cheap. `install.sh` rewrites the plist; its idempotence rule is unchanged.

## 3. Events

| Event | Fields | Writer |
|---|---|---|
| `waiting` | `{mins, blocker}` | ching-watch.sh, at stage 1 |
| `nudge_spoken` | `{mins}` | ching-watch.sh, after `speak.sh` succeeds |

`notify` events for kind `waiting` follow the existing contract. `dash.sh --next` already scores `idle` and `input`, so it needs no change.

## 4. Files

| File | Change |
|---|---|
| `bin/ching-watch.sh` | waiting check, stage 1 and 2, heavy-work gate |
| `bin/speak.sh` | new |
| `bin/notify.sh` | `waiting` kind, nudge cap |
| `install.sh` | plist `StartInterval` 60, install `speak.sh` |
| `tests/t_watch.sh` | waiting cases below |
| `tests/t_notify.sh` | `waiting` cases below |
| `tests/t_speak.sh` | new |

## 5. Tests

Bash, with stubs for `speak.sh`, `HID_IDLE_CMD`, the conch file and `WATCH_NOW`:

- A `working` session, idle keyboard for hours: no event, no banner, no speech.
- An `idle` session with a blocker, 1 minute old: nothing. At 3 minutes: one `waiting` event and one banner. A second tick: no second banner.
- A new transcript write clears the spell, and a later spell nudges again.
- A suppressed banner (quiet hours, daily cap) leaves `nudged_at` unset and logs the reason.
- 5 minutes after the banner, user present, conch free: one spoken note and `nudge_spoken`. A second tick: no second note.
- Same case with the user away, a held conch, an expired conch (counts as free), or an unreadable `ioreg`: speech skipped or allowed as specified, with `spoken_at` unset on skip.
- Two waiting sessions: only one speaks within `WATCH_SPEAK_GAP_MINS`.
- `done` sessions and sessions with no open work never nudge.
- `speak.sh`: Kokoro down returns non-zero, and the timeout is honored.

## 6. Ordering and risks

- **Ordering.** The Phase 1.5 plan owns `ching-watch.sh` (Task 5), `install.sh` (Task 6) and `notify.sh` (Task 4). This work starts after Checkpoint 1.5, so it never edits the same files as the build.
- **Nagging.** Mitigated by the grace period, once-per-spell banner, daily cap, quiet hours, speech gap and presence check. The pilot should tune the defaults, as for the Phase 1.5 stall threshold.
- **Voice contention.** Speech yields to a held conch. A session starting `converse` in the middle of a spoken note is possible, since `speak.sh` does not take the conch. The note is short, and the cost is one overlapping sentence.
- **Stale `status:`.** If a session's `status:` is `idle` but the user is in fact mid-turn, the 2-minute grace plus the transcript-mtime check covers it.

## 7. Out of scope

The notch widget, AI-written reminder text, nudging about things other than waiting sessions, and phone or remote delivery.
