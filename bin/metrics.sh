#!/usr/bin/env bash
# metrics.sh - the pilot-metrics report (PLAN section 7), read from the event log. Read-only.
#
#   metrics.sh [--days N] [--day YYYY-MM-DD] [--all] [--json]
#
#   --days N   the last N days up to today (default 7; today counts as one)
#   --day D    that one day only
#   --all      count sandbox/test sessions too (same as AGENT_TERMINAL_INCLUDE_SANDBOX=1)
#   --json     the same numbers as one JSON document
#
# One row per day: sessions seen, questions asked, notifications delivered / routed to the inbox / suppressed
# (budget, quiet hours, cooldown, no clock, other), stalls, watcher handoff events, release-gate results; then
# a TOTAL row, a table per release, and a footer that says which numbers are exact and which are proxies.
# Days are LOCAL time (TZ; TZ=UTC gives UTC days): notify.sh books its daily budget and quiet hours by the
# local clock, so a "day" here is the day those limits ran on. Event timestamps are UTC and are converted.
# Reads $AGENT_HOME/events.jsonl and, when the window reaches them, the rotated events-<UTC stamp>.jsonl files
# that agent-terminal-watch.sh leaves. One streaming jq pass over the log, so a 20 MiB log takes a couple of seconds;
# events whose cwd is_sandbox_path (lib.sh) are left out and counted. Malformed lines are skipped and counted.
# Env: AGENT_HOME  AGENT_TERMINAL_INCLUDE_SANDBOX  METRICS_NOW (epoch, tests)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

usage() { sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
bad_usage() { echo "metrics: $1" >&2; echo "usage: metrics.sh [--days N] [--day YYYY-MM-DD] [--all] [--json]" >&2; exit 64; }

DAYS=""; DAY=""; JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || bad_usage "--days needs a number"; DAYS=$2; shift 2 ;;
    --day) [ $# -ge 2 ] || bad_usage "--day needs a date (YYYY-MM-DD)"; DAY=$2; shift 2 ;;
    --all) export AGENT_TERMINAL_INCLUDE_SANDBOX=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) bad_usage "unknown argument $1" ;;
  esac
done
[ -z "$DAYS" ] || [ -z "$DAY" ] || bad_usage "use --days or --day, not both"
if [ -n "$DAYS" ]; then
  case "$DAYS" in ''|*[!0-9]*) bad_usage "--days must be a whole number (got '$DAYS')" ;; esac
  [ "${#DAYS}" -le 4 ] || bad_usage "--days is too large (at most 3650)"
  DAYS=$((10#$DAYS))
  { [ "$DAYS" -ge 1 ] && [ "$DAYS" -le 3650 ]; } || bad_usage "--days must be between 1 and 3650"
fi
if [ -n "$DAY" ]; then
  case "$DAY" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;; *) bad_usage "--day must look like 2026-10-14 (got '$DAY')" ;; esac
  # BSD date rolls an impossible date over (2026-02-30 becomes 03-02): a date that does not read back is wrong
  [ "$(date -j -f '%Y-%m-%d' "$DAY" +%Y-%m-%d 2>/dev/null || true)" = "$DAY" ] || bad_usage "--day is not a real date: $DAY"
fi
[ -n "$DAY" ] || [ -n "$DAYS" ] || DAYS=7

# The window, in local days. FROM..TO are day strings; LO/HI are UTC bounds 36 h wider than the window (more
# than any zone offset), used only to skip the clock conversion of events that are certainly outside it.
NOW=${METRICS_NOW:-}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
if [ -n "$DAY" ]; then FROM=$DAY; TO=$DAY
else TO=$(date -r "$NOW" +%Y-%m-%d); FROM=$(date -v-$((DAYS - 1))d -r "$NOW" +%Y-%m-%d); fi
noon() { date -j -f '%Y-%m-%d %H:%M:%S' "$1 12:00:00" +%s; }
iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
LO=$(iso $(($(noon "$FROM") - 129600)))
HI=$(iso $(($(noon "$TO") + 129600)))
TZNAME=$(date -r "$NOW" +%Z)

# The log files: the live one, plus rotated ones (events-YYYYMMDD-HHMMSS.jsonl, stamped in UTC when the
# watcher moved them) unless the whole file is older than the window.
FILES=()
LO_STAMP=$(printf '%s' "$LO" | tr -d ':-' | tr 'T' '-' | tr -d 'Z')
for f in "$AGENT_HOME"/events-[0-9]*.jsonl; do
  [ -f "$f" ] || continue
  stamp=${f##*/events-}; stamp=${stamp%.jsonl}
  case "$stamp" in [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]) ;; *) continue ;; esac
  if [[ "$stamp" < "$LO_STAMP" ]]; then continue; fi
  FILES+=("$f")
