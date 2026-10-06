#!/usr/bin/env bash
# Stop hook: retry then end, per-session counters, schema, any folder.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R=$(mk_repo stoprepo)
OKFILE="$WORK/tests-ok"
write_goal "$R" "test -f $OKFILE"
stop() { run_hook stop-check.sh "$(hook_json Stop "$1" "$2" "$(jq -n --arg m "${3:-All done.}" '{stop_hook_active:false,last_assistant_message:$m}')")"; }
notify_log() { cat "$AGENT_HOME/notify.log" 2>/dev/null || true; }

# failing tests: block three times, then let the session end
for i in 1 2 3; do
  out=$(stop "$R" sess-A)
  assert_eq "attempt $i: decision is block" "block" "$(printf '%s' "$out" | jq -r .decision)"
  assert_contains "attempt $i: reason says attempt $i of 3" "$(printf '%s' "$out" | jq -r .reason)" "attempt $i of 3"
done
assert_contains "reason carries the command" "$(printf '%s' "$out" | jq -r .reason)" "test -f $OKFILE"
out=$(stop "$R" sess-A); rc=$?
assert_eq "attempt 4: allowed to stop (exit 0)" "0" "$rc"
assert_eq "attempt 4: no block JSON" "" "$out"
assert_contains "cap recorded in STATE.md" "$(cat "$R/.agent/STATE.md")" "gave up after 3 retries"
assert_contains "cap notifies Blocked with the repo name" "$(notify_log)" "stoprepo (main): Blocked"
assert_contains "meta state is blocked" "$(cat "$AGENT_HOME/sessions/sess-A/meta")" "state=blocked"

# a second session has its own counter
out=$(stop "$R" sess-B)
assert_contains "second session starts at attempt 1" "$(printf '%s' "$out" | jq -r .reason)" "attempt 1 of 3"
# the counter lives per session id, outside the repo
assert_file "counter keyed by session id" "$AGENT_HOME/sessions/sess-B/retries"
assert_eq "counter value" "1" "$(cat "$AGENT_HOME/sessions/sess-B/retries")"

# tests go green: stop allowed, counter reset, Done notification
touch "$OKFILE"
: >"$AGENT_HOME/notify.log"
out=$(stop "$R" sess-B "Finished the work.")
assert_eq "green: no output" "" "$out"
assert_no_file "green: counter reset" "$AGENT_HOME/sessions/sess-B/retries"
assert_contains "green: Done notification with repo name" "$(notify_log)" "stoprepo (main): Done"
assert_contains "green: meta state done" "$(cat "$AGENT_HOME/sessions/sess-B/meta")" "state=done"

# a question at the end of the turn is "needs input"
: >"$AGENT_HOME/notify.log"; rm -f "$AGENT_HOME/notify/"*.last
stop "$R" sess-C "I changed X. Which colour do you want?" >/dev/null
assert_contains "question -> Needs input" "$(notify_log)" "Needs input"

# unchanged tree after a green run: the test command is not run again
CNT="$WORK/runs"; : >"$CNT"
write_goal "$R" "echo run >>$CNT"
stop "$R" sess-D >/dev/null; stop "$R" sess-D >/dev/null
assert_eq "unchanged tree: tests ran once" "1" "$(wc -l <"$CNT" | tr -d ' ')"
echo change >>"$R/README.md"
stop "$R" sess-D >/dev/null
assert_eq "changed tree: tests ran again" "2" "$(wc -l <"$CNT" | tr -d ' ')"
git -C "$R" checkout -q README.md

# placeholder test_command means "no check"
write_goal "$R" "<the repo's own check>"
out=$(stop "$R" sess-E); assert_eq "placeholder test_command: allows stop" "" "$out"

# a repo with no GOAL.md anywhere: allow, notify with the folder name
R3=$(mk_repo nogoal)
: >"$AGENT_HOME/notify.log"
out=$(stop "$R3" sess-F); assert_eq "repo without GOAL.md: allows stop silently" "" "$out"
assert_contains "repo without GOAL.md: notifies" "$(notify_log)" "nogoal (main): Done"

