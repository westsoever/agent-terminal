#!/usr/bin/env bash
# learn-corrections.sh [--stage1 | --classify]   the correction detector (Phase 6 spec 5.2; interfaces in
# docs/learn-contracts.md): owner corrections that repeat become rule proposals, $AGENT_HOME/proposals/rule-*.md.
#
#   learn-corrections.sh             one run (the nightly job calls this; steps below)
#   learn-corrections.sh --stage1    a filter: JSON lines on stdin ({text, after_interrupt, ...}) come out compact
#                                    with "stage1_hits": [cue names] added (empty when no cue hits). No model, no files.
#   learn-corrections.sh --classify  JSON lines on stdin ({id, text, prev_assistant_tail, after_interrupt}) -> the
#                                    classifier's {"labels":[...]} answer, from one LEARN_MODEL_CLASSIFY call.
#   learn-eval.sh uses the last two, so the evaluation measures the code that runs at night. A run:
#  1. New prompts: lines of .work/prompts.jsonl (learn-extract.sh) whose sid@ts is not yet in the label cache
#     .work/corrections-labels.jsonl. None: learn_run{outcome: nothing-new} and no model call.
#  2. Stage 1 (deterministic): the cues in S1_JQ over the whole prompt, plus every prompt that follows an
#     interrupt. A prompt with no hit is cached with label "-".
#  3. Stage 2: the hits, oldest first (by ts), at most LEARN_MAX_SNIPPETS (and, when lib.sh has learn_budget_left,
#     about tokens-left/450, at least 5), go to one learn_model_call with LEARN_MODEL_CLASSIFY; the rest wait for
#     the next run (outcome truncated). Each sent prompt is cached as "correction" with a one-line pattern, or
#     "not". Known patterns go along so that a repeat reuses its pattern.
#     A failed or capped call caches nothing for the hits, so the next run sends them again.
#  4. Clusters (deterministic): cached corrections grouped by normalised pattern (lower case, blanks squeezed,
#     trailing period dropped). A cluster counts at 3+ sessions on 2+ local days. Then, per cluster:
#     - fingerprint in rejected.txt, decided in archive/, or snoozed: skipped, no model call;
#     - already an open proposal: its counts and evidence are refreshed through proposal_write, no model call;
#     - found covered by an earlier run against the same rule files: counted as covered, no model call;
#     - otherwise it goes to stage 3.
#  5. Stage 3: one learn_model_call with LEARN_MODEL_DRAFT for the clusters left. It drafts the rule, a unified
#     diff and "why not already covered" against the global rules file and the AGENTS.md of the repos in the
#     evidence. A covered cluster is dropped and counted as covered. A patch that does not apply to the current
#     target (patch --dry-run) is dropped for this run and logged in .work/learn.log.
#  Target (D26): <repo>/AGENTS.md when every evidence cwd is inside that one repo (a worktree counts as its main
#  checkout); otherwise the global ~/.agents/CLAUDE.md. A repo target that is public (named in LEARN_PUBLIC_REPOS,
#  or a github.com remote that `gh repo view` reports PUBLIC) says so in the first sentence of ## proposal.
#  Proposal files are written only by proposal_write. The run ends with one learn_run event (name learn-corrections,
#  cwd .work): {component: corrections, scanned: new prompts, candidates: stage-1 hits sent to stage 2, proposals:
#  new files, outcome: ok|nothing-new|truncated|capped|error, covered: clusters dropped as covered}.
# Env: AGENT_HOME; the LEARN_* settings (learn_setting; LEARN_PUBLIC_REPOS: repo paths or names, blank or comma
#   separated); AGENT_TERMINAL_CLAUDE_BIN (learn_model_call); AGENT_TERMINAL_GLOBAL_RULES (default ~/.agents/CLAUDE.md);
#   AGENT_TERMINAL_GH_BIN (default gh); LEARN_CORRECTIONS_TEMPLATE (default templates/learn-prompts/corrections.md).
# Exit: 0, also when a model call fails or is capped (logged, the event says so); 2 bad usage; 3 unusable root.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
umask 077   # everything under .work (learn.log, the --classify prompt) is private, on every path
TEMPLATE=${LEARN_CORRECTIONS_TEMPLATE:-$SELF_DIR/../templates/learn-prompts/corrections.md}
GLOBAL_RULES=${AGENT_TERMINAL_GLOBAL_RULES:-$HOME/.agents/CLAUDE.md}

