#!/usr/bin/env bash
# kaching-watch.sh: tokens (dedupe, incremental, today only), context levels, stall, budget alerts,
# rotation, lock, shrinking transcripts.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
W="$BIN/kaching-watch.sh"
export SYNC_CHECK_CMD=true   # the watcher starts the git sync check in the background: not the real one in these sections
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

# ---------- a zero-usage record (API error, interrupt) must not reset the context level ----------
# Claude Code writes a synthetic assistant record with model "<synthetic>" and all-zero usage for a login
# error, a rate limit or an interrupt. Read as the last message it made the context 0%, so ctx_level fell
# from handoff to healthy and the next real message raised a second handoff notice.
zmsg() { # id : the record Claude Code writes for an API error
  jq -nc --arg id "$1" --arg ts "${DAY}T10:00:00.000Z" \
    '{type:"assistant",timestamp:$ts,error:"authentication_failed",isApiErrorMessage:true,
      message:{id:$id,model:"<synthetic>",role:"assistant",content:[{type:"text",text:"Login expired"}],
        usage:{input_tokens:0,output_tokens:0,cache_creation_input_tokens:0,cache_read_input_tokens:0}}}'
}
ZAH="$WORK/zero-ah"; mkdir -p "$ZAH/sessions/z1" "$ZAH/sessions/z2" "$ZAH/sessions/z3"
zreg() { printf 'cwd=%s\nname=proj\nstate=idle\ntranscript=%s\nupdated=%s\n' "$P" "$2" "$NOW" >"$ZAH/sessions/$1/meta"; }
zget() { meta_get "$ZAH/sessions/$1/meta" "$2"; }
zhand() { grep -c 'Context almost full' "$ZAH/notify.log" 2>/dev/null || true; }
zctx() { jq -r 'select(.kind=="context" and .sid=="'"$1"'") | .data.level' "$ZAH/events.jsonl" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

# a zero record arrives in a later run
TZ1="$WORK/z1.jsonl"; amsg zm1 0 170000 0 10 >"$TZ1"; zreg z1 "$TZ1"
AGENT_HOME="$ZAH" "$W"
assert_eq "zero usage: 85% is handoff" "handoff" "$(zget z1 ctx_level)"
assert_eq "zero usage: one handoff notice so far" "1" "$(zhand)"
zmsg zz1 >>"$TZ1"; AGENT_HOME="$ZAH" "$W"
assert_eq "zero usage: a later synthetic record keeps handoff" "handoff" "$(zget z1 ctx_level)"
assert_eq "zero usage: the percentage is kept" "85" "$(zget z1 ctx_pct)"
assert_eq "zero usage: the last real message id is kept" "zm1" "$(zget z1 tok_last_mid)"
assert_eq "zero usage: the synthetic record is consumed" "$(wc -c <"$TZ1" | tr -d ' ')" "$(zget z1 tok_offset)"
amsg zm2 0 175000 0 10 >>"$TZ1"; AGENT_HOME="$ZAH" "$W"
assert_eq "zero usage: the next real message is still handoff" "handoff" "$(zget z1 ctx_level)"
assert_eq "zero usage: no second handoff notice" "1" "$(zhand)"
assert_eq "zero usage: only one context event" "handoff" "$(zctx z1)"
assert_eq "zero usage: a synthetic record adds no tokens" "20" "$(awk '$1 == "z1" { print $2 }' "$ZAH/tokens/$DAY")"

# a real message and a zero record in the same new chunk: the zero record is last
TZ2="$WORK/z2.jsonl"; { amsg zm3 0 170000 0 10; zmsg zz2; } >"$TZ2"; zreg z2 "$TZ2"
AGENT_HOME="$ZAH" "$W"
assert_eq "zero usage: a zero record last in the chunk is ignored" "handoff" "$(zget z2 ctx_level)"
assert_eq "zero usage: percentage from the real message" "85" "$(zget z2 ctx_pct)"

# only zero records, no usage ever seen: nothing is invented
TZ3="$WORK/z3.jsonl"; zmsg zz3 >"$TZ3"; zreg z3 "$TZ3"
AGENT_HOME="$ZAH" "$W" 2>"$ZAH/err"
assert_eq "zero usage only: ctx_level stays unset" "" "$(zget z3 ctx_level)"
assert_eq "zero usage only: no percentage" "" "$(zget z3 ctx_pct)"
assert_eq "zero usage only: no error output" "" "$(cat "$ZAH/err")"
assert_eq "zero usage only: the record is still consumed" "$(wc -c <"$TZ3" | tr -d ' ')" "$(zget z3 tok_offset)"

# ---------- git sync check: started in the background, at most every SYNC_CHECK_INTERVAL_H hours ----------
# A fake command records every invocation. The watcher must start it detached (never wait for it), keep its
# own stamp, and turn a failure of the check into a line in watch.log, never into a failed watcher run.
SAH="$WORK/sync-ah"; SREC="$WORK/sync-rec.log"
cat >"$WORK/sync-fake.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$AGENT_HOME" "\$*" >>"$SREC"
case "\${FAKE_MODE:-}" in fail) exit 3 ;; hang) sleep 25.31 ;; slow) sleep 4 ;; esac
exit 0
EOF
chmod +x "$WORK/sync-fake.sh"
export SYNC_CHECK_CMD="$WORK/sync-fake.sh"
sreset() { rm -rf "$SAH"; mkdir -p "$SAH"; : >"$SREC"; }
srun() { AGENT_HOME="$SAH" WATCH_NOW="${1:-$NOW}" "$W"; }          # watcher with a fake clock (default: now)
scalls() { wc -l <"$SREC" | tr -d ' '; }
swait() { local i=0; while [ "$(scalls)" -lt "$1" ] && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done; }   # up to 6 s for N calls
wlog_has() { local i=0; while ! grep -q "$1" "$SAH/watch.log" 2>/dev/null && [ "$i" -lt 60 ]; do sleep 0.1; i=$((i + 1)); done; grep -c "$1" "$SAH/watch.log" 2>/dev/null || true; }

