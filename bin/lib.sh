# shellcheck shell=bash
# shellcheck disable=SC2034
# lib.sh - helpers shared by the agent-terminal hooks. Sourced, never executed.
#
# Machine-wide model: every session has a record under $AGENT_HOME/sessions/<session id>/ (meta, and
# STATE.md/NEXT.md when the cwd is not a repo that opted in). A repo opts in to per-repo state by having
# <repo>/.agent/GOAL.md; then GOAL/STATE/NEXT live in <repo>/.agent/ (per worktree). Nothing here assumes
# a git repo: cwd may be ~ or a plain folder.

AGENT_HOME=${AGENT_HOME:-$HOME/.agent}
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}

# D35, D65: the kit was Ching, then Kaching, and is now Agent Terminal. A variable set under an older name (KACHING_*,
# or CHING_* from before D35) still counts when the AGENT_TERMINAL_* one is unset (launchd jobs, shells and notes from
# before the rename); KACHING_* wins over CHING_*. Scripts that check a variable before sourcing this file spell the
# fallback out themselves.
for _kp in KACHING_ CHING_; do
  for _kv in $(compgen -e); do
    case "$_kv" in "$_kp"*) _kn="AGENT_TERMINAL_${_kv#"$_kp"}"; [ -n "${!_kn+x}" ] || export "$_kn=${!_kv}" ;; esac
  done
done
unset _kp _kv _kn

jget() { # field of the hook JSON in $INPUT ('' when absent / not JSON)
  if [ -n "${INPUT:-}" ]; then printf '%s' "$INPUT" | jq -r --arg f "$1" '.[$f] // empty' 2>/dev/null || true; fi
}

name_for() { # cwd root -> short display name: repo/worktree dir, "~" for home, else the folder name
  if [ -n "$2" ]; then basename "$2"
  elif [ "$1" = "$(cd "$HOME" 2>/dev/null && pwd -P || echo "$HOME")" ]; then echo "~"
  else basename "$1"; fi
}

# sid_dir RAW: set SID_NAME to the folder under sessions/ for session id RAW. An id that could leave it ("..", "/",
# a leading dot, odd bytes, very long) becomes sid-<hash of the raw id>, stable per id and distinct from other ids.
# (A variable, not output: dash.sh calls it per live session.)
sid_dir() {
  SID_NAME=$1
  case "$1" in .*|*..*|*[!A-Za-z0-9._-]*) SID_NAME="sid-$(printf '%s' "$1" | shasum | cut -c1-16)" ;; esac
  [ "${#SID_NAME}" -le 128 ] || SID_NAME="sid-$(printf '%s' "$1" | shasum | cut -c1-16)"
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
  sid_dir "$SID"; SID=$SID_NAME
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

