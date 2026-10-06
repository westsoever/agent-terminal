#!/usr/bin/env bash
# Stop hook: when a GOAL.md (repo .agent/GOAL.md, else ~/.agent/defaults/GOAL.md) names a test_command,
# run it; block the stop (with the failure tail) while it fails, at most 3 times per session id; then let
# the session end and notify. With no GOAL.md / no test_command it always allows the stop. Works in any
# folder (no git repo needed).
#
# Schemas confirmed in Phase 0: stdin has session_id, cwd, stop_hook_active, last_assistant_message;
# block = {"decision":"block","reason":"..."} on stdout, exit 0. Claude Code's own cap is 8, ours is 3;
# the per-session counter (not stop_hook_active) enforces it.
# Exit codes: 0 (allowed, or a block on stdout); 3 = no verdict: the hook could not do its own bookkeeping,
# the stop is allowed and stderr says why (see no_verdict below).
# The check goes through test-escalate.sh (no model unless it fails; Haiku, then Sonnet).
# One deadline covers the whole hook (check runs and model calls): install.sh gives the hook 900 s, and a hook
# that Claude Code kills allows the stop and orphans its children. Each step gets what is left; a check cut
# at the deadline blocks with "out of time" (a stop_deadline event), and that block counts as a retry.
# Env: STOP_CHECK_MAX_RETRIES (3) STOP_CHECK_TIMEOUT (one check run, 900 s)
#      STOP_CHECK_DEADLINE (the whole hook, 780 s: 2 minutes of margin under the 900 s hook timeout)
#      STOP_CHECK_SKIP_TTL (1800 s: how long an unchanged tree's green run is trusted; 0 = always run)
#      CHING_TEST_MODELS CHING_TEST_CALL_TIMEOUT CHING_TEST_MAX_TURNS (see test-escalate.sh)
set -euo pipefail
START=$(date +%s)
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

# A model started by test-escalate.sh inherits this hook: its stop is never gated, counted or notified.
[ -z "${CHING_ESCALATING:-}" ] || exit 0
# The same for anything the test_command itself starts (a claude -p smoke test, an Agent-SDK test, a suite
# with a live test): it inherits CHING_STOP_CHECK_RUNNING from the run below, so its own Stop hook ends here
# instead of running the test_command again under a new session id without end.
[ -z "${CHING_STOP_CHECK_RUNNING:-}" ] || exit 0

# No verdict (exit 3): the hook cannot do its own bookkeeping (jq missing, the session record cannot be
# written, the session folder is gone, any other unexpected failure). The stop is allowed, stderr says why
# (Claude Code shows the stderr of a hook that exits non-zero but not 2) and a stop_no_verdict event is
# logged when that still works. Never a block that blames the check for a failure of the hook.
DONE=""; OUT=""
no_verdict() { # reason
  DONE=1
  printf 'ching stop-check: no verdict (%s). The stop is allowed; no check result was recorded.\n' "$1" >&2
  ev stop_no_verdict "$(jq -nc --arg r "$1" '{reason:$r}' 2>/dev/null || true)" 2>/dev/null || true
  exit 3
}
on_exit() {
  local rc=$?
  if [ -n "$OUT" ]; then rm -f "$OUT"; fi
  if [ "$rc" -ne 0 ] && [ -z "$DONE" ]; then no_verdict "unexpected failure, exit $rc; see the error above"; fi
}
trap on_exit EXIT
# Without jq the hook cannot read its input: the session id would fall back to a nosession-<hash> shared by
# every session in this folder. Say so instead of failing open in silence.
command -v jq >/dev/null 2>&1 || no_verdict "jq is not on the hook PATH ($PATH); install jq or fix the PATH Claude Code runs hooks with"

# Both caps are safety limits: a non-number falls back to the default, and neither may be below 1
# (STOP_CHECK_TIMEOUT=0 would mean no alarm at all, STOP_CHECK_MAX_RETRIES=three would never be reached).
MAX=${STOP_CHECK_MAX_RETRIES:-3}
case "$MAX" in ''|*[!0-9]*) MAX=3 ;; esac
[ "$MAX" -ge 1 ] || MAX=1
TIMEOUT=${STOP_CHECK_TIMEOUT:-900}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=900 ;; esac
[ "$TIMEOUT" -ge 1 ] || TIMEOUT=1
BUDGET=${STOP_CHECK_DEADLINE:-780}
case "$BUDGET" in ''|*[!0-9]*) BUDGET=780 ;; esac
[ "${#BUDGET}" -le 6 ] || BUDGET=780
BUDGET=$((10#$BUDGET)); [ "$BUDGET" -ge 1 ] || BUDGET=1
DEADLINE=$((START + BUDGET))
SKIP_TTL=${STOP_CHECK_SKIP_TTL:-1800}
case "$SKIP_TTL" in ''|*[!0-9]*) SKIP_TTL=1800 ;; esac
[ "${#SKIP_TTL}" -le 9 ] || SKIP_TTL=1800

hook_init
resolve_state
# The session record holds the retry counter: without it the cap cannot work.
{ mkdir -p "$SESS_DIR" && [ -w "$SESS_DIR" ]; } 2>/dev/null || no_verdict "cannot write the session record $SESS_DIR; check AGENT_HOME"
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

[ -d "$WORK_DIR" ] || no_verdict "the session folder $WORK_DIR no longer exists; the done-check cannot run there"
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

# Nothing changed since the last green run (git repos only): skip the possibly slow test run. PASS_FILE holds
# "<fingerprint> <epoch of that run>". The fingerprint cannot see gitignored or outside inputs, so a green run
# is trusted for STOP_CHECK_SKIP_TTL seconds only (0 = never skip).
if [ -n "$ROOT" ] && [ -f "$PASS_FILE" ]; then
  pass_fp=""; pass_at=""
  read -r pass_fp pass_at <"$PASS_FILE" 2>/dev/null || true
  case "$pass_at" in ''|*[!0-9]*) pass_at=0 ;; esac
  age=$(($(date +%s) - pass_at))
  if [ "$pass_fp" = "$FP" ] && [ "$age" -lt "$SKIP_TTL" ]; then
    ev check_skipped "$(jq -nc --argjson a "$age" '{reason:"unchanged",age:$a}')"
    rm -f "$COUNTER"
    finish_ok
  fi
