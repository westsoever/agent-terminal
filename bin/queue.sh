#!/usr/bin/env bash
# queue.sh park|back|forget [NAME] | retile | tile | next | status
# The monitor queue: a Terminal window whose session waits for you moves to the main display; when you prompt
# it again it goes back to where it was. The main display holds only your own work plus what waits for you, so
# nothing there but your own windows means every agent is busy. `next` (bind it to a hotkey) brings the waiting
# windows to the front one at a time, oldest first, with the waiting tab selected.
#   park    a session waits (called by notify.sh for done, input, blocked, ready, idle): remember its tab;
#           when its window sits on another display, save the window's frame and move it to the main display,
#           same size (cascaded 32 px per window already there). A window on the main display is never moved
#           (it is one of yours).
#   back    the session was prompted (session-start.sh touch): forget its tab; when no other tab of a parked
#           window still waits, move the window back to exactly the saved frame.
#   forget  the session ended (session-start.sh end): forget its tab and, when nothing else waits there, the
#           parked window too, without moving it.
#   next    raise the next parked waiting window (after the one shown last, wrapping), select its tab, activate
#           Terminal. Prints one line for a Raycast HUD.
#   retile  a session started (session-start.sh): lay out the grid again, in the background.
#   tile    the same now, for a hotkey; prints how many windows moved.
#   status  the waiting tabs and the parked windows.
# Tiling (on unless queue_tile=off): every display but the main one is a grid of the Terminal windows that live
# there, parked ones included: a parked window keeps its cell (empty while it is away) and comes back to it, so
# the grid only changes when a window is opened or closed. 1 fills the display, 2 side by side, 3 in three
# columns, 4 as 2x2, more in ceil(sqrt(n)) columns (see queue-layout.pl). The main display is never laid out
# and park/back never resize. Windows on a hidden desktop or minimised are left alone.
# Focus: moving or tiling never raises a window or takes focus (queue-term.js puts Terminal's front window
# back if it changed); only `next` does, because you asked for it.
# A tab is grouped by its window: workers opened as tabs of the orchestrator's window move together.
# Only Terminal.app windows are handled; a session in another terminal (VS Code, Cursor) has no Terminal tab,
# so every command is a no-op for it. The session's tab is its controlling tty, found by walking up from this
# process to the first ancestor that has one; a run with no tty (the watcher, launchd, claude -p) does nothing.
# park/back/forget find the tty at once, then do the window work in the background so a hook never waits on it.
# Config ($AGENT_HOME/config): queue=off turns it off; queue_tile=off keeps the queue without tiling;
# queue_main_display=NAME picks the main display by (part of) its name, spaces as _ (default: the display with
# the menu bar).
# Env: QUEUE_TERM (the Terminal helper; default osascript -l JavaScript queue-term.js), QUEUE_TTY (skip the
#      tty lookup; "none" = no tty), QUEUE_SYNC=1 (no background fork), AGENT_HOME
set -euo pipefail
[ "${CHING_LEARNER:-}" != 1 ] || exit 0
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

CMD=${1:-status}
NAME_ARG=${2:-}
case "$(config_get queue on | tr '[:upper:]' '[:lower:]')" in off|0|no|false) exit 0 ;; esac
TILE=1
case "$(config_get queue_tile on | tr '[:upper:]' '[:lower:]')" in off|0|no|false) TILE=0 ;; esac

QDIR="$AGENT_HOME/queue"
WAITING="$QDIR/waiting"   # one file per waiting tab: <tty>, holding "<epoch> <name>"
PARKED="$QDIR/parked"     # one file per moved window: <window id>, holding its old frame and when: "x y w h epoch"
mkdir -p "$WAITING" "$PARKED"

term() {
  if [ -n "${QUEUE_TERM:-}" ]; then $QUEUE_TERM "$@"; else osascript -l JavaScript "$SELF_DIR/queue-term.js" "$@"; fi
}

session_tty() { # the controlling tty of the nearest ancestor that has one ('' when none)
  if [ -n "${QUEUE_TTY:-}" ]; then [ "$QUEUE_TTY" = none ] || printf '%s' "$QUEUE_TTY"; return 0; fi
  local p=$$ t i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    t=$(/bin/ps -o tty= -p "$p" 2>/dev/null | tr -d ' ') || return 0
    case "$t" in ''|'??'|-) ;; *) printf '%s' "$t"; return 0 ;; esac
    p=$(/bin/ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ') || return 0
    case "$p" in ''|0|1) return 0 ;; esac
    : "$i"
  done
}

