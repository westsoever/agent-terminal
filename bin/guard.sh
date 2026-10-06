#!/usr/bin/env bash
# guard.sh - PreToolUse hook: hard guardrails for every session on this machine (PLAN 5.1).
#
# Reads the hook JSON on stdin; prints a deny decision
#   {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":...}}
# (exit 0, schema confirmed in Phase 0) or allows silently. Fails CLOSED: an internal error blocks the
# call (exit 2 + stderr).
#
# This is the first of two layers. The second is the git pre-push hook (templates/pre-push), because a
# regex over a command string cannot see through every shell trick; this script therefore also denies
# anything whose push target it cannot resolve literally.
#
# Rules: 1 rm -rf outside the repo//tmp | 2 force push | 3 push to main/default without release token for
# the pushed commit | 4 vercel deploy, gh workflow run | 5 reading .env*, printing secrets | 6 Supabase
# apply_migration / non-read-only execute_sql / Management API / CLI db push | 7 editing a committed
# migration, db-migrate --record-only, --apply without a migrate token | 8 publishing (npm/bun/pnpm/yarn
# publish, gh release, gh repo delete/visibility/public, pushing a v* tag or all tags, tags/releases through
# gh api) | 9 closing PRs/issues | 10 sending email/chat
# (drafts only) | 11 gate settings in GOAL.md (review, release_mode, test_command). Extras: --no-verify,
# hook/settings/token tampering, gh pr merge, piping into a shell.
# The Monitor tool (it runs a shell command) goes through the Bash rules. A missing dependency, a failing
# splitter, a deny that cannot be printed, or a command that takes more than 8 s to check all fail closed.
# Every deny is also logged as a `deny` event, after the decision has been printed.
# Env: GUARD_PROTECTED_BRANCHES (default "main master" plus the remote default branch);
#      GUARD_TIME_LIMIT (seconds; can only lower the 8 s ceiling, for the tests)
set -euo pipefail

# The time ceiling counts from here. An inherited SECONDS (the hook environment) would otherwise start the clock
# late and deny every call. GUARD_TIME_LIMIT can only LOWER the 8 s limit (it is how the tests reach the ceiling).
SECONDS=0
TIME_LIMIT=8
case "${GUARD_TIME_LIMIT:-}" in ''|*[!0-9]*) ;; *) if [ "$GUARD_TIME_LIMIT" -lt 8 ]; then TIME_LIMIT=$GUARD_TIME_LIMIT; fi ;; esac
PROTECTED=${GUARD_PROTECTED_BRANCHES:-"main master"}
DEFB=""

# Every external tool the guard needs: a missing one must fail CLOSED (a missing sed used to leave the splitter
# with no segments, and every command was allowed).
for dep in jq dirname sed awk perl git tr grep sort wc head; do
  command -v "$dep" >/dev/null 2>&1 || { echo "GUARD: $dep is not installed; failing closed" >&2; exit 2; }
done
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
INPUT=$(cat)
DECIDED=0

emit_deny() {
  # The reason can carry attacker-shaped text (a 1 MB token makes jq fail with "Argument list too long"): cap it.
  local reason=$1
  if [ "${#reason}" -gt 500 ]; then reason="${reason:0:500}..."; fi
  # DECIDED only after the decision was printed; if it cannot be printed, exit 2 (a blocking error).
  if ! jq -n --arg r "GUARD: $reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; then
    echo "GUARD: could not print the deny decision; failing closed" >&2
    exit 2
  fi
  DECIDED=1
  # The decision is printed first; logging it can never change it.
  ( SID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null || true); CWD=${CWD:-$PWD}; NAME=$(basename "$CWD")
    # shellcheck source=lib.sh
    . "$SELF_DIR/lib.sh" && ev deny "$(jq -nc --arg r "$reason" --arg t "${TOOL:-}" '{rule:$r,tool:$t}')" ) >/dev/null 2>&1 || true
  exit 0
}
ceiling() { # a fail-closed time ceiling: the hook has 15 s, and a timed-out hook lets the call through
  if [ "$SECONDS" -ge "$TIME_LIMIT" ]; then emit_deny "command too large to check safely (took too long). Split it into smaller commands."; fi
}
allow() { DECIDED=1; exit 0; }
# shellcheck disable=SC2329
on_exit() {
  local rc=$?
  if [ "$DECIDED" -eq 0 ] && [ "$rc" -ne 0 ]; then
    echo "GUARD: internal error (exit $rc); failing closed. Ask the user." >&2
    exit 2
  fi
}
trap on_exit EXIT

TOOL=$(jq -r '.tool_name // ""' <<<"$INPUT")
TOOL_LC=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
CWD=$(jq -r '.cwd // ""' <<<"$INPUT")
[ -n "$CWD" ] || CWD=$PWD

# ---------- path helpers ----------
phys_dir() { ( cd "$1" 2>/dev/null && pwd -P ) || echo "$1"; }

resolve_path() { # path base -> absolute, physical (existing ancestor resolved), no trailing slash
  local p=$1 base=$2 out="" part oldifs d tail=""
  # shellcheck disable=SC2088
  case "$p" in
    "~") p=$HOME ;;
    "~/"*) p="$HOME/${p#"~/"}" ;;
  esac
  case "$p" in /*) ;; *) p="$base/$p" ;; esac
  oldifs=$IFS; IFS=/; set -f
  for part in $p; do
    case "$part" in ""|".") ;; "..") out=${out%/*} ;; *) out="$out/$part" ;; esac
  done
  set +f; IFS=$oldifs
  [ -n "$out" ] || out=/
  d=$out
  while [ "$d" != "/" ] && [ ! -d "$d" ]; do
    tail="/${d##*/}$tail"; d=${d%/*}; [ -n "$d" ] || d=/
  done
  if [ "$d" = "/" ]; then echo "${tail:-/}"; else echo "$(cd "$d" && pwd -P)$tail"; fi
}

CWD_PHYS=$(phys_dir "$CWD")
ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || ROOT=$CWD_PHYS
ROOT=$(phys_dir "$ROOT")

is_safe_delete_target() {
  local p=$1 tmp
  [ "$p" != "$ROOT" ] || return 1
  [ "$p" != "$ROOT/.git" ] || return 1
  case "$p" in "$ROOT"/*) return 0 ;; esac
  case "$p" in /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;; esac
  if [ -n "${TMPDIR:-}" ]; then
    tmp=$(phys_dir "${TMPDIR%/}")
    case "$p" in "$tmp"/*) return 0 ;; esac
  fi
  return 1
}

is_protected() { # branch name
  local b=$1 p
  [ -n "$b" ] || return 1
  for p in $PROTECTED $DEFB; do [ "$b" != "$p" ] || return 0; done
  return 1
}

# ---------- tokenising ----------
declare -a TOKS=()
NT=0
SIM_CWD=$CWD_PHYS
SIM_UNKNOWN=0
WRAPPERS=" sudo env command exec time nohup nice ionice xargs timeout watch caffeinate npx bunx bun pnpm yarn npm dlx x run exec bash sh zsh eval then do else if while until ! { parallel doppler dotenv direnv volta mise op "
CP_LIMIT=0   # index of the command word of the current segment (see compute_cmd_limit)
BASE=""

base_of() { # sets BASE to the basename of $1. ${t##*/} is quadratic in the token length on bash 3.2 (a 100 KB
  # token took 16 s), so a very long token, which is never a command word, is cut to its last 512 characters first.
  if [ "${#1}" -gt 512 ]; then BASE=${1: -512}; BASE=${BASE##*/}; else BASE=${1##*/}; fi
}

value_opt() { # wrapper, option -> 0 when the option takes a separate value word (that word is not the command)
  case "$1" in
    xargs) case "$2" in -I|-J|-a|-d|-E|-L|-n|-P|-R|-S|-s) return 0 ;; esac ;;
    sudo) case "$2" in -u|-g|-p|-C|-D|-R|-r|-t|-U) return 0 ;; esac ;;
    env) case "$2" in -u|-C|-P) return 0 ;; esac ;;
    timeout) case "$2" in -s|-k) return 0 ;; esac ;;
    npx|bunx) case "$2" in -p) return 0 ;; esac ;;
    exec) case "$2" in -a) return 0 ;; esac ;;
  esac
  return 1
}

