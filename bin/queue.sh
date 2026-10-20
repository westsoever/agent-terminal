#!/usr/bin/env bash
# queue.sh park|back|forget [NAME] | retile | tile | dragged ID X Y W H | show SESSION_ID | dismiss SESSION_ID |
#          return SESSION_ID | next | status
# The monitor queue: a Terminal window whose session waits for you moves to the main display; when you prompt
# it again it goes back to where it was. The main display holds only your own work plus what waits for you, so
# nothing there but your own windows means every agent is busy. `next` (bind it to a hotkey) brings the waiting
# windows to the front one at a time, oldest first, with the waiting tab selected.
#   park    a session waits (called by notify.sh for done, input, blocked, ready, idle): remember its tab.
#           When agent-terminal is closed and the kind is not idle, its window comes over: the window's frame is saved
#           and it moves to the main display into the park frame (queue_park_frame; all parked windows share it,
#           a stack). Only the window whose own event fired comes over, never a backlog (D38). A window on the
#           main display is never moved (it is one of yours). With agent-terminal open nothing moves (D37).
#   back    the session was prompted (session-start.sh touch): forget its tab; when no other tab of a parked
#           window still waits, move the window back to exactly the saved frame. That includes a window you
#           brought over by hand (show / h, or a drag) and holds while agent-terminal is open (D43).
#   forget  the session ended (session-start.sh end): forget its tab and, when nothing else waits there, the
#           parked window too, without moving it.
#   next    raise the next waiting tab's window wherever it is (after the one shown last, wrapping, oldest
#           first), select the tab, activate Terminal. Prints one line for a Raycast HUD.
#   dragged the menu bar app saw window ID change display by hand; X Y W H is its frame before. Onto the main
#           display: it takes the park frame and its cell stays reserved; it stays until you drag it back or
#           its session is prompted (D43). Back onto the other display: into exactly its reserved cell. Any
#           other window put on the other display joins the grid (D38).
#   show    put that agent's window on the main display now, as if dragged there.
#   return  agent-terminal sent that agent an answer: a window the queue moved to the main display (by its event, show
#           or a drag) goes back to its cell, also while agent-terminal is open; not while another tab of it waits (D42).
#   retile  a session started (session-start.sh): lay out the grid again, in the background.
#   tile    the same now, for a hotkey; prints how many windows moved.
#   status  the waiting tabs and the parked windows.
# Config ($AGENT_HOME/config): queue=off turns it off; queue_tile=off keeps the queue without tiling;
# queue_park_frame=X,Y,W,H is where a parked window goes on the main display, X,Y from the display's top-left
# corner (default 320,70,690,948; off = keep its size, cascaded);
# queue_main_display=NAME picks the main display by (part of) its name, spaces as _ (default: the display with
# the menu bar).
# Env: QUEUE_TERM (the Terminal helper; default osascript -l JavaScript queue-term.js), QUEUE_TTY (skip the
#      tty lookup; "none" = no tty), QUEUE_SYNC=1 (no background fork), AGENT_HOME
set -euo pipefail
# Tiling (on unless queue_tile=off): every display but the main one is a grid of the Terminal windows that live
# there, parked ones included: a parked window keeps its cell (empty while it is away) and comes back to it, so
# the grid only changes when a window is opened or closed. 1 fills the display, 2 side by side, 3 in three
# columns, 4 as 2x2, more in ceil(sqrt(n)) columns (see queue-layout.pl). The main display is never laid out
# and back never resizes (it restores the exact cell). Windows on a hidden desktop or minimised are left alone.
# Focus: moving or tiling never raises a window or takes focus (queue-term.js puts Terminal's front window
# back if it changed); only `next` does, because you asked for it.
# A tab is grouped by its window: workers opened as tabs of the orchestrator's window move together.
# Only Terminal.app windows are handled; a session in another terminal (VS Code, Cursor) has no Terminal tab,
# so every command is a no-op for it. The session's tab is its controlling tty, found by walking up from this
# process to the first ancestor that has one; a run with no tty (the watcher, launchd, claude -p) does nothing.
# park/back/forget find the tty at once, then do the window work in the background so a hook never waits on it.
[ "${AGENT_TERMINAL_LEARNER:-${KACHING_LEARNER:-${CHING_LEARNER:-}}}" != 1 ] || exit 0
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

CMD=${1:-status}
NAME_ARG=${2:-}
case "$(config_get queue on | tr '[:upper:]' '[:lower:]')" in off|0|no|false) exit 0 ;; esac
TILE=1
case "$(config_get queue_tile on | tr '[:upper:]' '[:lower:]')" in off|0|no|false) TILE=0 ;; esac

