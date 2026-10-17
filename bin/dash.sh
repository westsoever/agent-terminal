#!/usr/bin/env bash
# dash.sh [--speak | --inbox | --next | --counts | --route] [--hours N] [--all]
# Machine-wide view: one line per Claude session on this computer.
# Sources: (1) ~/.agent/sessions/*/meta written by the hooks and kaching-watch.sh, (2) transcripts in
# ~/.claude/projects/*/*.jsonl modified recently (sessions that predate the hooks), (3) worktrees
# (`git worktree list`) of every repo found, shown when they hold repo state but have no live session,
# plus the optional extra list in ~/.agent-repos.
#   (default)  name, state, age, ctx (● healthy ◐ watch ○ handoff ? unknown), tokens today, folder, note
#   --speak    short spoken summary that leads with how many need you; warns above 5 active sessions; ends with
#              "N proposals waiting." when the learner has any (proposals never send a notification)
#   --inbox    NEEDS YOU (blocked/input), READY (release gate passed for the current HEAD, waiting for --approve),
#              FINISHED (done since the last --inbox), PROPOSALS (the learner's open proposals in $AGENT_HOME/proposals,
#              "kind id: first sentence (sessions/days)", most sessions first; snoozed and decided ones are hidden;
#              decide them with bin/kaching-proposals). --inbox marks FINISHED as seen: it writes the time to
#              $AGENT_HOME/inbox.seen, so the next --inbox does not list those again. One entry per session.
#   --next     top 5 by urgency x importance x recency (blocked and input sessions stay above working ones),
#              each with its checkpoint next_action
#   --counts   machine-readable key=value lines for the menu bar dot (ui/menubar): sessions, active, blocked, input,
#              needs (blocked + input), proposals. Cheap and read-only: the registry only (no transcript scan, no git, so
#              sessions predating the hooks and worktree-only rows are not counted) and it never writes inbox.seen.
#   --route    the voice dispatcher's routing list, for a model to read (no ANSI, no speech): a header line, then one TSV
#              line per LIVE Claude Code session ($CLAUDE_DIR/sessions/*.json, kill -0 pid; the dispatcher and claude-mem
#              observers left out):  name  message_to  status  state  state_dir  notes  focus  branch
#              message_to is the json name (what SendMessage takes); name is "home" for ~; a missing value is "-".
#              Focused first (its tty is in $AGENT_HOME/dispatcher/focus, "<tty> <epoch>", at most DASH_FOCUS_MAX_AGE
#              seconds old), then busy, idle, then by name. Columns and DASH_PS_TTY_CMD: see route_list in this file.
# Git sync (bin/sync-check.sh writes $AGENT_HOME/sync-check.md): the default view ends with one `sync:` line when the
#   snapshot lists repos that need attention, or is older than 24 h; --inbox ends with a SYNC lane, oldest first, that
#   shows the snapshot age ("stale snapshot" over 24 h, "never run" without one). No snapshot: the default view is unchanged.
# Notes come from the STATE.md checkpoint `blocker:` (unless none), else the first "## Blocked" bullet.
# Env: AGENT_HOME CLAUDE_DIR AGENT_REPOS_FILE DASH_NOW (epoch, tests) DASH_ACTIVE_MINS (30) DASH_FOCUS_MAX_AGE (600) DASH_PS_TTY_CMD
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
    --counts) MODE=counts; shift ;;
    --route) MODE=route; shift ;;
    --hours) HOURS=${2:?}; shift 2 ;;
    --all) HOURS=720; shift ;;
    -h|--help) sed -n '2,/^# Env:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "dash: unknown argument $1 (use --speak, --inbox, --next, --counts, --route, --hours N, --all or --help)" >&2; exit 64 ;;
  esac
done

