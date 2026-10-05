#!/usr/bin/env bash
# post-release.sh [--sha SHA] [--no-watch]
# After a push to main: watch the deploy run(s) for that commit with `gh`, record the result under
# "## Releases" in .agent/STATE.md, notify, and on failure leave .agent/release-failed plus the
# one-revert rule. Idempotent: the same sha+result is recorded once.
# Env: GH_BIN (gh)  POST_RELEASE_WAIT_RUN (seconds to wait for a run to appear, 120)
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
GH=${GH_BIN:-gh}
SHA=""
WATCH=1
while [ $# -gt 0 ]; do
  case "$1" in
    --sha) SHA=${2:?--sha needs a value}; shift 2 ;;
    --no-watch) WATCH=0; shift ;;
    -h|--help) sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "post-release: unknown argument $1" >&2; exit 64 ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || { echo "post-release: not inside a git repository" >&2; exit 1; }
[ -n "$SHA" ] || SHA=$(git rev-parse HEAD)
SHA7=${SHA:0:7}
STATE="$ROOT/.agent/STATE.md"
mkdir -p "$ROOT/.agent"

RESULT=UNKNOWN
URL=""
DETAIL=""

if ! command -v "$GH" >/dev/null 2>&1; then
  DETAIL="gh not installed; deploy not watched"
elif [ "$WATCH" -eq 0 ]; then
  DETAIL="watching skipped (--no-watch)"
else
  runs="[]"
  waited=0
  limit=${POST_RELEASE_WAIT_RUN:-120}
  while :; do
    runs=$("$GH" run list --commit "$SHA" --limit 10 --json databaseId,workflowName,url 2>/dev/null || echo '[]')
    [ "$(printf '%s' "$runs" | jq 'length' 2>/dev/null || echo 0)" -gt 0 ] && break
    [ "$waited" -lt "$limit" ] || break
    sleep 5; waited=$((waited + 5))
  done
  if [ "$(printf '%s' "$runs" | jq 'length' 2>/dev/null || echo 0)" -eq 0 ]; then
    DETAIL="no CI run found for $SHA7"
  else
    RESULT=SUCCESS
    for id in $(printf '%s' "$runs" | jq -r '.[].databaseId'); do
      wrc=0
      "$GH" run watch "$id" --exit-status >/dev/null 2>&1 || wrc=$?
      info=$("$GH" run view "$id" --json conclusion,url,workflowName 2>/dev/null || echo '{}')
      concl=$(printf '%s' "$info" | jq -r '.conclusion // empty')
      u=$(printf '%s' "$info" | jq -r '.url // empty')
      name=$(printf '%s' "$info" | jq -r '.workflowName // empty')
      if [ "$wrc" -ne 0 ] || { [ -n "$concl" ] && [ "$concl" != success ]; }; then
        RESULT=FAILED
        DETAIL="${DETAIL}${name:-run $id}: ${concl:-failed}; "
        URL=${u:-$URL}
      else
        [ -n "$URL" ] || URL=$u
      fi
    done
  fi
fi

LINE="- $(date '+%Y-%m-%d %H:%M') | $SHA7 | $RESULT | ${URL:-no url}${DETAIL:+ | $DETAIL}"

record() {
  [ -f "$STATE" ] || printf '# State\n' >"$STATE"
  if grep -qE "^- [0-9-]+ [0-9:]+ \| $SHA7 \| $RESULT \|" "$STATE"; then return 0; fi
  if ! grep -q '^## Releases' "$STATE"; then printf '\n## Releases\n' >>"$STATE"; fi
  local tmp
  tmp=$(mktemp "$ROOT/.agent/.state.XXXXXX")
  awk -v line="$LINE" '
    /^## Releases[[:space:]]*$/ { print; inrel = 1; next }
    inrel && /^- \(none\)/ { next }
    inrel && /^## / { print line; done = 1; inrel = 0 }
    { print }
    END { if (inrel && !done) print line }
  ' "$STATE" >"$tmp"
  mv "$tmp" "$STATE"
}
record
CWD=$ROOT; NAME=$(basename "$ROOT")
ev release "$(jq -nc --arg s "$SHA" --arg o "$RESULT" '{sha:$s,outcome:("deploy-" + $o)}')"

case "$RESULT" in
  SUCCESS)
    rm -f "$ROOT/.agent/release-failed"
    NOTIFY_CWD="$ROOT" "$SELF_DIR/notify.sh" "done" "Release $SHA7 deployed and CI is green." </dev/null || true
    echo "post-release: SUCCESS for $SHA7 ${URL}" ;;
  FAILED)
    printf '%s\n' "$SHA" >"$ROOT/.agent/release-failed"
    NOTIFY_CWD="$ROOT" "$SELF_DIR/notify.sh" blocked "Release $SHA7 FAILED: ${DETAIL}" </dev/null || true
    echo "post-release: FAILED for $SHA7: ${DETAIL}${URL}"
    echo "You may push ONE revert commit through release-gate.sh (git revert $SHA7, evidence, gate, push). Then stop and wait for the user." ;;
  *)
    NOTIFY_CWD="$ROOT" "$SELF_DIR/notify.sh" input "Release $SHA7 pushed but the deploy was not confirmed: ${DETAIL}" </dev/null || true
    echo "post-release: UNKNOWN for $SHA7: ${DETAIL}" ;;
esac
[ "$RESULT" != FAILED ] || exit 1
