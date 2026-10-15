#!/usr/bin/env bash
# t_livewatch.sh - tests/live-watch.sh, the silent real-machine check of the launchd watcher, against a fake
# launchctl that replays a recorded `launchctl print` and counts kickstarts.
. "$(dirname "$0")/lib.sh"

LW=$KIT/tests/live-watch.sh
FAKE=$WORK/fake-lc
SCRIPT=$WORK/ching-watch-fake.sh
printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 0\n' >"$SCRIPT"
LOG=$AGENT_HOME/watch.log
: >"$LOG"

# fake launchctl: `print` replays $WORK/print.txt (exit 113 when the file is absent, like a missing job),
# `kickstart` appends to $WORK/lc.calls and raises the recorded `runs` unless $WORK/kick-noop exists.
cat >"$FAKE" <<'EOS'
#!/usr/bin/env bash
w=$(dirname "$0")
printf '%s\n' "$*" >>"$w/lc.calls"
case "${1:-}" in
  print)
    [ -f "$w/print.txt" ] || { echo 'Could not find service in domain' >&2; exit 113; }
    cat "$w/print.txt" ;;
  kickstart)
    if [ ! -e "$w/kick-noop" ] && [ -f "$w/print.txt" ]; then
      n=$(sed -n 's/^	runs = //p' "$w/print.txt")
      sed "s/^	runs = .*/	runs = $((n + 1))/" "$w/print.txt" >"$w/print.new" && mv "$w/print.new" "$w/print.txt"
    fi ;;
esac
EOS
chmod +x "$FAKE"
export LAUNCHCTL=$FAKE

mkprint() { # state runs lastexit [script]
  local state=$1 runs=$2 last=$3 script=${4:-$SCRIPT}
  printf 'gui/501/org.ching.watch = {\n\tactive count = 0\n\tpath = /x/org.ching.watch.plist\n\ttype = LaunchAgent\n\tstate = %s\n\n\tprogram = /bin/bash\n\targuments = {\n\t\t/bin/bash\n\t\t%s\n\t}\n\n\tstdout path = %s\n\tstderr path = %s\n\tenvironment = {\n\t\tAGENT_HOME => %s\n\t}\n\n\truns = %s\n\tlast exit code = %s\n\n\trun interval = 300 seconds\n}\n' \
    "$state" "$script" "$LOG" "$LOG" "$AGENT_HOME" "$runs" "$last" >"$WORK/print.txt"
}
lw() { LIVE_WATCH_KICK_WAIT=2 "$LW" "$@" 2>&1; }   # output of one run; $? of the run is read by the caller via lw_rc
lw_rc() { LIVE_WATCH_KICK_WAIT=2 "$LW" "$@" >/dev/null 2>&1; echo $?; }
now_ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ago_ts() { date -u -v-"$1" +%Y-%m-%dT%H:%M:%SZ; }   # BSD date: ago_ts 30H
put_event() { printf '{"ts":"%s","sid":"s","name":"n","cwd":"/x","kind":"%s","data":{}}\n' "$1" "$2" >>"$AGENT_HOME/events.jsonl"; }

# ---- not loaded
rm -f "$WORK/print.txt"
out=$(lw); rc=$(lw_rc)
assert_eq "not loaded: exit 1" "1" "$rc"
assert_contains "not loaded: says so" "$out" "FAIL: org.ching.watch is not loaded"

# ---- healthy
mkprint "not running" 174 0
put_event "$(now_ts)" context
out=$(lw); rc=$(lw_rc)
assert_eq "healthy: exit 0" "0" "$rc"
assert_contains "healthy: loaded line has state, runs and exit code" "$out" "loaded; state=not running, runs=174, last exit code=0"
assert_contains "healthy: script path is checked" "$out" "ok:   script $SCRIPT"
assert_contains "healthy: empty watch.log is explained" "$out" "watch.log is empty"
assert_contains "healthy: recent watcher event" "$out" "newest watcher event"
assert_not_contains "healthy: no FAIL" "$out" "FAIL:"
assert_contains "healthy: summary" "$out" "live-watch: OK"

# ---- last exit code
mkprint "not running" 5 78
out=$(lw); rc=$(lw_rc)
assert_eq "exit code 78: exit 1" "1" "$rc"
assert_contains "exit code 78: reported" "$out" "FAIL: last exit code is 78"
mkprint "not running" 0 "(never exited)"
out=$(lw); rc=$(lw_rc)
assert_eq "never exited: only a warning" "0" "$rc"
assert_contains "never exited: warned" "$out" "warn: the job has not run yet"