NOW=${DASH_NOW:-$(date +%s)}
CUTOFF=$((NOW - HOURS * 3600))
ACTIVE_SECS=$(( ${DASH_ACTIVE_MINS:-30} * 60 ))
REPOS_FILE=${AGENT_REPOS_FILE:-$HOME/.agent-repos}
TOKDAY="$AGENT_HOME/tokens/$(date -u -r "$NOW" +%Y-%m-%d)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/kaching-dash.XXXXXX")
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

# ---- --route: the dispatcher's routing list. Reads only the Claude Code session files, the metas of those
# sessions and the focus file: none of the registry, transcript or worktree scans below.
#   source     $CLAUDE_DIR/sessions/*.json (one jq over all files; one per file only when a file is unreadable).
#   skipped    dead pids (kill -0), files without a pid, a kind other than interactive, the dispatcher itself (json
#              name "dispatcher" or cwd $AGENT_HOME/dispatcher), claude-mem observer sessions (cwd under
#              /.claude-mem/observer-sessions, as terminal/snapshot.go hidden()).
#   name       the display name used elsewhere (name_for: repo/worktree dir, else the folder), "home" for the home folder
#   message_to the json name: what ListAgents shows and SendMessage takes
#   status     json busy|idle;  state: Kaching's meta state= (working/input/blocked/done/...)
#   state_dir  $AGENT_HOME/sessions/<sid> if it holds STATE.md, else <root>/.agent if that does (root: meta root=,
#              else the git toplevel of cwd), else $AGENT_HOME/sessions/<sid>;  notes: yes when state_dir has STATE.md
#   focus      "focused" for the session whose tty is named in $AGENT_HOME/dispatcher/focus ("<tty> <epoch>", written
#              by KachingBar on the voice shortcut; a /dev/ prefix is fine) while that epoch (else the file's mtime) is
#              at most DASH_FOCUS_MAX_AGE (600) seconds old
#   branch     meta branch=, else `git symbolic-ref --short -q HEAD` in cwd
# A missing value is "-", so no field is ever empty. Sorted focused first, then busy, idle, other, then name and
# message_to. No live session: the header only. The ttys come from ONE `ps -o pid=,tty= -p <pid,pid,...>`;
# DASH_PS_TTY_CMD (tests) replaces it: it is run with the comma-separated pid list as its one argument and prints
# "pid tty" lines. ----
route_list() {
  local sdir="$CLAUDE_DIR/sessions" f files=() raw rc
  local jqf='def v: if . == null then "-" else tostring | if . == "" then "-" else . end end;
    select(type == "object" and (.pid | type) == "number" and .pid > 0)
    | [(.pid | tostring), (.sessionId | v), (.cwd | v), (.name | v), (.status | v), (.kind | v)] | @tsv'
  printf 'name\tmessage_to\tstatus\tstate\tstate_dir\tnotes\tfocus\tbranch\n'
  [ -d "$sdir" ] || return 0
  for f in "$sdir"/*.json; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  # one jq over every file; a file that is not JSON (being rewritten, say) aborts it, so then one jq per file
  rc=0; raw=$(jq -r "$jqf" "${files[@]}" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    raw=$(for f in "${files[@]}"; do jq -r "$jqf" "$f" 2>/dev/null || true; done)
  fi

  local home_l=$HOME home_p disp_l="$AGENT_HOME/dispatcher" disp_p
  home_p=$(cd "$HOME" 2>/dev/null && pwd -P || printf '%s' "$HOME")
  disp_p=$(cd "$disp_l" 2>/dev/null && pwd -P || printf '%s' "$disp_l")
  local pid sid cwd jname jstatus kind live="$TMP/route.live" pids=""
  : >"$live"
  while IFS=$'\t' read -r pid sid cwd jname jstatus kind; do
    [ -n "$pid" ] || continue
    case "$kind" in -|interactive) ;; *) continue ;; esac
    [ "$jname" != dispatcher ] || continue
    if [ "$cwd" = "$disp_l" ] || [ "$cwd" = "$disp_p" ]; then continue; fi
    case "$cwd" in */.claude-mem/observer-sessions|*/.claude-mem/observer-sessions/*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$pid" "$sid" "$cwd" "$jname" "$jstatus" >>"$live"
    pids="${pids:+$pids,}$pid"
  done <<<"$raw"
  [ -n "$pids" ] || return 0

  # ttys: one ps call for every pid. TTYS holds " pid=tty " pairs; "??" (no terminal) never matches a focus.
  local TTYS=" " p t
  while read -r p t; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    TTYS="$TTYS$p=${t#/dev/} "
  done < <(if [ -n "${DASH_PS_TTY_CMD:-}" ]; then "$DASH_PS_TTY_CMD" "$pids"; else ps -o pid=,tty= -p "$pids"; fi 2>/dev/null || true)

  # the focus file: "<tty> <epoch>"; fresh when the epoch (else the mtime) is at most DASH_FOCUS_MAX_AGE old and at most 60 s ahead
  local ffile="$AGENT_HOME/dispatcher/focus" ftty="" fep="" fage max=${DASH_FOCUS_MAX_AGE:-600} focus_tty=""
  case "$max" in ''|*[!0-9]*) max=600 ;; esac
  if [ -f "$ffile" ]; then
    read -r ftty fep _ <"$ffile" || true
    ftty=${ftty#/dev/}
    case "$fep" in ''|*[!0-9]*) fep=$(file_mtime "$ffile") ;; esac
    fage=$((NOW - fep))
    if [ "$fage" -le "$max" ] && [ "$fage" -ge -60 ] && [ -n "$ftty" ] && [ "$ftty" != "??" ]; then focus_tty=$ftty; fi
  fi

  # git lookups (only for what the meta lacks), cached per cwd: many sessions share a folder
  local nl=$'\n' us=$'\037' gcache=$'\n' rest g_root g_branch
  local root branch state sd notes focus name tty srank frank
  while IFS=$'\t' read -r pid sid cwd jname jstatus; do
    # the registry dir name, as hook_init derives it from the session id
    case "$sid" in .*|*..*|*[!A-Za-z0-9._-]*) sid="sid-$(printf '%s' "$sid" | shasum | cut -c1-16)" ;; esac
    [ "${#sid}" -le 128 ] || sid="sid-$(printf '%s' "$sid" | shasum | cut -c1-16)"
    sd="$AGENT_HOME/sessions/$sid"
    meta_load "$sd/meta"
    root=$M_root; branch=$M_branch
    if { [ -z "$root" ] || [ -z "$branch" ]; } && [ -d "$cwd" ]; then
      case "$gcache" in
        *"$nl$cwd$us"*)
          rest=${gcache#*"$nl$cwd$us"}; g_root=${rest%%"$us"*}; rest=${rest#*"$us"}; g_branch=${rest%%"$nl"*} ;;
        *)
          g_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
          g_branch=""; [ -z "$g_root" ] || g_branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
          gcache="$gcache$cwd$us$g_root$us$g_branch$nl" ;;
      esac
      [ -n "$root" ] || root=$g_root
      [ -n "$branch" ] || branch=$g_branch
    fi
    if [ "$cwd" = "$home_l" ] || [ "$cwd" = "$home_p" ]; then name=home
    elif [ "$cwd" = "-" ]; then name="-"
    else name=$(name_for "$cwd" "$root"); [ "$name" != "~" ] || name=home; fi
    [ -n "$name" ] || name="-"
    state=${M_state:--}
    if [ -f "$sd/STATE.md" ]; then notes=yes
    elif [ -n "$root" ] && [ -f "$root/.agent/STATE.md" ]; then sd="$root/.agent"; notes=yes
    else notes=no; fi
    tty=""
    case "$TTYS" in *" $pid="*) tty=${TTYS#*" $pid="}; tty=${tty%% *} ;; esac
    focus="-"; frank=1
    if [ -n "$focus_tty" ] && [ "$tty" = "$focus_tty" ]; then focus=focused; frank=0; fi
    case "$jstatus" in busy) srank=0 ;; idle) srank=1 ;; *) srank=2 ;; esac
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$frank" "$srank" "$name" "$jname" "$jstatus" "$state" "$sd" \
      "$notes" "$focus" "${branch:--}"
  done <"$live" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n -k3,3 -k4,4 | cut -f3-
}
if [ "$MODE" = route ]; then route_list; exit 0; fi

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
    # --counts needs only the time and the state: no forks for the name, tokens, importance or next action
    if [ "$MODE" = counts ]; then row "$upd" "$sid" "${cwd:-?}" "" "" "$state" "" registry "" "" "" "" ""; continue; fi
    row "$upd" "$sid" "${cwd:-?}" "$(display_name "${cwd:-?}" "$root")" "$M_branch" "$state" "$note" registry \
      "$M_ctx" "$(tok_for "$sid")" "$M_stalled" "$(importance "$root")" \
      "$(next_of "$sdir/STATE.md")"
  done
fi

# ---- 2. transcripts (sessions not in the registry) ----
# Ids are matched with case, not `printf ids | grep -q`: grep stops at its first hit, a long list makes printf die
# of SIGPIPE, and under pipefail that reads as "not found" (a registered session listed again from its transcript).
nl=$'\n'; seen="$nl$(cut -d$'\037' -f2 "$ROWS")$nl"
if [ "$MODE" != counts ] && [ -d "$CLAUDE_DIR/projects" ]; then
  for t in "$CLAUDE_DIR"/projects/*/*.jsonl; do
    [ -f "$t" ] || continue
    tm=$(file_mtime "$t")
    [ "$tm" -ge "$CUTOFF" ] || continue
    sid=$(basename "$t" .jsonl)
    case "$seen" in *"$nl$sid$nl"*) continue ;; esac
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
: >"$TMP/repos"
[ "$MODE" = counts ] || { {
  cut -d$'\037' -f3 "$ROWS" | while IFS= read -r c; do [ -d "$c" ] && git -C "$c" rev-parse --show-toplevel 2>/dev/null; done || true
  if [ -f "$REPOS_FILE" ]; then
    grep -v '^[[:space:]]*#' "$REPOS_FILE" | sed 's/[[:space:]]*$//' | while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2088
      case "$p" in "~"|"~/"*) p="$HOME${p#"~"}" ;; esac
      [ -d "$p" ] && git -C "$p" rev-parse --show-toplevel 2>/dev/null
    done || true
  fi
} | sort -u >"$TMP/repos"; }
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -f "$wt/.agent/STATE.md" ] || continue
    wt_phys=$(cd "$wt" && pwd -P)
    # awk reads the whole file (a `cut | grep -q` would stop early and die of SIGPIPE on a big column)
    if WT="$wt_phys" awk -F'\037' '$3 == ENVIRON["WT"] { f = 1 } END { exit !f }' "$ROWS"; then continue; fi
    upd=$(file_mtime "$wt/.agent/STATE.md")
    [ "$upd" -ge "$CUTOFF" ] || continue
    st=$(sed -n '/^status:/{s/^status:[[:space:]]*//;p;q;}' "$wt/.agent/STATE.md")
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

