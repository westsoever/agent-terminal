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
# that Claude Code kills allows the stop and orphans its children. Each step gets what is left. A check cut
# off at the deadline has no verdict: the stop is allowed (exit 3, "out of time" on stderr), stop_deadline is
# logged and the user is notified; the model is not told to fix anything and no retry is counted.
# Env: STOP_CHECK_MAX_RETRIES (3) STOP_CHECK_TIMEOUT (one check run, 600 s, never more than the deadline;
#      a run cut by it is a failure, "timed out")
#      STOP_CHECK_DEADLINE (the whole hook, 780 s: 2 minutes of margin under the 900 s hook timeout)
#      STOP_CHECK_SKIP_TTL (1800 s: how long an unchanged tree's green run is trusted; 0 = always run)
#      CHING_NO_CHECKPOINT=1 (scripted runs: never ask for the checkpoint; see checkpoint_gate)
# Checkpoint rule (repo mode, once a prompt is recorded, only when the turn changed the tree): STATE.md must hold
# a valid <!-- ching:checkpoint --> block, written after the prompt: the six keys, none empty, and none of result,
# next_action, examined, not_examined still the template's "(none)". A touch of STATE.md is not enough (F7). When it
# is missing or invalid the stop is blocked once and the block's hash is kept in the session meta
# (ckpt_hash_at_block); the next stop of the same prompt passes only if the block CHANGED since then and is valid,
# else it is blocked one more time, and the stop after that is allowed with a checkpoint_unmet event. At most two
# blocks per prompt, whatever stop_hook_active says, so it can never loop. Opt-outs: CHING_NO_CHECKPOINT=1,
# CLAUDE_CODE_ENTRYPOINT=sdk-*. Residual: a valid block left over from an earlier turn, with STATE.md touched this
# turn, passes on the first stop (nothing says the block was not rewritten).
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
  if [ -n "$OUT" ]; then rm -f "$OUT" "$OUT.report"; fi
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
BUDGET=${STOP_CHECK_DEADLINE:-780}
case "$BUDGET" in ''|*[!0-9]*) BUDGET=780 ;; esac
[ "${#BUDGET}" -le 6 ] || BUDGET=780
BUDGET=$((10#$BUDGET)); [ "$BUDGET" -ge 1 ] || BUDGET=1
DEADLINE=$((START + BUDGET))
TIMEOUT=${STOP_CHECK_TIMEOUT:-600}
case "$TIMEOUT" in ''|*[!0-9]*) TIMEOUT=600 ;; esac
[ "${#TIMEOUT}" -le 6 ] || TIMEOUT=600
TIMEOUT=$((10#$TIMEOUT)); [ "$TIMEOUT" -ge 1 ] || TIMEOUT=1
[ "$TIMEOUT" -le "$BUDGET" ] || TIMEOUT=$BUDGET   # a run limit past the deadline would never apply
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

# tree_changed_since EPOCH: true when the work tree may have changed at or after EPOCH: HEAD moved (a commit,
# checkout or reset writes its reflog), or a changed, staged, untracked or deleted path has an mtime at or
# after it. Anything it cannot tell (a git error, a deleted path) counts as changed.
tree_changed_since() {
  local logs
  logs=$(git -C "$ROOT" rev-parse --git-path logs/HEAD 2>/dev/null) || return 0
  case "$logs" in /*) ;; *) logs="$ROOT/$logs" ;; esac
  if [ -f "$logs" ]; then [ "$(file_mtime "$logs")" -lt "$1" ] || return 0
  else [ "$(git -C "$ROOT" log -1 --format=%ct 2>/dev/null || echo 0)" -lt "$1" ] || return 0; fi   # no reflog
  (cd "$ROOT" && perl -e '
    my $p = shift;
    open(my $fh, "-|", qw(git status --porcelain -z --untracked-files=all)) or exit 0;
    local $/ = "\0"; my $skip = 0;
    while (my $e = <$fh>) {
      chomp $e;
      if ($skip) { $skip = 0; next }            # the old name of a rename or copy
      my ($xy, $path) = (substr($e, 0, 2), substr($e, 3));
      $skip = 1 if $xy =~ /[RC]/;
      my @s = lstat $path;
      exit 0 if !@s || $s[9] >= $p;
    }
    close $fh or exit 0;
    exit 1;
  ' "$1")
}

# Repo mode only, and only once a prompt was recorded: block when STATE.md has no valid checkpoint block or it was
# not updated since that prompt (see the header for the full rule: at most two blocks per prompt). A fresh, valid
# checkpoint is checked first so the checkpoint event is logged whether the model wrote it unprompted or after a
# block. Not asked: when the turn changed nothing in the tree (a question answered), and in scripted runs, where the
# block would replace the run's answer: CHING_NO_CHECKPOINT=1, or CLAUDE_CODE_ENTRYPOINT=sdk-* (Claude Code sets
# sdk-cli for claude -p, sdk-ts/sdk-py for the Agent SDK, cli for an interactive session; seen in the 2.1 binary, not
# documented, hence the explicit switch too).
# prompt_state: set PROMPTED (epoch of the last prompt, '' when none or not in repo mode) and TREE_CHANGED
# (1/0) once. Called before the test run, so files the check itself writes do not count as the turn's work.
PROMPTED=""; TREE_CHANGED=""
prompt_state() {
  [ -z "$TREE_CHANGED" ] || return 0
  TREE_CHANGED=0
  [ "$REPO_MODE" -eq 1 ] || return 0
  [ -f "$SESS_DIR/meta" ] || return 0   # meta_get on a missing file fails under pipefail and set -e would end the hook
  PROMPTED=$(meta_get "$SESS_DIR/meta" prompted)
  [ -n "$PROMPTED" ] || return 0
  if tree_changed_since "$PROMPTED"; then TREE_CHANGED=1; fi
}

# ckpt_hash FILE: sha256 of the checkpoint block (the lines between the markers, trailing blanks and blank lines
# dropped), so a touch of the file or an edit outside the block does not change it. Needs the file to exist.
ckpt_hash() {
  awk '
    index($0, "<!-- ching:checkpoint -->") == 1 { c = 1; next }
    index($0, "<!-- /ching:checkpoint -->") == 1 { exit }
    c { sub(/[[:space:]]+$/, ""); if ($0 != "") print }
  ' "$1" | shasum -a 256 | cut -d' ' -f1
}
# ckpt_bad_keys FILE: the keys of the six that are missing, empty, or still the template's placeholder "(none)"
# (result, next_action, examined, not_examined; `none` and `0` are real answers for blocker and files_changed).
ckpt_bad_keys() {
  local k v bad=""
  for k in result blocker next_action files_changed examined not_examined; do
    v=$(checkpoint_get "$1" "$k")
    case "$k:$v" in
      *:) bad="$bad $k" ;;
      result:*|next_action:*|examined:*|not_examined:*) case "$v" in '('[Nn][Oo][Nn][Ee]')') bad="$bad $k" ;; esac ;;
    esac
  done
  printf '%s' "${bad# }"
}

# ckpt_task_type FILE: the block's optional task_type when it is one of the fixed types (D26: build, fix, research,
# merge/sync, ops/config, writing, data; case and blanks ignored, merge or sync -> merge/sync, ops or config ->
# ops/config), else empty: the template's (none), a missing line and any other word leave the type to the learner.
ckpt_task_type() {
  local t
  t=$(checkpoint_get "$1" task_type | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
  case "$t" in
    build|fix|research|merge/sync|ops/config|writing|data) printf '%s' "$t" ;;
    merge|sync) printf 'merge/sync' ;;
    ops|config) printf 'ops/config' ;;
  esac
}
# ckpt_event FILE: log the checkpoint event (spec 4.3): status, blocker, next_action, not_examined, and task_type
# when ckpt_task_type gives one. ev cuts strings to 300 characters but drops ALL the data of a line over 1 KB, so
# the free text is budgeted to fit: blocker and next_action 120 characters each, not_examined (the blind-spot
# ledger's input) 300, cut after its last whole item (items end at "; " or ", ") when that keeps at least half.
ckpt_event() {
  local st=$1 status
  status=$(sed -n 's/^status:[[:space:]]*//p' "$st" | head -1)
  # shellcheck disable=SC2016 # jq source
  ev checkpoint "$(jq -nc --arg s "$status" --arg b "$(checkpoint_get "$st" blocker)" --arg n "$(checkpoint_get "$st" next_action)" \
    --arg ne "$(checkpoint_get "$st" not_examined)" --arg t "$(ckpt_task_type "$st")" '
    def cut($m): .[0:$m];
    def items($m): if length <= $m then .
      else .[0:$m + 1] | ([capture("^(?<k>.*)(;|, )").k][0] // "" | sub("\\s+$"; "")) as $k
        | if ($k | length) * 2 >= $m then $k else .[0:$m] end end;
    {status: $s, blocker: ($b | cut(120)), next_action: ($n | cut(120)), not_examined: ($ne | items(300))}
    + (if $t == "" then {} else {task_type: $t} end)')"
}

checkpoint_gate() {
  [ "$REPO_MODE" -eq 1 ] || return 0
  local prompted st status nblocks=0 at_block cur=missing bad="" why="" reason
  prompt_state
  prompted=$PROMPTED
  [ -n "$prompted" ] || return 0
  st="$STATE_DIR/STATE.md"
  # blocks given for THIS prompt so far (a record from an older version has only checkpoint_blocked_for: one)
  if [ "$(meta_get "$SESS_DIR/meta" checkpoint_blocked_for)" = "$prompted" ]; then
    nblocks=$(meta_get "$SESS_DIR/meta" ckpt_blocks)
    case "$nblocks" in ''|*[!0-9]*) nblocks=1 ;; esac
  fi
  at_block=$(meta_get "$SESS_DIR/meta" ckpt_hash_at_block)
  if [ ! -f "$st" ] || ! grep -qF '<!-- ching:checkpoint -->' "$st"; then why=missing
  elif [ "$(file_mtime "$st")" -lt "$prompted" ]; then why=stale; cur=$(ckpt_hash "$st")
  else
    cur=$(ckpt_hash "$st")
    bad=$(ckpt_bad_keys "$st")
    if [ -n "$bad" ]; then why=invalid
    elif [ "$nblocks" -ge 1 ] && [ "$cur" = "$at_block" ]; then why=unchanged   # nothing was written since the block
    fi
  fi
  if [ -z "$why" ]; then
    ckpt_event "$st"
    return 0
  fi
  [ "${CHING_NO_CHECKPOINT:-}" != 1 ] || return 0
  case "${CLAUDE_CODE_ENTRYPOINT:-}" in sdk-*) return 0 ;; esac
  [ "$TREE_CHANGED" -eq 1 ] || return 0
  if [ "$nblocks" -ge 2 ]; then   # asked twice for this prompt: allow, say so, never loop
    ev checkpoint_unmet "$(jq -nc --arg w "$why" --arg k "$bad" --argjson n "$nblocks" '{reason:$w,keys:$k,blocks:$n}')"
    return 0
  fi
  nblocks=$((nblocks + 1))
  meta_set checkpoint_blocked_for "$prompted"
  meta_set ckpt_blocks "$nblocks"
  meta_set ckpt_hash_at_block "$cur"
  ev stop_blocked "$(jq -nc --argjson n "$nblocks" --arg w "$why" '{retry:$n,reason:"checkpoint",why:$w}')"
  if [ "$nblocks" -eq 1 ]; then
    reason="Do not stop yet: update the checkpoint block in $st for this turn. Edit only the six lines between <!-- ching:checkpoint --> and <!-- /ching:checkpoint --> (add the block if it is missing): result, blocker, next_action, files_changed, examined, not_examined. Nothing else is needed. Fill in real values: the template's (none) does not count for result, next_action, examined and not_examined (write none or nothing when that is the true answer). If the block is still empty or unchanged you are asked one more time, then the stop is allowed."
  else
    case "$why" in
      unchanged) reason="Do not stop yet: the checkpoint block in $st is unchanged since the first request. Rewrite its six lines (result, blocker, next_action, files_changed, examined, not_examined) for this turn. This is the last time it is asked for this prompt." ;;
      *) reason="Do not stop yet: the checkpoint block in $st is still ${why}${bad:+ ($bad missing, empty or still (none))}. Fill in the six lines between <!-- ching:checkpoint --> and <!-- /ching:checkpoint --> for this turn: result, blocker, next_action, files_changed, examined, not_examined; write none or nothing where that is the true answer. This is the last time it is asked for this prompt." ;;
    esac
  fi
  jq -n --arg r "$reason" '{decision:"block", reason:$r}'
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
  [ "${#pass_at}" -le 12 ] || pass_at=0
  age=$(($(date +%s) - 10#$pass_at))
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
prompt_state   # before the run: files the check writes are not the turn's work (checkpoint gate)
RUN_AT=$(date +%s)
# test-escalate.sh runs in a session (process group) of its own. A TERM/INT/HUP to this hook (Claude Code's
# hook timeout, Esc) takes that whole group down, TERM and then KILL, so no check run or model call outlives
# the hook; the hook then ends as a no verdict. `wait` returns at once when a trapped signal arrives.
ESC_PID=""
on_signal() { # name
  local _i
  if [ -n "$ESC_PID" ]; then
    kill -TERM -- "-$ESC_PID" 2>/dev/null || true
    for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      kill -0 -- "-$ESC_PID" 2>/dev/null || break; sleep 0.1
    done
    kill -KILL -- "-$ESC_PID" 2>/dev/null || true
  fi
  no_verdict "interrupted by SIG$1; the done-check and its children were stopped"
}
trap 'on_signal TERM' TERM; trap 'on_signal INT' INT; trap 'on_signal HUP' HUP
# --timeout kills the whole process group of a run that takes too long (exit 142), not only its top bash;
# --deadline makes every run and model call fit in what is left of the hook's budget; --report lists the
# models really called.
CHING_TEST_NOTIFY=0 perl -e 'use POSIX (); POSIX::setsid() or setpgrp(0, 0); exec { $ARGV[0] } @ARGV or exit 127' \
  "$SELF_DIR/test-escalate.sh" -C "$WORK_DIR" --timeout "$TIMEOUT" --deadline "$DEADLINE" --report "$OUT.report" -- \
  bash -c "$TEST_CMD" >"$OUT" 2>&1 </dev/null &
ESC_PID=$!
wait "$ESC_PID" || rc=$?
ESC_PID=""
trap - TERM INT HUP
TRIED=$(cat "$OUT.report" 2>/dev/null || true)
END_AT=$(date +%s)
# The tests event (spec 4.3): the verdict of this run, model fixes included, and its wall time. A run cut off
# at the hook deadline has no verdict and logs none (stop_deadline below); a run cut by STOP_CHECK_TIMEOUT failed.
if [ "$rc" -eq 0 ]; then ev tests "$(jq -nc --argjson s $((END_AT - RUN_AT)) '{outcome:"pass",secs:$s}')"
elif [ "$rc" -ne 142 ] || [ "$END_AT" -lt "$DEADLINE" ]; then ev tests "$(jq -nc --argjson s $((END_AT - RUN_AT)) '{outcome:"fail",secs:$s}')"
fi

if [ "$rc" -eq 0 ]; then
  # Record the tree as it was before the run, and only when the run (and any model fix) left it unchanged:
  # a tree that changed during the run was not the tree that was tested as a whole. It is checked next time.
  rm -f "$COUNTER" "$PASS_FILE"
  if [ -n "$ROOT" ] && [ "$(fingerprint)" = "$FP" ]; then printf '%s %s\n' "$FP" "$RUN_AT" >"$PASS_FILE"; fi
  finish_ok
fi
# Cut off at the deadline: the check never finished, so there is no verdict to act on. Blocking would only
# send the model to "fix" a check that may be fine, three times over 13 minutes each.
if [ "$rc" -eq 142 ] && [ "$END_AT" -ge "$DEADLINE" ]; then
  ev stop_deadline "$(jq -nc --argjson b "$BUDGET" --argjson e "$(($(date +%s) - START))" '{budget:$b,elapsed:$e}')"
  set_state blocked
  notify blocked "Done-check out of time after ${BUDGET}s (STOP_CHECK_DEADLINE), no verdict: $TEST_CMD"
  no_verdict "out of time: the done-check did not finish within the hook's ${BUDGET}s budget (STOP_CHECK_DEADLINE)"
fi
# Still failing after a model was really called: remember the tree before the run and the tree the models
# left behind. A ladder held back (daily ceiling, deadline, caller gone) has not failed on this tree.
if [ -n "$TRIED" ] && [ -n "$ROOT" ]; then
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
if [ "$rc" -eq 142 ]; then WHY="timed out after ${TIMEOUT}s"; else WHY="exit code $rc"; fi
REASON="Do not stop yet: the done-check in $GOAL_FILE failed ($WHY, attempt $n of $MAX). Command: $TEST_CMD"$'\n\n'"Last output:"$'\n'"$TAIL"$'\n\n'"Fix the failure and finish. Do not ask questions; log assumptions in STATE.md."
jq -n --arg r "$REASON" '{decision:"block", reason:$r}'
exit 0
