#!/usr/bin/env bash
# notify.sh KIND [MESSAGE]
# KIND: done | input | blocked | ready | idle | waiting | stall | handoff | tokens
# Routing (Phase 1.5): input, blocked and ready are urgent and always delivered. done goes to the inbox
# (dash.sh --inbox) and is not pushed (NOTIFY_PUSH_DONE=1 restores the push). Every other kind is
# budgeted: delivered only between NOTIFY_QUIET_END (9) and NOTIFY_QUIET_START (21) local time, at most
# NOTIFY_BUDGET (4) a day, NOTIFY_COOLDOWN_MINS (45) apart per session; otherwise logged as suppressed.
# handoff keeps the quiet hours but is not counted against the daily budget or the cooldown; it has its own
# per-session cooldown instead, NOTIFY_HANDOFF_COOLDOWN_MINS (120).
# Hook usage reads hook JSON on stdin (cwd, session_id); works in any folder, repo or not. The folder /
# repo name is always in the title. Delivery: terminal-notifier (click activates the Claude app), else
# osascript. Env: NOTIFY_CWD NOTIFY_SESSION NOTIFY_ACTIVATE NOTIFY_DRY_RUN NOTIFY_LOG NOTIFY_NOW (epoch)
# NOTIFY_TERMINAL_NOTIFIER NOTIFY_OSASCRIPT NOTIFY_IDLE_SUPPRESS (900 s) NOTIFY_PUSH_DONE AGENT_HOME
set -euo pipefail
# A learner model call (learn_model_call sets KACHING_LEARNER=1) never notifies: no log line, no popup, no .last stamp.
[ "${KACHING_LEARNER:-${CHING_LEARNER:-}}" != 1 ] || exit 0
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
SID=$SESSION
BRANCH=$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true)

case "$KIND" in
  done)    LABEL="Done";                DEFAULT="Session finished." ;;
  input)   LABEL="Needs input";         DEFAULT="Waiting for your answer." ;;
  blocked) LABEL="Blocked";             DEFAULT="Stopped and needs you." ;;
  ready)   LABEL="Ready to push";       DEFAULT="Release gate passed; waiting for your approval." ;;
  idle)    LABEL="Waiting";             DEFAULT="Idle, waiting for you." ;;
  waiting) LABEL="Waiting for you";     DEFAULT="Finished and waiting for your next step." ;;
  stall)   LABEL="Stalled";             DEFAULT="No progress for a while." ;;
  handoff) LABEL="Context almost full"; DEFAULT="Run /handoff and continue in a fresh session." ;;
  tokens)  LABEL="Token budget";        DEFAULT="Token use crossed a daily budget mark." ;;
  *)       LABEL="$KIND";               DEFAULT="" ;;
esac
[ -n "$MSG" ] || MSG=$DEFAULT

TITLE="$NAME"
[ -z "$BRANCH" ] || TITLE="$NAME ($BRANCH)"
TITLE="$TITLE: $LABEL"

clean() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | cut -c1-200; }
TITLE=$(clean "$TITLE")
MSG=$(clean "$MSG")

# The monitor queue (queue.sh): a session that now waits for you moves its Terminal window to the main display.
# Only a call from inside the session has its tty; the watcher's calls find none and do nothing there.
case "$KIND" in done|input|blocked|ready|idle) QUEUE_SID=$SESSION QUEUE_KIND=$KIND "$SELF_DIR/queue.sh" park "$NAME" </dev/null || true ;; esac

mkdir -p "$AGENT_HOME/notify"
LAST="$AGENT_HOME/notify/$SESSION.last"
NOW=${NOTIFY_NOW:-$(date +%s)}

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

case "$KIND" in
  input|blocked|ready) CLASS=urgent ;;
  done) if [ -n "${NOTIFY_PUSH_DONE:-}" ]; then CLASS=urgent; else CLASS=inbox; fi ;;
  *) CLASS=budgeted ;;
esac

HANDOFF_COOLDOWN_MINS=${NOTIFY_HANDOFF_COOLDOWN_MINS:-120}
case "$HANDOFF_COOLDOWN_MINS" in ''|*[!0-9]*) HANDOFF_COOLDOWN_MINS=120 ;; esac
[ "${#HANDOFF_COOLDOWN_MINS}" -le 6 ] || HANDOFF_COOLDOWN_MINS=120
HANDOFF_COOLDOWN_MINS=$((10#$HANDOFF_COOLDOWN_MINS))
WHY=""
budget_ok() { # 0 when a budgeted alert may go out now (and books it); else sets WHY
  local hour used last file
  hour=$(date -r "$NOW" +%H 2>/dev/null || true); hour=${hour#0}
  # no readable hour (a date without BSD -r on PATH): the quiet-hours check cannot run, so do not send
  case "$hour" in ''|*[!0-9]*) WHY=no-clock; return 1 ;; esac
  if [ "$hour" -lt "${NOTIFY_QUIET_END:-9}" ] || [ "$hour" -ge "${NOTIFY_QUIET_START:-21}" ]; then WHY=quiet-hours; return 1; fi
  # handoff is rare (once per crossing of 80%) and actionable: no daily count and not the shared cooldown,
  # only its own per-session one, so a context level that wobbles around 80% cannot push again and again
  if [ "$KIND" = handoff ]; then
    file="$AGENT_HOME/notify/$SESSION.handoff"
    last=$(cat "$file" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
    if [ $((NOW - last)) -lt $((HANDOFF_COOLDOWN_MINS * 60)) ]; then WHY=handoff-cooldown; return 1; fi
    printf '%s\n' "$NOW" >"$file"
    return 0
  fi
  file="$AGENT_HOME/notify/budget-$(date -r "$NOW" +%Y-%m-%d)"
  used=$(cat "$file" 2>/dev/null || echo 0); case "$used" in ''|*[!0-9]*) used=0 ;; esac
  if [ "$used" -ge "${NOTIFY_BUDGET:-4}" ]; then WHY=daily-budget; return 1; fi
  last=$(cat "$AGENT_HOME/notify/$SESSION.budgeted" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((NOW - last)) -lt $(( ${NOTIFY_COOLDOWN_MINS:-45} * 60 )) ]; then WHY=cooldown; return 1; fi
  printf '%s\n' $((used + 1)) >"$file"
  printf '%s\n' "$NOW" >"$AGENT_HOME/notify/$SESSION.budgeted"
  return 0
}

OUTCOME=delivered
case "$CLASS" in
  inbox) METHOD=inbox; OUTCOME=suppressed; WHY=routed-to-inbox ;;
  budgeted) if ! budget_ok; then METHOD="suppressed:$WHY"; OUTCOME=suppressed; fi ;;
esac

printf '%s\t%s\t%s\t%s\n' "$(date -r "$NOW" '+%Y-%m-%d %H:%M:%S')" "$METHOD" "$TITLE" "$MSG" >>"$LOG"
ev notify "$(jq -nc --arg k "$KIND" --arg o "$OUTCOME" --arg w "$WHY" '{kind:$k,outcome:$o,reason:$w}')"

case "$METHOD" in
  terminal-notifier)
    "$TN" -title "$TITLE" -message "$MSG" -group "kaching-$NAME" -activate "$ACTIVATE" >/dev/null 2>&1 || true ;;
  osascript)
    # Title and message go in as argv so they are never parsed as AppleScript source.
    "$OSA" -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' -- "$TITLE" "$MSG" >/dev/null 2>&1 || true ;;
esac
exit 0
