#!/usr/bin/env bash
# ching-watch.sh: tokens (dedupe, incremental, today only), context levels, stall, budget alerts,
# rotation, lock, shrinking transcripts.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
W="$BIN/ching-watch.sh"
DAY=$(date -u +%Y-%m-%d)
NOW=$(date +%s)
P="$WORK/proj"; mkdir -p "$P"
EVF="$AGENT_HOME/events.jsonl"
TOK="$AGENT_HOME/tokens/$DAY"
reg() { # sid state transcript
  local d="$AGENT_HOME/sessions/$1"; mkdir -p "$d"
  printf 'cwd=%s\nname=proj\nstate=%s\ntranscript=%s\nupdated=%s\n' "$P" "$2" "$3" "$NOW" >"$d/meta"
}
mget() { meta_get "$AGENT_HOME/sessions/$1/meta" "$2"; }
amsg() { # id input cache_read cache_create output [day]
  jq -nc --arg id "$1" --arg ts "${6:-$DAY}T10:00:00.000Z" --argjson i "$2" --argjson r "$3" --argjson c "$4" --argjson o "$5" \
    '{type:"assistant",timestamp:$ts,message:{id:$id,model:"claude-opus-5-5",usage:{input_tokens:$i,cache_read_input_tokens:$r,cache_creation_input_tokens:$c,output_tokens:$o}}}'
}
tok_of() { awk -v s="$1" '$1 == s { print $2 }' "$TOK" 2>/dev/null; }

# tokens: duplicate lines per message id count once; malformed lines skipped; context from the last message
T1="$WORK/t1.jsonl"
{ echo '{"type":"user","message":{"content":"hi"}}'; amsg m1 2 100000 10 50; amsg m1 2 100000 10 50; echo 'not json'; amsg m2 1 110000 5 20; } >"$T1"
reg s1 idle "$T1"
assert_ok "watch run exits 0" "$W"
assert_eq "tokens: (50+2+10)+(20+1+5) with duplicate m1 counted once" "88" "$(tok_of s1)"
assert_eq "context: 110006 of 200k is healthy" "healthy" "$(mget s1 ctx_level)"
assert_eq "context: pct stored" "55" "$(mget s1 ctx_pct)"
amsg m3 0 130000 0 10 >>"$T1"
"$W"
assert_eq "incremental: only the new message is added" "98" "$(tok_of s1)"
assert_eq "context: 65% is watch" "watch" "$(mget s1 ctx_level)"
assert_contains "events: context change logged" "$(jq -r 'select(.kind=="context") | .data.level' "$EVF")" "watch"
"$W"
assert_eq "re-run without new lines adds nothing" "98" "$(tok_of s1)"
amsg m3 0 130000 0 10 >>"$T1"
"$W"
assert_eq "a duplicate of the last message across runs is not counted" "98" "$(tok_of s1)"
amsg m4 0 170000 0 0 >>"$T1"
"$W"
assert_eq "context: 85% is handoff" "handoff" "$(mget s1 ctx_level)"
assert_contains "handoff notifies (budgeted kind)" "$(cat "$AGENT_HOME/notify.log")" "Context almost full"

# a context above 200k means a 1M window
T2="$WORK/t2.jsonl"; amsg n1 0 500000 0 1 >"$T2"; reg s2 idle "$T2"; "$W"
assert_eq "1M window detected: 500k is healthy" "healthy" "$(mget s2 ctx_level)"

# messages from another day are not counted today
T3="$WORK/t3.jsonl"; amsg o1 0 1000 0 999 2020-01-01 >"$T3"; reg s3 idle "$T3"; "$W"
assert_eq "old-day tokens are not counted" "" "$(tok_of s3)"

# a partial last line waits for the next run
T4="$WORK/t4.jsonl"; { amsg p1 0 1000 0 5; printf '{"type":"assist'; } >"$T4"; reg s4 idle "$T4"; "$W"
full=$(amsg p1 0 1000 0 5 | wc -c | tr -d ' ')
assert_eq "offset stops at the last newline" "$full" "$(mget s4 tok_offset)"

# Review Focus 4: a transcript that shrinks resets the offset
amsg r1 0 1 0 7 >"$T4"; "$W"   # shorter than the old content, so the file shrank
assert_eq "shrunk transcript: offset reset and re-read" "$(wc -c <"$T4" | tr -d ' ')" "$(mget s4 tok_offset)"
assert_eq "shrunk transcript: new message counted" "12" "$(tok_of s4)"
# an emptied transcript must not leave the old offset behind: a regrown file is read from the start
: >"$T4"; "$W"
assert_eq "emptied transcript: stored offset reset to 0" "0" "$(mget s4 tok_offset)"
amsg r2 0 1 0 9 >"$T4"; "$W"   # same size as the r1 line, which is what the stale offset was
assert_eq "emptied then regrown transcript is read from the start" "21" "$(tok_of s4)"

