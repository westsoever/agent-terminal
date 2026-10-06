#!/usr/bin/env bash
# dash.sh [--speak | --inbox | --next] [--hours N] [--all]
# Machine-wide view: one line per Claude session on this computer.
# Sources: (1) ~/.agent/sessions/*/meta written by the hooks and ching-watch.sh, (2) transcripts in
# ~/.claude/projects/*/*.jsonl modified recently (sessions that predate the hooks), (3) worktrees
# (`git worktree list`) of every repo found, shown when they hold repo state but have no live session,
# plus the optional extra list in ~/.agent-repos.
#   (default)  name, state, age, ctx (● healthy ◐ watch ○ handoff ? unknown), tokens today, folder, note
#   --speak    short spoken summary that leads with how many need you; warns above 5 active sessions
#   --inbox    NEEDS YOU (blocked/input), READY (release gate passed, waiting for --approve),
#              FINISHED (done since the last --inbox)
#   --next     top 5 by urgency x importance x recency, each with its checkpoint next_action
# Notes come from the STATE.md checkpoint `blocker:` (unless none), else the first "## Blocked" bullet.
# Env: AGENT_HOME CLAUDE_DIR AGENT_REPOS_FILE DASH_NOW (epoch, tests) DASH_ACTIVE_MINS (30)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

MODE=table; HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --speak) MODE=speak; shift ;;
    --inbox) MODE=inbox; shift ;;
    --next) MODE=next; shift ;;
    --hours) HOURS=${2:?}; shift 2 ;;
    --all) HOURS=720; shift ;;
    -h|--help) sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "dash: unknown argument $1" >&2; exit 64 ;;
  esac
done

NOW=${DASH_NOW:-$(date +%s)}
CUTOFF=$((NOW - HOURS * 3600))
ACTIVE_SECS=$(( ${DASH_ACTIVE_MINS:-30} * 60 ))
REPOS_FILE=${AGENT_REPOS_FILE:-$HOME/.agent-repos}
TOKDAY="$AGENT_HOME/tokens/$(date -u -r "$NOW" +%Y-%m-%d)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-dash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; : >"$ROWS"
# fields (0x1f separated): updated sid cwd name branch state note src ctx tok stalled imp next_action
row() { local IFS=$'\037'; printf '%s\n' "$*" >>"$ROWS"; }

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
is_none() { # true for an empty value or a "nothing here" sentinel: none, (none), none. (any case)
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in ''|none|'(none)'|none.) return 0 ;; esac
  return 1
}
state_note() { # STATE.md -> checkpoint blocker unless none; without a checkpoint block, the first bullet
  [ -f "$1" ] || return 0
  if grep -qF '<!-- ching:checkpoint -->' "$1"; then
    local b; b=$(checkpoint_get "$1" blocker)
    if is_none "$b"; then return 0; fi
    printf '%s\n' "$b"
  else
    first_blocker "$1"
  fi
}
next_of() { # STATE.md -> checkpoint next_action unless empty or a sentinel (the template ships "(none)")
  local a; a=$(checkpoint_get "$1" next_action)
  if is_none "$a"; then return 0; fi
  printf '%s\n' "$a"
}
importance() { if [ -n "$1" ] && [ -f "$1/.agent/GOAL.md" ]; then echo 3; else echo 1; fi; }
tok_for() { [ -f "$TOKDAY" ] || return 0; awk -v s="$1" '$1 == s { print $2; exit }' "$TOKDAY"; }
tok_h() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1000000) printf "%.1fM", n / 1000000; else if (n >= 1000) printf "%dk", n / 1000; else if (n > 0) printf "%d", n; else printf "-" }'; }
ctx_sym() { case "$1" in healthy) printf '●' ;; watch) printf '◐' ;; handoff) printf '○' ;; *) printf '?' ;; esac; }

# meta_load FILE: every key the registry needs, read in ONE pass with builtins only (no fork per key and
# none per file). Sets M_updated M_state M_cwd M_root M_transcript M_branch M_ctx M_stalled. Same result
# as meta_get: the first line of a key wins, a missing key is empty, a last line without a newline counts.
meta_load() {
  local line k seen=" "
  M_updated=""; M_state=""; M_cwd=""; M_root=""; M_transcript=""; M_branch=""; M_ctx=""; M_stalled=""
  [ -r "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    k=${line%%=*}
    case "$k" in
      updated|state|cwd|root|transcript|branch|ctx_level|stalled_at) ;;
      *) continue ;;
    esac
    case "$line" in *=*) ;; *) continue ;; esac
    case "$seen" in *" $k "*) continue ;; esac
    seen="$seen$k "
    case "$k" in
      updated) M_updated=${line#*=} ;;
      state) M_state=${line#*=} ;;
      cwd) M_cwd=${line#*=} ;;
      root) M_root=${line#*=} ;;
      transcript) M_transcript=${line#*=} ;;
      branch) M_branch=${line#*=} ;;
      ctx_level) M_ctx=${line#*=} ;;
      stalled_at) M_stalled=${line#*=} ;;
    esac
  done <"$1"
  return 0
}

