# Ching Check-in Nudges Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a session is waiting on the user, show a banner, and if it is still unanswered after about 5 minutes, speak one short note through the local voice, without nagging.

**Architecture:** One new section in the existing one-shot watcher `bin/ching-watch.sh` (launchd, every 5 minutes) decides who is waiting from each session's registry `meta` (`state`, `updated`) and checkpoint. A new `bin/speak.sh` posts text to the local Kokoro service and plays it. `bin/notify.sh` gets one new budgeted kind, `waiting`. Everything stays in bash, with no AI calls and no daemon.

**Tech Stack:** macOS system bash 3.2, jq 1.7.1, curl, `afplay`, `ioreg`, launchd. Tests use the existing harness `tests/run.sh` + `tests/lib.sh`.

**Spec:** `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`. Read it first, especially section 2 (what the review found).

**Status (2026-10-06, 12:40):** Tasks 0-6 are done on branch `nudge` (worktree `~/bbq/.worktrees/ching-nudge`), rebased onto `main` after the Phase 1.5 fix wave was merged (`3f94bef`). Commits after the rebase: speak.sh `0fbfe21`, notify `8f7a95c`, banner `cf67de0`, spoken note `2df81ea`, docs and live smoke `f3d4d25`, stale cap (Task 6) `a4d2cd1`, final-review fix wave `560e457`, `6858a6f`, `0342023`. The suite there passes (1573 passed, 0 failed). Task 5 step 4 (spec coverage) was run by a separate verifier and its gaps went into the fix wave. The whole-branch review and a scoped re-review are clean. Still open: Task 5 step 5 (real-machine check from launchd; it needs the nudge code on `main`, because the launchd job runs the `main` checkout) and the user's approval at Checkpoint 1.6 before `nudge` merges.

## Global Constraints

- Bash 3.2 compatible: no associative arrays, no `${var,,}`, no `mapfile`/`readarray`, no `&>>`.
- Every script in `bin/` except `lib.sh` keeps `set -euo pipefail` within its first 40 lines (`t_lint` enforces it). shellcheck `-S warning` stays clean for `bin/*.sh`.
- No new dependencies. No AI or model calls anywhere in this work.
- Tests never touch the real `~/.claude`, `~/.agent`, `~/.voicemode` or launchd, never play audio, and never read the real `ioreg`. Everything goes through the `tests/lib.sh` sandbox. Tests always set `SPEAK_CMD`, `HID_IDLE_CMD`, `VOICEMODE_CONCH` and `WATCH_NOW`.
- Constants (spec values, verbatim):

  | Constant | Value |
  |---|---|
  | `WATCH_WAIT_GRACE_MINS` | 2 |
  | `WATCH_SPEAK_AFTER_MINS` | 5 |
  | `WATCH_PRESENT_MINS` | 10 (idle time below this counts as present; exactly 10 minutes counts as absent) |
  | `WATCH_SPEAK_GAP_MINS` | 10 |
  | Kokoro URL / voice | `http://127.0.0.1:8880/v1/audio/speech` / `af_sky`, mp3 |
  | Synthesis request limit | 30 s (`curl -m 30`) |
  | Waiting states | `input`, `blocked`, and `done` with open work |
  | Quiet hours | same as banners: `NOTIFY_QUIET_END` (9) to `NOTIFY_QUIET_START` (21), local time |
  | Watcher tick | unchanged at 300 s; no `install.sh` change |

