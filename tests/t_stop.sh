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
assert_contains "question -> meta state input" "$(cat "$AGENT_HOME/sessions/sess-C/meta")" "state=input"
assert_contains "question -> meta ask holds it" "$(cat "$AGENT_HOME/sessions/sess-C/meta")" "ask=Which colour do you want?"
# a request with no question mark is "needs input" too
stop "$R" sess-C "Merged. If it doesn't snap, tell me and I'll check the logs." >/dev/null
assert_contains "request -> meta state input" "$(cat "$AGENT_HOME/sessions/sess-C/meta")" "state=input"
# the next done turn clears the ask
stop "$R" sess-C "All merged and installed." >/dev/null
assert_contains "done -> meta state done" "$(cat "$AGENT_HOME/sessions/sess-C/meta")" "state=done"
assert_eq "done -> meta ask empty" "ask=" "$(grep '^ask=' "$AGENT_HOME/sessions/sess-C/meta")"

# unchanged tree after a green run: the test command is not run again
CNT="$WORK/runs"; : >"$CNT"
write_goal "$R" "echo run >>$CNT"
stop "$R" sess-D >/dev/null; stop "$R" sess-D >/dev/null
assert_eq "unchanged tree: tests ran once" "1" "$(wc -l <"$CNT" | tr -d ' ')"
echo change >>"$R/README.md"
stop "$R" sess-D >/dev/null
assert_eq "changed tree: tests ran again" "2" "$(wc -l <"$CNT" | tr -d ' ')"
git -C "$R" checkout -q README.md
assert_contains "unchanged tree: a check_skipped event is logged" "$(jq -r 'select(.kind=="check_skipped" and .sid=="sess-D") | .data.reason' "$AGENT_HOME/events.jsonl")" "unchanged"
# F8: the skip has a time limit (STOP_CHECK_SKIP_TTL, default 1800 s): an older green run is not trusted
: >"$CNT"
STOP_CHECK_SKIP_TTL=1 stop "$R" sess-TTL >/dev/null; sleep 2
STOP_CHECK_SKIP_TTL=1 stop "$R" sess-TTL >/dev/null
assert_eq "skip TTL: a green run older than the TTL is run again" "2" "$(wc -l <"$CNT" | tr -d ' ')"
STOP_CHECK_SKIP_TTL=0 stop "$R" sess-TTL >/dev/null
assert_eq "skip TTL 0: never skipped" "3" "$(wc -l <"$CNT" | tr -d ' ')"
# F8: the green fingerprint is the tree as it was before the run, kept only when the run left the tree as it
# found it. A check that writes into the tree is run again next time; once it writes nothing new, it is skipped.
: >"$CNT"
write_goal "$R" "echo run >>$CNT; echo gen >$R/gen.out"
stop "$R" sess-PRE >/dev/null; stop "$R" sess-PRE >/dev/null; stop "$R" sess-PRE >/dev/null
assert_eq "pre-run fingerprint: the run that changed the tree is not trusted, the next one is" "2" "$(wc -l <"$CNT" | tr -d ' ')"
rm -f "$R/gen.out"

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
out=$(AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-ESC1)
assert_eq "escalation: cheap model fixed it, stop allowed" "" "$out"
assert_eq "escalation: only the cheap model was called" "cheap" "$(tr '\n' ' ' <"$ESC_CALLS" | sed 's/ $//')"
rm -f "$ESC_FILE"
out=$(AGENT_TERMINAL_TEST_MODELS="" stop "$R" sess-ESC2)
assert_eq "no models configured: plain block" "block" "$(printf '%s' "$out" | jq -r .decision)"
# recursion guard: a model started by test-escalate.sh inherits this hook; its stop is never gated
: >"$ESC_CALLS"; rm -f "$ESC_FILE"
out=$(AGENT_TERMINAL_ESCALATING=1 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-ESC3)
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
exit 0
EOS
chmod +x "$WORK/fake-claude-nofix"
export NOFIX_CALLS="$WORK/nofix-calls"; : >"$NOFIX_CALLS"
write_goal "$R" "test -f $WORK/never-exists"
# every stop below changes the tree first: the ladder is skipped for a tree it already failed on (tested below)
for i in 1 2 3; do
  echo "cap $i" >>"$R/churn.txt"
  # LADDER_DAILY=100: this test counts the calls per stop, the daily ceiling (default 6) has its own test below
  out=$(AGENT_TERMINAL_TEST_LADDER_DAILY=100 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-nofix" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-CAPLADDER)
  assert_eq "cap ladder: stop $i blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
done
GAVE_UP_BEFORE=$(grep -c 'gave up after' "$R/.agent/STATE.md" || true)
out=$(AGENT_TERMINAL_TEST_LADDER_DAILY=100 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-nofix" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-CAPLADDER)
assert_eq "cap ladder: stop 4 is allowed" "" "$out"
assert_eq "cap ladder: 3 blocking stops x 2 models, none on the cap stop" "6" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
assert_no_file "cap ladder: counter reset at the cap" "$AGENT_HOME/sessions/sess-CAPLADDER/retries"
assert_eq "cap ladder: the cap stop is still recorded in STATE.md" "$((GAVE_UP_BEFORE + 1))" "$(grep -c 'gave up after' "$R/.agent/STATE.md" || true)"

# Daily ceiling: the retry cap is per session id, so a repo whose tests fail for any reason (a missing service)
# would pay for the whole ladder on every blocked stop of every session. AGENT_TERMINAL_TEST_LADDER_DAILY caps the
# model calls per UTC day, machine-wide. One session id, 3 prompts x 4 stops: 18 calls without the ceiling.
rm -rf "$AGENT_HOME/ladder"; : >"$NOFIX_CALLS"
for p in 1 2 3; do
  for i in 1 2 3; do
    echo "daily $p $i" >>"$R/churn.txt"
    out=$(AGENT_TERMINAL_TEST_LADDER_DAILY=4 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-nofix" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-DAILY)
    assert_eq "daily ceiling: prompt $p stop $i still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
  done
  out=$(AGENT_TERMINAL_TEST_LADDER_DAILY=4 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-nofix" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-DAILY)
  assert_eq "daily ceiling: prompt $p stop 4 is allowed" "" "$out"
done
assert_eq "daily ceiling 4: 3 prompts x 4 stops make exactly 4 model calls" "4" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
assert_eq "daily ceiling 4: the counter says 4" "4" "$(cat "$AGENT_HOME/ladder/$(date -u +%Y-%m-%d)")"
assert_contains "daily ceiling 4: the cap is in the escalation log" "$(cat "$AGENT_HOME/test-escalation.log")" "ladder-cap"

# Same failing tree, same ladder result: a tree the ladder already failed on is not sent to it again.
LR=$(mk_repo ladderrepo); write_goal "$LR" "test -f $WORK/never-exists"
cat >"$WORK/fake-claude-try" <<'EOS'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --model ] && echo "$2" >>"$NOFIX_CALLS"; shift; done
echo "attempted fix" >"$TRY_FILE"   # edits the tree without fixing anything
EOS
chmod +x "$WORK/fake-claude-try"
export TRY_FILE="$LR/attempt.txt"
lstop() { AGENT_TERMINAL_TEST_LADDER_DAILY=100 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-try" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$LR" "$1"; }
: >"$NOFIX_CALLS"
out=$(lstop sess-SAME)
assert_eq "same tree: first stop runs the ladder (2 calls)" "2" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
out=$(lstop sess-SAME)
assert_eq "same tree: the tree the ladder left behind is not sent again" "2" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
assert_eq "same tree: the stop still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_contains "same tree: a ladder_skipped event says why" "$(jq -r 'select(.kind=="ladder_skipped" and .sid=="sess-SAME") | .data.reason' "$AGENT_HOME/events.jsonl")" "same-tree"
out=$(lstop sess-OTHER)
assert_eq "same tree: another session on that tree does not pay either" "2" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
echo "real change" >>"$LR/README.md"
out=$(lstop sess-SAME)
assert_eq "changed tree: the ladder runs again" "4" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
git -C "$LR" checkout -q README.md
# a tree is recorded only when a model was really called: a ladder held back by the daily ceiling or by the
# deadline has not failed on it
echo "skipped-ladder tree" >>"$LR/README.md"; : >"$NOFIX_CALLS"
out=$(AGENT_TERMINAL_TEST_LADDER_DAILY=0 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-try" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$LR" sess-NOREC)
assert_eq "daily ceiling 0: no model call" "0" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
out=$(STOP_CHECK_DEADLINE=20 lstop sess-NOREC)
assert_eq "deadline too near: no model call" "0" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
out=$(lstop sess-NOREC)
assert_eq "a tree no model was called on is not recorded: the ladder runs on it later" "2" "$(wc -l <"$NOFIX_CALLS" | tr -d ' ')"
git -C "$LR" checkout -q README.md; rm -f "$LR/attempt.txt"

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
# TIMEOUT=0 would mean no limit: it behaves like 1 second. (A non-number falls back to 600 s, which
# cannot be observed without a 600 s test, so only the zero case is tested.)
write_goal "$R" "sleep 3; exit 1"
out=$(STOP_CHECK_TIMEOUT=0 stop "$R" sess-TMOZERO)
assert_contains "TIMEOUT=0 behaves like 1: timed out after 1s" "$(printf '%s' "$out" | jq -r .reason)" "timed out after 1s"
# F4: a timed-out test_command is killed with its whole process group, not only the top bash. The forked
# sleeper ignores TERM, so only the KILL that follows reaches it.
cat >"$WORK/forker.sh" <<'EOS'
#!/usr/bin/env bash
( trap '' TERM; exec sleep 300 ) &
echo "$!" >"$1"
wait
EOS
gone() { # pid : 0 when the process is gone within 3 s
  local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do kill -0 "$1" 2>/dev/null || return 0; sleep 0.2; done; return 1
}
PGF="$WORK/pg-sleeper"; rm -f "$PGF"
write_goal "$R" "bash $WORK/forker.sh $PGF"
out=$(STOP_CHECK_TIMEOUT=1 stop "$R" sess-PGKILL)
assert_contains "process group: the timeout still blocks with timed out" "$(printf '%s' "$out" | jq -r .reason)" "timed out after 1s"
pg_pid=$(cat "$PGF" 2>/dev/null || echo 0)
if [ "$pg_pid" -gt 0 ] && gone "$pg_pid"; then pass "process group: the forked sleeper is gone"; else fail "process group: the forked sleeper is gone" "  pid $pg_pid still alive"; fi
[ "$pg_pid" -gt 0 ] && kill -9 "$pg_pid" 2>/dev/null
# A TERM to the hook itself (what Claude Code sends on its hook timeout or on Esc) takes the whole check down:
# test-escalate.sh, the test run and everything it forked. The hook ends as a no verdict.
cat >"$WORK/slowcheck.sh" <<'EOS'
#!/usr/bin/env bash
echo "$$" >"$1.bash"
sleep 97 &
echo "$!" >"$1"
wait
EOS
TP="$WORK/term-pids"; rm -f "$TP" "$TP.bash"
write_goal "$R" "bash $WORK/slowcheck.sh $TP"
hook_json Stop "$R" sess-TERM '{"stop_hook_active":false}' >"$WORK/term.json"
"$BIN/stop-check.sh" <"$WORK/term.json" >"$WORK/term.out" 2>"$WORK/term.err" &
hp=$!
for i in $(seq 1 50); do [ -s "$TP" ] && break; sleep 0.1; done
s=$(date +%s); kill -TERM "$hp"; rc=0; wait "$hp" || rc=$?; e=$(date +%s)
assert_eq "TERM to the hook: it ends within 3 s" "1" "$([ $((e - s)) -le 3 ] && echo 1 || echo 0)"
assert_eq "TERM to the hook: no verdict (exit 3)" "3" "$rc"
assert_eq "TERM to the hook: no block" "" "$(cat "$WORK/term.out")"
assert_contains "TERM to the hook: stderr says it was interrupted" "$(cat "$WORK/term.err")" "interrupted"
for f in "$TP" "$TP.bash"; do
  p=$(cat "$f" 2>/dev/null || echo 0)
  if [ "$p" -gt 0 ] && gone "$p"; then pass "TERM to the hook: $(basename "$f") process is gone"; else fail "TERM to the hook: $(basename "$f") process is gone" "  pid $p"; fi
  [ "$p" -gt 0 ] && kill -9 "$p" 2>/dev/null
done

# F3: one deadline for the whole hook (STOP_CHECK_DEADLINE, default 780 s, under the 900 s hook timeout).
# A check cut off at the deadline has no verdict: the model is not told to fix anything. The stop is allowed
# (exit 3, "out of time" on stderr), stop_deadline is logged, the user is notified once, no retry is counted.
write_goal "$R" "sleep 30"
: >"$AGENT_HOME/notify.log"
s=$(date +%s); rc=0
out=$(printf '%s' "$(hook_json Stop "$R" sess-DEADLINE '{"stop_hook_active":false}')" | STOP_CHECK_DEADLINE=2 STOP_CHECK_TIMEOUT=900 "$BIN/stop-check.sh" 2>"$WORK/dl.err") || rc=$?
e=$(date +%s)
assert_eq "deadline: the hook ends near its deadline, not after the 30 s check (even with STOP_CHECK_TIMEOUT=900)" "1" "$([ $((e - s)) -le 6 ] && echo 1 || echo 0)"
assert_eq "deadline: no block (a check with no result is no verdict)" "" "$out"
assert_eq "deadline: exit 3 (no verdict, stop allowed)" "3" "$rc"
assert_contains "deadline: stderr says the hook ran out of time" "$(cat "$WORK/dl.err")" "out of time"
assert_eq "deadline: a stop_deadline event is logged" "2" "$(jq -r 'select(.kind=="stop_deadline" and .sid=="sess-DEADLINE") | .data.budget' "$AGENT_HOME/events.jsonl")"
assert_eq "deadline: no stop_blocked event" "" "$(jq -r 'select(.kind=="stop_blocked" and .sid=="sess-DEADLINE") | .sid' "$AGENT_HOME/events.jsonl")"
assert_no_file "deadline: no retry counted" "$AGENT_HOME/sessions/sess-DEADLINE/retries"
assert_eq "deadline: the user is notified once" "1" "$(grep -c 'out of time' "$AGENT_HOME/notify.log")"
out=$(STOP_CHECK_DEADLINE=abc STOP_CHECK_TIMEOUT=1 stop "$R" sess-DEADLINE-BAD)
assert_contains "deadline: a non-number falls back to the default (the 1 s timeout applies)" "$(printf '%s' "$out" | jq -r .reason)" "timed out after 1s"
# the ladder only starts a model call when the budget leaves room for it and for the re-check after it
cat >"$WORK/fake-claude-count" <<'EOS'
#!/usr/bin/env bash
echo call >>"$COUNT_CALLS"
EOS
chmod +x "$WORK/fake-claude-count"
export COUNT_CALLS="$WORK/count-calls"; : >"$COUNT_CALLS"
write_goal "$R" "false"
out=$(STOP_CHECK_DEADLINE=20 AGENT_TERMINAL_TEST_LADDER_DAILY=100 AGENT_TERMINAL_CLAUDE_BIN="$WORK/fake-claude-count" AGENT_TERMINAL_TEST_MODELS="cheap strong" stop "$R" sess-DLLADDER)
assert_eq "deadline: too little budget left, no model call" "0" "$(wc -l <"$COUNT_CALLS" | tr -d ' ')"
assert_eq "deadline: the failing check still blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_contains "deadline: the ladder skip is in the escalation log" "$(cat "$AGENT_HOME/test-escalation.log")" "reason=deadline"

# ---------- events (Phase 1.5) ----------
EVF="$AGENT_HOME/events.jsonl"
assert_eq "events: three test blocks and one cap for sess-A" "4" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .kind' "$EVF" | wc -l | tr -d ' ')"
assert_contains "events: cap is marked" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .data.reason' "$EVF")" "tests-cap"
assert_contains "events: a green stop logs stop_ok" "$(jq -r 'select(.kind=="stop_ok") | .sid' "$EVF")" "sess-B"

# ---------- checkpoint rule (Phase 1.5) ----------
CR=$(mk_repo cprepo); write_goal "$CR" "true"
# a real checkpoint: all six keys filled (blocker: none and files_changed: 0 are real answers too)
good_block() { printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nresult: ok\nblocker: none\nnext_action: none\nfiles_changed: 1\nexamined: bin/x.sh\nnot_examined: nothing\n<!-- /ching:checkpoint -->\n' >"$1/.agent/STATE.md"; }
touch_prompt() { printf '%s' "$(hook_json UserPromptSubmit "$1" "$2")" | "$BIN/session-start.sh" touch; }
work() { echo "$2" >>"$1/work.txt"; }   # repo text : the turn changes the tree (the gate only asks after a change)
touch_prompt "$CR" cp-1; work "$CR" cp-1
out=$(stop "$CR" cp-1)
assert_eq "checkpoint missing: blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
r=$(printf '%s' "$out" | jq -r .reason)
assert_contains "checkpoint reason: asks only for the checkpoint block" "$r" "Edit only the six lines"
assert_contains "checkpoint reason: names the six keys" "$r" "result, blocker, next_action, files_changed, examined, not_examined"
assert_not_contains "checkpoint reason: no /handoff (a full handoff is not needed)" "$r" "/handoff"
out=$(stop "$CR" cp-1)
assert_eq "checkpoint still missing: asked one more time" "block" "$(printf '%s' "$out" | jq -r .decision)"
out=$(stop "$CR" cp-1)
assert_eq "checkpoint: asked at most twice per prompt" "" "$out"
# the first two cp-1 stops exited at a block, so the only stop_ok for cp-1 comes from the third reaching its normal end
assert_eq "checkpoint: the capped stop ran to the end (one stop_ok, not a dead hook)" "cp-1" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-1") | .sid' "$EVF")"
touch_prompt "$CR" cp-2
good_block "$CR"
out=$(stop "$CR" cp-2)
assert_eq "fresh checkpoint: no block" "" "$out"
assert_contains "fresh checkpoint: checkpoint event" "$(jq -r 'select(.kind=="checkpoint") | .sid' "$AGENT_HOME/events.jsonl")" "cp-2"
touch -t 202001010000 "$CR/.agent/STATE.md"
touch_prompt "$CR" cp-2; work "$CR" cp-2
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
touch_prompt "$CR" cp-5; work "$CR" cp-5
out=$(stop "$CR" cp-5)
assert_eq "block-then-comply: first stop blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_eq "block-then-comply: no checkpoint event yet" "" "$(jq -r 'select(.kind=="checkpoint" and .sid=="cp-5") | .sid' "$EVF")"
good_block "$CR"; sed -i.bak 's/^result: ok/result: wrote the checkpoint for cp-5/' "$CR/.agent/STATE.md"; rm -f "$CR/.agent/STATE.md.bak"
out=$(stop "$CR" cp-5)
assert_eq "block-then-comply: second stop passes" "" "$out"
assert_eq "block-then-comply: checkpoint event logged after the block" "cp-5" "$(jq -r 'select(.kind=="checkpoint" and .sid=="cp-5") | .sid' "$EVF")"
assert_eq "block-then-comply: second stop ran to the end (stop_ok logged)" "cp-5" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cp-5") | .sid' "$EVF")"
# a turn that changed nothing in the tree (a question answered, a plan explained) is not asked for a checkpoint
CU=$(mk_repo cpunchanged); write_goal "$CU" "true"
echo old >"$CU/old.txt"   # dirty, but from before the prompt
age_tree() { touch -t 202001010000 "$CU/.git/logs/HEAD" "$CU/old.txt" "$CU/README.md"; }
age_tree; touch_prompt "$CU" cu-1
out=$(stop "$CU" cu-1)
assert_eq "unchanged since the prompt: no checkpoint block" "" "$out"
assert_eq "unchanged since the prompt: stop ran to the end (stop_ok logged)" "cu-1" "$(jq -r 'select(.kind=="stop_ok" and .sid=="cu-1") | .sid' "$EVF")"
age_tree; touch_prompt "$CU" cu-2; echo edit >>"$CU/README.md"
out=$(stop "$CU" cu-2)
assert_eq "a tracked file edited after the prompt: blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
git -C "$CU" checkout -q README.md
age_tree; touch_prompt "$CU" cu-3; commit_file "$CU" new.txt x
out=$(stop "$CU" cu-3)
assert_eq "a commit after the prompt (clean tree): blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
age_tree; touch -t 202001010000 "$CU/new.txt"; touch_prompt "$CU" cu-4; rm "$CU/new.txt"
out=$(stop "$CU" cu-4)
assert_eq "a tracked file deleted after the prompt: blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
# scripted runs opt out: AGENT_TERMINAL_NO_CHECKPOINT=1, or a non-interactive Claude Code run (claude -p sets
# CLAUDE_CODE_ENTRYPOINT=sdk-cli; the Agent SDK sets sdk-ts / sdk-py)
touch_prompt "$CR" cp-6; work "$CR" cp-6
out=$(AGENT_TERMINAL_NO_CHECKPOINT=1 stop "$CR" cp-6)
assert_eq "AGENT_TERMINAL_NO_CHECKPOINT=1: no checkpoint block" "" "$out"
touch_prompt "$CR" cp-7; work "$CR" cp-7
out=$(CLAUDE_CODE_ENTRYPOINT=sdk-cli stop "$CR" cp-7)
assert_eq "claude -p (CLAUDE_CODE_ENTRYPOINT=sdk-cli): no checkpoint block" "" "$out"
touch_prompt "$CR" cp-8; work "$CR" cp-8
out=$(CLAUDE_CODE_ENTRYPOINT=cli stop "$CR" cp-8)
assert_eq "interactive claude (CLAUDE_CODE_ENTRYPOINT=cli): still asked" "block" "$(printf '%s' "$out" | jq -r .decision)"
# the gate looks at the tree as it was before the test run: files the check itself writes are not the turn's work
git -C "$CU" checkout -q new.txt
write_goal "$CU" "echo gen >$CU/gen-by-test.out"
age_tree; touch -t 202001010000 "$CU/new.txt"; touch_prompt "$CU" cu-5
out=$(stop "$CU" cu-5)
assert_eq "a check that writes into the tree does not make the turn look changed" "" "$out"
assert_file "the check did write into the tree" "$CU/gen-by-test.out"
# ---------- the checkpoint has to be real (lens finding F7) ----------
# A touch of STATE.md used to satisfy the gate (the template already holds the marker). The block must now be valid:
# the six keys present, none empty, result/next_action/examined/not_examined not the template's "(none)". After a
# block, the next stop passes only when the block changed since the block was asked for AND is valid; otherwise it is
# asked once more, and the stop after that is allowed with a checkpoint_unmet event. Never more than two blocks.
cp_blocks() { jq -r --arg s "$1" 'select(.kind=="stop_blocked" and .sid==$s and .data.reason=="checkpoint") | .data.retry' "$EVF" | tr '\n' ' '; }
cp_unmet() { jq -r --arg s "$1" 'select(.kind=="checkpoint_unmet" and .sid==$s) | .data.reason' "$EVF" | tr '\n' ' '; }
cp_ok() { jq -r --arg s "$1" 'select(.kind=="checkpoint" and .sid==$s) | .sid' "$EVF" | head -1; }
cp_decision() { if [ -z "$1" ]; then echo allow; else printf '%s' "$1" | jq -r '.decision // "allow"' 2>/dev/null || echo garbage; fi; }
use_template() { cp "$KIT/templates/STATE.md" "$1/.agent/STATE.md"; }
CF=$(mk_repo cpfill); write_goal "$CF" "true"
# placeholders only: the template touched (fresh mtime, marker present) is not a checkpoint
touch_prompt "$CF" f7-a; work "$CF" f7-a; use_template "$CF"
out=$(stop "$CF" f7-a)
assert_eq "placeholder-only block, first stop: blocks" "block" "$(cp_decision "$out")"
assert_contains "placeholder-only block: the reason names the unfilled keys" "$(printf '%s' "$out" | jq -r .reason)" "result"
out=$(stop "$CF" f7-a)
assert_eq "placeholder-only block, second stop: asked once more" "block" "$(cp_decision "$out")"
assert_contains "second ask says it is the last" "$(printf '%s' "$out" | jq -r .reason)" "last time"
out=$(stop "$CF" f7-a)
assert_eq "placeholder-only block, third stop: allowed (the cap)" "" "$out"
assert_eq "placeholder-only: exactly two checkpoint blocks, never a loop" "1 2 " "$(cp_blocks f7-a)"
assert_eq "placeholder-only: checkpoint_unmet logged with the reason" "invalid " "$(cp_unmet f7-a)"
assert_eq "placeholder-only: no checkpoint event" "" "$(cp_ok f7-a)"
assert_eq "placeholder-only: the capped stop ran to its end (stop_ok)" "f7-a" "$(jq -r 'select(.kind=="stop_ok" and .sid=="f7-a") | .sid' "$EVF")"
out=$(stop "$CF" f7-a)
assert_eq "after the cap, later stops of the same prompt stay allowed" "" "$out"
assert_eq "after the cap: still two blocks in all" "1 2 " "$(cp_blocks f7-a)"
# an unchanged block after the block is not enough, a touch of the file or an edit outside the block neither
touch_prompt "$CF" f7-b; work "$CF" f7-b; good_block "$CF"; touch -t 202001010000 "$CF/.agent/STATE.md"
out=$(stop "$CF" f7-b)
assert_eq "valid block older than the prompt: blocks" "block" "$(cp_decision "$out")"
touch "$CF/.agent/STATE.md"
out=$(stop "$CF" f7-b)
assert_eq "same block, file only touched: asked once more" "block" "$(cp_decision "$out")"
assert_contains "unchanged block: the reason says so" "$(printf '%s' "$out" | jq -r .reason)" "unchanged"
printf '\n## Done\n- worked\n' >>"$CF/.agent/STATE.md"
out=$(stop "$CF" f7-b)
assert_eq "same block, an edit outside the block: allowed (the cap)" "" "$out"
assert_eq "unchanged: checkpoint_unmet logged with the reason" "unchanged " "$(cp_unmet f7-b)"
assert_eq "unchanged: two blocks, no checkpoint event" "1 2 :" "$(cp_blocks f7-b):$(cp_ok f7-b)"
# a real block after the first block passes at once, and the checkpoint event carries its values
touch_prompt "$CF" f7-c; work "$CF" f7-c; use_template "$CF"
out=$(stop "$CF" f7-c)
assert_eq "template, then a real block: first stop blocks" "block" "$(cp_decision "$out")"
good_block "$CF"
out=$(stop "$CF" f7-c)
assert_eq "template, then a real block: the next stop passes" "" "$out"
assert_eq "template, then a real block: one block only" "1 " "$(cp_blocks f7-c)"
assert_eq "template, then a real block: checkpoint event logged" "f7-c" "$(cp_ok f7-c)"
assert_eq "template, then a real block: no checkpoint_unmet" "" "$(cp_unmet f7-c)"
assert_eq "the checkpoint event carries the block's values" "none|none" "$(jq -r 'select(.kind=="checkpoint" and .sid=="f7-c") | "\(.data.blocker)|\(.data.next_action)"' "$EVF")"
# a real block written before any block is not asked for again
touch_prompt "$CF" f7-d; work "$CF" f7-d; good_block "$CF"
out=$(stop "$CF" f7-d)
assert_eq "real block written unprompted: no block" "" "$out"
assert_eq "real block written unprompted: no block event, a checkpoint event" ":f7-d" "$(cp_blocks f7-d):$(cp_ok f7-d)"
# blocker: none and files_changed: 0 are real answers; the placeholder is (none) in the other four
touch_prompt "$CF" f7-e; work "$CF" f7-e
printf '# State\n<!-- ching:checkpoint -->\nresult: fixed the parser\nblocker: none\nnext_action: review the PR\nfiles_changed: 0\nexamined: the failing test\nnot_examined: the live site\n<!-- /ching:checkpoint -->\n' >"$CF/.agent/STATE.md"
out=$(stop "$CF" f7-e)
assert_eq "blocker none and files_changed 0 are accepted" "" "$out"
# each way to be invalid: a missing key, an empty value, a value that is still (none)
break_block() { # key how: spoil that key of the good block
  case "$2" in
    missing) sed -i.bak "/^$1:/d" "$CF/.agent/STATE.md" ;;
    empty) sed -i.bak "s/^$1:.*/$1:   /" "$CF/.agent/STATE.md" ;;
    none) sed -i.bak "s/^$1:.*/$1: (none)/" "$CF/.agent/STATE.md" ;;
    None) sed -i.bak "s/^$1:.*/$1: (None)/" "$CF/.agent/STATE.md" ;;
  esac
  rm -f "$CF/.agent/STATE.md.bak"
}
for spec in files_changed:missing blocker:missing examined:empty result:empty result:none next_action:None examined:none not_examined:none; do
  key=${spec%%:*}; how=${spec#*:}
  touch_prompt "$CF" "f7-$key-$how"; work "$CF" "f7-$key-$how"; good_block "$CF"; break_block "$key" "$how"
  out=$(stop "$CF" "f7-$key-$how")
  assert_eq "invalid block ($key $how): blocks" "block" "$(cp_decision "$out")"
  assert_contains "invalid block ($key $how): the reason names the key" "$(printf '%s' "$out" | jq -r .reason)" "$key"
  good_block "$CF"
  out=$(stop "$CF" "f7-$key-$how")
  assert_eq "invalid block ($key $how), then filled in: passes" "" "$out"
done
touch_prompt "$CF" f7-old; work "$CF" f7-old
printf '# State\n<!-- ching:checkpoint -->\nresult: ok\nblocker: none\nnext_action: none\n<!-- /ching:checkpoint -->\n' >"$CF/.agent/STATE.md"
out=$(stop "$CF" f7-old)
assert_eq "the old three-key block is not a checkpoint any more" "block" "$(cp_decision "$out")"
assert_contains "three-key block: the reason names the missing keys" "$(printf '%s' "$out" | jq -r .reason)" "files_changed"
# invalid after the block, then fixed on the second ask: passes (the second ask is a real chance)
touch_prompt "$CF" f7-f; work "$CF" f7-f; use_template "$CF"
stop "$CF" f7-f >/dev/null
printf '# State\n<!-- ching:checkpoint -->\nresult: half done\nblocker: none\n<!-- /ching:checkpoint -->\n' >"$CF/.agent/STATE.md"
out=$(stop "$CF" f7-f)
assert_eq "changed but invalid: asked once more" "block" "$(cp_decision "$out")"
good_block "$CF"
out=$(stop "$CF" f7-f)
assert_eq "fixed on the second ask: passes" "" "$out"
assert_eq "fixed on the second ask: two blocks, a checkpoint event, no unmet" "1 2 :f7-f:" "$(cp_blocks f7-f):$(cp_ok f7-f):$(cp_unmet f7-f)"
# the hook JSON from a real session has stop_hook_active true on the stops after a block: same behaviour, same cap
touch_prompt "$CF" f7-g; work "$CF" f7-g; use_template "$CF"
stop_active() { run_hook stop-check.sh "$(hook_json Stop "$1" "$2" '{"stop_hook_active":true,"last_assistant_message":"x"}')"; }
out1=$(stop_active "$CF" f7-g); out2=$(stop_active "$CF" f7-g); out3=$(stop_active "$CF" f7-g)
assert_eq "stop_hook_active true: block, block, allow" "block block allow" "$(cp_decision "$out1") $(cp_decision "$out2") $(cp_decision "$out3")"
# opt-outs: placeholders are fine for scripted runs, before and after a block
touch_prompt "$CF" f7-h; work "$CF" f7-h; use_template "$CF"
out=$(AGENT_TERMINAL_NO_CHECKPOINT=1 stop "$CF" f7-h)
assert_eq "AGENT_TERMINAL_NO_CHECKPOINT=1 with a placeholder block: allowed" "" "$out"
touch_prompt "$CF" f7-i; work "$CF" f7-i; use_template "$CF"
out=$(CLAUDE_CODE_ENTRYPOINT=sdk-ts stop "$CF" f7-i)
assert_eq "sdk entrypoint with a placeholder block: allowed" "" "$out"
touch_prompt "$CF" f7-j; work "$CF" f7-j; use_template "$CF"
stop "$CF" f7-j >/dev/null
out=$(AGENT_TERMINAL_NO_CHECKPOINT=1 stop "$CF" f7-j)
assert_eq "opt-out after the first block: allowed, no second block" "" "$out"
assert_eq "opt-outs: no checkpoint_unmet, no extra blocks" ":1 " "$(cp_unmet f7-j):$(cp_blocks f7-j)"
assert_eq "opt-outs: nothing blocked for h and i" "" "$(cp_blocks f7-h)$(cp_blocks f7-i)"
# a turn that changed nothing is not asked, even with a placeholder block
touch_prompt "$CF" f7-k; use_template "$CF"
git -C "$CF" status --porcelain >/dev/null
age_all() { touch -t 202001010000 "$CF/.git/logs/HEAD" "$CF/README.md" "$CF/work.txt" 2>/dev/null || true; }
age_all; touch_prompt "$CF" f7-k; touch -t 202001010000 "$CF/.agent/STATE.md"
out=$(stop "$CF" f7-k)
assert_eq "nothing changed in the tree: no checkpoint ask" "" "$out"
# a new prompt starts the count again
sleep 1
touch_prompt "$CF" f7-a; work "$CF" f7-a; use_template "$CF"
out=$(stop "$CF" f7-a)
assert_eq "a later prompt of the same session is asked again" "block" "$(cp_decision "$out")"
assert_eq "a later prompt: the block count restarts at 1" "1 2 1 " "$(cp_blocks f7-a)"

# ---------- no verdict (F5, F9) ----------
# When the hook cannot do its own bookkeeping it has no verdict: it allows the stop, says why on stderr,
# exits 3 (a non-blocking hook error, so Claude Code shows the message) and logs stop_no_verdict when it can.
# It never blocks with a misleading "done-check failed".
stopx() { # cwd sid : run the hook with stdout in $WORK/nv.out, stderr in $WORK/nv.err; print the exit code
  local rc=0
  printf '%s' "$(hook_json Stop "$1" "$2" '{"stop_hook_active":false,"last_assistant_message":"x"}')" \
    | "$BIN/stop-check.sh" >"$WORK/nv.out" 2>"$WORK/nv.err" || rc=$?
  echo "$rc"
}
nv_event() { jq -r --arg s "$1" 'select(.kind=="stop_no_verdict" and .sid==$s) | .data.reason' "$EVF" 2>/dev/null; }
NV=$(mk_repo nvrepo); write_goal "$NV" "false"
mkdir -p "$AGENT_HOME/sessions"; chmod 500 "$AGENT_HOME/sessions"
rc=$(stopx "$NV" nv-1)
chmod 700 "$AGENT_HOME/sessions"
assert_eq "unwritable sessions dir: exit 3 (no verdict)" "3" "$rc"
assert_eq "unwritable sessions dir: no block" "" "$(cat "$WORK/nv.out")"
assert_contains "unwritable sessions dir: stderr says no verdict" "$(cat "$WORK/nv.err")" "no verdict"
assert_contains "unwritable sessions dir: stderr names the session dir" "$(cat "$WORK/nv.err")" "$AGENT_HOME/sessions/nv-1"
assert_contains "unwritable sessions dir: stop_no_verdict event" "$(nv_event nv-1)" "session record"
ROH="$WORK/ro-agent-home"; mkdir -p "$ROH"; chmod 500 "$ROH"
rc=$(AGENT_HOME="$ROH" stopx "$NV" nv-2)
chmod 700 "$ROH"
assert_eq "unwritable AGENT_HOME: exit 3 (no verdict)" "3" "$rc"
assert_eq "unwritable AGENT_HOME: no block" "" "$(cat "$WORK/nv.out")"
assert_contains "unwritable AGENT_HOME: stderr says no verdict" "$(cat "$WORK/nv.err")" "no verdict"
# a read-only escalation log costs log lines, never the verdict: a green check is still green
write_goal "$NV" "true"
touch "$AGENT_HOME/test-escalation.log"; chmod 400 "$AGENT_HOME/test-escalation.log"
rc=$(stopx "$NV" nv-3)
assert_eq "read-only escalation log, green check: allowed normally (exit 0)" "0" "$rc"
assert_eq "read-only escalation log, green check: no false block" "" "$(cat "$WORK/nv.out")"
write_goal "$NV" "exit 4"
rc=$(stopx "$NV" nv-3b)
chmod 600 "$AGENT_HOME/test-escalation.log"
assert_contains "read-only escalation log, red check: blocks with the check's own exit code" "$(jq -r .reason "$WORK/nv.out")" "exit code 4"
# a cwd that was deleted: the check cannot run there
mkdir -p "$AGENT_HOME/defaults" "$WORK/gone-dir"
printf 'test_command: true\n' >"$AGENT_HOME/defaults/GOAL.md"
rmdir "$WORK/gone-dir"
rc=$(stopx "$WORK/gone-dir" nv-4)
rm -rf "$AGENT_HOME/defaults"
assert_eq "deleted cwd: exit 3 (no verdict)" "3" "$rc"
assert_eq "deleted cwd: no block" "" "$(cat "$WORK/nv.out")"
assert_contains "deleted cwd: stderr says the folder is gone" "$(cat "$WORK/nv.err")" "no longer exists"
assert_contains "deleted cwd: stop_no_verdict event" "$(nv_event nv-4)" "no longer exists"
# any other failure of the hook itself (here: the retry counter is a directory) is a no verdict too
write_goal "$NV" "false"
mkdir -p "$AGENT_HOME/sessions/nv-6/retries"
rc=$(stopx "$NV" nv-6)
assert_eq "unexpected hook failure: exit 3 (no verdict)" "3" "$rc"
assert_eq "unexpected hook failure: no block" "" "$(cat "$WORK/nv.out")"
assert_contains "unexpected hook failure: stderr says no verdict" "$(cat "$WORK/nv.err")" "no verdict (unexpected failure"
assert_contains "unexpected hook failure: stop_no_verdict event" "$(nv_event nv-6)" "unexpected failure"
# F9: jq missing from the hook PATH: loud, and no shared nosession-<hash> record
NOJQ="$WORK/nojq-bin"; mkdir -p "$NOJQ"
ln -s /usr/bin/* "$NOJQ"/ 2>/dev/null; ln -s /bin/* "$NOJQ"/ 2>/dev/null; rm -f "$NOJQ/jq"
write_goal "$NV" "false"
J=$(hook_json Stop "$NV" nv-5 '{"stop_hook_active":false}')
rc=0; printf '%s' "$J" | PATH="$NOJQ" "$BIN/stop-check.sh" >"$WORK/nv.out" 2>"$WORK/nv.err" || rc=$?
assert_eq "no jq: exit 3 (no verdict)" "3" "$rc"
assert_eq "no jq: no block" "" "$(cat "$WORK/nv.out")"
assert_contains "no jq: stderr names jq" "$(cat "$WORK/nv.err")" "jq is not on the hook PATH"
assert_eq "no jq: no shared nosession-<hash> record" "" "$(ls "$AGENT_HOME/sessions" | grep '^nosession-' || true)"

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
# ---------- the learner's own model calls (AGENT_TERMINAL_LEARNER=1): no check, no gate, no notification ----------
LRS=$(mk_repo learnstop); write_goal "$LRS" "false"
out=$(AGENT_TERMINAL_LEARNER=1 "$BIN/stop-check.sh" 2>&1 <<<"$(hook_json Stop "$LRS" s-learner)"); rc=$?
assert_eq "learner: exit 0" "0" "$rc"
assert_eq "learner: never blocks (a failing test_command is not run)" "" "$out"
assert_no_file "learner: no session dir" "$AGENT_HOME/sessions/s-learner"
assert_eq "learner: no notify.log line" "0" "$(grep -c 'learnstop' "$AGENT_HOME/notify.log" 2>/dev/null || true)"
assert_eq "learner: no events" "0" "$(grep -c '"s-learner"' "$AGENT_HOME/events.jsonl" 2>/dev/null || true)"
exit 0
