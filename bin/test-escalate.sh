#!/usr/bin/env bash
# test-escalate.sh [-C DIR] [--timeout SECS] [--deadline EPOCH] [--report FILE] [-- TEST_COMMAND...]
# Run the tests; spend model tokens only when they fail, starting with the cheapest model.
#   0. run the test command with no model at all; pass -> exit 0
#   1. fail -> ask each model in the ladder, cheapest first, to fix it; re-run the tests after each try
#   2. a model's fix makes the tests pass -> stop (the stronger models are never called)
#   3. the whole ladder fails -> notify "blocked" (unless CHING_TEST_NOTIFY=0), exit with the tests' exit code
# Every test run and every model call runs in a session (process group) of its own with no terminal, stdin
# /dev/null; when its time is up the whole group is killed (TERM, then KILL) and the exit code is 142. No
# model call starts once the caller ($PPID, e.g. stop-check.sh) is gone: nobody would wait for its edits.
#   --report FILE     write the models really called (one line, empty when none) to FILE at the end
#   --timeout SECS    the most one test run may take (0 = no limit of its own)
#   --deadline EPOCH  everything ends by then (stop-check.sh passes its hook deadline). A test run is cut at the
#                     deadline; a model call starts only while 30 s for itself plus the last run's time (for the
#                     re-check) are left, else the ladder ends ("ladder-skip ... reason=deadline" in the log).
# Env: CHING_TEST_MODELS (default "claude-haiku-4-5-20251001 claude-sonnet-5-5", cheapest first)
#      CHING_TEST_BUDGET_USD (per model call, default 0.50) CHING_CLAUDE_BIN (default claude)
#      CHING_TEST_CALL_TIMEOUT (per model call, default 300 s) CHING_TEST_MAX_TURNS (per model call, default 30)
#      CHING_TEST_NOTIFY (1) CHING_TEST_LOG (default $AGENT_HOME/test-escalation.log; a log that cannot be
#      written loses its lines, never the verdict) AGENT_HOME
#      CHING_TEST_LADDER_DAILY (default 6; digits only, 0 = no model at all): the most model calls this script
#      starts per UTC day on the whole machine. The count is $AGENT_HOME/ladder/<YYYY-MM-DD>, checked and
#      incremented before every call. At the limit (or when the count cannot be written) no model is called and
#      the run ends as if no model were configured: the tests' exit code, a ladder-cap line in the log.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

digits() { # value default max_len : the value when it is digits only and not too long, else the default
  case "$1" in ''|*[!0-9]*) echo "$2" ;; *) if [ "${#1}" -le "$3" ]; then echo $((10#$1)); else echo "$2"; fi ;; esac
}
DIR=$PWD; TIMEOUT=0; DEADLINE=0; REPORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    -C) DIR=$2; shift 2 ;;
    --timeout) TIMEOUT=$(digits "${2:-}" 0 6); shift 2 ;;
    --deadline) DEADLINE=$(digits "${2:-}" 0 12); shift 2 ;;
    --report) REPORT=$2; shift 2 ;;
    --) shift; break ;;
    *) break ;;
  esac
