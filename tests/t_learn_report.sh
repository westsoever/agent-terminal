#!/usr/bin/env bash
# t_learn_report.sh - the learner's weekly report and blind-spot ledger (spec 5.4): sessions and prompts per
# folder, UTC to local hours and weekdays, stop retries / stalls / handoffs / denies per folder, notifications
# by reason, the per-task_type table once the fields exist, week on week only when both weeks have data, the
# blind-spot bar (3 checkpoints in 2 sessions), and the events of sdk-cli sessions left out. The .work input is
# made by learn-extract.sh over the fixture tree plus events written here. LEARN_NOW and TZ pin the clock.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
export TZ=UTC
LEARN_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-19 06:00:00" +%s)   # Monday of 2026-W43: the default is W42
export LEARN_NOW
FX="$KIT/tests/fixtures/learn"
X="$BIN/learn-extract.sh"
REP="$BIN/learn-report.sh"
ROOT="$AGENT_HOME/proposals"
WD="$ROOT/.work"
P="$CLAUDE_DIR/projects"
LOG="$AGENT_HOME/events.jsonl"
SHOP=/Users/fixture/code/shop; BLOG=/Users/fixture/code/blog; LEADS=/Users/fixture/work/leads
A1=a1000000-0000-4000-8000-00000000a001; A2=a2000000-0000-4000-8000-00000000a002
B1=b1000000-0000-4000-8000-00000000b001; E2=e2000000-0000-4000-8000-00000000e002   # E2: the sdk-cli session

assert_fails "no extractor output yet: refused" "$REP"