sreset; srun; swait 1
assert_eq "sync: the first tick starts the check once" "1" "$(scalls)"
assert_eq "sync: ... with --quiet and the watcher's AGENT_HOME" "$SAH|--quiet" "$(cat "$SREC")"
assert_eq "sync: the stamp holds the tick time" "$NOW" "$(cat "$SAH/sync-check.stamp")"
srun; sleep 1
assert_eq "sync: the next tick, seconds later, does not start it again" "1" "$(scalls)"
srun $((NOW + 5 * 3600 + 3540)); sleep 1
assert_eq "sync: 5 h 59 min later is still inside the 6 h interval" "1" "$(scalls)"
srun $((NOW + 6 * 3600)); swait 2
assert_eq "sync: 6 h later it runs again" "2" "$(scalls)"
srun $((NOW + 6 * 3600 + 300)); sleep 1
assert_eq "sync: and the interval restarts from that run" "2" "$(scalls)"

sreset; SYNC_CHECK_INTERVAL_H=1 srun; swait 1
SYNC_CHECK_INTERVAL_H=1 srun $((NOW + 1800)); sleep 1
assert_eq "sync: SYNC_CHECK_INTERVAL_H=1: 30 min later nothing" "1" "$(scalls)"
SYNC_CHECK_INTERVAL_H=1 srun $((NOW + 3700)); swait 2
assert_eq "sync: SYNC_CHECK_INTERVAL_H=1: after an hour it runs" "2" "$(scalls)"
sreset; SYNC_CHECK_INTERVAL_H=0 srun; sleep 1
assert_eq "sync: SYNC_CHECK_INTERVAL_H=0 switches the check off" "0" "$(scalls)"
assert_no_file "sync: ... and leaves no stamp" "$SAH/sync-check.stamp"
sreset; SYNC_CHECK_INTERVAL_H=soon srun; swait 1
assert_eq "sync: a junk interval falls back to the default and still runs" "1" "$(scalls)"
sreset; : >"$SAH/sync-check.md"; touch -t "$(date -r "$NOW" +%Y%m%d%H%M.%S)" "$SAH/sync-check.md"   # made "now" on the fake clock:
srun; sleep 1   # under the parallel suite this line runs minutes after NOW was set, past the 60 s future-mtime guard
assert_eq "sync: a snapshot younger than the interval (an on-demand run) counts as a run" "0" "$(scalls)"
sreset; : >"$SAH/sync-check.md"; touch -t 202001010000 "$SAH/sync-check.md"; srun; swait 1
assert_eq "sync: an old snapshot does not hold the check back" "1" "$(scalls)"
sreset; printf '%s\n' $((NOW + 864000)) >"$SAH/sync-check.stamp"; srun; swait 1
assert_eq "sync: a stamp from the future (clock set back) does not block it for good" "1" "$(scalls)"
sreset; printf 'junk\n' >"$SAH/sync-check.stamp"; srun; swait 1
assert_eq "sync: a junk stamp counts as never run" "1" "$(scalls)"

