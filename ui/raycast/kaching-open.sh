#!/bin/bash
# Raycast script command: bring the agent terminal (kaching) forward, or open it in a new Terminal window.
# KachingBar runs it from its hotkeys (ui/menubar/Hotkeys.swift, ~/.agent/hotkeys). Raycast can run it too: Settings >
# Script Commands > Script Folders > + (this folder), then Record Hotkey on the command.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Agent Terminal
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🟠
# @raycast.packageName Kaching
# @raycast.description Brings the kaching agent terminal to the front, or starts it.

STATE="${AGENT_HOME:-$HOME/.agent}/terminal/open"
pid=$(sed -n 's/^pid=//p' "$STATE" 2>/dev/null)
tty=$(sed -n 's/^self_tty=//p' "$STATE" 2>/dev/null)
if [ -n "$pid" ] && [ -n "$tty" ] && kill -0 "$pid" 2>/dev/null; then
  exec osascript -l JavaScript "${AGENT_HOME:-$HOME/.agent}/terminal/send.js" raise "$tty"
fi
# not running: a new Terminal window on the main display (the one with the menu bar, or queue_main_display),
# filling it; the one agent window the monitor queue brings there sits behind it.
wid=$(osascript -e 'tell application "Terminal"
  activate
  set t to do script "exec $HOME/.local/bin/kaching"
  set background color of t to {2827, 2827, 2827}
  return id of front window
end tell')
K="$HOME/.claude/kaching"; [ -d "$K" ] || K="$HOME/.claude/ching"   # before install.sh ran since the rename (D35)
QT="$K/bin/queue-term.js"
want=$(sed -n 's/^queue_main_display=//p' "${AGENT_HOME:-$HOME/.agent}/config" 2>/dev/null | tail -1)
screens=$(osascript -l JavaScript "$QT" screens 2>/dev/null)
frame=$(printf '%s\n' "$screens" | awk -v w="$want" 'w != "" && index(tolower($5), tolower(w)) { print $1, $2, $3, $4; exit }')
[ -n "$frame" ] || frame=$(printf '%s\n' "$screens" | head -1 | awk '{ print $1, $2, $3, $4 }')
# A window Terminal has just opened ignores a new frame for about a second: set it until it holds (at most ~3 s).
if [ -n "$frame" ]; then
  for _ in 1 2 3 4 5 6 7 8; do
    # shellcheck disable=SC2086
    osascript -l JavaScript "$QT" move "$wid" $frame >/dev/null
    got=$(osascript -l JavaScript "$QT" windows 2>/dev/null | awk -v i="$wid" '$1 == i { print $2, $3 }')
    [ "$got" = "$(printf '%s' "$frame" | awk '{ print $1, $2 }')" ] && break
    sleep 0.4
  done
fi
