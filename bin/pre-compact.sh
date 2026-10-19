#!/usr/bin/env bash
# PreCompact hook: write a mechanical snapshot (folder, branch, status, diff stat, time) into a fenced
# block in STATE.md (repo .agent/ if the repo opted in, else the session dir). The model writes the
# narrative; this only preserves facts. Idempotent. Works in non-git folders.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

hook_init
resolve_state
ev compact "$(jq -nc --arg t "$(jget trigger)" '{trigger:$t}')"
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/STATE.md"
BEGIN='<!-- ching:snapshot:begin -->'
END='<!-- ching:snapshot:end -->'

BLOCK="$BEGIN"$'\n'"## Snapshot (automatic, taken before compaction at $(date '+%Y-%m-%d %H:%M:%S'))"$'\n'
BLOCK="$BLOCK- folder: $CWD"$'\n'
if [ -n "$ROOT" ]; then
  branch=$(git -C "$ROOT" symbolic-ref --short -q HEAD 2>/dev/null || echo detached)
  head=$(git -C "$ROOT" log -1 --format='%h %s' 2>/dev/null || echo none)
  status=$(git -C "$ROOT" status --short 2>/dev/null | head -30 || true)
  stat=$(git -C "$ROOT" diff --stat HEAD 2>/dev/null | tail -15 || true)
  BLOCK="$BLOCK- branch: $branch"$'\n'"- head: $head"$'\n'"- uncommitted files:"$'\n'
  if [ -n "$status" ]; then BLOCK="$BLOCK$(printf '%s\n' "$status" | sed 's/^/    /')"$'\n'; else BLOCK="$BLOCK    (clean)"$'\n'; fi
  if [ -n "$stat" ]; then BLOCK="$BLOCK- diff stat:"$'\n'"$(printf '%s\n' "$stat" | sed 's/^/    /')"$'\n'; fi
else
  BLOCK="$BLOCK- not a git repository"$'\n'
fi
BLOCK="$BLOCK$END"

TMP=$(mktemp "$STATE_DIR/.state.XXXXXX")
BLOCK_FILE=$(mktemp "$STATE_DIR/.block.XXXXXX")
trap 'rm -f "$TMP" "$BLOCK_FILE"' EXIT
printf '%s\n' "$BLOCK" >"$BLOCK_FILE"
snapshot() {
  if [ -f "$STATE" ] && grep -qF "$BEGIN" "$STATE"; then
    awk -v b="$BEGIN" -v e="$END" -v bf="$BLOCK_FILE" '
      index($0, b) { while ((getline line < bf) > 0) print line; skip = 1; next }
      skip && index($0, e) { skip = 0; next }
      !skip { print }
    ' "$STATE" >"$TMP"
  else
    { if [ -f "$STATE" ]; then cat "$STATE"; echo; fi; cat "$BLOCK_FILE"; } >"$TMP"
  fi
  mv "$TMP" "$STATE"
}
# the sessions of a repo share its STATE.md: read and replace it under the lock its other writers take, so a
# checkpoint written in between is not lost
with_lock "$STATE_DIR/.state.lock" snapshot
exit 0