QDIR="$AGENT_HOME/queue"
WAITING="$QDIR/waiting"   # one file per waiting tab: <tty>, holding "epoch session_id kind name" (name may hold spaces)
PARKED="$QDIR/parked"     # one file per moved window: <window id>, holding its old frame, when and how:
                          # "x y w h epoch auto|hand" (hand: dragged over by you; a drag back or a prompt sends it back)
COME="$QDIR/come"         # one file per tab whose own park event may bring its window over: <tty>
TABS="$QDIR/tabs"         # one file per Terminal session: <session id>, holding "tty window_id tab_index name"
mkdir -p "$WAITING" "$PARKED" "$TABS" "$COME"

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

# One queue change at a time (two sessions stopping together would both count the parked windows). An flock (lib.sh
# lock_fd9): held until this run exits, dropped by the kernel if it dies. 30 s covers the slowest retile.
lock() { lock_fd9 "$QDIR/.queue.lock" 30; }

WINDOWS=""   # queue-term.js windows: "id x y w h ttys onscreen", updated in place by relocate
SCREENS=""
load_windows() { WINDOWS=$(term windows 2>/dev/null || true); screens >/dev/null; }   # screens here: later calls run in $(...) and could not fill the cache
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
      printf '%s %s %s %s %s\n' "$x" "$y" "$w" "$h" "$(cut -d' ' -f5- "$PARKED/$id")" >"$PARKED/$id"
    done <<<"$out"
  fi
  # shellcheck disable=SC2086
  if [ -n "${m// /}" ]; then term move $m >/dev/null 2>&1 || true; fi
  printf '%s\n' "$(( $(printf '%s' "$m" | wc -w) / 5 ))"
}

main_display() { # "x y w h fx fy" of the main display: visible frame, then its own top-left corner
  local want s
  want=$(config_get queue_main_display "")
  s=$(screens)
  if [ -n "$want" ]; then
    printf '%s\n' "$s" | awk -v w="$want" 'index(tolower($5), tolower(w)) { print $1, $2, $3, $4, ($6 == "" ? $1 : $6), ($7 == "" ? $2 : $7); f = 1; exit } END { if (!f) exit 1 }' && return 0
  fi
  printf '%s\n' "$s" | awk 'NF >= 4 { print $1, $2, $3, $4, ($6 == "" ? $1 : $6), ($7 == "" ? $2 : $7); exit }'
}

park_target() { # window line -> "x y w h" on the main display: the park frame, or its size cascaded
  local x y w h mx my mw mh fx fy n nx ny frame px py pw ph
  read -r _ x y w h _ <<<"$1" || true
  read -r mx my mw mh fx fy <<<"$(main_display)" || true
  # the park frame: x,y from the display's own top-left corner (what the screenshot crosshair shows), w,h;
  # every parked window gets the same frame, a stack that `next` goes through. off: keep the window's size
  # and cascade it 32 px per window already parked.
  frame=$(config_get queue_park_frame "320,70,690,948")
  IFS=, read -r px py pw ph <<<"$frame" || true
  if [[ "$frame" =~ ^[0-9]{1,5},[0-9]{1,5},[0-9]{1,5},[0-9]{1,5}$ ]] && [ $((10#$pw)) -gt 0 ] && [ $((10#$ph)) -gt 0 ]; then
    nx=$(( ${fx:-$mx} + 10#$px )); ny=$(( ${fy:-$my} + 10#$py )); w=$((10#$pw)); h=$((10#$ph))
    [ "$ny" -ge "$my" ] || ny=$my
  else
    n=$(find "$PARKED" -type f | wc -l | tr -d ' ')
    nx=$((mx + 40 + (n % 8) * 32)); ny=$((my + 40 + (n % 8) * 32))
  fi
  # never larger than the display, never past its edges
  [ "$w" -le "$mw" ] || w=$mw
  [ "$h" -le "$mh" ] || h=$mh
  [ $((nx + w)) -le $((mx + mw)) ] || nx=$((mx + mw - w))
  [ $((ny + h)) -le $((my + mh)) ] || ny=$((my + mh - h))
  printf '%s %s %s %s\n' "$nx" "$ny" "$w" "$h"
}

yours() { # window line -> true when it sits on the main display and is not parked: your own, never moved
  local id x y w h mx my mw mh
  read -r id x y w h _ <<<"$1" || true
  [ ! -f "$PARKED/$id" ] || return 1
  read -r mx my mw mh _ <<<"$(main_display)" || true
  [ -n "${mh:-}" ] || return 1
  [ $((x + w / 2)) -ge "$mx" ] && [ $((x + w / 2)) -lt $((mx + mw)) ] && [ $((y + h / 2)) -ge "$my" ] && [ $((y + h / 2)) -lt $((my + mh)) ]
}

prune() { # drop waiting tabs and parked windows that no longer exist
  local f
  for f in "$PARKED"/*; do
    [ -f "$f" ] || continue
    printf '%s\n' "$WINDOWS" | awk -v i="${f##*/}" '$1 == i { f = 1 } END { exit !f }' || rm -f "$f"
  done
  for f in "$WAITING"/*; do
    [ -f "$f" ] || continue
    [ -n "$(window_of "${f##*/}")" ] || rm -f "$f"
  done
}

waiting_windows() { # ids of the windows with a waiting tab, oldest wait first, each once; never one of yours
  local g win seen=" "
  for g in "$WAITING"/*; do [ -f "$g" ] || continue; printf '%s %s\n' "$(cut -d' ' -f1 "$g")" "${g##*/}"; done | sort -n |
  while read -r _ tty; do
    win=$(window_of "$tty")
    [ -n "$win" ] || continue
    case "$seen" in *" ${win%% *} "*) continue ;; esac
    ! yours "$win" || continue
    seen="$seen${win%% *} "
    printf '%s\n' "${win%% *}"
  done
}