done
if [ $# -gt 0 ]; then TEST_CMD=("$@")
elif [ -x "$DIR/tests/run.sh" ]; then TEST_CMD=(tests/run.sh)
else echo "test-escalate: no test command given and no tests/run.sh in $DIR" >&2; exit 2; fi

MODELS=${CHING_TEST_MODELS-claude-haiku-4-5-20251001 claude-sonnet-5-5}   # set but empty = no model
# Recursion guard: a model started below loads the same Stop hook, which would run this script again and
# start more models without end. Children carry CHING_ESCALATING=1 and never start models of their own.
[ -z "${CHING_ESCALATING:-}" ] || MODELS=""
BUDGET=${CHING_TEST_BUDGET_USD:-0.50}
CLAUDE=${CHING_CLAUDE_BIN:-claude}
CALL_TIMEOUT=$(digits "${CHING_TEST_CALL_TIMEOUT:-}" 300 6); [ "$CALL_TIMEOUT" -ge 1 ] || CALL_TIMEOUT=1
TURNS=$(digits "${CHING_TEST_MAX_TURNS:-}" 30 4); [ "$TURNS" -ge 1 ] || TURNS=1
LOG=${CHING_TEST_LOG:-$AGENT_HOME/test-escalation.log}
# The log is for people. One that cannot be written must not end this script: under set -e that turned a
# green check into a failed one (a false block in stop-check.sh). Say so once on stderr and go on.
mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
LOG_WARNED=""
log() {
  if { printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; } 2>/dev/null; then return 0; fi
  [ -n "$LOG_WARNED" ] || echo "test-escalate: cannot write $LOG; its lines are lost" >&2
  LOG_WARNED=1
}

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

# run_limited SECS CMD... : run CMD in a process group of its own. After SECS (0 = no limit) the whole group
# gets TERM, then KILL a second later, and the exit code is 142 (what an alarm gives). A TERM/INT/HUP to the
# runner takes the group down too, so children forked by the command are never left behind.
run_limited() {
  perl -e '
    use POSIX ":sys_wait_h";
    my $t = shift @ARGV;
    my $pid = fork;
    defined $pid or die "fork: $!\n";
    # setsid: a new session is also a new process group, and it has no controlling terminal, so a test that
    # reads the tty fails at once instead of being stopped (SIGTTIN) until the time limit.
    if (!$pid) { POSIX::setsid() or setpgrp(0, 0); exec { $ARGV[0] } @ARGV; print STDERR "exec $ARGV[0]: $!\n"; POSIX::_exit(127); }
    my $reaped = 0;
    my $down = sub {
      kill "TERM", -$pid; kill "TERM", $pid;
      for (1 .. 10) {
        $reaped ||= waitpid($pid, WNOHANG) != 0;
        last if $reaped && !kill(0, -$pid);
        select undef, undef, undef, 0.1;
      }
      kill "KILL", -$pid; kill "KILL", $pid;
      waitpid($pid, 0) unless $reaped;
    };
    $SIG{ALRM} = sub { $down->(); exit 142 };
    $SIG{$_} = sub { $down->(); exit 143 } for qw(TERM INT HUP);
    alarm $t if $t > 0;
    waitpid($pid, 0);
    my $s = $?;
    exit($s & 127 ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}

left() { # seconds until the deadline (a large number when there is none)
  if [ "$DEADLINE" -gt 0 ]; then echo $((DEADLINE - $(date +%s))); else echo 999999; fi
}

OUT=$(mktemp /tmp/ching-test-escalate.XXXXXX)
TRIED=""
# --report FILE gets the models really called (one line, empty when none), whatever the outcome
trap 'rm -f "$OUT"; if [ -n "$REPORT" ]; then printf "%s\n" "$TRIED" >"$REPORT" 2>/dev/null || true; fi' EXIT
RC=0; DUR=0
run_tests() { # step : one test run, cut at --timeout or at the deadline, whichever comes first
  local l lim=$TIMEOUT s
  RC=0; l=$(left)
  if [ "$l" -le 0 ]; then
    RC=142; log "deadline step=$1 (no time left to run the tests)"
    echo "test-escalate: out of time before the $1 run (deadline passed)" >"$OUT"
    return "$RC"
  fi
  if [ "$lim" -eq 0 ] || [ "$lim" -gt "$l" ]; then lim=$l; fi
  s=$(date +%s)
  (cd "$DIR" && run_limited "$lim" "${TEST_CMD[@]}") </dev/null >"$OUT" 2>&1 || RC=$?
  DUR=$(($(date +%s) - s))
  if [ "$RC" -eq 142 ] && [ "$(left)" -le 0 ]; then log "deadline step=$1 (the tests were cut at the deadline)"; fi
  return "$RC"
}

if run_tests check; then log "pass model=none"; echo "tests pass (no model used)"; exit 0; fi

for m in $MODELS; do
  if ! kill -0 "$PPID" 2>/dev/null; then log "ladder-skip model=$m reason=parent-gone"; break; fi
  # A call starts only when it gets at least 30 s and the re-check after it still fits before the deadline.
  lim=$CALL_TIMEOUT; l=$(left); room=$((l - DUR - 5))
  if [ "$room" -lt 30 ]; then
    log "ladder-skip model=$m reason=deadline left=${l}s"
    CWD=$DIR ev ladder_skipped "$(jq -nc --arg m "$m" --argjson l "$l" '{reason:"deadline",model:$m,left:$l}')"
    break
  fi
  [ "$room" -ge "$lim" ] || lim=$room
  ladder_take || break   # no call past the daily ceiling: fall through to the plain "still failing" ending
  TRIED="${TRIED:+$TRIED }$m"
  echo "tests fail; asking $m to fix"
  prompt="The test command \`${TEST_CMD[*]}\` fails in $DIR. Fix the cause with the smallest correct change. Do not edit or delete tests to make them pass. Do not commit. Output of the failing run (last 200 lines):

$(tail -n 200 "$OUT")"
  crc=0
  (cd "$DIR" && run_limited "$lim" env CHING_ESCALATING=1 "$CLAUDE" -p --model "$m" --max-turns "$TURNS" \
    --max-budget-usd "$BUDGET" --no-session-persistence "$prompt" </dev/null >/dev/null 2>&1) || crc=$?
  if [ "$crc" -eq 142 ]; then log "model-timeout model=$m limit=${lim}s"; fi
  if run_tests recheck; then log "pass model=$m"; echo "tests pass after fix by $m"; exit 0; fi
  log "fail model=$m"
done

log "blocked ladder=[$TRIED]"
if [ -n "$TRIED" ] && [ "${CHING_TEST_NOTIFY:-1}" = 1 ]; then
  "$SELF_DIR/notify.sh" blocked "Tests still failing after: $TRIED" </dev/null >/dev/null 2>&1 || true
fi
echo "tests still fail (models tried: ${TRIED:-none})" >&2
tail -n 40 "$OUT" >&2
exit "$RC"