- Meta keys written by this work: `nudged_for` and `spoken_for`, each holding the `updated` value of the spell it covers. Events: `waiting` and `nudge_spoken`. Notify kind: `waiting`.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa
  ```
- All work happens in the worktree `~/bbq/.worktrees/ching-nudge` on branch `nudge` (Task 0). Never edit files in `~/bbq/ching` or in the `ching-harvest` worktree.

## Review Focus

1. **A new Stop must re-arm the nudge.** The spell is identified by `updated`; a session that waits, gets a prompt, and waits again must be nudged again, and one waiting spell must never nudge twice. Tests in Tasks 3 and 4.
2. **A banner that notify suppressed (budget, quiet hours) must be retried, not lost or marked as sent.** Test in Task 3.
3. **Text with quotes, backslashes or newlines** (a session name or next action containing them) must reach Kokoro as valid JSON and never break the script. Test in Task 1.
4. **A corrupt, empty, expired or dead-holder conch file** must count as "voice free". Only a live holder blocks speech: an unexpired `held:true` hold, or a `held:false` call lock inside VoiceMode's own lock-expiry window (VoiceMode writes `held:false` for the whole of an active call and deletes the file on release; amended in the final review, I2). Test in Task 4.
5. **Presence at the boundary and when unreadable.** 599 s idle speaks, exactly 600 s does not, and an unreadable or non-numeric `ioreg` result counts as absent. Test in Task 4.
6. **Old sessions must never nudge.** Registry sessions pile up (the Phase 1.5 watcher skips any whose meta is older than 48 h). A session left `done`, `input` or `blocked` for days with a non-empty `NEXT.md` would otherwise get a banner on the first tick after install, and a spoken "has been waiting 4320 minutes" whenever the user is at the Mac. A spell older than `WATCH_NUDGE_MAX_HOURS` (default 12) is not a check-in. Test in Task 6.

## Execution waves (D10: parallel implementers on disjoint files, separate verifier)

| Wave | Tasks | Files touched (disjoint within a wave) |
|---|---|---|
| 0 | Task 0 | none (preconditions, worktree) |
| 1 | **A:** Task 1 · **B:** Task 2 | A: `bin/speak.sh`, `tests/t_speak.sh` · B: `bin/notify.sh`, `tests/t_notify.sh` |
| 2 | Task 3, then Task 4 | `bin/ching-watch.sh`, `tests/t_nudge.sh` (both tasks, so sequential) |
| 3 | Task 5 | docs, `tests/live-smoke.sh`, verification (separate verifier per D10) |
| 4 | Task 6 | `bin/ching-watch.sh`, `tests/t_nudge.sh`, and the spec, docs lines it names. Runs after the rebase (Task 0 step 4), before Task 5 steps 3-5 are re-run. |

---

### Task 0: Preconditions and worktree

**Files:** none changed.

- [ ] **Step 1: Confirm Phase 1.5 is on `main`**

Run: `git -C ~/bbq/ching ls-files bin/ching-watch.sh bin/notify.sh tests/t_watch.sh && git -C ~/bbq/ching log --oneline main | head -5`
Expected: all three files listed, and the log shows the Phase 1.5 work merged. If `bin/ching-watch.sh` is missing from `main`, STOP and tell the user: "The nudge work extends ching-watch.sh from Phase 1.5, which is not on main yet. Please merge phase-1.5-harvest first." Do not continue.

- [ ] **Step 2: Create the worktree** (already done: `nudge` exists. Skip this step and use the existing worktree.)

```bash
git -C ~/bbq/ching worktree add ~/bbq/.worktrees/ching-nudge -b nudge main
cd ~/bbq/.worktrees/ching-nudge
```

- [ ] **Step 3: Baseline suite**

Run: `tests/run.sh`
Expected: `TOTAL: N passed, 0 failed`. Write N down; every later task must keep 0 failed.

- [ ] **Step 4: Rebase onto the Phase 1.5 fix wave**

`main` holds the Phase 1.5 merge `b73af38`, but the branch `phase-1.5-harvest` has 8 later commits (guard fix waves, the 48 h session skip in `ching-watch.sh`, notify clock and budget fixes, the escalation ceiling) that are not on `main` yet. They edit `bin/ching-watch.sh` and `bin/notify.sh`, which this plan also edits.

Run: `git -C ~/bbq/ching merge-base --is-ancestor phase-1.5-harvest main && echo merged || echo NOT-MERGED`
If it prints `NOT-MERGED`, STOP and tell the user: "The Phase 1.5 fix wave (8 commits on phase-1.5-harvest, tip 0556a4c) is not on main. The nudge branch must be rebased onto it. Please merge it first." Once it prints `merged`:

```bash
git -C ~/bbq/.worktrees/ching-nudge rebase main
cd ~/bbq/.worktrees/ching-nudge && tests/run.sh
```
Expected: the rebase applies cleanly, or conflicts only in `bin/ching-watch.sh` or `bin/notify.sh`. Resolve a conflict by keeping both sides (the fix-wave lines and the nudge block); never drop a fix-wave line. Then `0 failed`.

---

### Task 1: `bin/speak.sh`

**Files:**
- Create: `bin/speak.sh` (then `chmod +x bin/speak.sh`), `tests/t_speak.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces, for Task 4: `speak.sh TEXT` exits 0 after playing the text, non-zero otherwise (64 for empty text), prints nothing on success, leaves no temp file. Env overrides: `SPEAK_URL`, `SPEAK_VOICE`, `SPEAK_CURL` (default `curl`), `SPEAK_PLAYER` (default `afplay`).

- [ ] **Step 1: Write the failing test** `tests/t_speak.sh`

```bash
#!/usr/bin/env bash
# speak.sh: posts text to the local Kokoro service and plays the result. curl and the player are stubs.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="$BIN/speak.sh"
CALLS="$WORK/calls"; PLAYED="$WORK/played"
CURL="$WORK/curl-stub.sh"; PLAYER="$WORK/player-stub.sh"
mkdir -p "$WORK/tmp"

# stub curl: one argument per line into $CALLS; writes fake audio to the -o target unless told to fail
cat >"$CURL" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$CALLS"
out=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = -o ]; then out=\$2; fi
  shift
done
if [ -n "\${STUB_FAIL:-}" ]; then exit 7; fi
if [ -n "\${STUB_EMPTY:-}" ]; then : >"\$out"; exit 0; fi
printf 'ID3fake' >"\$out"
EOF
cat >"$PLAYER" <<EOF
#!/usr/bin/env bash
cp "\$1" "$PLAYED"
EOF
chmod +x "$CURL" "$PLAYER"
sp() { env TMPDIR="$WORK/tmp" SPEAK_CURL="$CURL" SPEAK_PLAYER="$PLAYER" "$@"; }
body_of() { awk 'prev == "-d" { print; exit } { prev = $0 }' "$CALLS"; }

assert_ok "speaks plain text" sp "$S" "Hello there"
assert_file "the audio reached the player" "$PLAYED"
assert_contains "request has the 30 s limit" "$(tr '\n' ' ' <"$CALLS")" "-m 30"
assert_contains "request goes to the local Kokoro endpoint" "$(tr '\n' ' ' <"$CALLS")" "http://127.0.0.1:8880/v1/audio/speech"
assert_eq "body input" "Hello there" "$(body_of | jq -r .input)"
assert_eq "body voice" "af_sky" "$(body_of | jq -r .voice)"
assert_eq "body model" "kokoro" "$(body_of | jq -r .model)"
assert_eq "no temp file is left behind" "0" "$(find "$WORK/tmp" -type f | wc -l | tr -d ' ')"

# Review Focus 3: quotes, a backslash and a newline survive as valid JSON
HOSTILE=$'He said "hi"\nit'"'"'s a \\ back'
assert_ok "speaks hostile text" sp "$S" "$HOSTILE"
assert_eq "hostile text round-trips through the JSON body" "$HOSTILE" "$(body_of | jq -r .input)"

rm -f "$PLAYED"
assert_fails "service down: fails" sp env STUB_FAIL=1 "$S" "x"
assert_no_file "service down: nothing is played" "$PLAYED"
assert_fails "empty audio: fails" sp env STUB_EMPTY=1 "$S" "x"
assert_no_file "empty audio: nothing is played" "$PLAYED"
assert_fails "no text: fails" sp "$S" ""
exit 0
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_speak|TOTAL'`
Expected: failures (`speak.sh: No such file`).

- [ ] **Step 3: Implement** `bin/speak.sh` (then `chmod +x bin/speak.sh`)