fi

OUT=$(mktemp "${TMPDIR:-/tmp}/ching-stop.XXXXXX")   # removed by on_exit

# The retry count so far, read before the run: when it is already at the cap, this is the stop that will
# be allowed whatever happens, so the paid model ladder must not run for it.
n=0
if [ -f "$COUNTER" ]; then n=$(cat "$COUNTER" 2>/dev/null || echo 0); fi
case "$n" in ''|*[!0-9]*) n=0 ;; esac

# Trees the model ladder already failed on (machine-wide, the last 100 fingerprints): the same failing tree
# gets the same answer, so it is not paid for again. Any change to the tree makes a new fingerprint.
LADDER_FAILED="$AGENT_HOME/ladder-failed"
remember_ladder_failed() { # fingerprint...
  local tmp
  tmp=$(mktemp "$AGENT_HOME/.ladder-failed.XXXXXX" 2>/dev/null) || return 0
  if { tail -n 100 "$LADDER_FAILED" 2>/dev/null || true; printf '%s\n' "$@"; } >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$LADDER_FAILED" 2>/dev/null || rm -f "$tmp"
  else rm -f "$tmp"; fi
}

rc=0
# test-escalate.sh runs the check with no model first; only on failure does it call the cheapest model
# (Haiku), then the next (Sonnet), re-running the check after each. CHING_TEST_MODELS="" turns that off.
# CHING_STOP_CHECK_RUNNING marks everything the test command starts (see the guard at the top). It is not
# CHING_ESCALATING: test-escalate.sh would switch the model ladder off for this run too.
export CHING_STOP_CHECK_RUNNING=1
if [ "$n" -ge "$MAX" ]; then export CHING_TEST_MODELS=""
elif [ -n "$ROOT" ] && [ -f "$LADDER_FAILED" ] && grep -qxF "$FP" "$LADDER_FAILED" 2>/dev/null; then
  export CHING_TEST_MODELS=""
  ev ladder_skipped '{"reason":"same-tree"}'
fi
LADDER_ON=0; [ -z "${CHING_TEST_MODELS-x}" ] || LADDER_ON=1
RUN_AT=$(date +%s)
# --timeout kills the whole process group of a run that takes too long (exit 142), not only its top bash;
# --deadline makes every run and model call fit in what is left of the hook's budget.
CHING_TEST_NOTIFY=0 "$SELF_DIR/test-escalate.sh" -C "$WORK_DIR" --timeout "$TIMEOUT" --deadline "$DEADLINE" -- \
  bash -c "$TEST_CMD" >"$OUT" 2>&1 </dev/null || rc=$?

if [ "$rc" -eq 0 ]; then
  # Record the tree as it was before the run, and only when the run (and any model fix) left it unchanged:
  # a tree that changed during the run was not the tree that was tested as a whole. It is checked next time.
  rm -f "$COUNTER" "$PASS_FILE"
  if [ -n "$ROOT" ] && [ "$(fingerprint)" = "$FP" ]; then printf '%s %s\n' "$FP" "$RUN_AT" >"$PASS_FILE"; fi
  finish_ok
fi
# Still failing after the ladder: remember the tree before the run and the tree the models left behind.
if [ "$LADDER_ON" -eq 1 ] && [ -n "$ROOT" ]; then
  FP_AFTER=$(fingerprint)
  if [ "$FP_AFTER" = "$FP" ]; then remember_ladder_failed "$FP"; else remember_ladder_failed "$FP" "$FP_AFTER"; fi
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
if [ "$rc" -eq 142 ] && [ "$(date +%s)" -ge "$DEADLINE" ]; then
  WHY="out of time: the hook's ${BUDGET}s budget (STOP_CHECK_DEADLINE) ran out before the check finished"
  ev stop_deadline "$(jq -nc --argjson b "$BUDGET" --argjson e "$(($(date +%s) - START))" '{budget:$b,elapsed:$e}')"
elif [ "$rc" -eq 142 ]; then WHY="timed out after ${TIMEOUT}s"
else WHY="exit code $rc"; fi
REASON="Do not stop yet: the done-check in $GOAL_FILE failed ($WHY, attempt $n of $MAX). Command: $TEST_CMD"$'\n\n'"Last output:"$'\n'"$TAIL"$'\n\n'"Fix the failure and finish. Do not ask questions; log assumptions in STATE.md."
jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
