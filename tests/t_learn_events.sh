#!/usr/bin/env bash
# t_learn_events.sh - the Phase 6 event extensions (spec 4.3): the checkpoint event carries not_examined and
# task_type (D26's fixed list), stop-check.sh logs a `tests` event {outcome, secs} for every run of the test
# command, the STATE.md template and /handoff offer the optional task_type line, and a stop-check-produced
# event reaches learn-report.sh's per-task-type table and blind-spot ledger with the field names it reads.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
EVF="$AGENT_HOME/events.jsonl"
TYPES="build fix research merge/sync ops/config writing data"
stop() { run_hook stop-check.sh "$(hook_json Stop "$1" "$2" '{"stop_hook_active":false,"last_assistant_message":"Done."}')"; }
touch_prompt() { printf '%s' "$(hook_json UserPromptSubmit "$1" "$2")" | "$BIN/session-start.sh" touch; }
tests_ev() { jq -c --arg s "$1" 'select(.kind=="tests" and .sid==$s) | .data' "$EVF"; }
ckpt_ev() { jq -c --arg s "$1" 'select(.kind=="checkpoint" and .sid==$s) | .data' "$EVF" | tail -1; }
block() { # repo task_type_line not_examined [blocker] [next_action]: a valid checkpoint block
  {
    printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nresult: ok\nblocker: %s\nnext_action: %s\n' "${4:-none}" "${5:-none}"
    printf 'files_changed: 1\nexamined: bin/x.sh\nnot_examined: %s\n' "$3"
    if [ -n "$2" ]; then printf '%s\n' "$2"; fi
    printf '<!-- /ching:checkpoint -->\n'
  } >"$1/.agent/STATE.md"
}

# ---------- templates ----------
ST="$KIT/templates/STATE.md"; HO="$KIT/commands/handoff.md"
assert_eq "STATE.md template: task_type parses, placeholder (none)" "(none)" "$(checkpoint_get "$ST" task_type)"
assert_contains "handoff: optional task_type line in the block" "$(cat "$HO")" "task_type: "
for t in $TYPES; do
  assert_contains "STATE.md template lists task type $t" "$(cat "$ST")" "$t"
  assert_contains "handoff lists task type $t" "$(cat "$HO")" "$t"
done
assert_eq "STATE.md template: the list is a comment, outside the block" "" \
  "$(awk '/<!-- ching:checkpoint -->/{c=1;next} /<!-- \/ching:checkpoint -->/{c=0} c && /<!--/' "$ST")"

# ---------- the tests event ----------
R=$(mk_repo evrepo)
OK="$WORK/ok"
write_goal "$R" "test -f $OK"
stop "$R" t-1 >/dev/null
assert_eq "failing run: one tests event, outcome fail" "fail" "$(tests_ev t-1 | jq -r .outcome)"
assert_eq "failing run: secs is a number" "number" "$(tests_ev t-1 | jq -r '.secs | type')"
assert_eq "failing run: only outcome and secs" '["outcome","secs"]' "$(tests_ev t-1 | jq -c 'keys')"
touch "$OK"
stop "$R" t-1 >/dev/null
assert_eq "then green: fail, pass in that order" "fail pass" "$(tests_ev t-1 | jq -r .outcome | tr '\n' ' ' | sed 's/ $//')"
assert_eq "tests event comes before stop_ok" "tests stop_ok" \
  "$(jq -r 'select(.sid=="t-1" and (.kind=="tests" or .kind=="stop_ok")) | .kind' "$EVF" | tail -2 | tr '\n' ' ' | sed 's/ $//')"
stop "$R" t-1 >/dev/null
assert_eq "unchanged tree (check skipped): no tests event" "2" "$(tests_ev t-1 | grep -c .)"
write_goal "$R" "sleep 1; true"
stop "$R" t-2 >/dev/null
assert_eq "secs measures the run" "true" "$(tests_ev t-2 | jq -r '.secs >= 1')"
write_goal "$R" "sleep 5"
STOP_CHECK_TIMEOUT=1 stop "$R" t-3 >/dev/null
assert_eq "a run cut by STOP_CHECK_TIMEOUT is a fail" "fail" "$(tests_ev t-3 | jq -r .outcome)"
STOP_CHECK_DEADLINE=1 stop "$R" t-4 >/dev/null 2>&1
assert_eq "cut off at the hook deadline (no verdict): no tests event" "" "$(tests_ev t-4)"
P="$WORK/plain"; mkdir -p "$P"
stop "$P" t-5 >/dev/null
assert_eq "no test_command: no tests event" "" "$(tests_ev t-5)"

