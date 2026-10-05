#!/usr/bin/env bash
# lib.sh contracts: ev (append-only event log) and checkpoint_get (STATE.md checkpoint block).
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
EVF="$AGENT_HOME/events.jsonl"

SID=s1; NAME=demo; CWD=/tmp/demo
ev prompt
line=$(tail -1 "$EVF")
assert_eq "ev: kind" "prompt" "$(printf '%s' "$line" | jq -r .kind)"
assert_eq "ev: sid" "s1" "$(printf '%s' "$line" | jq -r .sid)"
assert_eq "ev: name" "demo" "$(printf '%s' "$line" | jq -r .name)"
assert_eq "ev: cwd" "/tmp/demo" "$(printf '%s' "$line" | jq -r .cwd)"
assert_eq "ev: empty data is {}" "{}" "$(printf '%s' "$line" | jq -c .data)"
assert_contains "ev: ISO UTC timestamp" "$(printf '%s' "$line" | jq -r .ts)" "Z"
assert_eq "ev: file is private (0600)" "600" "$(stat -f %Lp "$EVF")"

ev stop_blocked '{"retry":2,"reason":"tests"}'
assert_eq "ev: data kept" "2" "$(tail -1 "$EVF" | jq -r .data.retry)"

long=$(printf 'x%.0s' $(seq 1 500))
ev notify "$(jq -nc --arg m "$long" '{msg:$m}')"
assert_eq "ev: strings cut to 300 chars" "300" "$(tail -1 "$EVF" | jq -r '.data.msg | length')"

ev notify "$(jq -nc --arg m "$long" '{a:$m,b:$m,c:$m,d:$m}')"
assert_eq "ev: line over 1 KB keeps only truncated:true" '{"truncated":true}' "$(tail -1 "$EVF" | jq -c .data)"

# Review Focus 5: quotes and newlines in cwd still give one valid JSON line
CWD=$'/tmp/we"ird\nfolder'
ev prompt
CWD=/tmp/demo
assert_eq "ev: every line is valid JSON (quotes/newline in cwd)" "$(wc -l <"$EVF" | tr -d ' ')" "$(jq -c . "$EVF" | wc -l | tr -d ' ')"
assert_contains "ev: the odd cwd survives" "$(jq -r 'select(.kind=="prompt") | .cwd' "$EVF")" 'we"ird'

n=$(wc -l <"$EVF")
out=$(ev bad 'not json' 2>&1); rc=$?
assert_eq "ev: bad data returns 0" "0" "$rc"
assert_eq "ev: bad data prints nothing" "" "$out"
assert_eq "ev: bad data writes nothing" "$n" "$(wc -l <"$EVF")"

touch "$WORK/afile"
out=$(AGENT_HOME="$WORK/afile/sub" ev prompt 2>&1); rc=$?
assert_eq "ev: unwritable log returns 0" "0" "$rc"
assert_eq "ev: unwritable log prints nothing" "" "$out"

S="$WORK/STATE.md"
cat >"$S" <<'EOS'
# State
status: working
blocker: not-in-block
<!-- ching:checkpoint -->
result: wired the widget
blocker: need the staging token
next_action: run the gate
not_examined: mobile layout
<!-- /ching:checkpoint -->
EOS
assert_eq "checkpoint_get: reads a key inside the block" "need the staging token" "$(checkpoint_get "$S" blocker)"
assert_eq "checkpoint_get: next_action" "run the gate" "$(checkpoint_get "$S" next_action)"
assert_eq "checkpoint_get: absent key is empty" "" "$(checkpoint_get "$S" files_changed)"
assert_eq "checkpoint_get: missing file is empty" "" "$(checkpoint_get "$WORK/nope.md" result)"
printf '# State\nblocker: outside\n' >"$WORK/S2.md"
assert_eq "checkpoint_get: ignores keys outside the block" "" "$(checkpoint_get "$WORK/S2.md" blocker)"
exit 0
