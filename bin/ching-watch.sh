#!/usr/bin/env bash
# ching-watch.sh - one-shot watcher, run every 5 minutes by launchd (org.ching.watch). Not a daemon.
# For every live session in $AGENT_HOME/sessions: stall detection, context pressure and today's token
# total, read incrementally from the transcript (byte offset in meta). Then token-budget alerts and
# events.jsonl rotation. It never touches a session: it writes meta keys, $AGENT_HOME/tokens/<UTC day>,
# events and notifications only.
# Meta keys written: tok_offset tok_last_mid ctx_level ctx_pct stalled_at
# Env: AGENT_HOME WATCH_NOW (epoch, tests) WATCH_STALL_MINS (20) WATCH_ROTATE_BYTES (20971520)
#      TOKEN_BUDGET_DAILY (unset = no token alerts; also read from $AGENT_HOME/defaults/ching.env)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

NOW=${WATCH_NOW:-$(date +%s)}
STALL_SECS=$(( ${WATCH_STALL_MINS:-20} * 60 ))
if [ -z "${TOKEN_BUDGET_DAILY:-}" ] && [ -f "$AGENT_HOME/defaults/ching.env" ]; then
  TOKEN_BUDGET_DAILY=$(sed -n 's/^TOKEN_BUDGET_DAILY=//p' "$AGENT_HOME/defaults/ching.env" | head -1)
fi
case "${TOKEN_BUDGET_DAILY:-}" in *[!0-9]*) TOKEN_BUDGET_DAILY="" ;; esac
DAY=$(date -u -r "$NOW" +%Y-%m-%d)
mkdir -p "$AGENT_HOME/tokens"

LOCK="$AGENT_HOME/watch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(file_mtime "$LOCK") )) -lt 600 ]; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-watch.XXXXXX")
trap 'rm -rf "$LOCK" "$TMP"' EXIT

wnotify() { NOTIFY_CWD="$CWD" NOTIFY_SESSION="$SID" NOTIFY_NOW="$NOW" "$SELF_DIR/notify.sh" "$1" "$2" </dev/null >/dev/null 2>&1 || true; }