# the fixture tree (the learner's own e6 run moved to this sandbox's .work, as in t_learn_extract.sh)
mkdir -p "$P"; cp -R "$FX/claude/projects/." "$P/"
enc=$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g'); mkdir -p "$P/$enc"
sed "s#/Users/fixture/.agent/proposals/.work#$WD#g" "$P"/-Users-fixture--agent-proposals--work/*.jsonl >"$P/$enc/e6.jsonl"
rm -rf "$P/-Users-fixture--agent-proposals--work"

ev_at() { # ts sid cwd kind [data_json]: one line shaped like lib.sh ev
  local d=${5:-}; [ -n "$d" ] || d='{}'
  jq -nc --arg ts "$1" --arg sid "$2" --arg cwd "$3" --arg kind "$4" --argjson data "$d" \
    '{ts:$ts, sid:$sid, name:($cwd | split("/") | last), cwd:$cwd, kind:$kind, data:$data}' >>"$LOG"
}
notif() { ev_at "$1" "$2" "$SHOP" notify "$(jq -nc --arg k "$3" --arg o "$4" --arg r "$5" '{kind:$k,outcome:$o,reason:$r}')"; }
ckpt() { ev_at "$1" "$2" "$3" checkpoint "$(jq -nc --arg n "$4" --arg t "${5:-}" '{status:"",blocker:"none",next_action:"x",not_examined:$n} + (if $t == "" then {} else {task_type:$t} end)')"; }

# week 42 (2026-10-12 .. 18)
ev_at 2026-10-12T12:05:00Z $A1 $SHOP stop_blocked '{"retry":1,"reason":"checkpoint"}'
ev_at 2026-10-12T12:06:00Z $A1 $SHOP stop_blocked '{"retry":2,"reason":"checkpoint"}'
ev_at 2026-10-12T12:07:00Z $A1 $SHOP context '{"level":"handoff","pct":85}'
ev_at 2026-10-12T12:08:00Z $A1 $SHOP context '{"level":"watch","pct":65}'
ev_at 2026-10-12T13:05:00Z $A2 $BLOG stall '{"idle_mins":20}'
ev_at 2026-10-12T13:06:00Z $A2 $BLOG deny '{"rule":"x","tool":"Bash"}'
ev_at 2026-10-12T13:07:00Z $A2 $BLOG deny '{"rule":"x","tool":"Bash"}'
ev_at 2026-10-12T13:08:00Z $A2 $BLOG deny '{"rule":"x","tool":"Bash"}'
notif 2026-10-13T09:00:00Z $A1 input delivered ""
notif 2026-10-13T09:01:00Z $A1 handoff delivered ""
notif 2026-10-13T23:00:00Z $A1 waiting suppressed quiet-hours
notif 2026-10-13T23:01:00Z $A1 waiting suppressed quiet-hours
notif 2026-10-13T23:02:00Z $A1 idle suppressed quiet-hours
notif 2026-10-14T10:00:00Z $A1 "done" suppressed routed-to-inbox
for i in 1 2 3 4 5; do ev_at 2026-10-12T12:40:0${i}Z $E2 $LEADS stop_blocked '{"retry":1,"reason":"checkpoint"}'; done
ev_at 2026-10-25T10:00:00Z $A1 $SHOP deny '{"rule":"x","tool":"Bash"}'    # week 43: not in the W42 report
# blind spots: "the safari check in <path>" in a1 and a2 (events) and b1 (STATE.md) = 3 checkpoints, 3 sessions;
# the same item in a1's STATE.md is already a1's event and does not count again; the sdk-cli session does not
# count; "review of <commit>" is 3 checkpoints in 1 session; "the iOS build" is 2 checkpoints in 2 sessions
ckpt 2026-10-12T12:09:00Z $A1 $SHOP "the Safari check in /Users/fixture/code/shop/web; none; review of a0dd6fc4"
ckpt 2026-10-12T12:10:00Z $A1 $SHOP "review of 7656497"
ckpt 2026-10-12T12:11:00Z $A1 $SHOP "review of 1234abc (only diagnosed)"
ckpt 2026-10-13T13:09:00Z $A2 $BLOG "The Safari check in ~/code/blog/web, the iOS build"
ckpt 2026-10-12T12:40:09Z $E2 $LEADS "the safari check in /x"
mkstate() { # sid not_examined
  mkdir -p "$AGENT_HOME/sessions/$1"
  printf 'cwd=/Users/fixture\n' >"$AGENT_HOME/sessions/$1/meta"
  printf '# State\n\n<!-- ching:checkpoint -->\nresult: x\nnot_examined: %s\n<!-- /ching:checkpoint -->\n' "$2" >"$AGENT_HOME/sessions/$1/STATE.md"
}
mkstate $B1 "the safari check in /tmp/probe (not run); the iOS build"
mkstate $A1 "the Safari check in /somewhere/else"

"$X" || fail "the extractor ran" ""
out=$("$REP" 2>"$WORK/rep.err"); rc=$?
R="$ROOT/report-2026-W42.md"
assert_eq "report: exit 0" "0" "$rc"
assert_eq "report: quiet on stderr" "" "$(cat "$WORK/rep.err")"
assert_eq "report: says where it wrote" "report $(cd "$ROOT" && pwd -P)/report-2026-W42.md" "$out"
assert_file "report: default week is the last complete one (W42)" "$R"
assert_eq "report: mode 0600" "600" "$(stat -f %Lp "$R")"
rep=$(cat "$R")
assert_contains "header: week and dates" "$rep" "week: 2026-10-12 to 2026-10-18 (local time, UTC)"

# sessions and prompts per folder (from .work/prompts.jsonl: 17 prompts in 6 sessions)
assert_contains "folders: shop 3 sessions 9 prompts" "$rep" "| $SHOP | 3 | 9 |"
assert_contains "folders: blog 2 sessions 5 prompts" "$rep" "| $BLOG | 2 | 5 |"
assert_contains "folders: home 1 session 3 prompts" "$rep" "| /Users/fixture | 1 | 3 |"
assert_contains "folders: total" "$rep" "| **total** | 6 | 17 |"
hours() { printf '%s\n' "$1" | grep '^| prompts | ' | head -1; }
assert_eq "hours (UTC): 3 at 11, 9 at 12, 5 at 13" \
  "| prompts | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 3 | 9 | 5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |" "$(hours "$rep")"
assert_contains "weekdays: Mon 6, Tue 3, Wed 8" "$rep" "| prompts | 6 | 3 | 8 | 0 | 0 | 0 | 0 |"

# per-folder event counts; the sdk-cli session's 5 stop retries are not counted
assert_contains "events: shop 2 retries, 1 handoff (a watch level is not one)" "$rep" "| $SHOP | 2 | 0 | 1 | 0 |"
assert_contains "events: blog 1 stall, 3 denies" "$rep" "| $BLOG | 0 | 1 | 0 | 3 |"
assert_contains "events: total" "$rep" "| **total** | 2 | 1 | 1 | 3 |"
assert_not_contains "events: the sdk-cli session's folder is left out" "$rep" "$LEADS"
assert_contains "notifications: delivered" "$rep" "| delivered | - | 2 | handoff 1, input 1 |"
assert_contains "notifications: quiet hours by kind" "$rep" "| suppressed | quiet-hours | 3 | waiting 2, idle 1 |"
assert_contains "notifications: inbox" "$rep" "| suppressed | routed-to-inbox | 1 | done 1 |"
assert_contains "task types: none yet" "$rep" "No task_type yet"
assert_contains "week on week: hidden while W41 is empty" "$rep" "Not shown: 2026-W41 has no data."

# blind spots
assert_contains "ledger: 3 checkpoints in 3 sessions (STATE.md counted once per session)" "$rep" "| 3 | 3 | written blindspot-the-safari-check-in.md |"
assert_contains "ledger: 3 checkpoints in 1 session stays below the bar" "$rep" "| 3 | 1 | below the bar |"
assert_contains "ledger: 2 checkpoints in 2 sessions stays below the bar" "$rep" "| the iOS build | 2 | 2 | below the bar |"
assert_not_contains "ledger: none is not an item" "$rep" "| none |"
BS="$ROOT/blindspot-the-safari-check-in.md"
assert_file "ledger: blindspot proposal written" "$BS"
assert_eq "blindspot: header" "blindspot blindspot 3 templates/VERIFY.md" \
  "$(for k in kind component sessions target; do proposal_get "$BS" "$k"; done | tr '\n' ' ' | sed 's/ $//')"
assert_eq "blindspot: fingerprint of the normalised item" "$(proposal_fingerprint "the safari check in")" "$(proposal_get "$BS" fingerprint)"
assert_eq "blindspot: one evidence line per checkpoint" "3" "$(proposal_section "$BS" evidence | grep -c '^- ')"
assert_eq "blindspot: exactly one proposal" "1" "$(find "$ROOT" -maxdepth 1 -name 'blindspot-*.md' | grep -c .)"
assert_eq "learn_run: one report event" '{"component":"report","scanned":35,"candidates":3,"proposals":1,"outcome":"ok"}' \
  "$(jq -c 'select(.kind == "learn_run" and .data.component == "report") | .data' "$LOG")"

# a rerun refreshes, does not duplicate; the report is the same apart from the generated line
cp "$R" "$WORK/r1"
"$REP" >/dev/null
assert_contains "rerun: the proposal is refreshed" "$(cat "$R")" "| 3 | 3 | refreshed blindspot-the-safari-check-in.md |"
assert_eq "rerun: still one proposal" "1" "$(find "$ROOT" -maxdepth 1 -name 'blindspot-*.md' | grep -c .)"
assert_eq "rerun: learn_run counts no new proposal" "0" \
  "$(jq -r 'select(.kind == "learn_run" and .data.component == "report") | .data.proposals' "$LOG" | tail -1)"
assert_eq "rerun: deterministic apart from the status" "$(grep -v '^generated:' "$WORK/r1" | sed 's/ written blindspot/ refreshed blindspot/')" \
  "$(grep -v '^generated:' "$R")"
proposal_fingerprint "the safari check in" >"$ROOT/rejected.txt"; rm -f "$BS"
"$REP" >/dev/null
assert_contains "rejected: never proposed again" "$(cat "$R")" "| 3 | 3 | skipped rejected |"
assert_no_file "rejected: no file" "$BS"
rm -f "$ROOT/rejected.txt"

# local time: the same prompts in Tokyo (UTC+9)
TZ=Asia/Tokyo "$REP" >/dev/null
assert_eq "hours (Tokyo): 3 at 20, 9 at 21, 5 at 22" \
  "| prompts | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 3 | 9 | 5 | 0 |" "$(hours "$(cat "$R")")"
# a prompt at 23:30 UTC on Sunday is Monday 01:30 in Copenhagen (UTC+2 in October): the next week
printf '%s\n' '{"sid":"z1","ts":"2026-10-18T23:30:00.000Z","cwd":"/Users/fixture/late","text":"late","prev_assistant_tail":"","after_interrupt":false}' >>"$WD/prompts.jsonl"
TZ=Europe/Copenhagen "$REP" --week 2026-W43 >/dev/null
r43=$(cat "$ROOT/report-2026-W43.md")
assert_contains "UTC to local: Sunday 23:30 UTC is in the next local week" "$r43" "| /Users/fixture/late | 1 | 1 |"
assert_contains "UTC to local: at 01 local" "$r43" "| prompts | 0 | 1 | 0 |"
assert_contains "UTC to local: on a Monday" "$r43" "| prompts | 1 | 0 | 0 | 0 | 0 | 0 | 0 |"
TZ=UTC "$REP" --week 2026-W42 >/dev/null
assert_contains "UTC to local: in UTC it stays in W42" "$(cat "$R")" "| /Users/fixture/late | 1 | 1 |"

# week on week once the week before has data; per task type once checkpoints carry task_type
ev_at 2026-10-06T09:00:00Z $A1 $SHOP deny '{"rule":"x","tool":"Bash"}'
ckpt 2026-10-14T09:00:00Z $A1 $SHOP "nothing" bugfix
ev_at 2026-10-14T09:01:00Z $A1 $SHOP tests '{"outcome":"fail","secs":4}'
ev_at 2026-10-14T09:11:00Z $A1 $SHOP tests '{"outcome":"pass","secs":4}'
ckpt 2026-10-14T13:00:00Z $A2 $BLOG "nothing" docs
ev_at 2026-10-14T13:01:00Z $A2 $BLOG tests '{"outcome":"pass","secs":2}'
"$X"; "$REP" >/dev/null
rep=$(cat "$R")
assert_contains "week on week: shown when both weeks have data" "$rep" "| measure | 2026-W41 | 2026-W42 | change |"
assert_contains "week on week: denies 1 then 3" "$rep" "| denies | 1 | 3 | +2 |"
assert_contains "week on week: W41 has no prompts, so no change for sessions" "$rep" "| sessions | - | 7 | - |"
assert_contains "week on week: nor for prompts" "$rep" "| prompts | - | 18 | - |"
assert_not_contains "week on week: no change against a week without prompts" "$rep" "| +7 |"
# prompts in W40 and W41 but no events in W40: the W41 report shows no change for the event measures
printf '%s\n' '{"sid":"w41","ts":"2026-10-07T10:00:00.000Z","cwd":"/Users/fixture/code/shop","text":"x","prev_assistant_tail":"","after_interrupt":false}' \
  '{"sid":"w40","ts":"2026-09-30T10:00:00.000Z","cwd":"/Users/fixture/code/shop","text":"y","prev_assistant_tail":"","after_interrupt":false}' >>"$WD/prompts.jsonl"
"$REP" >/dev/null
assert_contains "week on week: W41 now has prompts, sessions 1 then 7" "$(cat "$R")" "| sessions | 1 | 7 | +6 |"
"$REP" --week 2026-W41 >/dev/null
r41=$(cat "$ROOT/report-2026-W41.md")
assert_contains "week on week: sessions 1 then 1" "$r41" "| sessions | 1 | 1 | 0 |"
assert_contains "week on week: W40 has no events, so no change for denies" "$r41" "| denies | - | 1 | - |"
assert_contains "week on week: nor for notifications" "$r41" "| notifications delivered | - | 0 | - |"
assert_not_contains "week on week: no +1 against a week without events" "$r41" "| +1 |"
assert_contains "task type: bugfix, a fail then green 10 minutes later" "$rep" "| bugfix | 1 | 2 | 2 | 1 | 0 | 10 |"
assert_contains "task type: docs, green first time" "$rep" "| docs | 1 | 0 | 1 | 0 | 1 | - |"

# feedback (spec 6.5): decisions per component from proposal events and archive/, and a component with only
# rejections for 4 weeks flagged. W42 is 10-12..18; its W-3 is W39 (09-21..27).
R42() { cat "$R"; }
assert_contains "feedback: none decided yet" "$(R42)" "No proposal decided yet"
mkdir -p "$ROOT/archive"
arch() { # file id component status [touch stamp]
  printf 'id: %s\nkind: %s\nstatus: %s\ncreated: 2026-09-01T00:00:00Z\ncomponent: %s\n\n## proposal\nx\n' "$2" "${2%%-*}" "$4" "$3" >"$ROOT/archive/$1"
  [ -z "${5:-}" ] || touch -t "$5" "$ROOT/archive/$1"
}
decision() { ev_at "$1" "" /Users/fixture proposal "$(jq -nc --arg i "$2" --arg a "$3" '{id:$i, action:$a}')"; }
arch rule-a.md rule-a corrections approved
arch rule-b.md rule-b corrections rejected
arch rule-c.md rule-c corrections snoozed:2026-11-01 202610141200   # no event: counted from archive/, on its mtime
arch skill-x.md skill-x skills rejected
arch skill-y.md skill-y skills rejected
arch skill-z.md skill-z skills rejected
arch blindspot-q.md blindspot-q blindspot rejected
decision 2026-10-13T10:00:00Z rule-a approved
decision 2026-10-07T10:00:00Z rule-b rejected
decision 2026-09-23T10:00:00Z skill-x rejected
decision 2026-10-01T10:00:00Z skill-y rejected
decision 2026-10-14T10:00:00Z skill-z rejected
decision 2026-10-15T10:00:00Z blindspot-q rejected
decision 2026-10-20T10:00:00Z skill-w approved   # W43: after the week, not counted (no archive file: kind skill -> skills)
"$X"; "$REP" >/dev/null
fb=$(sed -n '/^## Feedback on proposals/,/^## Blind spots/p' "$R")
assert_contains "feedback: header row" "$fb" "| component | approved | rejected | snoozed | approved in all | rejected in all | snoozed in all |"
assert_contains "feedback: corrections (archive-only snooze counted)" "$fb" "| corrections | 1 | 0 | 1 | 1 | 1 | 1 |"
assert_contains "feedback: skills (the W43 approval is after the week)" "$fb" "| skills | 0 | 1 | 0 | 0 | 3 | 0 |"
assert_contains "feedback: blindspot" "$fb" "| blindspot | 0 | 1 | 0 | 0 | 1 | 0 |"
assert_contains "feedback: skills only rejected since W39: flagged" "$fb" "skills: only rejections since 2026-09-23"
assert_contains "feedback: the flag says how to turn it off" "$fb" "LEARN_DISABLE=skills"
assert_not_contains "feedback: blindspot only rejected for one week: not flagged" "$fb" "blindspot: only rejections"
assert_not_contains "feedback: corrections had an approval: not flagged" "$fb" "corrections: only rejections"
"$REP" --week 2026-W43 >/dev/null
fb43=$(sed -n '/^## Feedback on proposals/,/^## Blind spots/p' "$ROOT/report-2026-W43.md")
assert_contains "feedback: W43 counts the approval" "$fb43" "| skills | 1 | 0 | 0 | 1 | 3 | 0 |"
assert_not_contains "feedback: an approval ends the streak" "$fb43" "skills: only rejections"
# blindspot rejections since W39: the flag names the report step, which writes blindspot proposals
arch blindspot-p.md blindspot-p blindspot rejected
decision 2026-09-22T10:00:00Z blindspot-p rejected
"$X"; "$REP" >/dev/null
assert_contains "feedback: blindspot flagged with the report step's name" "$(R42)" "LEARN_DISABLE=report"

# usage
assert_eq "bad --week: exit 64" "64" "$("$REP" --week 2026-42 >/dev/null 2>&1; echo $?)"
assert_eq "impossible --week: exit 64" "64" "$("$REP" --week 2026-W60 >/dev/null 2>&1; echo $?)"
assert_eq "unknown argument: exit 64" "64" "$("$REP" --bogus >/dev/null 2>&1; echo $?)"
"$REP" --week 2026-W39 >/dev/null
r39=$(cat "$ROOT/report-2026-W39.md")
assert_contains "an empty week: says so" "$r39" "No counted prompts this week."
assert_eq "an empty week: learn_run nothing-new" "nothing-new" \
  "$(jq -r 'select(.kind == "learn_run" and .data.component == "report") | .data.outcome' "$LOG" | tail -1)"
out=$(bash -c 'set -euo pipefail; "$1" --week 2026-W42' _ "$REP" 2>&1); rc=$?
assert_eq "strict caller: exit 0" "0" "$rc"
exit 0
