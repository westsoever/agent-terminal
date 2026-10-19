#!/usr/bin/env bash
# learn.sh [--weekly | --nightly] - the learner's one entry point (Phase 6 spec 5 and 7), run by launchd
# (org.agent-terminal.learn, every day at 05:30 local; install.sh). It runs the learner components in order, under a mkdir
# lock (the agent-terminal-watch.sh pattern), each with cwd $AGENT_HOME/proposals/.work:
#   nightly  learn-extract.sh, learn-corrections.sh
#   weekly   then learn-skills.sh and learn-report.sh
# The weekly part runs on the first run of each ISO week (normally Monday 05:30; a Monday missed while the Mac was
# off runs at the next run), recorded in .work/weekly-stamp. --weekly forces it, --nightly leaves it out.
# A component file that does not exist (yet) is skipped with a learn_run {outcome: missing} event, so this works
# before every component has landed. LEARN_DISABLE (environment or $AGENT_HOME/config; names separated by commas or
# spaces: extract corrections skills report, or all) skips a component with learn_run {outcome: disabled}.
# Sets AGENT_TERMINAL_LEARNER=1 (guard learner mode) and CLAUDE_MEM_INTERNAL=1 (claude-mem does not observe, D27) for every
# component. Fails quiet: every component's output and a line per step go to .work/learn.log; a component that
# exits non-zero, or runs past LEARN_COMPONENT_TIMEOUT seconds (default 3600), gives learn_run {outcome: error}. It
# never touches hooks, sessions or anything outside $AGENT_HOME/proposals (events.jsonl aside). Prints one summary
# line. Exit 0, also when a component failed; 64 for a bad argument. TERM or INT stops the running component's whole
# process group before the lock is released (learn_run {outcome: error, rc: 143 or 130}) and exits 143 or 130.
# Env: AGENT_HOME LEARN_DISABLE LEARN_COMPONENT_TIMEOUT LEARN_LOCK_STALE (seconds, default 14400)
#      LEARN_COMPONENT_DIR (where the learn-*.sh files are; default this directory, tests)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

WEEKLY=auto
while [ $# -gt 0 ]; do
  case "$1" in
    --weekly) WEEKLY=yes; shift ;;
    --nightly) WEEKLY=no; shift ;;
    -h|--help) sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "learn: unknown argument $1 (--weekly | --nightly)" >&2; exit 64 ;;
  esac
done

export AGENT_TERMINAL_LEARNER=1 CLAUDE_MEM_INTERNAL=1
umask 077
COMP_DIR=${LEARN_COMPONENT_DIR:-$SELF_DIR}
SID=""; NAME="ching-learn"; CWD=""   # what ev() stamps on the events

run_event() { # component outcome [extra json object]
  local x=${3:-}
  [ -n "$x" ] || x='{}'
  ev learn_run "$(jq -nc --arg c "$1" --arg o "$2" --argjson x "$x" \
    '{component: $c, scanned: 0, candidates: 0, proposals: 0, outcome: $o} + $x')"
}