# agterm, the agent terminal, is open: $AGENT_HOME/terminal/open holds pid= (alive) and tty= (the agent selected)
open_get() { sed -n "s/^$1=//p" "$AGENT_HOME/terminal/open" 2>/dev/null | head -n 1; }
single_mode() {
  local pid
  pid=$(open_get pid)
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null
}

# reconcile: move windows so the main display holds what it should now, then flush (the grid comes along).
#   agent-terminal open (D37): nothing comes over or goes back on its own; agent-terminal's list is the inbox. The grid
#           on the other displays is still laid out (D68), and a move already asked for (send_back) is applied.
#   agent-terminal closed: the windows with a waiting tab whose own park event asked to come (come/<tty>) are parked;
#           a window parked that way goes back to its cell once none of its tabs wants it. A window you dragged
#           over (hand) is not sent back here: only a drag back or a prompt of its session (send_back) moves it.
# A window that is wanted and not parked is parked; an auto-parked window that is not wanted goes back.
reconcile() {
  local want="" win f id target t
  [ -n "$(main_display)" ] || return 0
  prune
  if single_mode; then flush >/dev/null; return 0; fi
  for f in "$COME"/*; do
    [ -f "$f" ] || continue
    t=${f##*/}
    [ -f "$WAITING/$t" ] || { rm -f "$f"; continue; }
    win=$(window_of "$t")
    [ -n "$win" ] || continue
    ! yours "$win" || continue
    want="$want ${win%% *}"
  done
  want=" $want "
  for f in "$PARKED"/*; do
    [ -f "$f" ] || continue
    id=${f##*/}
    case "$want" in *" $id "*) continue ;; esac
    [ "$(cut -d' ' -f6 "$f")" != hand ] || continue
    # shellcheck disable=SC2046
    relocate "$id" $(cut -d' ' -f1-4 "$f")
    rm -f "$f"
    ev queue_back "$(jq -nc --arg w "$id" '{window:$w}')"
  done
  for id in $want; do
    [ ! -f "$PARKED/$id" ] || continue
    park_window "$id" auto
  done
  flush >/dev/null
}

park_window() { # id auto|hand [x y w h: the cell to keep, default where it is now]: into the park frame
  local id=$1 win target cell
  win=$(printf '%s\n' "$WINDOWS" | awk -v i="$id" '$1 == i { print; exit }')
  [ -n "$win" ] || return 0
  cell=${3:+$3 $4 $5 $6}
  [ -n "$cell" ] || cell=$(printf '%s' "$win" | awk '{ print $2, $3, $4, $5 }')
  target=$(park_target "$win")   # before the record: the cascade counts the windows already parked
  printf '%s %s %s\n' "$cell" "$(date +%s)" "$2" >"$PARKED/$id"
  # shellcheck disable=SC2086
  relocate "$id" $target
  ev queue_park "$(jq -nc --arg w "$id" --arg h "$2" '{window:$w,how:$h}')"
}

