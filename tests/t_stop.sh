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
exit 0
