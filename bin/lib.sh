# shellcheck shell=bash
# shellcheck disable=SC2034
# lib.sh - helpers shared by the ching hooks. Sourced, never executed.
#
# Machine-wide model: every session has a record under $AGENT_HOME/sessions/<session id>/ (meta, and
# STATE.md/NEXT.md when the cwd is not a repo that opted in). A repo opts in to per-repo state by having
# <repo>/.agent/GOAL.md; then GOAL/STATE/NEXT live in <repo>/.agent/ (per worktree). Nothing here assumes
# a git repo: cwd may be ~ or a plain folder.

AGENT_HOME=${AGENT_HOME:-$HOME/.agent}
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}

jget() { # field of the hook JSON in $INPUT ('' when absent / not JSON)
  if [ -n "${INPUT:-}" ]; then printf '%s' "$INPUT" | jq -r --arg f "$1" '.[$f] // empty' 2>/dev/null || true; fi
}

name_for() { # cwd root -> short display name: repo/worktree dir, "~" for home, else the folder name
  if [ -n "$2" ]; then basename "$2"
  elif [ "$1" = "$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")" ]; then echo "~"
  else basename "$1"; fi
}

# hook_init: read hook JSON from stdin (unless a tty) and set INPUT CWD SID ROOT NAME WORK_DIR.
hook_init() {
  INPUT=""
  if [ ! -t 0 ]; then INPUT=$(cat || true); fi
  CWD=$(jget cwd)
  [ -n "$CWD" ] || CWD=${HOOK_CWD:-$PWD}
  if [ -d "$CWD" ]; then CWD=$(cd "$CWD" && pwd -P); fi
  SID=$(jget session_id)
  [ -n "$SID" ] || SID="nosession-$(printf '%s' "$CWD" | shasum | cut -c1-8)"
  # SID names a directory under sessions/: one that could leave it ("..", "/", a leading dot, odd bytes,
  # very long) becomes sid-<hash of the raw id>, stable per id and distinct from other ids.
  case "$SID" in .*|*..*|*[!A-Za-z0-9._-]*) SID="sid-$(printf '%s' "$SID" | shasum | cut -c1-16)" ;; esac
  [ "${#SID}" -le 128 ] || SID="sid-$(printf '%s' "$SID" | shasum | cut -c1-16)"
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
  NAME=$(name_for "$CWD" "$ROOT")
  WORK_DIR=${ROOT:-$CWD}
}

# resolve_state: set SESS_DIR REPO_MODE STATE_DIR GOAL_FILE (GOAL_FILE is '' when there is none).
resolve_state() {
  SESS_DIR="$AGENT_HOME/sessions/$SID"
  REPO_MODE=0
  GOAL_FILE=""
  if [ -n "$ROOT" ] && [ -f "$ROOT/.agent/GOAL.md" ]; then
    REPO_MODE=1; STATE_DIR="$ROOT/.agent"; GOAL_FILE="$ROOT/.agent/GOAL.md"
  else
    STATE_DIR=$SESS_DIR
    if [ -f "$AGENT_HOME/defaults/GOAL.md" ]; then GOAL_FILE="$AGENT_HOME/defaults/GOAL.md"; fi
  fi
}

# meta_set key value : single-line key=value registry for the current session. The hooks and the watcher
# write the same file, so the whole read-modify-write is one perl call holding flock on .meta.flock (perl's
# flock works on macOS, which has no flock(1)). The kernel drops the lock when its holder dies, so there are
# no stale locks. A holder that hangs is waited for 2 s at most (UserPromptSubmit hooks get 5 s), then the
# write goes ahead. The key is matched literally. Fails (non-zero) when the session dir cannot be written.
meta_set() {
  mkdir -p "$SESS_DIR" 2>/dev/null || return 1
  perl -e '
    use Fcntl qw(:flock);
    my ($d, $k, $v) = @ARGV;
    open(my $l, ">>", "$d/.meta.flock") or exit 1;
    for (1 .. 200) { last if flock($l, LOCK_EX | LOCK_NB); select undef, undef, undef, 0.01 }
    my @keep;
    if (open(my $in, "<", "$d/meta")) {
      for (<$in>) { next if index($_, "$k=") == 0; $_ .= "\n" unless /\n\z/; push @keep, $_ }
      close $in;
    }
    my $tmp = "$d/.meta.$$";
    open(my $out, ">", $tmp) or exit 1;
    print $out @keep, "$k=$v\n";
    close $out and rename($tmp, "$d/meta") and exit 0;
    unlink $tmp; exit 1;
  ' "$SESS_DIR" "$1" "$2" 2>/dev/null
}

meta_get() { # file key
  sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

goal_get() { # file key : value of a `key: value` line, trailing blanks removed
  if [ -n "$1" ] && [ -f "$1" ]; then sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed 's/[[:space:]]*$//'; fi
}

secret() { # per-machine HMAC secret for release/migrate tokens
  local f="$AGENT_HOME/secret"
  if [ ! -s "$f" ]; then
    mkdir -p "$AGENT_HOME"
    ( umask 077; od -An -N32 -tx1 /dev/urandom | tr -d ' \n' >"$f" )
  fi
  cat "$f"
}

sign() { # sign a b c... -> sha256 of "a|b|c|<secret>"
  local IFS='|'
  printf '%s|%s' "$*" "$(secret)" | shasum -a 256 | cut -d' ' -f1
}

file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

# ev KIND [DATA_JSON]: append one line to $AGENT_HOME/events.jsonl, the input contract for the Phase 6
# learning loop. Uses SID NAME CWD when set. Strings in DATA are cut to 300 chars; a line over 1 KB keeps
# only {"truncated":true}. Never fails and never prints: observing must not break a hook.
ev() {
  local kind=$1 data=${2:-} line
  [ -n "$data" ] || data='{}'
  line=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "${SID:-}" --arg name "${NAME:-}" \
      --arg cwd "${CWD:-}" --arg kind "$kind" --argjson data "$data" \
      '{ts:$ts, sid:$sid, name:$name, cwd:$cwd, kind:$kind,
        data:($data | walk(if type == "string" then .[0:300] else . end))}' 2>/dev/null) || return 0
  if [ "${#line}" -gt 1024 ]; then
    line=$(printf '%s' "$line" | jq -c '.data = {truncated: true}' 2>/dev/null) || return 0
  fi
  { (umask 077; mkdir -p "$AGENT_HOME" && printf '%s\n' "$line" >>"$AGENT_HOME/events.jsonl"); } 2>/dev/null || true
  return 0
}

checkpoint_get() { # file key -> value of the first `key:` line inside the ching:checkpoint block
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    index($0, "<!-- ching:checkpoint -->") == 1 { c = 1; next }
    index($0, "<!-- /ching:checkpoint -->") == 1 { c = 0; next }
    c && index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }
  ' "$1"
}

# is_sandbox_path PATH: true for throwaway locations (test and probe sandboxes) that reports must not count:
# /tmp, /private/tmp, macOS per-user temp (/var/folders, /private/var/folders) and any task*-repo folder.
# CHING_INCLUDE_SANDBOX=1 turns the exclusion off (tests whose fixtures live under /tmp, "--all" flags).
is_sandbox_path() {
  [ -z "${CHING_INCLUDE_SANDBOX:-}" ] || return 1
  case "$1" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    */task*-repo|*/task*-repo/*) return 0 ;;
  esac
  return 1
}