# the watcher does not wait for a slow check, and a failing one never fails the watcher
sreset; t0=$(date +%s)
rc=0; out=$(FAKE_MODE=slow srun 2>&1) || rc=$?
t1=$(date +%s)
assert_eq "sync: a 4 s check does not make the tick wait (under 3 s)" "yes" "$([ $((t1 - t0)) -lt 3 ] && echo yes || echo no)"
assert_eq "sync: the tick exits 0 and prints nothing" "0:" "$rc:$out"
swait 1
sreset; rc=0; FAKE_MODE=fail srun || rc=$?
assert_eq "sync: a failing check: the watcher still exits 0" "0" "$rc"
assert_eq "sync: ... and watch.log records the failure" "1" "$(wlog_has 'sync-check: exited with status 3')"
assert_contains "sync: ... with a timestamp and the watcher's name" "$(cat "$SAH/watch.log")" "kaching-watch: sync-check"
sreset; rc=0; SYNC_CHECK_CMD="$WORK/no-such-sync-check" srun || rc=$?
assert_eq "sync: a check that cannot start: the watcher exits 0" "0" "$rc"
assert_eq "sync: ... and watch.log says it" "1" "$(wlog_has 'cannot start')"
sreset; rc=0; FAKE_MODE=hang SYNC_CHECK_MAX_SECS=1 srun || rc=$?
assert_eq "sync: a hanging check: the watcher exits 0" "0" "$rc"
assert_eq "sync: ... it is stopped at the time ceiling and watch.log says so" "1" "$(wlog_has 'stopped after 1s')"
sleep 1
assert_eq "sync: ... and nothing of it is left running" "0" "$(pgrep -f "sleep 25.31" | wc -l | tr -d ' ')"
# the real check under the ceiling: a fetch that hangs inside it goes down with it (its own session included)
mkdir -p "$WORK/shim"
cat >"$WORK/shim/git" <<'EOF'
#!/bin/bash
for a in "$@"; do if [ "$a" = fetch ]; then sleep "${SHIM_SLEEP:-3}"; break; fi; done
exec /usr/bin/git "$@"
EOF
chmod +x "$WORK/shim/git"
sreset; HR=$(mk_repo hangrepo); printf '%s\n' "$HR" >"$SAH/repos"
KACHING_INCLUDE_SANDBOX=1 AGENT_REPOS_FILE="$SAH/repos" PATH="$WORK/shim:$PATH" SHIM_SLEEP=23 SYNC_CHECK_CMD="$BIN/sync-check.sh" SYNC_CHECK_MAX_SECS=2 srun
assert_eq "sync: the real check is stopped at the ceiling while it fetches" "1" "$(wlog_has 'stopped after 2s')"
sleep 2
assert_eq "sync: ... and the hung fetch is not left behind" "0" "$(pgrep -f 'sleep 23' | wc -l | tr -d ' ')"
# the rest of the tick is unaffected: a tick that launches the check still reads transcripts
sreset
T9="$WORK/t9.jsonl"; amsg k1 0 1000 0 33 >"$T9"
mkdir -p "$SAH/sessions/s9"; printf 'cwd=%s\nname=proj\nstate=idle\ntranscript=%s\nupdated=%s\n' "$P" "$T9" "$NOW" >"$SAH/sessions/s9/meta"
srun
assert_eq "sync: a tick that launches the check still counts tokens" "33" "$(awk '$1 == "s9" { print $2 }' "$SAH/tokens/$DAY")"
exit 0
