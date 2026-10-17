#!/usr/bin/env bash
# learn-report.sh - the learner's weekly report and blind-spot ledger (Phase 6 spec 5.4). Deterministic, no
# model call. Reads what learn-extract.sh left in $AGENT_HOME/proposals/.work and writes:
#
#   proposals/report-YYYY-Www.md   (through proposal_safe_path, mode 0600; rewritten when run again)
#     - sessions and counted prompts per folder (.work/prompts.jsonl, the same filter as every learner count)
#     - prompt hours and weekdays in local time (timestamps are UTC and are converted with TZ)
#     - stop retries (stop_blocked), stalls, context handoffs (context level handoff) and denies per folder
#     - notifications delivered, and suppressed by reason (notify events)
#     - per task_type: sessions, stop retries, test runs and time to green, once checkpoint events carry
#       task_type and `tests` events exist (spec 4.3); until then one line says so
#     - week on week: a measure shows a change only when both weeks have data for it (prompts for sessions
#       and prompts, events for the rest); otherwise its row shows "-"
#     - feedback (spec 6.5): approved, rejected and snoozed per component, in the week and up to its end, from
#       `proposal` events (the component from the archived file, else from the id's kind) and from archive/
#       files that no event names (on their mtime). A component whose decisions since its last approval or
#       snooze are all rejections, the first of them 4 or more weeks ago (in week W-3 or earlier), is flagged
#       with the LEARN_DISABLE name that turns it off (blindspot proposals come from the report step)
#     - the blind-spot ledger
#   proposals/blindspot-<slug>.md  (through proposal_write) for each not_examined item seen in 3 or more
#     checkpoints across 2 or more sessions. Items come from checkpoint events (data.not_examined) and from the
#     checkpoint block of STATE.md files ($AGENT_HOME/sessions/*/STATE.md and <folder>/.agent/STATE.md for the
#     folders seen in events); a STATE.md item already present in an event of the same session is not counted
#     twice. Items are split on ";" and ", ", parenthesised asides dropped, then lower-cased with paths (words
#     holding a "/") and commit ids (7-40 hex characters with a digit) stripped. The ledger covers all events.
#
#   learn-report.sh [--week YYYY-Www]
#
#   --week W   the ISO week to report (local time). Default: the last complete week before today.
#
# Events of sessions whose transcript has no countable line (sdk-cli runs; the extractor's state says which)
# are left out, like the sandbox and .work events learn_event_ok already drops. Emits one learn_run event
# (component report). Exit: 0 ok | 1 the extractor has not run or a step failed | 3 unsafe path | 64 usage.
# Env: AGENT_HOME TZ LEARN_NOW (epoch seconds, tests)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
umask 077