# plain non-git folder
P="$WORK/some folder"; mkdir -p "$P"; : >"$AGENT_HOME/notify.log"
out=$(stop "$P" sess-G); assert_eq "non-git folder: allows stop" "" "$out"
assert_contains "non-git folder: notification names the folder" "$(notify_log)" "some folder: Done"

# cwd = ~
: >"$AGENT_HOME/notify.log"
out=$(stop "$HOME" sess-H); assert_eq "home: allows stop" "" "$out"
assert_contains "home: notification titled ~" "$(notify_log)" "~: Done"

# machine default GOAL.md with a failing test applies to a non-git folder, running in that folder
mkdir -p "$AGENT_HOME/defaults"
printf 'test_command: test -f marker-file-here\n' >"$AGENT_HOME/defaults/GOAL.md"
out=$(stop "$P" sess-I)
assert_eq "defaults GOAL: blocks a non-git folder" "block" "$(printf '%s' "$out" | jq -r .decision)"
touch "$P/marker-file-here"
out=$(stop "$P" sess-I); assert_eq "defaults GOAL: runs in the session folder, then allows" "" "$out"
rm -rf "$AGENT_HOME/defaults"

# timeout is treated as a failure
write_goal "$R" "sleep 5"
out=$(STOP_CHECK_TIMEOUT=1 stop "$R" sess-J)
assert_contains "timeout -> block with timed out" "$(printf '%s' "$out" | jq -r .reason)" "timed out"

# escalation: a failing check calls the cheap model, which fixes it, so the stop is allowed
cat >"$WORK/fake-claude" <<'EOS'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --model ] && echo "$2" >>"$ESC_CALLS"; shift; done
touch "$ESC_FILE"
EOS
chmod +x "$WORK/fake-claude"
export ESC_CALLS="$WORK/esc-calls" ESC_FILE="$WORK/esc-ok"; : >"$ESC_CALLS"; rm -f "$ESC_FILE"
write_goal "$R" "test -f $ESC_FILE"
out=$(CHING_CLAUDE_BIN="$WORK/fake-claude" CHING_TEST_MODELS="cheap strong" stop "$R" sess-ESC1)
assert_eq "escalation: cheap model fixed it, stop allowed" "" "$out"
assert_eq "escalation: only the cheap model was called" "cheap" "$(tr '\n' ' ' <"$ESC_CALLS" | sed 's/ $//')"
rm -f "$ESC_FILE"
out=$(CHING_TEST_MODELS="" stop "$R" sess-ESC2)
assert_eq "no models configured: plain block" "block" "$(printf '%s' "$out" | jq -r .decision)"
# recursion guard: a model started by test-escalate.sh inherits this hook; its stop is never gated
: >"$ESC_CALLS"; rm -f "$ESC_FILE"
out=$(CHING_ESCALATING=1 CHING_CLAUDE_BIN="$WORK/fake-claude" CHING_TEST_MODELS="cheap strong" stop "$R" sess-ESC3)
assert_eq "escalating child: stop is allowed, never blocked" "" "$out"
assert_eq "escalating child: no model is started" "0" "$(wc -l <"$ESC_CALLS" | tr -d ' ')"
assert_no_file "escalating child: no retry counter written" "$AGENT_HOME/sessions/sess-ESC3/retries"

# ---------- runaway guards (Task 12a) ----------
# F1: the test_command itself may start a Claude session; that session's Stop hook is stop-check.sh again,
# under a new session id. The hook marks its test run, so the nested stop is never gated, counted or run.
# The stand-in test is bounded (it nests at most twice) so an unfixed hook ends instead of looping.
NR1=$(mk_repo nestrepo)
cat >"$WORK/nest-test.sh" <<'EOS'
#!/usr/bin/env bash
echo run >>"$NEST_CNT"
n=$(wc -l <"$NEST_CNT" | tr -d ' ')
if [ "$n" -lt 3 ]; then
  jq -n --arg c "$NEST_CWD" --arg s "sess-NEST-in$n" \
    '{hook_event_name:"Stop",cwd:$c,session_id:$s,stop_hook_active:false,last_assistant_message:"x"}' \
    | "$NEST_HOOK" >>"$NEST_OUT" 2>&1
  echo "$?" >>"$NEST_RC"
