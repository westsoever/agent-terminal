#!/usr/bin/env bash
# metrics.sh: the pilot-metrics report (PLAN section 7) read from events.jsonl. Fixtures are synthetic event
# logs in the shape lib.sh ev writes; the real log is never read. TZ and METRICS_NOW pin the clock.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
unset CHING_INCLUDE_SANDBOX                    # the session running the tests must not switch the exclusion off
export TZ=UTC
NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-16 12:00:00" +%s)   # 2026-10-16 12:00 UTC (TZ=UTC above)
export METRICS_NOW=$NOW
M="$BIN/metrics.sh"
W=/work/alpha; V=/work/beta; H=/Users/test     # real (non-sandbox) working folders

LOG="$AGENT_HOME/events.jsonl"
ev_at() { # ts sid cwd kind [data_json]: append one line shaped like lib.sh ev (to $LOG)
  local d=${5:-}; [ -n "$d" ] || d='{}'
  jq -nc --arg ts "$1" --arg sid "$2" --arg cwd "$3" --arg kind "$4" --argjson data "$d" \
    '{ts:$ts, sid:$sid, name:($cwd | split("/") | last), cwd:$cwd, kind:$kind, data:$data}' >>"$LOG"
}
notif() { # ts sid kind outcome reason
  ev_at "$1" "$2" "$W" notify "$(jq -nc --arg k "$3" --arg o "$4" --arg r "$5" '{kind:$k,outcome:$o,reason:$r}')"
}
rel() { # ts sha outcome [detail]   (hooks log release events with no session id)
  ev_at "$1" "" "$H/proj" release "$(jq -nc --arg s "$2" --arg o "$3" --arg d "${4:-}" 'if $d == "" then {sha:$s,outcome:$o} else {sha:$s,outcome:$o,detail:$d} end')"
}
SHA_A=$(printf 'a%.0s' $(seq 1 40)); SHA_B=$(printf 'b%.0s' $(seq 1 40))

# tcell ROW COLUMN: one cell of the main table in $OUT (row label in column 1, column by its header name)
tcell() {
  printf '%s\n' "$OUT" | awk -v r="$1" -v c="$2" '
    $1 == "day" { col = 0; for (i = 1; i <= NF; i++) if ($i == c) col = i; next }
    $1 == r && col { print $col; exit }'
}