```bash
#!/usr/bin/env bash
# speak.sh TEXT - say TEXT through the local Kokoro service (VoiceMode's TTS) and play it. Local only:
# nothing leaves the machine. Prints nothing; exits non-zero when the text is empty, Kokoro is down, or no
# audio came back. The synthesis request is limited to 30 s. It does not take the VoiceMode conch; the
# caller checks that first.
# Env: SPEAK_URL SPEAK_VOICE (af_sky) SPEAK_CURL (curl) SPEAK_PLAYER (afplay)
set -euo pipefail

TEXT=${1:-}
if [ -z "$TEXT" ]; then echo "usage: speak.sh TEXT" >&2; exit 64; fi
URL=${SPEAK_URL:-http://127.0.0.1:8880/v1/audio/speech}
VOICE=${SPEAK_VOICE:-af_sky}
CURL=${SPEAK_CURL:-curl}
PLAYER=${SPEAK_PLAYER:-afplay}

TMP=$(mktemp "${TMPDIR:-/tmp}/ching-speak.XXXXXX")
trap 'rm -f "$TMP"' EXIT

BODY=$(jq -nc --arg t "$TEXT" --arg v "$VOICE" '{model:"kokoro", input:$t, voice:$v, response_format:"mp3"}')
"$CURL" -sf -m 30 -H 'Content-Type: application/json' -d "$BODY" -o "$TMP" "$URL"
[ -s "$TMP" ] || exit 1
"$PLAYER" "$TMP"
```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Includes `t_lint` (strict mode and shellcheck on the new script).

- [ ] **Step 5: Commit**

```bash
git add bin/speak.sh tests/t_speak.sh
git commit -m "speak.sh: say a sentence through the local Kokoro service

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa"
```

---

### Task 2: `waiting` kind in `notify.sh`

**Files:**
- Modify: `bin/notify.sh` (header comment and the label `case`)
- Test: `tests/t_notify.sh`

**Interfaces:**
- Consumes: the Phase 1.5 `notify.sh` (budgeted class for every kind that is not `input`, `blocked`, `ready` or `done`) and the `nt` helper and `NOON`, `LOG`, `AGENT_HOME` variables defined in the Phase 1.5 block at the end of `tests/t_notify.sh`.
- Produces, for Task 3: kind `waiting`. Its notify log title is `<name> (<branch>): Waiting for you`, its default message is `Finished and waiting for your next step.`, and it is budgeted (quiet hours, 4 a day, 45-minute cooldown per session) with no other special handling.

- [ ] **Step 1: Write the failing test.** In `tests/t_notify.sh`, append before the final `exit 0`, after the `events: inbox routing` assertion:

```bash
# ---------- waiting (check-in nudge) ----------
rm -rf "$AGENT_HOME/notify"; : >"$LOG"
nt n1 waiting
assert_contains "waiting is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
assert_contains "waiting has its own label" "$(tail -1 "$LOG")" "notifyrepo (main): Waiting for you"
printf '%s' "$(hook_json Notification "$R" n1b)" | NOTIFY_NOW=$NOON "$BIN/notify.sh" waiting
assert_contains "waiting has a default message" "$(tail -1 "$LOG")" "Finished and waiting for your next step."
nt n1 waiting $((NOON + 600))
assert_contains "waiting obeys the per-session cooldown" "$(tail -1 "$LOG")" "suppressed:cooldown"
for s in n2 n3; do nt "$s" waiting; done
nt n4 waiting
assert_contains "waiting counts against the daily budget" "$(tail -1 "$LOG")" "suppressed:daily-budget"
rm -rf "$AGENT_HOME/notify"
nt n6 waiting $((NOON + 10 * 3600))
assert_contains "waiting waits out quiet hours" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
```

The budget arithmetic: `n1`, `n1b`, `n2` and `n3` are four delivered alerts, so `n4` is the fifth and is suppressed. The `printf` line calls `notify.sh` without a message, because `nt` always passes one.

- [ ] **Step 2: Run and confirm the new tests fail**

Run: `tests/run.sh 2>&1 | grep -E 't_notify|TOTAL'`
Expected: failures on "waiting has its own label" and "waiting has a default message" (the kind falls into the generic label branch today). The budget, cooldown and quiet-hours assertions already pass; that is fine.

- [ ] **Step 3: Implement.** In `bin/notify.sh`:

1. In the header comment, change the line `# KIND: done | input | blocked | ready | idle | stall | handoff | tokens` to `# KIND: done | input | blocked | ready | idle | waiting | stall | handoff | tokens`.
2. In the first `case "$KIND" in` block (labels), add this line directly after the `idle)` line:

```bash
  waiting) LABEL="Waiting for you";     DEFAULT="Finished and waiting for your next step." ;;
```

No change to the routing `case`: `waiting` already falls into the budgeted class.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/notify.sh tests/t_notify.sh
git commit -m "notify: add the budgeted waiting kind for check-in nudges

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa"
```

---

### Task 3: Waiting detection and the banner in `ching-watch.sh`

**Files:**
- Modify: `bin/ching-watch.sh`
- Create: `tests/t_nudge.sh`

**Interfaces:**
- Consumes: `ev`, `meta_get`, `meta_set`, `resolve_state`, `checkpoint_get` (lib.sh); the watcher's existing `wnotify KIND MESSAGE` helper and its `NOW`, `AGENT_HOME`, `SELF_DIR` variables (it sets `NOTIFY_CWD`, `NOTIFY_SESSION` and `NOTIFY_NOW` from `CWD`, `SID` and `NOW`); `notify.sh waiting` (Task 2); meta keys `state`, `updated`, `cwd`, `name`, `root` written by the hooks.
- Produces, for Task 4: the nudge loop that ends with the line `done # end of nudge pass`, with these variables set for each waiting session inside it: `SID`, `SESS_DIR`, `STATE_DIR`, `CWD`, `NAME`, `state`, `upd` (the `updated` epoch), `age` (seconds since `upd`), `nxt` (next action, empty if none) and `blk` (blocker, empty if none). Meta key `nudged_for`. Event `waiting` with data `{mins, state}`.

