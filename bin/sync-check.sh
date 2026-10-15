#!/usr/bin/env bash
# sync-check.sh [--quiet] [--no-fetch]   what could be lost or forgotten in the repos Ching knows about
# READ-ONLY: it never pushes, pulls, merges, rebases, checks out, resets, deletes or prunes, and never writes
# into a working tree. The one git command that changes anything is `git fetch --all --no-tags --no-prune`
# (remote-tracking refs only), run with a timeout, GIT_TERMINAL_PROMPT=0 and gc/maintenance off. A repo without
# a remote is not fetched; a failed or timed-out fetch is reported as "fetch failed" and the rest still reports.
# Repos: the lines of $AGENT_REPOS_FILE (default ~/.agent-repos; `~` allowed, # comments) plus the cwd of every
# event in $AGENT_HOME/events.jsonl (sync events excluded) and of every session meta, each resolved with
# `git rev-parse --show-toplevel` and then to its main checkout (`git worktree list`), so a repo shows once with
# its worktrees. Non-repos, bare repos, paths that are gone and sandbox paths (lib.sh is_sandbox_path: /tmp,
# task*-repo) are skipped; CHING_INCLUDE_SANDBOX=1 keeps sandbox paths.
# Per repo: (a) commits not pushed: per local branch with an upstream, the ahead count; a branch with no upstream
#   (or a gone one) counts its commits that are on no remote branch (not for a repo without any remote);
#   (b) behind origin after the fetch: the branch checked out in each worktree, and the base branch;
#   (c) uncommitted changes per worktree: modified, staged, untracked (files git ignores are not counted);
#   (d) linked worktrees whose branch is already merged into the base branch or its origin twin (what
#   `git branch --merged` says); the main checkout and a branch still sitting at the base tip are not listed;
#   (e) stash entries.
# Ages (the "oldest" in every line; <1h under an hour, then hours up to 47, then days):
#   unpushed = committer date of the oldest commit not on the upstream (no upstream: not on any remote branch);
#   behind = committer date of the oldest commit you are missing; uncommitted = oldest mtime among the changed
#   files (a deleted file has none); merged worktree = committer date of the branch tip; stash = committer date
#   of the oldest entry.
# Output: $AGENT_HOME/sync-check.md (latest snapshot, replaced atomically, starts with `generated: <UTC ISO>`);
#   one `sync` event per repo with findings in $AGENT_HOME/events.jsonl (counts and oldest_age_h only); and at
#   most one budgeted banner per local day (notify.sh kind sync, stamp $AGENT_HOME/sync-banner.day, never spoken)
#   when some finding other than behind-origin is older than SYNC_BANNER_AGE_H (24) hours (behind-origin only with
#   SYNC_BANNER_INCLUDE_BEHIND=1: an active repo is behind most days and nothing is lost by it). On demand it prints a one-line summary and the
#   snapshot path (--quiet: nothing). ching-watch.sh starts it in the background every SYNC_CHECK_INTERVAL_H (6) hours.
# Env: AGENT_HOME AGENT_REPOS_FILE SYNC_NO_FETCH (non-empty = no fetch, like --no-fetch) SYNC_FETCH_TIMEOUT (45 s per
#   repo) SYNC_FETCH_BUDGET (150 s for all fetches together; later repos are not fetched) SYNC_BANNER_AGE_H SYNC_BANNER_INCLUDE_BEHIND
#   SYNC_NOW (epoch, tests) CHING_INCLUDE_SANDBOX NOTIFY_* (the banner)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

QUIET=0; NOFETCH=${SYNC_NO_FETCH:-}
while [ $# -gt 0 ]; do
  case "$1" in
    --quiet) QUIET=1; shift ;;
    --no-fetch) NOFETCH=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "sync-check: unknown argument $1" >&2; exit 64 ;;
  esac
done