fi
exit 1
EOS
export NEST_CNT="$WORK/nest-cnt" NEST_OUT="$WORK/nest-out" NEST_RC="$WORK/nest-rc" NEST_CWD="$NR1" NEST_HOOK="$BIN/stop-check.sh"
: >"$NEST_CNT"; : >"$NEST_OUT"; : >"$NEST_RC"
write_goal "$NR1" "bash $WORK/nest-test.sh"
out=$(stop "$NR1" sess-NEST)
assert_eq "nested stop: the top-level stop still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_eq "nested stop: the test command ran once (not once per nesting level)" "1" "$(wc -l <"$NEST_CNT" | tr -d ' ')"
assert_eq "nested stop: the nested hook ran and exited 0" "0" "$(tr '\n' ' ' <"$NEST_RC" | sed 's/ $//')"
assert_eq "nested stop: the nested hook printed nothing" "" "$(cat "$NEST_OUT")"
assert_no_file "nested stop: no retry counter for the first nested session" "$AGENT_HOME/sessions/sess-NEST-in1/retries"
assert_no_file "nested stop: no retry counter for a second nested session" "$AGENT_HOME/sessions/sess-NEST-in2/retries"
assert_file "nested stop: the top-level session has its own counter" "$AGENT_HOME/sessions/sess-NEST/retries"

# F2: the stop that hits the cap is allowed anyway, so it must not pay for the model ladder again.
cat >"$WORK/fake-claude-nofix" <<'EOS'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --model ] && echo "$2" >>"$NOFIX_CALLS"; shift; done
# ---------- session ids (F12) ----------
# a session id is a directory name under sessions/: one with ".." or "/" must not reach outside it
SR=$(mk_repo sidrepo); write_goal "$SR" "false"
out=$(stop "$SR" "../escape-a")
assert_eq "sid with ..: still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_no_file "sid with ..: nothing written outside sessions/" "$AGENT_HOME/escape-a"
out=$(stop "$SR" "nest/ed")
assert_no_file "sid with /: no nested directory" "$AGENT_HOME/sessions/nest"
out=$(stop "$SR" "..")
assert_no_file "sid '..': no retries file in AGENT_HOME" "$AGENT_HOME/retries"
assert_eq "unsafe sids map to their own sid-<hash> dirs" "3" "$(ls "$AGENT_HOME/sessions" | grep -c '^sid-')"
out=$(stop "$SR" "../escape-a")
assert_contains "the same unsafe sid keeps its own counter" "$(printf '%s' "$out" | jq -r .reason)" "attempt 2 of 3"
exit 0
EOS
chmod +x "$WORK/fake-claude-nofix"
export NOFIX_CALLS="$WORK/nofix-calls"; : >"$NOFIX_CALLS"
write_goal "$R" "test -f $WORK/never-exists"
for i in 1 2 3; do
  # LADDER_DAILY=100: this test counts the calls per stop, the daily ceiling (default 6) has its own test below
  out=$(CHING_TEST_LADDER_DAILY=100 CHING_CLAUDE_BIN="$WORK/fake-claude-nofix" CHING_TEST_MODELS="cheap strong" stop "$R" sess-CAPLADDER)
  assert_eq "cap ladder: stop $i blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
done
GAVE_UP_BEFORE=$(grep -c 'gave up after' "$R/.agent/STATE.md" || true)
out=$(CHING_TEST_LADDER_DAILY=100 CHING_CLAUDE_BIN="$WORK/fake-claude-nofix" CHING_TEST_MODELS="cheap strong" stop "$R" sess-CAPLADDER)
assert_eq "cap ladder: stop 4 is allowed" "" "$out"
assert_eq "cap ladder: 3 blocking stops x 2 models, none on the cap stop" "6" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
assert_no_file "cap ladder: counter reset at the cap" "$AGENT_HOME/sessions/sess-CAPLADDER/retries"
assert_eq "cap ladder: the cap stop is still recorded in STATE.md" "$((GAVE_UP_BEFORE + 1))" "$(grep -c 'gave up after' "$R/.agent/STATE.md" || true)"