# One queue change at a time (two sessions stopping together would both count the parked windows).
# mkdir is atomic; a lock older than 30 s is from a run that died and is taken over.
lock() {
  local n=0
  until mkdir "$QDIR/.lock" 2>/dev/null; do
    if [ $(( $(date +%s) - $(file_mtime "$QDIR/.lock") )) -gt 30 ]; then rmdir "$QDIR/.lock" 2>/dev/null || true; continue; fi
    n=$((n + 1)); [ "$n" -lt 100 ] || return 1
    sleep 0.1
  done
  trap 'rmdir "$QDIR/.lock" 2>/dev/null || true' EXIT
}

WINDOWS=""   # queue-term.js windows: "id x y w h ttys onscreen", updated in place by relocate
SCREENS=""
load_windows() { WINDOWS=$(term windows 2>/dev/null || true); }
screens() { [ -n "$SCREENS" ] || SCREENS=$(term screens 2>/dev/null || true); printf '%s\n' "$SCREENS"; }
window_of() { # tty -> "id x y w h ttys" of the window holding that tab
  printf '%s\n' "$WINDOWS" | awk -v t="$1" 'NF >= 6 { n = split($6, a, ","); for (i = 1; i <= n; i++) if (a[i] == t) { print; exit } }'
}
others_waiting() { # window line, tty -> true when another tab of that window still waits
  local tt
  for tt in $(printf '%s' "$1" | awk '{ gsub(",", " ", $6); print $6 }'); do
    [ "$tt" != "$2" ] || continue
    [ ! -f "$WAITING/$tt" ] || return 0
  done
  return 1
}

# relocate ID X Y W H: the window goes there. WINDOWS is updated too, so a layout sees it in its new place.
MOVES=""
relocate() {
  WINDOWS=$(printf '%s\n' "$WINDOWS" | awk -v i="$1" -v x="$2" -v y="$3" -v w="$4" -v h="$5" '$1 == i { $2 = x; $3 = y; $4 = w; $5 = h; $7 = 1 } { print }')
  MOVES="$MOVES $1 $2 $3 $4 $5"
}
layout() { # the grid changes: "move id x y w h" and "park id x y w h" lines (see queue-layout.pl)
  local mx my f
  read -r mx my _ <<<"$(main_display)" || true
  { screens | sed 's/^/S /'
    [ -z "${my:-}" ] || printf 'M %s %s\n' "$mx" "$my"
    printf '%s\n' "$WINDOWS" | sed 's/^/W /'
    for f in "$PARKED"/*; do [ -f "$f" ] || continue; printf 'P %s %s\n' "${f##*/}" "$(cut -d' ' -f1-4 "$f")"; done
  } | perl "$SELF_DIR/queue-layout.pl"
}
flush() { # apply the relocations, then (tiling) the grid: moves for shown windows, new cells for parked ones.
  local m=$MOVES out what id x y w h
  MOVES=""
  if [ "$TILE" = 1 ]; then
    out=$(layout)
    m="$m $(printf '%s\n' "$out" | awk '$1 == "move" { print $2, $3, $4, $5, $6 }' | tr '\n' ' ')"
    while read -r what id x y w h; do
      [ "$what" = park ] && [ -f "$PARKED/$id" ] || continue
      printf '%s %s %s %s %s\n' "$x" "$y" "$w" "$h" "$(cut -d' ' -f5 "$PARKED/$id")" >"$PARKED/$id"
    done <<<"$out"
  fi
  # shellcheck disable=SC2086
  if [ -n "${m// /}" ]; then term move $m >/dev/null 2>&1 || true; fi
  printf '%s\n' "$(( $(printf '%s' "$m" | wc -w) / 5 ))"
}

main_display() { # "x y w h" of the main display
  local want s
  want=$(config_get queue_main_display "")
  s=$(screens)
  if [ -n "$want" ]; then
    printf '%s\n' "$s" | awk -v w="$want" 'index(tolower($5), tolower(w)) { print $1, $2, $3, $4; f = 1; exit } END { if (!f) exit 1 }' && return 0
  fi
  printf '%s\n' "$s" | awk 'NF >= 4 { print $1, $2, $3, $4; exit }'
}

do_park() { # tty name
  local tty=$1 win id x y w h mx my mw mh n nx ny
  [ -f "$WAITING/$tty" ] || printf '%s %s\n' "$(date +%s)" "${2:-?}" >"$WAITING/$tty"
  lock || return 0
  load_windows
  win=$(window_of "$tty"); [ -n "$win" ] || return 0
  read -r id x y w h _ <<<"$win" || true
  [ ! -f "$PARKED/$id" ] || return 0
  read -r mx my mw mh <<<"$(main_display)" || true
  [ -n "${mh:-}" ] || return 0
  # already on the main display (its centre is there): one of yours, leave it
  if [ $((x + w / 2)) -ge "$mx" ] && [ $((x + w / 2)) -lt $((mx + mw)) ] && [ $((y + h / 2)) -ge "$my" ] && [ $((y + h / 2)) -lt $((my + mh)) ]; then return 0; fi
  # keep its size (at most the display less a margin) and cascade it 32 px per window already parked
  n=$(find "$PARKED" -type f | wc -l | tr -d ' ')
  [ "$w" -le $((mw - 80)) ] || w=$((mw - 80))
  [ "$h" -le $((mh - 80)) ] || h=$((mh - 80))
  nx=$((mx + 40 + (n % 8) * 32)); ny=$((my + 40 + (n % 8) * 32))
  [ $((nx + w)) -le $((mx + mw)) ] || nx=$((mx + mw - w))
  [ $((ny + h)) -le $((my + mh)) ] || ny=$((my + mh - h))
  printf '%s %s\n' "$(printf '%s' "$win" | awk '{ print $2, $3, $4, $5 }')" "$(date +%s)" >"$PARKED/$id"
  relocate "$id" "$nx" "$ny" "$w" "$h"
  flush >/dev/null
  ev queue_park "$(jq -nc --arg t "$tty" '{tty:$t}')"
}

