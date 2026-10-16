#!/usr/bin/env bash
# learn-skills.sh - the skill-candidate miner (Phase 6 spec 5.3; interfaces in docs/learn-contracts.md).
#
#   learn-skills.sh [--dry-run]
#
# Reads the extractor's .work/toolseq.jsonl and .work/prompts.jsonl under $AGENT_HOME/proposals and the installed
# skills, and writes at most LEARN_SKILL_MAX skill-<slug>.md proposals, only through proposal_write.
#   1. Deterministic: every 3-6-step run of tokens with at least 2 distinct tokens, counted once per session, kept
#      when it is in 3+ sessions on 2+ days. Only maximal runs are kept: one that sits inside a longer kept run with
#      the same session set is not listed. Then dropped: runs made only of Read/Edit/Grep/Glob/Write, and runs that
#      use an installed skill (a Skill:<name> token). Ranked by sessions x length, then days. Each session carries
#      the human prompt that preceded the run (toolseq prompts[{i,ts}] joined to prompts.jsonl on sid and ts).
#   2. Candidates whose fingerprint was rejected, approved or is snoozed are not sent again. The best ones (at most
#      40, each with at most 3 prompts, at most LEARN_MAX_SNIPPETS prompts in all; hitting that cap is the outcome
#      "truncated") go to ONE learn_model_call with LEARN_MODEL_DRAFT (prompt: templates/learn-prompts/skills.md).
#      The model keeps the nameable, repeatable intents no installed skill covers and drafts a SKILL.md
#      description. Kept answers are matched back to the candidates sent (anything else is ignored), taken in rank
#      order, and written until LEARN_SKILL_MAX proposals were written or refreshed.
# No model call when there is no candidate, or when the input is the same as the last successful run's.
# One learn_run event per run: {component:"skills", scanned, candidates, proposals, outcome}.
# --dry-run prints every ranked candidate as one JSON line {sequence, sessions, days, length, score, folders,
#   prompts, evidence} and stops: no model call, no proposal, no event.
# Exit: 0 ok, nothing-new, truncated, capped or disabled (LEARN_SKILL_MAX=0) | 1 error (logged) | 64 usage.
# Env: AGENT_HOME CLAUDE_DIR CHING_CLAUDE_BIN LEARN_* (learn_setting)
#      CHING_SKILL_DIRS    colon-separated directories whose <name>/SKILL.md are installed skills ($CLAUDE_DIR/skills)
#      CHING_PLUGINS_FILE  plugin list ($CLAUDE_DIR/plugins/installed_plugins.json); <installPath>/skills/<name>/SKILL.md
#                          of each plugin is the installed skill <plugin>:<name>
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
TEMPLATE="$SELF_DIR/../templates/learn-prompts/skills.md"
SHORTLIST=40   # candidates sent to the model, at most
EVIDENCE=5     # evidence lines per proposal (most recent sessions first), at most