# ---------- fixture A: two busy days (14, 15), today (16, TZ=UTC) and one old day (08) ----------
# day 14: s1 asks twice and finishes once; s2 stalls and crosses 80% context; s3 gets two delivered
# notices (one a handoff nudge); s1 logs 8 suppressed notices (3 quiet, 1 budget, 2 cooldown, 1 no-clock,
# 1 unknown reason) and 2 inbox routings; a machine-wide tokens event and a session-less deny are not sessions;
# three failed release gates (review missing, review rejected with 2 unresolved blocking findings, evidence)
D14=2026-10-14T
ev_at ${D14}08:00:00Z s1 $W session_start '{"source":"startup"}'
ev_at ${D14}08:01:00Z s1 $W prompt
ev_at ${D14}08:10:00Z s1 $W stop_ok '{"outcome":"input"}'
ev_at ${D14}08:20:00Z s1 $W stop_ok '{"outcome":"input"}'
ev_at ${D14}08:30:00Z s1 $W stop_ok '{"outcome":"done"}'
ev_at ${D14}09:00:00Z s2 $V prompt
ev_at ${D14}09:30:00Z s2 $V stall '{"idle_mins":20}'
ev_at ${D14}09:31:00Z s2 $V context '{"level":"handoff","pct":85}'
ev_at ${D14}09:32:00Z s2 $V context '{"level":"watch","pct":65}'
ev_at ${D14}09:33:00Z s2 $V context '{"level":"healthy","pct":40}'
notif ${D14}10:00:00Z s3 input delivered ""
notif ${D14}10:01:00Z s3 handoff delivered ""
notif ${D14}11:00:00Z s1 done suppressed routed-to-inbox
notif ${D14}11:01:00Z s1 done suppressed routed-to-inbox
notif ${D14}11:02:00Z s1 waiting suppressed quiet-hours
notif ${D14}11:03:00Z s1 waiting suppressed quiet-hours
notif ${D14}11:04:00Z s1 handoff suppressed quiet-hours
notif ${D14}11:05:00Z s1 stall suppressed daily-budget
notif ${D14}11:06:00Z s1 waiting suppressed cooldown
notif ${D14}11:07:00Z s1 handoff suppressed handoff-cooldown
notif ${D14}11:08:00Z s1 stall suppressed no-clock
notif ${D14}11:09:00Z s1 stall suppressed mystery
ev_at ${D14}12:00:00Z machine /Users/test tokens '{"day_total":900,"budget":1000,"crossed":80}'
ev_at ${D14}12:01:00Z "" $W deny '{"rule":"force push","tool":"Bash"}'
rel ${D14}13:00:00Z "$SHA_A" gate-fail "no review file at .agent/review/$SHA_A.md. Dispatch a fresh read-only reviewer subagent."
rel ${D14}13:10:00Z "$SHA_A" gate-fail "$(printf 'review file .agent/review/%s.md rejected:\n  - 2 blocking finding(s) without a resolved: line' "$SHA_A")"
rel ${D14}13:20:00Z "$SHA_A" gate-fail "no evidence file at .agent/verify/$SHA_A.md (see templates/VERIFY.md)"
# day 15: s1 asks once; s4 gets two delivered notices (a stall and an idle) and stalls twice; 2 budget
# suppressions and 1 inbox routing; two more 80% crossings; release B fails on tests, then passes, then deploys
D15=2026-10-15T
ev_at ${D15}08:00:00Z s1 $W prompt
ev_at ${D15}08:10:00Z s1 $W stop_ok '{"outcome":"input"}'
notif ${D15}09:00:00Z s4 stall delivered ""
notif ${D15}09:01:00Z s4 idle delivered ""
notif ${D15}10:00:00Z s4 stall suppressed daily-budget
notif ${D15}10:01:00Z s4 stall suppressed daily-budget
notif ${D15}10:02:00Z s4 done suppressed routed-to-inbox
ev_at ${D15}11:00:00Z s4 $V stall '{"idle_mins":25}'
ev_at ${D15}11:30:00Z s4 $V stall '{"idle_mins":40}'
ev_at ${D15}12:00:00Z s4 $V context '{"level":"handoff","pct":90}'
ev_at ${D15}12:10:00Z s4 $V context '{"level":"handoff","pct":93}'
rel ${D15}13:00:00Z "$SHA_B" gate-fail "test_command failed (exit 1): bun test"
rel ${D15}13:30:00Z "$SHA_B" gate-pass-confirm
rel ${D15}14:00:00Z "$SHA_B" deploy-SUCCESS
# today (16) and an old day (08)
ev_at 2026-10-16T09:00:00Z s5 $W prompt
ev_at 2026-10-16T09:10:00Z s5 $W stop_ok '{"outcome":"input"}'
ev_at 2026-10-08T09:10:00Z s6 $W stop_ok '{"outcome":"input"}'

OUT=$("$M" 2>&1); rc=$?
assert_eq "default run exits 0" "0" "$rc"
assert_contains "header names the days as local time" "$OUT" "days are local time"
assert_contains "header says which clock (TZ label)" "$OUT" "(UTC)"
assert_contains "header names the window" "$OUT" "2026-10-10"
for c in sess asked deliv inbox supp budg quiet cool noclk other stall ctx80 nudge gpass gfail rvmis rvbad blkd; do
  case "$(printf '%s\n' "$OUT" | grep '^day ')" in *" $c"*) pass "table has the $c column" ;; *) fail "table has the $c column" "$OUT" ;; esac
done
assert_eq "day 14 rows exist, old day 08 is outside the default 7 days" "2026-10-14 2026-10-15 2026-10-16 TOTAL" \
  "$(printf '%s\n' "$OUT" | awk '$1 ~ /^2026-10-[0-9][0-9]$/ || $1 == "TOTAL" { printf "%s%s", sep, $1; sep = " " }')"