# ---- git sync snapshot (bin/sync-check.sh): read in one awk pass, and only by the default view and --inbox ----
SYNC_SNAP="$AGENT_HOME/sync-check.md"
sync_age_fmt() { # hours -> <1h, 5h (up to 47 h), 3d
  local h=$1
  if [ "$h" -lt 1 ]; then echo "<1h"; elif [ "$h" -lt 48 ]; then echo "${h}h"; else echo "$((h / 24))d"; fi
}
# sync_load: SYNC_STATE (none | fresh | stale: older than 24 h), SYNC_AGE_H (snapshot age), SYNC_N (repos needing
# attention), SYNC_OLD_H (their oldest finding when the snapshot was made); rows "name US needs US age_h" go to
# $TMP/sync.rows in the snapshot's own order, which is oldest first.
sync_load() {
  local kind a b c gen="" gen_epoch age
  SYNC_STATE=none; SYNC_N=0; SYNC_OLD_H=0; SYNC_AGE_H=0; : >"$TMP/sync.rows"
  [ -f "$SYNC_SNAP" ] || return 0
  awk '
    /^generated:/ && !g { g = 1; v = $0; sub(/^generated:[ ]*/, "", v); print "G\037" v; next }
    /^## / { name = $0; sub(/^## /, "", name); sub(/ -- oldest .*$/, "", name); needs = ""; next }
    /^needs:/ && name != "" { needs = $0; sub(/^needs:[ ]*/, "", needs); next }
    /^age_h:/ && name != "" { h = $0; sub(/^age_h:[ ]*/, "", h); print "R\037" name "\037" needs "\037" h; name = "" }
  ' "$SYNC_SNAP" >"$TMP/sync.all" 2>/dev/null || true
  while IFS=$'\037' read -r kind a b c; do
    case "$kind" in
      G) gen=$a ;;
      R) case "$c" in ''|*[!0-9]*) c=0 ;; esac
         SYNC_N=$((SYNC_N + 1)); [ "$c" -le "$SYNC_OLD_H" ] || SYNC_OLD_H=$c
         printf '%s\037%s\037%s\n' "$a" "$b" "$c" >>"$TMP/sync.rows" ;;
    esac
  done <"$TMP/sync.all"
  gen_epoch=""
  if [ -n "$gen" ]; then gen_epoch=$(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$gen" +%s 2>/dev/null || true); fi
  case "$gen_epoch" in ''|*[!0-9]*) gen_epoch=$(file_mtime "$SYNC_SNAP") ;; esac
  age=$((NOW - gen_epoch)); [ "$age" -ge 0 ] || age=0
  SYNC_AGE_H=$((age / 3600))
  if [ "$age" -gt 86400 ]; then SYNC_STATE=stale; else SYNC_STATE=fresh; fi
}
sync_what() { # the findings in a few words
  if [ "$SYNC_N" -eq 0 ]; then printf 'clean when last run'
  elif [ "$SYNC_N" -eq 1 ]; then printf '1 repo needs attention (oldest %s)' "$(sync_age_fmt "$SYNC_OLD_H")"
  else printf '%s repos need attention (oldest %s)' "$SYNC_N" "$(sync_age_fmt "$SYNC_OLD_H")"; fi
}
sync_line() { # the default view's last line: nothing without a snapshot, and nothing for a fresh clean one
  sync_load
  case "$SYNC_STATE" in
    none) return 0 ;;
    stale) printf 'sync: stale snapshot (%s old): %s - bin/dash.sh --inbox\n' "$(sync_age_fmt "$SYNC_AGE_H")" "$(sync_what)" ;;
    *) [ "$SYNC_N" -eq 0 ] || printf 'sync: %s - bin/dash.sh --inbox\n' "$(sync_what)" ;;
  esac
}
sync_lane() { # --inbox's last lane
  local name needs h
  sync_load
  case "$SYNC_STATE" in
    none) echo "SYNC"; echo "  never run (bin/sync-check.sh)"; return 0 ;;
    stale) echo "SYNC (oldest first; stale snapshot, $(sync_age_fmt "$SYNC_AGE_H") old: run bin/sync-check.sh)" ;;
    *) echo "SYNC (oldest first; snapshot $(sync_age_fmt "$SYNC_AGE_H") old)" ;;
  esac
  if [ "$SYNC_N" -eq 0 ]; then echo "  (nothing)"; return 0; fi
  while IFS=$'\037' read -r name needs h; do
    printf '  %s: %s (oldest %s)\n' "$name" "$needs" "$(sync_age_fmt "$h")"
  done <"$TMP/sync.rows"
}

