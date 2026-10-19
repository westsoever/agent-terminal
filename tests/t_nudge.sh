#!/usr/bin/env bash
# agent-terminal-watch.sh check-in nudges: who counts as waiting, the banner for finished sessions with open work,
# and (Task 4) the spoken note. The clock, the voice, the idle read and the conch are all faked.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
W="$BIN/agent-terminal-watch.sh"
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
at() { date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-05 $1" +%s; } # local time of day on the fake day -> epoch
run() { WATCH_NOW=$(now) "$W"; }
mget() { meta_get "$AGENT_HOME/sessions/$1/meta" "$2"; }
reg() { # sid state age_secs [root]: a session whose last Stop was age_secs before now; its folder is named after the sid
  local d="$AGENT_HOME/sessions/$1"; mkdir -p "$d" "$WORK/cwd/$1"
  printf 'cwd=%s\nname=%s\nroot=%s\nstate=%s\nupdated=%s\n' "$WORK/cwd/$1" "$1" "${4:-}" "$2" "$(( $(now) - $3 ))" >"$d/meta"
}
checkpoint() { # sid next_action blocker
  printf '# State\n<!-- ching:checkpoint -->\nresult: x\nblocker: %s\nnext_action: %s\nfiles_changed: 0\nexamined: x\nnot_examined: x\n<!-- /ching:checkpoint -->\n' "$3" "$2" >"$AGENT_HOME/sessions/$1/STATE.md"
}
reset() {
  rm -rf "$AGENT_HOME/sessions" "$AGENT_HOME/notify" "$AGENT_HOME/tokens" "$EVF" "$SPOKEN" "$VOICEMODE_CONCH"
  mkdir -p "$AGENT_HOME"; : >"$NLOG"; : >"$SPOKEN"; unset TNOW
}
banners() { grep -c $'\tdry-run\t.*Waiting for you' "$NLOG" || true; }
spoken() { wc -l <"$SPOKEN" | tr -d ' '; }

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
assert_eq "event: waiting with the minutes" "3" "$(jq -r 'select(.kind=="waiting") | .data.mins' "$EVF")"
assert_eq "nudged_for records the spell" "$(( NOON - 180 ))" "$(mget d1 nudged_for)"
run
assert_eq "same spell: no second banner" "1" "$(banners)"
# an hour later notify's own 45-minute cooldown is over, so only nudged_for can still hold the banner back
TNOW=$(( NOON + 3600 )); run
assert_eq "same spell, an hour later (notify cooldown over): still one banner" "1" "$(banners)"
unset TNOW

# the grace period is exactly 2 minutes by default
reset; reg d1 done 119; checkpoint d1 "go" none; run
assert_eq "done, 119 s old: still inside the grace period" "0" "$(banners)"
reset; reg d1 done 120; checkpoint d1 "go" none; run
assert_eq "done, 120 s old: banner" "1" "$(banners)"

# Review Focus 1: a new Stop (new updated) is a new spell
reset; reg d1 done 180; checkpoint d1 "ship the migration" none; run
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

# with both a next action and a blocker, the banner carries the next action
reset; reg d1 done 600; checkpoint d1 "ship the migration" "need the staging token"; run
assert_contains "banner with both: the next action" "$(tail -1 "$NLOG")" "ship the migration"
assert_not_contains "banner with both: not the blocker" "$(tail -1 "$NLOG")" "need the staging token"

# the template ships "next_action: (none)": a "nothing here" sentinel is not open work (same list as dash.sh)
reset; reg d1 done 600; checkpoint d1 "(none)" none; run
assert_eq "done, next_action (none): no banner" "0" "$(banners)"
assert_eq "done, next_action (none): not spoken" "0" "$(spoken)"
reset; reg d1 done 600; checkpoint d1 "none." "None."; run
assert_eq "done, next_action none. and blocker None.: no banner" "0" "$(banners)"
assert_eq "done, next_action none. and blocker None.: not spoken" "0" "$(spoken)"
reset; reg d1 done 600; checkpoint d1 "(NONE)" none; run
assert_eq "done, next_action (NONE) in capitals: no banner" "0" "$(banners)"
reset; reg i1 input 400; checkpoint i1 "(none)" "need the staging token"; run
assert_contains "input, next_action (none) and a real blocker: the note uses the blocker" "$(cat "$SPOKEN")" "need the staging token"
assert_not_contains "input, next_action (none): the note does not read the sentinel" "$(cat "$SPOKEN")" "(none)"
reset; reg d1 done 600; checkpoint d1 "(none)" "need the staging token"; run
assert_eq "done, next_action (none) and a real blocker: banner" "1" "$(banners)"
assert_contains "that banner carries the blocker" "$(tail -1 "$NLOG")" "need the staging token"
reset; reg d1 done 600; checkpoint d1 "ship it" none; run
assert_eq "done, next_action ship it: still nudges" "1" "$(banners)"

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
# the same through quiet hours (notify's other reason): suppressed, logged, nudged_for unset
reset; TNOW=$(( NOON + 10 * 3600 )); reg d1 done 400; checkpoint d1 "go" none; run
assert_eq "22:00: no banner" "0" "$(banners)"
assert_contains "22:00: the suppression is logged" "$(tail -1 "$NLOG")" "suppressed:quiet-hours"
assert_eq "22:00: nudged_for stays unset (suppressed, not sent)" "" "$(mget d1 nudged_for)"
unset TNOW

# a session in a repo keeps its checkpoint and NEXT.md in <root>/.agent/ (repo mode needs the GOAL.md there)
R="$WORK/repo1"
reset; mkdir -p "$R/.agent"; printf '# Goal\ntest_command: true\n' >"$R/.agent/GOAL.md"
reg d1 done 400 "$R"
printf '# State\n<!-- ching:checkpoint -->\nresult: x\nblocker: none\nnext_action: land the repo change\nfiles_changed: 0\nexamined: x\nnot_examined: x\n<!-- /ching:checkpoint -->\n' >"$R/.agent/STATE.md"
run
assert_eq "repo mode: open work only in <root>/.agent/STATE.md: banner" "1" "$(banners)"
assert_contains "repo mode: the banner carries that next action" "$(tail -1 "$NLOG")" "land the repo change"
assert_contains "repo mode: the spoken note carries it too" "$(cat "$SPOKEN")" "land the repo change"
reset; reg d1 done 400 "$R"; rm -f "$R/.agent/STATE.md"; printf 'continue in the repo\n' >"$R/.agent/NEXT.md"; run
assert_eq "repo mode: open work only in <root>/.agent/NEXT.md: banner" "1" "$(banners)"

# ---------- spoken note ----------
iso() { printf '%s.123456' "$(date -r $(( $(now) + $1 )) '+%Y-%m-%dT%H:%M:%S')"; } # local time as VoiceMode writes it
conch() { # pid(JSON) held(true|false) acquired expires: write the conch file as VoiceMode does
  # held:false is a call in progress (acquired = call start, no expires); held:true is the short hold between turns.
  # acquired and expires: seconds from now, "-" for null, x... for a literal string that is not a date.
  local acq=null exp=null
  case "$3" in -) ;; x*) acq="\"$3\"" ;; *) acq="\"$(iso "$3")\"" ;; esac
  case "$4" in -) ;; x*) exp="\"$4\"" ;; *) exp="\"$(iso "$4")\"" ;; esac
  printf '{\n  "pid": %s,\n  "agent": "claude-code",\n  "held": %s,\n  "acquired": %s,\n  "expires": %s\n}\n' "$1" "$2" "$acq" "$exp" >"$VOICEMODE_CONCH"
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
# 11 minutes later the 10-minute speech gap is over, so only spoken_for can still hold the note back
TNOW=$(( NOON + 660 )); run
assert_eq "same spell, past the speech gap: still one note" "1" "$(spoken)"
unset TNOW
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
reset; reg e1 ended 400; checkpoint e1 "x" "need a decision"; run
assert_eq "ended: never spoken" "0" "$(spoken)"
assert_eq "ended: no banner" "0" "$(banners)"
# a waiting session that gets a new prompt (working again) is not spoken about
reset; reg i1 input 240; run
TNOW=$(( NOON + 60 )); reg i1 working 300; run
assert_eq "input, then a new prompt (working): not spoken" "0" "$(spoken)"
unset TNOW