- [ ] **Step 1: Write the failing test** `tests/t_nudge.sh`

```bash
#!/usr/bin/env bash
# ching-watch.sh check-in nudges: who counts as waiting, the banner for finished sessions with open work,
# and (Task 4) the spoken note. The clock, the voice, the idle read and the conch are all faked.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
W="$BIN/ching-watch.sh"
NOON=$(date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-05 12:00:00" +%s)
EVF="$AGENT_HOME/events.jsonl"
NLOG="$AGENT_HOME/notify.log"
SPOKEN="$WORK/spoken.log"
STUB="$WORK/speak-stub.sh"
cat >"$STUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$1" >>"$SPOKEN"
EOF
chmod +x "$STUB"
export SPEAK_CMD="$STUB" HID_IDLE_CMD="echo 30" VOICEMODE_CONCH="$WORK/conch"

now() { printf '%s' "${TNOW:-$NOON}"; }
run() { WATCH_NOW=$(now) "$W"; }
mget() { meta_get "$AGENT_HOME/sessions/$1/meta" "$2"; }
reg() { # sid state age_secs: a session whose last Stop was age_secs before now; its folder is named after the sid
  local d="$AGENT_HOME/sessions/$1"; mkdir -p "$d" "$WORK/cwd/$1"
  printf 'cwd=%s\nname=%s\nroot=\nstate=%s\nupdated=%s\n' "$WORK/cwd/$1" "$1" "$2" "$(( $(now) - $3 ))" >"$d/meta"
}
checkpoint() { # sid next_action blocker
  printf '# State\n<!-- ching:checkpoint -->\nresult: x\nblocker: %s\nnext_action: %s\nfiles_changed: 0\nexamined: x\nnot_examined: x\n<!-- /ching:checkpoint -->\n' "$3" "$2" >"$AGENT_HOME/sessions/$1/STATE.md"
}
reset() {
  rm -rf "$AGENT_HOME/sessions" "$AGENT_HOME/notify" "$EVF" "$SPOKEN" "$VOICEMODE_CONCH"
  mkdir -p "$AGENT_HOME"; : >"$NLOG"; : >"$SPOKEN"; unset TNOW
}
banners() { grep -c $'\tdry-run\t.*Waiting for you' "$NLOG" || true; }

# a working session is never waiting, however long it has been quiet
reset; reg w1 working 7200; checkpoint w1 "do x" none; run
assert_eq "working session: no banner" "0" "$(banners)"

# a finished session with a next action: nothing inside the grace period, one banner after it
reset; reg d1 done 60; checkpoint d1 "ship the migration" none; run
assert_eq "done, 1 minute old: still inside the grace period" "0" "$(banners)"
reset; reg d1 done 180; checkpoint d1 "ship the migration" none; run
assert_eq "done with a next action, 3 minutes old: one banner" "1" "$(banners)"
assert_contains "banner title names the session" "$(tail -1 "$NLOG")" "d1: Waiting for you"
assert_contains "banner carries the next action" "$(tail -1 "$NLOG")" "ship the migration"
assert_eq "event: waiting with the state" "done" "$(jq -r 'select(.kind=="waiting") | .data.state' "$EVF")"
assert_eq "nudged_for records the spell" "$(( NOON - 180 ))" "$(mget d1 nudged_for)"
run
assert_eq "same spell: no second banner" "1" "$(banners)"

# Review Focus 1: a new Stop (new updated) is a new spell
TNOW=$(( NOON + 3600 )); reg d1 done 180; run
assert_eq "new Stop re-arms the banner" "2" "$(banners)"
assert_eq "nudged_for follows the new spell" "$(( TNOW - 180 ))" "$(mget d1 nudged_for)"
unset TNOW

# a blocker alone counts as open work; so does a non-empty NEXT.md; "none" and blank do not
reset; reg d2 done 600; checkpoint d2 none "need the staging token"; run
assert_eq "done with only a blocker: banner" "1" "$(banners)"
assert_contains "banner carries the blocker" "$(tail -1 "$NLOG")" "need the staging token"
reset; reg d3 done 600; printf 'continue with the import\n' >"$AGENT_HOME/sessions/d3/NEXT.md"; run
assert_eq "done with a non-empty NEXT.md: banner" "1" "$(banners)"
assert_contains "banner falls back to the default message" "$(tail -1 "$NLOG")" "Finished and waiting for your next step."
reset; reg d4 done 600; checkpoint d4 none None; run
assert_eq "done, checkpoint says none: no banner" "0" "$(banners)"
reset; reg d5 done 600; printf '  \n\n' >"$AGENT_HOME/sessions/d5/NEXT.md"; run
assert_eq "done, blank NEXT.md: no banner" "0" "$(banners)"
reset; reg d6 done 600; run
assert_eq "done, no checkpoint and no NEXT.md: no banner" "0" "$(banners)"

# input and blocked already got their banner at Stop; the watcher adds none
reset; reg i1 input 600; reg b1 blocked 600; checkpoint b1 "x" "need a decision"; run
assert_eq "input and blocked: no watcher banner" "0" "$(banners)"

# ended sessions and a damaged meta are skipped without breaking the run
reset; reg e1 ended 600; checkpoint e1 "x" none
mkdir -p "$AGENT_HOME/sessions/bad"; printf 'state=done\nupdated=abc\n' >"$AGENT_HOME/sessions/bad/meta"
assert_ok "run survives a garbage updated value" run
assert_eq "ended session: no banner" "0" "$(banners)"

# Review Focus 2: a banner notify suppressed is not marked as sent, and goes out on a later tick
reset; reg d7 done 180; checkpoint d7 "go" none
NOTIFY_BUDGET=0 WATCH_NOW=$NOON "$W"
assert_eq "suppressed by the budget: not delivered" "0" "$(banners)"
assert_contains "the suppression is logged" "$(tail -1 "$NLOG")" "suppressed:daily-budget"
assert_eq "suppressed: nudged_for stays unset" "" "$(mget d7 nudged_for)"
run
assert_eq "next tick delivers it" "1" "$(banners)"
assert_eq "now nudged_for is set" "$(( NOON - 180 ))" "$(mget d7 nudged_for)"
exit 0
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_nudge|TOTAL'`
Expected: failures starting with "done with a next action, 3 minutes old: one banner".