# day 14, metric by metric
assert_eq "14 sessions seen (machine/tokens and session-less events are not sessions)" "3" "$(tcell 2026-10-14 sess)"
assert_eq "14 asked = stop_ok outcome input" "2" "$(tcell 2026-10-14 asked)"
assert_eq "14 delivered" "2" "$(tcell 2026-10-14 deliv)"
assert_eq "14 inbox" "2" "$(tcell 2026-10-14 inbox)"
assert_eq "14 suppressed (without inbox)" "8" "$(tcell 2026-10-14 supp)"
assert_eq "14 suppressed by budget" "1" "$(tcell 2026-10-14 budg)"
assert_eq "14 suppressed by quiet hours" "3" "$(tcell 2026-10-14 quiet)"
assert_eq "14 suppressed by cooldown (incl. handoff-cooldown)" "2" "$(tcell 2026-10-14 cool)"
assert_eq "14 suppressed with no clock" "1" "$(tcell 2026-10-14 noclk)"
assert_eq "14 suppressed for an unknown reason" "1" "$(tcell 2026-10-14 other)"
assert_eq "14 stalls" "1" "$(tcell 2026-10-14 stall)"
assert_eq "14 context handoff-level events" "1" "$(tcell 2026-10-14 ctx80)"
assert_eq "14 handoff nudges delivered" "1" "$(tcell 2026-10-14 nudge)"
assert_eq "14 gate passes" "0" "$(tcell 2026-10-14 gpass)"
assert_eq "14 gate fails" "3" "$(tcell 2026-10-14 gfail)"
assert_eq "14 review missing" "1" "$(tcell 2026-10-14 rvmis)"
assert_eq "14 review rejected" "1" "$(tcell 2026-10-14 rvbad)"
assert_eq "14 unresolved blocking findings named in failed gates" "2" "$(tcell 2026-10-14 blkd)"
# day 15
assert_eq "15 sessions" "2" "$(tcell 2026-10-15 sess)"
assert_eq "15 asked" "1" "$(tcell 2026-10-15 asked)"
assert_eq "15 delivered" "2" "$(tcell 2026-10-15 deliv)"
assert_eq "15 inbox" "1" "$(tcell 2026-10-15 inbox)"
assert_eq "15 suppressed" "2" "$(tcell 2026-10-15 supp)"
assert_eq "15 budget" "2" "$(tcell 2026-10-15 budg)"
assert_eq "15 stalls" "2" "$(tcell 2026-10-15 stall)"
assert_eq "15 ctx80" "2" "$(tcell 2026-10-15 ctx80)"
assert_eq "15 nudge (a delivered stall is not a handoff nudge)" "0" "$(tcell 2026-10-15 nudge)"
assert_eq "15 gate pass" "1" "$(tcell 2026-10-15 gpass)"
assert_eq "15 gate fail (tests)" "1" "$(tcell 2026-10-15 gfail)"
assert_eq "15 no review problem on a test failure" "0" "$(tcell 2026-10-15 rvmis)"
assert_eq "15 blocking" "0" "$(tcell 2026-10-15 blkd)"
# today
assert_eq "16 asked" "1" "$(tcell 2026-10-16 asked)"
assert_eq "16 sessions" "1" "$(tcell 2026-10-16 sess)"
# TOTAL
assert_eq "TOTAL asked" "4" "$(tcell TOTAL asked)"
assert_eq "TOTAL sessions: s1..s5, s1 counted once" "5" "$(tcell TOTAL sess)"
assert_eq "TOTAL delivered" "4" "$(tcell TOTAL deliv)"
assert_eq "TOTAL inbox" "3" "$(tcell TOTAL inbox)"
assert_eq "TOTAL suppressed" "10" "$(tcell TOTAL supp)"
assert_eq "TOTAL budget" "3" "$(tcell TOTAL budg)"
assert_eq "TOTAL stalls" "3" "$(tcell TOTAL stall)"
assert_eq "TOTAL ctx80" "3" "$(tcell TOTAL ctx80)"
assert_eq "TOTAL nudge" "1" "$(tcell TOTAL nudge)"
assert_eq "TOTAL gate passes" "1" "$(tcell TOTAL gpass)"
assert_eq "TOTAL gate fails" "4" "$(tcell TOTAL gfail)"
assert_eq "TOTAL blocking" "2" "$(tcell TOTAL blkd)"
# per release: A never passed, B failed once then passed and deployed
rrow() { printf '%s\n' "$OUT" | awk -v s="$1" '$1 == s { print; exit }' | tr -s ' '; }
assert_contains "releases: sha A listed (7 chars) with its first day" "$(rrow aaaaaaa)" "2026-10-14"
assert_contains "releases: A failed three gates" "$(rrow aaaaaaa)" " 0 3 1 1 2"
assert_contains "releases: B passed once, failed once" "$(rrow bbbbbbb)" " 1 1 0 0 0"
assert_contains "releases: B deployed" "$(rrow bbbbbbb)" "deploy-SUCCESS"
# footer: what is exact and what is a proxy, said plainly
assert_contains "footer: asked is a proxy" "$(printf '%s\n' "$OUT" | grep '^  asked')" "proxy"
assert_contains "footer: asked says how the question is detected" "$OUT" 'ends in "?"'
assert_contains "footer: stall reality cannot be told" "$(printf '%s\n' "$OUT" | grep '^  stall')" "cannot be told from the log"
assert_contains "footer: /handoff runs are not logged" "$(printf '%s\n' "$OUT" | grep '^  nudge')" "not logged"
assert_contains "footer: blocking count of a passed review is not logged" "$(printf '%s\n' "$OUT" | grep '^  blkd')" "not logged"
assert_contains "footer: sessions seen line" "$OUT" "sessions seen: 5 distinct"
assert_contains "footer: nothing excluded in this log" "$OUT" "excluded: 0 events"
assert_contains "footer: nothing malformed in this log" "$OUT" "skipped: 0 malformed lines"

