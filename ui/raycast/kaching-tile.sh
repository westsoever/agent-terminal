#!/bin/bash
# Raycast script command: lay out the Terminal windows of each display in a grid (bin/queue.sh tile).
# KachingBar runs it from its hotkeys (ui/menubar/Hotkeys.swift, ~/.agent/hotkeys). Raycast can run it too: Settings >
# Script Commands > Script Folders > + (this folder), then Record Hotkey on the command.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Tile Terminals
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ▦
# @raycast.packageName Kaching
# @raycast.description Lays out the Terminal windows of each display in a grid: 2 side by side, 3 in columns, 4 as 2x2.

K="$HOME/.claude/kaching"; [ -d "$K" ] || K="$HOME/.claude/ching"   # before install.sh ran since the rename (D35)
exec "$K/bin/queue.sh" tile
