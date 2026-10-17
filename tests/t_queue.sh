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
assert_eq "next with only a main-display session waiting" "Nothing waiting" "$("$Q" next)"

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

# the park frame (default 320,70,460,790 from the main display's corner): every parked window gets it, a stack;
# back restores each one's exact cell
printf '%s\n' "" >"$AGENT_HOME/config"
reset "161 1920 -67 960 1080 ttys150" "162 2880 -67 960 1080 ttys151"
QUEUE_TTY=ttys150 "$Q" park a
QUEUE_TTY=ttys151 "$Q" park b
assert_eq "park frame: first window" "320 70 460 790" "$(win 161)"
assert_eq "park frame: second window stacks on it" "320 70 460 790" "$(win 162)"
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
assert_eq "queue_tile=off: retile moves nothing" "" "$(cat "$FT/calls")"
exit 0
