#!/usr/bin/env bash
# t_config.sh - lib.sh config_get / push_gate_on: the machine-level config file $AGENT_HOME/config.
. "$(dirname "$0")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

C=$AGENT_HOME/config
cfg() { printf '%b' "$1" >"$C"; }

rm -f "$C"
assert_eq "no file: default" "dflt" "$(config_get push_gate dflt)"
assert_eq "no file, no default: empty" "" "$(config_get push_gate)"
push_gate_on && fail "no file: gate is off" "  gate was on" || pass "no file: gate is off by default"

cfg 'push_gate=on\n'
assert_eq "plain value" "on" "$(config_get push_gate off)"
push_gate_on && pass "push_gate=on is on" || fail "push_gate=on is on" "  gate was off"
cfg '  push_gate  =  ON  \n'
push_gate_on && pass "blanks and case are ignored" || fail "blanks and case are ignored" "  gate was off"
cfg 'push_gate="on"\n'
push_gate_on && pass "double quotes are dropped" || fail "double quotes are dropped" "  gate was off"
cfg "push_gate='on'\n"
push_gate_on && pass "single quotes are dropped" || fail "single quotes are dropped" "  gate was off"
cfg 'push_gate=on # the owner asked\n'
push_gate_on && pass "trailing comment is dropped" || fail "trailing comment is dropped" "  gate was off"
cfg 'push_gate=on\npush_gate=off\n'
push_gate_on && fail "last assignment wins (off)" "  gate was on" || pass "last assignment wins (off)"
cfg 'push_gate=off\npush_gate=on\n'
push_gate_on && pass "last assignment wins (on)" || fail "last assignment wins (on)" "  gate was off"
cfg '# push_gate=on\n'
push_gate_on && fail "a commented line is ignored" "  gate was on" || pass "a commented line is ignored"
cfg 'push_gate=maybe\n'
push_gate_on && fail "garbage means off" "  gate was on" || pass "garbage means off"
cfg 'push_gate=\n'
push_gate_on && fail "empty means off" "  gate was on" || pass "empty means off"
cfg 'xpush_gate=on\n'
push_gate_on && fail "another key with the same ending is not it" "  gate was on" || pass "another key with the same ending is not it"
cfg 'other=1\npush_gate=on\nthird=3\n'
assert_eq "other keys are read too" "3" "$(config_get third)"
assert_eq "other keys do not leak" "1" "$(config_get other)"
cfg 'push_gate=on'
push_gate_on && pass "no trailing newline" || fail "no trailing newline" "  gate was off"
chmod 000 "$C"
push_gate_on && fail "unreadable file means off" "  gate was on" || pass "unreadable file means off"
chmod 600 "$C"; rm -f "$C"
exit 0
