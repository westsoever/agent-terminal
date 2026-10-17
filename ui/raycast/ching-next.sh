#!/bin/bash
# Raycast script command: bring the next waiting agent's Terminal window to the front (bin/queue.sh next).
# Add this folder in Raycast (Extensions > Script Commands > Add Directories) and give the command a hotkey.

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Next Waiting Agent
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🟠
# @raycast.packageName Ching
# @raycast.description Brings the oldest waiting agent's Terminal window to the front, then the next one on each press.

exec "$HOME/.claude/ching/bin/queue.sh" next