compute_cmd_limit() { # CP_LIMIT = index of the command word: the first token that is not a wrapper, an option
  # (or an option's value word), an assignment or a redirection. Linear, computed once per segment.
  local k=0 t w="" skip=0
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}
    if [ "$skip" -eq 1 ]; then skip=0; k=$((k + 1)); continue; fi
    case "$t" in
      "<"*|">"*|"&>"*|[0-9]"<"*|[0-9]">"*)   # a redirection; a bare '>' / '>>' / '2>' takes the next word as its target
        if [ -z "${t//[0-9<>&]/}" ]; then skip=1; fi ;;
      -*) if [ -n "$w" ] && value_opt "$w" "$t"; then skip=1; fi ;;
      *=*|[0-9]*) ;;
      *) base_of "$t"
         case "$WRAPPERS" in *" $BASE "*) w=$BASE ;; *) break ;; esac ;;
    esac
    k=$((k + 1))
  done
  CP_LIMIT=$k
}

tokenize() {
  local s=$1
  if [ "${#s}" -gt 2048 ]; then
    # ${s//x/} is far worse than linear on bash 3.2 (10000 quote characters: 39 s, and bash cannot be interrupted
    # inside it), so a long segment is cleaned by tr, which is the same three deletions
    s=$(printf '%s' "$s" | tr -d "\"'\\\\")
  else
    s=${s//\"/}; s=${s//\'/}; s=${s//\\/}
  fi
  TOKS=()
  read -r -a TOKS <<<"$s" || true
  NT=${#TOKS[@]}
  compute_cmd_limit
}

cmd_pos() { [ "$1" -le "$CP_LIMIT" ]; }   # is token index $1 in command position?

has_token() { # exact basename match anywhere
  local k=0
  while [ "$k" -lt "$NT" ]; do base_of "${TOKS[$k]}"; [ "$BASE" != "$1" ] || return 0; k=$((k + 1)); done
  return 1
}
# shellcheck disable=SC2254
seg_matches() { local k=0; while [ "$k" -lt "$NT" ]; do case "${TOKS[$k]}" in $1) return 0 ;; esac; k=$((k + 1)); done; return 1; }

seg_has_operand() { # any token after the first that is not an option?
  local k=1
  while [ "$k" -lt "$NT" ]; do case "${TOKS[$k]}" in -*) ;; *) return 0 ;; esac; k=$((k + 1)); done
  return 1
}
var_is_secret() { case "$1" in \$*[Tt][Oo][Kk][Ee][Nn]*|\$*[Ss][Ee][Cc][Rr][Ee][Tt]*|\$*[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]*|\$*[Aa][Pp][Ii]_[Kk][Ee][Yy]*|\$*[Pp][Rr][Ii][Vv][Aa][Tt][Ee]_[Kk][Ee][Yy]*) return 0 ;; esac; return 1; }

seg_writes() { # does the current segment write/modify files?
  local k=0 b t
  case "$SEG_RAW" in *">"*) return 0 ;; esac
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}; base_of "$t"; b=$BASE
    case "$b" in
      rm|mv|cp|tee|truncate|ln|chmod|chown|dd|install|rsync|ed|unlink|shred) return 0 ;;
      sed|perl) { seg_matches '-i*' || seg_matches '-[!-]*i*'; } && return 0 ;;   # -i, -i.bak, and any short-option cluster holding an i (-pi, -ri, -wpi)
    esac
    case "$t" in --in-place*) return 0 ;; esac
    k=$((k + 1))
  done
  return 1
}