# meta_set key value [key value]... : single-line key=value registry for the current session. The hooks and the
# watcher write the same file, so the whole read-modify-write is one perl call holding flock on .meta.flock (perl's
# flock works on macOS, which has no flock(1)). The kernel drops the lock when its holder dies, so there are
# no stale locks. A holder that hangs is waited for 2 s at most (UserPromptSubmit hooks get 5 s), then the
# write goes ahead. The key is matched literally. Fails (non-zero) when the session dir cannot be written.
meta_set() {
  mkdir -p "$SESS_DIR" 2>/dev/null || return 1
  perl -e '
    use Fcntl qw(:flock);
    use Time::HiRes ();
    my ($d, @kv) = @ARGV;
    my @k = @kv[grep { $_ % 2 == 0 } 0 .. $#kv];
    open(my $l, ">>", "$d/.meta.flock") or exit 1;
    # a wall-clock deadline: 200 tries of 10 ms stretch past 2.7 s on a loaded machine
    my $end = Time::HiRes::time() + 2;
    until (flock($l, LOCK_EX | LOCK_NB)) { last if Time::HiRes::time() >= $end; select undef, undef, undef, 0.01 }
    my @keep;
    if (open(my $in, "<", "$d/meta")) {
      for my $l (<$in>) { next if grep { index($l, "$_=") == 0 } @k; $l .= "\n" unless $l =~ /\n\z/; push @keep, $l }
      close $in;
    }
    my $tmp = "$d/.meta.$$";
    open(my $out, ">", $tmp) or exit 1;
    print $out @keep, map { "$kv[2 * $_]=$kv[2 * $_ + 1]\n" } 0 .. $#k;
    close $out and rename($tmp, "$d/meta") and exit 0;
    unlink $tmp; exit 1;
  ' "$SESS_DIR" "$@" 2>/dev/null
}

# lock_fd9 LOCKFILE [SECS]: take an flock on LOCKFILE through fd 9 and keep it until `exec 9>&-` or the shell exits.
# perl locks the open file that this shell keeps on fd 9, so the lock outlives perl, and the kernel drops it when
# the holder dies: no stale lock to take over. Waits SECS (default 10), then fails (1). One lock per shell (fd 9);
# a child that outlives the work keeps the lock unless it is started with 9>&-.
lock_fd9() {
  { exec 9>>"$1"; } 2>/dev/null || return 1
  perl -e 'use Fcntl ":flock"; open(my $l, ">&=", 9) or exit 1;
    for (1 .. $ARGV[0] * 50) { exit 0 if flock($l, LOCK_EX | LOCK_NB); select undef, undef, undef, 0.02 } exit 1' "${2:-10}" && return 0
  exec 9>&-; return 1
}
# with_lock LOCKFILE CMD...: run CMD (a function too) holding lock_fd9 on LOCKFILE; CMD's status, 1 on timeout.
# The local has an odd name: CMD sees it (bash scoping is dynamic), and a plain `rc` hid the caller's.
with_lock() {
  local _with_lock_rc
  lock_fd9 "$1" || return 1
  shift; "$@"; _with_lock_rc=$?
  exec 9>&-; return "$_with_lock_rc"
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
# AGENT_TERMINAL_INCLUDE_SANDBOX=1 turns the exclusion off (tests whose fixtures live under /tmp, "--all" flags).
is_sandbox_path() {
  [ -z "${AGENT_TERMINAL_INCLUDE_SANDBOX:-}" ] || return 1
  case "$1" in
    /tmp|/tmp/*|/private/tmp|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    */task*-repo|*/task*-repo/*) return 0 ;;
  esac
  return 1
}

# config_get KEY [DEFAULT]: value of `KEY=value` in the machine-level config $AGENT_HOME/config (default
# ~/.agent/config). One setting per line, `#` starts a comment, blanks around the key and the value are
# ignored, the LAST assignment wins, one pair of quotes around the value is dropped. A missing or unreadable
# file, or a missing key, gives DEFAULT (empty when none). Never fails and never prints errors.
config_get() {
  local v
  v=$(sed -n 's/^[[:space:]]*'"$1"'[[:space:]]*=[[:space:]]*//p' "$AGENT_HOME/config" 2>/dev/null | tail -n 1 \
      | sed -e 's/[[:space:]]*#.*$//' -e 's/[[:space:]]*$//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\\(.*\\)'\$/\\1/") || v=""
  if [ -n "$v" ]; then printf '%s' "$v"; else printf '%s' "${2:-}"; fi
}

# push_gate_on: true only when the machine config says `push_gate=on` (case-insensitive). The release gate on a
# plain push or merge to main is OFF by default (decision D24: the owner wants automatic commits, pushes and
# merges); every repo-level setting such as GOAL.md release_mode is ignored while it is off.
push_gate_on() {
  case "$(config_get push_gate off | tr '[:upper:]' '[:lower:]')" in on) return 0 ;; *) return 1 ;; esac
}

# ---------- Phase 6 learner contracts (spec 4.1-4.4; interfaces in docs/learn-contracts.md) ----------
# The learner reads transcripts and events and writes only under $AGENT_HOME/proposals. These are the shared
# pieces every learner component codes against: one exclusion filter, one redaction, one proposal writer.
# where this file lives (learn-filter.jq and learn-redact.pl sit beside it); no subshell when sourced by absolute path,
# which every hook does
case "${BASH_SOURCE[0]}" in */*) LIB_DIR=${BASH_SOURCE[0]%/*} ;; *) LIB_DIR=. ;; esac
case "$LIB_DIR" in /*) ;; *) LIB_DIR=$(cd "$LIB_DIR" && pwd) ;; esac
PROPOSAL_KINDS="rule skill blindspot prune lesson"
PROPOSAL_COMPONENTS="corrections skills report blindspot lessons"

# learn_setting NAME: a LEARN_* setting. The environment wins, then `NAME=value` in $AGENT_HOME/config, then the
# built-in default (D26 and spec 5.6). Fails for a name that is not LEARN_*.
learn_setting() {
  case "$1" in LEARN_[A-Z]*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Z0-9_]*) return 1 ;; esac
  local def=""
  case "$1" in
    LEARN_MODEL_CLASSIFY) def=haiku ;;
    LEARN_MODEL_DRAFT) def=sonnet ;;
    LEARN_TOKEN_CAP) def=200000 ;;
    LEARN_SKILL_MAX) def=3 ;;
    LEARN_MAX_SNIPPETS) def=100 ;;
    LEARN_CALL_TIMEOUT) def=900 ;;
    LEARN_CALL_OVERHEAD) def=4000 ;;
  esac
  if [ -n "${!1:-}" ]; then printf '%s' "${!1}"; else config_get "$1" "$def"; fi
}

learn_work_dir() { printf '%s' "$AGENT_HOME/proposals/.work"; }   # the learner's cwd; never counted

# learn_redact [--jsonl]: stdin -> stdout with credentials replaced by [REDACTED] (bin/learn-redact.pl).
learn_redact() { perl "$LIB_DIR/learn-redact.pl" "$@"; }

# learn_skip_project DIR: true when a ~/.claude/projects/<dir> is skipped unread (observer runs, sandboxes, the
# learner's own .work). DIR may be a path or a bare name; only its last component is judged.
learn_skip_project() {
  local d=${1%/}
  [ "$(jq -nr --arg d "${d##*/}" --arg w "$(learn_work_dir)" -L "$LIB_DIR" \
      'include "learn-filter"; $d | learn_project_excluded($w)' 2>/dev/null)" = true ]
}

