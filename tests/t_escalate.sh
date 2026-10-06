#!/usr/bin/env bash
# test-escalate.sh: no model when green; cheapest model first; escalate only on failure; notify at the end.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R="$WORK/proj"; mkdir -p "$R"
# fake claude: records the --model it was called with; "fixes" the project when its model is in $FIXERS
cat >"$WORK/fake-claude" <<'EOS'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do [ "$1" = --model ] && m=$2; shift; done
echo "$m" >>"$CALLS"
echo "${CHING_ESCALATING:-unset}" >>"${ENVS:-/dev/null}"
case " $FIXERS " in *" $m "*) touch "$PROJ/fixed" ;; esac
EOS
chmod +x "$WORK/fake-claude"
export CHING_CLAUDE_BIN="$WORK/fake-claude" CALLS="$WORK/calls" PROJ="$R" CHING_TEST_LOG="$WORK/esc.log"
export CHING_TEST_MODELS="cheap strong"
T=(test -f "$R/fixed")

: >"$CALLS"; touch "$R/fixed"
assert_ok "green tests: exit 0" "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}"
assert_eq "green tests: no model called" "0" "$(wc -l <"$CALLS" | tr -d ' ')"

: >"$CALLS"; rm "$R/fixed"; export FIXERS="cheap"
assert_ok "cheap model fixes it: exit 0" "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}"
assert_eq "cheap model fixes it: only cheap called" "cheap" "$(tr '\n' ' ' <"$CALLS" | sed 's/ $//')"

: >"$CALLS"; rm -f "$R/fixed"; export FIXERS="strong"
assert_ok "escalates to strong model: exit 0" "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}"
assert_eq "escalation order cheap then strong" "cheap strong" "$(tr '\n' ' ' <"$CALLS" | sed 's/ $//')"

: >"$CALLS"; rm -f "$R/fixed"; export FIXERS=""
assert_fails "nobody fixes it: exit non-zero" "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}"
assert_contains "blocked is logged" "$(cat "$CHING_TEST_LOG")" "blocked"

unset CHING_TEST_MODELS
out=$(grep -c 'claude-haiku-4-5-20251001 claude-sonnet-5-5' "$BIN/test-escalate.sh")
assert_eq "default ladder is haiku-4-5 then sonnet-5-5" "1" "$([ "$out" -ge 1 ] && echo 1 || echo 0)"

# ---------- recursion guard ----------
# A model started by test-escalate.sh loads the same Stop hook. Without a guard that hook would run
# test-escalate.sh again and start more models, without end. Children get CHING_ESCALATING=1.
export CHING_TEST_MODELS="cheap strong" ENVS="$WORK/envs"
: >"$ENVS"; : >"$CALLS"; rm -f "$R/fixed"; export FIXERS="cheap"
"$BIN/test-escalate.sh" -C "$R" -- "${T[@]}" >/dev/null 2>&1 || true
assert_eq "child model is started with CHING_ESCALATING=1" "1" "$(head -1 "$ENVS")"

: >"$CALLS"; rm -f "$R/fixed"; export FIXERS="cheap strong"
out=$(CHING_ESCALATING=1 "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}" 2>&1); rc=$?
assert_eq "inside an escalation: no model is started" "0" "$(wc -l <"$CALLS" | tr -d ' ')"
assert_eq "inside an escalation: the failing tests still fail" "1" "$([ "$rc" -ne 0 ] && echo 1 || echo 0)"

# ---------- daily ceiling on paid model calls ----------
# Every `claude` call started here is counted in $AGENT_HOME/ladder/<UTC day>, across all sessions and repos;
# CHING_TEST_LADDER_DAILY (default 6, 0 = no model at all) is the most calls per day. Checked per call.
LD="$AGENT_HOME/ladder"; DAY=$(date -u +%Y-%m-%d)
export FIXERS=""   # nobody fixes it: every failing run goes down the whole ladder
ladder_run() { # limit : one failing run, exit code ignored
  CHING_TEST_LADDER_DAILY=$1 "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}" >/dev/null 2>&1 || true
}
ncalls() { wc -l <"$CALLS" | tr -d ' '; }