# ---------- rule 1: rm -rf ----------
check_delete_target() { # path-as-written
  local a=$1 pre dir abs
  case "$a" in
    *'$'*|*'`'*) emit_deny "recursive delete with an unresolved variable or substitution (${a:0:200}). Use a literal path inside the repo or /tmp." ;;
  esac
  # no real path is this long (PATH_MAX is 1024), and resolving a huge one is quadratic on bash 3.2
  if [ "${#a}" -gt 4096 ]; then emit_deny "recursive delete of a path too long to check. Use a literal path inside the repo or /tmp."; fi
  if [ "$SIM_UNKNOWN" -eq 1 ]; then
    case "$a" in /*|"~"*) ;; *) emit_deny "recursive delete with a relative path after a cd the guard cannot resolve. Use an absolute path inside the repo or /tmp." ;; esac
  fi
  case "$a" in
    *[\*\?\[]*)
      pre=${a%%[\*\?\[]*}
      case "$pre" in */*) dir=${pre%/*}; [ -n "$dir" ] || dir=/ ;; *) dir=. ;; esac
      abs=$(resolve_path "$dir" "$SIM_CWD")
      if [ "$abs" = "$ROOT" ] || is_safe_delete_target "$abs"; then return 0; fi
      emit_deny "recursive delete of '$a' is outside the current repo and /tmp. Delete only inside the repo or a /tmp path."
      ;;
  esac
  abs=$(resolve_path "$a" "$SIM_CWD")
  is_safe_delete_target "$abs" || emit_deny "recursive delete of '$abs' is outside the current repo and /tmp (or is the repo root / .git itself). Delete only inside the repo or a /tmp path."
}

check_rm() { # $1 = index of rm token
  local k a rec=0 eo=0
  k=$(( $1 + 1 ))
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    if [ "$eo" -eq 0 ]; then
      case "$a" in
        --) eo=1 ;;
        --recursive) rec=1 ;;
        --no-preserve-root) emit_deny "rm --no-preserve-root is never allowed." ;;
        --*) ;;
        -*) case "$a" in *[rR]*) rec=1 ;; esac ;;
      esac
    fi
    k=$((k + 1))
  done
  [ "$rec" -eq 1 ] || return 0
  eo=0; k=$(( $1 + 1 ))
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    if [ "$eo" -eq 0 ] && [ "$a" = "--" ]; then eo=1; k=$((k + 1)); continue; fi
    if [ "$eo" -eq 1 ] || { case "$a" in -*) false ;; *) true ;; esac; }; then check_delete_target "$a"; fi
    k=$((k + 1))
  done
}

check_find_delete() { # find ... -delete / -exec rm
  local k=1 a
  seg_matches '-delete' || { seg_matches '-exec' && has_token rm; } || return 0
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    case "$a" in -*|'('|'!') break ;; esac
    check_delete_target "$a"
    k=$((k + 1))
  done
}

# ---------- rules 2, 3: git ----------
require_token() { # sha dir dst
  local out rc=0
  out=$(cd "$2" && "$SELF_DIR/release-gate.sh" --verify "$1" 2>&1) || rc=$?
  [ "$rc" -eq 0 ] || emit_deny "push to $3 denied: $out. Run release-gate.sh (tests, evidence) first; in confirm mode the user must approve."
}

check_refspec() { # refspec gdir delete
  local r=$1 gdir=$2 del=$3 src dst cur sha
  src=${r%%:*}
  if [[ "$r" == *:* ]]; then dst=${r#*:}; else dst=$r; fi
  case "$src$dst" in
    *'$'*|*'*'*|*'?'*|*'['*|*'`'*|*'{'*|*'~'*)
      emit_deny "cannot determine the push target from '$r' (variable, glob or brace). Name the branch literally, e.g. git push origin HEAD:my-branch." ;;
  esac
  dst=${dst#refs/heads/}
  if [ "$dst" = HEAD ]; then cur=$(git -C "$gdir" symbolic-ref --short -q HEAD 2>/dev/null || true); dst=$cur; fi
  is_protected "$dst" || return 0
  [ -n "$src" ] || emit_deny "deleting the protected branch $dst is not allowed."
  [ "$del" -eq 0 ] || emit_deny "deleting the protected branch $dst is not allowed."
  sha=$(git -C "$gdir" rev-parse --verify -q "${src}^{commit}" 2>/dev/null || true)
  [ -n "$sha" ] || emit_deny "cannot resolve '$src' to a commit for the push to $dst."
  require_token "$sha" "$gdir" "$dst"
}

# ---------- rule 8: release tags (miso publishes on a v* tag push) ----------
deny_tag_push() {
  emit_deny "rule 8: pushing a release tag publishes a release (miso's release.yml runs on v* tags). Create the tag locally, then notify the user that it is ready. ($1)"
}
is_release_tag_ref() { # refspec gdir -> 0 when it pushes or deletes a v* tag
  local r=${1#+} src dst
  src=${r%%:*}
  if [[ "$r" == *:* ]]; then dst=${r#*:}; else dst=$r; fi
  case "$dst" in
    refs/tags/v*|tags/v*) return 0 ;;
    refs/*|tags/*) return 1 ;;
  esac
  # an unqualified name: a version-shaped name, or a local v* tag (git pushes it as a tag)
  case "$dst" in v[0-9]*) return 0 ;; v*) ;; *) return 1 ;; esac
  git -C "$2" show-ref --verify -q "refs/tags/$dst" 2>/dev/null && return 0
  # src:dst with a tag as the source makes git create dst under refs/tags
  case "$src" in refs/tags/*|tags/*) return 0 ;; esac
  [ -n "$src" ] && git -C "$2" show-ref --verify -q "refs/tags/$src" 2>/dev/null && return 0
  return 1
}
push_config_tags() { # any token that sets push.followTags (not to false), a remote push refspec or a mirror remote
  # (git -c, GIT_CONFIG_KEY_n / GIT_CONFIG_PARAMETERS); only tokens that can match are lower-cased
  local k=0 t
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}
    case "$t" in
      *[Ff][Oo][Ll][Ll][Oo][Ww][Tt][Aa][Gg][Ss]*|*[Rr][Ee][Mm][Oo][Tt][Ee].*)
        t=$(printf '%s' "$t" | LC_ALL=C tr 'A-Z' 'a-z')
        case "$t" in
          *push.followtags=false|*push.followtags=no|*push.followtags=off|*push.followtags=0) ;;
          *push.followtags*|*remote.*.push|*remote.*.push=*|*remote.*.mirror*) return 0 ;;
        esac ;;
    esac
    k=$((k + 1))
  done
  return 1
}
check_push_tags() { # $1 = gdir, $2 = 1 when the command names refspecs; TOKS is the segment
  local v
  if push_config_tags; then deny_tag_push "push.followTags, a remote push refspec or a mirror remote set for this push can push tags"; fi
  v=$(git -C "$1" config --bool --get push.followTags 2>/dev/null || true)
  [ "$v" != true ] || deny_tag_push "push.followTags is true in this repo's config"
  v=$(git -C "$1" config --bool --get-regexp '^remote\..*\.mirror$' 2>/dev/null || true)
  case "$v" in *" true"*) deny_tag_push "a remote in this repo's config is a mirror" ;; esac
  if [ "$2" -eq 0 ]; then   # without refspecs git uses remote.<name>.push from the config
    v=$(git -C "$1" config --get-regexp '^remote\..*\.push$' 2>/dev/null || true)
    case "$v" in *tags*) deny_tag_push "a remote push refspec in this repo's config pushes tags" ;; esac
  fi
}

check_push() { # $1 = index of 'push' token, $2 = git dir
  local gdir=$2 k a force=0 del=0 all=0 np=0 refs="" r cur up sha prev=""
  k=$(( $1 + 1 ))
  if [ "$SIM_UNKNOWN" -eq 1 ]; then emit_deny "git push after a cd the guard cannot resolve. Use 'git -C <literal dir> push ...'."; fi
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    case "$a" in
      --tags|--follow-tags) deny_tag_push "git push $a can push a release tag; push branches by name" ;;
      --force|--force-with-lease|--force-with-lease=*|--force-if-includes|--mirror) force=1 ;;
      --delete) del=1 ;;
      --all|--branches) all=1 ;;
      -o|--push-option|--repo|--receive-pack|--exec) k=$((k + 1)) ;;
      --*) ;;
      -*) case "$a" in *f*) force=1 ;; esac; case "$a" in *d*) del=1 ;; esac ;;
      +*) force=1; np=$((np + 1)); refs="$refs$a"$'\n' ;;
      *) np=$((np + 1)); if [ "$np" -eq 1 ] && [[ "$a" != *:* ]]; then :; else refs="$refs$a"$'\n'; fi ;;
    esac
    k=$((k + 1))
  done
  [ "$force" -eq 0 ] || emit_deny "force push is never allowed (--force, --force-with-lease, +refspec, --mirror). Push a new commit; to undo a release push a revert commit through the gate."
  DEFB=$(git -C "$gdir" symbolic-ref --short -q refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  [ "$all" -eq 0 ] || emit_deny "git push --all would push the protected branch without a release token. Push named branches."
  if [ -n "$refs" ]; then check_push_tags "$gdir" 1; else check_push_tags "$gdir" 0; fi
  while IFS= read -r r; do   # `tag <name>` is refs/tags/<name>
    [ -n "$r" ] || continue
    if [ "$prev" = tag ]; then case "$r" in v*) deny_tag_push "git push ... tag $r" ;; esac; fi
    if is_release_tag_ref "$r" "$gdir"; then deny_tag_push "$r"; fi
    prev=$r
  done <<<"$refs"
  if [ -z "$refs" ]; then
    cur=$(git -C "$gdir" symbolic-ref --short -q HEAD 2>/dev/null || true)
    up=$(git -C "$gdir" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)
    if is_protected "$cur" || is_protected "${up#*/}"; then
      sha=$(git -C "$gdir" rev-parse HEAD 2>/dev/null || true)
      [ -n "$sha" ] || emit_deny "cannot resolve HEAD for the push."
      require_token "$sha" "$gdir" "${cur:-the default branch}"
    fi
    return 0
  fi
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    check_refspec "$r" "$gdir" "$del"
  done <<<"$refs"
}

check_git() { # $1 = index of git token
  local j gdir=$SIM_CWD a sub k prev
  j=$(( $1 + 1 ))
  while [ "$j" -lt "$NT" ]; do
    a=${TOKS[$j]}
    case "$a" in
      -C) if [ "${#TOKS[$((j + 1))]}" -gt 4096 ]; then emit_deny "git -C with a path too long to check."; fi
          gdir=$(resolve_path "${TOKS[$((j + 1))]:-.}" "$gdir"); j=$((j + 2)) ;;
      -c|--git-dir|--work-tree|--namespace|--exec-path) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  sub=${TOKS[$j]:-}
  k=$j
  while [ "$k" -lt "$NT" ]; do
    case "${TOKS[$k]}" in
      --no-verify|--no-verify=*) emit_deny "--no-verify skips the git hooks (including the pre-push release backstop). Remove it and fix what the hook reports." ;;
    esac
    k=$((k + 1))
  done
  if [ "$sub" = commit ]; then
    k=$j; prev=""
    while [ "$k" -lt "$NT" ]; do
      a=${TOKS[$k]}
      case "$a" in
        --*) ;;
        -*n*) if [ "$prev" != "-m" ] && [ "$prev" != "-F" ]; then emit_deny "git commit -n is --no-verify; it skips the git hooks."; fi ;;
      esac
      prev=$a; k=$((k + 1))
    done
  fi
  [ "$sub" != push ] || check_push "$j" "$gdir"
}

# ---------- rules 4, 6, 7 and extras ----------
graphql_mutation() { # `gh api graphql` whose query text (anywhere in the command: the segment splitter cuts at the
  # parentheses of a query) is a mutation that closes, merges, deletes, publishes or writes refs/commits
  case "$CMD_ALL" in *[[:space:]]graphql*) ;; *) return 1 ;; esac
  case "$CMD_ALL" in *[Mm][Uu][Tt][Aa][Tt][Ii][Oo][Nn]*) ;; *) return 1 ;; esac
  case "$CMD_ALL" in
    *[Cc][Ll][Oo][Ss][Ee]*|*[Mm][Ee][Rr][Gg][Ee]*|*[Dd][Ee][Ll][Ee][Tt][Ee]*|*[Pp][Uu][Bb][Ll][Ii][Ss][Hh]*|*[Uu][Pp][Dd][Aa][Tt][Ee][Rr][Ee][Ff]*|*[Cc][Rr][Ee][Aa][Tt][Ee][Rr][Ee][Ff]*|*[Cc][Rr][Ee][Aa][Tt][Ee][Cc][Oo][Mm][Mm][Ii][Tt]*) return 0 ;;
  esac
  return 1
}

