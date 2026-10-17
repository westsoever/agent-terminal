#!/usr/bin/env bash
# session-start.sh [touch|end]
#   (no arg) SessionStart hook: register the session in $AGENT_HOME/sessions/<id>/meta and inject
#            GOAL/STATE/NEXT (only the ones that exist) as additionalContext. Works in any folder.
#            The session is "idle" (nobody has prompted yet) except after compact, which keeps its state.
#   touch   UserPromptSubmit hook: mark the session "working"; its window leaves the monitor queue (queue.sh back).
#   end      SessionEnd hook: mark the session "ended" (queue.sh forget).
set -euo pipefail
# A learner model call (learn_model_call sets CHING_LEARNER=1) is no session: no registry entry, no event, no context.
[ "${CHING_LEARNER:-}" != 1 ] || exit 0
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

MODE=${1:-start}
hook_init
resolve_state
NOW=$(date +%s)

case "$MODE" in
  touch) meta_set state working; meta_set updated "$NOW"; meta_set prompted "$NOW"; ev prompt
         "$SELF_DIR/queue.sh" back </dev/null || true; exit 0 ;;
  end)   meta_set state ended;   meta_set updated "$NOW"; ev session_end
         "$SELF_DIR/queue.sh" forget </dev/null || true; exit 0 ;;
esac

BRANCH=$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true)
mkdir -p "$SESS_DIR"
[ -n "$(meta_get "$SESS_DIR/meta" started)" ] || meta_set started "$NOW"
meta_set cwd "$CWD"
meta_set root "$ROOT"
meta_set name "$NAME"
meta_set branch "$BRANCH"
meta_set transcript "$(jget transcript_path)"
SRC=$(jget source)
meta_set source "$SRC"
# Nobody has prompted yet, so a started, resumed or cleared session is idle until its UserPromptSubmit
# (touch) marks it working. Marking it working here made the watcher report a resumed session with an old
# transcript as stalled at its next run. compact fires in the middle of a turn, or after a manual /compact:
# it keeps the state and `updated` the session has (working when it has none).
case "$SRC" in
  compact) if [ -z "$(meta_get "$SESS_DIR/meta" state)" ]; then meta_set state working; meta_set updated "$NOW"; fi ;;
  *) meta_set state idle; meta_set updated "$NOW" ;;
esac
rm -f "$SESS_DIR/retries"
ev session_start "$(jq -nc --arg s "$SRC" '{source:$s}')"

MAX=${SESSION_START_MAX_BYTES:-6000}
if [ "$REPO_MODE" -eq 1 ]; then WHERE="repo state in $STATE_DIR"; else WHERE="machine-level session state in $STATE_DIR (no repo GOAL.md here)"; fi
CTX="# Agent state for $NAME (injected by the SessionStart hook). Session $SID. $WHERE."$'\n'
CTX="$CTX""Keep STATE.md and NEXT.md up to date in that directory."$'\n'
for p in "$GOAL_FILE" "$STATE_DIR/STATE.md" "$STATE_DIR/NEXT.md"; do
  [ -n "$p" ] && [ -s "$p" ] || continue
  body=$(head -c "$MAX" "$p")
  if [ "$(wc -c <"$p")" -gt "$MAX" ]; then body="$body"$'\n'"[truncated: read $p for the rest]"; fi
  CTX="$CTX"$'\n'"## $p"$'\n'"$body"$'\n'
done
jq -n --arg c "$CTX" '{hookSpecificOutput:{hookEventName:"SessionStart",additionalContext:$c}}'
