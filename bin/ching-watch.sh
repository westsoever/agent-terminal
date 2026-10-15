#!/usr/bin/env bash
# ching-watch.sh - one-shot watcher, run every 5 minutes by launchd (org.ching.watch). Not a daemon.
# For every live session in $AGENT_HOME/sessions: stall detection, context pressure and today's token
# total, read incrementally from the transcript (byte offset in meta). Then token-budget alerts and
# events.jsonl rotation. It never touches a session: it writes meta keys, $AGENT_HOME/tokens/<UTC day>,
# events and notifications only.
# Meta keys written: tok_offset tok_last_mid ctx_level ctx_pct stalled_at
# Check-in nudges (3b): sessions waiting on the user get a `waiting` banner (finished sessions with open
# work) and, after a delay, one spoken note. Meta keys: nudged_for spoken_for. Env: WATCH_WAIT_GRACE_MINS (2)
# WATCH_NUDGE_MAX_HOURS (12; 0 switches nudging off) WATCH_SPEAK_AFTER_MINS (5) WATCH_PRESENT_MINS (10)
# WATCH_SPEAK_GAP_MINS (10) NOTIFY_QUIET_START (21) NOTIFY_QUIET_END (9). A knob that is not plain digits
# falls back to its default. For tests: SPEAK_CMD, HID_IDLE_CMD (a shell command that prints idle seconds),
# IOREG_CMD (default /usr/sbin/ioreg: launchd's PATH has no /usr/sbin), VOICEMODE_CONCH (the conch file),
# VOICEMODE_CONCH_LOCK_EXPIRY (VoiceMode's own active-call window, default 300 s).
# Git sync check (4b): starts bin/sync-check.sh in the background, detached, with its own lock and a hard time
# ceiling, at most every SYNC_CHECK_INTERVAL_H (6; 0 switches it off) hours. $AGENT_HOME/sync-check.stamp holds the time
# of the last start; a snapshot younger than the interval (an on-demand run) counts as a run too. The tick never waits
# for it; a failure of the check is a line in $AGENT_HOME/watch.log, never a non-zero exit. Env: SYNC_CHECK_MAX_SECS
# (300) SYNC_CHECK_CMD (tests).
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
num_or() { # value default -> value as a decimal number when it is 1 to 9 digits, else default (never fails)
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) if [ "${#1}" -le 9 ]; then printf '%s' $((10#$1)); else printf '%s' "$2"; fi ;;
  esac
}
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
  # Records whose usage totals are zero (model "<synthetic>": API error, rate limit, interrupt) say nothing
  # about the context window, so they are skipped: read as the last message they reset ctx_level to healthy.
  jq -cR --arg day "$DAY" 'fromjson? | select(.type == "assistant" and ((.message.usage // null) | type) == "object")
      | select((.message.usage | (.input_tokens // 0) + (.output_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) > 0)
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

# A knob that is not plain digits (a typo in launchd's environment, "1.5") falls back to its default: the
# nudge pass must never end the tick early, because the token budget and the log rotation come after it.
SPEAK_AFTER_SECS=$(( $(num_or "${WATCH_SPEAK_AFTER_MINS:-}" 5) * 60 ))
PRESENT_SECS=$(( $(num_or "${WATCH_PRESENT_MINS:-}" 10) * 60 ))
SPEAK_GAP_SECS=$(( $(num_or "${WATCH_SPEAK_GAP_MINS:-}" 10) * 60 ))
QUIET_END=$(num_or "${NOTIFY_QUIET_END:-}" 9)
QUIET_START=$(num_or "${NOTIFY_QUIET_START:-}" 21)
# VoiceMode's own window for an active call (VOICEMODE_CONCH_LOCK_EXPIRY, default 300 s; 0 = never stale there)
CONCH_ACTIVE_SECS=$(num_or "$(printf '%s' "${VOICEMODE_CONCH_LOCK_EXPIRY:-}" | sed 's/\..*//')" 300)
[ "$CONCH_ACTIVE_SECS" -gt 0 ] || CONCH_ACTIVE_SECS=300
CONCH_FILE=${VOICEMODE_CONCH:-$HOME/.voicemode/conch}
LAST_SPOKEN="$AGENT_HOME/notify/last-spoken"

hour_ok() { # inside the same window as budgeted banners
  local h; h=$(date -r "$NOW" +%H); h=${h#0}
  [ "$h" -ge "$QUIET_END" ] && [ "$h" -lt "$QUIET_START" ]
}
user_present() { # keyboard or mouse used within PRESENT_SECS; unreadable counts as absent
  local idle
  if [ -n "${HID_IDLE_CMD:-}" ]; then
    idle=$(bash -c "$HID_IDLE_CMD" 2>/dev/null || true)
  else
    # absolute path: ioreg is in /usr/sbin, which is not on the PATH of the launchd job
    idle=$("${IOREG_CMD:-/usr/sbin/ioreg}" -c IOHIDSystem 2>/dev/null | awk '/"HIDIdleTime"/ { print int($NF / 1000000000); exit }' || true)
  fi
  case "$idle" in ''|*[!0-9]*) return 1 ;; esac
  [ "$idle" -lt "$PRESENT_SECS" ]
}
conch_secs() { # ISO local time as VoiceMode writes it -> epoch, or nothing when it does not parse
  local secs; secs=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null || true)
  case "$secs" in ''|*[!0-9]*) ;; *) printf '%s' "$secs" ;; esac
}
voice_free() { # false while VoiceMode is in use: a live process with an active call or an unexpired hold
  # VoiceMode writes ~/.voicemode/conch for the whole call (held:false, acquired = call start) and between
  # turns as a short hold (held:true, absolute expires). Anything else is free: no file, not a JSON object,
  # no live pid, an expired hold, a call older than VoiceMode's own stale window, a timestamp that does not parse.
  local out pid held exp acq secs
  [ -f "$CONCH_FILE" ] || return 0
  out=$(jq -r 'if type == "object" then
      [(.pid | if type == "number" and . == floor and . >= 1 then tostring else "" end),
       (.held == true | tostring),
       (.expires | if type == "string" then . else "" end),
       (.acquired | if type == "string" then . else "" end)] | join("|") else empty end' "$CONCH_FILE" 2>/dev/null || true)
  [ -n "$out" ] || return 0
  IFS='|' read -r pid held exp acq <<<"$out" || true
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#pid}" -le 7 ] || return 0
  if ! kill -0 "$pid" 2>/dev/null; then return 0; fi
  if [ "$held" = true ]; then
    secs=$(conch_secs "$exp"); [ -n "$secs" ] || return 0
    [ "$secs" -le "$NOW" ]                        # a hold is over once its expires has passed
  else
    secs=$(conch_secs "$acq"); [ -n "$secs" ] || return 0
    [ $((NOW - secs)) -gt "$CONCH_ACTIVE_SECS" ]  # a call is over once it is older than the stale window
  fi
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
GRACE_SECS=$(( $(num_or "${WATCH_WAIT_GRACE_MINS:-}" 2) * 60 ))
MAX_AGE_SECS=$(( $(num_or "${WATCH_NUDGE_MAX_HOURS:-}" 12) * 3600 )) # older than this is stale, not waiting; 0 = nudging off
# A meta file is rewritten at every update, so its mtime is never older than `updated`: a meta untouched for
# longer than the cap cannot be a live spell. Skipped on the mtime alone with the builtin -nt (no fork per file),
# the way the 48 h pass above does it. The age check below stays: a fresh meta can carry an old `updated`.
NREF="$TMP/nref"
nref_epoch=$((NOW - MAX_AGE_SECS)); [ "$nref_epoch" -gt 86400 ] || nref_epoch=86400
touch -t "$(date -r "$nref_epoch" +%Y%m%d%H%M.%S)" "$NREF"
SPEAK_FAILED=0 # one failed speak per tick is enough: a hung Kokoro must not cost 30 s per waiting session

log_lines() { # number of lines in notify.log; 0 when it is missing or unreadable
  local n; n=$({ wc -l <"$NOTIFY_LOG_FILE"; } 2>/dev/null | tr -d ' ') || n=""
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}
open_value() { # text -> text, or nothing when it is blank or a "nothing here" sentinel (same list as dash.sh is_none)
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in ''|none|'(none)'|none.) ;; *) printf '%s' "$1" ;; esac
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ "$MAX_AGE_SECS" -gt 0 ] || break
  [ -f "$m" ] || continue
  [ "$m" -nt "$NREF" ] || continue
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
  [ "$SPEAK_FAILED" = 0 ] || continue
  hour_ok && user_present && voice_free && gap_ok || continue
  dflt="it needs your input"; [ "$state" != blocked ] || dflt="it is blocked"
  mins=$((age / 60))
  say=$(printf '%s has been waiting %s minutes: %s.' "$NAME" "$mins" "${nxt:-${blk:-$dflt}}" | tr '\n\r' '  ' | cut -c1-300)
  mkdir -p "$AGENT_HOME/notify"
  if "${SPEAK_CMD:-$SELF_DIR/speak.sh}" "$say" >/dev/null 2>&1; then
    meta_set spoken_for "$upd"
    printf '%s\n' "$NOW" >"$LAST_SPOKEN"
    ev nudge_spoken "$(jq -nc --argjson m "$mins" '{mins:$m}')"
  else
    SPEAK_FAILED=1 # nothing is stamped: the spell and the speech gap stay open for the next tick
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

# 4b. git sync check. Started in the background, never waited for: a small perl supervisor forks, setsid()s into a
# session of its own (launchd ends the job's own process group when the tick exits; this one is not in it), runs
# sync-check.sh with stdout and stderr appended to watch.log, and stops it (TERM, then KILL) at SYNC_CHECK_MAX_SECS.
# The start is stamped before it is attempted, so a check that keeps failing is retried at the next interval, not
# every 5 minutes. Any trouble becomes a line in watch.log; nothing here can fail the tick.
SYNC_INTERVAL_SECS=$(( $(num_or "${SYNC_CHECK_INTERVAL_H-}" 6) * 3600 )) # 0 = off
SYNC_STAMP="$AGENT_HOME/sync-check.stamp"
sync_due() { # not started for SYNC_INTERVAL_SECS, and no snapshot younger than that either
  local st mt
  st=$(cat "$SYNC_STAMP" 2>/dev/null || echo 0); case "$st" in ''|*[!0-9]*) st=0 ;; esac
  [ "$st" -le $((NOW + 60)) ] || st=0 # a stamp from the future (clock set back) must not block the check for good
  [ $((NOW - st)) -ge "$SYNC_INTERVAL_SECS" ] || return 1
  mt=$(file_mtime "$AGENT_HOME/sync-check.md")
  [ "$mt" -le $((NOW + 60)) ] || mt=0
  [ $((NOW - mt)) -ge "$SYNC_INTERVAL_SECS" ]
}
sync_launch() { # MAX_SECS LOG CMD ARGS... : returns at once; the check runs on in its own session
  perl -e '
    use POSIX ();
    my ($max, $log, @cmd) = @ARGV;
    my $note = sub {
      open(my $fh, ">>", $log) or return;
      my @t = gmtime;
      printf $fh "%04d-%02d-%02dT%02d:%02d:%02dZ ching-watch: %s\n", $t[5] + 1900, $t[4] + 1, @t[3, 2, 1, 0], $_[0];
      close $fh;
    };
    my $p = fork;
    defined $p or exit 1;
    exit 0 if $p;
    POSIX::setsid();
    POSIX::nice(10);                       # a background chore: git status over every repo must not compete with the user
    open(STDIN, "<", "/dev/null"); open(STDOUT, ">>", $log); open(STDERR, ">&STDOUT");
    my $k = fork;
    defined $k or do { $note->("sync-check: fork failed"); exit 1 };
    if (!$k) { exec { $cmd[0] } @cmd; $note->("sync-check: cannot start $cmd[0]: $!"); POSIX::_exit(127) }
    $SIG{ALRM} = sub {
      $SIG{TERM} = "IGNORE";
      $note->("sync-check: stopped after ${max}s (time ceiling)");
      kill "TERM", -$$; select undef, undef, undef, 2; kill "KILL", -$$; exit 142;
    };
    alarm $max;
    waitpid($k, 0);
    my $s = $?;
    alarm 0;
    if ($s & 127) { $note->(sprintf("sync-check: killed by signal %d", $s & 127)) }
    elsif (($s >> 8) != 0 && ($s >> 8) != 127) { $note->(sprintf("sync-check: exited with status %d", $s >> 8)) }
    exit 0;
  ' "$@"
}
if [ "$SYNC_INTERVAL_SECS" -gt 0 ] && sync_due; then
  { printf '%s\n' "$NOW" >"$SYNC_STAMP.tmp" && mv -f "$SYNC_STAMP.tmp" "$SYNC_STAMP"; } 2>/dev/null || true
  SYNC_MAX=$(num_or "${SYNC_CHECK_MAX_SECS-}" 300); [ "$SYNC_MAX" -gt 0 ] || SYNC_MAX=300
  if ! sync_launch "$SYNC_MAX" "$AGENT_HOME/watch.log" "${SYNC_CHECK_CMD:-$SELF_DIR/sync-check.sh}" --quiet </dev/null >/dev/null 2>&1; then
    printf '%s ching-watch: sync-check could not be started\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$AGENT_HOME/watch.log" 2>/dev/null || true
  fi
fi

# 5. rotation
EVF="$AGENT_HOME/events.jsonl"
if [ -f "$EVF" ] && [ "$(wc -c <"$EVF" | tr -d ' ')" -gt "${WATCH_ROTATE_BYTES:-20971520}" ]; then
  mv "$EVF" "$AGENT_HOME/events-$(date -u -r "$NOW" +%Y%m%d-%H%M%S).jsonl"
fi
exit 0
