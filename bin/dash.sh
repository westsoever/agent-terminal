#!/usr/bin/env bash
# dash.sh [--speak] [--hours N] [--all]
# Machine-wide view: one line per Claude session on this computer.
# Sources: (1) ~/.agent/sessions/*/meta written by the SessionStart/Stop hooks, (2) transcripts in
# ~/.claude/projects/*/*.jsonl modified recently (covers sessions that predate the hooks), (3) worktrees
# (`git worktree list`) of every repo found, shown when they hold repo state but have no live session,
# plus the optional extra list in ~/.agent-repos. --speak prints a short spoken summary and warns above
# 5 active sessions.
# Env: AGENT_HOME CLAUDE_DIR AGENT_REPOS_FILE DASH_NOW (epoch, tests) DASH_ACTIVE_MINS (30)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

SPEAK=0; HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --speak) SPEAK=1; shift ;;
    --hours) HOURS=${2:?}; shift 2 ;;
    --all) HOURS=720; shift ;;
    -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "dash: unknown argument $1" >&2; exit 64 ;;
  esac
done

NOW=${DASH_NOW:-$(date +%s)}
CUTOFF=$((NOW - HOURS * 3600))
ACTIVE_SECS=$(( ${DASH_ACTIVE_MINS:-30} * 60 ))
REPOS_FILE=${AGENT_REPOS_FILE:-$HOME/.agent-repos}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-dash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; : >"$ROWS"      # unit-separator (0x1f) separated: updated sid cwd name branch state note source

human_age() { # seconds
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 90 ]; then echo "${s}s"
  elif [ "$s" -lt 5400 ]; then echo "$(( (s + 30) / 60 ))m"
  elif [ "$s" -lt 129600 ]; then echo "$(( (s + 1800) / 3600 ))h"
  else echo "$(( (s + 43200) / 86400 ))d"; fi
}
spoken_age() {
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 90 ]; then echo "just now"
  elif [ "$s" -lt 5400 ]; then echo "$(( (s + 30) / 60 )) minutes ago"
  else echo "$(( (s + 1800) / 3600 )) hours ago"; fi
}
display_name() { name_for "$1" "$2"; }
first_blocker() { # STATE.md -> first bullet under "## Blocked" that is not "(none)"
  [ -f "$1" ] || return 0
  awk '
    /^## Blocked/ { b = 1; next }
    /^## / { b = 0 }
    b && /^[[:space:]]*[-*][[:space:]]/ {
      l = $0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", l)
      if (tolower(l) !~ /^\(?none\)?\.?$/ && l != "") { print l; exit }
    }' "$1"
}

# ---- 1. registry ----
if [ -d "$AGENT_HOME/sessions" ]; then
  for m in "$AGENT_HOME"/sessions/*/meta; do
    [ -f "$m" ] || continue
    sid=$(basename "$(dirname "$m")")
    upd=$(meta_get "$m" updated); [ -n "$upd" ] || upd=$(file_mtime "$m")
    state=$(meta_get "$m" state); [ -n "$state" ] || state=unknown
    cwd=$(meta_get "$m" cwd); root=$(meta_get "$m" root)
    tr_path=$(meta_get "$m" transcript)
    if [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
      tm=$(file_mtime "$tr_path"); [ "$tm" -le "$upd" ] || upd=$tm
    fi
    [ "$upd" -ge "$CUTOFF" ] || continue
    [ "$state" != ended ] || continue
    # blockers / notes come from the session's own STATE.md (repo state when the repo opted in)
    sdir="$AGENT_HOME/sessions/$sid"
    if [ -n "$root" ] && [ -f "$root/.agent/GOAL.md" ]; then sdir="$root/.agent"; fi
    note=$(first_blocker "$sdir/STATE.md")
    [ -z "$note" ] || [ "$state" = blocked ] || [ "$state" = input ] || state=blocked
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$upd" "$sid" "${cwd:-?}" "$(display_name "${cwd:-?}" "$root")" \
      "$(meta_get "$m" branch)" "$state" "$note" registry >>"$ROWS"
  done
fi

# ---- 2. transcripts (sessions not in the registry) ----
seen=$(cut -d$'\037' -f2 "$ROWS" | sort -u)
if [ -d "$CLAUDE_DIR/projects" ]; then
  for t in "$CLAUDE_DIR"/projects/*/*.jsonl; do
    [ -f "$t" ] || continue
    tm=$(file_mtime "$t")
    [ "$tm" -ge "$CUTOFF" ] || continue
    sid=$(basename "$t" .jsonl)
    if printf '%s\n' "$seen" | grep -qxF "$sid"; then continue; fi
    cwd=$(grep -m1 -o '"cwd": *"[^"]*"' "$t" 2>/dev/null | head -1 | sed 's/^"cwd": *"//; s/"$//' || true)
    [ -n "$cwd" ] || cwd="?"
    root=""
    if [ -d "$cwd" ]; then root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true); fi
    branch=""
    if [ -d "$cwd" ]; then branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true); fi
    state=idle
    [ $((NOW - tm)) -ge 120 ] || state=working
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$tm" "$sid" "$cwd" "$(display_name "$cwd" "$root")" "$branch" "$state" "" transcript >>"$ROWS"
  done
