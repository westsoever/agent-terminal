#!/usr/bin/env bash
# queue.sh: park moves a window from the other display to the main one and back on the next prompt; tabs of one
# window move together; a window on the main display is never moved; next cycles oldest first; queue=off.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake Terminal: windows from $FT/windows ("id x y w h ttys [onscreen]", onscreen 1 when left out), every
# call logged, move rewrites the frames.
FT="$WORK/fake-term"; mkdir -p "$FT"
cat >"$FT/term" <<'EOS'
#!/usr/bin/env bash
d=$(dirname "$0"); printf '%s\n' "$*" >>"$d/calls"
case "$1" in
  screens) printf '0 30 1920 992 DELL_P2425H 0 0\n1920 -67 1920 1080 SA240Y 1920 -67\n' ;;
  windows) awk 'NF == 6 { $7 = 1 } { print }' "$d/windows" ;;
  move) shift
        while [ $# -ge 5 ]; do
          awk -v i="$1" -v x="$2" -v y="$3" -v w="$4" -v h="$5" '$1 == i { $2 = x; $3 = y; $4 = w; $5 = h } { print }' "$d/windows" >"$d/w.tmp" && mv "$d/w.tmp" "$d/windows"
          shift 5
        done ;;
esac
EOS
chmod +x "$FT/term"
export QUEUE_TERM="$FT/term" QUEUE_SYNC=1
Q="$BIN/queue.sh"
QD="$AGENT_HOME/queue"
reset() { printf '%s\n' "$@" >"$FT/windows"; : >"$FT/calls"; rm -f "$QD"/waiting/* "$QD"/parked/* "$QD/last"; }
win() { awk -v i="$1" '$1 == i { print $2, $3, $4, $5 }' "$FT/windows"; }
mkdir -p "$QD/waiting" "$QD/parked"
# the park frame is off (same size, cascaded) unless a test sets it: the last assignment wins
setcfg() { printf '%s\n' queue_park_frame=off "$@" >"$AGENT_HOME/config"; }
# the queue without tiling first; tiling (the default) is tested at the end
setcfg queue_tile=off

# park: a window on the other display moves to the main one, keeping its size; back restores it
reset "11 2879 484 961 529 ttys003" "12 0 30 961 979 ttys001"
QUEUE_TTY=ttys003 "$Q" park worker
assert_eq "park moves the window to the main display" "40 70 961 529" "$(win 11)"
assert_eq "park saves the old frame" "2879 484 961 529" "$(cut -d' ' -f1-4 "$QD/parked/11")"
QUEUE_TTY=ttys003 "$Q" park worker
assert_eq "a second park of a parked window moves nothing" "1" "$(grep -c '^move' "$FT/calls")"
QUEUE_TTY=ttys003 "$Q" back
assert_eq "back restores the old frame" "2879 484 961 529" "$(win 11)"
assert_eq "back forgets the parked window" "" "$(ls "$QD/parked")"

# a window already on the main display is yours: never moved, never queued for next
QUEUE_TTY=ttys001 "$Q" park main
assert_eq "main-display window is not moved" "0 30 961 979" "$(win 12)"
assert_eq "next: a waiting tab on the main display is raised too" "main" "$("$Q" next)"

# tabs of one window move together and stay until no tab waits
reset "21 1920 -37 961 1043 ttys010,ttys011,ttys012"
QUEUE_TTY=ttys011 "$Q" park w1
QUEUE_TTY=ttys012 "$Q" park w2
assert_eq "grouped window parked once" "1" "$(grep -c '^move' "$FT/calls")"
assert_eq "a tall window is clamped to the display" "40 30 961 992" "$(win 21)"
QUEUE_TTY=ttys011 "$Q" back
assert_eq "stays parked while another tab waits" "40 30 961 992" "$(win 21)"
QUEUE_TTY=ttys012 "$Q" back
assert_eq "goes back when no tab waits" "1920 -37 961 1043" "$(win 21)"

# next: oldest first, cycles, selects the waiting tab; cascade offsets the second window
reset "31 2000 100 800 500 ttys020" "32 2100 200 800 500 ttys021,ttys022"
QUEUE_TTY=ttys020 "$Q" park first
sleep 1
QUEUE_TTY=ttys022 "$Q" park second
assert_eq "second parked window cascades" "72 102 800 500" "$(win 32)"
assert_eq "next: oldest first, with the count" "first (1 more waiting)" "$("$Q" next)"
assert_contains "next raises the window and tab" "$(cat "$FT/calls")" "raise 31 ttys020"
assert_eq "next again: the following one" "second (1 more waiting)" "$("$Q" next)"
assert_contains "next selects the waiting tab of a grouped window" "$(cat "$FT/calls")" "raise 32 ttys022"
assert_eq "next wraps around" "first (1 more waiting)" "$("$Q" next)"

# forget (session ended): the tab leaves the queue, the window stays where it is
QUEUE_TTY=ttys020 "$Q" forget
assert_eq "forget does not move the window" "40 70 800 500" "$(win 31)"
assert_eq "forget drops it from next" "second" "$("$Q" next)"

# a closed window drops out of the queue
reset "41 2000 100 800 500 ttys030"
QUEUE_TTY=ttys030 "$Q" park gone
printf '' >"$FT/windows"
assert_eq "closed window: nothing waiting" "Nothing waiting" "$("$Q" next)"
assert_eq "closed window: records pruned" "" "$(find "$QD/waiting" "$QD/parked" -type f)"

# no tty (watcher, launchd, claude -p, VS Code): nothing happens
reset "51 2000 100 800 500 ttys040"
QUEUE_TTY=none "$Q" park x
assert_eq "no tty: no Terminal call" "" "$(cat "$FT/calls")"

# queue_main_display picks the other display by name
reset "61 0 30 800 500 ttys050"
setcfg queue_tile=off queue_main_display=sa240
QUEUE_TTY=ttys050 "$Q" park x
assert_eq "queue_main_display: parks onto the named display" "1960 -27 800 500" "$(win 61)"

# queue=off: does nothing
reset "71 2000 100 800 500 ttys060"
setcfg queue=off
QUEUE_TTY=ttys060 "$Q" park x
assert_eq "queue=off: no Terminal call" "" "$(cat "$FT/calls")"
setcfg queue_tile=off

# hooks: notify.sh parks for a waiting kind, not for a budget alert; session-start.sh touch brings it back
R=$(mk_repo queuerepo)
reset "81 2000 100 800 500 ttys070"
printf '%s' "$(hook_json Notification "$R" q1)" | QUEUE_TTY=ttys070 "$BIN/notify.sh" tokens
assert_eq "notify tokens: not parked" "2000 100 800 500" "$(win 81)"
printf '%s' "$(hook_json Notification "$R" q1)" | QUEUE_TTY=ttys070 "$BIN/notify.sh" input "Which one?"
assert_eq "notify input: parked" "40 70 800 500" "$(win 81)"
assert_contains "the HUD name is the repo" "$("$Q" status)" "queuerepo"
printf '%s' "$(hook_json UserPromptSubmit "$R" q1)" | QUEUE_TTY=ttys070 "$BIN/session-start.sh" touch
assert_eq "prompt: back on its display" "2000 100 800 500" "$(win 81)"

# ---------- tiling (the default) ----------
setcfg ""
moves() { grep -c '^move' "$FT/calls"; }
# four on the other display: a 2x2 grid in reading order; the main display is never laid out
reset "90 100 100 700 500 ttys079" "91 1950 -50 800 400 ttys080" "92 2900 -50 800 400 ttys081" \
      "93 1950 500 800 400 ttys082" "94 2900 500 800 400 ttys083"
assert_eq "tile: four windows moved" "Tiled: 4 windows moved" "$("$Q" tile)"
assert_eq "2x2: top left" "1920 -67 960 540" "$(win 91)"
assert_eq "2x2: top right" "2880 -67 960 540" "$(win 92)"
assert_eq "2x2: bottom left" "1920 473 960 540" "$(win 93)"
assert_eq "2x2: bottom right" "2880 473 960 540" "$(win 94)"
assert_eq "main display: your window untouched" "100 100 700 500" "$(win 90)"
assert_eq "tile again: nothing to move" "Tiled: 0 windows moved" "$("$Q" tile)"

# park: the bottom-left one comes over at its own size; the other three keep their cells, its cell stays empty
: >"$FT/calls"
QUEUE_TTY=ttys082 "$Q" park w
assert_eq "park: same size on the main display" "40 70 960 540" "$(win 93)"
assert_eq "park: only the parked window moves" "move 93 40 70 960 540" "$(grep '^move' "$FT/calls")"
assert_eq "park: the others keep their cells" "2880 473 960 540" "$(win 94)"
QUEUE_TTY=ttys082 "$Q" back
assert_eq "back: exactly its old cell" "1920 473 960 540" "$(win 93)"

# a window closed while another is parked: the grid shrinks and the parked one's cell moves with it
QUEUE_TTY=ttys082 "$Q" park w
awk '$1 != 92' "$FT/windows" >"$FT/w.tmp" && mv "$FT/w.tmp" "$FT/windows"
QUEUE_TTY=ttys080 "$Q" retile
assert_eq "3 left: three columns, first" "1920 -67 640 1080" "$(win 91)"
assert_eq "3 left: the parked one stays on the main display" "40 70 960 540" "$(win 93)"
assert_eq "3 left: the parked one's new cell is saved" "2560 -67 640 1080" "$(cut -d' ' -f1-4 "$QD/parked/93")"
assert_eq "3 left: third column" "3200 -67 640 1080" "$(win 94)"
QUEUE_TTY=ttys082 "$Q" back
assert_eq "back: into its new cell" "2560 -67 640 1080" "$(win 93)"

# a fifth window opened: 3 on top, 2 below, and every window keeps its corner
reset "151 1920 -67 960 540 ttys140" "152 2880 -67 960 540 ttys141" "153 1920 473 960 540 ttys142" \
      "154 2880 473 960 540 ttys143" "155 2600 200 700 400 ttys144"
"$Q" tile >/dev/null
assert_eq "grow to 5: top left stays top left" "1920 -67 640 540" "$(win 151)"
assert_eq "grow to 5: top right stays top right" "3200 -67 640 540" "$(win 152)"
assert_eq "grow to 5: bottom left stays bottom left" "1920 473 960 540" "$(win 153)"
assert_eq "grow to 5: bottom right stays bottom right" "2880 473 960 540" "$(win 154)"
assert_eq "grow to 5: the new one takes the free cell" "2560 -67 640 540" "$(win 155)"

# the park frame (default 320,70,690,948 from the main display's corner): every parked window gets it, a stack;
# back restores each one's exact cell
printf '%s\n' "" >"$AGENT_HOME/config"
reset "161 1920 -67 960 1080 ttys150" "162 2880 -67 960 1080 ttys151"
QUEUE_TTY=ttys150 "$Q" park a
QUEUE_TTY=ttys151 "$Q" park b
assert_eq "park frame: first window" "320 70 690 948" "$(win 161)"
assert_eq "park frame: second window stacks on it" "320 70 690 948" "$(win 162)"
QUEUE_TTY=ttys151 "$Q" back
assert_eq "park frame: back to its exact cell" "2880 -67 960 1080" "$(win 162)"
setcfg queue_tile=off queue_park_frame=100,0,3000,2000
reset "171 2000 100 800 500 ttys160"
QUEUE_TTY=ttys160 "$Q" park c
assert_eq "park frame: kept inside the display, below the menu bar" "0 30 1920 992" "$(win 171)"
setcfg queue_tile=off queue_park_frame=12,x,3,4
reset "181 2000 100 800 500 ttys170"
QUEUE_TTY=ttys170 "$Q" park d
assert_eq "park frame: a bad value falls back to same size, cascaded" "40 70 800 500" "$(win 181)"
setcfg ""

# a window on a hidden desktop is not laid out
reset "111 0 30 1920 992 ttys100" "112 2000 100 800 500 ttys101 0"
assert_eq "tile: nothing to move" "Tiled: 0 windows moved" "$("$Q" tile)"
assert_eq "tile: no move call when nothing changes" "0" "$(moves)"
assert_eq "hidden-desktop window untouched" "2000 100 800 500" "$(win 112)"

# a session start re-tiles; queue_tile=off leaves the windows as they are
reset "131 2000 30 700 700 ttys120" "132 2800 30 700 700 ttys121"
printf '%s' "$(hook_json SessionStart "$R" q2)" | QUEUE_TTY=ttys121 "$BIN/session-start.sh" >/dev/null
assert_eq "session start: re-tiled, left half" "1920 -67 960 1080" "$(win 131)"
assert_eq "session start: re-tiled, right half" "2880 -67 960 1080" "$(win 132)"
reset "141 2000 30 700 700 ttys130" "142 2800 30 700 700 ttys131"
setcfg queue_tile=off
QUEUE_TTY=ttys131 "$Q" retile
assert_eq "queue_tile=off: retile moves nothing" "0" "$(moves)"

# ---------- for kaching: the tabs map, the waiting record, dismiss, single mode, show ----------
setcfg queue_tile=off
TB="$QD/tabs"
reset "201 2000 100 800 500 ttys200,ttys201" "202 2100 600 800 400 ttys202" "203 2900 100 800 400 ttys203"
QUEUE_SID=s200 QUEUE_NAME="my proj" QUEUE_TTY=ttys200 "$Q" retile
QUEUE_SID=s201 QUEUE_NAME=two QUEUE_TTY=ttys201 "$Q" retile
assert_eq "tabs map: tty, window, tab index, name" "ttys201 201 2 two" "$(cat "$TB/s201")"
assert_eq "tabs map: a name with spaces" "ttys200 201 1 my proj" "$(cat "$TB/s200")"
QUEUE_SID=s201 QUEUE_NAME=two QUEUE_TTY=ttys201 "$Q" forget
assert_eq "tabs map: removed when the session ends" "" "$(ls "$TB" | grep -c s201 | grep -v 0)"
# waiting record: epoch, session id, kind, name; a second park keeps the epoch and takes the new kind
QUEUE_SID=s202 QUEUE_KIND=input QUEUE_TTY=ttys202 "$Q" park "proj b"
first=$(cut -d' ' -f1 "$QD/waiting/ttys202")
assert_eq "waiting record: session id, kind, name" "s202 input proj b" "$(cut -d' ' -f2- "$QD/waiting/ttys202")"
sleep 1
QUEUE_SID=s202 QUEUE_KIND=idle QUEUE_TTY=ttys202 "$Q" park "proj b"
assert_eq "waiting record: the epoch stays" "$first" "$(cut -d' ' -f1 "$QD/waiting/ttys202")"
assert_eq "waiting record: the kind updates" "idle" "$(cut -d' ' -f3 "$QD/waiting/ttys202")"
assert_eq "status shows the name" "proj b  ttys202  (window 202)" "$("$Q" status)"
# dismiss: out of the queue without an answer, back to its cell
assert_eq "dismiss names the agent" "Dismissed proj b" "$("$Q" dismiss s202)"
assert_eq "dismiss: back in its cell" "2100 600 800 400" "$(win 202)"
assert_eq "dismiss: no longer waiting" "" "$(ls "$QD/waiting")"
assert_eq "dismiss: unknown session" "Unknown session: nope" "$("$Q" dismiss nope)"

# kaching open (a live pid in terminal/open, D37): no window moves; kaching's list is the inbox
reset "211 2000 100 800 500 ttys210" "212 2100 600 800 400 ttys211" "213 2900 100 800 400 ttys212"
mkdir -p "$AGENT_HOME/terminal"
QUEUE_SID=s212 QUEUE_TTY=ttys212 "$Q" park early             # waits before kaching opens: comes over (normal mode)
assert_eq "before kaching: the waiting one comes over" "40 70 800 400" "$(win 213)"
printf 'pid=%s\nself_tty=ttys999\nsid=\ntty=\n' "$$" >"$AGENT_HOME/terminal/open"
QUEUE_SID=s210 QUEUE_TTY=ttys210 "$Q" park a
sleep 1
QUEUE_SID=s211 QUEUE_TTY=ttys211 "$Q" park b
assert_eq "kaching open: a waiting window stays in its cell" "2000 100 800 500" "$(win 211)"
assert_eq "kaching open: the next one too" "2100 600 800 400" "$(win 212)"
assert_eq "kaching open: one parked before stays where it is (no moves at all)" "40 70 800 400" "$(win 213)"
QUEUE_SID=s212 QUEUE_TTY=ttys212 "$Q" back
assert_eq "kaching open: answered, it still does not move" "40 70 800 400" "$(win 213)"
QUEUE_SID=s210 QUEUE_TTY=ttys210 "$Q" back
assert_eq "kaching open: nothing came over" "2100 600 800 400" "$(win 212)"
# kaching closed (a dead pid): no backlog comes over; only a window whose own event fires now
printf 'pid=999999\n' >"$AGENT_HOME/terminal/open"
QUEUE_SID=s210 QUEUE_TTY=ttys210 "$Q" retile
assert_eq "closed: a window that waited while kaching was open stays in its cell" "2100 600 800 400" "$(win 212)"
QUEUE_SID=s211 QUEUE_KIND=idle QUEUE_TTY=ttys211 "$Q" park b
assert_eq "closed: the idle reminder brings nothing over" "2100 600 800 400" "$(win 212)"
QUEUE_SID=s211 QUEUE_KIND=done QUEUE_TTY=ttys211 "$Q" park b
assert_eq "closed: its own done event brings it over" "40 70 800 400" "$(win 212)"
QUEUE_SID=s211 QUEUE_TTY=ttys211 "$Q" back
assert_eq "closed: answered, back to its cell" "2100 600 800 400" "$(win 212)"
rm -f "$AGENT_HOME/terminal/open"

# ---------- dragged by hand (D38): the menu bar app reports a window that changed display ----------
setcfg queue_park_frame=320,70,690,948
reset "301 1920 -67 960 540 ttys300" "302 2880 -67 960 540 ttys301" "303 1920 473 960 540 ttys302" \
      "304 2880 473 960 540 ttys303" "305 100 100 700 500 ttys304"
# drag the bottom-left one onto the main display: it takes the park frame; its cell stays reserved
awk '$1 == 303 { $2 = 500; $3 = 300 } { print }' "$FT/windows" >"$FT/w.tmp" && mv "$FT/w.tmp" "$FT/windows"
"$Q" dragged 303 1920 473 960 540
assert_eq "drag to main: the park frame" "320 70 690 948" "$(win 303)"
assert_eq "drag to main: its cell is kept" "1920 473 960 540 hand" "$(cut -d' ' -f1-4,6 "$QD/parked/303")"
assert_eq "drag to main: the others keep the 2x2 grid" "2880 473 960 540" "$(win 304)"
# a prompt or another session's event does not send a hand-dragged window back
QUEUE_SID=s302 QUEUE_TTY=ttys302 "$Q" back
assert_eq "hand-dragged: a prompt leaves it on the main display" "320 70 690 948" "$(win 303)"
# drag it back (dropped somewhere on monitor 2): exactly into its reserved cell
awk '$1 == 303 { $2 = 3000; $3 = 100 } { print }' "$FT/windows" >"$FT/w.tmp" && mv "$FT/w.tmp" "$FT/windows"
"$Q" dragged 303 320 70 690 948
assert_eq "drag back: exactly its cell" "1920 473 960 540" "$(win 303)"
assert_eq "drag back: no longer parked" "" "$(ls "$QD/parked")"
# your own window dragged onto monitor 2 joins the grid (5 windows: 3 on top, 2 below)
awk '$1 == 305 { $2 = 2500; $3 = 100 } { print }' "$FT/windows" >"$FT/w.tmp" && mv "$FT/w.tmp" "$FT/windows"
"$Q" dragged 305 100 100 700 500
assert_eq "drag onto monitor 2: joins the grid" "2560 -67 640 540" "$(win 305)"
assert_eq "drag onto monitor 2: the corners keep their corners" "1920 473 960 540" "$(win 303)"
# a window the queue parked itself is left alone when the watcher reports its move
reset "311 1920 -67 960 1080 ttys310" "312 2880 -67 960 1080 ttys311"
QUEUE_SID=s310 QUEUE_TTY=ttys310 "$Q" park a
: >"$FT/calls"
"$Q" dragged 311 1920 -67 960 1080
assert_eq "own park reported as a drag: nothing moves" "0" "$(moves)"
assert_eq "own park reported as a drag: still auto" "auto" "$(cut -d' ' -f6 "$QD/parked/311")"
# show SESSION_ID: as if dragged over
QUEUE_SID=s311 QUEUE_NAME=b QUEUE_TTY=ttys311 "$Q" retile
assert_eq "show: done" "Shown" "$("$Q" show s311)"
assert_eq "show: on the main display" "hand" "$(cut -d' ' -f6 "$QD/parked/312")"
assert_eq "dragged: bad arguments" "2" "$("$Q" dragged 1 x >/dev/null 2>&1; echo $?)"
exit 0
