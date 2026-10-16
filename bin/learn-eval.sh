#!/usr/bin/env bash
# learn-eval.sh [--labels FILE] [--stage2] [--misses]   measure the correction detector against a labelled set
# (Phase 6 spec 10, question 7). READ-ONLY on the labels file.
#
# FILE (default $AGENT_HOME/proposals/.eval/labels.jsonl) holds one JSON object per line with at least
#   {id, text, label: "correction"|"not"} and optionally prev_assistant_tail and after_interrupt. A file without an
#   after_interrupt field may say so in stage1_hits (an "after_interrupt" entry), as the labelling pass wrote it.
# The labelled set holds the owner's own prompts: it lives outside the repo, and nothing here copies it.
#
# Stage 1 (always, no model): runs `learn-corrections.sh --stage1` over every item and prints recall (corrections
#   hit / corrections) and precision (corrections hit / items hit), then hits and corrections per cue, and the
#   corrections only that cue catches. Precision here is over the labelled set only, which is itself made of items
#   some filter flagged, so it is higher than over all prompts.
# --stage2: also sends the stage-1 hits to the classifier for real (`learn-corrections.sh --classify`, in batches of
#   LEARN_MAX_SNIPPETS, through learn_model_call and its token cap) and prints the classifier's precision and
#   recall on what it was sent, and the end-to-end recall (stage 1 and stage 2 together).
# --misses: also lists the corrections stage 1 misses (id and the first 120 characters).
# Exit: 0; 1 a stage-2 call failed; 2 bad usage or an unreadable labels file.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

LABELS=$AGENT_HOME/proposals/.eval/labels.jsonl STAGE2=0 MISSES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --labels) [ $# -ge 2 ] || { echo "learn-eval: --labels needs a file" >&2; exit 2; }; LABELS=$2; shift 2 ;;
    --stage2) STAGE2=1; shift ;;
    --misses) MISSES=1; shift ;;
    *) echo "usage: learn-eval.sh [--labels FILE] [--stage2] [--misses]" >&2; exit 2 ;;
  esac
done
[ -r "$LABELS" ] && [ -f "$LABELS" ] || { echo "learn-eval: cannot read $LABELS" >&2; exit 2; }

TMPD=$(mktemp -d "${TMPDIR:-/tmp}/learn-eval.XXXXXX")
trap 'rm -rf "$TMPD"' EXIT
chmod 700 "$TMPD"

pct() { awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "n/a"; else printf "%.1f%%\n", 100 * a / b }'; }

jq -c -R 'fromjson? // empty | select(type == "object" and (.id | type) == "string" and (.label == "correction" or .label == "not"))
  | {id, label, text: (.text // ""), prev_assistant_tail: (.prev_assistant_tail // ""),
     after_interrupt: (if has("after_interrupt") then .after_interrupt == true
                       else ((.stage1_hits // []) | any(.[]; . == "after_interrupt")) end)}' "$LABELS" \
  | "$SELF_DIR/learn-corrections.sh" --stage1 >"$TMPD/s1"

n=$(grep -c . "$TMPD/s1" || true)
[ "$n" -gt 0 ] || { echo "learn-eval: no labelled items in $LABELS" >&2; exit 2; }
read -r c h tp <<<"$(jq -rs '[length, (map(select(.label == "correction")) | length), (map(select(.stage1_hits != [])) | length),
  (map(select(.label == "correction" and .stage1_hits != [])) | length)] | .[1:] | map(tostring) | join(" ")' "$TMPD/s1")"
echo "labels: $LABELS ($n items, $c corrections)"
echo "stage 1: $h hits; recall $tp/$c = $(pct "$tp" "$c"); precision $tp/$h = $(pct "$tp" "$h")"
echo "per cue (hits, corrections among them, corrections only this cue catches):"
jq -rs '(map(.stage1_hits[]) | unique) as $cues
  | $cues[] as $q
  | [ $q,
      (map(select(.stage1_hits | index($q))) | length),
      (map(select(.label == "correction" and (.stage1_hits | index($q)))) | length),
      (map(select(.label == "correction" and .stage1_hits == [$q])) | length) ]
  | @tsv' "$TMPD/s1" | awk -F'\t' '{ printf "  %-16s %5d %5d %5d\n", $1, $2, $3, $4 }'

if [ "$MISSES" = 1 ]; then
  echo "corrections stage 1 misses:"
  jq -r 'select(.label == "correction" and .stage1_hits == []) | "  \(.id)  \(.text | gsub("[\\r\\n\\t]+"; " ") | .[0:120])"' "$TMPD/s1"
fi

[ "$STAGE2" = 1 ] || exit 0

# ---------- stage 2, for real ----------
max=$(learn_setting LEARN_MAX_SNIPPETS); case "$max" in ''|*[!0-9]*|0) max=200 ;; esac
jq -c 'select(.stage1_hits != [])' "$TMPD/s1" >"$TMPD/hits"
split -l "$max" "$TMPD/hits" "$TMPD/batch."
: >"$TMPD/answers"
for b in "$TMPD"/batch.*; do
  [ -f "$b" ] || continue
  if ! "$SELF_DIR/learn-corrections.sh" --classify <"$b" >"$TMPD/answer"; then
    echo "learn-eval: a classifier call failed; see $(learn_work_dir)/learn.log" >&2; exit 1
  fi
  jq -c '(.labels // [])[] | select(type == "object")' "$TMPD/answer" >>"$TMPD/answers"
done
read -r sent truth pred both all <<<"$(jq -rs --slurpfile a "$TMPD/answers" '
  (($a | map({(.id | tostring): .label}) | add) // {}) as $l
  | (map(select(.label == "correction")) | length) as $all
  | map(select(.stage1_hits != []) | . + {pred: ($l[.id] == "correction")})
  | [length, (map(select(.label == "correction")) | length), (map(select(.pred)) | length),
     (map(select(.pred and .label == "correction")) | length), $all] | map(tostring) | join(" ")' "$TMPD/s1")"
echo "stage 2 ($(learn_setting LEARN_MODEL_CLASSIFY)): $sent sent, $truth of them corrections, $pred labelled correction"
echo "  precision $both/$pred = $(pct "$both" "$pred"); recall $both/$truth = $(pct "$both" "$truth")"
echo "  end to end: recall $both/$all = $(pct "$both" "$all")"
