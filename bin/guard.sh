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
# migration, db-migrate --record-only, --apply without a migrate token. Extras: --no-verify, hook/settings/
# token tampering, gh pr merge, piping into a shell.
# Env: GUARD_PROTECTED_BRANCHES (default "main master" plus the remote default branch)
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PROTECTED=${GUARD_PROTECTED_BRANCHES:-"main master"}
DEFB=""

command -v jq >/dev/null 2>&1 || { echo "GUARD: jq is not installed; failing closed" >&2; exit 2; }
INPUT=$(cat)
DECIDED=0

emit_deny() {
  DECIDED=1
  jq -n --arg r "GUARD: $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
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
WRAPPERS=" sudo env command exec time nohup nice ionice xargs timeout watch caffeinate npx bunx bun pnpm yarn npm dlx x run exec bash sh zsh eval then do else if while until ! { "

tokenize() {
  local s=$1
  s=${s//\"/}; s=${s//\'/}; s=${s//\\/}
  TOKS=()
  read -r -a TOKS <<<"$s" || true
  NT=${#TOKS[@]}
}

cmd_pos() { # is token index $1 in command position (only wrappers/options/assignments before it)?
  local k=0 t b
  while [ "$k" -lt "$1" ]; do
    t=${TOKS[$k]}; b=${t##*/}
    case "$t" in
      -*|*=*|[0-9]*) ;;
      *) case "$WRAPPERS" in *" $b "*) ;; *) return 1 ;; esac ;;
    esac
    k=$((k + 1))
  done
  return 0
}

has_token() { # exact basename match anywhere
  local k=0
  while [ "$k" -lt "$NT" ]; do [ "${TOKS[$k]##*/}" != "$1" ] || return 0; k=$((k + 1)); done
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
    t=${TOKS[$k]}; b=${t##*/}
    case "$b" in
      rm|mv|cp|tee|truncate|ln|chmod|chown|dd|install|rsync|ed|unlink|shred) return 0 ;;
      sed|perl) seg_matches '-i*' && return 0 ;;
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
    *'$'*|*'`'*) emit_deny "recursive delete with an unresolved variable or substitution ($a). Use a literal path inside the repo or /tmp." ;;
  esac
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

check_push() { # $1 = index of 'push' token, $2 = git dir
  local gdir=$2 k a force=0 del=0 all=0 np=0 refs="" r cur up sha
  k=$(( $1 + 1 ))
  if [ "$SIM_UNKNOWN" -eq 1 ]; then emit_deny "git push after a cd the guard cannot resolve. Use 'git -C <literal dir> push ...'."; fi
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    case "$a" in
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
      -C) gdir=$(resolve_path "${TOKS[$((j + 1))]:-.}" "$gdir"); j=$((j + 2)) ;;
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
check_gh() { # $1 = index of gh
  local k subs="" n=0 a mut=0 hit=0 method=""
  k=$(( $1 + 1 ))
  while [ "$k" -lt "$NT" ]; do
    a=${TOKS[$k]}
    case "$a" in
      -X|--method) method=${TOKS[$((k + 1))]:-}; k=$((k + 1)) ;;
      -f|-F|--field|--raw-field|--input) mut=1 ;;
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
    " workflow run"*|" workflow dispatch"*|" run rerun"*) emit_deny "starting or re-running workflows by hand is not allowed; deploys come from CI on a push. To roll back, push a revert commit through the release gate." ;;
    " api"*)
      case "$method" in ''|GET|get) ;; *) mut=1 ;; esac
      if [ "$mut" -eq 1 ] && [ "$hit" -eq 1 ]; then emit_deny "gh api call that merges, dispatches workflows, or writes refs/contents bypasses the release gate."; fi ;;
  esac
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
  case "${TOKS[0]##*/}" in
    git) case " ${TOKS[*]} " in *" commit "*|*" tag "*|*" check-ignore "*|*" status "*) return 0 ;; esac ;;
  esac
  k=0
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}; b=${t##*/}
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
  first=${TOKS[0]##*/}
  case "$first" in
    printenv) emit_deny "printenv dumps credentials into the session." ;;
    env) [ "$NT" -gt 1 ] || emit_deny "'env' with no command dumps credentials into the session." ;;
    export|declare|typeset) seg_matches '-p' && emit_deny "listing exported variables dumps credentials into the session." ;;
    echo|printf) k=1; while [ "$k" -lt "$NT" ]; do var_is_secret "${TOKS[$k]}" && emit_deny "printing a token/secret variable is not allowed."; k=$((k + 1)); done ;;
  esac
}

