#!/usr/bin/env bash
# test-escalate.sh [-C DIR] [-- TEST_COMMAND...]
# Run the tests; spend model tokens only when they fail, starting with the cheapest model.
#   0. run the test command with no model at all; pass -> exit 0
#   1. fail -> ask each model in the ladder, cheapest first, to fix it; re-run the tests after each try
#   2. a model's fix makes the tests pass -> stop (the stronger models are never called)
#   3. the whole ladder fails -> notify "blocked" (unless CHING_TEST_NOTIFY=0), exit with the tests' exit code
# Env: CHING_TEST_MODELS (default "claude-haiku-4-5-20251001 claude-sonnet-5-5", cheapest first)
#      CHING_TEST_BUDGET_USD (per model call, default 0.50) CHING_CLAUDE_BIN (default claude)
#      CHING_TEST_NOTIFY (1) CHING_TEST_LOG (default $AGENT_HOME/test-escalation.log) AGENT_HOME
#      CHING_TEST_LADDER_DAILY (default 6; digits only, 0 = no model at all): the most model calls this script
#      starts per UTC day on the whole machine. The count is $AGENT_HOME/ladder/<YYYY-MM-DD>, checked and
#      incremented before every call. At the limit (or when the count cannot be written) no model is called and
#      the run ends as if no model were configured: the tests' exit code, a ladder-cap line in the log.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

DIR=$PWD
if [ "${1:-}" = "-C" ]; then DIR=$2; shift 2; fi
if [ "${1:-}" = "--" ]; then shift; fi
if [ $# -gt 0 ]; then TEST_CMD=("$@")
elif [ -x "$DIR/tests/run.sh" ]; then TEST_CMD=(tests/run.sh)
else echo "test-escalate: no test command given and no tests/run.sh in $DIR" >&2; exit 2; fi

MODELS=${CHING_TEST_MODELS-claude-haiku-4-5-20251001 claude-sonnet-5-5}   # set but empty = no model
# Recursion guard: a model started below loads the same Stop hook, which would run this script again and
# start more models without end. Children carry CHING_ESCALATING=1 and never start models of their own.
[ -z "${CHING_ESCALATING:-}" ] || MODELS=""
BUDGET=${CHING_TEST_BUDGET_USD:-0.50}
CLAUDE=${CHING_CLAUDE_BIN:-claude}
LOG=${CHING_TEST_LOG:-$AGENT_HOME/test-escalation.log}
mkdir -p "$(dirname "$LOG")"
log() { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# Daily ceiling on model calls, machine-wide (every session, every repo). Without it a repo whose tests fail
# for any reason (a missing service) pays for the whole ladder on every blocked stop of every session.
LIMIT=${CHING_TEST_LADDER_DAILY:-6}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=6 ;; esac
[ "${#LIMIT}" -le 9 ] || LIMIT=999999999
LADDER_DIR=$AGENT_HOME/ladder
# ladder_take: 0 = a model call may start and is already counted; 1 = make no call (limit reached, or the
# call cannot be counted: an unwritable counter must never mean unlimited spend). Checked once per call.
ladder_take() {
  local day f n tmp
  day=$(date -u +%Y-%m-%d); f=$LADDER_DIR/$day; n=0
  if [ -f "$f" ]; then n=$(head -n 1 "$f" 2>/dev/null || true); fi
  case "$n" in ''|*[!0-9]*) n=0 ;; esac   # a garbage or unreadable counter counts as 0
  [ "${#n}" -le 9 ] || n=999999999
  n=$((10#$n))
  if [ "$n" -ge "$LIMIT" ]; then
    log "ladder-cap date=$day count=$n limit=$LIMIT"
    CWD=$DIR ev ladder_cap "$(jq -nc --arg d "$day" --argjson n "$n" --argjson l "$LIMIT" '{date:$d,count:$n,limit:$l}')"
    return 1
  fi
  if [ -d "$f" ] || ! (umask 077; mkdir -p "$LADDER_DIR") 2>/dev/null || ! tmp=$(mktemp "$LADDER_DIR/.count.XXXXXX" 2>/dev/null); then
    log "ladder-skip date=$day count=$n limit=$LIMIT reason=counter-not-writable"
    return 1
  fi
  if printf '%s\n' "$((n + 1))" >"$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then return 0; fi
  rm -f "$tmp"
  log "ladder-skip date=$day count=$n limit=$LIMIT reason=counter-not-writable"
  return 1
}

OUT=$(mktemp /tmp/ching-test-escalate.XXXXXX)
trap 'rm -f "$OUT"' EXIT
RC=0
run_tests() { RC=0; (cd "$DIR" && "${TEST_CMD[@]}") >"$OUT" 2>&1 || RC=$?; return "$RC"; }

if run_tests; then log "pass model=none"; echo "tests pass (no model used)"; exit 0; fi

TRIED=""
for m in $MODELS; do
  ladder_take || break   # no call past the daily ceiling: fall through to the plain "still failing" ending
  TRIED="${TRIED:+$TRIED }$m"
  echo "tests fail; asking $m to fix"
  prompt="The test command \`${TEST_CMD[*]}\` fails in $DIR. Fix the cause with the smallest correct change. Do not edit or delete tests to make them pass. Do not commit. Output of the failing run (last 200 lines):

$(tail -n 200 "$OUT")"
  (cd "$DIR" && CHING_ESCALATING=1 "$CLAUDE" -p --model "$m" --max-budget-usd "$BUDGET" --no-session-persistence "$prompt" </dev/null >/dev/null 2>&1) || true
  if run_tests; then log "pass model=$m"; echo "tests pass after fix by $m"; exit 0; fi
  log "fail model=$m"
done

log "blocked ladder=[$TRIED]"
if [ -n "$TRIED" ] && [ "${CHING_TEST_NOTIFY:-1}" = 1 ]; then
  "$SELF_DIR/notify.sh" blocked "Tests still failing after: $TRIED" </dev/null >/dev/null 2>&1 || true
fi
echo "tests still fail (models tried: ${TRIED:-none})" >&2
tail -n 40 "$OUT" >&2
exit "$RC"