check_gh() { # $1 = index of gh
  local k subs="" n=0 a mut=0 hit=0 method="" inp=0
  k=$(( $1 + 1 ))
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    case "$a" in
      -X|--method) method=${TOKS[$((k + 1))]:-}; k=$((k + 1)) ;;
      -X?*) method=${a#-X} ;;               # attached: -XPUT
      --method=*) method=${a#--method=} ;;
      -R|--repo) k=$((k + 1)) ;;   # the repo is a value, not a subcommand (gh pr -R o/r close 5)
      --input|--input=*) mut=1; inp=1 ;;    # a request body from a file: its text cannot be inspected
      -f|-F|--field|--raw-field) mut=1 ;;
      -*) ;;
      *) if [ "$n" -lt 2 ]; then subs="$subs $a"; n=$((n + 1)); fi
         case "$a" in *git/refs*|*/merge|*/merges|*dispatches*|*/contents/*) hit=1 ;; esac ;;
    esac
    k=$((k + 1))
  done
  case "$subs" in
    " pr merge"*)
      # Allowed only through the gate: valid token for the local HEAD, and the merge pinned to that exact
      # commit with --match-head-commit so GitHub refuses it if the PR head is anything else.
      local msha pin="" kk
      msha=$(git -C "$SIM_CWD" rev-parse HEAD 2>/dev/null || true)
      [ -n "$msha" ] || emit_deny "gh pr merge: cannot resolve HEAD here. Run it from inside the repo whose release token you minted."
      kk=$(( $1 + 1 ))
      while [ "$kk" -lt "$NT" ]; do
        case "${TOKS[$kk]}" in
          --match-head-commit) pin=${TOKS[$((kk + 1))]:-} ;;
          --match-head-commit=*) pin=${TOKS[$kk]#--match-head-commit=} ;;
        esac
        kk=$((kk + 1))
      done
      require_token "$msha" "$SIM_CWD" "gh pr merge"
      [ "$pin" = "$msha" ] || emit_deny "gh pr merge must be pinned to the released commit: add --match-head-commit $msha." ;;
    " pr close"*|" issue close"*|" issue delete"*)
      emit_deny "rule 9: closing or deleting PRs and issues is the user's call. Comment with your reasoning (gh pr comment / gh issue comment) and notify instead." ;;
    " release create"*|" release delete"*|" release edit"*|" release upload"*)
      emit_deny "rule 8: publishing a release is the user's call. Prepare it, then notify that it is ready." ;;
    " repo delete"*) emit_deny "rule 8: deleting a repository is the user's call." ;;
    " repo edit"*) if seg_matches '--visibility*'; then emit_deny "rule 8: changing repository visibility is the user's call."; fi ;;
    " repo create"*) if seg_matches '--public'; then emit_deny "rule 8: a public repository publishes code. Create it with --private, or ask the user."; fi ;;
    " workflow run"*|" workflow dispatch"*|" run rerun"*) emit_deny "starting or re-running workflows by hand is not allowed; deploys come from CI on a push. To roll back, push a revert commit through the release gate." ;;
    " api"*)
      local mm=0
      case "$method" in ''|[Gg][Ee][Tt]|[Hh][Ee][Aa][Dd]) ;; *) mut=1; mm=1 ;; esac
      if [ "$mut" -eq 1 ] && seg_matches '*state=closed*'; then emit_deny "rule 9: closing an issue or PR through the API is the user's call. Comment and notify instead."; fi
      if [ "$mut" -eq 1 ] && { seg_matches '*refs/tags*' || seg_matches '*/releases' || seg_matches '*/releases/*'; }; then
        emit_deny "rule 8: creating a tag or a release through the API publishes a release. Create the tag locally, then notify the user that it is ready."
      fi
      if [ "$mut" -eq 1 ] && [ "$hit" -eq 1 ]; then emit_deny "gh api call that merges, dispatches workflows, or writes refs/contents bypasses the release gate."; fi
      if [ "$mm" -eq 1 ] && [ "$inp" -eq 1 ]; then emit_deny "gh api with a mutating method and --input sends a body the guard cannot read. Use the dedicated gh subcommand, or ask the user."; fi
      if [ "$inp" -eq 1 ] && seg_matches graphql; then emit_deny "gh api graphql --input sends a query the guard cannot read. Pass the query with -f query=... so it can be checked."; fi
      if graphql_mutation; then emit_deny "rule 3/9: a GraphQL mutation that closes, merges, deletes, publishes or writes refs is the user's call (it bypasses the release gate)."; fi ;;
  esac
}

check_publish() { # $1 = index of npm/pnpm/bun/yarn
  # The word right after the package manager is the subcommand. A read-only or test subcommand there makes a
  # later `publish` an argument (bun test publish, npm view publish); a dry run publishes nothing. Anything else
  # (an option first, whose value could be taken for the subcommand: npm --prefix test publish) keeps the old
  # rule: any `publish` word in the command is denied.
  local sub scr=""
  sub=${TOKS[$(( $1 + 1 ))]:-}
  base_of "${TOKS[$1]}"
  if [ "$BASE" = npm ]; then
    # npm runs any unique prefix of a command (npm 11: pu..publis is publish, unp.. unpublish, dep.. deprecate);
    # no other npm command starts with pu, unp or dep. pnpm/yarn are not known to; bun runs a script named pub.
    case "$sub" in
      pu|pub|publ|publi|publis) sub=publish ;;
      unp|unpu|unpub|unpubl|unpubli|unpublis|dep|depr|depre|deprec|depreca|deprecat|dist-tags) scr=$sub ;;
    esac
  fi
  case "$sub" in
    npm|pnpm|bun|yarn) return 0 ;;   # yarn npm ...: that word is in command position and is checked itself
    test|t|tst|view|v|info|show|help|help-search|search|s|find|ls|list|outdated|why|explain|audit|pack) return 0 ;;
    publish)   # a dry run, unless anything could switch it back off (--dry-run false, --no-dry-run, =false)
      if seg_matches --dry-run && ! seg_matches '--dry-run=*' && ! seg_matches '--no-dry-run*' && ! seg_matches false && ! seg_matches 0; then return 0; fi
      scr=publish ;;
    run|run-script)   # the script name right after it decides: a script named like a publish is one
      scr=${TOKS[$(( $1 + 2 ))]:-}
      case "$scr" in -*|'') scr="" ;; *publish*|*dist-tag*|*deprecate*) ;; *) return 0 ;; esac ;;
  esac
  if seg_matches publish || seg_matches unpublish || seg_matches deprecate || seg_matches dist-tag || [ -n "$scr" ]; then
    emit_deny "rule 8: publishing a package is the user's call. Run '${TOKS[$1]##*/} pack' to check the tarball, then notify that it is ready."
  fi
}

check_vercel() { # $1 = index of vercel token
  local k a sub=""
  k=$(( $1 + 1 ))
  seg_matches '--version' && return 0; seg_matches '--help' && return 0
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}; case "$a" in -*) ;; *) sub=$a; break ;; esac; k=$((k + 1))
  done
  case "$sub" in whoami|ls|list|inspect|logs|help) return 0 ;; esac
  emit_deny "the vercel CLI is not allowed to deploy or change anything (deploys come from CI only). Read-only: whoami, ls, inspect, logs. Rolling back means pushing a revert commit through the release gate."
}

check_supabase_cli() { # $1 = index
  local k a subs="" n=0
  k=$(( $1 + 1 ))
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}; case "$a" in -*) ;; *) if [ "$n" -lt 2 ]; then subs="$subs $a"; n=$((n + 1)); fi ;; esac; k=$((k + 1))
  done
  case "$subs" in
    " db push"*|" db reset"*|" db execute"*|" db remote"*|" migration up"*|" migration repair"*) emit_deny "supabase CLI '$subs' changes the shared database outside the migration ledger. Create a numbered migration file and use migrate-gate.sh then db-migrate.ts --apply." ;;
  esac
}

is_env_token() { # token -> 0 if any path/argument piece in it names an env file with secrets
  local t=$1 r oldifs=$IFS rc=1
  set -f; IFS='/=<@(),'
  for r in $t; do
    case "$r" in .env.example|.env.sample|.env.template|.env.dist|.env.defaults|*.env.example) continue ;; esac
    case "$r" in .env|.env.*|*.env|.env\**|.env\?*) rc=0; break ;; esac
  done
  set +f; IFS=$oldifs
  return "$rc"
}