usage() { sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "learn-skills: unknown argument '$1'" >&2; echo "usage: learn-skills.sh [--dry-run]" >&2; exit 64 ;;
  esac
  shift
done

# ev() reads these: the learner's events carry its own .work as cwd (learn_event_ok keeps learn_run anyway)
SID=""; NAME=learn-skills; CWD=$(learn_work_dir)
SCANNED=0; CANDS=0; PROPS=0
finish() { # OUTCOME [EXIT]: emit learn_run (not in a dry run) and exit
  if [ "$DRY" -eq 0 ]; then
    ev learn_run "$(jq -nc --argjson s "$SCANNED" --argjson c "$CANDS" --argjson p "$PROPS" --arg o "$1" \
      '{component: "skills", scanned: $s, candidates: $c, proposals: $p, outcome: $o}')"
  fi
  exit "${2:-0}"
}
LOGF=""
log() { [ -n "$LOGF" ] || return 0; { (umask 077; printf '%s skills: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOGF"); } 2>/dev/null || true; }

ROOT=$(proposals_root) || finish error 1
LOGF=$(proposal_safe_path .work/learn.log) || finish error 1
TS_FILE=$(proposal_safe_path .work/toolseq.jsonl) || finish error 1
PR_FILE=$(proposal_safe_path .work/prompts.jsonl) || finish error 1
[ -f "$TS_FILE" ] || TS_FILE=/dev/null
[ -f "$PR_FILE" ] || PR_FILE=/dev/null

# ---------- installed skills: "name<TAB>description" lines ----------
skill_desc() { # SKILL.md -> its front-matter description on one line (a | or > block gives its first line)
  awk 'NR == 1 { if ($0 != "---") exit; next }
       $0 == "---" { exit }
       want { sub(/^[ \t]+/, ""); print; exit }
       /^description:/ { v = $0; sub(/^description:[ \t]*/, "", v)
                         if (v == "" || v ~ /^[|>][-+]?$/) { want = 1; next }
                         print v; exit }' "$1" 2>/dev/null | tr '\t' ' ' | cut -c1-200
}
installed_skills() {
  local dirs d f plugin path pf=${CHING_PLUGINS_FILE:-$CLAUDE_DIR/plugins/installed_plugins.json}
  IFS=: read -r -a dirs <<<"${CHING_SKILL_DIRS:-$CLAUDE_DIR/skills}"
  for d in ${dirs[@]+"${dirs[@]}"}; do
    for f in "$d"/*/SKILL.md; do
      [ -f "$f" ] || continue
      d=${f%/SKILL.md}; printf '%s\t%s\n' "${d##*/}" "$(skill_desc "$f")"
    done
  done
  [ -f "$pf" ] || return 0
  jq -r '.plugins // {} | to_entries[] | (.key | split("@")[0]) as $p
         | .value[]? | select((.installPath | type) == "string") | "\($p)\t\(.installPath)"' "$pf" 2>/dev/null \
    | while IFS=$'\t' read -r plugin path; do
        for f in "$path"/skills/*/SKILL.md; do
          [ -f "$f" ] || continue
          d=${f%/SKILL.md}; printf '%s:%s\t%s\n' "$plugin" "${d##*/}" "$(skill_desc "$f")"
        done
      done
}
INSTALLED=$(installed_skills | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
  | {name: .[0], description: (.[1] // "")}) | unique_by(.name)')
# names a skill answers to: "<plugin>:<skill>" and the bare "<skill>"
NAMESET=$(printf '%s' "$INSTALLED" | jq -c 'map(.name, (.name | split(":") | last)) | map({key: ., value: true}) | from_entries')

# ---------- deterministic stage (one jq pass) ----------
# Every array slice is copied (`| map(.)`) before it is compared: jq 1.7.1 (macOS /usr/bin/jq) compares slices
# wrongly, so `unique` dropped real n-grams and `==` said two different slices were equal.
# shellcheck disable=SC2016 # jq program, not shell
MINE='
def lines: split("\n") | map(fromjson? // empty | select(type == "object"));
def pos($t; $s): first(range(0; ($t | length) - ($s | length) + 1) as $i | select(($t[$i:$i + ($s | length)] | map(.)) == $s) | $i) // 0;
def isre: IN("Read", "Edit", "Grep", "Glob", "Write");
($ts | lines | map(select((.sid | type) == "string" and (.tokens | type) == "array") | .tokens |= map(tostring))
  | group_by(.sid) | map(last)) as $rows
| ($rows | map({key: .sid, value: .}) | from_entries) as $by
| ($pr | lines | map({key: "\(.sid)@\(.ts)", value: (.text // "" | tostring)}) | from_entries) as $ptext
| [ $rows[] | . as $r
    | [ range(3; 7) as $n | range(0; ($r.tokens | length) - $n + 1) as $s | $r.tokens[$s:$s + $n] | map(.) | select(unique | length >= 2) ]
    | unique[] | {k: join("\u0001"), seq: ., sid: $r.sid, day: ($r.day // "" | tostring)} ]
| group_by(.k)
| map(select(length >= 3) | {k: .[0].k, seq: .[0].seq, sids: (map(.sid) | unique), days: (map(.day) | unique | length)})
| map(select((.sids | length) >= 3 and .days >= 2) | .skey = (.sids | join("\u0002")))
| . as $q
| map(. as $s | select(any($q[]; .skey == $s.skey and (.seq | length) > ($s.seq | length)
      and (("\u0001" + .k + "\u0001") | contains("\u0001" + $s.k + "\u0001"))) | not))
| map(select(all(.seq[]; isre) | not))
| map(select(any(.seq[]; startswith("Skill:") and (.[6:] as $x | $names[$x] or $names[$x | split(":") | last])) | not))
| map(. as $c
    | [ $c.sids[] | $by[.] as $r | pos($r.tokens; $c.seq) as $p
        | ([ ($r.prompts // [])[] | select(type == "object" and (.i | type) == "number" and .i <= $p) ] | last) as $pp
        | {sid: $r.sid, day: ($r.day // "" | tostring), cwd: ($r.cwd // "" | tostring),
           quote: (if $pp then ($ptext["\($r.sid)@\($pp.ts)"] // "") else "" end)} ]
    | sort_by(.day, .sid) | reverse
    | {sequence: $c.seq, sessions: ($c.sids | length), days: $c.days, length: ($c.seq | length),
       score: (($c.sids | length) * ($c.seq | length)), folders: (map(.cwd) | unique),
       prompts: (reduce (.[] | .quote[0:300] | select(test("\\S"))) as $t ([]; if any(.[]; . == $t) then . else . + [$t] end) | .[0:3]),
       evidence: .[0:$evn]})
| sort_by(-.score, -.days, (.sequence | join(" > ")))
| {scanned: ($rows | length), candidates: .}'
RES=$(jq -n -c --rawfile ts "$TS_FILE" --rawfile pr "$PR_FILE" --argjson names "$NAMESET" --argjson evn "$EVIDENCE" "$MINE") \
  || { log "the deterministic stage failed"; finish error 1; }
if [ "$DRY" -eq 1 ]; then printf '%s' "$RES" | jq -c '.candidates[]'; exit 0; fi
SCANNED=$(printf '%s' "$RES" | jq '.scanned')
CANDS=$(printf '%s' "$RES" | jq '.candidates | length')
[ "$CANDS" -gt 0 ] || finish nothing-new

MAX=$(learn_setting LEARN_SKILL_MAX); case "$MAX" in ''|*[!0-9]*) MAX=3 ;; esac
[ "$MAX" -gt 0 ] || finish disabled
SNIP=$(learn_setting LEARN_MAX_SNIPPETS); case "$SNIP" in ''|*[!0-9]*) SNIP=200 ;; esac

# ---------- the shortlist: decided fingerprints left out, LEARN_MAX_SNIPPETS prompts at most ----------
decided() { # FP: rejected (rejected.txt or archive), approved, or snoozed until a later day
  if [ -f "$ROOT/rejected.txt" ] && awk -v f="$1" '$1 == f { found = 1 } END { exit !found }' "$ROOT/rejected.txt"; then return 0; fi
  case "$(proposal_status_of_fp "$ROOT" "$1")" in approved*|rejected*|snoozed*) return 0 ;; esac
  return 1
}
SHORT=""; NSHORT=0; SENT=0; TRUNC=0
while IFS=$'\t' read -r nq seq c; do
  [ "$NSHORT" -lt "$SHORTLIST" ] || break
  fp=$(proposal_fingerprint "$seq")
  decided "$fp" && continue
  [ "$nq" -gt 0 ] || nq=1
  if [ $((SENT + nq)) -gt "$SNIP" ]; then TRUNC=1; break; fi
  SENT=$((SENT + nq)); NSHORT=$((NSHORT + 1))
  SHORT+=$(printf '%s' "$c" | jq -c --arg fp "$fp" '. + {fp: $fp}')$'\n'
done < <(printf '%s' "$RES" | jq -r '.candidates[] | "\(.prompts | length)\t\(.sequence | join(" > "))\t\(tojson)"')
if [ "$NSHORT" -eq 0 ]; then
  if [ "$TRUNC" -eq 1 ]; then finish truncated; else finish nothing-new; fi
fi

# ---------- the model pass ----------
[ -f "$TEMPLATE" ] || { log "no prompt template at $TEMPLATE"; finish error 1; }
MODEL=$(learn_setting LEARN_MODEL_DRAFT)
PROMPT=$(
  sed "s/{{MAX}}/$MAX/g" "$TEMPLATE"
  printf '\n## installed_skills\n\n'
  printf '%s' "$INSTALLED" | jq -c '.[]'
  printf '\n## candidates\n\n'
  printf '%s' "$SHORT" | jq -c '{sequence, sessions, days, length, folders, prompts}'
)
PROMPT=$(printf '%s\n' "$PROMPT" | learn_redact)
SHA_FILE=$(proposal_safe_path .work/skills-input.sha) || finish error 1
SHA=$(printf '%s\n%s' "$MODEL" "$PROMPT" | shasum | cut -c1-40)
if [ "$(cat "$SHA_FILE" 2>/dev/null || true)" = "$SHA" ]; then finish nothing-new; fi

rc=0
ANS=$(printf '%s\n' "$PROMPT" | learn_model_call "$MODEL" 2>>"$LOGF") || rc=$?
case "$rc" in
  0) ;;
  5) finish capped ;;
  *) log "the model call failed (exit $rc)"; finish error 1 ;;
esac
if ! printf '%s' "$ANS" | jq -e '(.skills | type) == "array"' >/dev/null 2>&1; then
  log "the answer has no skills array"; finish error 1
fi

# kept answers matched back to the candidates sent, in rank order; a sequence that was not sent is ignored
KEPT=$(printf '%s' "$SHORT" | jq -c --argjson a "$ANS" '
  ($a.skills | map(select(type == "object" and .keep == true and (.sequence | type) == "array")
    | {key: (.sequence | map(tostring) | join("\u0001")), value: .}) | from_entries) as $k
  | (.sequence | join("\u0001")) as $key | select($k[$key]) | . + {draft: $k[$key]}')

is_installed() { [ -n "$1" ] && printf '%s' "$NAMESET" | jq -e --arg n "$1" '.[$n] // false' >/dev/null; }
WERR=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  [ "$PROPS" -lt "$MAX" ] || break
  slug=$(proposal_slug "$(printf '%s' "$line" | jq -r '.draft.slug // .draft.name // "" | tostring')")
  [ -n "$slug" ] || slug=$(proposal_slug "$(printf '%s' "$line" | jq -r '.sequence | join(" ")')")
  name=$(proposal_slug "$(printf '%s' "$line" | jq -r '.draft.name // .draft.slug // "" | tostring')")
  [ -n "$name" ] || name=$slug
  if is_installed "$slug" || is_installed "$name"; then log "dropped $name: an installed skill has that name"; continue; fi
  json=$(printf '%s' "$line" | jq -c --arg name "$name" '
    (.draft.proposal // "" | tostring) as $p
    | {component: "skills", fingerprint: .fp, sessions, days, target: $name,
       proposal: (if ($p | test("\\S")) then $p + "\n\nSteps seen: \(.sequence | join(" > ")) (\(.sessions) sessions on \(.days) days)." else "" end),
       evidence, why_not_covered: (.draft.why_not_covered // "" | tostring)}')
  prc=0
  for suf in "" -2 -3 -4 -5; do
    prc=0
    out=$(printf '%s' "$json" | proposal_write "skill-$slug$suf.md" 2>>"$LOGF") || prc=$?
    [ "$prc" -eq 4 ] || break
  done
  case "$prc:$out" in
    0:written*|0:refreshed*) PROPS=$((PROPS + 1)) ;;
    0:skipped*) ;;
    *) log "proposal_write skill-$slug failed (exit $prc)"; WERR=1 ;;
  esac
done <<<"$KEPT"

# a clean run remembers its input, so the same input next time makes no model call
if [ "$WERR" -eq 0 ]; then { (umask 077; printf '%s\n' "$SHA" >"$SHA_FILE"); } 2>/dev/null || true; fi
if [ "$TRUNC" -eq 1 ]; then finish truncated; else finish ok; fi