tok_add() { # sid n -> add n to today's total for sid
  local f="$AGENT_HOME/tokens/$DAY" cur
  cur=$(awk -v s="$1" '$1 == s { print $2; exit }' "$f" 2>/dev/null || true); [ -n "$cur" ] || cur=0
  { if [ -f "$f" ]; then awk -v s="$1" '$1 != s' "$f"; fi; printf '%s %s\n' "$1" $((cur + $2)); } >"$f.tmp"
  mv "$f.tmp" "$f"
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ -f "$m" ] || continue
  SESS_DIR=$(dirname "$m"); SID=$(basename "$SESS_DIR")
  state=$(meta_get "$m" state)
  [ "$state" != ended ] || continue
  CWD=$(meta_get "$m" cwd); NAME=$(meta_get "$m" name)
  tr=$(meta_get "$m" transcript)
  if [ -z "$tr" ] || [ ! -f "$tr" ]; then continue; fi
  tm=$(file_mtime "$tr")

  # 1. stall: working, transcript silent for STALL_SECS; reported once, cleared by any new write
  stalled=$(meta_get "$m" stalled_at)
  if [ -n "$stalled" ] && [ "$tm" -ge "$stalled" ]; then meta_set stalled_at ""; stalled=""; fi
  if [ "$state" = working ] && [ -z "$stalled" ] && [ $((NOW - tm)) -ge "$STALL_SECS" ]; then
    meta_set stalled_at "$NOW"
    mins=$(( (NOW - tm) / 60 ))
    ev stall "$(jq -nc --argjson m "$mins" '{idle_mins:$m}')"
    wnotify stall "No progress for $mins minutes."
  fi

  # 2. incremental read of complete new lines. A transcript that shrank (rewritten, truncated) is read
  # from the start again, and the reset is stored at once so an emptied file cannot keep a stale offset.
  size=$(wc -c <"$tr" | tr -d ' ')
  off=$(meta_get "$m" tok_offset); case "$off" in ''|*[!0-9]*) off=0 ;; esac
  if [ "$off" -gt "$size" ]; then off=0; meta_set tok_offset 0; fi
  [ "$off" -lt "$size" ] || continue
  tail -c +$((off + 1)) "$tr" >"$TMP/chunk"
  cut=$(perl -0777 -ne 'print rindex($_, "\n") + 1' "$TMP/chunk")
  [ "$cut" -gt 0 ] || continue
  head -c "$cut" "$TMP/chunk" >"$TMP/lines"
  meta_set tok_offset $((off + cut))
  jq -cR --arg day "$DAY" 'fromjson? | select(.type == "assistant" and ((.message.usage // null) | type) == "object")
      | {id: (.message.id // ""), today: ((.timestamp // "") | startswith($day)), u: .message.usage}' \
      "$TMP/lines" >"$TMP/usage" 2>/dev/null || true
  [ -s "$TMP/usage" ] || continue
  last_mid=$(meta_get "$m" tok_last_mid)
  read -r add ctx mid < <(jq -rs --arg last "$last_mid" '
      (reduce .[] as $r ({seen: {($last): true}, add: 0};
         if .seen[$r.id] then . else (.seen[$r.id] = true)
           | .add += (if $r.today then ($r.u.output_tokens // 0) + ($r.u.input_tokens // 0) + ($r.u.cache_creation_input_tokens // 0) else 0 end) end)) as $acc
      | (last.u | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) as $ctx
      | "\($acc.add) \($ctx) \(last.id)"' "$TMP/usage") || continue
  case "$add$ctx" in *[!0-9]*) continue ;; esac
  meta_set tok_last_mid "$mid"
  [ "$add" -eq 0 ] || tok_add "$SID" "$add"

  # 3. context pressure: window is 200k unless the context already exceeds it (then 1M)
  win=200000; [ "$ctx" -le 200000 ] || win=1000000
  pct=$(( ctx * 100 / win ))
  if [ "$pct" -ge 80 ]; then lvl=handoff; elif [ "$pct" -ge 60 ]; then lvl=watch; else lvl=healthy; fi
  meta_set ctx_pct "$pct"
  if [ "$lvl" != "$(meta_get "$m" ctx_level)" ]; then
    meta_set ctx_level "$lvl"
    ev context "$(jq -nc --arg l "$lvl" --argjson p "$pct" '{level:$l,pct:$p}')"
    [ "$lvl" != handoff ] || wnotify handoff "Context ${pct}% full: run /handoff and continue in a fresh session."
  fi
done

# 4. daily token budget (machine-wide), one alert per mark per day
if [ -n "${TOKEN_BUDGET_DAILY:-}" ] && [ -f "$AGENT_HOME/tokens/$DAY" ]; then
  total=$(awk '{ s += $2 } END { print s + 0 }' "$AGENT_HOME/tokens/$DAY")
  for mark in 80 100; do
    flag="$AGENT_HOME/tokens/$DAY.alert$mark"
    if [ $((total * 100)) -ge $((TOKEN_BUDGET_DAILY * mark)) ] && [ ! -f "$flag" ]; then
      : >"$flag"
      SID=machine; NAME=machine; CWD=$HOME
      ev tokens "$(jq -nc --argjson t "$total" --argjson b "$TOKEN_BUDGET_DAILY" --argjson c "$mark" '{day_total:$t,budget:$b,crossed:$c}')"
      wnotify tokens "Token use today is at ${mark}% of the budget ($total of $TOKEN_BUDGET_DAILY)."
    fi
  done
fi

# 5. rotation
EVF="$AGENT_HOME/events.jsonl"
if [ -f "$EVF" ] && [ "$(wc -c <"$EVF" | tr -d ' ')" -gt "${WATCH_ROTATE_BYTES:-20971520}" ]; then
  mv "$EVF" "$AGENT_HOME/events-$(date -u -r "$NOW" +%Y%m%d-%H%M%S).jsonl"
fi
exit 0