# learn_filter MODE FILE...: print the lines that count, compact JSON, one per line, in file order.
#   prompts  counted human prompts (learn_human_prompt)        - transcripts
#   lines    user/assistant lines of countable sessions        - transcripts (tool calls for the miner)
#   events   countable events.jsonl lines (learn_event_ok)      - events files
# Transcript files in a skipped project directory are not read. Malformed lines are skipped; a missing file is
# skipped. Exit 0, or 2 for an unknown MODE. The defs live in bin/learn-filter.jq.
learn_filter() {
  local mode=$1 sel f dirs lf_files=() lf_keep=()
  shift
  # shellcheck disable=SC2016 # $work is a jq variable, not a shell one
  case "$mode" in
    prompts) sel='learn_human_prompt($work)' ;;
    lines) sel='learn_session_ok($work)' ;;
    events) sel='learn_event_ok($work)' ;;
    *) echo "learn_filter: unknown mode '$mode' (prompts|lines|events)" >&2; return 2 ;;
  esac
  for f in "$@"; do [ -f "$f" ] && lf_files+=("$f"); done
  [ "${#lf_files[@]}" -gt 0 ] || return 0
  if [ "$mode" != events ]; then
    # one jq call judges every project directory; files under a skipped one drop out
    dirs=$(for f in "${lf_files[@]}"; do d=$(dirname "$f"); printf '%s\n' "${d##*/}"; done | sort -u \
      | jq -Rr --arg w "$(learn_work_dir)" -L "$LIB_DIR" 'include "learn-filter"; select(learn_project_excluded($w))')
    if [ -n "$dirs" ]; then
      local d
      for f in "${lf_files[@]}"; do
        d=$(dirname "$f"); d=${d##*/}
        printf '%s\n' "$dirs" | grep -qxF -- "$d" || lf_keep+=("$f")
      done
      [ "${#lf_keep[@]}" -gt 0 ] || return 0
      lf_files=("${lf_keep[@]}")
    fi
  fi
  # perl ends every file with a newline, so the last line of one file never runs into the next
  perl -ne 'print; print "\n" unless /\n\z/' "${lf_files[@]}" \
    | jq -R -c --arg work "$(learn_work_dir)" -L "$LIB_DIR" "include \"learn-filter\"; fromjson? // empty | select($sel)"
}

# proposal_fingerprint TEXT: sha1 of the normalised pattern (lower case, blanks squeezed and trimmed). Every
# component fingerprints its normalised pattern (rule) or token sequence (skill, joined with " > ") with this.
proposal_fingerprint() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -s '[:space:]' ' ' | sed 's/^ //; s/ $//' | shasum | cut -c1-40
}

# proposal_slug TEXT: a file-name slug: lower case, runs of other characters -> "-", at most 50 characters.
proposal_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9][^a-z0-9]*/-/g; s/^-//' | cut -c1-50 | sed 's/-*$//'
}

# proposal_get FILE KEY: value of a header line (the lines before the first blank line).
proposal_get() {
  [ -f "$1" ] || return 0
  awk -v k="$2" '$0 == "" { exit } index($0, k ": ") == 1 { print substr($0, length(k) + 3); exit }' "$1"
}

# proposal_section FILE NAME: the body of "## NAME", without the blank lines around it.
proposal_section() {
  [ -f "$1" ] || return 0
  awk -v h="## $2" '
    $0 == h { on = 1; next }
    on && index($0, "## ") == 1 { exit }
    on { if ($0 == "" && !seen) next; seen = 1; buf = buf $0 "\n"; if ($0 != "") { out = out buf; buf = "" } }
    END { printf "%s", out }' "$1"
}

# proposal_patch FILE: the raw unified diff of a rule proposal (the ```diff fence removed).
proposal_patch() {
  proposal_section "$1" patch | sed '1{/^```diff$/d;}' | sed '${/^```$/d;}'
}

# proposals_root: make $AGENT_HOME/proposals (mode 0700, tightened when it exists) and print its canonical path.
# Refuses (exit 3) when it is a symlink: a planted link would send the learner's writes elsewhere.
proposals_root() {
  local home root
  ( umask 077; mkdir -p "$AGENT_HOME" ) 2>/dev/null
  home=$(cd "$AGENT_HOME" 2>/dev/null && pwd -P) || { echo "proposals: cannot reach AGENT_HOME $AGENT_HOME" >&2; return 3; }
  root=$home/proposals
  if [ -L "$root" ]; then echo "proposals: $root is a symlink; refusing to write through it" >&2; return 3; fi
  ( umask 077; mkdir -p "$root" ) 2>/dev/null
  if [ ! -d "$root" ] || [ -L "$root" ] || ! chmod 700 "$root" 2>/dev/null; then
    echo "proposals: cannot use $root" >&2; return 3
  fi
  printf '%s' "$root"
}