# ---- learner proposals (Phase 6 spec 6.1): read only, and the proposals folder is never created here ----
PROP_DIR="$AGENT_HOME/proposals"
proposal_rows() { # the open proposals, most sessions first: "kind id: first sentence (n sessions/m days)"
  local f st today
  [ -d "$PROP_DIR" ] && [ ! -L "$PROP_DIR" ] || return 0
  today=$(date -r "$NOW" +%Y-%m-%d)
  for f in "$PROP_DIR"/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    case "${f##*/}" in report-*) continue ;; esac
    st=$(proposal_get "$f" status)
    case "$st" in
      open) ;;
      snoozed:*) if [[ "${st#snoozed:}" > "$today" ]]; then continue; fi ;;
      *) continue ;;
    esac
    printf '%s\t%s\t%s %s: %s (%s sessions/%s days)\n' "$(proposal_get "$f" sessions)" "${f##*/}" \
      "$(proposal_get "$f" kind)" "$(proposal_get "$f" id)" \
      "$(proposal_section "$f" proposal | tr '\n' ' ' | perl -ne 's/\s+/ /g; s/^ //; s/(.*?[.!?])(\s.*|$)/$1/; print substr($_, 0, 160)')" \
      "$(proposal_get "$f" sessions)" "$(proposal_get "$f" days)"
  done | sort -t $'\t' -k1,1rn -k2,2 | cut -f3
}