READERS=" cat tac less more head tail grep egrep fgrep rg ag sed awk gawk cut sort uniq tee bat nl xxd od strings cp mv base64 source . python python3 node bun deno ruby perl php sh bash zsh xargs jq curl wget open code vim vi nano emacs diff cmp rev tr paste column fold add "

check_env_files() { # whole line (tokens in TOKS): a reader and an env-file operand together
  local k t b reader=0 envtok=0
  base_of "${TOKS[0]}"
  case "$BASE" in
    git) case " ${TOKS[*]} " in *" commit "*|*" tag "*|*" check-ignore "*|*" status "*) return 0 ;; esac ;;
  esac
  k=0
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}; base_of "$t"; b=$BASE
    case "$READERS" in *" $b "*) reader=1 ;; esac
    case "$b" in .gitignore|.dockerignore|.npmignore|.vercelignore|.eslintignore) return 0 ;; esac
    case "$t" in "<"*) reader=1 ;; esac
    if is_env_token "$t"; then envtok=1; fi
    k=$((k + 1))
  done
  if [ "$envtok" -eq 1 ] && [ "$reader" -eq 1 ]; then
    emit_deny "reading or copying .env files would put credentials into the session. Scripts that need them (db-migrate.ts) read .env themselves; run those instead. .env.example is fine."
  fi
}

check_secret_dump() { # one segment
  local k first
  base_of "${TOKS[0]}"; first=$BASE
  case "$first" in
    printenv) emit_deny "printenv dumps credentials into the session." ;;
    env) [ "$NT" -gt 1 ] || emit_deny "'env' with no command dumps credentials into the session." ;;
    # `A && B` as the last statement of a case arm returns 1 when A fails, and set -e then kills the caller
    # ("internal error; failing closed") for every plain `export FOO=1`: use if. Bare export/declare/typeset
    # (no operand) list the environment just like -p does.
    export|declare|typeset)
      if seg_matches '-p' || ! seg_has_operand; then emit_deny "listing exported variables dumps credentials into the session."; fi ;;
    echo|printf) k=1; while [ "$k" -lt "$NT" ]; do var_is_secret "${TOKS[$k]}" && emit_deny "printing a token/secret variable is not allowed."; k=$((k + 1)); done ;;
  esac
}

check_misc() { # one segment, tokens in TOKS
  local k t b
  k=0
  while [ "$k" -lt "$NT" ]; do
    ceiling
    t=${TOKS[$k]}; base_of "$t"; b=$BASE
    case "$t" in
      *release-token*|*release-ready*|*migrate-token*|*migrate-confirmed*|*.agent/secret*)
        emit_deny "release/migration tokens and the signing secret are managed by release-gate.sh and migrate-gate.sh only." ;;
    esac
    if cmd_pos "$k"; then
      case "$b" in
        rm) check_rm "$k" ;;
        find) [ "$k" -ne 0 ] || check_find_delete ;;
        git) check_git "$k" ;;
        gh) check_gh "$k" ;;
        npm|pnpm|bun|yarn) check_publish "$k" ;;
        vercel|vercel@*) check_vercel "$k" ;;
        supabase) check_supabase_cli "$k" ;;
        eval) case "$SEG_RAW" in *'$'*|*'`'*) emit_deny "eval with a variable or substitution hides what will run." ;; esac ;;
        curl|wget|http|https)
          if seg_matches '*api.supabase.com*'; then
            if seg_matches '*database/query*' || seg_matches '-d' || seg_matches '--data*' || seg_matches '--json' || seg_matches '-F' || seg_matches '-X' || seg_matches '--request'; then
              emit_deny "the Supabase Management API can run DDL outside the migration ledger. Use numbered migration files and migrate-gate.sh."
            fi
          fi ;;
        psql)
          if seg_matches '*supabase.co*' || seg_matches '*supabase.com*' || seg_matches '*pooler*' || seg_matches '$*DATABASE*' || seg_matches '$*SUPABASE*' || seg_matches '$*POSTGRES*'; then
            emit_deny "psql against the shared Supabase database bypasses the migration ledger. Use migrate-gate.sh and db-migrate.ts."
          fi ;;
        bash|sh|zsh)
          if [ "$k" -eq 0 ] && ! seg_has_operand; then emit_deny "piping into a shell hides what will run. Save the script to a file and review it."; fi ;;
      esac
    fi
    case "$b" in
      db-migrate*|db:migrate*)
        if cmd_pos "$k"; then check_migrate "$k"; fi ;;
    esac
    k=$((k + 1))
  done
  case "$SEG_RAW" in
    *core.hooksPath*|*core.hookspath*)
      case "$SEG_RAW" in *--get*|*--list*|*"-l "*) ;; *) emit_deny "changing core.hooksPath disables the pre-push release backstop." ;; esac ;;
  esac
  if has_token release-gate.sh && { seg_matches '--approve'; }; then emit_deny "release approval is for the human. Tell the user the gate passed and wait."; fi
  if has_token migrate-gate.sh && { seg_matches '--confirm*'; }; then emit_deny "confirming a destructive migration is for the human. Stop and ask the user."; fi
  tamper_bash
  check_secret_dump
}

check_migrate() { # $1 = index of the db-migrate token
  local out rc=0
  if seg_matches '--record-only*'; then emit_deny "db-migrate --record-only marks migrations applied without running them; it needs human judgment."; fi
  if seg_matches '--apply*'; then
    if [ "$SIM_UNKNOWN" -eq 1 ]; then emit_deny "db-migrate --apply after a cd the guard cannot resolve."; fi
    out=$(cd "$SIM_CWD" && "$SELF_DIR/migrate-gate.sh" --verify 2>&1) || rc=$?
    [ "$rc" -eq 0 ] || emit_deny "db-migrate --apply denied: $out. Run migrate-gate.sh first (dry run, lint, tests)."
  fi
}