# quiet hours, both edges: 09:00 up to but not including 21:00
qh() { reset; TNOW=$(at "$1"); reg i1 input 400; run; assert_eq "quiet hours: spoken at $1" "$2" "$(spoken)"; unset TNOW; }
qh 08:59:00 0
qh 09:00:00 1
qh 20:59:00 1
qh 21:00:00 0
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

# the real `ioreg | awk` branch, as launchd runs it: HID_IDLE_CMD unset, a PATH without /usr/sbin, the binary
# replaced by IOREG_CMD (never the real ioreg). The stub prints a realistic ioreg block; HIDIdleTime is in nanoseconds.
IOSTUB="$WORK/ioreg-stub.sh"
cat >"$IOSTUB" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >"$WORK/ioreg.args"
printf '+-o IOHIDSystem  <class IOHIDSystem, id 0x100000a3b, registered, matched, active, busy 0 (0 ms), retain 8>\n    | {\n    | |   "HIDKeyRepeat" = 0\n'
[ -z "\${STUB_IOREG_NS:-}" ] || printf '    | |   "HIDIdleTime" = %s\n' "\$STUB_IOREG_NS"
printf '    | }\n'
exit "\${STUB_IOREG_RC:-0}"
EOF
chmod +x "$IOSTUB"
RPATH="/usr/bin:/bin:$(dirname "$(command -v jq)")"
case ":$RPATH:" in *:/usr/sbin:*) fail "the launchd-like PATH must not contain /usr/sbin" "  PATH: $RPATH" ;; *) pass "the launchd-like PATH has no /usr/sbin" ;; esac
assert_eq "on that PATH a bare ioreg is not found" "" "$(PATH=$RPATH command -v ioreg || true)"
ioreg_run() { # nanoseconds(or "" for no HIDIdleTime line) [stub exit status]
  reset; reg i1 input 400; : >"$WORK/ioreg.args"
  PATH=$RPATH HID_IDLE_CMD="" IOREG_CMD="$IOSTUB" STUB_IOREG_NS="$1" STUB_IOREG_RC="${2:-0}" run
}
ioreg_run 599000000000
assert_eq "ioreg branch: 599 s idle is present, spoken" "1" "$(spoken)"
assert_eq "ioreg branch: called as ioreg -c IOHIDSystem" "-c IOHIDSystem" "$(cat "$WORK/ioreg.args")"
ioreg_run 599999999999
assert_eq "ioreg branch: 599.99 s idle is still present (whole seconds)" "1" "$(spoken)"
ioreg_run 600000000000
assert_eq "ioreg branch: exactly 600 s idle is absent, not spoken" "0" "$(spoken)"
ioreg_run ""
assert_eq "ioreg branch: no HIDIdleTime line counts as absent" "0" "$(spoken)"
ioreg_run "" 3
assert_eq "ioreg branch: ioreg failing counts as absent" "0" "$(spoken)"
# the stub tests above go through IOREG_CMD, so only this reading of the script can notice a bare `ioreg` default
assert_eq "the watcher has no bare ioreg invocation" "0" "$(grep -v '^[[:space:]]*#' "$W" | grep 'ioreg' | grep -vc '/usr/sbin/ioreg' || true)"
assert_contains "the default is the absolute path, overridable by IOREG_CMD" "$(cat "$W")" '"${IOREG_CMD:-/usr/sbin/ioreg}" -c IOHIDSystem'

