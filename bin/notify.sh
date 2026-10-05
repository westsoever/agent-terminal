#!/usr/bin/env bash
# notify.sh KIND [MESSAGE]
# KIND: done | input | blocked | ready | idle
# Hook usage reads hook JSON on stdin (cwd, session_id); works in any folder, repo or not. The folder /
# repo name is always in the title. Delivery: terminal-notifier (click activates the Claude app), else
# osascript. Env: NOTIFY_CWD NOTIFY_SESSION NOTIFY_ACTIVATE NOTIFY_DRY_RUN NOTIFY_LOG
# NOTIFY_TERMINAL_NOTIFIER NOTIFY_OSASCRIPT NOTIFY_IDLE_SUPPRESS (900 s) AGENT_HOME
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

KIND=${1:-done}
MSG=${2:-}
ACTIVATE=${NOTIFY_ACTIVATE:-com.anthropic.claudefordesktop}

HOOK_CWD=${NOTIFY_CWD:-}
hook_init
if [ -n "${NOTIFY_CWD:-}" ]; then
  CWD=$NOTIFY_CWD
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
  NAME=$(name_for "$CWD" "$ROOT")
fi
SESSION=${NOTIFY_SESSION:-$SID}
BRANCH=$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true)

case "$KIND" in
  done)    LABEL="Done";           DEFAULT="Session finished." ;;
  input)   LABEL="Needs input";    DEFAULT="Waiting for your answer." ;;
  blocked) LABEL="Blocked";        DEFAULT="Stopped and needs you." ;;
  ready)   LABEL="Ready to push";  DEFAULT="Release gate passed; waiting for your approval." ;;
  idle)    LABEL="Waiting";        DEFAULT="Idle, waiting for you." ;;
  *)       LABEL="$KIND";          DEFAULT="" ;;
esac
[ -n "$MSG" ] || MSG=$DEFAULT

TITLE="$NAME"
[ -z "$BRANCH" ] || TITLE="$NAME ($BRANCH)"
TITLE="$TITLE: $LABEL"

clean() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | cut -c1-200; }
TITLE=$(clean "$TITLE")
MSG=$(clean "$MSG")

mkdir -p "$AGENT_HOME/notify"
LAST="$AGENT_HOME/notify/$SESSION.last"
NOW=$(date +%s)

# idle_prompt fires ~60s after a response. Skip it when we already notified this session recently.
if [ "$KIND" = idle ] && [ -f "$LAST" ]; then
  prev=$(cat "$LAST" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ $((NOW - prev)) -lt "${NOTIFY_IDLE_SUPPRESS:-900}" ]; then exit 0; fi
fi
printf '%s\n' "$NOW" >"$LAST"

LOG=${NOTIFY_LOG:-$AGENT_HOME/notify.log}
TN=${NOTIFY_TERMINAL_NOTIFIER:-terminal-notifier}
OSA=${NOTIFY_OSASCRIPT:-osascript}

if [ -n "${NOTIFY_DRY_RUN:-}" ]; then
  METHOD=dry-run
elif command -v "$TN" >/dev/null 2>&1; then
  METHOD=terminal-notifier
else
  METHOD=osascript
fi
printf '%s\t%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$METHOD" "$TITLE" "$MSG" >>"$LOG"

case "$METHOD" in
  terminal-notifier)
    "$TN" -title "$TITLE" -message "$MSG" -group "ching-$NAME" -activate "$ACTIVATE" >/dev/null 2>&1 || true ;;
  osascript)
    # Title and message go in as argv so they are never parsed as AppleScript source.
    "$OSA" -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' -- "$TITLE" "$MSG" >/dev/null 2>&1 || true ;;
esac
exit 0
