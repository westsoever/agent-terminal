#!/bin/bash
# Raycast script command: bring the next waiting agent's Terminal window to the front (bin/queue.sh next).
# AgentTerminalBar runs it from its hotkeys (ui/menubar/Hotkeys.swift, ~/.agent/hotkeys). Raycast can run it too: Settings >
# Script Commands > Script Folders > + (this folder), then Record Hotkey on the command.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Next Waiting Agent
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🟠
# @raycast.packageName Agent Terminal
# @raycast.description Brings the oldest waiting agent's Terminal window to the front, then the next one on each press.

K="$HOME/.claude/agent-terminal"
[ -d "$K" ] || K="$HOME/.claude/kaching"   # before install.sh ran since the rename (D65)
[ -d "$K" ] || K="$HOME/.claude/ching"     # and since D35
exec "$K/bin/queue.sh" next