is_migration_path() { case "$1" in */migrations/*.sql|migrations/*.sql) return 0 ;; esac; return 1; }

committed_migration() { # absolute physical path -> 0 if it exists in HEAD of its repo
  local p=$1 dir top rel
  dir=$(dirname "$p")
  [ -d "$dir" ] || return 1
  top=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)
  [ -n "$top" ] || return 1
  top=$(phys_dir "$top")
  rel=${p#"$top"/}
  git -C "$top" cat-file -e "HEAD:$rel" 2>/dev/null
}

is_tamper_path() { # macOS volumes are case-insensitive: match on the lower-cased path (like is_goal_path)
  local l s
  l=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  s=$(printf '%s' "$SELF_DIR" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$l" in "$s"|"$s"/*) return 0 ;; esac
  case "$l" in
    */.claude/settings.json|*/.claude/settings.local.json|*/.git/hooks|*/.git/hooks/*|*.githooks|*.githooks/*|*/ching/bin|*/ching/bin/*|*/.claude/ching|*/.claude/ching/*) return 0 ;;
  esac
  return 1
}

# ---------- rule 11: gate settings in GOAL.md ----------
is_goal_path() { # macOS volumes are case-insensitive by default, so .agent/goal.md is the same file: match on the lower-cased path
  local l
  l=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z')
  case "$l" in */.agent/goal.md|*/defaults/goal.md) return 0 ;; esac   # */defaults/ also covers AGENT_HOME overrides
  return 1
}
# -a: a NUL byte in the text must not turn the output into "Binary file matches" (the lines would vanish);
# LC_ALL=C on every stage: sed fails on a byte sequence that is not valid UTF-8 and would drop the lines too.
gated_lines() { LC_ALL=C grep -aE '^[[:space:]]*(review|release_mode|test_command):' | LC_ALL=C sed 's/[[:space:]]*$//' | LC_ALL=C sort || true; }
deny_goal() { emit_deny "rule 11: review, release_mode and test_command in GOAL.md are the user's settings. Put the proposed change in STATE.md and notify the user."; }
goal_seg_writes() { # seg_writes, except that discarding or merging a stream (2>/dev/null, 2>&1 split at '&') is not a write
  local keep=$SEG_RAW rc=0
  SEG_RAW=$(printf '%s\n' "$keep" | sed -E 's#[0-9]*>>?[[:space:]]*/dev/null([[:space:]]|$)# #g; s#[0-9]*>[[:space:]]*$##')
  seg_writes || rc=$?
  SEG_RAW=$keep
  return "$rc"
}
check_new_goal() { # $1 = the gated lines of a GOAL.md that does not exist yet
  local rv relm
  # EVERY review:/release_mode: line counts, not just the first one: a harmless indented decoy line must not
  # hide the unindented line goal_get reads. `grep -vx ... || true` keeps this safe under pipefail.
  rv=$(printf '%s\n' "$1" | LC_ALL=C sed -n 's/^[[:space:]]*review:[[:space:]]*//p' | LC_ALL=C grep -vxe required -e '' || true)
  relm=$(printf '%s\n' "$1" | LC_ALL=C sed -n 's/^[[:space:]]*release_mode:[[:space:]]*//p' | LC_ALL=C grep -vxe confirm -e '' || true)
  if [ -n "$rv" ] || [ -n "$relm" ]; then
    emit_deny "rule 11: a new GOAL.md may only start with review: required and release_mode: confirm. The user switches them."
  fi
}
check_goal_write() { # $1 = absolute path of a GOAL.md being written by Edit/MultiEdit/Write
  local old new before after size
  # Defence in depth next to grep -a: a NUL byte anywhere in the input of a GOAL.md write is never legitimate
  # (and any failure to look is a deny).
  jq -e '[.tool_input | .. | strings | select(contains("\u0000"))] | length == 0' <<<"$INPUT" >/dev/null 2>&1 || deny_goal
  case "$TOOL" in
    Edit|MultiEdit)
      if [ "$TOOL" = Edit ]; then
        old=$(jq -r '.tool_input.old_string // ""' <<<"$INPUT" | gated_lines)
        new=$(jq -r '.tool_input.new_string // ""' <<<"$INPUT")
      else
        old=$(jq -r '[.tool_input.edits[]?.old_string // ""] | join("\n")' <<<"$INPUT" | gated_lines)
        new=$(jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")' <<<"$INPUT")
      fi
      if [ ! -f "$1" ]; then
        # Nothing on disk: the edits can only create the file (empty old_string) and later edits then change it,
        # so check the RESULT of applying them to empty text, not the strings they carry (a partial-line
        # "confirm" -> "auto" after the creating edit names no setting).
        after=$(printf '%s' "$INPUT" | perl "$SELF_DIR/goal-sim-edit.pl" "$TOOL" "$1" | gated_lines) || deny_goal
        check_new_goal "$after"
        # and, as before, the settings the edit strings name themselves (an edit whose old_string cannot match
        # still must not carry an unsafe setting)
        new=$(printf '%s\n' "$new" | gated_lines)
        check_new_goal "$new"
        return 0
      fi
      new=$(printf '%s\n' "$new" | gated_lines)
      [ "$old" = "$new" ] || deny_goal   # cheap first pass: the edit text itself names a changed setting
      # second pass: a partial-line edit ("confirm" -> "auto") names no setting, so apply the edit(s) to the
      # file as it is on disk and compare its gated lines before and after. Anything we cannot check is a deny.
      size=$(wc -c <"$1" | tr -d ' ') || deny_goal
      [ "$size" -le 262144 ] || deny_goal
      before=$(gated_lines <"$1") || deny_goal
      after=$(printf '%s' "$INPUT" | perl "$SELF_DIR/goal-sim-edit.pl" "$TOOL" "$1" | gated_lines) || deny_goal
      [ "$before" = "$after" ] || deny_goal ;;
    Write)
      new=$(jq -r '.tool_input.content // ""' <<<"$INPUT" | gated_lines)
      if [ -f "$1" ]; then
        old=$(gated_lines <"$1")
        [ "$old" = "$new" ] || deny_goal
      else
        check_new_goal "$new"
      fi ;;
  esac
}

goal_token_path() { # token -> sets GABS to the GOAL.md path it names, or "" (not in a $() so that a deny can exit)
  # The path may follow an attached redirect operator (>>f, 2>f, &>f) or a name= prefix (of=f), and a directory
  # name may itself hold a '<', '>' or '=' (.agent/sub=dir/../GOAL.md). So try the whole token and the tail
  # after each of those characters; any one resolving to a GOAL.md path counts.
  local rest=$1 n=0 cand
  GABS=""
  while :; do
    if [ "${#rest}" -le 4096 ]; then   # no real path is longer; resolving a huge one is quadratic on bash 3.2
      cand=$(resolve_path "$rest" "$SIM_CWD")
      if is_goal_path "$cand"; then GABS=$cand; return 0; fi
    fi
    [ "$rest" != "${rest#*[<>=]}" ] || return 0
    rest=${rest#*[<>=]}
    n=$((n + 1))
    if [ "$n" -gt 24 ]; then emit_deny "rule 11: a token naming GOAL.md with this many '<', '>' or '=' cannot be checked. Use the Edit or Write tool."; fi
  done
}

tamper_bash() {
  local k=0 t abs gabs
  while [ "$k" -lt "$NT" ]; do
    ceiling
    t=${TOKS[$k]}
    case "$t" in -*) k=$((k + 1)); continue ;; esac
    abs=""
    # any case: macOS volumes are case-insensitive, so .claude/Settings.JSON is settings.json
    case "$t" in *[Hh][Oo][Oo][Kk][Ss]*|*[Ss][Ee][Tt][Tt][Ii][Nn][Gg][Ss]*|*[Cc][Hh][Ii][Nn][Gg]*|*.[Ss][Qq][Ll])
      if [ "${#t}" -le 4096 ]; then abs=$(resolve_path "$t" "$SIM_CWD"); fi ;;
    esac
    if [ -n "$abs" ] && is_tamper_path "$abs" && seg_writes; then
      emit_deny "editing hooks, settings or the guard itself ($t) would disable the guardrails. Ask the user."
    fi
    gabs=""
    case "$t" in
      *[Gg][Oo][Aa][Ll].[Mm][Dd]*) goal_token_path "$t"; gabs=$GABS ;;
    esac
    # '>&f' is split at the '&', so the target is the first token of a segment whose predecessor ended in '>'
    if [ -n "$gabs" ] && is_goal_path "$gabs" && { goal_seg_writes || { [ "$k" -eq 0 ] && [ "$SEG_AFTER_REDIR" -eq 1 ]; }; }; then
      emit_deny "rule 11: write GOAL.md with the Edit or Write tool so the guard can check its gate settings."
    fi
    if [ -n "$abs" ] && is_migration_path "$abs" && seg_writes && [ "$SIM_UNKNOWN" -eq 0 ]; then
      if committed_migration "$abs"; then
        emit_deny "$t is an already-committed migration; never edit it. Write a NEW numbered migration file that alters it."
      fi
    fi
    k=$((k + 1))
  done
}

# ---------- Bash driver ----------
SEG_RAW=""
SEG_AFTER_REDIR=0   # the previous segment ended in '>' (the split at '&' of '>&file' puts the file in this one)
NEXT_AFTER_REDIR=0
scan_segment() {
  local trimmed tail ci tgt
  ceiling
  SEG_RAW=$1
  tokenize "$1"
  [ "$NT" -gt 0 ] || return 0
  SEG_AFTER_REDIR=$NEXT_AFTER_REDIR
  if [ "${#1}" -gt 256 ]; then tail=${1: -256}; else tail=$1; fi   # ${1##*pattern} on a long segment is quadratic
  trimmed=${tail%"${tail##*[![:space:]]}"}
  case "$trimmed" in *'>') NEXT_AFTER_REDIR=1 ;; *) NEXT_AFTER_REDIR=0 ;; esac
  # track cd so later relative paths resolve like the shell would
  base_of "${TOKS[0]}"
  if [ "$BASE" = cd ] || [ "$BASE" = pushd ]; then
    ci=1   # skip the options (-P, -L, --): the target is the first word after them; a lone '-' is the previous directory
    while [ "$ci" -lt "$NT" ]; do
      case "${TOKS[$ci]}" in
        -) break ;;
        --) ci=$((ci + 1)); break ;;
        -*) ci=$((ci + 1)) ;;
        *) break ;;
      esac
    done
    tgt=${TOKS[$ci]:-$HOME}
    if [ "${#tgt}" -gt 4096 ]; then tgt='$too-long'; fi   # no real path is this long: treat it as unresolvable
    case "$tgt" in
      *'$'*|*'`'*|-) SIM_UNKNOWN=1 ;;
      *) SIM_CWD=$(resolve_path "$tgt" "$SIM_CWD"); SIM_UNKNOWN=0 ;;
    esac
    return 0
  fi
  check_misc
}