# limit 3, two failing runs of a 2-model ladder: exactly 3 calls (the cap is per call: run 2 gets 1 of its 2)
rm -rf "$LD"; : >"$CALLS"; rm -f "$R/fixed"
ladder_run 3
assert_eq "limit 3: first run uses the whole ladder (2 calls)" "2" "$(ncalls)"
ladder_run 3
assert_eq "limit 3: second run gets the 1 call that is left, not 2" "3" "$(ncalls)"
assert_eq "limit 3: the calls were cheap, strong, cheap" "cheap strong cheap" "$(tr '\n' ' ' <"$CALLS" | sed 's/ $//')"
assert_eq "limit 3: the counter file holds 3" "3" "$(cat "$LD/$DAY")"
out=$(CHING_TEST_LADDER_DAILY=3 "$BIN/test-escalate.sh" -C "$R" -- "${T[@]}" 2>&1); rc=$?
assert_eq "limit reached: no further model call" "3" "$(ncalls)"
assert_eq "limit reached: exit code is the tests' exit code" "1" "$rc"
assert_contains "limit reached: same output as with no models" "$out" "tests still fail (models tried: none)"
assert_not_contains "limit reached: no 'asking' line" "$out" "asking"
assert_contains "limit reached: ladder-cap logged with date, count and limit" "$(cat "$CHING_TEST_LOG")" "ladder-cap date=$DAY count=3 limit=3"
assert_eq "limit reached: a ladder_cap event is logged" "3" "$(jq -r 'select(.kind=="ladder_cap") | .data.limit' "$AGENT_HOME/events.jsonl" | tail -1)"

# limit 0: the ladder is off
rm -rf "$LD"; : >"$CALLS"
ladder_run 0
assert_eq "limit 0: no model call" "0" "$(ncalls)"
assert_no_file "limit 0: nothing counted" "$LD/$DAY"

# a limit that is not digits falls back to the default 6
for bad in many -1 2.5 ""; do
  rm -rf "$LD"; : >"$CALLS"
  ladder_run "$bad"; ladder_run "$bad"; ladder_run "$bad"; ladder_run "$bad"
  assert_eq "limit '$bad' behaves like 6: 4 runs of 2 models make 6 calls" "6" "$(ncalls)"
done

# the day is the UTC day, not the local one (the zones are 14 h ahead of and 11 h behind UTC)
rm -rf "$LD"; : >"$CALLS"
TZ=Pacific/Kiritimati ladder_run 6
TZ=Pacific/Pago_Pago ladder_run 6
assert_eq "counter file is named by the UTC day" "$DAY" "$(ls "$LD")"
assert_eq "counter file counts across both time zones" "4" "$(cat "$LD/$DAY")"

# a garbage, empty or unreadable counter counts as 0 and never crashes or blocks
for junk in "not a number" "-3" "12abc"; do
  rm -rf "$LD"; mkdir -p "$LD"; printf '%s\n' "$junk" >"$LD/$DAY"; : >"$CALLS"
  ladder_run 6
  assert_eq "garbage counter '$junk' counts as 0: the ladder runs" "2" "$(ncalls)"
  assert_eq "garbage counter '$junk' is replaced by a real count" "2" "$(cat "$LD/$DAY")"
done
rm -rf "$LD"; mkdir -p "$LD"; : >"$LD/$DAY"; : >"$CALLS"
ladder_run 6
assert_eq "empty counter file counts as 0: the ladder runs" "2" "$(ncalls)"
printf '5\n' >"$LD/$DAY"; chmod 000 "$LD/$DAY"; : >"$CALLS"
ladder_run 6
assert_eq "unreadable counter file counts as 0: the ladder runs" "2" "$(ncalls)"
chmod 600 "$LD/$DAY" 2>/dev/null || true

# an unwritable counter must not stop the tests, but spends nothing: no call can be counted, so none is made
RUNS="$WORK/esc-runs"; TC=(bash -c "echo run >>$RUNS; exit 3")
rm -rf "$LD"; mkdir -p "$LD"; chmod 500 "$LD"; : >"$CALLS"; : >"$RUNS"
out=$(CHING_TEST_LADDER_DAILY=6 "$BIN/test-escalate.sh" -C "$R" -- "${TC[@]}" 2>&1); rc=$?
chmod 700 "$LD"
assert_eq "read-only ladder dir: no model call" "0" "$(ncalls)"
assert_eq "read-only ladder dir: the tests still ran" "1" "$(wc -l <"$RUNS" | tr -d ' ')"
assert_eq "read-only ladder dir: exit code is the tests' exit code" "3" "$rc"
assert_contains "read-only ladder dir: reports the failure" "$out" "tests still fail"
rm -rf "$LD"; : >"$LD"; : >"$CALLS"; : >"$RUNS"
out=$(CHING_TEST_LADDER_DAILY=6 "$BIN/test-escalate.sh" -C "$R" -- "${TC[@]}" 2>&1); rc=$?
assert_eq "ladder dir is a file: no model call" "0" "$(ncalls)"
assert_eq "ladder dir is a file: the tests still ran, exit code kept" "1 3" "$(wc -l <"$RUNS" | tr -d ' ') $rc"
rm -f "$LD"; mkdir -p "$LD/$DAY"; : >"$CALLS"
ladder_run 6
assert_eq "counter path is a directory (cannot be counted): no model call" "0" "$(ncalls)"
rm -rf "$LD"

# green tests stay free: no model, and the counter is not even created
touch "$R/fixed"; : >"$CALLS"
ladder_run 6
assert_eq "green tests: no model call" "0" "$(ncalls)"
assert_no_file "green tests: the counter is not created" "$LD"
exit 0