digits() { # value default [max_len=9] : the value as a decimal number when it is plain digits (1 to max_len), else the default
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) if [ "${#1}" -le "${3:-9}" ]; then printf '%s' $((10#$1)); else printf '%s' "$2"; fi ;; esac
}
NOW=$(digits "${SYNC_NOW:-}" "$(date +%s)" 12)
FETCH_TIMEOUT=$(digits "${SYNC_FETCH_TIMEOUT:-}" 45); [ "$FETCH_TIMEOUT" -ge 1 ] || FETCH_TIMEOUT=1
FETCH_BUDGET=$(digits "${SYNC_FETCH_BUDGET:-}" 150)
BANNER_SECS=$(( $(digits "${SYNC_BANNER_AGE_H:-}" 24) * 3600 ))
REPOS_FILE=${AGENT_REPOS_FILE:-$HOME/.agent-repos}
SNAP="$AGENT_HOME/sync-check.md"
mkdir -p "$AGENT_HOME"

# Own lock (mkdir). A holder that died without cleaning up (killed at the watcher's time ceiling) is stale after 15 min.
LOCK="$AGENT_HOME/sync-check.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(file_mtime "$LOCK") )) -lt 900 ]; then
    [ "$QUIET" = 1 ] || echo "sync-check: already running (lock $LOCK)"
    exit 0
  fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-sync.XXXXXX")
SNAP_TMP="$AGENT_HOME/.sync-check.md.$$"
trap 'rm -rf "$LOCK" "$TMP"; rm -f "$SNAP_TMP"' EXIT

# Nothing below may write into a repo: no optional index refresh, no prompts, no fsmonitor daemon, no auto gc.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C
g() { git -c core.fsmonitor=false -c gc.auto=0 -c maintenance.auto=false "$@"; }

age_fmt() { # seconds -> <1h, 5h (up to 47 h), 3d
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 3600 ]; then echo "<1h"
  elif [ "$s" -lt 172800 ]; then echo "$((s / 3600))h"
  else echo "$((s / 86400))d"; fi
}
age_of() { # epoch -> seconds before NOW (never negative; 0 when it is not a number)
  case "$1" in ''|*[!0-9]*) echo 0; return 0 ;; esac
  local a=$((NOW - $1)); [ "$a" -ge 0 ] || a=0
  echo "$a"
}
min_ct() { awk 'NR == 1 || $1 + 0 < m + 0 { m = $1 } END { if (NR) print m }'; }   # smallest number on stdin (reads it all: no SIGPIPE)
ct_min_of() { g -C "$R" "$@" | min_ct || true; }   # oldest committer time (epoch) of a `log --format=%ct` selection
num() { # value -> the value when it is plain digits, else 0
  case "$1" in ''|*[!0-9]*) echo 0 ;; *) echo $((10#$1)) ;; esac
}
cnt() { if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%s %s' "$1" "${3:-$2s}"; fi; }   # 1 commit / 3 commits
maxi() { if [ "$1" -gt "$2" ]; then echo "$1"; else echo "$2"; fi; }
join_items() { awk 'NR <= 4 { s = s (s == "" ? "" : ", ") $0 } END { if (NR > 4) s = s ", +" (NR - 4) " more"; print s }' "$1"; }
short_path() { case "$1" in "$HOME"/*) printf '%s/%s' '~' "${1#"$HOME"/}" ;; *) printf '%s' "$1" ;; esac; }

# run_limited SECS CMD... : CMD in a session of its own (no terminal). After SECS the whole group gets TERM, then
# KILL a second later, and the exit code is 142. A TERM/INT/HUP to the runner takes the group down too.
run_limited() {
  perl -e '
    use POSIX ":sys_wait_h";
    my $t = shift @ARGV;
    my $pid = fork;
    defined $pid or die "fork: $!\n";
    if (!$pid) { POSIX::setsid() or setpgrp(0, 0); exec { $ARGV[0] } @ARGV; POSIX::_exit(127); }
    my $reaped = 0;
    my $down = sub {
      kill "TERM", -$pid; kill "TERM", $pid;
      for (1 .. 10) {
        $reaped ||= waitpid($pid, WNOHANG) != 0;
        last if $reaped && !kill(0, -$pid);
        select undef, undef, undef, 0.1;
      }
      kill "KILL", -$pid; kill "KILL", $pid;
      waitpid($pid, 0) unless $reaped;
    };
    $SIG{ALRM} = sub { $down->(); exit 142 };
    $SIG{$_} = sub { $down->(); exit 143 } for qw(TERM INT HUP);
    alarm $t if $t > 0;
    waitpid($pid, 0);
    my $s = $?;
    exit($s & 127 ? 128 + ($s & 127) : $s >> 8);
  ' "$@"
}

# dirty_counts WT < `git status --porcelain=v1 -z` -> "modified staged untracked oldest_mtime" (0 when none).
# One perl pass: counts the XY codes and takes the oldest lstat mtime among the changed paths.
dirty_counts() {
  perl -0777 -e '
    my $wt = shift; my ($mod, $stg, $unt, $old) = (0, 0, 0, 0);
    my @e = split /\0/, scalar <STDIN>;
    while (@e) {
      my $e = shift @e; next if length($e) < 4;
      my ($x, $y, $p) = (substr($e, 0, 1), substr($e, 1, 1), substr($e, 3));
      shift @e if $x =~ /[RC]/ || $y =~ /[RC]/;   # rename/copy: the next entry is the old path
      if ($x eq "?") { $unt++ } elsif ($x eq "!") { next } else { $stg++ if $x ne " "; $mod++ if $y ne " " }
      my @s = lstat("$wt/$p");
      $old = $s[9] if @s && (!$old || $s[9] < $old);
    }
    print "$mod $stg $unt $old\n";
  ' "$1"
}

# ---------- 1. which repos ----------
CANDS="$TMP/cands"; : >"$CANDS"
if [ -f "$REPOS_FILE" ]; then
  { grep -v '^[[:space:]]*#' "$REPOS_FILE" || true; } | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | while IFS= read -r p; do
    [ -n "$p" ] || continue
    # shellcheck disable=SC2088
    case "$p" in "~"|"~/"*) p="$HOME${p#"~"}" ;; esac
    printf '%s\n' "$p"
  done >>"$CANDS"
fi
# Event cwds: pull the quoted values out with grep (jq over a 20 MB log is slow), unique them, then let jq
# decode the JSON strings. Our own sync events are left out, so a repo is not "known" just because it was reported.
if [ -f "$AGENT_HOME/events.jsonl" ]; then
  { grep -v '"kind":"sync"' "$AGENT_HOME/events.jsonl" || true; } | { grep -oE '"cwd":"([^"\\]|\\.)*"' || true; } \
    | sort -u | sed 's/^"cwd"://' | { jq -r '.' 2>/dev/null || true; } >>"$CANDS"
fi
if [ -d "$AGENT_HOME/sessions" ]; then
  { find "$AGENT_HOME/sessions" -mindepth 2 -maxdepth 2 -name meta -print0 2>/dev/null | xargs -0 grep -h '^cwd=' 2>/dev/null || true; } \
    | sed 's/^cwd=//' | sort -u >>"$CANDS"
fi
# Resolve every candidate to the main checkout of its repo; skip what is not an absolute, existing, non-sandbox path
# inside a non-bare repo. Unique candidates only: the events of a busy machine hold a few hundred cwds, not thousands.
sort -u "$CANDS" | while IFS= read -r c; do
  case "$c" in /*) ;; *) continue ;; esac
  if is_sandbox_path "$c"; then continue; fi
  [ -d "$c" ] || continue
  top=$(g -C "$c" rev-parse --show-toplevel 2>/dev/null) || continue
  main=$(g -C "$top" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p') || main=""
  { [ -n "$main" ] && [ -d "$main" ]; } || main=$top
  [ "$(g -C "$main" rev-parse --is-bare-repository 2>/dev/null || true)" = false ] || continue
  if is_sandbox_path "$main"; then continue; fi
  printf '%s\n' "$main"
done | sort -u >"$TMP/repos"

# ---------- 2. one repo ----------
# check_repo R: sets U_* (unpushed), N_* (no upstream), B_* (behind), D_* (dirty), M_* (merged), S_* (stash) and
# OLDEST (seconds), FETCH (ok failed skipped off none); item lists go to $TMP/*.items.
fetch_repo() {
  local t left
  FETCH=none
  [ -n "$(g -C "$R" remote 2>/dev/null || true)" ] || return 0
  if [ -n "$NOFETCH" ]; then FETCH=off; return 0; fi
  left=$((FETCH_BUDGET - (SECONDS - T0)))
  if [ "$left" -le 0 ]; then FETCH=skipped; return 0; fi
  t=$FETCH_TIMEOUT; [ "$t" -le "$left" ] || t=$left
  # --no-prune and fetch.prune=false: a global fetch.prune=true must not delete remote-tracking refs. No tags.
  if run_limited "$t" env GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never SSH_ASKPASS_REQUIRE=never \
       git -c gc.auto=0 -c maintenance.auto=false -c fetch.prune=false -c fetch.pruneTags=false -c fetch.writeCommitGraph=false \
       -C "$R" fetch --all --no-tags --no-prune --no-recurse-submodules --quiet </dev/null >/dev/null 2>&1; then FETCH=ok; else FETCH=failed; fi
}

check_repo() {
  local ref upref trk br ahead behind has_up age n wt wbr flags tip basetip twin out mod stg unt old parts into is_main
  U_BR=0; U_N=0; U_AGE=0; N_BR=0; N_N=0; N_AGE=0; B_BR=0; B_N=0; B_AGE=0
  D_WT=0; D_MOD=0; D_STG=0; D_UNT=0; D_AGE=0; M_N=0; M_AGE=0; S_N=0; S_AGE=0; OLDEST=0; BAN_AGE=0
  : >"$TMP/unp.items"; : >"$TMP/nup.items"; : >"$TMP/beh.items"; : >"$TMP/dirty.items"; : >"$TMP/mrg.items"
  fetch_repo
  HAS_REMOTE=0; [ "$FETCH" = none ] || HAS_REMOTE=1

  # worktrees: path, branch (empty when detached), flags; the first one is the main checkout
  g -C "$R" worktree list --porcelain 2>/dev/null | awk '
    function out() { if (p != "") print p "\037" b "\037" fl }
    /^worktree / { out(); p = substr($0, 10); b = ""; fl = ""; next }
    /^branch / { b = substr($0, 8); sub("^refs/heads/", "", b); next }
    /^bare/ { fl = fl "bare " } /^prunable/ { fl = fl "prunable " }
    END { out() }' >"$TMP/wt" || true
  : >"$TMP/wtbr"
  while IFS=$'\037' read -r wt wbr flags; do [ -z "$wbr" ] || printf '%s\n' "$wbr" >>"$TMP/wtbr"; done <"$TMP/wt"

  # base branch: origin/HEAD, else main, else master, else what the main checkout has checked out
  BASE=$(g -C "$R" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^[^/]*/##') || BASE=""
  if [ -z "$BASE" ] || ! g -C "$R" show-ref --verify --quiet "refs/heads/$BASE"; then
    BASE=""
    for n in main master; do
      if g -C "$R" show-ref --verify --quiet "refs/heads/$n"; then BASE=$n; break; fi
    done
  fi
  [ -n "$BASE" ] || BASE=$(g -C "$R" symbolic-ref --quiet --short HEAD 2>/dev/null) || BASE=""
  local base_up=""   # set to the base's remote ref when it has one (configured upstream, else origin/<base>)

  # (a) commits not pushed, (b) behind origin: one pass over the local branches
  g -C "$R" for-each-ref --format='%(refname)%1f%(upstream)%1f%(upstream:track,nobracket)' refs/heads >"$TMP/refs" 2>/dev/null || true
  while IFS=$'\037' read -r ref upref trk; do
    br=${ref#refs/heads/}; ahead=0; behind=0; has_up=""
    case "$upref" in refs/remotes/*) has_up=1 ;; esac
    if [ -n "$has_up" ] && [ "$trk" != gone ]; then
      case "$trk" in *ahead\ *) ahead=${trk#*ahead }; ahead=$(num "${ahead%%[!0-9]*}") ;; esac
      case "$trk" in *behind\ *) behind=${trk#*behind }; behind=$(num "${behind%%[!0-9]*}") ;; esac
      [ "$br" != "$BASE" ] || base_up=$upref
      if [ "$ahead" -gt 0 ]; then
        age=$(age_of "$(ct_min_of log --format=%ct "$upref..$ref" --)")
        U_BR=$((U_BR + 1)); U_N=$((U_N + ahead)); U_AGE=$(maxi "$age" "$U_AGE")
        printf '%s +%s (%s)\n' "$br" "$ahead" "$(age_fmt "$age")" >>"$TMP/unp.items"
      fi
      if [ "$behind" -gt 0 ] && { [ "$br" = "$BASE" ] || grep -qxF -- "$br" "$TMP/wtbr"; }; then
        age=$(age_of "$(ct_min_of log --format=%ct "$ref..$upref" --)")
        B_BR=$((B_BR + 1)); B_N=$((B_N + behind)); B_AGE=$(maxi "$age" "$B_AGE")
        printf '%s -%s (%s)\n' "$br" "$behind" "$(age_fmt "$age")" >>"$TMP/beh.items"
      fi
    elif [ "$HAS_REMOTE" = 1 ]; then
      # no (remote) upstream, or the upstream is gone: commits that are on no remote branch at all
      n=$(num "$(g -C "$R" rev-list --count "$ref" --not --remotes -- 2>/dev/null || true)")
      if [ "$n" -gt 0 ]; then
        age=$(age_of "$(ct_min_of log --format=%ct "$ref" --not --remotes --)")
        N_BR=$((N_BR + 1)); N_N=$((N_N + n)); N_AGE=$(maxi "$age" "$N_AGE")
        printf '%s: %s on no remote branch (%s)\n' "$br" "$(cnt "$n" commit)" "$(age_fmt "$age")" >>"$TMP/nup.items"
      fi
    fi
  done <"$TMP/refs"
  # a base branch without a configured upstream still has an origin twin to be behind
  twin=""
  if [ -n "$BASE" ] && [ "$HAS_REMOTE" = 1 ]; then
    if [ -n "$base_up" ]; then twin=$base_up
    elif g -C "$R" show-ref --verify --quiet "refs/remotes/origin/$BASE"; then twin="refs/remotes/origin/$BASE"; fi
    if [ -n "$twin" ] && [ -z "$base_up" ]; then
      behind=$(num "$(g -C "$R" rev-list --count "refs/heads/$BASE..$twin" -- 2>/dev/null || true)")
      if [ "$behind" -gt 0 ]; then
        age=$(age_of "$(ct_min_of log --format=%ct "refs/heads/$BASE..$twin" --)")
        B_BR=$((B_BR + 1)); B_N=$((B_N + behind)); B_AGE=$(maxi "$age" "$B_AGE")
        printf '%s -%s (%s)\n' "$BASE" "$behind" "$(age_fmt "$age")" >>"$TMP/beh.items"
      fi
    fi
  fi

  # (c) uncommitted changes per worktree, (d) merged linked worktrees
  basetip=""; [ -z "$BASE" ] || basetip=$(g -C "$R" rev-parse --verify --quiet "refs/heads/$BASE" 2>/dev/null) || basetip=""
  local first=1
  while IFS=$'\037' read -r wt wbr flags; do
    if [ "$first" = 1 ]; then first=0; is_main=1; else is_main=0; fi
    case "$flags" in *bare*|*prunable*) continue ;; esac
    [ -d "$wt" ] || continue
    out=$(g -C "$wt" status --porcelain=v1 -z --untracked-files=normal 2>/dev/null | dirty_counts "$wt") || out=""
    read -r mod stg unt old <<<"${out:-0 0 0 0}" || true
    mod=$(num "$mod"); stg=$(num "$stg"); unt=$(num "$unt"); old=$(num "$old")
    if [ $((mod + stg + unt)) -gt 0 ]; then
      age=0; [ "$old" -eq 0 ] || age=$(age_of "$old")
      D_WT=$((D_WT + 1)); D_MOD=$((D_MOD + mod)); D_STG=$((D_STG + stg)); D_UNT=$((D_UNT + unt)); D_AGE=$(maxi "$age" "$D_AGE")
      parts=""
      [ "$mod" -eq 0 ] || parts="$mod modified"
      [ "$stg" -eq 0 ] || parts="$parts${parts:+, }$stg staged"
      [ "$unt" -eq 0 ] || parts="$parts${parts:+, }$unt untracked"
      printf '%s: %s (%s)\n' "$(short_path "$wt")" "$parts" "$(age_fmt "$age")" >>"$TMP/dirty.items"
    fi
    if [ "$is_main" = 0 ] && [ -n "$wbr" ] && [ "$wbr" != "$BASE" ] && [ -n "$basetip" ]; then
      tip=$(g -C "$R" rev-parse --verify --quiet "refs/heads/$wbr" 2>/dev/null) || tip=""
      if [ -n "$tip" ] && [ "$tip" != "$basetip" ] && g -C "$R" merge-base --is-ancestor "$tip" "$basetip" 2>/dev/null; then
        into=$BASE
      elif [ -n "$tip" ] && [ -n "$twin" ] && [ "$tip" != "$(g -C "$R" rev-parse --verify --quiet "$twin" 2>/dev/null || true)" ] \
           && g -C "$R" merge-base --is-ancestor "$tip" "$twin" 2>/dev/null; then
        into=${twin#refs/remotes/}
      else into=""; fi
      if [ -n "$into" ]; then
        age=$(age_of "$(g -C "$R" log -1 --format=%ct "$tip" -- 2>/dev/null || true)")
        M_N=$((M_N + 1)); M_AGE=$(maxi "$age" "$M_AGE")
        printf '%s (branch %s, merged into %s, tip %s old)\n' "$(short_path "$wt")" "$wbr" "$into" "$(age_fmt "$age")" >>"$TMP/mrg.items"
      fi
    fi
  done <"$TMP/wt"

  # (e) stash
  g -C "$R" stash list --format=%ct >"$TMP/stash" 2>/dev/null || true
  S_N=$(grep -c . "$TMP/stash" || true); S_N=$(num "$S_N")
  if [ "$S_N" -gt 0 ]; then S_AGE=$(age_of "$(min_ct <"$TMP/stash")"); fi

  for age in "$U_AGE" "$N_AGE" "$B_AGE" "$D_AGE" "$M_AGE" "$S_AGE"; do OLDEST=$(maxi "$age" "$OLDEST"); done
  # The banner ignores behind-origin (the main branch of a repo with collaborators is a day behind most days and
  # nothing is lost by it); it stays in the snapshot, the events and dash. SYNC_BANNER_INCLUDE_BEHIND=1 counts it.
  for age in "$U_AGE" "$N_AGE" "$D_AGE" "$M_AGE" "$S_AGE"; do BAN_AGE=$(maxi "$age" "$BAN_AGE"); done
  if [ -n "${SYNC_BANNER_INCLUDE_BEHIND:-}" ]; then BAN_AGE=$(maxi "$B_AGE" "$BAN_AGE"); fi
  FINDINGS=$((U_BR + N_BR + B_BR + D_WT + M_N + S_N))
}

addneed() { needs="$needs${needs:+, }$1"; }
T0=$SECONDS
REPO_N=0; FIND_N=0; MAX_OLD=0; MAX_BAN=0; F_OK=0; F_FAIL=0; F_SKIP=0
: >"$TMP/order"; : >"$TMP/clean"
while IFS= read -r R; do
  [ -n "$R" ] || continue
  REPO_N=$((REPO_N + 1))
  check_repo
  case "$FETCH" in ok) F_OK=$((F_OK + 1)) ;; failed) F_FAIL=$((F_FAIL + 1)) ;; skipped) F_SKIP=$((F_SKIP + 1)) ;; esac
  name=$(basename "$R")
  if [ "$FINDINGS" -eq 0 ]; then
    note=""; case "$FETCH" in failed) note=" (fetch failed)" ;; skipped) note=" (fetch skipped)" ;; esac
    printf '%s%s\n' "$name" "$note" >>"$TMP/clean"
    continue
  fi
  FIND_N=$((FIND_N + 1)); MAX_OLD=$(maxi "$OLDEST" "$MAX_OLD"); MAX_BAN=$(maxi "$BAN_AGE" "$MAX_BAN")
  needs=""
  [ "$U_N" -eq 0 ] || addneed "$(cnt "$U_N" "unpushed commit")"
  [ "$N_BR" -eq 0 ] || addneed "$(cnt "$N_BR" branch branches) with no upstream ($(cnt "$N_N" commit))"
  [ "$B_N" -eq 0 ] || addneed "$(cnt "$B_N" commit) behind origin"
  [ "$D_WT" -eq 0 ] || addneed "$(cnt "$D_WT" "dirty worktree")"
  [ "$M_N" -eq 0 ] || addneed "$(cnt "$M_N" "merged worktree")"
  [ "$S_N" -eq 0 ] || addneed "$(cnt "$S_N" stash stashes)"
  {
    printf '## %s -- oldest %s\n' "$name" "$(age_fmt "$OLDEST")"
    printf 'path: %s\nneeds: %s\nage_h: %s\n' "$R" "$needs" $((OLDEST / 3600))
    [ "$U_BR" -eq 0 ] || printf -- '- unpushed: %s\n' "$(join_items "$TMP/unp.items")"
    [ "$N_BR" -eq 0 ] || printf -- '- no upstream: %s\n' "$(join_items "$TMP/nup.items")"
    [ "$B_BR" -eq 0 ] || printf -- '- behind origin: %s\n' "$(join_items "$TMP/beh.items")"
    [ "$D_WT" -eq 0 ] || printf -- '- uncommitted: %s\n' "$(join_items "$TMP/dirty.items")"
    [ "$M_N" -eq 0 ] || printf -- '- merged worktrees: %s\n' "$(join_items "$TMP/mrg.items")"
    [ "$S_N" -eq 0 ] || printf -- '- stash: %s (oldest %s)\n' "$(cnt "$S_N" entry entries)" "$(age_fmt "$S_AGE")"
    case "$FETCH" in
      failed) printf -- '- fetch failed: the remote could not be reached; ahead and behind use the last known remote state\n' ;;
      skipped) printf -- '- fetch skipped: the time budget for fetching was used up; ahead and behind use the last known remote state\n' ;;
    esac
    printf '\n'
  } >"$TMP/sec.$FIND_N"
  printf '{"unpushed_branches":%s,"unpushed_commits":%s,"no_upstream_branches":%s,"no_upstream_commits":%s,"behind_branches":%s,"behind_commits":%s,"dirty_worktrees":%s,"modified":%s,"staged":%s,"untracked":%s,"merged_worktrees":%s,"stashes":%s,"fetch":"%s","oldest_age_h":%s}\n' \
    "$U_BR" "$U_N" "$N_BR" "$N_N" "$B_BR" "$B_N" "$D_WT" "$D_MOD" "$D_STG" "$D_UNT" "$M_N" "$S_N" "$FETCH" $((OLDEST / 3600)) >"$TMP/ev.$FIND_N"
  printf '%s\037%s\n' "$name" "$R" >"$TMP/who.$FIND_N"
  printf '%s\t%s\n' "$OLDEST" "$FIND_N" >>"$TMP/order"
done <"$TMP/repos"

# ---------- 3. the snapshot, replaced atomically ----------
CLEAN_N=$((REPO_N - FIND_N))
if [ "$FIND_N" -eq 1 ]; then verb="needs"; else verb="need"; fi
summary="$FIND_N $(if [ "$FIND_N" -eq 1 ]; then echo repo; else echo repos; fi) $verb attention, $CLEAN_N clean"
[ "$FIND_N" -eq 0 ] || summary="$summary (oldest finding $(age_fmt "$MAX_OLD"))"
if [ -n "$NOFETCH" ]; then fsum="Fetch: off (remote state may be out of date)."
elif [ $((F_OK + F_FAIL + F_SKIP)) -eq 0 ]; then fsum="Fetch: nothing to fetch."
else
  fsum="Fetch:"; fsep=" "
  [ "$F_OK" -eq 0 ] || { fsum="$fsum${fsep}$F_OK ok"; fsep=", "; }
  [ "$F_FAIL" -eq 0 ] || { fsum="$fsum${fsep}$F_FAIL failed"; fsep=", "; }
  [ "$F_SKIP" -eq 0 ] || { fsum="$fsum${fsep}$F_SKIP skipped"; fsep=", "; }
  fsum="$fsum."
fi
{
  printf 'generated: %s\n' "$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ)"
  printf 'Git sync check, %s local time: %s. %s\n\n' "$(date -r "$NOW" '+%Y-%m-%d %H:%M')" "$summary" "$fsum"
  sort -t$'\t' -k1,1nr -k2,2n "$TMP/order" | while IFS=$'\t' read -r _ i; do cat "$TMP/sec.$i"; done
  if [ -s "$TMP/clean" ]; then printf 'clean: %s\n' "$(awk '{ s = s (s == "" ? "" : ", ") $0 } END { print s }' "$TMP/clean")"; else printf 'clean: (none)\n'; fi
} >"$SNAP_TMP"
mv -f "$SNAP_TMP" "$SNAP"

# ---------- 4. one sync event per repo with findings (the same oldest-first order as the snapshot) ----------
SID=""
sort -t$'\t' -k1,1nr -k2,2n "$TMP/order" | while IFS=$'\t' read -r _ i; do
  IFS=$'\037' read -r NAME CWD <"$TMP/who.$i"
  ev sync "$(cat "$TMP/ev.$i")"
done

# ---------- 5. at most one budgeted banner a day, only for a finding older than SYNC_BANNER_AGE_H ----------
# notify.sh decides quiet hours, the daily budget and the cooldown; a banner it suppresses does not use up the
# day, so a later run (daytime) can still deliver it. The stamp is ours: wiping notify's budget files changes nothing.
banner() {
  local day stamp before after method msg
  [ "$FIND_N" -gt 0 ] && [ "$MAX_BAN" -ge "$BANNER_SECS" ] || return 0
  day=$(date -r "$NOW" +%Y-%m-%d)
  stamp="$AGENT_HOME/sync-banner.day"
  [ "$(cat "$stamp" 2>/dev/null || true)" != "$day" ] || return 0
  nlog=${NOTIFY_LOG:-$AGENT_HOME/notify.log}
  before=$({ wc -l <"$nlog"; } 2>/dev/null | tr -d ' ') || before=0; before=$(num "$before")
  msg="Git sync: $FIND_N $(if [ "$FIND_N" -eq 1 ]; then echo "repo needs"; else echo "repos need"; fi) attention (oldest $(age_fmt "$MAX_OLD")). Run bin/dash.sh --inbox"
  NOTIFY_CWD="$HOME" NOTIFY_SESSION=sync-check NOTIFY_NOW="$NOW" "$SELF_DIR/notify.sh" sync "$msg" </dev/null >/dev/null 2>&1 || true
  after=$({ wc -l <"$nlog"; } 2>/dev/null | tr -d ' ') || after=0; after=$(num "$after")
  method=$(tail -1 "$nlog" 2>/dev/null | cut -f2 || true)
  case "$method" in suppressed:*) return 0 ;; esac
  if [ "$after" -gt "$before" ]; then
    printf '%s\n' "$day" >"$stamp.tmp" && mv -f "$stamp.tmp" "$stamp"
  fi
  return 0
}
banner

if [ "$QUIET" = 0 ]; then
  echo "sync-check: $summary. $fsum"
  echo "snapshot: $SNAP"
fi
exit 0
