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

OUT=$(mktemp /tmp/ching-test-escalate.XXXXXX)
trap 'rm -f "$OUT"' EXIT
RC=0
run_tests() { RC=0; (cd "$DIR" && "${TEST_CMD[@]}") >"$OUT" 2>&1 || RC=$?; return "$RC"; }

if run_tests; then log "pass model=none"; echo "tests pass (no model used)"; exit 0; fi

for m in $MODELS; do
  echo "tests fail; asking $m to fix"
  prompt="The test command \`${TEST_CMD[*]}\` fails in $DIR. Fix the cause with the smallest correct change. Do not edit or delete tests to make them pass. Do not commit. Output of the failing run (last 200 lines):

$(tail -n 200 "$OUT")"
  (cd "$DIR" && CHING_ESCALATING=1 "$CLAUDE" -p --model "$m" --max-budget-usd "$BUDGET" --no-session-persistence "$prompt" </dev/null >/dev/null 2>&1) || true
  if run_tests; then log "pass model=$m"; echo "tests pass after fix by $m"; exit 0; fi
  log "fail model=$m"
done

log "blocked ladder=[$MODELS]"
if [ -n "$MODELS" ] && [ "${CHING_TEST_NOTIFY:-1}" = 1 ]; then
  "$SELF_DIR/notify.sh" blocked "Tests still failing after: $MODELS" </dev/null >/dev/null 2>&1 || true
fi
echo "tests still fail (models tried: ${MODELS:-none})" >&2
tail -n 40 "$OUT" >&2
exit "$RC"