check_misc() { # one segment, tokens in TOKS
  local k t b
  k=0
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}; b=${t##*/}
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

is_tamper_path() {
  case "$1" in "$SELF_DIR"|"$SELF_DIR"/*) return 0 ;; esac
  case "$1" in
    */.claude/settings.json|*/.claude/settings.local.json|*/.git/hooks|*/.git/hooks/*|*.githooks|*.githooks/*|*/ching/bin|*/ching/bin/*|*/.claude/ching|*/.claude/ching/*) return 0 ;;
  esac
  return 1
}

tamper_bash() {
  local k=0 t abs
  while [ "$k" -lt "$NT" ]; do
    t=${TOKS[$k]}
    case "$t" in -*) k=$((k + 1)); continue ;; esac
    abs=""
    case "$t" in *hooks*|*settings*|*ching*|*.sql) abs=$(resolve_path "$t" "$SIM_CWD") ;; esac
    if [ -n "$abs" ] && is_tamper_path "$abs" && seg_writes; then
      emit_deny "editing hooks, settings or the guard itself ($t) would disable the guardrails. Ask the user."
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
scan_segment() {
  SEG_RAW=$1
  tokenize "$1"
  [ "$NT" -gt 0 ] || return 0
  # track cd so later relative paths resolve like the shell would
  if [ "${TOKS[0]##*/}" = cd ] || [ "${TOKS[0]##*/}" = pushd ]; then
    local tgt=${TOKS[1]:-$HOME}
    case "$tgt" in
      *'$'*|*'`'*|-) SIM_UNKNOWN=1 ;;
      *) SIM_CWD=$(resolve_path "$tgt" "$SIM_CWD"); SIM_UNKNOWN=0 ;;
    esac
    return 0
  fi
  check_misc
}

strip_heredocs() { # drop heredoc bodies unless the heredoc feeds an interpreter
  awk '
    skip { l = $0; sub(/^[ \t]+/, "", l); if (l == word) skip = 0; next }
    {
      print
      if (match($0, /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z_0-9]*["'"'"']?/)) {
        w = substr($0, RSTART, RLENGTH); gsub(/<<-?[ \t]*|["'"'"']/, "", w)
        pre = substr($0, 1, RSTART - 1); n = split(pre, t, /[ \t]+/); interp = 0; redir = 0
        for (i = 1; i <= n; i++) {
          if (redir) { redir = 0; continue }
          if (t[i] ~ /^[0-9]*>>?$/) { redir = 1; continue }
          b = t[i]; sub(/.*\//, "", b)
          if (b ~ /^(bash|sh|zsh|python3?|node|perl|ruby|bun|deno)$/) interp = 1
        }
        if (!interp) { word = w; skip = 1 }
      }
    }'
}

check_bash() {
  local cmd seg
  cmd=$(jq -r '.tool_input.command // ""' <<<"$INPUT")
  [ -n "$cmd" ] || allow
  cmd=$(printf '%s\n' "$cmd" | strip_heredocs)
  while IFS= read -r seg; do   # pass 1: per line, for rules that need the whole line (.env readers)
    SEG_RAW=$seg; tokenize "$seg"
    if [ "$NT" -gt 0 ]; then check_env_files; fi
  done <<<"$cmd"
  while IFS= read -r seg; do   # pass 2: per simple command
    scan_segment "$seg"
  done < <(printf '%s\n' "$cmd" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/[;|&()`]/\n/g')
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

case "$TOOL" in
  Bash) check_bash ;;
  Read|Grep) check_read ;;
  Edit|Write|MultiEdit|NotebookEdit) check_write ;;
  *) case "$TOOL_LC" in mcp__*supabase*) check_supabase_mcp ;; *) allow ;; esac ;;
esac