# proposal_safe_path PATH: print the absolute path PATH names inside the proposals root, or fail (exit 3).
# PATH is relative to the root, or absolute and inside it (spelled through $AGENT_HOME or canonically). Refused:
# empty, a "." or ".." component, anything outside the root, the root itself, a symlink anywhere below the root,
# an existing directory at PATH. Missing parent directories are made with mode 0700. Every learner write under
# proposals/ (.work extracts, the weekly report) goes through this; proposal files go through proposal_write.
proposal_safe_path() {
  local p=$1 root lit rel cur part base
  root=$(proposals_root) || return 3
  case "$p" in ""|*$'\n'*) echo "proposals: empty or multi-line path refused" >&2; return 3 ;; esac
  case "/$p/" in */../*|*/./*) echo "proposals: '.' or '..' in a path is refused: $p" >&2; return 3 ;; esac
  lit=${AGENT_HOME%/}/proposals
  case "$p" in
    "$root"/*) rel=${p#"$root"/} ;;
    "$lit"/*) rel=${p#"$lit"/} ;;
    /*) echo "proposals: $p is outside $root" >&2; return 3 ;;
    *) rel=$p ;;
  esac
  rel=$(printf '%s' "$rel" | tr -s /); rel=${rel#/}; rel=${rel%/}
  [ -n "$rel" ] || { echo "proposals: the root itself is not a file" >&2; return 3; }
  base=${rel##*/}
  cur=$root
  while [ "$rel" != "$base" ]; do
    part=${rel%%/*}; rel=${rel#*/}
    cur=$cur/$part
    if [ -L "$cur" ]; then echo "proposals: $cur is a symlink; refused" >&2; return 3; fi
    if [ ! -e "$cur" ]; then ( umask 077; mkdir "$cur" ) || return 3
    elif [ ! -d "$cur" ]; then echo "proposals: $cur is not a directory" >&2; return 3; fi
  done
  cur=$cur/$base
  if [ -L "$cur" ] || [ -d "$cur" ]; then echo "proposals: $cur is a symlink or a directory; refused" >&2; return 3; fi
  printf '%s' "$cur"
}