# send_back TTY HOW: the session of TTY was prompted or answered, so its window, when the queue moved it to the
# main display (its own event, show / h, or a drag), goes back to exactly its cell, also while agent-terminal is open:
# it is the owner's own action (D42, D43). Not while another tab of that window still waits. Prints what it did.
send_back() {
  local win id
  win=$(window_of "$1")
  id=${win%% *}
  if [ -z "$win" ] || [ ! -f "$PARKED/$id" ]; then echo "Not parked"; return 0; fi
  if others_waiting "$win" "$1"; then echo "Another tab waits"; return 0; fi
  # shellcheck disable=SC2046
  relocate "$id" $(cut -d' ' -f1-4 "$PARKED/$id")
  rm -f "$PARKED/$id" "$COME/$1"
  ev queue_back "$(jq -nc --arg w "$id" --arg h "$2" '{window:$w,how:$h}')"
  echo "Returned"
}

on_main() { # x y w h -> true when that frame's centre is on the main display
  local mx my mw mh
  read -r mx my mw mh _ <<<"$(main_display)" || true
  [ -n "${mh:-}" ] || return 1
  [ $(($1 + $3 / 2)) -ge "$mx" ] && [ $(($1 + $3 / 2)) -lt $((mx + mw)) ] && [ $(($2 + $4 / 2)) -ge "$my" ] && [ $(($2 + $4 / 2)) -lt $((my + mh)) ]
}

# dragged ID X Y W H: window ID changed display by hand (the menu bar app watches); X Y W H is where it was.
do_dragged() {
  local id=$1 win x y w h
  win=$(printf '%s\n' "$WINDOWS" | awk -v i="$id" '$1 == i { print; exit }')
  [ -n "$win" ] || return 0
  read -r _ x y w h _ <<<"$win" || true
  if on_main "$x" "$y" "$w" "$h"; then
    # onto the main display: a window the queue parked is already where it belongs; one that came from
    # another display takes the park frame and keeps that cell reserved
    [ ! -f "$PARKED/$id" ] || return 0
    on_main "$2" "$3" "$4" "$5" && return 0
    park_window "$id" hand "$2" "$3" "$4" "$5"
  elif [ -f "$PARKED/$id" ]; then
    # back onto the other display: exactly into its reserved cell
    # shellcheck disable=SC2046
    relocate "$id" $(cut -d' ' -f1-4 "$PARKED/$id")
    rm -f "$PARKED/$id"
    ev queue_back "$(jq -nc --arg w "$id" '{window:$w,how:"hand"}')"
  fi
  # anything put on the other display joins the grid (no-op for a window already in its cell)
  flush >/dev/null
}

# register TTY: tabs/<session id> = "tty window_id tab_index name" for every Terminal session (agent-terminal reads it).
register() {
  [ -n "${QUEUE_SID:-}" ] || return 0
  local win idx tmp
  win=$(window_of "$1"); [ -n "$win" ] || return 0
  idx=$(printf '%s' "$win" | awk -v t="$1" '{ n = split($6, a, ","); for (i = 1; i <= n; i++) if (a[i] == t) print i }')
  mkdir -p "$TABS"
  tmp="$TABS/.$QUEUE_SID.$$"
  printf '%s %s %s %s\n' "$1" "${win%% *}" "${idx:-1}" "${QUEUE_NAME:-?}" >"$tmp" && mv -f "$tmp" "$TABS/$QUEUE_SID"
}

mark_waiting() { # tty: waiting/<tty> = "epoch session_id kind name"; a tab already waiting keeps its epoch
  local since
  since=$(cut -d' ' -f1 "$WAITING/$1" 2>/dev/null || true)
  case "$since" in ''|*[!0-9]*) since=$(date +%s) ;; esac
  printf '%s %s %s %s\n' "$since" "${QUEUE_SID:--}" "${QUEUE_KIND:-done}" "${QUEUE_NAME:-?}" >"$WAITING/$1"
}

tty_of_sid() { # session id -> its tty (tabs map, else a waiting record that names it)
  local f
  case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 0 ;; esac
  if [ -f "$TABS/$1" ]; then cut -d' ' -f1 "$TABS/$1"; return 0; fi
  for f in "$WAITING"/*; do [ -f "$f" ] || continue; [ "$(cut -d' ' -f2 "$f")" != "$1" ] || { printf '%s' "${f##*/}"; return 0; }; done
}

# Waiting tabs, oldest first, wherever their window is: "tty id name".
pending() {
  local f tty win id
  load_windows
  prune
  for f in "$WAITING"/*; do
    [ -f "$f" ] || continue
    tty=${f##*/}
    win=$(window_of "$tty")
    id=${win%% *}
    [ -n "$id" ] || continue
    printf '%s %s %s %s\n' "$(cut -d' ' -f1 "$f")" "$tty" "$id" "$(cut -d' ' -f4- "$f")"
  done | sort -n | cut -d' ' -f2-
}