# ---------- window: --days, --day ----------
OUT=$("$M" --days 2 2>&1)
assert_eq "--days 2: yesterday-and-today only" "2026-10-15 2026-10-16 TOTAL" \
  "$(printf '%s\n' "$OUT" | awk '$1 ~ /^2026-10-[0-9][0-9]$/ || $1 == "TOTAL" { printf "%s%s", sep, $1; sep = " " }')"
assert_eq "--days 2: TOTAL asked" "2" "$(tcell TOTAL asked)"
assert_eq "--days 2: TOTAL sessions" "3" "$(tcell TOTAL sess)"
OUT=$("$M" --days 1 2>&1)
assert_eq "--days 1: today only" "1" "$(tcell TOTAL asked)"
OUT=$("$M" --days 9 2>&1)
assert_eq "--days 9 reaches the old day" "5" "$(tcell TOTAL asked)"
assert_contains "--days 9: the old day has a row" "$OUT" "2026-10-08"
OUT=$("$M" --day 2026-10-14 2>&1); rc=$?
assert_eq "--day: exit 0" "0" "$rc"
assert_eq "--day: that day's asked" "2" "$(tcell 2026-10-14 asked)"
assert_eq "--day: that one day is the only day row" "1" "$(printf '%s\n' "$OUT" | awk '$1 ~ /^2026-10-[0-9][0-9]$/ { n++ } END { print n + 0 }')"
assert_eq "--day: TOTAL equals the day" "2" "$(tcell TOTAL asked)"
OUT=$("$M" --day 2026-10-12 2>&1); rc=$?
assert_eq "--day with no events: exit 0" "0" "$rc"
assert_contains "--day with no events says so" "$OUT" "no events"
OUT=$("$M" --days 0 2>&1); rc=$?; assert_eq "--days 0 is a usage error (64)" "64" "$rc"
OUT=$("$M" --days x 2>&1); rc=$?; assert_eq "--days x is a usage error (64)" "64" "$rc"
OUT=$("$M" --days 2>&1); rc=$?; assert_eq "--days without a value is a usage error (64)" "64" "$rc"
OUT=$("$M" --day 2026-02-30 2>&1); rc=$?; assert_eq "--day with an impossible date is a usage error (64)" "64" "$rc"
OUT=$("$M" --day yesterday 2>&1); rc=$?; assert_eq "--day with a word is a usage error (64)" "64" "$rc"
OUT=$("$M" --days 3 --day 2026-10-14 2>&1); rc=$?; assert_eq "--days with --day is a usage error (64)" "64" "$rc"
OUT=$("$M" --bogus 2>&1); rc=$?; assert_eq "unknown argument is a usage error (64)" "64" "$rc"
OUT=$("$M" --help 2>&1); rc=$?
assert_eq "--help exits 0" "0" "$rc"
assert_contains "--help shows the usage" "$OUT" "[--days N]"