# stall: working session with a transcript untouched for 20+ minutes, reported once, cleared on progress
T5="$WORK/t5.jsonl"; amsg w1 0 1000 0 1 >"$T5"; touch -t 202001010000 "$T5"; reg s5 working "$T5"
"$W"
assert_contains "stall: stalled_at set" "$(cat "$AGENT_HOME/sessions/s5/meta")" "stalled_at=1"
assert_contains "stall: notification" "$(cat "$AGENT_HOME/notify.log")" "proj: Stalled"
"$W"
assert_eq "stall: reported once" "1" "$(jq -r 'select(.kind=="stall" and .sid=="s5") | .kind' "$EVF" | wc -l | tr -d ' ')"
touch "$T5"; "$W"
assert_eq "stall: cleared after progress" "" "$(mget s5 stalled_at)"
T6="$WORK/t6.jsonl"; amsg e1 0 1 0 1 >"$T6"; touch -t 202001010000 "$T6"; reg s6 ended "$T6"; "$W"
assert_eq "ended sessions are skipped" "" "$(mget s6 stalled_at)"
reg s8 working "$WORK/missing.jsonl"
assert_ok "missing transcript does not break the run" "$W"

# daily token budget: one alert at 80% and one at 100%, never repeated
TOKEN_BUDGET_DAILY=50 "$W"; TOKEN_BUDGET_DAILY=50 "$W"
assert_file "budget: 80% flag" "$TOK.alert80"
assert_file "budget: 100% flag" "$TOK.alert100"
assert_eq "budget: two token events, not repeated" "2" "$(jq -r 'select(.kind=="tokens") | .kind' "$EVF" | wc -l | tr -d ' ')"

# lock: a fresh lock means another run is busy; a lock older than 10 minutes is stale
T7="$WORK/t7.jsonl"; amsg l1 0 1 0 1 >"$T7"; touch -t 202001010000 "$T7"; reg s7 working "$T7"
mkdir "$AGENT_HOME/watch.lock"; "$W"
assert_eq "fresh lock: run skipped" "" "$(mget s7 stalled_at)"
touch -t 202001010000 "$AGENT_HOME/watch.lock"; "$W"
assert_contains "stale lock: run proceeds" "$(cat "$AGENT_HOME/sessions/s7/meta")" "stalled_at=1"
assert_no_file "lock removed after the run" "$AGENT_HOME/watch.lock"

# rotation
WATCH_ROTATE_BYTES=10 "$W"
assert_no_file "events.jsonl rotated away" "$EVF"
assert_eq "one rotated file kept" "1" "$(ls "$AGENT_HOME"/events-*.jsonl | wc -l | tr -d ' ')"

# ---------- fix wave FC1-1: TOKEN_BUDGET_DAILY parsing ----------
# Each case runs in its own AGENT_HOME that holds one day total (no sessions), so only the budget code runs.
bud_flags() { # agent_home -> "80", "80 100", "100" or ""
  local f=""
  if [ -f "$1/tokens/$DAY.alert80" ]; then f="80"; fi
  if [ -f "$1/tokens/$DAY.alert100" ]; then f="$f${f:+ }100"; fi
  printf '%s' "$f"
}
bud() { # name day_total expected_alerts expected_token_events env_value("-" = unset) [ching.env line]
  local ah="$WORK/bud-$1"
  rm -rf "$ah"; mkdir -p "$ah/tokens" "$ah/defaults"
  printf 'mach %s\n' "$2" >"$ah/tokens/$DAY"
  if [ -n "${6:-}" ]; then printf '%s\n' "$6" >"$ah/defaults/ching.env"; fi
  if [ "$5" = "-" ]; then AGENT_HOME="$ah" "$W" 2>"$ah/err"; else AGENT_HOME="$ah" TOKEN_BUDGET_DAILY="$5" "$W" 2>"$ah/err"; fi
  assert_eq "budget $1: alerts fired" "$3" "$(bud_flags "$ah")"
  assert_eq "budget $1: token events" "$4" "$(jq -r 'select(.kind=="tokens") | .kind' "$ah/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
  assert_eq "budget $1: stderr is empty" "" "$(cat "$ah/err")"
}
bud octal-env 9 "80 100" 2 08 ""
assert_eq "budget octal-env: the budget is read as decimal 8" "8 8" "$(jq -r 'select(.kind=="tokens") | .data.budget' "$WORK/bud-octal-env/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//')"
bud octal-file 9 "80 100" 2 - "TOKEN_BUDGET_DAILY=08"
bud zero-env 9 "" 0 0 ""
bud zero-file 9 "" 0 - "TOKEN_BUDGET_DAILY=0"
bud zeros-only 9 "" 0 000 ""
bud export-quoted 85 "80" 1 - 'export TOKEN_BUDGET_DAILY="100"'
bud single-quoted 85 "80" 1 - "TOKEN_BUDGET_DAILY='100'"
bud plain-file 85 "80" 1 - "TOKEN_BUDGET_DAILY=100"
bud export-zero-padded 9 "80 100" 2 - "export TOKEN_BUDGET_DAILY=0008"
bud garbage-env 9 "" 0 abc ""
bud negative-env 9 "" 0 -5 ""
bud ten-digits-env 9 "" 0 1000000000 ""
bud garbage-file 9 "" 0 - 'TOKEN_BUDGET_DAILY="1x0"'
bud empty-file 9 "" 0 - "TOKEN_BUDGET_DAILY="
bud nine-digits-file 9 "" 0 - "TOKEN_BUDGET_DAILY=999999999"