# Review Focus 4 (I2): VoiceMode is in use while a LIVE process has an active call (held:false, the whole call)
# or an unexpired hold between turns (held:true, absolute expires). Everything else is free.
LIVE=$$; true & DEAD=$!; wait "$DEAD"
assert_ok "fixture: the live pid is alive" kill -0 "$LIVE"
assert_fails "fixture: the dead pid is gone" kill -0 "$DEAD"
cs() { # name expected_spoken pid held acquired expires: one tick with that conch file
  reset; reg i1 input 400; conch "$3" "$4" "$5" "$6"; run
  assert_eq "conch $1" "$2" "$(spoken)"
}
reset; reg i1 input 400; conch "$LIVE" true -5 60; run
assert_eq "conch: live pid, hold not expired: not spoken" "0" "$(spoken)"
run
assert_eq "conch: still held: retried, still silent" "0" "$(spoken)"
conch "$LIVE" true -5 -60; run
assert_eq "conch: the hold expired: spoken" "1" "$(spoken)"
cs "live pid, hold expiring this very second: spoken" 1 "$LIVE" true -5 0
cs "live pid, hold expiring in 1 s: not spoken" 0 "$LIVE" true -5 1
cs "live pid, call in progress (held:false, started 30 s ago): not spoken" 0 "$LIVE" false -30 -
cs "live pid, call started 300 s ago (inside VoiceMode's window): not spoken" 0 "$LIVE" false -300 -
cs "live pid, call started 301 s ago (VoiceMode would clear it): spoken" 1 "$LIVE" false -301 -
cs "dead pid, call in progress: spoken" 1 "$DEAD" false -30 -
cs "dead pid, hold not expired: spoken" 1 "$DEAD" true -5 60
cs "pid 0 (kill -0 0 would hit the whole process group): spoken" 1 0 false -30 -
cs "pid as a string, not a number: spoken" 1 "\"$LIVE\"" false -30 -
cs "no pid: spoken" 1 null false -30 -
cs "hold with an expires that is not a date: spoken" 1 "$LIVE" true -5 xnot-a-date
cs "hold with no expires: spoken" 1 "$LIVE" true -5 -
cs "call with an acquired that is not a date: spoken" 1 "$LIVE" false xnot-a-date -
cs "call with no acquired: spoken" 1 "$LIVE" false - -
reset; reg i1 input 400; echo 'not json {' >"$VOICEMODE_CONCH"; run
assert_eq "conch: corrupt file counts as free" "1" "$(spoken)"
reset; reg i1 input 400; : >"$VOICEMODE_CONCH"; run
assert_eq "conch: empty file counts as free" "1" "$(spoken)"
reset; reg i1 input 400; printf '[{"pid": %s, "held": false, "acquired": "%s"}]\n' "$LIVE" "$(iso -30)" >"$VOICEMODE_CONCH"; run
assert_eq "conch: a JSON array (even one that looks like a call) counts as free" "1" "$(spoken)"
reset; reg i1 input 400; echo '42' >"$VOICEMODE_CONCH"; run
assert_eq "conch: a JSON scalar counts as free" "1" "$(spoken)"
reset; reg i1 input 400; run
assert_eq "conch: missing file counts as free" "1" "$(spoken)"
# VoiceMode's own window is configurable (VOICEMODE_CONCH_LOCK_EXPIRY); a call older than it is stale
reset; reg i1 input 400; conch "$LIVE" false -100 -; VOICEMODE_CONCH_LOCK_EXPIRY=60 run
assert_eq "conch: window 60 s, call 100 s old: spoken" "1" "$(spoken)"
reset; reg i1 input 400; conch "$LIVE" false -100 -; VOICEMODE_CONCH_LOCK_EXPIRY=abc run
assert_eq "conch: a bad window falls back to 300 s: call 100 s old, not spoken" "0" "$(spoken)"