case "$MODE" in
  counts)
    printf 'sessions=%s\nactive=%s\nblocked=%s\ninput=%s\nneeds=%s\nproposals=%s\n' \
      "$total" "$active" "$blocked" "$waiting" $((blocked + waiting)) "$(proposal_rows | grep -c . || true)"
    exit 0 ;;

  table)
    if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; sync_line; exit 0; fi
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      label=$(label_of "$name" "$branch")
      [ "$src" = worktree ] || label="$label ${sid:0:7}"
      printf '%-34s %-8s %5s %s %6s  %s%s\n' "$label" "$state" "$(human_age $((NOW - upd)))" "$(ctx_sym "$ctx")" "$(tok_h "$tok")" \
        "$cwd" "${note:+  -- $note}"
    done <"$TMP/sorted"
    echo "-- $total session(s), $active active"
    if [ "$active" -gt 5 ]; then echo "WARNING: $active active sessions; the plan caps this at about 5. Park some behind their STATE.md."; fi
    sync_line
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
    echo "PROPOSALS (decide with bin/kaching-proposals)"
    proposal_rows >"$TMP/props"
    if [ -s "$TMP/props" ]; then sed 's/^/  /' "$TMP/props"; else echo "  (nothing)"; fi
    sync_lane
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
props_said() { # " N proposals waiting." or nothing
  local n
  n=$(proposal_rows | grep -c . || true)
  if [ "$n" -eq 1 ]; then printf ' 1 proposal waiting.'; elif [ "$n" -gt 1 ]; then printf ' %s proposals waiting.' "$n"; fi
}
if [ "$total" -eq 0 ]; then echo "No Claude sessions in the last $HOURS hours.$(props_said)"; exit 0; fi
need=$((blocked + waiting)); out=""
if [ "$need" -eq 1 ]; then out="1 needs you. "; elif [ "$need" -gt 1 ]; then out="$need need you. "; fi
out="$out$active active session"; [ "$active" -eq 1 ] || out="${out}s"; out="$out out of $total."
n=0
while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
  [ "$name" != "~" ] || name=Home   # text-to-speech says nothing for "~"
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
  [ "$nn" != "~" ] || nn=home
  out="$out Nothing is blocked. Latest: $nn is $ns, $(spoken_age $((NOW - nu)))."
fi
[ "$done_n" -eq 0 ] || out="$out $done_n finished."
if [ "$active" -gt 5 ]; then out="$out Warning: that is more than five active sessions; consider parking some."; fi
echo "$out$(props_said)"