# ---------- the checkpoint event ----------
C=$(mk_repo ckrepo); write_goal "$C" "true"
ck() { # sid task_type_line not_examined [blocker] [next_action] -> the checkpoint event data
  touch_prompt "$C" "$1"; echo "$1" >>"$C/work.txt"
  block "$C" "$2" "$3" "${4:-none}" "${5:-none}"
  stop "$C" "$1" >/dev/null
  ckpt_ev "$1"
}
d=$(ck c-1 "task_type: fix" "the live site; mobile layout")
assert_eq "checkpoint: not_examined carried" "the live site; mobile layout" "$(printf '%s' "$d" | jq -r .not_examined)"
assert_eq "checkpoint: task_type carried" "fix" "$(printf '%s' "$d" | jq -r .task_type)"
assert_eq "checkpoint: the old fields stay" "none|none" "$(printf '%s' "$d" | jq -r '"\(.blocker)|\(.next_action)"')"
assert_eq "task_type: case and blanks normalised" "merge/sync" "$(ck c-2 "task_type:   Merge/Sync  " x | jq -r .task_type)"
assert_eq "task_type: merge is merge/sync" "merge/sync" "$(ck c-3 "task_type: merge" x | jq -r .task_type)"
assert_eq "task_type: config is ops/config" "ops/config" "$(ck c-4 "task_type: config" x | jq -r .task_type)"
assert_eq "task_type: the template placeholder is left out" "null" "$(ck c-5 "task_type: (none)" x | jq -r .task_type)"
assert_eq "task_type: a value off the list is left out (the learner classifies)" "null" "$(ck c-6 "task_type: refactoring" x | jq -r .task_type)"
assert_eq "task_type: no line, no field" "null" "$(ck c-7 "" x | jq -r .task_type)"
assert_eq "no task_type line: the block still passes" "c-7" "$(jq -r 'select(.kind=="checkpoint" and .sid=="c-7") | .sid' "$EVF")"
for t in $TYPES; do
  assert_eq "task_type: $t accepted" "$t" "$(ck "c-t-${t%/*}" "task_type: $t" x | jq -r .task_type)"
done
# the cap: every string at most 300 characters, and a long block never makes ev drop the data (line > 1 KB)
item='checked item number abcdefghi-'                 # 30 characters
long=""; for i in $(seq 1 20); do long="$long${long:+; }$item$i"; done   # about 660 characters
words=$(printf 'w%.0s ' $(seq 1 300))
d=$(ck c-8 "task_type: data" "$long" "$words" "$words")
assert_eq "long block: the data is kept (not truncated:true)" "data" "$(printf '%s' "$d" | jq -r .task_type)"
ne=$(printf '%s' "$d" | jq -r .not_examined)
assert_eq "long not_examined: at most 300 characters" "true" "$([ "${#ne}" -le 300 ] && echo true || echo false)"
assert_eq "long not_examined: cut at an item boundary (no half item)" "$item" "$(printf '%s' "$ne" | awk -F'; ' '{print $NF}' | sed 's/[0-9]*$//')"
assert_contains "long not_examined: starts with the first item" "$ne" "${item}1; ${item}2"
assert_eq "long blocker and next_action: cut too" "true" "$(printf '%s' "$d" | jq -r '(.blocker | length) <= 300 and (.next_action | length) <= 300')"
# a long cwd as well: the whole line stays under ev's 1 KB
LC="$WORK/a-rather-long-folder-name-for-the-cap-check-0123456789/and-another-long-level-abcdefghijklmnopqrstuvwxyz"
mkdir -p "$(dirname "$LC")"; git clone -q "$C" "$LC"; write_goal "$LC" "true"
touch_prompt "$LC" c-9; echo x >>"$LC/work.txt"; block "$LC" "task_type: writing" "$long" "$words" "$words"
stop "$LC" c-9 >/dev/null
assert_eq "long block in a long cwd: the data is kept" "writing" "$(ckpt_ev c-9 | jq -r .task_type)"
assert_eq "long block in a long cwd: not_examined kept" "true" "$(ckpt_ev c-9 | jq -r '(.not_examined | length) > 100')"

# ---------- end to end: a stop-check-produced event through the report ----------
# The hook's events carry this sandbox's /tmp cwd, which every learner component drops (learn_event_ok), so
# the e2e copies them with only the cwd rewritten to a real-looking folder. The data is the hook's own.
E=$(mk_repo e2erepo); OK2="$WORK/ok2"; write_goal "$E" "test -f $OK2"
touch_prompt "$E" e2e-1; echo x >>"$E/work.txt"
stop "$E" e2e-1 >/dev/null                                    # tests fail: blocked, a tests fail event
touch "$OK2"; block "$E" "task_type: fix" "the Safari check; the iOS build"
stop "$E" e2e-1 >/dev/null                                    # green, checkpoint with task_type
assert_eq "e2e: the hook logged fail, pass and the checkpoint" "fail pass fix" \
  "$(jq -r 'select(.sid=="e2e-1") | if .kind=="tests" then .data.outcome elif .kind=="checkpoint" then .data.task_type else empty end' "$EVF" | tr '\n' ' ' | sed 's/ $//')"
H="$WORK/e2e-home"; mkdir -p "$H"
jq -c 'select(.sid=="e2e-1") | .cwd = "/Users/fixture/code/e2e"' "$EVF" >"$H/events.jsonl"
week=$(TZ=UTC date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(jq -r 'select(.kind=="tests") | .ts' "$H/events.jsonl" | head -1)" +%G-W%V)
AGENT_HOME="$H" CLAUDE_DIR="$WORK/e2e-claude" TZ=UTC "$BIN/learn-extract.sh" >/dev/null 2>"$WORK/e2e.err" || fail "e2e: extractor ran" "$(cat "$WORK/e2e.err")"
AGENT_HOME="$H" CLAUDE_DIR="$WORK/e2e-claude" TZ=UTC "$BIN/learn-report.sh" --week "$week" >/dev/null 2>>"$WORK/e2e.err" || fail "e2e: report ran" "$(cat "$WORK/e2e.err")"
rep=$(cat "$H/proposals/report-$week.md" 2>/dev/null)
assert_contains "e2e: per task type row (1 session, 1 retry, 2 runs, 1 failed, 0 first time, 0 min)" "$rep" "| fix | 1 | 1 | 2 | 1 | 0 | 0 |"
assert_not_contains "e2e: the tests events were seen" "$rep" "No tests events yet"
assert_contains "e2e: not_examined reaches the blind-spot ledger" "$rep" "| the Safari check | 1 | 1 | below the bar |"
exit 0
