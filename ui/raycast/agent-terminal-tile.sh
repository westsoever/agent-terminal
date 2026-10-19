#!/bin/bash
# Raycast script command: lay out the Terminal windows of each display in a grid (bin/queue.sh tile).
# AgentTerminalBar runs it from its hotkeys (ui/menubar/Hotkeys.swift, ~/.agent/hotkeys). Raycast can run it too: Settings >
# Script Commands > Script Folders > + (this folder), then Record Hotkey on the command.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Tile Terminals
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ▦
# @raycast.packageName Agent Terminal
# @raycast.description Lays out the Terminal windows of each display in a grid: 2 side by side, 3 in columns, 4 as 2x2.

K="$HOME/.claude/agent-terminal"
[ -d "$K" ] || K="$HOME/.claude/kaching"   # before install.sh ran since the rename (D65)
[ -d "$K" ] || K="$HOME/.claude/ching"     # and since D35
exec "$K/bin/queue.sh" tile
