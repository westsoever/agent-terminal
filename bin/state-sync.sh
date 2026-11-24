#!/usr/bin/env bash
# state-sync.sh [start|stop|end|sync|init <remote>] - keep session state ($AGENT_HOME, ~/.agent) and skills
# (~/.agents) the same on every Mac (D84). Each folder is a git repo; a sync commits what its .gitignore lets
# in, rebases onto origin and pushes.
#   start  SessionStart hook: sync in the background, so the session starts at once.
#   stop   Stop hook: the same, at most once per STATE_SYNC_GAP seconds (default 600).
#   end    SessionEnd hook: sync in the background.
#   sync   sync now, in the foreground (the hooks run this).
#   init <remote>  turn $AGENT_HOME into a clone of <remote> in place. Local files stay; only sessions/ is
#          tracked (whitelist .gitignore), so secret/, tokens/, keys and logs never leave the machine.
# Never force-pushes. A rebase that conflicts is aborted and logged in $AGENT_HOME/state-sync.log; the repo is
# left as it was for a human (sync-check.sh reports it as ahead/behind).
# STATE_SYNC_OFF=1 turns it off. STATE_SYNC_DIRS (space separated) replaces the default folder list.
set -euo pipefail
AGENT_HOME=${AGENT_HOME:-$HOME/.agent}
DIRS=${STATE_SYNC_DIRS:-"$AGENT_HOME $HOME/.agents"}
LOG=$AGENT_HOME/state-sync.log
GAP=${STATE_SYNC_GAP:-600}
STAMP=$AGENT_HOME/.state-sync.stamp
MODE=${1:-sync}
SELF=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")
[ "${STATE_SYNC_OFF:-}" = 1 ] && exit 0
[ "${AGENT_TERMINAL_LEARNER:-}" = 1 ] && exit 0
export GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=20
export GIT_SSH_COMMAND=${GIT_SSH_COMMAND:-"ssh -o BatchMode=yes -o ConnectTimeout=10"}

log() { mkdir -p "$AGENT_HOME"; printf '%s %s %s\n' "$(date '+%F %T')" "$MODE" "$*" >>"$LOG"; }

bg() { # run "sync" detached; hooks must not wait on the network
  [ -t 0 ] || cat >/dev/null   # the hook's JSON
  if [ "${STATE_SYNC_FG:-}" = 1 ]; then "$SELF" sync; else nohup "$SELF" sync >/dev/null 2>&1 </dev/null & fi
  exit 0
}

WHITELIST='# Only session state syncs between machines (agent-terminal D84, bin/state-sync.sh).
# Everything else in ~/.agent is per machine or secret: secret/, tokens/, terminal/keys.toml, events.jsonl, logs.
/*
!/.gitignore
!/sessions/
/sessions/*/.meta.flock
.DS_Store'

sync_one() { # repo; caller holds the repo lock
  local repo=$1 br before
  [ -d "$repo/.git" ] || return 0
  git -C "$repo" remote get-url origin >/dev/null 2>&1 || return 0
  br=$(git -C "$repo" symbolic-ref --short -q HEAD) || { log "$repo: detached HEAD, skipped"; return 0; }
  if [ -d "$repo/.git/rebase-merge" ] || [ -d "$repo/.git/rebase-apply" ] || [ -f "$repo/.git/MERGE_HEAD" ]; then
    log "$repo: a rebase or merge is in progress, skipped"; return 0
  fi
  git -C "$repo" add -A >/dev/null 2>&1 || true
  if ! git -C "$repo" diff --cached --quiet; then
    git -C "$repo" commit -q --no-verify -m "sync: $(hostname -s) $(date '+%F %T')" || { log "$repo: commit failed"; return 1; }
  fi
  before=$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)
  local has=0
  git -C "$repo" ls-remote --exit-code --heads origin "$br" >/dev/null 2>&1 || has=$?
  if [ "$has" = 0 ]; then
    git -C "$repo" fetch -q origin "$br" 2>>"$LOG" || { log "$repo: fetch failed (offline?)"; return 1; }
  elif [ "$has" != 2 ]; then
    log "$repo: origin unreachable (offline?)"; return 1
  fi
  if [ "$has" = 0 ]; then
    if ! git -C "$repo" rebase -q --autostash "origin/$br" >/dev/null 2>&1; then
      git -C "$repo" rebase --abort >/dev/null 2>&1 || true
      log "$repo: rebase onto origin/$br conflicts; nothing pushed, resolve by hand"; return 1
    fi
  fi
  if [ "$has" = 2 ] || [ -n "$(git -C "$repo" rev-list "origin/$br..HEAD" 2>/dev/null)" ]; then
    git -C "$repo" push -q origin "$br" 2>>"$LOG" || { log "$repo: push failed"; return 1; }
  fi
  # ~/.agents moved: link any new skill into ~/.claude/skills
  if [ "$before" != "$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)" ] && [ -x "$repo/install.sh" ] && [ "$repo" = "$HOME/.agents" ]; then
    "$repo/install.sh" >/dev/null 2>&1 || log "$repo: install.sh failed"
  fi
  return 0
}

case "$MODE" in
  start|end) bg ;;
  stop)
    [ -t 0 ] || cat >/dev/null
    now=$(date +%s); last=$(cat "$STAMP" 2>/dev/null || echo 0)
    [ $((now - last)) -ge "$GAP" ] || exit 0
    mkdir -p "$AGENT_HOME"; echo "$now" >"$STAMP"
    bg </dev/null ;;
  _locked) rc=0; sync_one "$2" || rc=$?; exit "$rc" ;;
  sync)
    rc=0
    for d in $DIRS; do
      [ -d "$d/.git" ] || continue
      # one sync per repo at a time: many sessions end together
      lockf -s -t 120 "$d/.git/state-sync.lock" "$SELF" _locked "$d" || rc=1
    done
    exit $rc ;;
  init)
    remote=${2:?usage: state-sync.sh init <remote url>}
    repo=$AGENT_HOME
    mkdir -p "$repo"
    if [ -d "$repo/.git" ]; then echo "$repo is already a git repo"; exit 0; fi
    git -C "$repo" init -q -b main
    git -C "$repo" remote add origin "$remote"
    [ -f "$repo/.gitignore" ] || printf '%s\n' "$WHITELIST" >"$repo/.gitignore"
    if git -C "$repo" fetch -q origin main 2>/dev/null; then
      git -C "$repo" reset -q origin/main                      # index = origin; local files untouched
      git -C "$repo" ls-files -d -z | xargs -0 git -C "$repo" checkout -q --   # bring in what only origin has
      git -C "$repo" branch -q --set-upstream-to=origin/main main
    fi
    MODE=sync; "$SELF" sync || echo "first sync failed: see $LOG" >&2
    git -C "$repo" branch -q --set-upstream-to=origin/main main 2>/dev/null || true
    echo "$repo now syncs with $remote" ;;
  *) echo "usage: state-sync.sh [start|stop|end|sync|init <remote>]" >&2; exit 2 ;;
esac