# Drop the bodies of heredocs that do not feed an interpreter (a body is data, not commands). When in doubt the
# lines are KEPT, because a false deny is cheaper than a body that swallows the commands after it:
#  - here-strings (<<<), and <<word inside quotes, comments or (( )) arithmetic, are not heredocs;
#  - the delimiter is the whole word after optional quotes (END-OF-FILE, EOF.1), not just its leading letters;
#  - the skipped lines are buffered and printed at END if the terminator never came;
#  - $1 selects how a line that ends in an odd number of backslashes is treated: 1 joins it with the next line
#    (so the heredoc body starts after the joined line), 2 joins it unless the backslash sits in a comment (the
#    shell does not continue a comment: `ls # note \` + `gh pr close 5` runs both), 0 never joins. The guard
#    scans the output of all the views that differ and denies when any one is denied;
#  - $( inside double quotes is command context again, so the body of git commit -m "$(cat <<'EOF' ... EOF)"
#    is data like the unquoted $(cat <<'EOF'; bash -c "$(cat <<EOF ...)" stays scanned (an interpreter).
strip_heredocs() {
  awk -v jn="$1" -v sq="'" -v dq='"' '
    function isinterp(pre,   n, t, i, b, redir, r) {
      n = split(pre, t, /[ \t]+/); redir = 0; r = 0
      for (i = 1; i <= n; i++) {
        if (redir) { redir = 0; continue }
        if (t[i] ~ /^[0-9]*>>?$/) { redir = 1; continue }
        b = t[i]; sub(/.*\//, "", b)
        if (b ~ /^(bash|sh|zsh|python3?|node|perl|ruby|bun|deno)$/) r = 1
      }
      return r
    }
    function odd_trailing(line,   n, t) {   # an odd number of backslashes at the end (only the tail is looked at: a
      # regex over a long run of backslashes is quadratic; size_verdict has already refused runs of 64 or more)
      n = length(line); t = (n > 64) ? substr(line, n - 63) : line
      return (match(t, /\\+$/) && RLENGTH % 2 == 1)
    }
    function in_comment(line,   len, i, c, q) {   # does a shell comment start somewhere in this line?
      if (index(line, "#") == 0) return 0   # no hash at all: nothing to walk (index is fast, the loop below is not)
      len = length(line); q = ""
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (q == sq) { if (c == sq) q = ""; continue }
        if (q == "ansi") { if (c == "\\") i++; else if (c == sq) q = ""; continue }
        if (q == dq) { if (c == "\\") i++; else if (c == dq) q = ""; continue }
        if (c == "\\") { i++; continue }
        if (c == "$" && substr(line, i + 1, 1) == sq) { q = "ansi"; i++; continue }   # ANSI-C quoting (dollar, single quote): a backslash escapes the next character
        if (c == sq || c == dq) { q = c; continue }
        if (c == "#" && (i == 1 || index(" \t;&|(", substr(line, i - 1, 1)) > 0)) return 1
      }
      return 0
    }
    function scan(line,   len, i, j, c, q, depth, ad, w, d, sp, sv_q, sv_d) {
      len = length(line); q = ""; depth = 0; ad = 0; sp = 0
      for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (q == sq) { if (c == sq) q = ""; continue }
        if (q == "ansi") { if (c == "\\") i++; else if (c == sq) q = ""; continue }
        if (q == dq) {
          if (c == "\\") i++
          else if (c == dq) q = ""
          else if (c == "$" && substr(line, i + 1, 1) == "(") {   # $( in double quotes: command context until its )
            sp++; sv_q[sp] = dq; sv_d[sp] = depth; q = ""; depth++; i++
            if (substr(line, i + 1, 1) == "(") { ad = depth; depth++; i++ }   # $(( is arithmetic
          }
          continue
        }
        if (c == "\\") { i++; continue }
        if (c == "$" && substr(line, i + 1, 1) == sq) { q = "ansi"; i++; continue }
        if (c == sq || c == dq) { q = c; continue }
        if (c == "#" && (i == 1 || index(" \t;&|(", substr(line, i - 1, 1)) > 0)) break
        if (c == "(") { depth++; if (!ad && substr(line, i + 1, 1) == "(") ad = depth; continue }
        if (c == ")") {
          depth--; if (depth < 0) depth = 0; if (ad && depth < ad) ad = 0
          if (sp > 0 && depth == sv_d[sp]) { q = sv_q[sp]; sp-- }   # back into the double quote
          continue
        }
        if (c == "<" && substr(line, i + 1, 1) == "<") {
          if (substr(line, i + 2, 1) == "<") { i += 2; continue }
          if (ad) { i++; continue }
          j = i + 2
          if (substr(line, j, 1) == "-") j++
          while (substr(line, j, 1) == " " || substr(line, j, 1) == "\t") j++
          while (substr(line, j, 1) == sq || substr(line, j, 1) == dq || substr(line, j, 1) == "\\") j++
          w = ""
          while (j <= len) { d = substr(line, j, 1); if (index(" \t;&|<>()" sq dq, d) > 0) break; w = w d; j++ }
          if (j <= len && (substr(line, j, 1) == sq || substr(line, j, 1) == dq)) j++
          if (w != "" && !isinterp(substr(line, 1, i - 1))) words[++nw] = w
          i = j - 1
        }
      }
    }
    skip {
      l = $0; sub(/^[ \t]+/, "", l)
      if (l == words[cur]) { cur++; if (cur > nw) { skip = 0; nb = 0 } }
      else buf[++nb] = $0
      next
    }
    {
      line = $0
      if (jn) while (odd_trailing(line) && !(jn == 2 && in_comment(line)) && (getline nx) > 0) line = substr(line, 1, length(line) - 1) nx
      print line
      if (index(line, "<<") > 0) { nw = 0; scan(line); if (nw > 0) { skip = 1; cur = 1; nb = 0 } }
    }
    END { if (skip) for (i = 1; i <= nb; i++) print buf[i] }'
}

join_continuations() { # backslash-newline is a line continuation: `git push \` + `origin HEAD:main` is one command
  # An odd number of backslashes before the newline continues the line; an even number is literal backslashes.
  # Runs AFTER strip_heredocs: a heredoc body line ending in a backslash must not swallow its terminator.
  perl -0777 -pe 's/(?<!\\)((?:\\\\)*)\\\n/$1/g'
}