# two waiting sessions do not talk back to back; the second goes on a later tick, after exactly 10 minutes
reset; reg i1 input 400; reg i2 input 400; run
assert_eq "two waiting sessions: one note now" "1" "$(spoken)"
assert_eq "the second is left for later" "" "$(mget i2 spoken_for)"
TNOW=$(( NOON + 599 )); run
assert_eq "599 s after the last note: the second still waits" "1" "$(spoken)"
TNOW=$(( NOON + 600 )); run
assert_eq "600 s after the last note: the second speaks" "2" "$(spoken)"
assert_eq "and the first is not repeated" "1" "$(grep -c 'i1 has been waiting' "$SPOKEN")"
unset TNOW

# a failing voice does not mark the spell as spoken
reset; reg i1 input 400
SPEAK_CMD=false run
assert_eq "voice failure: spoken_for stays unset" "" "$(mget i1 spoken_for)"
assert_no_file "voice failure: no last-spoken stamp" "$AGENT_HOME/notify/last-spoken"
run
assert_eq "voice back: spoken on the next tick" "1" "$(spoken)"
# ... and one failed attempt per tick is enough: a hung Kokoro must not cost 30 s per waiting session
FAILSTUB="$WORK/speak-fail.sh"; CALLS="$WORK/speak-calls.log"
printf '#!/usr/bin/env bash\nprintf "call\\n" >>"%s"\nexit 1\n' "$CALLS" >"$FAILSTUB"; chmod +x "$FAILSTUB"
reset; : >"$CALLS"; reg i1 input 400; reg i2 input 400; reg i3 input 400
SPEAK_CMD="$FAILSTUB" run
assert_eq "three waiting sessions, voice down: one attempt in the tick" "1" "$(wc -l <"$CALLS" | tr -d ' ')"
assert_eq "voice down: no spoken_for on any session" "" "$(mget i1 spoken_for)$(mget i2 spoken_for)$(mget i3 spoken_for)"
assert_no_file "voice down: no last-spoken stamp" "$AGENT_HOME/notify/last-spoken"
run
assert_eq "voice back on the next tick: one note" "1" "$(spoken)"