# ---------- fix wave FC1-2: a session whose meta file is older than 48 h is skipped before any key is read ----------
OAH="$WORK/old-ah"; mkdir -p "$OAH/sessions"
oreg() { # sid state transcript meta_age_secs : session in the old-ah sandbox whose meta file is that old
  local d="$OAH/sessions/$1"; mkdir -p "$d"
  printf 'cwd=%s\nname=proj\nstate=%s\ntranscript=%s\nupdated=%s\n' "$P" "$2" "$3" "$NOW" >"$d/meta"
  touch -t "$(date -r $((NOW - $4)) +%Y%m%d%H%M.%S)" "$d/meta"
}
TO1="$WORK/o1.jsonl"; amsg q1 0 1 0 1 >"$TO1"; touch -t 202001010000 "$TO1"; oreg o1 working "$TO1" 259200   # 3 days old
TO2="$WORK/o2.jsonl"; amsg q2 0 1 0 1 >"$TO2"; touch -t 202001010000 "$TO2"; oreg o2 working "$TO2" 144000   # 40 h old: inside the window
TO3="$WORK/o3.jsonl"; amsg q3 0 1000 0 77 >"$TO3"; oreg o3 idle "$TO3" 259200                                # 3 days old, unread tokens
AGENT_HOME="$OAH" "$W"
assert_eq "old meta: a silent working session is not stalled" "" "$(meta_get "$OAH/sessions/o1/meta" stalled_at)"
assert_eq "old meta: no stall event for it" "0" "$(jq -r 'select(.kind=="stall" and .sid=="o1") | .kind' "$OAH/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "old meta: its transcript is not read" "" "$(awk '$1 == "o3" { print $2 }' "$OAH/tokens/$DAY" 2>/dev/null)"
assert_eq "old meta: its meta is left untouched" "" "$(meta_get "$OAH/sessions/o3/meta" tok_offset)"
assert_contains "meta inside 48 h still stalls" "$(cat "$OAH/sessions/o2/meta")" "stalled_at=1"
assert_eq "meta inside 48 h: one stall event" "1" "$(jq -r 'select(.kind=="stall" and .sid=="o2") | .kind' "$OAH/events.jsonl" | wc -l | tr -d ' ')"

# ---------- a resumed session that nobody has prompted is not stalled ----------
# SessionStart used to set state=working, so a resumed session with a transcript older than WATCH_STALL_MINS
# was reported stalled at the next run, and the alert used up the shared daily budget.
RAH="$WORK/resume-ah"; mkdir -p "$RAH"
TR1="$WORK/resumed.jsonl"; amsg rs1 0 1000 0 1 >"$TR1"; touch -t 202001010000 "$TR1"
( export AGENT_HOME="$RAH"
  run_hook session-start.sh "$(hook_json SessionStart "$P" s-resumed "$(jq -nc --arg t "$TR1" '{source:"resume",transcript_path:$t}')")" >/dev/null )
AGENT_HOME="$RAH" "$W"
assert_eq "resume: a resumed session with an old transcript is not stalled" "" "$(meta_get "$RAH/sessions/s-resumed/meta" stalled_at)"
assert_eq "resume: no stall event" "0" "$(jq -r 'select(.kind=="stall") | .kind' "$RAH/events.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
assert_no_file "resume: no alert was sent at all" "$RAH/notify.log"
assert_eq "resume: no daily budget used" "0" "$(ls "$RAH/notify" 2>/dev/null | grep -c '^budget' || true)"
( export AGENT_HOME="$RAH"; printf '%s' "$(hook_json UserPromptSubmit "$P" s-resumed)" | "$BIN/session-start.sh" touch )
AGENT_HOME="$RAH" "$W"
assert_contains "resume: after a prompt the same silence is a stall" "$(cat "$RAH/sessions/s-resumed/meta")" "stalled_at=1"
assert_contains "resume: and then the alert is sent" "$(cat "$RAH/notify.log")" "proj: Stalled"
exit 0
