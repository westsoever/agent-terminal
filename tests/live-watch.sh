#!/usr/bin/env bash
# live-watch.sh - SILENT, read-only check that the real launchd watcher (org.kaching.watch) is alive (PLAN 1.6.5,
# the real-machine check without ears). It speaks nothing, writes nothing and changes no job. Reports:
#   loaded, state, launchd's run counter and last exit code; the script launchd runs exists and parses;
#   watch.log (empty is normal: the watcher prints nothing on success, errors land there);
#   the newest event only the watcher writes (context, stall, waiting, nudge_spoken) and how old it is.
# `--kick` also starts one extra run (launchctl kickstart WITHOUT -k, so a run in progress is never killed)
# and waits for the `runs` counter to go up: the proof that launchd starts the job right now.
# An idle machine has no sessions and so no watcher events: an old or missing event is a warning, not a failure.
# Not covered, needs a human in the daytime: that the spoken note works from launchd (audio, ioreg, quiet hours).
# Exit: 0 when nothing failed (warnings allowed), 1 on a failure, 2 on bad usage.
# Env: LAUNCHCTL (launchctl) WATCH_LABEL (org.kaching.watch) AGENT_HOME (~/.agent) LIVE_WATCH_MAX_AGE_H (6)
#      LIVE_WATCH_KICK_WAIT (seconds to wait for the counter after --kick, default 15)
set -euo pipefail
LAUNCHCTL=${LAUNCHCTL:-launchctl}
LABEL=${WATCH_LABEL:-org.kaching.watch}
AGENT_HOME=${AGENT_HOME:-$HOME/.agent}
num_or() { case "$1" in ''|*[!0-9]*|0) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac; }
MAX_AGE_H=$(num_or "${LIVE_WATCH_MAX_AGE_H:-}" 6)
KICK_WAIT=$(num_or "${LIVE_WATCH_KICK_WAIT:-}" 15)

KICK=0
case "${1:-}" in
  '') ;;
  --kick) KICK=1 ;;
  *) echo "usage: live-watch.sh [--kick]" >&2; exit 2 ;;
esac

FAILS=0
ok()   { printf 'ok:   %s\n' "$*"; }
warn() { printf 'warn: %s\n' "$*"; }
bad()  { printf 'FAIL: %s\n' "$*"; FAILS=$((FAILS + 1)); }
done_() { # summary line and exit status
  if [ "$FAILS" -eq 0 ]; then echo "live-watch: OK"; else echo "live-watch: $FAILS failure(s)"; fi
  [ "$FAILS" -eq 0 ]
}

TAB=$(printf '\t')
DOMAIN="gui/$(id -u)/$LABEL"
if ! PRINT=$("$LAUNCHCTL" print "$DOMAIN" 2>&1); then
  bad "$LABEL is not loaded (install.sh loads it; launchctl said: $(printf '%s' "$PRINT" | head -1))"
  done_; exit
fi
field() { # top-level `key = value` of launchctl print
  printf '%s\n' "$PRINT" | awk -v k="$1" -v t="$TAB" 'index($0, t k " = ") == 1 { print substr($0, length(t k " = ") + 1); exit }'
}

state=$(field state); runs=$(field runs); last=$(field 'last exit code')
ok "loaded; state=${state:-?}, runs=${runs:-?}, last exit code=${last:-?}"
case "$last" in
  0) ;;
  ''|'(never exited)') warn "the job has not run yet (no exit code recorded)" ;;
  *) bad "last exit code is $last (the watcher exits 0 when it works; run it by hand: /bin/bash <script>)" ;;
esac

# the script is the last `.sh` word of the program arguments
script=$(printf '%s\n' "$PRINT" | awk -v t="$TAB" '
  $0 == t "arguments = {" { a = 1; next }
  a && $0 == t "}" { a = 0 }
  a { sub(/^[ \t]+/, ""); if ($0 ~ /\.sh$/) s = $0 }
  END { print s }')
if [ -z "$script" ] || [ ! -r "$script" ]; then
  bad "script ${script:-<none in the job>} is not readable"
elif ! bash -n "$script" 2>/dev/null; then
  bad "script $script does not parse (bash -n)"
else
  real=$(cd "$(dirname "$script")" && pwd -P)/$(basename "$script")
  ok "script $script (resolves to $real) is readable and parses"
fi

log=$(field 'stderr path')
if [ -n "$log" ] && [ -f "$log" ]; then
  if [ -s "$log" ]; then
    warn "watch.log has $(wc -c <"$log" | tr -d ' ') bytes (updated $(date -r "$(stat -f %m "$log" 2>/dev/null || stat -c %Y "$log")" '+%F %T')); last lines:"
    tail -n 3 "$log" | sed 's/^/        /'
  else
    ok "watch.log is empty (nothing is printed on success; errors would land here)"
  fi
else
  warn "watch.log (${log:-no path in the job}) does not exist yet"
fi

# heartbeat: newest event only the watcher writes
ev_file=$AGENT_HOME/events.jsonl
newest=""; kind=""
if [ -f "$ev_file" ]; then
  line=$(jq -r 'select(.kind == "context" or .kind == "stall" or .kind == "waiting" or .kind == "nudge_spoken") | "\(.ts) \(.kind)"' "$ev_file" 2>/dev/null | sort | tail -n 1 || true)
  newest=${line%% *}; kind=${line##* }
fi
epoch_of() { date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null || true; }
if [ -z "$newest" ]; then
  warn "no watcher event in $ev_file (normal on a machine with no live session)"
else
  e=$(epoch_of "$newest")
  if [ -z "$e" ]; then
    warn "newest watcher event has an unreadable timestamp: $newest"
  else
    age_h=$(( ($(date +%s) - e) / 3600 ))
    if [ "$age_h" -le "$MAX_AGE_H" ]; then ok "newest watcher event ($kind) at $newest, $age_h h old"
    else warn "newest watcher event is $age_h h old ($kind at $newest); expected only when no session was live"; fi
  fi
fi

if [ "$KICK" -eq 1 ]; then
  before=${runs:-0}
  "$LAUNCHCTL" kickstart "$DOMAIN" >/dev/null 2>&1 || true
  after=$before; waited=0
  while [ "$waited" -lt "$KICK_WAIT" ]; do
    PRINT=$("$LAUNCHCTL" print "$DOMAIN" 2>&1 || true)
    after=$(field runs); after=${after:-$before}
    [ "$after" -gt "$before" ] && break
    sleep 1; waited=$((waited + 1))
  done
  if [ "$after" -gt "$before" ]; then ok "kickstart: runs $before -> $after, last exit code=$(field 'last exit code')"
  else bad "kickstart did not start a run within ${KICK_WAIT}s (runs stayed $before; a run already in progress also looks like this)"; fi
fi
done_
