#!/usr/bin/env bash
# queue.sh: park moves a window from the other display to the main one and back on the next prompt; tabs of one
# window move together; a window on the main display is never moved; next cycles oldest first; queue=off.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# A fake Terminal: windows from $FT/windows ("id x y w h ttys"), every call logged, move rewrites the frame.
FT="$WORK/fake-term"; mkdir -p "$FT"
cat >"$FT/term" <<'EOS'
#!/usr/bin/env bash
d=$(dirname "$0"); printf '%s\n' "$*" >>"$d/calls"
case "$1" in
  screens) printf '0 30 1920 992 DELL_P2425H\n1920 -67 1920 1080 SA240Y\n' ;;
  windows) cat "$d/windows" ;;
  move) awk -v i="$2" -v x="$3" -v y="$4" -v w="$5" -v h="$6" '$1 == i { $2 = x; $3 = y; $4 = w; $5 = h } { print }' "$d/windows" >"$d/w.tmp" && mv "$d/w.tmp" "$d/windows" ;;
esac
EOS
chmod +x "$FT/term"
export QUEUE_TERM="$FT/term" QUEUE_SYNC=1
Q="$BIN/queue.sh"
QD="$AGENT_HOME/queue"
reset() { printf '%s\n' "$@" >"$FT/windows"; : >"$FT/calls"; rm -f "$QD"/waiting/* "$QD"/parked/* "$QD/last"; }
win() { awk -v i="$1" '$1 == i { print $2, $3, $4, $5 }' "$FT/windows"; }
mkdir -p "$QD/waiting" "$QD/parked"

# park: a window on the other display moves to the main one, keeping its size; back restores it
reset "11 2879 484 961 529 ttys003" "12 0 30 961 979 ttys001"
QUEUE_TTY=ttys003 "$Q" park worker
assert_eq "park moves the window to the main display" "40 70 961 529" "$(win 11)"
assert_eq "park saves the old frame" "2879 484 961 529" "$(cat "$QD/parked/11")"
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
assert_eq "a tall window is clamped to the display" "40 70 961 912" "$(win 21)"
QUEUE_TTY=ttys011 "$Q" back
assert_eq "stays parked while another tab waits" "40 70 961 912" "$(win 21)"
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
printf 'queue_main_display=sa240\n' >"$AGENT_HOME/config"
QUEUE_TTY=ttys050 "$Q" park x
assert_eq "queue_main_display: parks onto the named display" "1960 -27 800 500" "$(win 61)"

# queue=off: does nothing
reset "71 2000 100 800 500 ttys060"
printf 'queue=off\n' >"$AGENT_HOME/config"
QUEUE_TTY=ttys060 "$Q" park x
assert_eq "queue=off: no Terminal call" "" "$(cat "$FT/calls")"
rm -f "$AGENT_HOME/config"

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
exit 0
