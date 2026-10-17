#!/bin/bash
# Raycast script command: lay out the Terminal windows of each display in a grid (bin/queue.sh tile).
# Add this folder in Raycast (Extensions > Script Commands > Add Directories) and give the command a hotkey.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Tile Terminals
# @raycast.mode silent

# Optional parameters:
# @raycast.icon ▦
# @raycast.packageName Ching
# @raycast.description Lays out the Terminal windows of each display in a grid: 2 side by side, 3 in columns, 4 as 2x2.

exec "$HOME/.claude/ching/bin/queue.sh" tile