# proposal_status_of_fp ROOT FP: how an existing proposal with fingerprint FP stands, as "<state> <file>":
# open (a file at the top of ROOT; an expired snooze there counts as open), approved / rejected / snoozed (a
# decided file in ROOT/archive, or a future snooze anywhere). Prints nothing when no file has FP.
proposal_status_of_fp() {
  local root=$1 fp=$2 f st today open=""
  today=$(date +%Y-%m-%d)
  for f in "$root"/*.md "$root"/archive/*.md; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(proposal_get "$f" fingerprint)" = "$fp" ] || continue
    st=$(proposal_get "$f" status)
    case "$st" in
      approved|rejected) [ "${f%/*}" = "$root/archive" ] && { printf '%s %s' "$st" "$f"; return 0; } ;;
      snoozed:*) if [[ "${st#snoozed:}" > "$today" ]]; then printf 'snoozed %s' "$f"; return 0; fi ;;
    esac
    [ "${f%/*}" = "$root" ] && [ -z "$open" ] && open=$f
  done
  [ -z "$open" ] || printf 'open %s' "$open"
}

# _proposal_text JSON KEY: a free-text field. A "## " line inside it would end its section early: demoted to "### ".
# (?m) makes ^ match at every line start in jq regexes.
_proposal_text() { printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // "" | gsub("(?m)^## "; "### ")'; }

# proposal_write PATH < JSON: the ONLY writer of proposal files (spec 4.2). PATH is "<kind>-<slug>.md" at the top
# of $AGENT_HOME/proposals (relative, or absolute inside it). JSON on stdin:
#   {component, fingerprint (40 hex, from proposal_fingerprint), sessions, days, target, proposal,
#    evidence: [{sid, day: "YYYY-MM-DD", cwd, quote}], patch (rule only, required), why_not_covered
#    (required for rule and skill), kind (optional; must match PATH)}
# Every string is redacted (learn_redact) before it is written; quotes are then cut to 300 characters.
# Prints one line and exits 0:  written <file> | refreshed <file> | skipped rejected|approved|snoozed <fp>
#   refreshed: an open proposal already has this fingerprint (under any slug); its sessions, days and evidence
#   are replaced, everything else (id, created, proposal, patch, why) is kept, and PATH is not used.
#   skipped: the fingerprint is in rejected.txt (first field of a line), or an archived proposal with it was
#   approved or rejected, or is snoozed until a later date.
# Fails: 2 bad input, 3 unsafe path, 4 PATH already holds a different fingerprint, 1 write error.
proposal_write() {
  local abs root base id kind slug json err fp st prev cur sessions days evidence tmp
  root=$(proposals_root) || return 3
  abs=$(proposal_safe_path "${1:-}") || return 3
  base=${abs##*/}
  if [ "$abs" != "$root/$base" ]; then echo "proposal_write: proposals sit at the top of $root: ${1:-}" >&2; return 3; fi
  id=${base%.md}
  [ "$id.md" = "$base" ] || { echo "proposal_write: the file name must end in .md: $base" >&2; return 2; }
  kind=${id%%-*}; slug=${id#*-}
  case " $PROPOSAL_KINDS " in *" $kind "*) ;; *) echo "proposal_write: unknown kind '$kind' ($PROPOSAL_KINDS)" >&2; return 2 ;; esac
  if [ "$slug" = "$id" ] || ! [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || [ "${#id}" -gt 80 ]; then
    echo "proposal_write: '$id' is not <kind>-<slug> (lower-case letters, digits, single dashes, at most 80 characters)" >&2; return 2
  fi
  json=$(jq -c . 2>/dev/null) || { echo "proposal_write: stdin is not JSON" >&2; return 2; }
  # control characters never reach a header or evidence line: a newline in a sid would start a line (or a "## "
  # section) of its own, an escape sequence would play in a terminal. Runs become one space; a sid loses them
  # (and blanks) outright, so it stays one word. A non-object is left for the checks below to refuse.
  json=$(printf '%s' "$json" | jq -c '
    def clean: if type == "string" then gsub("[[:cntrl:]]+"; " ") else . end;
    if type == "object" then
      (if has("target") and (.target | type) == "string" and (.target | test("\n") | not) then .target |= clean else . end)
      | (if (.evidence | type) == "array" then .evidence |= map(if type == "object" then
          (if (.sid | type) == "string" then .sid |= gsub("[[:cntrl:][:space:]]+"; "") else . end)
          | (if has("cwd") then .cwd |= clean else . end) | (if has("quote") then .quote |= clean else . end)
        else . end) else . end)
    else . end' 2>/dev/null) || { echo "proposal_write: stdin is not JSON" >&2; return 2; }
  err=$(printf '%s' "$json" | jq -r --arg kind "$kind" --arg comps "$PROPOSAL_COMPONENTS" '
    def str($k): (.[$k] | type) == "string" and (.[$k] | test("\\S"));
    def nat($k): (.[$k] | type) == "number" and .[$k] >= 0 and .[$k] == (.[$k] | floor);
    # a unified diff line: a header, a hunk, context, +, -, "\ No newline", or blank (a context line some tools strip)
    def badline: [.patch | split("\n")[] | select(test("^(--- |\\+\\+\\+ |@@ |[ +\\-\\\\]|$|diff |index |(new|deleted) file mode |old mode |new mode |similarity index |rename (from|to) )") | not)] | first;
    if type != "object" then "not a JSON object"
    elif has("kind") and .kind != $kind then "kind \(.kind) does not match the file name (\($kind))"
    elif (.fingerprint | type) != "string" or (.fingerprint | test("^[0-9a-f]{40}$") | not) then "fingerprint must be 40 lower-case hex (proposal_fingerprint)"
    elif (.component | type) != "string" or (.component as $c | $comps | split(" ") | any(. == $c) | not) then "component must be one of: \($comps)"
    elif (nat("sessions") and nat("days")) | not then "sessions and days must be whole numbers"
    elif str("target") | not then "target is required"
    elif (.target | test("\n")) then "target must be one line"
    elif str("proposal") | not then "proposal text is required"
    elif (.evidence | type) != "array" then "evidence must be an array"
    elif any(.evidence[]; (type != "object") or ((.sid | type) != "string") or (.sid == "") or ((.day | type) != "string") or (.day | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") | not)) then "every evidence item needs sid and day (YYYY-MM-DD)"
    elif $kind == "rule" and (str("patch") | not) then "a rule needs a patch (unified diff)"
    elif has("patch") and (.patch | type) == "string" and (.patch | split("\n") | index(["```"]) != null) then "a patch line cannot be a bare ``` fence"
    elif $kind == "rule" and (badline != null) then "the patch must be a unified diff (headers, @@, context, + and - lines only); this line is not: \(badline | .[0:80])"
    elif $kind == "rule" and ((.patch | test("(?m)^--- ")) and (.patch | test("(?m)^\\+\\+\\+ ")) and (.patch | test("(?m)^@@ ")) | not) then "the patch must be a unified diff with ---, +++ and @@ lines"
    elif ($kind == "rule" or $kind == "skill") and (str("why_not_covered") | not) then "why_not_covered is required for \($kind)"
    else "" end' 2>/dev/null) || err="unreadable input"
  [ -z "$err" ] || { echo "proposal_write: $err" >&2; return 2; }
  json=$(printf '%s\n' "$json" | learn_redact --jsonl) || return 1
  fp=$(printf '%s' "$json" | jq -r .fingerprint)

  if [ -f "$root/rejected.txt" ] && awk -v f="$fp" '$1 == f { found = 1 } END { exit !found }' "$root/rejected.txt"; then
    echo "skipped rejected $fp"; return 0
  fi
  st=$(proposal_status_of_fp "$root" "$fp")
  case "$st" in
    approved*|rejected*|snoozed*) echo "skipped ${st%% *} $fp"; return 0 ;;
  esac
  sessions=$(printf '%s' "$json" | jq -r .sessions)
  days=$(printf '%s' "$json" | jq -r .days)
  evidence=$(printf '%s' "$json" | jq -r '
    if (.evidence | length) == 0 then "- (none)" else
    .evidence[] | "- \(.sid[0:8]) \(.day) \((.cwd // "-") | gsub("[[:cntrl:]]+"; " ") | if . == "" then "-" else . end) \"\((.quote // "") | gsub("[[:cntrl:]]+"; " ") | .[0:300])\""
    end')

  if [ "${st%% *}" = open ]; then
    prev=${st#open }; abs=$prev
    cur=$(
      printf 'id: %s\nkind: %s\nstatus: open\ncreated: %s\ncomponent: %s\nfingerprint: %s\nsessions: %s\ndays: %s\ntarget: %s\n' \
        "$(proposal_get "$prev" id)" "$(proposal_get "$prev" kind)" "$(proposal_get "$prev" created)" \
        "$(proposal_get "$prev" component)" "$fp" "$sessions" "$days" "$(proposal_get "$prev" target)"
      printf '\n## proposal\n%s\n\n## evidence\n%s\n' "$(proposal_section "$prev" proposal)" "$evidence"
      if grep -qx '## patch' "$prev"; then printf '\n## patch\n%s\n' "$(proposal_section "$prev" patch)"; fi
      printf '\n## why this is not already covered\n%s\n' "$(proposal_section "$prev" 'why this is not already covered')"
    )
    st=refreshed
  else
    if [ -e "$abs" ]; then echo "proposal_write: $abs already holds another fingerprint; pick another slug" >&2; return 4; fi
    cur=$(
      printf 'id: %s\nkind: %s\nstatus: open\ncreated: %s\ncomponent: %s\nfingerprint: %s\nsessions: %s\ndays: %s\ntarget: %s\n' \
        "$id" "$kind" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$json" | jq -r .component)" "$fp" "$sessions" "$days" \
        "$(printf '%s' "$json" | jq -r .target)"
      printf '\n## proposal\n%s\n\n## evidence\n%s\n' "$(_proposal_text "$json" proposal)" "$evidence"
      # shellcheck disable=SC2016 # a markdown fence, not a command substitution
      if [ "$kind" = rule ]; then printf '\n## patch\n```diff\n%s\n```\n' "$(printf '%s' "$json" | jq -r .patch)"; fi
      printf '\n## why this is not already covered\n%s\n' "$(_proposal_text "$json" why_not_covered | sed '1s/^$/not applicable/')"
    )
    st=written
  fi
  # write beside the target and rename over it: a reader never sees half a file, and a rename replaces a link
  # itself rather than writing through it (links were refused above anyway)
  tmp="$root/.${abs##*/}.tmp.$$"
  if ! ( umask 077; set -C; printf '%s\n' "$cur" >"$tmp" ) 2>/dev/null || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$abs"; then
    rm -f "$tmp"; echo "proposal_write: cannot write $abs" >&2; return 1
  fi
  echo "$st $abs"
}

# _learn_limited SECS CMD...: run CMD in a process group of its own; after SECS the whole group gets TERM, then
# KILL, and the exit code is 142. A trimmed copy of test-escalate.sh run_limited; a hung `claude` must not hold the
# nightly job, nor its children the pipe. The watchdog itself, sent TERM, INT or HUP (launchd stopping the job,
# learn.sh's own signal trap), does the same to the group before it exits 128+signal: CMD never outlives it. The
# group gets up to 3 s after TERM, so a nested watchdog (learn.sh > component > learn_model_call > claude) can stop
# its own group first. learn.sh runs the program text directly (exec perl -e "$_LEARN_LIMITED_PL") so the pid it
# signals is the watchdog's.
# shellcheck disable=SC2016 # perl source, not shell
_LEARN_LIMITED_PL='
  use POSIX ":sys_wait_h";
  my $t = shift @ARGV;
  my $pid = fork;
  defined $pid or exit 1;
  if (!$pid) { setpgrp(0, 0); $SIG{$_} = "DEFAULT" for qw(TERM INT HUP); exec { $ARGV[0] } @ARGV; POSIX::_exit(127); }
  sub stop {
    my $code = shift;
    kill "TERM", -$pid; kill "TERM", $pid;
    for (1 .. 30) { waitpid($pid, WNOHANG); last unless kill 0, -$pid; select undef, undef, undef, 0.1; }
    kill "KILL", -$pid; waitpid($pid, 0); exit $code;
  }
  $SIG{ALRM} = sub { stop(142) };
  $SIG{TERM} = sub { stop(143) }; $SIG{INT} = sub { stop(130) }; $SIG{HUP} = sub { stop(129) };
  alarm $t if $t > 0;
  waitpid($pid, 0);
  exit($? & 127 ? 128 + ($? & 127) : $? >> 8);
'
_learn_limited() { perl -e "$_LEARN_LIMITED_PL" "$@"; }

# learn_estimate_tokens < TEXT: what a learn_model_call with TEXT as its prompt is expected to cost, in tokens:
# the bytes / 2.4, rounded up (JSON snippets tokenise at about 2.4 bytes per token, measured 2026-10-17), plus a
# quarter of that for the answer and its thinking, plus LEARN_CALL_OVERHEAD (default 4000: about 2.7k tokens of
# fixed prompt per call, measured live on 2026-10-17 with the isolation flags below). An estimate: a call may still
# overshoot it, by up to about a quarter of its own size in the worst case measured.
learn_estimate_tokens() {
  local bytes ovh
  bytes=$(wc -c | tr -d ' ')
  ovh=$(learn_setting LEARN_CALL_OVERHEAD); case "$ovh" in ''|*[!0-9]*) ovh=4000 ;; esac
  local inp=$(( (bytes * 5 + 11) / 12 ))
  printf '%s\n' $(( inp + inp / 4 + ovh ))
}

# learn_budget_left: the tokens left today under LEARN_TOKEN_CAP (never below 0). A component that batches its
# input sizes the batch so that learn_estimate_tokens of the prompt fits this; learn_model_call refuses (exit 5) a
# call whose estimate does not fit. Read without the lock: a hint, the refusal is the check.
learn_budget_left() {
  local cap used
  cap=$(learn_setting LEARN_TOKEN_CAP); case "$cap" in ''|*[!0-9]*) cap=200000 ;; esac
  used=$(cat "$(learn_work_dir)/tokens-$(date +%Y-%m-%d)" 2>/dev/null || true); used=${used%%[!0-9]*}
  [ -n "$used" ] || used=0
  if [ "$used" -ge "$cap" ]; then echo 0; else echo $((cap - used)); fi
}

# _learn_tokens_add FILE LOCK DELTA [CAP]: add DELTA (may be negative) to the day total in FILE, holding an flock
# on LOCK, and print the new total. With CAP: refuse (exit 5, print the total unchanged) when the total is already
# at CAP or the sum would pass it. Exit 3 when the files cannot be used.
_learn_tokens_add() {
  ( umask 077; perl -e '
    use Fcntl ":flock";
    my ($f, $lk, $d, $cap) = @ARGV;
    open(my $l, ">>", $lk) or exit 3;
    flock($l, LOCK_EX) or exit 3;
    my $u = 0;
    if (open(my $h, "<", $f)) { my $x = <$h>; $u = $1 if defined $x && $x =~ /^(\d+)/; close $h; }
    if (defined $cap && $cap ne "" && ($u >= $cap || $u + $d > $cap)) { print "$u\n"; exit 5; }
    my $n = $u + $d; $n = 0 if $n < 0;
    my $tmp = "$f.tmp.$$";
    open(my $o, ">", $tmp) or exit 3; print $o "$n\n"; close $o or exit 3;
    rename($tmp, $f) or exit 3;
    print "$n\n";
  ' "$@" )
}

# learn_model_call MODEL < PROMPT: the learner's one way to call a model (spec 5.6). Runs
#   "${AGENT_TERMINAL_CLAUDE_BIN:-claude}" -p --model MODEL --tools "" --output-format json --strict-mcp-config
#     --disable-slash-commands --no-session-persistence --setting-sources "" --settings <LEARN_CALL_SETTINGS>
# with the prompt on stdin, in $(learn_work_dir), with AGENT_TERMINAL_LEARNER=1 (guard learner mode) and
# CLAUDE_MEM_INTERNAL=1 (claude-mem does not observe the run, D27), cut after LEARN_CALL_TIMEOUT seconds. Prints
# the model's answer: the one JSON document in the envelope's .result, compact, a ```json fence removed.
# Isolation, checked live on 2026-10-17 (claude 2.1.302, stream-json init message):
#   --tools "" only removes the built-in tools: the run still had every MCP server (Gmail send, Drive share, ...)
#   and its prompt cost 211k cache-creation tokens. --strict-mcp-config (no MCP servers) and
#   --disable-slash-commands (no skills) leave tools [] and mcp_servers [].
#   The owner's hooks still ran on every call (Agent Terminal's session-start/stop-check/notify, a "Session finished" popup,
#   the remember plugin's SessionEnd summarizer). --setting-sources "" loads no user, project or local settings, so
#   no user hooks and no plugins (only the built-in cc-plugin-* ones; no hook fired); auth is unchanged (OAuth from
#   the keychain, HOME stays real). --settings then adds back one hook, guard.sh in learner mode for every tool, so
#   the guard stays the second layer (there are no tools for it to see), and turns auto-memory off (else an empty
#   ~/.claude/projects/<.work>/memory is made). --no-session-persistence: no transcript under ~/.claude/projects.
#   With all of it a call costs about 2.7k tokens before the prompt's own.
# Budget: the call's learn_estimate_tokens is reserved in .work/tokens-<local YYYY-MM-DD> before it starts and
# replaced by every token the envelope reports (input, output, cache read, cache creation) after it, each under an
# flock on .work/tokens.lock. When the reservation does not fit under LEARN_TOKEN_CAP no call starts. Each call
# adds one line to .work/learn.log (claude's stderr goes there too).
# Exit: 0 ok | 1 the call failed, timed out, or gave no success envelope | 2 the answer is not one JSON document |
#       3 .work cannot be used | 5 capped (the estimate does not fit what is left today), no call made |
#       64 no MODEL.
learn_model_call() {
  local model=${1:-} tokf logf lockf work cap lim est total out rc tok res pf settings
  [ -n "$model" ] || { echo "learn_model_call: no model given" >&2; return 64; }
  tokf=$(proposal_safe_path ".work/tokens-$(date +%Y-%m-%d)") || return 3
  logf=$(proposal_safe_path .work/learn.log) || return 3
  lockf=$(proposal_safe_path .work/tokens.lock) || return 3
  work=${tokf%/*}
  cap=$(learn_setting LEARN_TOKEN_CAP); case "$cap" in ''|*[!0-9]*) cap=200000 ;; esac
  lim=$(learn_setting LEARN_CALL_TIMEOUT); case "$lim" in ''|*[!0-9]*) lim=900 ;; esac
  pf=$(umask 077; mktemp "$work/.prompt.XXXXXX") || return 3
  cat >"$pf" || { rm -f "$pf"; return 3; }
  est=$(learn_estimate_tokens <"$pf")
  rc=0; total=$(_learn_tokens_add "$tokf" "$lockf" "$est" "$cap") || rc=$?
  if [ "$rc" -ne 0 ]; then
    rm -f "$pf"
    [ "$rc" -eq 5 ] || { echo "learn_model_call: cannot update $tokf" >&2; return 3; }
    { (umask 077; printf '%s model=%s rc=capped tokens=0 estimate=%s day_total=%s cap=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model" "$est" "$total" "$cap" >>"$logf"); } 2>/dev/null
    return 5
  fi
  settings=$(jq -nc --arg g "$(printf '%q' "$LIB_DIR/guard.sh")" \
    '{autoMemoryEnabled: false, hooks: {PreToolUse: [{matcher: "*", hooks: [{type: "command", command: $g, timeout: 15}]}]}}')
  out=$(cd "$work" && AGENT_TERMINAL_LEARNER=1 CLAUDE_MEM_INTERNAL=1 _learn_limited "$lim" \
        "${AGENT_TERMINAL_CLAUDE_BIN:-claude}" -p --model "$model" --tools "" --output-format json \
        --strict-mcp-config --disable-slash-commands --no-session-persistence \
        --setting-sources "" --settings "$settings" <"$pf" 2>>"$logf"); rc=$?
  rm -f "$pf"
  tok=$(printf '%s' "$out" | jq -r '[.usage.input_tokens, .usage.output_tokens, .usage.cache_read_input_tokens,
        .usage.cache_creation_input_tokens] | map(. // 0) | add' 2>/dev/null) || tok=0
  case "$tok" in ''|*[!0-9]*) tok=0 ;; esac
  total=$(_learn_tokens_add "$tokf" "$lockf" $((tok - est))) || total="?"
  { (umask 077; printf '%s model=%s rc=%s tokens=%s day_total=%s estimate=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$model" "$rc" "$tok" "$total" "$est" >>"$logf"); } 2>/dev/null
  if [ "$rc" -ne 0 ] || [ "$(printf '%s' "$out" | jq -r '.is_error' 2>/dev/null)" != false ]; then
    echo "learn_model_call: the call failed (exit $rc)" >&2; return 1
  fi
  res=$(printf '%s' "$out" | jq -r '.result // empty' 2>/dev/null \
        | sed -e '1{/^[[:space:]]*```[A-Za-z]*[[:space:]]*$/d;}' | sed -e '${/^[[:space:]]*```[[:space:]]*$/d;}')
  res=$(printf '%s' "$res" | jq -s -c 'if length == 1 then .[0] else error("not one document") end' 2>/dev/null) || res=""
  [ -n "$res" ] || { echo "learn_model_call: the answer is not one JSON document" >&2; return 2; }
  printf '%s\n' "$res"
}