# ---- script missing / broken
mkprint "not running" 3 0 "$WORK/no-such-watch.sh"
out=$(lw); rc=$(lw_rc)
assert_eq "missing script: exit 1" "1" "$rc"
assert_contains "missing script: named" "$out" "FAIL: script $WORK/no-such-watch.sh is not readable"
printf 'if then fi (\n' >"$WORK/broken.sh"
mkprint "not running" 3 0 "$WORK/broken.sh"
out=$(lw); rc=$(lw_rc)
assert_eq "syntax error in script: exit 1" "1" "$rc"
assert_contains "syntax error in script: named" "$out" "FAIL: script $WORK/broken.sh does not parse"
mkprint "running" 3 0
assert_contains "running state is shown" "$(lw)" "state=running"

# ---- watch.log with content is a warning with its tail, not a failure
mkprint "not running" 174 0
printf 'line one\nline two\nline three\nline four\n' >"$LOG"
out=$(lw); rc=$(lw_rc)
assert_eq "watch.log with content: exit 0" "0" "$rc"
assert_contains "watch.log with content: warned" "$out" "warn: watch.log has"
assert_contains "watch.log with content: shows the tail" "$out" "line four"
assert_not_contains "watch.log with content: only the last three lines" "$out" "line one"
: >"$LOG"

# ---- heartbeat: old or no watcher events are warnings (an idle machine has none)
: >"$AGENT_HOME/events.jsonl"
out=$(lw); rc=$(lw_rc)
assert_eq "no events at all: exit 0" "0" "$rc"
assert_contains "no events at all: warned" "$out" "warn: no watcher event"
put_event "$(ago_ts 30H)" context
out=$(lw)
assert_contains "30 h old event: warned with its age" "$out" "warn: newest watcher event is 30 h old"
put_event "$(now_ts)" session_start      # not a watcher event: must not count as a heartbeat
out=$(lw)
assert_contains "other event kinds are not a heartbeat" "$out" "warn: newest watcher event is 30 h old"
put_event "$(ago_ts 1H)" stall
assert_contains "a stall event counts, 1 h old" "$(lw)" "ok:   newest watcher event (stall)"
assert_contains "a zero age limit falls back to the default" "$(LIVE_WATCH_MAX_AGE_H=0 lw)" "ok:   newest watcher event"
assert_contains "bad age limit falls back" "$(LIVE_WATCH_MAX_AGE_H=x lw)" "ok:   newest watcher event"

# ---- default mode is read-only: only `print`, nothing written under AGENT_HOME
: >"$WORK/lc.calls"
before=$(cd "$AGENT_HOME" && find . -type f -exec shasum {} + | sort | shasum)
lw >/dev/null
after=$(cd "$AGENT_HOME" && find . -type f -exec shasum {} + | sort | shasum)
assert_eq "read-only: AGENT_HOME untouched" "$before" "$after"
assert_eq "read-only: launchctl got only print calls" "$(printf 'print')" "$(cut -d' ' -f1 "$WORK/lc.calls" | sort -u | tr '\n' ' ' | sed 's/ $//')"

# ---- --kick: one kickstart without -k, runs must go up
mkprint "not running" 10 0
: >"$WORK/lc.calls"
out=$(lw --kick); rc=$(lw_rc --kick)
assert_eq "kick: exit 0 when runs goes up" "0" "$rc"
assert_contains "kick: runs went up" "$out" "kickstart: runs 10 -> 11"
assert_contains "kick: kickstarted the right job" "$(cat "$WORK/lc.calls")" "kickstart gui/$(id -u)/org.ching.watch"
assert_not_contains "kick: never uses -k (would kill a run in progress)" "$(cat "$WORK/lc.calls")" "kickstart -k"
mkprint "not running" 10 0
touch "$WORK/kick-noop"
out=$(lw --kick); rc=$(lw_rc --kick)
assert_eq "kick: exit 1 when the job did not run" "1" "$rc"
assert_contains "kick: said so" "$out" "FAIL: kickstart did not start a run"
rm -f "$WORK/kick-noop"

# ---- usage
assert_eq "unknown flag: exit 2" "2" "$(lw_rc --bogus)"
exit 0