fi

# ---- 3. worktrees of every repo found (+ ~/.agent-repos) with repo state but no live session ----
{
  cut -d$'\037' -f3 "$ROWS" | while IFS= read -r c; do [ -d "$c" ] && git -C "$c" rev-parse --show-toplevel 2>/dev/null; done || true
  if [ -f "$REPOS_FILE" ]; then
    grep -v '^[[:space:]]*#' "$REPOS_FILE" | sed 's/[[:space:]]*$//' | while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2088
      case "$p" in "~"|"~/"*) p="$HOME${p#"~"}" ;; esac
      [ -d "$p" ] && git -C "$p" rev-parse --show-toplevel 2>/dev/null
    done || true
  fi
} | sort -u >"$TMP/repos"
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -f "$wt/.agent/STATE.md" ] || continue
    wt_phys=$(cd "$wt" && pwd -P)
    if cut -d$'\037' -f3 "$ROWS" | grep -qxF "$wt_phys"; then continue; fi
    upd=$(file_mtime "$wt/.agent/STATE.md")
    [ "$upd" -ge "$CUTOFF" ] || continue
    st=$(sed -n 's/^status:[[:space:]]*//p' "$wt/.agent/STATE.md" | head -1)
    [ -n "$st" ] || st=idle
    note=$(first_blocker "$wt/.agent/STATE.md")
    [ -z "$note" ] || st=blocked
    printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' "$upd" "worktree" "$wt_phys" "$(basename "$wt")" \
      "$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)" "$st" "$note" worktree >>"$ROWS"
  done
done <"$TMP/repos"

sort -rn -t $'\037' -k1,1 "$ROWS" >"$TMP/sorted"

active=0; blocked=0; waiting=0; done_n=0; total=0
while IFS=$'\037' read -r upd sid cwd name branch state note src; do
  total=$((total + 1))
  age=$((NOW - upd))
  case "$state" in
    blocked) blocked=$((blocked + 1)) ;;
    input) waiting=$((waiting + 1)) ;;
    done) done_n=$((done_n + 1)) ;;
  esac
  case "$state" in
    working|blocked|input|unknown) [ "$age" -le "$ACTIVE_SECS" ] && active=$((active + 1)) || true ;;
  esac
done <"$TMP/sorted"

if [ "$SPEAK" -eq 0 ]; then
  if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; exit 0; fi
  while IFS=$'\037' read -r upd sid cwd name branch state note src; do
    label=$name; [ -z "$branch" ] || label="$name [$branch]"
    [ "$src" = worktree ] || label="$label ${sid:0:7}"
    printf '%-34s %-8s %5s  %s%s\n' "$label" "$state" "$(human_age $((NOW - upd)))" "$cwd" "${note:+  -- $note}"
  done <"$TMP/sorted"
  echo "-- $total session(s), $active active"
  if [ "$active" -gt 5 ]; then echo "WARNING: $active active sessions; the plan caps this at about 5. Park some behind their STATE.md."; fi
  exit 0
fi

# ---- spoken summary: short sentences, no paths, no ids ----
if [ "$total" -eq 0 ]; then echo "No Claude sessions in the last $HOURS hours."; exit 0; fi
out="$active active session"; [ "$active" -eq 1 ] || out="${out}s"; out="$out out of $total."
n=0
while IFS=$'\037' read -r upd sid cwd name branch state note src; do
  case "$state" in
    blocked) s="$name is blocked${note:+: $note}." ;;
    input) s="$name needs your input." ;;
    *) continue ;;
  esac
  n=$((n + 1)); [ "$n" -le 3 ] || continue
  out="$out $s"
done <"$TMP/sorted"
[ "$n" -le 3 ] || out="$out And $((n - 3)) more waiting."
if [ "$n" -eq 0 ]; then
  newest=$(head -1 "$TMP/sorted")
  nn=$(printf '%s' "$newest" | cut -d$'\037' -f4); nu=$(printf '%s' "$newest" | cut -d$'\037' -f1); ns=$(printf '%s' "$newest" | cut -d$'\037' -f6)
  out="$out Nothing is blocked. Latest: $nn is $ns, $(spoken_age $((NOW - nu)))."
fi
[ "$done_n" -eq 0 ] || out="$out $done_n finished."
if [ "$active" -gt 5 ]; then out="$out Warning: that is more than five active sessions; consider parking some."; fi
echo "$out"
