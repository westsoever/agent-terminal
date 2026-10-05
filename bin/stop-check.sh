#!/usr/bin/env bash
# Stop hook: when a GOAL.md (repo .agent/GOAL.md, else ~/.agent/defaults/GOAL.md) names a test_command,
# run it; block the stop (with the failure tail) while it fails, at most 3 times per session id; then let
# the session end and notify. With no GOAL.md / no test_command it always allows the stop. Works in any
# folder (no git repo needed).
#
# Schemas confirmed in Phase 0: stdin has session_id, cwd, stop_hook_active, last_assistant_message;
# block = {"decision":"block","reason":"..."} on stdout, exit 0. Claude Code's own cap is 8, ours is 3;
# the per-session counter (not stop_hook_active) enforces it.
# The check goes through test-escalate.sh (no model unless it fails; Haiku, then Sonnet).
# Env: STOP_CHECK_MAX_RETRIES (3) STOP_CHECK_TIMEOUT (900 s) CHING_TEST_MODELS (see test-escalate.sh)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

# A model started by test-escalate.sh inherits this hook: its stop is never gated, counted or notified.
[ -z "${CHING_ESCALATING:-}" ] || exit 0

MAX=${STOP_CHECK_MAX_RETRIES:-3}
TIMEOUT=${STOP_CHECK_TIMEOUT:-900}

hook_init
resolve_state
LAST_MSG=$(jget last_assistant_message)

notify() { # kind message
  NOTIFY_CWD="$CWD" NOTIFY_SESSION="$SID" "$SELF_DIR/notify.sh" "$1" "$2" </dev/null || true
}
set_state() { meta_set state "$1"; meta_set updated "$(date +%s)"; }

# A turn that ends with a question to the user is "needs input"; anything else is "done".
finish_ok() {
  local last snippet kind="done"
  last=$(printf '%s' "$LAST_MSG" | awk 'NF { l = $0 } END { print l }')
  if printf '%s' "$last" | grep -Eq '\?[[:space:]]*[)"*_]*$'; then kind=input; fi
  snippet=$(printf '%s' "$LAST_MSG" | tr '\n' ' ' | cut -c1-140)
  set_state "$kind"
  notify "$kind" "${snippet:-Session finished.}"
  exit 0
}

TEST_CMD=$(goal_get "$GOAL_FILE" test_command)
case "$TEST_CMD" in ''|'<'*) rm -f "$SESS_DIR/retries"; finish_ok ;; esac

mkdir -p "$SESS_DIR"
COUNTER="$SESS_DIR/retries"
PASS_FILE="$SESS_DIR/last-pass"

fingerprint() {
  {
    printf '%s' "$TEST_CMD"
    if [ -n "$ROOT" ]; then
      git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo no-head
      git -C "$ROOT" status --porcelain 2>/dev/null || true
      git -C "$ROOT" diff HEAD 2>/dev/null || true
      git -C "$ROOT" ls-files -o --exclude-standard -z 2>/dev/null | (cd "$ROOT" && xargs -0 cat 2>/dev/null) || true
    else
      date +%s.%N
    fi
  } | shasum -a 256 | cut -d' ' -f1
}
FP=$(fingerprint)

# Nothing changed since the last green run (git repos only): skip the possibly slow test run.
if [ -n "$ROOT" ] && [ -f "$PASS_FILE" ] && [ "$(cat "$PASS_FILE")" = "$FP" ]; then
  rm -f "$COUNTER"
  finish_ok
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/ching-stop.XXXXXX")
trap 'rm -f "$OUT"' EXIT
rc=0
# test-escalate.sh runs the check with no model first; only on failure does it call the cheapest model
# (Haiku), then the next (Sonnet), re-running the check after each. CHING_TEST_MODELS="" turns that off.
CHING_TEST_NOTIFY=0 "$SELF_DIR/test-escalate.sh" -C "$WORK_DIR" -- \
  perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT" bash -c "$TEST_CMD" >"$OUT" 2>&1 </dev/null || rc=$?

if [ "$rc" -eq 0 ]; then
  FP=$(fingerprint)   # a model may have changed files while fixing: record the tree as it is now
  rm -f "$COUNTER"
  printf '%s\n' "$FP" >"$PASS_FILE"
  finish_ok
fi

n=0
if [ -f "$COUNTER" ]; then n=$(cat "$COUNTER" 2>/dev/null || echo 0); fi
case "$n" in ''|*[!0-9]*) n=0 ;; esac

if [ "$n" -ge "$MAX" ]; then
  # Cap reached: allow the stop, record it, and tell the human.
  rm -f "$COUNTER"
  mkdir -p "$STATE_DIR"
  {
    printf '\n- %s stop-check: gave up after %s retries (session %s); %s still failing (exit %s). Last output:\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$MAX" "$SID" "$TEST_CMD" "$rc"
    tail -n 15 "$OUT" | sed 's/^/    /'
  } >>"$STATE_DIR/STATE.md" 2>/dev/null || true
  set_state blocked
  notify blocked "Tests still failing after $MAX retries: $TEST_CMD"
  exit 0
fi

n=$((n + 1))
printf '%s\n' "$n" >"$COUNTER"
TAIL=$(tail -n 40 "$OUT" | cut -c1-400 | head -c 3500)
if [ "$rc" -eq 142 ]; then WHY="timed out after ${TIMEOUT}s"; else WHY="exit code $rc"; fi
REASON="Do not stop yet: the done-check in $GOAL_FILE failed ($WHY, attempt $n of $MAX). Command: $TEST_CMD"$'\n\n'"Last output:"$'\n'"$TAIL"$'\n\n'"Fix the failure and finish. Do not ask questions; log assumptions in STATE.md."
jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