LOGF=$(proposal_safe_path .work/learn.log 2>/dev/null) || {
  echo "learn: $AGENT_HOME/proposals cannot be used (a symlink, or not writable); nothing ran" >&2
  run_event learn error; exit 0
}
WORK=${LOGF%/*}; CWD=$WORK
log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOGF" 2>/dev/null || true; }

STALE=$(learn_setting LEARN_LOCK_STALE); case "$STALE" in ''|*[!0-9]*) STALE=14400 ;; esac
LOCK="$WORK/learn.lock"
if [ -L "$LOCK" ]; then log "learn: $LOCK is a symlink; refusing to run"; run_event learn error; exit 0; fi
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(file_mtime "$LOCK") )) -lt "$STALE" ]; then
    log "learn: another run holds $LOCK; skipped"; echo "learn: another run is in progress; skipped"; exit 0
  fi
  log "learn: removing a stale lock (older than ${STALE}s)"
  rm -rf "$LOCK"; mkdir "$LOCK" 2>/dev/null || { log "learn: cannot take $LOCK"; run_event learn error; exit 0; }
fi
trap 'rm -rf "$LOCK"' EXIT
# TERM or INT (launchd stopping the job, ^C): the component runs in a process group of its own, which the signal
# sent to this script's group does not reach. Stop its watchdog, which takes the whole group down (TERM, then KILL
# after 3 s) and exits, then log, emit the component's error event and exit; the EXIT trap releases the lock last.
CHILD=""; CUR=""
on_signal() { # NAME EXIT-CODE
  trap '' TERM INT
  log "learn: SIG$1 while ${CUR:-nothing} ran; stopping"
  if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; wait "$CHILD" 2>/dev/null || true; fi
  [ -z "$CUR" ] || run_event "$CUR" error "$(jq -nc --argjson rc "$2" '{rc: $rc}')"
  echo "learn: stopped by SIG$1"
  exit "$2"
}
trap 'on_signal TERM 143' TERM
trap 'on_signal INT 130' INT

WEEK=$(date +%G-W%V)
STAMP="$WORK/weekly-stamp"
if [ "$WEEKLY" = auto ]; then
  if [ ! -L "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null || true)" = "$WEEK" ]; then WEEKLY=no; else WEEKLY=yes; fi
fi

DISABLE=" $(learn_setting LEARN_DISABLE | tr ',' ' ' | tr '[:upper:]' '[:lower:]' | tr -s ' ') "
TMO=$(learn_setting LEARN_COMPONENT_TIMEOUT); case "$TMO" in ''|*[!0-9]*) TMO=3600 ;; esac
SUMMARY=""

run_component() { # name script
  local name=$1 script=$2 rc start secs
  case "$DISABLE" in *" $name "*|*" all "*)
    log "$name: disabled (LEARN_DISABLE)"; run_event "$name" disabled; SUMMARY="$SUMMARY $name=disabled"; return 0 ;;
  esac
  if [ ! -f "$COMP_DIR/$script" ]; then
    log "$name: $COMP_DIR/$script does not exist; skipped"; run_event "$name" missing; SUMMARY="$SUMMARY $name=missing"; return 0
  fi
  log "$name: start ($script)"
  start=$(date +%s)
  rc=0
  # in the background, so a signal is handled at once (bash runs a trap only after a foreground command ends);
  # exec makes the watchdog's pid the one in CHILD
  CUR=$name
  ( cd "$WORK" && exec perl -e "$_LEARN_LIMITED_PL" "$TMO" /bin/bash "$COMP_DIR/$script" ) </dev/null >>"$LOGF" 2>&1 &
  CHILD=$!
  wait "$CHILD" || rc=$?
  CHILD=""; CUR=""
  secs=$(( $(date +%s) - start ))
  if [ "$rc" -eq 0 ]; then
    # a component can exit 0 and still log a failed model call: take its own learn_run outcome from this run
    local own
    own=$(tail -n 200 "$AGENT_HOME/events.jsonl" 2>/dev/null | jq -r --arg c "$name" --argjson t "$start" \
      'select(.kind == "learn_run" and .data.component == $c and ((.ts | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch 0) >= $t)) | .data.outcome' 2>/dev/null | tail -1 || true)
    case "$own" in ''|ok|nothing-new) own=ok ;; esac
    log "$name: $own (${secs}s)"; SUMMARY="$SUMMARY $name=$own"
  else
    [ "$rc" -ne 142 ] || log "$name: stopped after ${TMO}s (LEARN_COMPONENT_TIMEOUT)"
    log "$name: failed, exit $rc (${secs}s)"
    run_event "$name" error "$(jq -nc --argjson rc "$rc" '{rc: $rc}')"
    SUMMARY="$SUMMARY $name=error"
  fi
}

KIND=nightly; [ "$WEEKLY" = no ] || KIND=weekly
log "learn: $KIND run starts (week $WEEK)"
run_component extract learn-extract.sh
run_component corrections learn-corrections.sh
if [ "$WEEKLY" = yes ]; then
  run_component skills learn-skills.sh
  run_component report learn-report.sh
  # written after the attempt, whatever its outcome: a failing weekly part must not call the model every night
  { rm -f "$STAMP"; printf '%s\n' "$WEEK" >"$STAMP"; } 2>/dev/null || log "learn: cannot write $STAMP"
fi
log "learn: $KIND run done:$SUMMARY"
echo "learn: $KIND run:$SUMMARY"
exit 0
