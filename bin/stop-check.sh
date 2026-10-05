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
# The same for anything the test_command itself starts (a claude -p smoke test, an Agent-SDK test, a suite
# with a live test): it inherits CHING_STOP_CHECK_RUNNING from the run below, so its own Stop hook ends here
# instead of running the test_command again under a new session id without end.
[ -z "${CHING_STOP_CHECK_RUNNING:-}" ] || exit 0

# Both caps are safety limits: a non-number falls back to the default, and neither may be below 1
# (STOP_CHECK_TIMEOUT=0 would mean no alarm at all, STOP_CHECK_MAX_RETRIES=three would never be reached).
MAX=${STOP_CHECK_MAX_RETRIES:-3}
case "$MAX" in ''|*[!0-9]*) MAX=3 ;; esac
[ "$MAX" -ge 1 ] || MAX=1
TIMEOUT=${STOP_CHECK_TIMEOUT:-900}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=900 ;; esac
[ "$TIMEOUT" -ge 1 ] || TIMEOUT=1

hook_init
resolve_state
LAST_MSG=$(jget last_assistant_message)

notify() { # kind message
  NOTIFY_CWD="$CWD" NOTIFY_SESSION="$SID" "$SELF_DIR/notify.sh" "$1" "$2" </dev/null || true
}
set_state() { meta_set state "$1"; meta_set updated "$(date +%s)"; }

# Repo mode only, and only once a prompt was recorded: block ONCE per prompt when STATE.md has no
# checkpoint block or it was not updated since that prompt. The meta key makes the next Stop pass.
# A fresh checkpoint is checked first so the checkpoint event is logged whether the model wrote it
# unprompted or after the one block.
checkpoint_gate() {
  [ "$REPO_MODE" -eq 1 ] || return 0
  local prompted st status
  [ -f "$SESS_DIR/meta" ] || return 0   # meta_get on a missing file fails under pipefail and set -e would end the hook
  prompted=$(meta_get "$SESS_DIR/meta" prompted)
  [ -n "$prompted" ] || return 0
  st="$STATE_DIR/STATE.md"
  if [ -f "$st" ] && grep -qF '<!-- ching:checkpoint -->' "$st" && [ "$(file_mtime "$st")" -ge "$prompted" ]; then
    status=$(sed -n 's/^status:[[:space:]]*//p' "$st" | head -1)
    ev checkpoint "$(jq -nc --arg s "$status" --arg b "$(checkpoint_get "$st" blocker)" --arg n "$(checkpoint_get "$st" next_action)" \
      '{status:$s,blocker:$b,next_action:$n}')"
    return 0
  fi
  [ "$(meta_get "$SESS_DIR/meta" checkpoint_blocked_for)" != "$prompted" ] || return 0   # already asked once for this prompt
  meta_set checkpoint_blocked_for "$prompted"
  ev stop_blocked '{"retry":1,"reason":"checkpoint"}'
  jq -n --arg r "Do not stop yet: update the checkpoint block in $st for this turn (run /handoff: result, blocker, next_action, files_changed, examined, not_examined). This is asked once per prompt." \
    '{decision:"block", reason:$r}'
  exit 0
}

# A turn that ends with a question to the user is "needs input"; anything else is "done".
finish_ok() {
  checkpoint_gate
  local last snippet kind="done"
  last=$(printf '%s' "$LAST_MSG" | awk 'NF { l = $0 } END { print l }')
  if printf '%s' "$last" | grep -Eq '\?[[:space:]]*[)"*_]*$'; then kind=input; fi
  snippet=$(printf '%s' "$LAST_MSG" | tr '\n' ' ' | cut -c1-140)
  ev stop_ok "$(jq -nc --arg k "$kind" '{outcome:$k}')"
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

# The retry count so far, read before the run: when it is already at the cap, this is the stop that will
# be allowed whatever happens, so the paid model ladder must not run for it.
n=0
if [ -f "$COUNTER" ]; then n=$(cat "$COUNTER" 2>/dev/null || echo 0); fi
case "$n" in ''|*[!0-9]*) n=0 ;; esac

rc=0
# test-escalate.sh runs the check with no model first; only on failure does it call the cheapest model
# (Haiku), then the next (Sonnet), re-running the check after each. CHING_TEST_MODELS="" turns that off.
# CHING_STOP_CHECK_RUNNING marks everything the test command starts (see the guard at the top). It is not
# CHING_ESCALATING: test-escalate.sh would switch the model ladder off for this run too.
export CHING_STOP_CHECK_RUNNING=1
if [ "$n" -ge "$MAX" ]; then export CHING_TEST_MODELS=""; fi
CHING_TEST_NOTIFY=0 "$SELF_DIR/test-escalate.sh" -C "$WORK_DIR" -- \
  perl -e 'alarm shift @ARGV; exec @ARGV' "$TIMEOUT" bash -c "$TEST_CMD" >"$OUT" 2>&1 </dev/null || rc=$?

if [ "$rc" -eq 0 ]; then
  FP=$(fingerprint)   # a model may have changed files while fixing: record the tree as it is now
  rm -f "$COUNTER"
  printf '%s\n' "$FP" >"$PASS_FILE"
  finish_ok
fi

if [ "$n" -ge "$MAX" ]; then
  # Cap reached: allow the stop, record it, and tell the human.
  rm -f "$COUNTER"
  mkdir -p "$STATE_DIR"
  {
    printf '\n- %s stop-check: gave up after %s retries (session %s); %s still failing (exit %s). Last output:\n' \
      "$(date '+%Y-%m-%d %H:%M')" "$MAX" "$SID" "$TEST_CMD" "$rc"
    tail -n 15 "$OUT" | sed 's/^/    /'
  } >>"$STATE_DIR/STATE.md" 2>/dev/null || true
  ev stop_blocked '{"retry":"cap","reason":"tests-cap"}'
  set_state blocked
  notify blocked "Tests still failing after $MAX retries: $TEST_CMD"
  exit 0
fi

n=$((n + 1))
printf '%s\n' "$n" >"$COUNTER"
ev stop_blocked "$(jq -nc --argjson n "$n" '{retry:$n,reason:"tests"}')"
TAIL=$(tail -n 40 "$OUT" | cut -c1-400 | head -c 3500)
if [ "$rc" -eq 142 ]; then WHY="timed out after ${TIMEOUT}s"; else WHY="exit code $rc"; fi
REASON="Do not stop yet: the done-check in $GOAL_FILE failed ($WHY, attempt $n of $MAX). Command: $TEST_CMD"$'\n\n'"Last output:"$'\n'"$TAIL"$'\n\n'"Fix the failure and finish. Do not ask questions; log assumptions in STATE.md."
jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