do_back() { # tty move(1|0)
  local tty=$1 win id
  rm -f "$WAITING/$tty"
  lock || return 0
  load_windows
  win=$(window_of "$tty"); [ -n "$win" ] || return 0
  id=${win%% *}
  [ -f "$PARKED/$id" ] || return 0
  ! others_waiting "$win" "$tty" || return 0
  local old
  old=$(cut -d' ' -f1-4 "$PARKED/$id")
  rm -f "$PARKED/$id"
  # shellcheck disable=SC2086
  if [ "$2" = 1 ]; then relocate "$id" $old; flush >/dev/null; fi
  ev queue_back "$(jq -nc --arg t "$tty" --arg m "$2" '{tty:$t,moved:($m == "1")}')"
}

# Waiting tabs whose window is parked, oldest first: "tty id name". Drops tabs whose window is gone and
# parked records whose window is gone.
pending() {
  local f tty win id
  load_windows
  for f in "$PARKED"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$WINDOWS" | awk -v i="${f##*/}" '$1 == i { f = 1 } END { exit !f }' || rm -f "$f"
  done
  for f in "$WAITING"/*; do
    [ -f "$f" ] || continue
    tty=${f##*/}
    win=$(window_of "$tty")
    if [ -z "$win" ]; then rm -f "$f"; continue; fi
    id=${win%% *}
    [ -f "$PARKED/$id" ] || continue
    printf '%s %s %s\n' "$(cut -d' ' -f1 "$f")" "$tty" "$id $(cut -d' ' -f2- "$f")"
  done | sort -n | cut -d' ' -f2-
}

case "$CMD" in
  park|back|forget|retile)
    TTY=$(session_tty)
    [ -n "$TTY" ] || exit 0
    # the session's name for the HUD (the callers pass theirs; stdin is never read)
    [ -n "$NAME_ARG" ] || NAME_ARG=$(basename "$PWD")
    case "$CMD" in
      park)   job() { do_park "$TTY" "$NAME_ARG"; } ;;
      retile) [ "$TILE" = 1 ] || exit 0; job() { lock || return 0; load_windows; flush >/dev/null; } ;;
      back)   job() { do_back "$TTY" 1; } ;;
      forget) job() { do_back "$TTY" 0; } ;;
    esac
    if [ "${QUEUE_SYNC:-}" = 1 ]; then job; else (job) </dev/null >/dev/null 2>&1 & fi
    exit 0 ;;
  next)
    lock || { echo "Queue busy, try again"; exit 0; }
    list=$(pending)
    if [ -z "$list" ]; then echo "Nothing waiting"; exit 0; fi
    last=$(cat "$QDIR/last" 2>/dev/null || true)
    pick=$(printf '%s\n' "$list" | awk -v l="$last" 'NR == 1 { first = $0 } f { print; found = 1; exit } $1 == l { f = 1 } END { if (!found) print first }' | head -n 1)
    read -r tty id name <<<"$pick" || true
    printf '%s\n' "$tty" >"$QDIR/last"
    term raise "$id" "$tty" >/dev/null 2>&1 || true
    total=$(printf '%s\n' "$list" | wc -l | tr -d ' ')
    if [ "$total" -gt 1 ]; then echo "$name ($((total - 1)) more waiting)"; else echo "$name"; fi ;;
  tile)
    lock || { echo "Queue busy, try again"; exit 0; }
    load_windows
    TILE=1
    n=$(flush)
    if [ "$n" = 1 ]; then echo "Tiled: 1 window moved"; else echo "Tiled: $n windows moved"; fi ;;
  status)
    list=$(pending)
    if [ -z "$list" ]; then echo "nothing waiting"; else printf '%s\n' "$list" | awk '{ printf "%s  %s  (window %s)\n", $3, $1, $2 }'; fi ;;
  *) echo "usage: queue.sh park|back|forget [NAME] | retile | tile | next | status" >&2; exit 2 ;;
esac
exit 0