# Daily ceiling: the retry cap is per session id, so a repo whose tests fail for any reason (a missing service)
# would pay for the whole ladder on every blocked stop of every session. CHING_TEST_LADDER_DAILY caps the
# model calls per UTC day, machine-wide. One session id, 3 prompts x 4 stops: 18 calls without the ceiling.
rm -rf "$AGENT_HOME/ladder"; : >"$NOFIX_CALLS"
for p in 1 2 3; do
  for i in 1 2 3; do
    out=$(CHING_TEST_LADDER_DAILY=4 CHING_CLAUDE_BIN="$WORK/fake-claude-nofix" CHING_TEST_MODELS="cheap strong" stop "$R" sess-DAILY)
    assert_eq "daily ceiling: prompt $p stop $i still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
  done
  out=$(CHING_TEST_LADDER_DAILY=4 CHING_CLAUDE_BIN="$WORK/fake-claude-nofix" CHING_TEST_MODELS="cheap strong" stop "$R" sess-DAILY)
  assert_eq "daily ceiling: prompt $p stop 4 is allowed" "" "$out"
done
assert_eq "daily ceiling 4: 3 prompts x 4 stops make exactly 4 model calls" "4" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
assert_eq "daily ceiling 4: the counter says 4" "4" "$(cat "$AGENT_HOME/ladder/$(date -u +%Y-%m-%d)")"
assert_contains "daily ceiling 4: the cap is in the escalation log" "$(cat "$AGENT_HOME/test-escalation.log")" "ladder-cap"

# F6: a non-numeric or zero cap must not switch the safety limit off.
for i in 1 2 3; do
  out=$(STOP_CHECK_MAX_RETRIES=three stop "$R" sess-MAXWORD)
  assert_contains "MAX=three behaves like 3: stop $i blocks, attempt $i of 3" "$(printf '%s' "$out" | jq -r .reason)" "attempt $i of 3"
done
out=$(STOP_CHECK_MAX_RETRIES=three stop "$R" sess-MAXWORD)
assert_eq "MAX=three behaves like 3: stop 4 is allowed" "" "$out"
out=$(STOP_CHECK_MAX_RETRIES=0 stop "$R" sess-MAXZERO)
assert_contains "MAX=0 behaves like 1: first stop blocks, attempt 1 of 1" "$(printf '%s' "$out" | jq -r .reason)" "attempt 1 of 1"
out=$(STOP_CHECK_MAX_RETRIES=0 stop "$R" sess-MAXZERO)
assert_eq "MAX=0 behaves like 1: second stop is allowed" "" "$out"
# TIMEOUT=0 is perl `alarm 0` (no alarm): it behaves like 1 second. (A non-number falls back to 900 s, which
# cannot be observed without a 900 s test, so only the zero case is tested.)
write_goal "$R" "sleep 3; exit 1"
out=$(STOP_CHECK_TIMEOUT=0 stop "$R" sess-TMOZERO)
assert_contains "TIMEOUT=0 behaves like 1: timed out after 1s" "$(printf '%s' "$out" | jq -r .reason)" "timed out after 1s"

# ---------- events (Phase 1.5) ----------
EVF="$AGENT_HOME/events.jsonl"
assert_eq "events: three test blocks and one cap for sess-A" "4" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .kind' "$EVF" | wc -l | tr -d ' ')"
assert_contains "events: cap is marked" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .data.reason' "$EVF")" "tests-cap"
assert_contains "events: a green stop logs stop_ok" "$(jq -r 'select(.kind=="stop_ok") | .sid' "$EVF")" "sess-B"

