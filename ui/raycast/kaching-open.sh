#!/bin/bash
# Raycast script command: bring the agent terminal (kaching) forward, or open it in a new Terminal window.
# Add this folder in Raycast (Extensions > Script Commands > Add Directories) and give the command a hotkey.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Open Agent Terminal
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🟠
# @raycast.packageName Ching
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
QT="$HOME/.claude/ching/bin/queue-term.js"
want=$(sed -n 's/^queue_main_display=//p' "${AGENT_HOME:-$HOME/.agent}/config" 2>/dev/null | tail -1)
screens=$(osascript -l JavaScript "$QT" screens 2>/dev/null)
frame=$(printf '%s\n' "$screens" | awk -v w="$want" 'w != "" && index(tolower($5), tolower(w)) { print $1, $2, $3, $4; exit }')
[ -n "$frame" ] || frame=$(printf '%s\n' "$screens" | head -1 | awk '{ print $1, $2, $3, $4 }')
# shellcheck disable=SC2086
[ -z "$frame" ] || osascript -l JavaScript "$QT" move "$wid" $frame >/dev/null
