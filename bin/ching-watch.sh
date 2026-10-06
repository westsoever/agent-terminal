#!/usr/bin/env bash
# ching-watch.sh - one-shot watcher, run every 5 minutes by launchd (org.ching.watch). Not a daemon.
# For every live session in $AGENT_HOME/sessions: stall detection, context pressure and today's token
# total, read incrementally from the transcript (byte offset in meta). Then token-budget alerts and
# events.jsonl rotation. It never touches a session: it writes meta keys, $AGENT_HOME/tokens/<UTC day>,
# events and notifications only.
# Meta keys written: tok_offset tok_last_mid ctx_level ctx_pct stalled_at
# Check-in nudges (3b): sessions waiting on the user get a `waiting` banner (finished sessions with open
# work) and, after a delay, one spoken note. Meta keys: nudged_for spoken_for. Env: WATCH_WAIT_GRACE_MINS (2)
# WATCH_NUDGE_MAX_HOURS (12) WATCH_SPEAK_AFTER_MINS (5) WATCH_PRESENT_MINS (10) WATCH_SPEAK_GAP_MINS (10)
# SPEAK_CMD HID_IDLE_CMD VOICEMODE_CONCH
# Env: AGENT_HOME WATCH_NOW (epoch, tests) WATCH_STALL_MINS (20) WATCH_ROTATE_BYTES (20971520)
#      TOKEN_BUDGET_DAILY (unset = no token alerts; also read from $AGENT_HOME/defaults/ching.env)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

NOW=${WATCH_NOW:-$(date +%s)}
STALL_SECS=$(( ${WATCH_STALL_MINS:-20} * 60 ))
if [ -z "${TOKEN_BUDGET_DAILY:-}" ] && [ -f "$AGENT_HOME/defaults/ching.env" ]; then
  # `TOKEN_BUDGET_DAILY=N` or `export TOKEN_BUDGET_DAILY=N`, N optionally in single or double quotes
  TOKEN_BUDGET_DAILY=$(sed -n '/^[[:space:]]*\(export[[:space:]][[:space:]]*\)\{0,1\}TOKEN_BUDGET_DAILY=/{s/^[^=]*=[[:space:]]*//;s/[[:space:]]*$//;p;q;}' "$AGENT_HOME/defaults/ching.env")
  case "$TOKEN_BUDGET_DAILY" in
    \"*\") TOKEN_BUDGET_DAILY=${TOKEN_BUDGET_DAILY#\"}; TOKEN_BUDGET_DAILY=${TOKEN_BUDGET_DAILY%\"} ;;
    \'*\') TOKEN_BUDGET_DAILY=${TOKEN_BUDGET_DAILY#\'}; TOKEN_BUDGET_DAILY=${TOKEN_BUDGET_DAILY%\'} ;;
  esac
fi
# A usable budget is 1 to 9 digits and not zero; leading zeros are decimal ($((08)) would be an octal error).
# Anything else (empty, 0, garbage, too long) means no budget: no alerts and no error output.
case "${TOKEN_BUDGET_DAILY:-}" in
  ''|*[!0-9]*) TOKEN_BUDGET_DAILY="" ;;
  *) if [ "${#TOKEN_BUDGET_DAILY}" -le 9 ]; then TOKEN_BUDGET_DAILY=$((10#$TOKEN_BUDGET_DAILY)); else TOKEN_BUDGET_DAILY=""; fi
     [ "$TOKEN_BUDGET_DAILY" != 0 ] || TOKEN_BUDGET_DAILY="" ;;
esac
DAY=$(date -u -r "$NOW" +%Y-%m-%d)
mkdir -p "$AGENT_HOME/tokens"

LOCK="$AGENT_HOME/watch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(file_mtime "$LOCK") )) -lt 600 ]; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-watch.XXXXXX")
trap 'rm -rf "$LOCK" "$TMP"' EXIT
# Sessions whose meta file has not been written for 48 h are dead (ended ones pile up by the thousand).
# They are skipped on the file's mtime alone, with the builtin -nt: no meta_get, so no fork, per file.
REF="$TMP/ref48h"
touch -t "$(date -r $((NOW - 172800)) +%Y%m%d%H%M.%S)" "$REF"

wnotify() { NOTIFY_CWD="$CWD" NOTIFY_SESSION="$SID" NOTIFY_NOW="$NOW" "$SELF_DIR/notify.sh" "$1" "$2" </dev/null >/dev/null 2>&1 || true; }

tok_add() { # sid n -> add n to today's total for sid
  local f="$AGENT_HOME/tokens/$DAY" cur
  cur=$(awk -v s="$1" '$1 == s { print $2; exit }' "$f" 2>/dev/null || true); [ -n "$cur" ] || cur=0
  { if [ -f "$f" ]; then awk -v s="$1" '$1 != s' "$f"; fi; printf '%s %s\n' "$1" $((cur + $2)); } >"$f.tmp"
  mv "$f.tmp" "$f"
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ -f "$m" ] || continue
  [ "$m" -nt "$REF" ] || continue
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

SPEAK_AFTER_SECS=$(( ${WATCH_SPEAK_AFTER_MINS:-5} * 60 ))
PRESENT_SECS=$(( ${WATCH_PRESENT_MINS:-10} * 60 ))
SPEAK_GAP_SECS=$(( ${WATCH_SPEAK_GAP_MINS:-10} * 60 ))
CONCH_FILE=${VOICEMODE_CONCH:-$HOME/.voicemode/conch}
LAST_SPOKEN="$AGENT_HOME/notify/last-spoken"

hour_ok() { # inside the same window as budgeted banners
  local h; h=$(date -r "$NOW" +%H); h=${h#0}
  [ "$h" -ge "${NOTIFY_QUIET_END:-9}" ] && [ "$h" -lt "${NOTIFY_QUIET_START:-21}" ]
}
user_present() { # keyboard or mouse used within PRESENT_SECS; unreadable counts as absent
  local idle
  if [ -n "${HID_IDLE_CMD:-}" ]; then
    idle=$(bash -c "$HID_IDLE_CMD" 2>/dev/null || true)
  else
    idle=$(ioreg -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }' || true)
  fi
  case "$idle" in ''|*[!0-9]*) return 1 ;; esac
  [ "$idle" -lt "$PRESENT_SECS" ]
}
voice_free() { # false only while another session holds a live, unexpired VoiceMode conch
  local exp secs
  [ -f "$CONCH_FILE" ] || return 0
  exp=$(jq -r 'select(.held == true) | .expires // empty' "$CONCH_FILE" 2>/dev/null || true)
  [ -n "$exp" ] || return 0
  secs=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${exp%%.*}" +%s 2>/dev/null || true)
  case "$secs" in ''|*[!0-9]*) return 0 ;; esac
  [ "$secs" -le "$NOW" ]
}
gap_ok() { # nothing was spoken in the last SPEAK_GAP_SECS
  local last; last=$(cat "$LAST_SPOKEN" 2>/dev/null || echo 0)
  case "$last" in ''|*[!0-9]*) last=0 ;; esac
  [ $((NOW - last)) -ge "$SPEAK_GAP_SECS" ]
}