# hostile names and next actions reach the voice as one line, capped
reset; reg i1 input 400; checkpoint i1 'do "this" now; it'"'"'s a \ test' none; run
assert_eq "quotes and a backslash in the next action: spoken once" "1" "$(spoken)"
assert_contains "and spoken as written" "$(cat "$SPOKEN")" 'do "this" now; it'"'"'s a \ test'

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

# a meta file that has not been written for longer than the cap is skipped on its mtime, before any meta_get
# (the nudge pass must not undo the 48 h dead-session skip: it would fork three times per old session)
reset; reg i1 input 400; touch -t 202610031200 "$AGENT_HOME/sessions/i1/meta"; run
assert_eq "waiting session, meta file untouched for 2 days: not spoken" "0" "$(spoken)"
reset; reg d1 done 400; checkpoint d1 "go" none; touch -t 202610031200 "$AGENT_HOME/sessions/d1/meta"; run
assert_eq "done session, meta file untouched for 2 days: no banner" "0" "$(banners)"
reset; reg i1 input 400; touch -t 202610050001 "$AGENT_HOME/sessions/i1/meta"; run
assert_eq "meta file written 12 h minus 1 min ago: still nudged" "1" "$(spoken)"
reset; reg i1 input 400; touch -t 202610040001 "$AGENT_HOME/sessions/i1/meta"; WATCH_NUDGE_MAX_HOURS=48 run
assert_eq "a larger cap moves the mtime cutoff with it" "1" "$(spoken)"