# ---------- stage 1: the cues. Lower-cased text, curly apostrophes made straight, the whole prompt. ----------
# Each cue is named so that learn-eval.sh can report hits per cue. Tune against the labelled set:
#   bin/learn-eval.sh            (stage-1 recall and precision, per cue)
S1_JQ=$(cat <<'JQ'
def s1_hits:
  . as $o
  | (($o.text // "") | ascii_downcase | gsub("[‘’]"; "'")) as $t
  | def cue($name; $re): $name | select($t | test($re));
    [ cue("no_start"; "^[\\s\"'(]*(no|nope|nah)\\b(?!\\s+(worries|problem|rush|need)\\b)"),
      cue("dont"; "\\b(don'?t|do not|didn'?t|did not)\\b"),
      cue("stop"; "\\bstop(ped|ping)?\\b"),
      cue("actually"; "\\bactually\\b"),
      cue("instead"; ", not\\b|\\binstead\\b|\\brather than\\b"),
      cue("still"; "\\bstill\\b"),
      cue("should"; "\\b(should|shouldn'?t)\\b"),
      cue("again"; "\\b(again|i told you|i said|as i said|like i said|i already (said|told|asked)|i asked you|you keep)\\b"),
      cue("why_you"; "\\bwhy (did|do|would|are) you\\b|\\bwhy did it\\b"),
      cue("yourself"; "\\byourself\\b"),
      cue("do_it"; "\\bfor me\\b|\\bfrom here\\b|why do i (have|need) to|you should be able to|don'?t ask|without asking|you (can|could) do (it|this|that)|you have (the|access)|can'?t you|\\bjust (use|do|run|apply|go ahead)\\b"),
      cue("prev_session"; "\\b(previous|last|other|earlier|another|old|prior) (session|chat|conversation|thread)s?\\b"),
      ("merge_main" | select(($t | test("\\bmerg(e|es|ed|ing)\\b")) and ($t | test("\\b(main|master)\\b")))),
      cue("lost"; "\\b(lost|lose|losing|loses)\\b"),
      cue("wrong"; "\\b(wrong|mistake|not what i)\\b"),
      ("after_interrupt" | select($o.after_interrupt == true)) ];
JQ
)

stage1() { jq -c -R "$S1_JQ"' fromjson? // empty | . + {stage1_hits: s1_hits}'; }

# norm_pattern: the clustering key (stdin text -> stdout)
NORM_JQ='ascii_downcase | gsub("\\s+"; " ") | sub("^ "; "") | sub(" $"; "") | sub("[.]+$"; "")'

# fill_template TASK NAME=FILE...: the template section for TASK, from its "ching-learn-task:" line on, with
# each line that is exactly {{NAME}} replaced by the content of FILE (an empty file gives "(none)").
fill_template() {
  local task=$1; shift
  [ -f "$TEMPLATE" ] || { echo "learn-corrections: no template at $TEMPLATE" >&2; return 1; }
  awk -v task="$task" -v pairs="$*" '
    BEGIN { n = split(pairs, p, " "); for (i = 1; i <= n; i++) { k = p[i]; sub(/=.*/, "", k); v = p[i]; sub(/^[^=]*=/, "", v); f["{{" k "}}"] = v } }
    /^<!-- template: / { on = ($0 == "<!-- template: " task " -->"); started = 0; next }
    on && !started && /^ching-learn-task:/ { started = 1 }
    !started { next }
    ($0 in f) { got = 0; while ((getline line < f[$0]) > 0) { print line; got = 1 }; close(f[$0]); if (!got) print "(none)"; next }
    { print }
  ' "$TEMPLATE"
}

# classify SNIPPETS_FILE KNOWN_FILE OUT_FILE: one stage-2 call. Exit as learn_model_call.
classify() {
  local prompt rc=0
  prompt=$(proposal_safe_path .work/corrections-classify.prompt) || return 3
  fill_template corrections-classify "KNOWN_PATTERNS=$2" "SNIPPETS=$1" >"$prompt" || return 1
  learn_model_call "$(learn_setting LEARN_MODEL_CLASSIFY)" <"$prompt" >"$3" || rc=$?
  return "$rc"
}

case "${1:-}" in
  --stage1) stage1; exit 0 ;;
  --classify)
    in=$(proposal_safe_path .work/eval-classify.in) || exit 3
    known=$(proposal_safe_path .work/eval-classify.known) || exit 3
    out=$(proposal_safe_path .work/eval-classify.out) || exit 3
    (umask 077; jq -c -R 'fromjson? // empty | {id, text, prev_assistant_tail: (.prev_assistant_tail // ""), after_interrupt: (.after_interrupt // false)}' >"$in"; : >"$known")
    rc=0; classify "$in" "$known" "$out" || rc=$?
    [ "$rc" -eq 0 ] && cat "$out"
    rm -f "$in" "$known" "$out"
    exit "$rc" ;;
  "") ;;
  *) echo "usage: learn-corrections.sh [--stage1 | --classify]" >&2; exit 2 ;;
