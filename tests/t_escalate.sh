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