# ---------- bad knobs and a hostile notify.log must not end the tick early ----------
# The token budget and the log rotation come after the nudge pass, so every run here also has a daily token total
# over its budget: the alert flag proves the script got to the end. 1 = i1 (400 s old) is nudged; i2 (25 h) stays stale.
TOKDAY=$(date -u -r "$NOON" +%Y-%m-%d)
tickend() { # name: asserts after a run that set up a token total of 9 against a budget of 8
  assert_file "$1: the daily token alert after the nudge pass still fires" "$AGENT_HOME/tokens/$TOKDAY.alert100"
}
knob() { # VAR VALUE
  local rc
  reset; reg i1 input 400; reg i2 input 90000
  mkdir -p "$AGENT_HOME/tokens"; printf 'mach 9\n' >"$AGENT_HOME/tokens/$TOKDAY"
  env "$1=$2" TOKEN_BUDGET_DAILY=8 WATCH_NOW="$NOON" "$W" >/dev/null 2>"$WORK/knob.err"; rc=$?
  assert_eq "$1=$2: the run ends with exit 0" "0" "$rc"
  assert_eq "$1=$2: no error output" "" "$(cat "$WORK/knob.err")"
  assert_eq "$1=$2: the default applies: the 6-minute session is spoken" "1" "$(spoken)"
  assert_eq "$1=$2: the default cap applies: the 25 h session is stale" "" "$(mget i2 spoken_for)"
  tickend "$1=$2"
}
knob WATCH_NUDGE_MAX_HOURS abc
knob WATCH_NUDGE_MAX_HOURS 1.5
knob WATCH_NUDGE_MAX_HOURS ""
knob WATCH_WAIT_GRACE_MINS abc
knob WATCH_SPEAK_AFTER_MINS 1.5
knob WATCH_PRESENT_MINS abc
knob WATCH_SPEAK_GAP_MINS 1.5
knob NOTIFY_QUIET_END abc
knob NOTIFY_QUIET_START 1.5
# a cap so large that "now minus the cap" lies before 1970 must not break the mtime cutoff or end the tick
reset; reg i1 input 90000
mkdir -p "$AGENT_HOME/tokens"; printf 'mach 9\n' >"$AGENT_HOME/tokens/$TOKDAY"
WATCH_NUDGE_MAX_HOURS=999999999 TOKEN_BUDGET_DAILY=8 run; rc=$?
assert_eq "WATCH_NUDGE_MAX_HOURS=999999999: the run ends with exit 0" "0" "$rc"
assert_eq "WATCH_NUDGE_MAX_HOURS=999999999: nothing is stale, the 25 h session is spoken" "1" "$(spoken)"
tickend "WATCH_NUDGE_MAX_HOURS=999999999"
# WATCH_NUDGE_MAX_HOURS=0 switches nudging off
reset; reg i1 input 400; reg d1 done 400; checkpoint d1 "go" none
mkdir -p "$AGENT_HOME/tokens"; printf 'mach 9\n' >"$AGENT_HOME/tokens/$TOKDAY"
WATCH_NUDGE_MAX_HOURS=0 TOKEN_BUDGET_DAILY=8 run
assert_eq "WATCH_NUDGE_MAX_HOURS=0: nothing spoken" "0" "$(spoken)"
assert_eq "WATCH_NUDGE_MAX_HOURS=0: no banner" "0" "$(banners)"
tickend "WATCH_NUDGE_MAX_HOURS=0"
reset; reg d1 done 0; checkpoint d1 "go" none
WATCH_WAIT_GRACE_MINS=0 WATCH_NUDGE_MAX_HOURS=0 run
# (with the grace also 0, a session that stopped this second is inside the cap of 0 s: only the switch itself holds it back)
assert_eq "WATCH_NUDGE_MAX_HOURS=0 even for a session that stopped this second: no banner" "0" "$(banners)"
reset; reg d1 done 0; checkpoint d1 "go" none
WATCH_WAIT_GRACE_MINS=0 run
assert_eq "control: grace 0 and the default cap: a session that stopped this second gets its banner" "1" "$(banners)"
# an unreadable notify.log: the banner cannot be confirmed, but the tick still runs to its end
reset; reg d1 done 400; checkpoint d1 "go" none
mkdir -p "$AGENT_HOME/tokens"; printf 'mach 9\n' >"$AGENT_HOME/tokens/$TOKDAY"
chmod 000 "$NLOG"
if [ -r "$NLOG" ]; then
  pass "unreadable notify.log: skipped (this user can read a mode-000 file: root)"
else
  TOKEN_BUDGET_DAILY=8 run; rc=$?
  assert_eq "unreadable notify.log: the run ends with exit 0" "0" "$rc"
  tickend "unreadable notify.log"
  assert_eq "unreadable notify.log: the banner is not marked as sent" "" "$(mget d1 nudged_for)"
fi
chmod 644 "$NLOG"
exit 0