# 3b. check-in nudges. A session is waiting when its last Stop left it `input`, `blocked`, or `done` with
# something open (a checkpoint blocker or next_action other than "none", or a non-empty NEXT.md), at least
# WATCH_WAIT_GRACE_MINS ago. A spell is identified by the session's `updated` time, so a new Stop or prompt
# starts a new one. input and blocked already got their banner at Stop; `done` only lands in the inbox, so
# the watcher sends it a `waiting` banner, once per spell and only when notify.sh really delivered it.
# A session quiet for more than WATCH_NUDGE_MAX_HOURS is stale, not waiting: no banner and no spoken note.
NOTIFY_LOG_FILE=${NOTIFY_LOG:-$AGENT_HOME/notify.log}
GRACE_SECS=$(( ${WATCH_WAIT_GRACE_MINS:-2} * 60 ))
MAX_AGE_SECS=$(( ${WATCH_NUDGE_MAX_HOURS:-12} * 3600 )) # older than this is stale, not waiting

log_lines() { if [ -f "$NOTIFY_LOG_FILE" ]; then wc -l <"$NOTIFY_LOG_FILE" | tr -d ' '; else echo 0; fi; }
open_value() { # text -> text, or nothing when it is blank or "none"
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in ''|none) ;; *) printf '%s' "$1" ;; esac
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ -f "$m" ] || continue
  SESS_DIR=$(dirname "$m"); SID=$(basename "$SESS_DIR")
  state=$(meta_get "$m" state)
  case "$state" in input|blocked|done) ;; *) continue ;; esac
  upd=$(meta_get "$m" updated)
  case "$upd" in ''|*[!0-9]*) continue ;; esac
  age=$((NOW - upd))
  [ "$age" -ge "$GRACE_SECS" ] || continue
  [ "$age" -le "$MAX_AGE_SECS" ] || continue
  CWD=$(meta_get "$m" cwd); NAME=$(meta_get "$m" name); ROOT=$(meta_get "$m" root)
  resolve_state
  nxt=$(open_value "$(checkpoint_get "$STATE_DIR/STATE.md" next_action)")
  blk=$(open_value "$(checkpoint_get "$STATE_DIR/STATE.md" blocker)")
  if [ "$state" = "done" ] && [ -z "$nxt" ] && [ -z "$blk" ]; then
    { [ -f "$STATE_DIR/NEXT.md" ] && grep -q '[^[:space:]]' "$STATE_DIR/NEXT.md"; } || continue
  fi
  if [ "$state" = "done" ] && [ "$(meta_get "$m" nudged_for)" != "$upd" ]; then
    before=$(log_lines)
    wnotify waiting "${nxt:-$blk}"
    method=$(tail -1 "$NOTIFY_LOG_FILE" 2>/dev/null | cut -f2 || true)
    case "$method" in
      suppressed:*) ;;
      *) if [ "$(log_lines)" -gt "$before" ]; then
           meta_set nudged_for "$upd"
           ev waiting "$(jq -nc --argjson m $((age / 60)) --arg s "$state" '{mins:$m,state:$s}')"
         fi ;;
    esac
  fi
  # spoken note: once per spell, only when it can be heard and will not talk over anyone
  [ "$age" -ge "$SPEAK_AFTER_SECS" ] || continue
  [ "$(meta_get "$m" spoken_for)" != "$upd" ] || continue
  hour_ok && user_present && voice_free && gap_ok || continue
  dflt="it needs your input"; [ "$state" != blocked ] || dflt="it is blocked"
  mins=$((age / 60))
  say=$(printf '%s has been waiting %s minutes: %s.' "$NAME" "$mins" "${nxt:-${blk:-$dflt}}" | tr '\n\r' '  ' | cut -c1-300)
  mkdir -p "$AGENT_HOME/notify"
  if "${SPEAK_CMD:-$SELF_DIR/speak.sh}" "$say" >/dev/null 2>&1; then
    meta_set spoken_for "$upd"
    printf '%s\n' "$NOW" >"$LAST_SPOKEN"
    ev nudge_spoken "$(jq -nc --argjson m "$mins" '{mins:$m}')"
  fi
done # end of nudge pass

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