case "$CMD" in
  park|back|forget|retile)
    TTY=$(session_tty)
    [ -n "$TTY" ] || exit 0
    # the session's name for the HUD (the callers pass theirs; stdin is never read)
    [ -n "$NAME_ARG" ] || NAME_ARG=${QUEUE_NAME:-$(basename "$PWD")}
    QUEUE_NAME=$NAME_ARG
    case "${QUEUE_SID:-}" in .*|*[!A-Za-z0-9._-]*) QUEUE_SID="" ;; esac
    case "$CMD" in
      park)   job() { mark_waiting "$TTY"
                      # its own event, agent-terminal closed, not the idle reminder: this window may come over (D38)
                      if ! single_mode && [ "${QUEUE_KIND:-done}" != idle ]; then : >"$COME/$TTY"; fi
                      lock || return 0; load_windows; register "$TTY"; reconcile; } ;;
      back)   job() { rm -f "$WAITING/$TTY" "$COME/$TTY"; lock || return 0; load_windows; register "$TTY"
                      send_back "$TTY" prompted >/dev/null; reconcile; } ;;
      retile) job() { lock || return 0; load_windows; register "$TTY"; reconcile; } ;;
      forget) job() { # the session ended: its tab leaves the queue; a parked window with nothing else waiting
                      # stays where it is (it is yours now)
                local win
                rm -f "$WAITING/$TTY" "$COME/$TTY"; [ -z "${QUEUE_SID:-}" ] || rm -f "$TABS/$QUEUE_SID"
                lock || return 0; load_windows
                win=$(window_of "$TTY")
                if [ -n "$win" ] && ! others_waiting "$win" "$TTY"; then rm -f "$PARKED/${win%% *}"; fi
                reconcile; } ;;
    esac
    if [ "${QUEUE_SYNC:-}" = 1 ]; then job; else (job) </dev/null >/dev/null 2>&1 & fi
    exit 0 ;;
  return)
    # return SESSION_ID: agent-terminal answered the agent; its parked window goes back to its cell (D42). Moving it is
    # the owner's own action, so agent-terminal being open does not stop it.
    [ -n "$NAME_ARG" ] || { echo "usage: queue.sh return SESSION_ID" >&2; exit 2; }
    tty=$(tty_of_sid "$NAME_ARG")
    if [ -z "$tty" ]; then echo "Unknown session: $NAME_ARG"; exit 0; fi
    lock || { echo "Queue busy, try again"; exit 0; }
    load_windows
    send_back "$tty" answered
    flush >/dev/null ;;
  show|dismiss)
    # show SESSION_ID: put that agent's window on the main display now, as if you dragged it there.
    # dismiss SESSION_ID: take the agent out of the queue without an answer; a window the queue brought over
    #   goes back to its cell (agent-terminal closed).
    SID_ARG=$NAME_ARG
    if [ -z "$SID_ARG" ]; then echo "usage: queue.sh $CMD SESSION_ID" >&2; exit 2; fi
    tty=$(tty_of_sid "$SID_ARG")
    if [ -z "$tty" ]; then echo "Unknown session: $SID_ARG"; exit 0; fi
    lock || { echo "Queue busy, try again"; exit 0; }
    load_windows
    if [ "$CMD" = dismiss ]; then
      name=$(cut -d' ' -f4- "$WAITING/$tty" 2>/dev/null || true)
      rm -f "$WAITING/$tty" "$COME/$tty"
      reconcile
      echo "Dismissed ${name:-$SID_ARG}"
    else
      win=$(window_of "$tty")
      if [ -n "$win" ] && [ ! -f "$PARKED/${win%% *}" ] && ! yours "$win"; then park_window "${win%% *}" hand; flush >/dev/null; fi
      echo "Shown"
    fi ;;
  dragged)
    # shellcheck disable=SC2154
    case "${2:-}${3:-}${4:-}${5:-}${6:-}" in ''|*[!0-9-]*) echo "usage: queue.sh dragged ID X Y W H" >&2; exit 2 ;; esac
    lock || exit 0
    load_windows
    do_dragged "$2" "$3" "$4" "$5" "$6" ;;
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
    if [ -z "$list" ]; then echo "nothing waiting"; else printf '%s\n' "$list" | awk '{ n = $3; for (i = 4; i <= NF; i++) n = n " " $i; printf "%s  %s  (window %s)\n", n, $1, $2 }'; fi ;;
  *) echo "usage: queue.sh park|back|forget [NAME] | retile | tile | dragged ID X Y W H | show SESSION_ID | dismiss SESSION_ID | return SESSION_ID | next | status" >&2; exit 2 ;;
esac
exit 0