# ---------- --json carries the same numbers ----------
JSON=$("$M" --json 2>&1); rc=$?
assert_eq "--json exits 0" "0" "$rc"
assert_ok "--json is one valid JSON document" jq -e . <<<"$JSON"
OUT=$("$M" 2>&1)
jcheck() { # row-label json-selector label...
  local row=$1 sel=$2 col key v t
  for pair in sess:sessions asked:asked deliv:delivered inbox:inbox supp:suppressed budg:budget quiet:quiet cool:cooldown \
              noclk:no_clock other:other stall:stalls ctx80:ctx80 nudge:handoff_nudges gpass:gate_pass gfail:gate_fail \
              rvmis:review_missing rvbad:review_rejected blkd:blocking_unresolved; do
    col=${pair%%:*}; key=${pair#*:}
    v=$(printf '%s' "$JSON" | jq -r "$sel | .$key")
    t=$(tcell "$row" "$col")
    if [ "$v" = "$t" ] && [ -n "$t" ]; then pass "json = table: $row $col"; else fail "json = table: $row $col" "  table: $t json: $v"; fi
  done
}
jcheck 2026-10-14 '.days[] | select(.day == "2026-10-14")'
jcheck 2026-10-15 '.days[] | select(.day == "2026-10-15")'
jcheck TOTAL '.total'
assert_eq "json: day list" "2026-10-14 2026-10-15 2026-10-16" "$(printf '%s' "$JSON" | jq -r '[.days[].day] | join(" ")')"
assert_eq "json: window" "2026-10-10 2026-10-16" "$(printf '%s' "$JSON" | jq -r '[.window.from, .window.to] | join(" ")')"
assert_eq "json: releases" "aaaaaaa bbbbbbb" "$(printf '%s' "$JSON" | jq -r '[.releases[].sha] | join(" ")')"
assert_eq "json: release A blocking" "2" "$(printf '%s' "$JSON" | jq -r '.releases[] | select(.sha == "aaaaaaa") | .blocking_unresolved')"
assert_eq "json: release B deploy" "deploy-SUCCESS" "$(printf '%s' "$JSON" | jq -r '.releases[] | select(.sha == "bbbbbbb") | .deploy')"
assert_eq "json: excluded and malformed counts" "0 0 0" "$(printf '%s' "$JSON" | jq -r '[.excluded_sandbox_events, .malformed_lines, .undated_events] | map(tostring) | join(" ")')"
assert_eq "json: day basis" "local" "$(printf '%s' "$JSON" | jq -r '.day_basis')"
assert_eq "json --days 1 is the same window as the table" "1" "$("$M" --json --days 1 | jq -r '.total.asked')"

# ---------- missing, empty and damaged logs ----------
EMPTY="$WORK/ah-empty"; mkdir -p "$EMPTY"
OUT=$(AGENT_HOME="$EMPTY" "$M" 2>&1); rc=$?
assert_eq "missing log: exit 0" "0" "$rc"
assert_contains "missing log: says no events" "$OUT" "no events"
JSON=$(AGENT_HOME="$EMPTY" "$M" --json 2>&1); rc=$?
assert_eq "missing log --json: exit 0" "0" "$rc"
assert_eq "missing log --json: valid JSON, no days" "0" "$(printf '%s' "$JSON" | jq -r '.days | length')"
assert_eq "missing log --json: the total is zeros, not null" "0" "$(printf '%s' "$JSON" | jq -r '.total.asked')"
assert_eq "missing log: nothing but the one line" "1" "$(AGENT_HOME="$EMPTY" "$M" | wc -l | tr -d ' ')"
: >"$EMPTY/events.jsonl"
OUT=$(AGENT_HOME="$EMPTY" "$M" 2>&1); rc=$?
assert_eq "empty log: exit 0" "0" "$rc"
assert_contains "empty log: says no events" "$OUT" "no events"
printf '\n\n' >"$EMPTY/events.jsonl"
OUT=$(AGENT_HOME="$EMPTY" "$M" 2>&1); rc=$?
assert_contains "blank-lines-only log: says no events" "$OUT" "no events"
printf 'garbage\n{"half":\n' >"$EMPTY/events.jsonl"
OUT=$(AGENT_HOME="$EMPTY" "$M" 2>&1); rc=$?
assert_eq "all-garbage log: exit 0" "0" "$rc"
assert_contains "all-garbage log: says no events" "$OUT" "no events"
assert_contains "all-garbage log: still counts what it skipped" "$OUT" "skipped: 2 malformed lines"

BAD="$WORK/ah-bad"; mkdir -p "$BAD"
{
  echo '{"ts":"2026-10-14T10:00:00Z","sid":"m1","name":"x","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}'
  echo 'this is not json'
  echo '{"ts":"2026-10-14T10:00:01Z","sid":"m1","cwd":"/work/alpha","kind":"stop_ok"'
  echo '123'
  echo '[1,2]'
  echo 'null'
  echo '"just a string"'
  echo ''
  echo '{"sid":"m2","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}'
  echo '{"ts":"2026-10-14T10:00:02Z","sid":"m1","cwd":"/work/alpha","kind":"stop_ok"}'
  echo '{"ts":"2026-10-14T10:00:03Z","sid":"m1","cwd":"/work/alpha","kind":"notify","data":"oops"}'
  echo '{"ts":"2026-10-14T10:00:04Z","kind":"prompt"}'
  echo '{"ts":"garbage","sid":"m1","cwd":"/work/alpha","kind":"prompt"}'
  echo '{"ts":"2026-10-14T10:00:05Z","sid":7,"cwd":null,"data":null}'
  echo '{"ts":"2026-10-14T10:00:06Z","sid":"m1","cwd":"/work/alpha","kind":"notify","data":{"kind":5,"outcome":["x"],"reason":{}}}'
  echo '{"ts":"2026-10-14T10:00:07Z","sid":"m1","cwd":"/work/alpha","kind":"release","data":{"outcome":"gate-fail","detail":["not a string"]}}'
  echo '{"ts":"2026-10-14T10:00:08Z","sid":"m1","cwd":"/work/alpha","kind":"release","data":{"outcome":"gate-fail","detail":"review file x rejected: 99999999999999999999999 blocking finding(s) without a resolved: line"}}'
} >"$BAD/events.jsonl"
OUT=$(AGENT_HOME="$BAD" "$M" --days 7 2>&1); rc=$?
assert_eq "damaged log: exit 0, no crash" "0" "$rc"
assert_contains "damaged log: 6 malformed lines counted (blank line is not one)" "$OUT" "skipped: 6 malformed lines"
assert_contains "damaged log: 2 events without a usable timestamp" "$OUT" "2 events without a usable timestamp"
assert_eq "damaged log: the one valid question is counted" "1" "$(tcell 2026-10-14 asked)"
assert_eq "damaged log: sessions are m1 and 7 (a number sid counts, no sid does not)" "2" "$(tcell 2026-10-14 sess)"
assert_eq "damaged log: a notify event it cannot read lands in other" "2" "$(tcell 2026-10-14 other)"
assert_eq "damaged log: a non-string detail is a failed gate and nothing more" "2" "$(tcell 2026-10-14 gfail)"
assert_eq "damaged log: an absurd blocking count in a detail is ignored" "0" "$(tcell 2026-10-14 blkd)"
assert_eq "damaged log: the rejected-review text still counts as rejected" "1" "$(tcell 2026-10-14 rvbad)"
JSON=$(AGENT_HOME="$BAD" "$M" --days 7 --json 2>&1)
assert_eq "damaged log --json: counts" "6 2" "$(printf '%s' "$JSON" | jq -r '[.malformed_lines, .undated_events] | map(tostring) | join(" ")')"

# ---------- sandbox exclusion ----------
SB="$WORK/ah-sandbox"; mkdir -p "$SB"
{
  i=0
  for cwd in /work/alpha /work/alpha /work/beta; do
    i=$((i + 1))
    printf '{"ts":"2026-10-14T10:00:00Z","sid":"real-%s","name":"n","cwd":"%s","kind":"stop_ok","data":{"outcome":"input"}}\n' "$i" "$cwd"
  done
  for cwd in /tmp/x /private/tmp/y /var/folders/zz/T/z /Users/q/task7-repo /Users/q/task7-repo/sub; do
    i=$((i + 1))
    printf '{"ts":"2026-10-14T10:00:00Z","sid":"sbx-%s","name":"n","cwd":"%s","kind":"stop_ok","data":{"outcome":"input"}}\n' "$i" "$cwd"
  done
} >"$SB/events.jsonl"
OUT=$(AGENT_HOME="$SB" "$M" 2>&1)
assert_eq "sandbox: excluded by default (3 real questions)" "3" "$(tcell TOTAL asked)"
assert_eq "sandbox: sandbox sessions are not counted as sessions" "3" "$(tcell TOTAL sess)"
assert_contains "sandbox: the footer says how many events were excluded" "$OUT" "excluded: 5 events"
assert_contains "sandbox: the footer says how to include them" "$OUT" "--all"
OUT=$(AGENT_HOME="$SB" "$M" --all 2>&1)
assert_eq "sandbox: --all includes them" "8" "$(tcell TOTAL asked)"
assert_contains "sandbox: --all shows nothing excluded" "$OUT" "excluded: 0 events"
OUT=$(AGENT_HOME="$SB" CHING_INCLUDE_SANDBOX=1 "$M" 2>&1)
assert_eq "sandbox: CHING_INCLUDE_SANDBOX=1 includes them" "8" "$(tcell TOTAL asked)"
JSON=$(AGENT_HOME="$SB" "$M" --json)
assert_eq "sandbox: --json excluded count" "5" "$(printf '%s' "$JSON" | jq -r '.excluded_sandbox_events')"
assert_eq "sandbox: --json total asked" "3" "$(printf '%s' "$JSON" | jq -r '.total.asked')"
# a log that is only sandbox events: nothing to show, but the exclusion is still reported
SB2="$WORK/ah-sandbox-only"; mkdir -p "$SB2"
printf '{"ts":"2026-10-14T10:00:00Z","sid":"s","name":"n","cwd":"/tmp/x","kind":"stop_ok","data":{"outcome":"input"}}\n' >"$SB2/events.jsonl"
OUT=$(AGENT_HOME="$SB2" "$M" 2>&1); rc=$?
assert_eq "sandbox-only log: exit 0" "0" "$rc"
assert_contains "sandbox-only log: no events" "$OUT" "no events"
assert_contains "sandbox-only log: the exclusion is visible" "$OUT" "excluded: 1 events"
# the same fixtures under the real /tmp cwd shape the tests themselves use
OUT=$(AGENT_HOME="$SB2" CHING_INCLUDE_SANDBOX=1 "$M" 2>&1)
assert_eq "sandbox-only log with CHING_INCLUDE_SANDBOX=1 shows it" "1" "$(tcell TOTAL asked)"
# lib.sh keeps the one definition of what a sandbox is
assert_eq "metrics.sh does not define its own is_sandbox_path" "0" "$(grep -c '^is_sandbox_path()' "$M")"
assert_contains "metrics.sh sources lib.sh" "$(cat "$M")" 'lib.sh'

# a cwd with a quote, a tab and a newline (lib.sh ev keeps it as one valid line): counted under its own name,
# and a sandbox one with the same shape is still excluded
ODD="$WORK/ah odd"; mkdir -p "$ODD"
printf '%s\n' '{"ts":"2026-10-14T10:00:00Z","sid":"o1","cwd":"/work/we\"ird\tfolder\nx","kind":"stop_ok","data":{"outcome":"input"}}' \
  '{"ts":"2026-10-14T10:00:00Z","sid":"o2","cwd":"/tmp/we\"ird\nfolder","kind":"stop_ok","data":{"outcome":"input"}}' >"$ODD/events.jsonl"
OUT=$(AGENT_HOME="$ODD" "$M" 2>&1); rc=$?
assert_eq "odd cwd and a space in AGENT_HOME: exit 0" "0" "$rc"
assert_eq "odd cwd: the real one is counted, the sandbox one is not" "1" "$(tcell TOTAL asked)"
assert_contains "odd cwd: the sandbox one is reported as excluded" "$OUT" "excluded: 1 events"
# an unreadable log is an error, not "no events"
if [ "$(id -u)" != 0 ]; then
  UR="$WORK/ah-unreadable"; mkdir -p "$UR"; : >"$UR/events.jsonl"; chmod 000 "$UR/events.jsonl"
  OUT=$(AGENT_HOME="$UR" "$M" 2>&1); rc=$?
  assert_eq "unreadable log: exit 1" "1" "$rc"
  assert_contains "unreadable log: says so" "$OUT" "cannot read"
  chmod 600 "$UR/events.jsonl"
fi

# ---------- local time vs UTC around midnight and across the DST change ----------
TZD="$WORK/ah-tz"; mkdir -p "$TZD"
{
  # 21:59:59Z is 23:59:59 in Copenhagen (CEST, +2); 22:00:00Z is already the next local day
  printf '{"ts":"2026-10-14T21:59:59Z","sid":"t1","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n'
  printf '{"ts":"2026-10-14T22:00:00Z","sid":"t2","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n'
  # 22:00Z on the 24th is 00:00 local on the 25th (CEST); 22:30Z on the 25th is 23:30 local (CET, +1: the
  # clocks went back that night), so it still belongs to the 25th and not to the 26th
  printf '{"ts":"2026-10-24T22:00:00Z","sid":"t3","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n'
  printf '{"ts":"2026-10-25T22:30:00Z","sid":"t4","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n'
} >"$TZD/events.jsonl"
export METRICS_NOW=$(date -u -j -f '%Y-%m-%d %H:%M:%S' "2026-10-26 12:00:00" +%s)
rows() { printf '%s\n' "$OUT" | awk '$1 ~ /^2026-10-[0-9][0-9]$/ { printf "%s%s=%s", sep, $1, $3; sep = " " }'; }
OUT=$(AGENT_HOME="$TZD" TZ=UTC "$M" --days 30 2>&1)
assert_eq "UTC days: the two on the 14th together" "2026-10-14=2 2026-10-24=1 2026-10-25=1" "$(rows)"
assert_contains "UTC header says UTC" "$OUT" "(UTC)"
OUT=$(AGENT_HOME="$TZD" TZ=Europe/Copenhagen "$M" --days 30 2>&1)
assert_eq "Copenhagen days: midnight splits the 14th, DST day holds both" "2026-10-14=1 2026-10-15=1 2026-10-25=2" "$(rows)"
assert_contains "Copenhagen header says local time and the zone" "$OUT" "(CET)"
JSON=$(AGENT_HOME="$TZD" TZ=Europe/Copenhagen "$M" --days 30 --json)
assert_eq "Copenhagen --json: same days" "2026-10-14 2026-10-15 2026-10-25" "$(printf '%s' "$JSON" | jq -r '[.days[].day] | join(" ")')"
OUT=$(AGENT_HOME="$TZD" TZ=Europe/Copenhagen "$M" --day 2026-10-15 2>&1)
assert_eq "Copenhagen --day 15th picks the event that is 22:00Z on the 14th" "1" "$(tcell TOTAL asked)"
OUT=$(AGENT_HOME="$TZD" TZ=UTC "$M" --day 2026-10-15 2>&1)
assert_contains "UTC --day 15th has nothing" "$OUT" "no events"
export METRICS_NOW=$NOW

# ---------- rotated logs (ching-watch.sh moves a full log to events-<UTC stamp>.jsonl) ----------
RT="$WORK/ah-rot"; mkdir -p "$RT"
printf '{"ts":"2026-10-15T09:00:00Z","sid":"r1","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n' >"$RT/events.jsonl"
printf '{"ts":"2026-10-14T09:00:00Z","sid":"r2","cwd":"/work/alpha","kind":"stop_ok","data":{"outcome":"input"}}\n' >"$RT/events-20261015-020000.jsonl"
printf 'garbage that must never be read\n' >"$RT/events-20260101-000000.jsonl"        # rotated long before the window
printf 'garbage in a file that is not a rotation\n' >"$RT/events-notes.txt"
OUT=$(AGENT_HOME="$RT" "$M" 2>&1)
assert_eq "rotated: events from the live and the rotated file are both counted" "2" "$(tcell TOTAL asked)"
assert_eq "rotated: the older day comes from the rotated file" "1" "$(tcell 2026-10-14 asked)"
assert_contains "rotated: nothing malformed (old and unrelated files were not read)" "$OUT" "skipped: 0 malformed lines"
assert_contains "rotated: the header names the extra file" "$OUT" "events.jsonl + 1 rotated"
rm -f "$RT/events.jsonl"
OUT=$(AGENT_HOME="$RT" "$M" 2>&1)
assert_eq "rotated: works with only a rotated file left" "1" "$(tcell TOTAL asked)"
assert_contains "rotated: the header says the live log is missing" "$OUT" "events.jsonl (missing) + 1 rotated"
OUT=$(AGENT_HOME="$RT" "$M" --days 400 2>&1)
assert_contains "rotated: an old rotation is read once the window reaches it" "$OUT" "skipped: 1 malformed lines"

# ---------- speed: a log at the rotation size (20 MiB, ~150k events) ----------
BIG="$WORK/ah-big"; mkdir -p "$BIG"
awk 'BEGIN {
  for (i = 0; i < 1100; i++) {
    sid = "sess-" (i % 400)
    printf "{\"ts\":\"2026-10-15T%02d:%02d:%02dZ\",\"sid\":\"%s\",\"name\":\"alpha\",\"cwd\":\"/work/alpha\",\"kind\":\"stop_ok\",\"data\":{\"outcome\":\"%s\"}}\n", i % 24, i % 60, i % 60, sid, (i % 3 ? "done" : "input")
    printf "{\"ts\":\"2026-10-15T%02d:%02d:%02dZ\",\"sid\":\"%s\",\"name\":\"alpha\",\"cwd\":\"/work/alpha\",\"kind\":\"notify\",\"data\":{\"kind\":\"waiting\",\"outcome\":\"suppressed\",\"reason\":\"quiet-hours\"}}\n", i % 24, i % 60, i % 60, sid
    printf "{\"ts\":\"2026-10-15T%02d:%02d:%02dZ\",\"sid\":\"%s\",\"name\":\"alpha\",\"cwd\":\"/work/alpha\",\"kind\":\"checkpoint\",\"data\":{\"status\":\"\",\"blocker\":\"x\",\"next_action\":\"y\"}}\n", i % 24, i % 60, i % 60, sid
  }
}' >"$BIG/block.jsonl"
for _ in $(seq 1 46); do cat "$BIG/block.jsonl"; done >"$BIG/events.jsonl"; rm -f "$BIG/block.jsonl"
size=$(wc -c <"$BIG/events.jsonl" | tr -d ' ')
t0=$(date +%s)
OUT=$(AGENT_HOME="$BIG" "$M" 2>&1); rc=$?
t1=$(date +%s)
assert_eq "big log: exit 0" "0" "$rc"
assert_eq "big log: questions counted (367 of the 1100 stops in a block, 46 blocks)" "$((367 * 46))" "$(tcell TOTAL asked)"
assert_eq "big log: 400 sessions" "400" "$(tcell TOTAL sess)"
# The limit catches a pathological slowdown (a per-line jq or a quadratic step takes minutes), not a few seconds of
# noise: alone it takes a few seconds, but 22-26 s were seen while the whole suite ran in parallel, so 60 s leaves room.
if [ $((t1 - t0)) -le 60 ]; then pass "big log ($((size / 1048576)) MiB) in $((t1 - t0)) s, under 60 s"; else fail "big log ($((size / 1048576)) MiB) too slow" "  took $((t1 - t0)) s (limit 60 s)"; fi
exit 0