# ---------- checkpoint rule (Phase 1.5) ----------
CR=$(mk_repo cprepo); write_goal "$CR" "true"
touch_prompt() { printf '%s' "$(hook_json UserPromptSubmit "$1" "$2")" | "$BIN/session-start.sh" touch; }
touch_prompt "$CR" cp-1
out=$(stop "$CR" cp-1)
assert_eq "checkpoint missing: blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_contains "checkpoint missing: reason names /handoff" "$(printf '%s' "$out" | jq -r .reason)" "/handoff"
out=$(stop "$CR" cp-1)
assert_eq "checkpoint: asked only once per prompt" "" "$out"
# the first cp-1 stop exited at the block, so the only stop_ok for cp-1 comes from this second stop reaching its normal end
assert_eq "checkpoint: second stop ran to the end (one stop_ok, not a dead hook)" "cp-1" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-1") | .sid' "$EVF")"
touch_prompt "$CR" cp-2
printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nresult: ok\nblocker: none\nnext_action: none\n<!-- /ching:checkpoint -->\n' >"$CR/.agent/STATE.md"
out=$(stop "$CR" cp-2)
assert_eq "fresh checkpoint: no block" "" "$out"
assert_contains "fresh checkpoint: checkpoint event" "$(jq -r 'select(.kind=="checkpoint") | .sid' "$AGENT_HOME/events.jsonl")" "cp-2"
touch -t 202001010000 "$CR/.agent/STATE.md"
touch_prompt "$CR" cp-2
out=$(stop "$CR" cp-2)
assert_eq "stale checkpoint (older than the prompt): blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
CP="$WORK/cp plain"; mkdir -p "$CP"
touch_prompt "$CP" cp-3
out=$(stop "$CP" cp-3)
assert_eq "plain folder: never blocks for a checkpoint" "" "$out"
assert_eq "plain folder: stop ran to the end (stop_ok logged)" "cp-3" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-3") | .sid' "$EVF")"
NR=$(mk_repo cpnoprompt); write_goal "$NR" "true"
out=$(stop "$NR" cp-4)
assert_eq "no recorded prompt: never blocks for a checkpoint" "" "$out"
assert_eq "no recorded prompt: stop ran to the end (stop_ok logged)" "cp-4" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-4") | .sid' "$EVF")"
# block once, the model then writes the checkpoint: the next stop passes AND the checkpoint event is logged
touch_prompt "$CR" cp-5
out=$(stop "$CR" cp-5)
assert_eq "block-then-comply: first stop blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_eq "block-then-comply: no checkpoint event yet" "" "$(jq -r 'select(.kind=="checkpoint" and .sid=="cp-5") | .sid' "$EVF")"
printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nresult: ok\nblocker: none\nnext_action: none\n<!-- /ching:checkpoint -->\n' >"$CR/.agent/STATE.md"
out=$(stop "$CR" cp-5)
assert_eq "block-then-comply: second stop passes" "" "$out"
assert_eq "block-then-comply: checkpoint event logged after the block" "cp-5" "$(jq -r 'select(.kind=="checkpoint" and .sid=="cp-5") | .sid' "$EVF")"
assert_eq "block-then-comply: second stop ran to the end (stop_ok logged)" "cp-5" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-5") | .sid' "$EVF")"
# ---------- session ids (F12) ----------
# a session id is a directory name under sessions/: one with ".." or "/" must not reach outside it
SR=$(mk_repo sidrepo); write_goal "$SR" "false"
out=$(stop "$SR" "../escape-a")
assert_eq "sid with ..: still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_no_file "sid with ..: nothing written outside sessions/" "$AGENT_HOME/escape-a"
out=$(stop "$SR" "nest/ed")
assert_no_file "sid with /: no nested directory" "$AGENT_HOME/sessions/nest"
out=$(stop "$SR" "..")
assert_no_file "sid '..': no retries file in AGENT_HOME" "$AGENT_HOME/retries"
assert_eq "unsafe sids map to their own sid-<hash> dirs" "3" "$(ls "$AGENT_HOME/sessions" | grep -c '^sid-')"
out=$(stop "$SR" "../escape-a")
assert_contains "the same unsafe sid keeps its own counter" "$(printf '%s' "$out" | jq -r .reason)" "attempt 2 of 3"
exit 0