- [ ] **Step 3: Implement.** In `bin/ching-watch.sh`:

1. Header comment: add these two lines directly above the `# Env:` line:
   ```
   # Check-in nudges (3b): sessions waiting on the user get a `waiting` banner (finished sessions with open
   # work) and, after a delay, one spoken note. Meta keys: nudged_for spoken_for. Env: WATCH_WAIT_GRACE_MINS (2)
   ```
2. Insert this block immediately above the line `# 4. daily token budget (machine-wide), one alert per mark per day`:

```bash
# 3b. check-in nudges. A session is waiting when its last Stop left it `input`, `blocked`, or `done` with
# something open (a checkpoint blocker or next_action other than "none", or a non-empty NEXT.md), at least
# WATCH_WAIT_GRACE_MINS ago. A spell is identified by the session's `updated` time, so a new Stop or prompt
# starts a new one. input and blocked already got their banner at Stop; `done` only lands in the inbox, so
# the watcher sends it a `waiting` banner, once per spell and only when notify.sh really delivered it.
NOTIFY_LOG_FILE=${NOTIFY_LOG:-$AGENT_HOME/notify.log}
GRACE_SECS=$(( ${WATCH_WAIT_GRACE_MINS:-2} * 60 ))

log_lines() { if [ -f "$NOTIFY_LOG_FILE" ]; then wc -l <"$NOTIFY_LOG_FILE" | tr -d ' '; else echo 0; fi; }
open_value() { # text -> text, or nothing when it is blank or "none"
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in ''|none) ;; *) printf '%s' "$1" ;; esac
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ -f "$m" ] || continue
  SESS_DIR=$(dirname "$m"); SID=$(basename "$SESS_DIR")
  state=$(meta_get "$m" state)
  case "$state" in input|blocked|done) ;; *) continue ;; esac
  upd=$(meta_get "$m" updated)
  case "$upd" in ''|*[!0-9]*) continue ;; esac
  age=$((NOW - upd))
  [ "$age" -ge "$GRACE_SECS" ] || continue
  CWD=$(meta_get "$m" cwd); NAME=$(meta_get "$m" name); ROOT=$(meta_get "$m" root)
  resolve_state
  nxt=$(open_value "$(checkpoint_get "$STATE_DIR/STATE.md" next_action)")
  blk=$(open_value "$(checkpoint_get "$STATE_DIR/STATE.md" blocker)")
  if [ "$state" = done ] && [ -z "$nxt" ] && [ -z "$blk" ]; then
    { [ -f "$STATE_DIR/NEXT.md" ] && grep -q '[^[:space:]]' "$STATE_DIR/NEXT.md"; } || continue
  fi
  if [ "$state" = done ] && [ "$(meta_get "$m" nudged_for)" != "$upd" ]; then
    before=$(log_lines)
    wnotify waiting "${nxt:-$blk}"
    method=$(tail -1 "$NOTIFY_LOG_FILE" 2>/dev/null | cut -f2 || true)
    case "$method" in
      suppressed:*) ;;
      *) if [ "$(log_lines)" -gt "$before" ]; then
           meta_set nudged_for "$upd"
           ev waiting "$(jq -nc --argjson m $((age / 60)) --arg s "$state" '{mins:$m,state:$s}')"
         fi ;;
    esac
  fi
done # end of nudge pass

```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Includes `t_watch` (the Phase 1.5 watcher tests must still pass) and `t_lint`.

- [ ] **Step 5: Commit**

```bash
git add bin/ching-watch.sh tests/t_nudge.sh
git commit -m "ching-watch: banner for finished sessions that are waiting on the user

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa"
```

---

### Task 4: The spoken note in `ching-watch.sh`

**Files:**
- Modify: `bin/ching-watch.sh`
- Test: `tests/t_nudge.sh`

**Interfaces:**
- Consumes: Task 3's nudge loop and its per-session variables (`state`, `upd`, `age`, `nxt`, `blk`, `NAME`); `speak.sh` (Task 1). Env: `SPEAK_CMD` (default `$SELF_DIR/speak.sh`), `HID_IDLE_CMD` (a shell command that prints idle seconds; default reads `ioreg`), `VOICEMODE_CONCH` (default `$HOME/.voicemode/conch`), `WATCH_SPEAK_AFTER_MINS`, `WATCH_PRESENT_MINS`, `WATCH_SPEAK_GAP_MINS`.
- Produces: meta key `spoken_for`, file `$AGENT_HOME/notify/last-spoken` (epoch), event `nudge_spoken` with data `{mins}`.

- [ ] **Step 1: Write the failing tests.** In `tests/t_nudge.sh`, append before the final `exit 0`:

```bash
# ---------- spoken note ----------
spoken() { wc -l <"$SPOKEN" | tr -d ' '; }
conch() { # held|released offset_secs: write a conch file expiring offset_secs from now
  local h=true; [ "$1" = held ] || h=false
  printf '{"pid":1,"held":%s,"expires":"%s.000000"}\n' "$h" "$(date -r $(( $(now) + $2 )) '+%Y-%m-%dT%H:%M:%S')" >"$VOICEMODE_CONCH"
}

# one note per spell, after the delay
reset; reg i1 input 240; run
assert_eq "input, 4 minutes: too early to speak" "0" "$(spoken)"
reset; reg i1 input 360; run
assert_eq "input, 6 minutes: one spoken note" "1" "$(spoken)"
assert_contains "the note names the session and the wait" "$(cat "$SPOKEN")" "i1 has been waiting 6 minutes"
assert_contains "no checkpoint: the note says it needs input" "$(cat "$SPOKEN")" "it needs your input"
assert_eq "spoken_for records the spell" "$(( NOON - 360 ))" "$(mget i1 spoken_for)"
assert_eq "event: nudge_spoken" "6" "$(jq -r 'select(.kind=="nudge_spoken") | .data.mins' "$EVF")"
run
assert_eq "same spell: not spoken twice" "1" "$(spoken)"
TNOW=$(( NOON + 3600 )); reg i1 input 360; run
assert_eq "new Stop re-arms the spoken note" "2" "$(spoken)"
unset TNOW

# what the note says
reset; reg b1 blocked 400; checkpoint b1 "x" "need the staging token"; run
assert_contains "blocked with a blocker: the note says the next action first" "$(cat "$SPOKEN")" "waiting 6 minutes: x."
reset; reg b2 blocked 400; checkpoint b2 none "need the staging token"; run
assert_contains "blocker used when there is no next action" "$(cat "$SPOKEN")" "need the staging token"
reset; reg b3 blocked 400; run
assert_contains "blocked without a checkpoint" "$(cat "$SPOKEN")" "it is blocked"
reset; reg d1 done 400; checkpoint d1 "ship the migration" none; run
assert_contains "done with open work: banner and spoken note" "$(cat "$SPOKEN")" "ship the migration"
assert_eq "done with open work: banner too" "1" "$(banners)"
reset; reg d2 done 400; run
assert_eq "done without open work: never spoken" "0" "$(spoken)"
reset; reg w1 working 7200; run
assert_eq "working: never spoken" "0" "$(spoken)"

# quiet hours
reset; TNOW=$(( NOON + 10 * 3600 )); reg i1 input 400; run
assert_eq "22:00: not spoken" "0" "$(spoken)"
assert_eq "22:00: spoken_for stays unset" "" "$(mget i1 spoken_for)"
unset TNOW

# Review Focus 5: presence boundary and unreadable idle time
reset; reg i1 input 400
HID_IDLE_CMD="echo 599" run
assert_eq "599 s idle: still present, spoken" "1" "$(spoken)"
reset; reg i1 input 400
HID_IDLE_CMD="echo 600" run
assert_eq "600 s idle: absent, not spoken" "0" "$(spoken)"
assert_eq "absent: spoken_for stays unset" "" "$(mget i1 spoken_for)"
reset; reg i1 input 400
HID_IDLE_CMD="echo notanumber" run
assert_eq "non-numeric idle: counts as absent" "0" "$(spoken)"
reset; reg i1 input 400
HID_IDLE_CMD="false" run
assert_eq "failing idle read: counts as absent" "0" "$(spoken)"
run
assert_eq "the user returns (idle read works again): spoken on the next tick" "1" "$(spoken)"

# Review Focus 4: only a live, unexpired hold blocks speech
reset; reg i1 input 400; conch held 60; run
assert_eq "conch held and unexpired: not spoken" "0" "$(spoken)"
run
assert_eq "still held: retried, still silent" "0" "$(spoken)"
conch held -60; run
assert_eq "conch expired: spoken" "1" "$(spoken)"
reset; reg i1 input 400; conch released 60; run
assert_eq "conch held:false: spoken" "1" "$(spoken)"
reset; reg i1 input 400; echo 'not json {' >"$VOICEMODE_CONCH"; run
assert_eq "corrupt conch file: counts as free" "1" "$(spoken)"
reset; reg i1 input 400; run
assert_eq "missing conch file: counts as free" "1" "$(spoken)"

# two waiting sessions do not talk back to back; the second goes on a later tick
reset; reg i1 input 400; reg i2 input 400; run
assert_eq "two waiting sessions: one note now" "1" "$(spoken)"
assert_eq "the second is left for later" "" "$(mget i2 spoken_for)"
TNOW=$(( NOON + 601 )); run
assert_eq "after the gap the second one speaks" "2" "$(spoken)"
assert_eq "and the first is not repeated" "1" "$(grep -c 'i1 has been waiting' "$SPOKEN")"
unset TNOW

# a failing voice does not mark the spell as spoken
reset; reg i1 input 400
SPEAK_CMD=false run
assert_eq "voice failure: spoken_for stays unset" "" "$(mget i1 spoken_for)"
assert_no_file "voice failure: no last-spoken stamp" "$AGENT_HOME/notify/last-spoken"
run
assert_eq "voice back: spoken on the next tick" "1" "$(spoken)"

# hostile names and next actions reach the voice as one line, capped
reset; reg i1 input 400; checkpoint i1 'do "this" now; it'"'"'s a \ test' none; run
assert_eq "quotes and a backslash in the next action: spoken once" "1" "$(spoken)"
assert_contains "and spoken as written" "$(cat "$SPOKEN")" 'do "this" now; it'"'"'s a \ test'
```

- [ ] **Step 2: Run and confirm the new tests fail**

Run: `tests/run.sh 2>&1 | grep -E 't_nudge|TOTAL'`
Expected: failures starting with "input, 6 minutes: one spoken note". The "never spoken" and "too early" assertions pass already; that is fine.

- [ ] **Step 3: Implement.** In `bin/ching-watch.sh`:

1. In the header comment, extend the nudge `Env:` line with `WATCH_SPEAK_AFTER_MINS (5) WATCH_PRESENT_MINS (10) WATCH_SPEAK_GAP_MINS (10) SPEAK_CMD HID_IDLE_CMD VOICEMODE_CONCH`.
2. Insert these definitions immediately above the line `# 3b. check-in nudges.`:

```bash
SPEAK_AFTER_SECS=$(( ${WATCH_SPEAK_AFTER_MINS:-5} * 60 ))
PRESENT_SECS=$(( ${WATCH_PRESENT_MINS:-10} * 60 ))
SPEAK_GAP_SECS=$(( ${WATCH_SPEAK_GAP_MINS:-10} * 60 ))
CONCH_FILE=${VOICEMODE_CONCH:-$HOME/.voicemode/conch}
LAST_SPOKEN="$AGENT_HOME/notify/last-spoken"

hour_ok() { # inside the same window as budgeted banners
  local h; h=$(date -r "$NOW" +%H); h=${h#0}
  [ "$h" -ge "${NOTIFY_QUIET_END:-9}" ] && [ "$h" -lt "${NOTIFY_QUIET_START:-21}" ]
}
user_present() { # keyboard or mouse used within PRESENT_SECS; unreadable counts as absent
  local idle
  if [ -n "${HID_IDLE_CMD:-}" ]; then
    idle=$(bash -c "$HID_IDLE_CMD" 2>/dev/null || true)
  else
    idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }' || true)
  fi
  case "$idle" in ''|*[!0-9]*) return 1 ;; esac
  [ "$idle" -lt "$PRESENT_SECS" ]
}
voice_free() { # false only while another session holds a live, unexpired VoiceMode conch
  local exp secs
  [ -f "$CONCH_FILE" ] || return 0
  exp=$(jq -r 'select(.held == true) | .expires // empty' "$CONCH_FILE" 2>/dev/null || true)
  [ -n "$exp" ] || return 0
  secs=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${exp%%.*}" +%s 2>/dev/null || true)
  case "$secs" in ''|*[!0-9]*) return 0 ;; esac
  [ "$secs" -le "$NOW" ]
}
gap_ok() { # nothing was spoken in the last SPEAK_GAP_SECS
  local last; last=$(cat "$LAST_SPOKEN" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((NOW - last)) -ge "$SPEAK_GAP_SECS" ]
}

```

3. Replace the line `done # end of nudge pass` with:

```bash
  # spoken note: once per spell, only when it can be heard and will not talk over anyone
  [ "$age" -ge "$SPEAK_AFTER_SECS" ] || continue
  [ "$(meta_get "$m" spoken_for)" != "$upd" ] || continue
  hour_ok && user_present && voice_free && gap_ok || continue
  dflt="it needs your input"; [ "$state" != blocked ] || dflt="it is blocked"
  mins=$((age / 60))
  say=$(printf '%s has been waiting %s minutes: %s.' "$NAME" "$mins" "${nxt:-${blk:-$dflt}}" | tr '\n\r' '  ' | cut -c1-300)
  mkdir -p "$AGENT_HOME/notify"
  if "${SPEAK_CMD:-$SELF_DIR/speak.sh}" "$say" >/dev/null 2>&1; then
    meta_set spoken_for "$upd"
    printf '%s\n' "$NOW" >"$LAST_SPOKEN"
    ev nudge_spoken "$(jq -nc --argjson m "$mins" '{mins:$m}')"
  fi
done # end of nudge pass
```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/ching-watch.sh tests/t_nudge.sh
git commit -m "ching-watch: one spoken check-in note per waiting spell

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa"
```

---

### Task 5: Live check, docs, verification, Checkpoint 1.6 (separate verifier per D10)

**Files:**
- Modify: `tests/live-smoke.sh`, `ching-functions.md`, `DECISIONS.md`, `PLAN.md`

The implementer of Tasks 1-4 does not run this task's verification. A separate agent (or the user) does.

- [ ] **Step 1: Live smoke section.** In `tests/live-smoke.sh`, insert directly above the final `echo "sandbox: $S"` line:

```bash
echo "== 4. check-in nudge: real voice and idle read (you should hear one short sentence)"
if "$KIT/bin/speak.sh" "Ching check-in test."; then echo "speak.sh: ok"; else echo "speak.sh: FAILED (is Kokoro running on port 8880?)"; fi
idle=$(ioreg -c IOHIDSystem | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }')
echo "keyboard/mouse idle seconds: ${idle:-UNREADABLE}"
```

- [ ] **Step 2: Docs.**
  1. `ching-functions.md`: append this section at the end:

     ```markdown
     ## 5. Check-ins when a helper is waiting for you

     **The problem:** A helper finishes or gets stuck and waits for you, and you are looking at something else. Nothing tells you again.

     **What we add:**
     - **A banner** when a finished helper still has something open, such as a next step or a blocker.
     - **One spoken sentence**, about 5 to 10 minutes later, if the helper is still waiting. It only speaks when you are at the Mac, nobody else is speaking, and it is not quiet hours.
     - **Silence for busy helpers.** A helper that is still working never triggers a reminder, even if you have been away for hours.
     - **The same alert budget** as every other alert, so the check-ins cannot flood you.

     Later: a small panel in the notch that you hover over to see the updates.
     ```

  2. `DECISIONS.md`: append this entry at the end:

     ```markdown
     ## D19 (2026-10-05): Check-in nudges for waiting sessions

     **Decision (user):** Ching reminds the user when a session is waiting on them: a banner first, then one spoken note after about 5 minutes. The notch widget that opens on hover is deferred. It is built by extending the existing one-shot watcher, `ching-watch.sh`, and stays within D17 (no daemon, no AI calls).

     **Why:** The stall watcher watches sessions, not the user. Nothing noticed a finished session sitting in front of a user who had looked away.

     **How to apply:**
     - Waiting means `input`, `blocked`, or `done` with open work (a checkpoint blocker or next action, or a non-empty `NEXT.md`). A working session never nudges.
     - Keyboard and mouse idle time only gates the voice, never the banner.
     - Spec and plan: `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`, `docs/superpowers/plans/2026-10-05-ching-nudge.md`.
     ```

  3. `PLAN.md`: add this block directly after the Phase 1.5 checkpoint line (`**Checkpoint 1.5:** ...`):

     ```markdown
     ### Phase 1.6: Check-in nudges (spec and plan in `docs/superpowers/`; D19)

     - [ ] **1.6.1** `speak.sh`: say a sentence through the local Kokoro service.
     - [ ] **1.6.2** `notify.sh`: the budgeted `waiting` kind.
     - [ ] **1.6.3** `ching-watch.sh`: detect waiting sessions and send the banner for finished sessions with open work.
     - [ ] **1.6.4** `ching-watch.sh`: one spoken note per waiting spell (presence, voice lock, quiet hours, speech gap).
     - [ ] **1.6.5** Live smoke section, docs, and the real-machine check from launchd.

     **Checkpoint 1.6:** test output, the `ching-watch.sh` diff and the real-machine check. You approve before `nudge` merges into `main`.
     ```

- [ ] **Step 3: Full suite and lint**

Run: `tests/run.sh && tests/t_lint.sh 2>&1 | tail -3`
Expected: `0 failed`, with the `t_nudge` and `t_speak` counts present in the table.

- [ ] **Step 4: Spec coverage check (verifier).** For each numbered item in spec sections 3.1 to 3.4 and 5, name the test in `tests/t_nudge.sh`, `tests/t_speak.sh` or `tests/t_notify.sh` that covers it. Report any gap as a finding; do not fix it silently.

- [ ] **Step 5: Real-machine check (user watches; day time only, quiet hours apply).**

```bash
tests/live-smoke.sh   # section 4: you hear one sentence and see a numeric idle value
d=~/.agent/sessions/zz-nudge-test; mkdir -p "$d"
printf 'cwd=%s\nname=nudge-test\nroot=\nstate=input\nupdated=%s\n' "$HOME" "$(( $(date +%s) - 400 ))" >"$d/meta"
launchctl kickstart -k "gui/$UID/org.ching.watch"
```
Expected: within about a minute you hear "nudge-test has been waiting 6 minutes: it needs your input." through the real launchd job (this proves audio and `ioreg` work from launchd). Then clean up:

```bash
rm -rf ~/.agent/sessions/zz-nudge-test
```

- [ ] **Step 6: Commit**

```bash
git add tests/live-smoke.sh ching-functions.md DECISIONS.md PLAN.md
git commit -m "Check-in nudges: live smoke section, plain-language docs, D19, Phase 1.6 in PLAN

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01PE1WVfawsRDWZWqFtVsUZa"
```

**Checkpoint 1.6:** test output, the diff of `bin/ching-watch.sh`, and the result of the real-machine check. The user approves before merging `nudge` into `main`.

---

### Task 6: Stale-session cap (added in final review; runs after the Task 0 step 4 rebase, before Task 5 steps 3-5 are re-run)

**Files:**
- Modify: `bin/ching-watch.sh` (nudge block), `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`
- Test: `tests/t_nudge.sh`

**Interfaces:**
- Consumes: Task 3's nudge loop, specifically the line `[ "$age" -ge "$GRACE_SECS" ] || continue` and the variables `age`, `GRACE_SECS`.
- Produces: env `WATCH_NUDGE_MAX_HOURS` (default 12). A session whose `updated` is more than that many hours ago is neither bannered nor spoken about. Boundary: exactly the cap still nudges; one second more does not.

- [ ] **Step 1: Write the failing tests.** In `tests/t_nudge.sh`, append before the final `exit 0`:

```bash
# Review Focus 6: a spell older than the cap is not a check-in (no banner, no speech); inside it still is
reset; reg d1 done 90000; checkpoint d1 "ship the migration" none; run
assert_eq "done for 25 h with open work: no banner" "0" "$(banners)"
assert_eq "done for 25 h: not spoken" "0" "$(spoken)"
reset; reg i1 input 90000; run
assert_eq "input for 25 h: not spoken" "0" "$(spoken)"
assert_eq "input for 25 h: spoken_for stays unset" "" "$(mget i1 spoken_for)"
reset; reg i1 input 43200; run
assert_eq "exactly 12 h: still nudged" "1" "$(spoken)"
reset; reg i1 input 43201; run
assert_eq "12 h and 1 s: not nudged" "0" "$(spoken)"
reset; reg d1 done 43200; checkpoint d1 "go" none; run
assert_eq "done for exactly 12 h: still bannered" "1" "$(banners)"
reset; reg i1 input 90000
WATCH_NUDGE_MAX_HOURS=48 run
assert_eq "the cap is configurable" "1" "$(spoken)"
```

The `reset` helper already clears the sessions, so no state leaks between cases.

- [ ] **Step 2: Run and confirm the new tests fail**

Run: `tests/run.sh 2>&1 | grep -E 't_nudge|TOTAL'`
Expected: failures on "done for 25 h with open work: no banner", "input for 25 h: not spoken" and "12 h and 1 s: not nudged". The "exactly 12 h" and "configurable" cases already pass; that is fine.

- [ ] **Step 3: Implement.** In `bin/ching-watch.sh`:

1. Header comment: change `Env: WATCH_WAIT_GRACE_MINS (2)` to `Env: WATCH_WAIT_GRACE_MINS (2) WATCH_NUDGE_MAX_HOURS (12)`.
2. Directly below the line `GRACE_SECS=$(( ${WATCH_WAIT_GRACE_MINS:-2} * 60 ))` add:

```bash
MAX_AGE_SECS=$(( ${WATCH_NUDGE_MAX_HOURS:-12} * 3600 )) # older than this is stale, not waiting
```

3. Directly below the line `[ "$age" -ge "$GRACE_SECS" ] || continue` add:

```bash
  [ "$age" -le "$MAX_AGE_SECS" ] || continue
```

4. In the spec `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`, section 3.1: after item 2 (`the \`updated\` time is at least \`WATCH_WAIT_GRACE_MINS\` (default 2) ago.`) change the ending to `...ago, and`, and add item `3. the \`updated\` time is at most \`WATCH_NUDGE_MAX_HOURS\` (default 12) ago. Older sessions are stale, not waiting; this also keeps a backlog of old sessions from nagging on the first run.` In section 5 add the bullet `- A session older than the cap (25 h, and 12 h plus 1 s) never nudges; exactly 12 h still does; the cap is configurable.` Also change the intro of 3.1 from `is **waiting** when:` to `is **waiting** when all of these hold:`.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/ching-watch.sh tests/t_nudge.sh docs/superpowers/specs/2026-10-05-ching-nudge-design.md
git commit -m "ching-watch: sessions older than 12 h are stale, not waiting

Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Ra1bwwdfd3t4GPeJ7eg58X"
```