# ---- 1. registry ----
# A machine collects thousands of ended session metas (one runaway loop made 4,655 in a day), so this loop
# must cost nothing for them: ended sessions are never listed, whatever their age, and are dropped right
# after the single meta_load pass, before any stat or fork. Any other session is still judged on
# max(updated, transcript mtime), so an old meta with a fresh transcript stays listed.
if [ -d "$AGENT_HOME/sessions" ]; then
  for m in "$AGENT_HOME"/sessions/*/meta; do
    [ -f "$m" ] || continue
    meta_load "$m"
    [ "$M_state" != ended ] || continue
    sd=${m%/meta}; sid=${sd##*/}
    upd=$M_updated; [ -n "$upd" ] || upd=$(file_mtime "$m")
    state=$M_state; [ -n "$state" ] || state=unknown
    cwd=$M_cwd; root=$M_root
    tr_path=$M_transcript
    if [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
      tm=$(file_mtime "$tr_path"); [ "$tm" -le "$upd" ] || upd=$tm
    fi
    [ "$upd" -ge "$CUTOFF" ] || continue
    sdir="$AGENT_HOME/sessions/$sid"
    if [ -n "$root" ] && [ -f "$root/.agent/GOAL.md" ]; then sdir="$root/.agent"; fi
    note=$(state_note "$sdir/STATE.md")
    [ -z "$note" ] || [ "$state" = blocked ] || [ "$state" = input ] || state=blocked
    row "$upd" "$sid" "${cwd:-?}" "$(display_name "${cwd:-?}" "$root")" "$M_branch" "$state" "$note" registry \
      "$M_ctx" "$(tok_for "$sid")" "$M_stalled" "$(importance "$root")" \
      "$(next_of "$sdir/STATE.md")"
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
    root=""; branch=""
    if [ -d "$cwd" ]; then
      root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
      branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
    fi
    state=idle
    [ $((NOW - tm)) -ge 120 ] || state=working
    row "$tm" "$sid" "$cwd" "$(display_name "$cwd" "$root")" "$branch" "$state" "" transcript "" "" "" "$(importance "$root")" ""
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
    note=$(state_note "$wt/.agent/STATE.md")
    [ -z "$note" ] || st=blocked
    row "$upd" "worktree" "$wt_phys" "$(basename "$wt")" "$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)" \
      "$st" "$note" worktree "" "" "" "$(importance "$wt_phys")" "$(next_of "$wt/.agent/STATE.md")"
  done
done <"$TMP/repos"

sort -rn -t $'\037' -k1,1 "$ROWS" >"$TMP/sorted"

active=0; blocked=0; waiting=0; done_n=0; total=0
while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
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

label_of() { if [ -n "$2" ]; then printf '%s [%s]' "$1" "$2"; else printf '%s' "$1"; fi; }
ready_for_head() { # repo root -> 0 when .agent/release-ready names the repo's current HEAD (sha=); the signature is --approve's job
  local f="$1/.agent/release-ready" got want
  [ -f "$f" ] || return 1
  got=$(awk -F= '$1 == "sha" { print $2; exit }' "$f")
  [ -n "$got" ] || return 1
  want=$(git -C "$1" rev-parse HEAD 2>/dev/null) || return 1
  [ "$got" = "$want" ]
}

case "$MODE" in
  table)
    if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; exit 0; fi
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      label=$(label_of "$name" "$branch")
      [ "$src" = worktree ] || label="$label ${sid:0:7}"
      printf '%-34s %-8s %5s %s %6s  %s%s\n' "$label" "$state" "$(human_age $((NOW - upd)))" "$(ctx_sym "$ctx")" "$(tok_h "$tok")" \
        "$cwd" "${note:+  -- $note}"
    done <"$TMP/sorted"
    echo "-- $total session(s), $active active"
    if [ "$active" -gt 5 ]; then echo "WARNING: $active active sessions; the plan caps this at about 5. Park some behind their STATE.md."; fi
    exit 0 ;;

  inbox)
    SEEN_F="$AGENT_HOME/inbox.seen"
    last_seen=$(cat "$SEEN_F" 2>/dev/null || echo 0); case "$last_seen" in ''|*[!0-9]*) last_seen=0 ;; esac
    : >"$TMP/needs"; : >"$TMP/ready"; : >"$TMP/fin"
    # lane files hold  key US line US short-id  in newest-first order (sorted is newest first).
    # The key is the session id (a worktree-only row has no session, so its folder), or the repo for READY.
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      label=$(label_of "$name" "$branch")
      key=$sid; sid7=${sid:0:7}; if [ "$src" = worktree ]; then key="worktree:$cwd"; sid7=""; fi
      case "$state" in
        blocked) printf '%s\037  %s: blocked%s\037%s\n' "$key" "$label" "${note:+ -- $note}" "$sid7" >>"$TMP/needs" ;;
        input) printf '%s\037  %s: needs your input\037%s\n' "$key" "$label" "$sid7" >>"$TMP/needs" ;;
        done) [ "$upd" -le "$last_seen" ] || printf '%s\037  %s%s\037%s\n' "$key" "$label" "${nexta:+ -- next: $nexta}" "$sid7" >>"$TMP/fin" ;;
      esac
      r=""; if [ -d "$cwd" ]; then r=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true); fi
      if [ -n "$r" ] && ready_for_head "$r"; then
        printf '%s\037  %s: release gate passed; run release-gate.sh --approve in %s\037\n' "$r" "$(basename "$r")" "$r" >>"$TMP/ready"
      fi
    done <"$TMP/sorted"
    # One line per key, first (newest) occurrence wins. Identical lines from different sessions get the short
    # session id, so two sessions with the same label and note stay two visible entries.
    lane() {
      echo "$1"
      if [ -s "$2" ]; then
        awk -F'\037' '
          !seen[$1]++ { n++; line[n] = $2; id[n] = $3; cnt[$2]++ }
          END { for (i = 1; i <= n; i++) print line[i] (cnt[line[i]] > 1 && id[i] != "" ? " (" id[i] ")" : "") }' "$2"
      else
        echo "  (nothing)"
      fi
    }
    lane "NEEDS YOU" "$TMP/needs"
    lane "READY" "$TMP/ready"
    lane "FINISHED (since last look)" "$TMP/fin"
    mkdir -p "$AGENT_HOME"
    printf '%s\n' "$NOW" >"$SEEN_F"
    exit 0 ;;

  next)
    if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; exit 0; fi
    # score = urgency x importance x recency. Recency is clamped to [floor, 1]: a future-dated row (clock skew)
    # is no fresher than now. A working session loses recency over a day (floor 0.2). A blocked or waiting
    # session is no less urgent for waiting, so it loses at most 10% (floor 0.9); 10 x 0.9 and 9 x 0.9 stay
    # above the best working score (stalled, 8), so blocked and input outrank working sessions of equal or
    # lower importance however long they have waited. Equal scores list the newest first.
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      w=0
      case "$state" in
        blocked) u=10; w=1 ;;
        input) u=9; w=1 ;;
        *) if [ -n "$stalled" ]; then u=8; elif [ "$ctx" = handoff ]; then u=7; elif [ "$state" = working ]; then u=4; else u=2; fi ;;
      esac
      printf '%s\037%s\037%s\037%s\037%s\037%s\n' "$u" "${imp:-1}" $((NOW - upd)) "$w" "$(label_of "$name" "$branch") ($state)" "${nexta:-$note}"
    done <"$TMP/sorted" \
      | awk -F'\037' '{
          d = ($3 / 3600) / 24
          if ($4 == 1) { r = 1 - d / 10; lo = 0.9 } else { r = 1 - d; lo = 0.2 }
          if (r < lo) r = lo
          if (r > 1) r = 1
          printf "%.2f\037%d\037%s\037%s\n", $1 * $2 * r, $3, $5, $6 }' \
      | sort -t $'\037' -k1,1rn -k2,2n \
      | awk -F'\037' 'NR <= 5 { printf "%d. %s  [score %s]%s\n", NR, $3, $1, ($4 != "" ? "  -- " $4 : "") }'
    exit 0 ;;
esac

# ---- spoken summary: short sentences, no paths, no ids ----
if [ "$total" -eq 0 ]; then echo "No Claude sessions in the last $HOURS hours."; exit 0; fi
need=$((blocked + waiting)); out=""
if [ "$need" -eq 1 ]; then out="1 needs you. "; elif [ "$need" -gt 1 ]; then out="$need need you. "; fi
out="$out$active active session"; [ "$active" -eq 1 ] || out="${out}s"; out="$out out of $total."
n=0
while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
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