CMD_ALL=""   # the text being scanned (for checks that span segments)
scan_text() { # scan one text (heredoc bodies already stripped); a deny exits, so this only returns when it is clean
  local seg segs p1=$1
  # every piece of per-scan state starts fresh: the simulated cd, the redirect carry-over; the time ceiling
  # (SECONDS) keeps counting across scans
  SIM_CWD=$CWD_PHYS; SIM_UNKNOWN=0; SEG_RAW=""; SEG_AFTER_REDIR=0; NEXT_AFTER_REDIR=0; DEFB=""
  CMD_ALL=$1
  # a grep/rg pattern names no file (grep -n "ching.env" f): quote-data.pl masks the pattern words for pass 1
  case "$1" in
    *grep*|*rg*) p1=$(printf '%s\n' "$1" | perl "$SELF_DIR/quote-data.pl" patterns) || { echo "GUARD: could not read the grep patterns; failing closed" >&2; exit 2; } ;;
  esac
  while IFS= read -r seg; do   # pass 1: per line, for rules that need the whole line (.env readers)
    ceiling
    SEG_RAW=$seg; tokenize "$seg"
    if [ "$NT" -gt 0 ]; then check_env_files; fi
  done <<<"$p1"
  # A failed splitter must not look like "no segments": capture its output and fail closed if it errs.
  # quote-data.pl first blanks the separators inside quoted data (a grep pattern, an echo string, a commit
  # message), so `grep -E 'a|npm publish' f` stays one command; quoted code (bash -c '...') is still split.
  segs=$(printf '%s\n' "$1" | perl "$SELF_DIR/quote-data.pl" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|&()`]/\n/g') || { echo "GUARD: could not split the command; failing closed" >&2; exit 2; }
  while IFS= read -r seg; do   # pass 2: per simple command
    scan_segment "$seg"
  done <<<"$segs"
}

size_verdict() { # stdin: the raw command -> prints "ok", or "big" when it cannot be scanned in time. One linear awk
  # pass. The heredoc/join awk and the bash tokenizer cannot be interrupted by the 8 s ceiling, and a hook that
  # times out (15 s) lets the call run, so what would take too long is refused up front:
  #  - more than 256 KB, or more than 1000 backslash-newline continuations;
  #  - a logical (joined) line over 64 KB, or a join workload (the sum of the joined-line lengths at each join,
  #    which is what the comment-aware join costs) over 4.5 million characters;
  #  - a line that ends in 64 or more backslashes.
  LC_ALL=C awk -v maxbytes=262144 -v maxcont=1000 -v maxlogical=65536 -v maxwork=4500000 '
    BEGIN { bytes = 0; cont = 0; acc = 0; grp = 0; work = 0; bad = 0 }
    {
      n = length($0); bytes += n + 1
      if (bytes > maxbytes) { bad = 1; exit }
      t = (n > 64) ? substr($0, n - 63) : $0
      if (n >= 64 && match(t, /\\+$/) && RLENGTH >= 64) { bad = 1; exit }
      if (substr(t, length(t), 1) == "\\") {
        cont++; acc += n; work += acc; grp = 1
        if (cont > maxcont || acc > maxlogical || work > maxwork) { bad = 1; exit }
      } else {
        if (grp && acc + n > maxlogical) { bad = 1; exit }
        acc = 0; grp = 0
      }
    }
    END { print (bad ? "big" : "ok") }'
}

check_bash() {
  local raw plain joined prev verdict
  raw=$(jq -r '.tool_input.command // ""' <<<"$INPUT")
  [ -n "$raw" ] || allow
  # before any view is computed: a command that cannot be scanned in time is refused (fail closed)
  verdict=$(printf '%s\n' "$raw" | size_verdict) || { echo "GUARD: could not measure the command; failing closed" >&2; exit 2; }
  if [ "$verdict" != ok ]; then emit_deny "command too large to check safely (over 256 KB, over 1000 line continuations, or a joined line over 64 KB). Split it into smaller commands or put the script in a file."; fi
  # Up to three views of the command, denied when any one is denied:
  #  - un-joined: every physical line stands alone (the shell does not continue a comment that ends in a
  #    backslash, so `ls # note \` + `gh pr close 5` runs both);
  #  - joined: a backslash-newline continues the line (`git push \` + `origin HEAD:main` is one command);
  #  - joined except after a comment (the shell's real behaviour; needed for `ls # c \` + `git push \` +
  #    `origin HEAD:main`, which the other two views each get wrong).
  # Without a backslash-newline in the command all three are the same text, so only one scan runs.
  plain=$(printf '%s\n' "$raw" | strip_heredocs 0)
  scan_text "$plain"
  case "$raw" in
    *'\'$'\n'*)
      prev=$plain
      joined=$(printf '%s\n' "$raw" | strip_heredocs 1 | join_continuations)
      if [ "$joined" != "$prev" ]; then scan_text "$joined"; prev=$joined; fi
      joined=$(printf '%s\n' "$raw" | strip_heredocs 2)   # awk did every join itself: no perl pass, it ignores comments
      if [ "$joined" != "$prev" ] && [ "$joined" != "$plain" ]; then scan_text "$joined"; fi ;;
  esac
  allow
}

# ---------- Read / Grep / Edit / Write ----------
tool_path() { jq -r '[.tool_input.file_path, .tool_input.notebook_path, .tool_input.path] | map(select(. != null and . != "")) | first // ""' <<<"$INPUT"; }

check_read() {
  local p g
  p=$(tool_path)
  g=$(jq -r '.tool_input.glob // ""' <<<"$INPUT")
  if [ -n "$p" ] && is_env_token "$p"; then emit_deny "reading .env files would put credentials into the session. Scripts that need them read .env themselves; .env.example is fine."; fi
  if [ -n "$g" ] && is_env_token "$g"; then emit_deny "searching .env files would put credentials into the session."; fi
  case "$p" in *release-token*|*release-ready*|*migrate-token*|*migrate-confirmed*|*.agent/secret*) emit_deny "token and secret files are managed by the gate scripts only." ;; esac
  allow
}

check_write() {
  local p abs
  p=$(tool_path)
  [ -n "$p" ] || allow
  abs=$(resolve_path "$p" "$CWD_PHYS")
  case "$p" in *release-token*|*release-ready*|*migrate-token*|*migrate-confirmed*|*.agent/secret*) emit_deny "token and secret files are managed by the gate scripts only." ;; esac
  if is_tamper_path "$abs"; then emit_deny "editing hooks, settings or the guard ($abs) would disable the guardrails. Ask the user."; fi
  if is_migration_path "$abs" && committed_migration "$abs"; then
    emit_deny "$p is an already-committed migration; never edit it. Write a NEW numbered migration file that alters it."
  fi
  if is_goal_path "$abs"; then check_goal_write "$abs"; fi
  allow
}

# ---------- Supabase MCP ----------
readonly_sql() { # stdin: sql -> 0 if it is a single read-only statement
  perl -0777 -e '
    my $s = <STDIN>;
    $s =~ s{/\*.*?\*/}{ }gs; $s =~ s/--[^\n]*//g;
    $s =~ s{\$([A-Za-z_]*)\$.*?\$\1\$}{ }gs; $s =~ s/\x27(?:[^\x27]|\x27\x27)*\x27/\x27\x27/g;
    $s =~ s/^\s+|[\s;]+$//g; my $l = lc $s;
    exit 1 if $l eq "" || $l =~ /;/;
    exit 1 unless $l =~ /^(select|with|show|explain|table|values)\b/;
    exit 1 if $l =~ /^explain\s+(\([^)]*\)\s*)?analyze/ || $l =~ /^explain\s.*\banalyze\b/;
    exit 1 if $l =~ /\b(insert|update|delete|drop|alter|create|truncate|grant|revoke|comment|copy|call|do|vacuum|reindex|refresh|merge|lock|set|reset|into|listen|notify|execute|prepare|cluster|security|discard)\b/;
    exit 1 if $l =~ /\b(nextval|setval|pg_terminate_backend|pg_cancel_backend|pg_reload_conf|pg_read_file|pg_ls_dir|lo_import|lo_export|dblink|pg_advisory\w*|pg_sleep)\b/;
    exit 1 if $l =~ /\bfor\s+(update|share|no\s+key\s+update|key\s+share)\b/;
    exit 0;'
}

check_supabase_mcp() {
  local q
  case "$TOOL" in
    *__apply_migration) emit_deny "Supabase apply_migration bypasses the migration ledger. Write a numbered migration file, run migrate-gate.sh, then db-migrate.ts --apply." ;;
    *__execute_sql)
      q=$(jq -r '.tool_input.query // ""' <<<"$INPUT")
      if ! printf '%s' "$q" | readonly_sql; then
        emit_deny "execute_sql is limited to a single read-only statement (SELECT/WITH/SHOW/EXPLAIN without ANALYZE, no locking or side-effect functions). Anything that changes data or schema must be a numbered migration."
      fi ;;
  esac
  allow
}

check_send_mcp() { # rule 10 (D18): drafts only
  local op=${TOOL_LC##*__}
  case "$op" in *draft*) allow ;; esac
  case "$op" in
    *send*|reply|*_reply|reply_*|forward|*_forward|forward_*|*post_message*|*schedule_message*|*reply_to*|*reply_all*|*replyall*|*postmessage*|*update_message|*upload_file*)
      emit_deny "rule 10: sessions write drafts and never send (D18). Save it as a draft and notify the user to send it." ;;
  esac
  allow
}

case "$TOOL" in
  Bash|Monitor) check_bash ;;   # Monitor runs a shell command too ({command, description, timeout_ms})
  Read|Grep) check_read ;;
  Edit|Write|MultiEdit|NotebookEdit) check_write ;;
  *) case "$TOOL_LC" in
       mcp__*supabase*) check_supabase_mcp ;;
       mcp__*gmail*|mcp__*slack*|mcp__*discord*|mcp__*telegram*) check_send_mcp ;;
       *) allow ;;
     esac ;;
esac