esac

# ---------- the run ----------
ROOT=$(proposals_root) || exit 3
WORKF() { proposal_safe_path ".work/$1"; }
PROMPTS=$(WORKF prompts.jsonl) || exit 3
CACHE=$(WORKF corrections-labels.jsonl) || exit 3
COVERED=$(WORKF corrections-covered.txt) || exit 3
LOG=$(WORKF learn.log) || exit 3
TMPD=$(WORKF corrections-tmp/.keep) || exit 3; TMPD=${TMPD%/*}
rm -rf "$TMPD"; mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
# ev() reads these: the learner's events carry its own .work as cwd (learn_event_ok keeps learn_run anyway)
SID=""; NAME=learn-corrections; CWD=$(learn_work_dir)

SCANNED=0 CANDIDATES=0 PROPOSALS=0 COVERED_N=0 OUTCOME=ok
log() { printf '%s corrections: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG" 2>/dev/null || true; }
finish() {
  ev learn_run "$(jq -nc --argjson s "$SCANNED" --argjson c "$CANDIDATES" --argjson p "$PROPOSALS" \
      --arg o "$OUTCOME" --argjson v "$COVERED_N" \
      '{component: "corrections", scanned: $s, candidates: $c, proposals: $p, outcome: $o, covered: $v}')"
  exit 0
}
# the outcome that says most: error and capped beat truncated, truncated beats ok
set_outcome() {
  case "$OUTCOME:$1" in
    error:*|capped:truncated|capped:ok|truncated:ok) ;;
    *) OUTCOME=$1 ;;
  esac
}
model_failed() { # rc stage
  if [ "$1" -eq 5 ]; then set_outcome capped; log "$2 capped (LEARN_TOKEN_CAP)"; else set_outcome error; log "$2 failed (exit $1)"; fi
}

# 1. new prompts
touch "$CACHE"
jq -r '.id' "$CACHE" 2>/dev/null >"$TMPD/seen" || : >"$TMPD/seen"
if [ -f "$PROMPTS" ]; then
  jq -n -R -c --rawfile seen "$TMPD/seen" '
    (reduce ($seen | split("\n")[] | select(. != "")) as $i ({}; .[$i] = true)) as $s
    | inputs | fromjson? // empty | select(type == "object" and (.sid | type) == "string" and (.ts | type) == "string")
    | ("\(.sid)@\(.ts)") as $id | select($s[$id] | not)
    | {id: $id, sid, ts, cwd: (.cwd // ""), text: (.text // ""), prev_assistant_tail: (.prev_assistant_tail // ""),
       after_interrupt: (.after_interrupt == true),
       day: (try (.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 | strflocaltime("%Y-%m-%d")) catch .ts[0:10])}
  ' "$PROMPTS" >"$TMPD/new"
else
  : >"$TMPD/new"
fi
SCANNED=$(grep -c . "$TMPD/new" || true)
if [ "$SCANNED" -eq 0 ]; then OUTCOME=nothing-new; finish; fi

# 2. stage 1
stage1 <"$TMPD/new" >"$TMPD/s1"
jq -c 'select(.stage1_hits == []) | {id, label: "-"}' "$TMPD/s1" >>"$CACHE"
# oldest first: prompts.jsonl is in transcript order, not time order
jq -s -c 'map(select(.stage1_hits != []))
  | sort_by((.ts | try (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch 0),
            (.ts | try ((capture("(?<f>\\.[0-9]+)Z$").f // "0") | tonumber) catch 0), .id)[]' "$TMPD/s1" >"$TMPD/hits"
max=$(learn_setting LEARN_MAX_SNIPPETS); case "$max" in ''|*[!0-9]*|0) max=200 ;; esac
# the daily budget, when lib.sh has the helpers: the call's fixed cost (template + overhead, plus a 500-token margin
# for the known-pattern list) comes off first, then about 450 tokens per snippet. No room for one snippet: capped,
# no call (learn_model_call would refuse it anyway).
BUDGET_CAPPED=0
if declare -F learn_budget_left >/dev/null && declare -F learn_estimate_tokens >/dev/null; then
  left=$(learn_budget_left 2>/dev/null || true)
  base=$(learn_estimate_tokens <"$TEMPLATE" 2>/dev/null || true)
  case "$left$base" in
    ''|*[!0-9]*) ;;
    *) fit=$(( (left - base - 500) / 450 ))
       if [ "$fit" -lt 1 ]; then
         log "budget: $left tokens left today, a classify call needs at least $((base + 500 + 450)); skipped"
         BUDGET_CAPPED=1; max=0
       elif [ "$fit" -lt "$max" ] && [ "$(grep -c . "$TMPD/hits" || true)" -gt "$fit" ]; then
         log "budget: $left tokens left today; classify batch cut to $fit"; max=$fit
       fi ;;
  esac
fi
if [ "$BUDGET_CAPPED" -eq 1 ]; then set_outcome capped
elif [ "$(grep -c . "$TMPD/hits" || true)" -gt "$max" ]; then set_outcome truncated; fi
if [ "$max" -gt 0 ]; then head -n "$max" "$TMPD/hits" >"$TMPD/send"; else : >"$TMPD/send"; fi  # BSD head rejects -n 0
CANDIDATES=$(grep -c . "$TMPD/send" || true)

# 3. stage 2
if [ "$CANDIDATES" -gt 0 ]; then
  jq -c '{id, text, prev_assistant_tail, after_interrupt}' "$TMPD/send" >"$TMPD/snippets"
  jq -r 'select(.label == "correction") | .pattern' "$CACHE" | sort | uniq -c | sort -rn \
    | awk 'NR <= 200' | sed 's/^ *[0-9]* //' >"$TMPD/known"
  rc=0; classify "$TMPD/snippets" "$TMPD/known" "$TMPD/labels" 2>>"$LOG" || rc=$?
  if [ "$rc" -eq 0 ]; then
    # a sent prompt the answer does not label, or labels without a pattern, is cached as "not"
    jq -c --slurpfile a "$TMPD/labels" '
      ((($a[0].labels // []) | map(select(type == "object" and (.id | type) == "string")) | map({(.id): .}) | add) // {}) as $l
      | ($l[.id] // {}) as $x
      | if $x.label == "correction" and (($x.pattern // "") | type == "string" and test("\\S"))
        then {id, sid, day, cwd, label: "correction", pattern: ($x.pattern | gsub("[\\r\\n\\t]+"; " ")), quote: .text}
        else {id, label: "not"} end
    ' "$TMPD/send" >>"$CACHE"
  else
    model_failed "$rc" classify
  fi
fi

# 4. clusters at 3+ sessions on 2+ days
jq -c -s "
  map(select(.label == \"correction\")) | map(. + {key: (.pattern | $NORM_JQ)})
  | group_by(.key)[]
  | {key: .[0].key, pattern: .[0].pattern, sessions: (map(.sid) | unique | length), days: (map(.day) | unique | length),
     items: (sort_by(.id))}
  | select(.sessions >= 3 and .days >= 2)
" "$CACHE" >"$TMPD/clusters"

# place_of CWD: "repo<TAB><main checkout>" for a cwd inside a git work tree, else "dir<TAB><cwd>"
place_of() {
  local c=$1 common
  if [ -n "$c" ] && [ -d "$c" ] && common=$(git -C "$c" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
     && [ "$(git -C "$c" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]; then
    case "$common" in */.git) printf 'repo\t%s\n' "${common%/.git}"; return ;; esac
  fi
  printf 'dir\t%s\n' "${c:--}"
}
# tilde PATH: $HOME/x shown as ~/x
# shellcheck disable=SC2088 # a literal ~ in the text shown to the owner and the model
tilde() { case "$1" in "$HOME") printf '~' ;; "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }
# public_note REPO: the first sentence of a proposal whose target repo is public, or nothing
public_note() {
  local repo=$1 name=${1##*/} e url slug vis gh=${AGENT_TERMINAL_GH_BIN:-gh}
  for e in $(learn_setting LEARN_PUBLIC_REPOS | tr ',' ' '); do
    if [ "$e" = "$repo" ] || [ "$e" = "$name" ]; then
      printf 'The target repo %s is public (LEARN_PUBLIC_REPOS), so approving this publishes the rule.' "$name"; return
    fi
  done
  command -v "$gh" >/dev/null 2>&1 || return 0
  git -C "$repo" remote -v 2>/dev/null | awk '{print $2}' | sort -u | while IFS= read -r url; do
    slug=$(printf '%s' "$url" | sed -n 's#^.*github\.com[:/]\([^/]*/[^/]*\)$#\1#p' | sed 's/\.git$//')
    [ -n "$slug" ] || continue
    vis=$(_learn_limited 20 "$gh" repo view "$slug" --json visibility --jq .visibility 2>/dev/null </dev/null || true)
    if [ "$vis" = PUBLIC ]; then
      printf 'The target repo %s has a public remote (github.com/%s), so approving this publishes the rule.' "$name" "$slug"; break
    fi
  done
}
# patch_applies TARGET_FILE PATCH_FILE: true when the diff applies cleanly (-p1) to a copy of TARGET_FILE
patch_applies() {
  local d="$TMPD/patchcheck"
  rm -rf "$d"; mkdir -p "$d"
  [ ! -f "$1" ] || cp "$1" "$d/${1##*/}"
  patch -p1 -s -t -N --dry-run -d "$d" <"$2" >/dev/null 2>&1
}

: >"$TMPD/pending"
while IFS= read -r cl; do
  [ -n "$cl" ] || continue
  key=$(printf '%s' "$cl" | jq -r .key)
  fp=$(proposal_fingerprint "$key")
  if [ -f "$ROOT/rejected.txt" ] && awk -v f="$fp" '$1 == f { found = 1 } END { exit !found }' "$ROOT/rejected.txt"; then
    log "skipped rejected $fp"; continue
  fi
  st=$(proposal_status_of_fp "$ROOT" "$fp")
  # the evidence: one quote per session first, newest sessions first, at most 6
  ev_json=$(printf '%s' "$cl" | jq -c '.items | group_by(.sid) | map(max_by(.id)) | sort_by(.day) | reverse | .[0:6]
    | map({sid, day, cwd, quote})')
  sessions=$(printf '%s' "$cl" | jq -r .sessions); days=$(printf '%s' "$cl" | jq -r .days)
  case "$st" in
    approved*|rejected*|snoozed*) log "skipped ${st%% *} $fp"; continue ;;
    open*)
      f=${st#open }
      out=$(jq -nc --arg fp "$fp" --argjson s "$sessions" --argjson d "$days" --argjson e "$ev_json" \
          --arg t "$(proposal_get "$f" target)" --arg p "$(proposal_section "$f" proposal)" \
          --arg patch "$(proposal_patch "$f")" --arg w "$(proposal_section "$f" 'why this is not already covered')" \
          '{component: "corrections", kind: "rule", fingerprint: $fp, sessions: $s, days: $d, target: $t, proposal: $p,
            evidence: $e, patch: $patch, why_not_covered: $w}' | proposal_write "$f" 2>>"$LOG") || log "refresh of $f failed"
      log "$out"; continue ;;
  esac
  # the target: one repo, or global
  places=$(printf '%s' "$cl" | jq -r '.items[].cwd' | sort -u | while IFS= read -r c; do place_of "$c"; done | sort -u)
  if [ "$(printf '%s\n' "$places" | grep -c .)" -eq 1 ] && [ "${places%%	*}" = repo ]; then
    repo=${places#*	}; tfile=$repo/AGENTS.md
  else
    repo=""; tfile=$GLOBAL_RULES
  fi
  digest=$(cat "$GLOBAL_RULES" "$tfile" 2>/dev/null | shasum | cut -c1-40)
  if grep -qx "$fp $digest" "$COVERED" 2>/dev/null; then
    COVERED_N=$((COVERED_N + 1)); continue
  fi
  printf '%s' "$cl" | jq -c --arg fp "$fp" --arg tf "$tfile" --arg t "$(tilde "$tfile")" --arg repo "$repo" \
    --arg dg "$digest" --argjson e "$ev_json" --arg places "$places" \
    '{fp: $fp, key, pattern, sessions, days, tfile: $tf, target: $t, repo: $repo, digest: $dg, evidence: $e,
      places: ($places | split("\n") | map(select(. != "") | split("\t")[1]))}' >>"$TMPD/pending"
done <"$TMPD/clusters"

# 5. stage 3
if [ -s "$TMPD/pending" ]; then
  jq -c '{pattern, target, sessions, days, places, quotes: (.evidence | map(.quote) | .[0:5])}' "$TMPD/pending" >"$TMPD/cl-in"
  # the global file and every target (shown as "(missing)" when absent), then the AGENTS.md of each repo seen
  { printf '%s\n' "$GLOBAL_RULES"; jq -r '.tfile' "$TMPD/pending"; jq -r '.places[] | . + "/AGENTS.md"' "$TMPD/pending"; } \
    | awk '!seen[$0]++' >"$TMPD/rulefiles"
  jq -r '.tfile' "$TMPD/pending" >"$TMPD/targets"
  while IFS= read -r f; do
    if [ "$f" != "$GLOBAL_RULES" ] && [ ! -f "$f" ] && ! grep -qxF "$f" "$TMPD/targets"; then continue; fi
    printf '=== %s (patch paths a/%s and b/%s) ===\n' "$(tilde "$f")" "${f##*/}" "${f##*/}"
    if [ -f "$f" ]; then head -c 40000 "$f"; printf '\n'; else printf '(missing)\n'; fi
    printf '=== end of %s ===\n\n' "$(tilde "$f")"
  done <"$TMPD/rulefiles" >"$TMPD/rules"
  fill_template corrections-draft "CLUSTERS=$TMPD/cl-in" "RULES=$TMPD/rules" >"$TMPD/draft.prompt"
  rc=0; learn_model_call "$(learn_setting LEARN_MODEL_DRAFT)" <"$TMPD/draft.prompt" >"$TMPD/draft" 2>>"$LOG" || rc=$?
  if [ "$rc" -ne 0 ]; then
    model_failed "$rc" draft
  else
    while IFS= read -r pc; do
      [ -n "$pc" ] || continue
      key=$(printf '%s' "$pc" | jq -r .key)
      r=$(jq -c --arg k "$key" "first((.rules // [])[] | select(type == \"object\" and ((.pattern // \"\") | tostring | $NORM_JQ) == \$k))" \
          "$TMPD/draft" 2>/dev/null) || r=""
      if [ -z "$r" ]; then log "draft gave no answer for: $key"; continue; fi
      fp=$(printf '%s' "$pc" | jq -r .fp)
      if [ "$(printf '%s' "$r" | jq -r '.covered == true')" = true ]; then
        COVERED_N=$((COVERED_N + 1))
        printf '%s %s\n' "$fp" "$(printf '%s' "$pc" | jq -r .digest)" >>"$COVERED"
        log "covered: $(printf '%s' "$pc" | jq -r .pattern) ($(printf '%s' "$r" | jq -r '.covered_by // "" | .[0:200]'))"
        continue
      fi
      if ! printf '%s' "$r" | jq -e '[.proposal, .patch, .why_not_covered] | all(type == "string" and test("\\S"))' >/dev/null; then
        log "draft for '$key' lacks proposal, patch or why_not_covered"; continue
      fi
      tfile=$(printf '%s' "$pc" | jq -r .tfile)
      printf '%s\n' "$(printf '%s' "$r" | jq -r .patch)" >"$TMPD/patch"
      if ! patch_applies "$tfile" "$TMPD/patch"; then log "draft patch for '$key' does not apply to $tfile; dropped this run"; continue; fi
      repo=$(printf '%s' "$pc" | jq -r .repo)
      note=""; [ -z "$repo" ] || note=$(public_note "$repo")
      slug=$(proposal_slug "$(printf '%s' "$r" | jq -r '.slug // ""')")
      [ -n "$slug" ] || slug=$(proposal_slug "$key")
      slug=$(printf '%s' "$slug" | cut -c1-70 | sed 's/-*$//')
      json=$(jq -nc --argjson pc "$pc" --argjson r "$r" --arg note "$note" '{
        component: "corrections", kind: "rule", fingerprint: $pc.fp, sessions: $pc.sessions, days: $pc.days,
        target: $pc.target, evidence: $pc.evidence, patch: $r.patch, why_not_covered: $r.why_not_covered,
        proposal: (if $note == "" then $r.proposal else $note + " " + $r.proposal end)}')
      for n in "" -2 -3 -4 -5; do
        rc=0; out=$(printf '%s' "$json" | proposal_write "rule-$slug$n.md" 2>>"$LOG") || rc=$?
        [ "$rc" -eq 4 ] || break
      done
      log "${out:-proposal_write failed (exit $rc) for '$key'}"
      case "$out" in written*) PROPOSALS=$((PROPOSALS + 1)) ;; esac
    done <"$TMPD/pending"
  fi
fi
finish