done
ROTATED=${#FILES[@]}
LIVE_PRESENT=false
if [ -f "$AGENT_HOME/events.jsonl" ]; then FILES+=("$AGENT_HOME/events.jsonl"); LIVE_PRESENT=true; fi
for f in ${FILES[@]+"${FILES[@]}"}; do
  [ -r "$f" ] || { echo "metrics: cannot read $f" >&2; exit 1; }
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/agent-terminal-metrics.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# Pass 1, the only pass over the log: every line is parsed once and folded into a small aggregate,
# days -> cwd -> {events, sids, n: bucket counts, rel: per-release counts}. The cwd is kept as a key so that
# the sandbox test (a bash function in lib.sh, one definition for every report) can be applied afterwards
# to the few hundred distinct cwds instead of to every event.
PASS1=$(cat <<'EOF'
def s: if type == "string" then . else "" end;
# the unresolved-blocking count a failed review gate names: "<N> blocking finding(s) without a resolved: line"
def blocking($det):
  ($det | split("blocking finding(s) without a resolved")) as $p
  | if ($p | length) > 1
    then (($p[0] | split(" ") | map(select(. != "")) | last // "") as $t
          | if ($t | test("^[0-9]{1,6}$")) then ($t | tonumber) else 0 end)
    else 0 end;
# one release event -> [[bucket, amount], ...]
def gate($d):
  ($d.outcome | s) as $o | ($d.detail | s) as $det
  | if ($o | startswith("gate-pass")) then [["gpass", 1]]
    elif $o == "gate-fail" then
      [["gfail", 1]]
      + (if ($det | startswith("no review file")) then [["rmiss", 1]] else [] end)
      + (if ($det | startswith("review file ")) and ($det | contains(" rejected"))
         then [["rbad", 1]] + (blocking($det) as $b | if $b > 0 then [["blkd", $b]] else [] end) else [] end)
    else [] end;
# one event -> [[bucket, amount], ...]
def tally($k; $d):
  ($d.outcome | s) as $o | ($d.reason | s) as $r
  | if $k == "stop_ok" then (if $o == "input" then [["asked", 1]] else [] end)
    elif $k == "notify" then
      (if $o == "delivered" then [["deliv", 1]]
       elif $o == "suppressed" then
         (if $r == "routed-to-inbox" then [["inbox", 1]]
          elif $r == "daily-budget" then [["budget", 1]]
          elif $r == "quiet-hours" then [["quiet", 1]]
          elif $r == "cooldown" or $r == "handoff-cooldown" then [["cool", 1]]
          elif $r == "no-clock" then [["noclk", 1]]
          else [["other", 1]] end)
       else [["other", 1]] end)
      + (if ($d.kind | s) == "handoff" and $o == "delivered" then [["nudge", 1]] else [] end)
    elif $k == "stall" then [["stall", 1]]
    elif $k == "context" then (if ($d.level | s) == "handoff" then [["ctx80", 1]] else [] end)
    elif $k == "release" then gate($d)
    else [] end;
reduce inputs as $line ({bad: 0, undated: 0, first: null, last: null, days: {}};
  ($line | try fromjson catch null) as $e
  | if ($e | type) != "object" then (if ($line | test("^[ \t\r]*$")) then . else .bad += 1 end)
    elif ($e.ts | type) != "string" then .undated += 1
    else
      $e.ts as $ts
      | (if .first == null or $ts < .first then .first = $ts else . end)
      | (if .last == null or $ts > .last then .last = $ts else . end)
      | if $ts < $lo or $ts > $hi then
          # outside the window: skipped without a clock conversion, unless it is not even shaped like a time
          (if ($ts | length) >= 20 and $ts[4:5] == "-" and $ts[10:11] == "T" and $ts[0:1] >= "0" and $ts[0:1] <= "9"
           then . else .undated += 1 end)
        else
          (try ($ts | fromdateiso8601) catch null) as $ep
          | if $ep == null then .undated += 1
            else
              ($ep | strflocaltime("%Y-%m-%d")) as $day
              | ($e.cwd | s | gsub("[\t\n\r]"; " ")) as $cwd
              | ($e.kind | s) as $k
              | ($e.data | if type == "object" then . else {} end) as $d
              | ($e.sid | if type == "string" then . elif type == "number" then tostring else "" end) as $sid
              | .days[$day][$cwd].events += 1
              # the machine-wide token event has the pseudo session "machine": not a session
              | (if $sid != "" and $k != "tokens" then .days[$day][$cwd].sids[$sid] = true else . end)
              | reduce (tally($k; $d)[]) as [$b, $n] (.; .days[$day][$cwd].n[$b] += $n)
              | if $k == "release" then
                  ($d.sha | s) as $sha
                  | reduce (gate($d)[]) as [$b, $n] (.; .days[$day][$cwd].rel[$sha][$b] += $n)
                  | (if (($d.outcome | s) | startswith("deploy-")) then .days[$day][$cwd].rel[$sha].deploy = ($d.outcome | s) else . end)
                else . end
            end
        end
    end)
EOF
)
if [ "${#FILES[@]}" -eq 0 ]; then
  echo '{"bad":0,"undated":0,"first":null,"last":null,"days":{}}' >"$TMP/agg.json"
elif ! jq -nR --arg lo "$LO" --arg hi "$HI" "$PASS1" "${FILES[@]}" >"$TMP/agg.json" 2>"$TMP/jq.err"; then
  echo "metrics: could not read the event log: $(head -c 300 "$TMP/jq.err")" >&2
  exit 1
fi

# Sandbox cwds, by the one definition in lib.sh (is_sandbox_path honours AGENT_TERMINAL_INCLUDE_SANDBOX / --all).
: >"$TMP/sbx.txt"
if [ -z "${AGENT_TERMINAL_INCLUDE_SANDBOX:-}" ]; then
  while IFS= read -r c; do
    if is_sandbox_path "$c"; then printf '%s\n' "$c" >>"$TMP/sbx.txt"; fi
  done < <(jq -r '[.days[] | keys[]] | unique | .[]' "$TMP/agg.json")
fi
jq -R . "$TMP/sbx.txt" | jq -sc . >"$TMP/sbx.json"
FILES_JSON=$(printf '%s\n' ${FILES[@]+"${FILES[@]}"} | jq -R . | jq -sc 'map(select(. != ""))')

# Pass 2, on the small aggregate: the window, the sandbox cut, per-day and total rows, per-release rows.
RESULT=$(cat <<'EOF'
def sum($k): map(.c.n[$k] // 0) | add // 0;
def row: {
  sessions: (map(.c.sids // {} | keys[]) | unique | length),
  asked: sum("asked"), delivered: sum("deliv"), inbox: sum("inbox"),
  suppressed: (sum("budget") + sum("quiet") + sum("cool") + sum("noclk") + sum("other")),
  budget: sum("budget"), quiet: sum("quiet"), cooldown: sum("cool"), no_clock: sum("noclk"), other: sum("other"),
  stalls: sum("stall"), ctx80: sum("ctx80"), handoff_nudges: sum("nudge"),
  gate_pass: sum("gpass"), gate_fail: sum("gfail"), review_missing: sum("rmiss"), review_rejected: sum("rbad"),
  blocking_unresolved: sum("blkd") };
def relsum($k): map(.v[$k] // 0) | add;
($sbx[0] // [] | map({key: ., value: true}) | from_entries) as $sb
| [.days | to_entries[] | select(.key >= $from and .key <= $to)
   | .key as $day | .value | to_entries[] | {day: $day, cwd: .key, c: .value}] as $cells
| ($cells | map(select($sb[.cwd] // false))) as $dropped
| ($cells | map(select(($sb[.cwd] // false) | not))) as $kept
| {tz: $tz, day_basis: "local", window: {from: $from, to: $to},
   log: {live: $live, live_present: $livep, files: $files, rotated: $rotated, first_ts: .first, last_ts: .last},
   sandbox_included: ($incl == "1"),
   events: ($kept | map(.c.events // 0) | add // 0),
   days: ($kept | group_by(.day) | map({day: .[0].day} + row)),
   total: ($kept | row),
   releases: ([$kept[] | .day as $d | .cwd as $cwd | (.c.rel // {}) | to_entries[] | {sha: .key, day: $d, cwd: $cwd, v: .value}]
     | group_by(.sha)
     | map(. as $g | {sha: ($g[0].sha | if . == "" then "(none)" else .[0:7] end),
                      day: ($g | map(.day) | min),
                      repo: ($g[0].cwd | split("/") | last // ""),
                      gate_pass: ($g | relsum("gpass")), gate_fail: ($g | relsum("gfail")),
                      review_missing: ($g | relsum("rmiss")), review_rejected: ($g | relsum("rbad")),
                      blocking_unresolved: ($g | relsum("blkd")),
                      deploy: ($g | sort_by(.day) | map(.v.deploy // empty) | last // "")})
     | sort_by(.day, .sha)),
   excluded_sandbox_events: ($dropped | map(.c.events // 0) | add // 0),
   malformed_lines: .bad, undated_events: .undated}
EOF
)
jq --slurpfile sbx "$TMP/sbx.json" --arg from "$FROM" --arg to "$TO" --arg tz "$TZNAME" --arg incl "${AGENT_TERMINAL_INCLUDE_SANDBOX:-}" \
   --argjson files "$FILES_JSON" --argjson rotated "$ROTATED" --arg live "$AGENT_HOME/events.jsonl" --argjson livep "$LIVE_PRESENT" \
   "$RESULT" "$TMP/agg.json" >"$TMP/result.json"

if [ "$JSON" -eq 1 ]; then jq . "$TMP/result.json"; exit 0; fi

# The text report: header, day table with TOTAL, release table, counters. Columns are as wide as their widest cell.
TABLE=$(cat <<'EOF'
def n: tostring;
def rp($w): n | ((" " * ($w - length)) // "") + .;
def lp($w): n | . + ((" " * ($w - length)) // "");
def widths($cols; $rows): $cols | map(. as $c | ([$c.l | length] + ($rows | map(.[$c.k] | n | length))) | max);
def cell($c; $w; $r): if $c.a == "l" then ($r[$c.k] | lp($w)) else ($r[$c.k] | rp($w)) end;
def line($cols; $w; $gaps; $r):
  [range(0; $cols | length) as $i | (if ($gaps | index($i)) then " " else "" end) + cell($cols[$i]; $w[$i]; $r)]
  | join(" ") | sub(" +$"; "");
def headrow($cols): reduce $cols[] as $c ({}; .[$c.k] = $c.l);
def col($l; $k; $a): {l: $l, k: $k, a: $a};
# a label line over a run of columns: "-- notifications ------"
def band($t; $span): (("-- " + $t + " ") | . + (("-" * ($span - length)) // ""));
def groupline($w; $gaps; $groups):
  [range(0; $w | length) as $i
   | ($groups | map(select(.from == $i)) | first) as $g
   | if $g != null then
       ([range($g.from; $g.to + 1) | $w[.]] | add + ($g.to - $g.from)) as $span
       | (if ($gaps | index($i)) then " " else "" end) + band($g.text; $span)
     elif ($groups | map(select(.from < $i and $i <= .to)) | length) > 0 then empty
     else (if ($gaps | index($i)) then " " else "" end) + (" " * $w[$i] // "") end]
  | join(" ") | sub(" +$"; "");
def table($cols; $rows; $gaps; $groups):
  widths($cols; ($rows + [headrow($cols)])) as $w
  | [(if $groups == [] then empty else groupline($w; $gaps; $groups) end),
     line($cols; $w; $gaps; headrow($cols)),
     ($rows[] | line($cols; $w; $gaps; .))] | .[];
def dcols: [col("day"; "day"; "l"), col("sess"; "sessions"; "r"), col("asked"; "asked"; "r"), col("deliv"; "delivered"; "r"),
  col("inbox"; "inbox"; "r"), col("supp"; "suppressed"; "r"), col("budg"; "budget"; "r"), col("quiet"; "quiet"; "r"),
  col("cool"; "cooldown"; "r"), col("noclk"; "no_clock"; "r"), col("other"; "other"; "r"), col("stall"; "stalls"; "r"),
  col("ctx80"; "ctx80"; "r"), col("nudge"; "handoff_nudges"; "r"), col("gpass"; "gate_pass"; "r"), col("gfail"; "gate_fail"; "r"),
  col("rvmis"; "review_missing"; "r"), col("rvbad"; "review_rejected"; "r"), col("blkd"; "blocking_unresolved"; "r")];
def rcols: [col("sha"; "sha"; "l"), col("day"; "day"; "l"), col("repo"; "repo"; "l"), col("gpass"; "gate_pass"; "r"),
  col("gfail"; "gate_fail"; "r"), col("rvmis"; "review_missing"; "r"), col("rvbad"; "review_rejected"; "r"),
  col("blkd"; "blocking_unresolved"; "r"), col("deploy"; "deploy"; "l")];
(.window | if .from == .to then .from + " (1 day)" else .from + " to " + .to end) as $win
| [ (if .events == 0 then
       (if (.log.files | length) == 0 then "no events (no log at \(.log.live))"
        elif .log.first_ts == null then "no events (the log has no readable event)"
        else "no events from \($win) (the log runs from \(.log.first_ts) to \(.log.last_ts))" end)
     else
       ("agent-terminal pilot metrics, \($win); days are local time (\(.tz)), the clock notify.sh budgets by",
        "log: \(.log.live)" + (if .log.live_present then "" else " (missing)" end) + (if .log.rotated > 0 then " + \(.log.rotated) rotated" else "" end),
        "",
        table(dcols; (.days + [.total + {day: "TOTAL"}]); [2, 3, 11, 12, 14];
              [{from: 3, to: 10, text: "notifications"}, {from: 12, to: 13, text: "handoff"}, {from: 14, to: 18, text: "release gate"}]),
        "",
        (if (.releases | length) == 0 then "releases: none in this window"
         else table(rcols; (.releases | map(.deploy |= (if . == "" then "-" else . end))); [3]; []) end),
        "",
        "sessions seen: \(.total.sessions) distinct over the window (the TOTAL row counts a session once, however many days it spans)")
     end),
    (if (.log.files | length) == 0 then empty else
      ("excluded: \(.excluded_sandbox_events) events"
         + (if .sandbox_included then " (sandbox/test sessions are counted: --all or AGENT_TERMINAL_INCLUDE_SANDBOX=1)"
            else " from sandbox/test sessions (cwd under /tmp, /private/tmp, /var/folders or a task*-repo folder); --all or AGENT_TERMINAL_INCLUDE_SANDBOX=1 counts them" end),
       "skipped: \(.malformed_lines) malformed lines, \(.undated_events) events without a usable timestamp") end) ]
| .[]
EOF
)
jq -r "$TABLE" "$TMP/result.json"

if [ "$(jq -r .events "$TMP/result.json")" -gt 0 ]; then
cat <<'EOF'

columns (exact = a count of logged events; proxy = a stand-in for what PLAN section 7 asks):
  sess   exact  distinct session ids with any event that day
  asked  proxy  stop_ok events with outcome input: stop-check.sh calls a turn a question when the last line of the final message ends in "?". Permission prompts and idle notices are not counted
  deliv  exact  notify events delivered (urgent kinds always; budgeted kinds inside budget and hours)
  inbox  exact  notify events routed to the inbox (kind done): logged as suppressed, never pushed
  supp   exact  notify events held back for a reason: budg + quiet + cool + noclk + other (inbox not included)
  budg quiet cool noclk  exact  daily budget used up / quiet hours / per-session cooldown (the handoff cooldown too) / no readable clock
  other  exact  held back for a reason this report does not know, or an outcome it cannot read
  stall  exact  stall events (a working session whose transcript went silent); whether a stall was real cannot be told from the log
  ctx80  exact  context events at level handoff (the watcher saw 80% or more; repeats if the level wobbles)
  nudge  exact  handoff notifications delivered; whether /handoff was then run is not logged
  gpass gfail  exact  release events gate-pass-* and gate-fail
  rvmis rvbad  exact  failed gates whose detail says the review file is missing / was rejected
  blkd   proxy  unresolved [blocking] findings named in failed-gate details; the blocking count of a review that passed is not logged
not in the log at all: idle notices dropped by notify.sh's de-dup, /handoff runs, what became of a stall, blocking findings of passed gates.
EOF
fi
exit 0
