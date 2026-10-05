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