usage() { sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
bad_usage() { echo "learn-report: $1" >&2; echo "usage: learn-report.sh [--week YYYY-Www]" >&2; exit 64; }
die() { echo "learn-report: $1" >&2; exit 1; }

WEEK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --week) [ $# -ge 2 ] || bad_usage "--week needs a week (YYYY-Www)"; WEEK=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) bad_usage "unknown argument $1" ;;
  esac
done

NOW=${LEARN_NOW:-}
case "$NOW" in ''|*[!0-9]*) NOW=$(date +%s) ;; esac
at_noon() { # DAY [-v+Nd] +FMT: DAY at local noon (DST-safe), shifted, formatted (BSD date: -v before the date)
  if [ $# -eq 3 ]; then date -j "$2" -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" "$3"; else date -j -f "%Y-%m-%d %H:%M:%S" "$1 12:00:00" "$2"; fi
}
if [ -n "$WEEK" ]; then
  case "$WEEK" in [0-9][0-9][0-9][0-9]-W[0-9][0-9]) ;; *) bad_usage "--week must look like 2026-W42 (got '$WEEK')" ;; esac
  y=${WEEK%%-W*}; w=$((10#${WEEK##*-W}))
  # ISO week 1 holds January 4: its Monday plus (w - 1) weeks
  u4=$(at_noon "$y-01-04" +%u)
  MON=$(at_noon "$y-01-04" -v+$(((w - 1) * 7 - (u4 - 1)))d +%Y-%m-%d)
  [ "$(at_noon "$MON" +%G-W%V)" = "$WEEK" ] || bad_usage "--week is not a real ISO week: $WEEK"
else
  u=$(date -r "$NOW" +%u)
  MON=$(date -r "$NOW" -v-$((u - 1 + 7))d +%Y-%m-%d)
  WEEK=$(at_noon "$MON" +%G-W%V)
fi
SUN=$(at_noon "$MON" -v+6d +%Y-%m-%d)
W2MON=$(at_noon "$MON" -v-14d +%Y-%m-%d)   # a rejection streak that began before this day spans 4 or more weeks
PMON=$(at_noon "$MON" -v-7d +%Y-%m-%d)
PREV=$(at_noon "$PMON" +%G-W%V)
TZNAME=$(at_noon "$MON" +%Z)

ROOT=$(proposals_root) || exit 3
REPORT=$(proposal_safe_path "report-$WEEK.md") || exit 3
WD=$ROOT/.work
[ -f "$WD/offsets" ] && [ -f "$WD/prompts.jsonl" ] && [ -f "$WD/extract-state.json" ] \
  || die "no extractor output in $WD: run learn-extract.sh first"
EVW=$WD/events.jsonl
[ -f "$EVW" ] || EVW=/dev/null

TMP=$(mktemp -d "${TMPDIR:-/tmp}/kaching-learn-report.XXXXXX")
trap 'rm -rf "$TMP"; rm -f "$ROOT"/.report-*.tmp."$$"' EXIT

# ---------- the inputs, cut to what the report needs ----------
jq -c '[.sessions | to_entries[] | select(.value.seen == true and .value.ok != true) | .key]' "$WD/extract-state.json" \
  >"$TMP/excluded" || die "cannot read the extractor state"
# shellcheck disable=SC2016 # jq source
WEEKOF='def week: tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%G-W%V")) catch "");'
jq -c "$WEEKOF"' select((.ts | week) as $w | $w == $week or $w == $prev) | . + {w: (.ts | week)}' \
  --arg week "$WEEK" --arg prev "$PREV" "$WD/prompts.jsonl" >"$TMP/prompts" || die "cannot read prompts.jsonl"
jq -c --slurpfile x "$TMP/excluded" "$WEEKOF"'
  ($x[0] | map({key: ., value: true}) | from_entries) as $ex
  | select(type == "object" and ($ex[.sid // ""] | not))
  | if .kind == "checkpoint" then . + {w: (.ts | week)}
    else select((.ts | week) as $w | $w == $week or $w == $prev) | . + {w: (.ts | week)} end' \
  --arg week "$WEEK" --arg prev "$PREV" "$EVW" >"$TMP/events" || die "cannot read events.jsonl"

# ---------- blind-spot ledger: checkpoint events plus STATE.md checkpoint blocks ----------
: >"$TMP/state-items"
add_state() { # file key cwd
  local ne day
  ne=$(checkpoint_get "$1" not_examined)
  [ -n "$ne" ] || return 0
  day=$(date -r "$(file_mtime "$1")" +%Y-%m-%d)
  jq -nc --arg sid "$2" --arg cwd "$3" --arg day "$day" --arg t "$ne" '{sid:$sid, cwd:$cwd, day:$day, text:$t, src:"state"}' \
    >>"$TMP/state-items"
}
for f in "$AGENT_HOME"/sessions/*/STATE.md; do
  [ -f "$f" ] || continue
  d=${f%/STATE.md}
  add_state "$f" "${d##*/}" "$(meta_get "$d/meta" cwd)"
done
# repo-mode STATE.md: <folder>/.agent/STATE.md for every folder (and its parents) that events name
jq -r 'select(.kind != "learn_run" and .kind != "proposal") | .cwd // empty' "$EVW" 2>/dev/null | sort -u >"$TMP/cwds" || true
: >"$TMP/repos"
while IFS= read -r c; do
  while [ -n "$c" ] && [ "$c" != / ]; do
    if [ -f "$c/.agent/STATE.md" ]; then printf '%s\n' "$c" >>"$TMP/repos"; break; fi
    c=${c%/*}
  done
done <"$TMP/cwds"
sort -u "$TMP/repos" | while IFS= read -r r; do add_state "$r/.agent/STATE.md" "repo:$r" "$r"; done

# shellcheck disable=SC2016 # jq source
LEDGER='
def items: gsub("\\([^)]*\\)"; "") | [splits("\\s*;\\s*|,\\s+|\\n")] | map(sub("^\\s+"; "") | sub("[\\s.]+$"; "")) | map(select(. != ""));
def norm: ascii_downcase
  | gsub("\\S*/\\S*"; "")
  | gsub("\\b(?=[0-9a-f]*[0-9])[0-9a-f]{7,40}\\b"; "")
  | gsub("\\s+"; " ") | sub("^ "; "") | sub("[ .,:;]+$"; "");
def empty_item: . == "" or test("^(none|nothing|n/?a|-+)$");
def localday: tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch .[0:10]);
([$ev[] | select(.kind == "checkpoint" and ((.data.not_examined // "") | tostring | test("\\S")))
   | {sid: (.sid // ""), cwd: (.cwd // ""), day: (.ts | localday), text: (.data.not_examined | tostring), src: "event"}]) as $e
| [($e + $st)[] | . as $c | ($c.text | items[]) | {raw: ., n: norm, sid: $c.sid, cwd: $c.cwd, day: $c.day, src: $c.src}
   | select(.n | empty_item | not)] as $all
| ([$all[] | select(.src == "event") | "\(.sid)\t\(.n)"] | map({key: ., value: true}) | from_entries) as $seen
| [$all[] | select(.src == "event" or ($seen["\(.sid)\t\(.n)"] | not))]
| group_by(.n)
| map({n: .[0].n, raw: (sort_by(.day) | last | .raw), checkpoints: length, sessions: (map(.sid) | unique | length), days: (map(.day) | unique | length),
       evidence: (sort_by(.day) | reverse | .[0:10] | map({sid: (if .sid == "" then "unknown" else .sid end), day, cwd, quote: .raw}))})
| sort_by(-.checkpoints, -.sessions, .n)
| .[]
'
jq -c -n --slurpfile ev "$TMP/events" --slurpfile st "$TMP/state-items" "$LEDGER" >"$TMP/ledger" || die "cannot build the blind-spot ledger"

: >"$TMP/ledger-out"
PROPS=0
while IFS= read -r it; do
  [ -n "$it" ] || continue
  n=$(printf '%s' "$it" | jq -r .n)
  cps=$(printf '%s' "$it" | jq -r .checkpoints); ses=$(printf '%s' "$it" | jq -r .sessions)
  status="below the bar"
  if [ "$cps" -ge 3 ] && [ "$ses" -ge 2 ]; then
    slug=$(proposal_slug "$n")
    if [ -z "$slug" ]; then status="no usable name"
    else
      fp=$(proposal_fingerprint "$n")
      json=$(printf '%s' "$it" | jq -c --arg fp "$fp" '{
        component: "blindspot", fingerprint: $fp, sessions, days, target: "templates/VERIFY.md",
        proposal: ("Checkpoints listed \"\(.raw)\" (or the same item in other words) under not_examined \(.checkpoints) times in \(.sessions) sessions on \(.days) days. "
          + "Add a review lens line or a VERIFY.md prompt that asks for it, so that the next session examines it or says why it cannot."),
        evidence}')
      status="proposal failed"
      for suf in "" -2 -3 -4 -5; do
        rc=0; out=$(printf '%s' "$json" | proposal_write "blindspot-$slug$suf.md" 2>"$TMP/pw.err") || rc=$?
        if [ "$rc" -eq 4 ]; then continue; fi
        if [ "$rc" -eq 0 ]; then
          case "$out" in
            written*) PROPS=$((PROPS + 1)); status="${out%% *} ${out##*/}" ;;   # learn_run counts new files only
            refreshed*) status="${out%% *} ${out##*/}" ;;
            skipped*) status=$(printf '%s' "$out" | cut -d' ' -f1-2) ;;
          esac
        else
          echo "learn-report: proposal_write: $(cat "$TMP/pw.err")" >&2
        fi
        break
      done
    fi
  fi
  printf '%s' "$it" | jq -c --arg s "$status" '{n, raw, checkpoints, sessions, status: $s}' >>"$TMP/ledger-out"
done <"$TMP/ledger"

# ---------- feedback: decisions per component (proposal events, and archive/ files no event names) ----------
: >"$TMP/archive"
for f in "$ROOT"/archive/*.md; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  id=$(proposal_get "$f" id); [ -n "$id" ] || { id=${f##*/}; id=${id%%.*}; }
  m=$(file_mtime "$f")
  jq -nc --arg id "$id" --arg c "$(proposal_get "$f" component)" --arg s "$(proposal_get "$f" status)" \
    --arg day "$(date -r "$m" +%Y-%m-%d)" --arg w "$(date -r "$m" +%G-W%V)" '{id:$id, component:$c, status:$s, day:$day, w:$w}' >>"$TMP/archive"
done
# shellcheck disable=SC2016 # jq source
jq -R -n -c --slurpfile a "$TMP/archive" --arg sun "$SUN" "$WEEKOF"'
  def localday: tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch "");
  def kindcomp: {rule: "corrections", skill: "skills", blindspot: "blindspot", lesson: "lessons", prune: "lessons"}[split("-")[0]] // "unknown";
  def acts: IN("approved", "rejected", "snoozed");
  ($a | map(select(.component != "")) | map({key: .id, value: .component}) | from_entries) as $comp
  | [inputs | fromjson? // empty
     | select(type == "object" and .kind == "proposal" and (.data.id | type) == "string" and (.data.action | type) == "string" and (.data.action | acts))
     | {id: .data.id, action: .data.action, ts: (.ts | tostring), day: (.ts | localday), w: (.ts | week)}] as $ev
  | ($ev | map({key: .id, value: true}) | from_entries) as $named
  | ($ev + [$a[] | select($named[.id] | not) | (.status | sub(":.*$"; "")) as $act | select($act | acts)
            | {id, action: $act, ts: (.day + "T12:00:00Z"), day, w}])[]
  | select(.day != "" and .day <= $sun) | . + {component: ($comp[.id] // (.id | kindcomp))}' "$EVW" >"$TMP/decisions" \
  || die "cannot read the proposal decisions"

# ---------- the report ----------
# shellcheck disable=SC2016 # jq source
REPORT_JQ='
def folder: if . == "" or . == null then "-" elif . == $home then "~" elif startswith($home + "/") then "~" + .[($home | length):] else . end;
def lt($f): tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601 | strflocaltime($f)) catch "");
def row: "| " + (map(tostring) | join(" | ")) + " |";
def median: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def secs: tostring | (try (sub("\\.[0-9]+"; "") | fromdateiso8601) catch null);
def stats($w):
  ([$p[] | select(.w == $w)]) as $pp
  | ([$e[] | select(.w == $w and .kind != "learn_run" and .kind != "proposal")]) as $ee
  | {prompts: ($pp | length), sessions: ($pp | map(.sid) | unique | length),
     retries: ([$ee[] | select(.kind == "stop_blocked")] | length),
     stalls: ([$ee[] | select(.kind == "stall")] | length),
     handoffs: ([$ee[] | select(.kind == "context" and .data.level == "handoff")] | length),
     denies: ([$ee[] | select(.kind == "deny")] | length),
     delivered: ([$ee[] | select(.kind == "notify" and .data.outcome == "delivered")] | length),
     suppressed: ([$ee[] | select(.kind == "notify" and .data.outcome == "suppressed")] | length),
     events: ($ee | length)};
([$p[] | select(.w == $week)]) as $pp
| ([$e[] | select(.w == $week and .kind != "learn_run" and .kind != "proposal")]) as $ee
| stats($week) as $now | stats($prev) as $before
| [
  "# Weekly report \($week)", "",
  "week: \($mon) to \($sun) (local time, \($tz))",
  "generated: \($gen)",
  "sources: \($now.prompts) counted prompts (.work/prompts.jsonl) and \($now.events) events (.work/events.jsonl) in the week",
  "",
  "## Sessions and prompts per folder", "",
  (if ($pp | length) == 0 then "No counted prompts this week."
   else ("| folder | sessions | prompts |", "|---|---:|---:|",
     ($pp | group_by(.cwd) | map({f: (.[0].cwd | folder), s: (map(.sid) | unique | length), n: length})
       | sort_by(-.n, .f)[] | [.f, .s, .n] | row),
     (["**total**", $now.sessions, $now.prompts] | row)) end),
  "",
  "## When prompts were typed (local time, \($tz))", "",
  (if ($pp | length) == 0 then "No counted prompts this week."
   else ([$pp[] | .ts | lt("%H")] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $h
     | ([$pp[] | .ts | lt("%u")] | group_by(.) | map({key: .[0], value: length}) | from_entries) as $d
     | ("| hour | " + ([range(0; 24) | if . < 10 then "0\(.)" else "\(.)" end] | join(" | ")) + " |",
        "|---|" + ([range(0; 24) | "---:"] | join("|")) + "|",
        "| prompts | " + ([range(0; 24) | (if . < 10 then "0\(.)" else "\(.)" end) as $k | ($h[$k] // 0 | tostring)] | join(" | ")) + " |",
        "",
        "| weekday | Mon | Tue | Wed | Thu | Fri | Sat | Sun |", "|---|---:|---:|---:|---:|---:|---:|---:|",
        "| prompts | " + ([range(1; 8) | tostring | $d[.] // 0 | tostring] | join(" | ")) + " |") end),
  "",
  "## Stop retries, stalls, context handoffs and denies per folder", "",
  ([$ee[] | select(.kind == "stop_blocked" or .kind == "stall" or .kind == "deny" or (.kind == "context" and .data.level == "handoff"))] as $x
   | if ($x | length) == 0 then "None this week."
     else ("| folder | stop retries | stalls | context handoffs | denies |", "|---|---:|---:|---:|---:|",
       ($x | group_by(.cwd) | map({f: (.[0].cwd | folder),
            r: ([.[] | select(.kind == "stop_blocked")] | length), s: ([.[] | select(.kind == "stall")] | length),
            h: ([.[] | select(.kind == "context")] | length), d: ([.[] | select(.kind == "deny")] | length)})
         | sort_by(-(.r + .s + .h + .d), .f)[] | [.f, .r, .s, .h, .d] | row),
       (["**total**", $now.retries, $now.stalls, $now.handoffs, $now.denies] | row)) end),
  "",
  "## Notifications", "",
  ([$ee[] | select(.kind == "notify")] as $x
   | if ($x | length) == 0 then "None this week."
     else ("| outcome | reason | count | by kind |", "|---|---|---:|---|",
       ($x | group_by([.data.outcome // "", .data.reason // ""]) | map({o: (.[0].data.outcome // "-"), r: (.[0].data.reason // ""), n: length,
            k: (group_by(.data.kind // "") | map({k: (.[0].data.kind // "-"), n: length}) | sort_by(-.n, .k) | map("\(.k) \(.n)") | join(", "))})
         | sort_by(.o != "delivered", -.n, .r)[] | [.o, (if .r == "" then "-" else .r end), .n, .k] | row)) end),
  "",
  "## Per task type", "",
  ([$e[] | select(.kind == "checkpoint" and ((.data.task_type // "") | tostring | test("\\S")))]
   | map({key: .sid, value: (.data.task_type | tostring)}) | from_entries) as $tt
  | ([$ee[] | select(.kind == "tests")]) as $tests
  | (if ($tt | length) == 0 then "No task_type yet: checkpoint events do not carry it (spec 4.3)."
     else ([$ee[] | select(.kind == "stop_blocked" or .kind == "tests" or .kind == "checkpoint") | select($tt[.sid] != null)] | group_by($tt[.sid])) as $g
       | if ($g | length) == 0 then "No session with a task_type was active this week."
         else ("| task type | sessions | stop retries | test runs | failed | green first time | median minutes to green |",
               "|---|---:|---:|---:|---:|---:|---:|",
           ($g | map(. as $grp
             | ($grp | map(.sid) | unique) as $sids
             | ([$sids[] as $s | [$grp[] | select(.sid == $s and .kind == "tests")] | sort_by(.ts)
                 | (map(.data.outcome) | index("fail")) as $f
                 | if length == 0 then empty
                   elif $f == null then {first: true}
                   else (.[$f:] | map(.) | map(select(.data.outcome == "pass")) | first) as $ok
                     | if $ok == null then {first: false} else {first: false, mins: ((($ok.ts | secs) - (.[$f].ts | secs)) / 60 | floor)} end
                   end]) as $runs
             | [$tt[$grp[0].sid], ($sids | length), ([$grp[] | select(.kind == "stop_blocked")] | length),
                ([$grp[] | select(.kind == "tests")] | length), ([$grp[] | select(.kind == "tests" and .data.outcome == "fail")] | length),
                ([$runs[] | select(.first)] | length), ([$runs[] | .mins // empty] | median // "-")])
             | sort_by(.[0])[] | row),
           (if ($tests | length) == 0 then "", "No tests events yet, so time to green cannot be measured." else empty end)) end end),
  "",
  "## Week on week", "",
  # a measure is compared only when both weeks have data from its source: prompts, or events
  ({prompts: ($before.prompts > 0 and $now.prompts > 0), events: ($before.events > 0 and $now.events > 0)}) as $both
  | (if $now.events + $now.prompts == 0 or $before.events + $before.prompts == 0
   then "Not shown: \(if $before.events + $before.prompts == 0 then $prev else $week end) has no data."
   elif ($both.prompts or $both.events) | not
   then "Not shown: no measure has data in both weeks (\($prev): \($before.prompts) prompts, \($before.events) events; \($week): \($now.prompts) prompts, \($now.events) events)."
   else ("| measure | \($prev) | \($week) | change |", "|---|---:|---:|---:|",
     ([["sessions", "sessions", "prompts"], ["prompts", "prompts", "prompts"], ["stop retries", "retries", "events"], ["stalls", "stalls", "events"],
       ["context handoffs", "handoffs", "events"], ["denies", "denies", "events"], ["notifications delivered", "delivered", "events"],
       ["notifications suppressed", "suppressed", "events"]][]
      | .[2] as $src
      | [.[0], (if $before[$src] > 0 then $before[.[1]] else "-" end), (if $now[$src] > 0 then $now[.[1]] else "-" end),
         (if $both[$src] then (($now[.[1]] - $before[.[1]]) | if . > 0 then "+\(.)" else tostring end) else "-" end)] | row),
     (if $both.prompts and $both.events then empty
      else "", "A \"-\" means that week has no \(if $both.prompts then "events" else "prompts" end) to compare, so the change is not shown." end)) end),
  "",
  "## Feedback on proposals", "",
  (if ($d | length) == 0 then "No proposal decided yet (no proposal events, no files in archive/)."
   else ("Approved, rejected and snoozed proposals per component: in the week, and in all up to its end (proposal events, and archive/ files no event names).", "",
     "| component | approved | rejected | snoozed | approved in all | rejected in all | snoozed in all |",
     "|---|---:|---:|---:|---:|---:|---:|",
     ($d | group_by(.component)[] | . as $g
      | [$g[0].component]
        + ([["approved", "rejected", "snoozed"][] as $x | [$g[] | select(.w == $week and .action == $x)] | length])
        + ([["approved", "rejected", "snoozed"][] as $x | [$g[] | select(.action == $x)] | length])
      | row),
     ($d | group_by(.component) | map(sort_by(.day, .ts)
        | (map(.action != "rejected") | rindex(true)) as $last
        | (if $last == null then . else .[$last + 1:] end) as $streak
        | select(($streak | length) > 0 and $streak[0].day < $w2mon)
        | {c: .[0].component, since: $streak[0].day, n: ($streak | length)}) as $flags
      | if ($flags | length) == 0 then empty
        else "", ($flags[] | "- \(.c): only rejections since \(.since) (\(.n) in a row, 4 weeks or more). To turn it off: LEARN_DISABLE=\(if .c == "blindspot" then "report" else .c end)") end)) end),
  "",
  "## Blind spots (all checkpoints so far)", "",
  "An item becomes a blindspot proposal at 3 checkpoints in 2 or more sessions.",
  "",
  (if ($l | length) == 0 then "No not_examined items yet: checkpoint events and STATE.md files hold none."
   else ("| item | checkpoints | sessions | status |", "|---|---:|---:|---|",
     ($l[0:30][] | [(.raw | gsub("\\|"; "/")), .checkpoints, .sessions, .status] | row),
     (if ($l | length) > 30 then "", "\($l | length - 30) more items below the bar are not listed." else empty end)) end)
  ] | join("\n")
'
jq -n -r --slurpfile p "$TMP/prompts" --slurpfile e "$TMP/events" --slurpfile l "$TMP/ledger-out" \
  --slurpfile d "$TMP/decisions" --arg w2mon "$W2MON" --arg week "$WEEK" --arg prev "$PREV" --arg mon "$MON" --arg sun "$SUN" --arg tz "$TZNAME" --arg home "$HOME" \
  --arg gen "$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ)" "$REPORT_JQ" >"$TMP/report" \
  || die "cannot build the report"

tmp="$ROOT/.report-$WEEK.tmp.$$"
if ! cp "$TMP/report" "$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$REPORT"; then die "cannot write $REPORT"; fi

# ---------- bookkeeping ----------
scanned=$(jq -n --slurpfile p "$TMP/prompts" --slurpfile e "$TMP/events" --arg w "$WEEK" \
  '([$p[] | select(.w == $w)] | length) + ([$e[] | select(.w == $w and .kind != "learn_run" and .kind != "proposal")] | length)')
cands=$(grep -c . "$TMP/ledger-out" || true)
outcome=ok; [ "$scanned" -gt 0 ] || outcome=nothing-new
SID="" NAME=".work" CWD=$WD ev learn_run "$(jq -nc --argjson s "$scanned" --argjson c "$cands" --argjson p "$PROPS" --arg o "$outcome" \
  '{component:"report", scanned:$s, candidates:$c, proposals:$p, outcome:$o}')"
echo "report $REPORT"
exit 0
