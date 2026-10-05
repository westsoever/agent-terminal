#!/usr/bin/env bash
# release-gate.sh - the gate in front of `git push origin HEAD:main` (PLAN 5.2)
#
#   release-gate.sh               run the gate for HEAD; on success mint a one-commit release token
#                                 (release_mode auto) or a "ready" marker + notification (confirm)
#   release-gate.sh --approve     HUMAN ONLY (guard.sh denies agents): turn the ready marker for HEAD
#                                 into a token
#   release-gate.sh --verify [SHA]  exit 0 only if a valid token exists for SHA (default HEAD).
#                                 Used by guard.sh and by the pre-push hook.
#
# Checks, in order: clean tree, up to date with origin/<base>, evidence file parses clean for this exact
# HEAD (including a "## not examined" section), review file for this HEAD (unless GOAL.md says
# review: off), test_command passes. The model's own verdict is ignored.
# Tokens are HMAC-signed with a per-machine secret so a file written by hand is rejected.
# Env: AGENT_HOME  RELEASE_GATE_TIMEOUT (1800 s)  RELEASE_GATE_REMOTE (origin)
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
REMOTE=${RELEASE_GATE_REMOTE:-origin}

MODE=run
VSHA=""
case "${1:-}" in
  --verify) MODE=verify; VSHA=${2:-} ;;
  --approve) MODE=approve ;;
  -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo "release-gate: unknown argument $1" >&2; exit 64 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || { echo "release-gate: not inside a git repository" >&2; exit 1; }
AGENT_DIR="$ROOT/.agent"
TOKEN="$AGENT_DIR/release-token"
READY="$AGENT_DIR/release-ready"

# file format: kind=..., sha=..., time=..., sig=...
field() { sed -n "s/^$2=//p" "$1" | head -1; }

write_signed() { # file kind sha
  local now sig
  now=$(date +%s)
  sig=$(sign "$2" "$3" "$now")
  mkdir -p "$AGENT_DIR"
  printf 'kind=%s\nsha=%s\ntime=%s\nsig=%s\n' "$2" "$3" "$now" "$sig" >"$1"
}

check_signed() { # file kind expected-sha -> 0 valid; message on stderr
  local f=$1 kind=$2 want=$3 t_sha t_time t_sig
  if [ ! -f "$f" ]; then echo "no ${kind} for this checkout; run release-gate.sh first" >&2; return 1; fi
  t_sha=$(field "$f" sha); t_time=$(field "$f" time); t_sig=$(field "$f" sig)
  if [ "$(field "$f" kind)" != "$kind" ] || [ "$(sign "$kind" "$t_sha" "$t_time")" != "$t_sig" ]; then
    echo "$kind signature invalid (edited or forged); run release-gate.sh" >&2; return 1
  fi
  if [ "$t_sha" != "$want" ]; then
    echo "$kind is for ${t_sha:0:7} but the commit being pushed is ${want:0:7}; re-run release-gate.sh" >&2; return 1
  fi
}

if [ "$MODE" = verify ]; then
  [ -n "$VSHA" ] || VSHA=$(git rev-parse HEAD)
  check_signed "$TOKEN" release-token "$VSHA"
  exit $?
fi

HEAD_SHA=$(git rev-parse HEAD)
CWD=$ROOT; NAME=$(basename "$ROOT")

if [ "$MODE" = approve ]; then
  check_signed "$READY" release-ready "$HEAD_SHA" || exit 1
  write_signed "$TOKEN" release-token "$HEAD_SHA"
  rm -f "$READY"
  echo "release-gate: approved. Token minted for ${HEAD_SHA:0:7}. Push with: git push $REMOTE HEAD:main"
  exit 0
fi

GOAL="$AGENT_DIR/GOAL.md"
TEST_CMD=$(goal_get "$GOAL" test_command)
RELEASE_MODE=$(goal_get "$GOAL" release_mode); [ -n "$RELEASE_MODE" ] || RELEASE_MODE=confirm
BASE=$(goal_get "$GOAL" base_branch); [ -n "$BASE" ] || BASE=main
case "$TEST_CMD" in ''|'<'*) echo "release-gate: FAIL: no test_command in <repo>/.agent/GOAL.md (the release gate is opt-in per repo: add a GOAL.md with test_command and release_mode)" >&2; exit 1 ;; esac
case "$RELEASE_MODE" in auto|confirm) ;; *) echo "release-gate: FAIL: release_mode must be auto or confirm (got '$RELEASE_MODE')" >&2; exit 1 ;; esac

fail() { ev release "$(jq -nc --arg s "$HEAD_SHA" --arg m "$1" '{sha:$s,outcome:"gate-fail",detail:$m}')"; echo "release-gate: FAIL: $1" >&2; exit 1; }

# 1. clean tree
if [ -n "$(git status --porcelain)" ]; then fail "working tree is not clean (commit or stash first)"; fi

# 2. up to date with the remote base
git fetch --quiet "$REMOTE" "$BASE" 2>/dev/null || fail "cannot fetch $REMOTE/$BASE"
git merge-base --is-ancestor "FETCH_HEAD" HEAD 2>/dev/null || fail "HEAD is not up to date with $REMOTE/$BASE (merge or rebase first)"

# 3. evidence
EVIDENCE="$AGENT_DIR/verify/$HEAD_SHA.md"
[ -f "$EVIDENCE" ] || fail "no evidence file at .agent/verify/$HEAD_SHA.md (see templates/VERIFY.md)"

block() { # file section -> contents of the fenced block under "## section"
  awk -v n="$2" '
    { low = tolower($0) }
    low ~ "^## *" n "[[:space:]]*$" { insec = 1; seen = 1; next }
    /^## / { insec = 0; infence = 0 }
    insec && /^```/ { infence = !infence; next }
    insec && infence { print }
    END { if (!seen) exit 3 }
  ' "$1"
}
bullets() { # file section -> bullet lines under "## section"
  awk -v n="$2" '
    { low = tolower($0) }
    low ~ "^## *" n "[[:space:]]*$" { insec = 1; next }
    /^## / { insec = 0 }
    insec && /^[[:space:]]*[-*][[:space:]]/ { sub(/^[[:space:]]*[-*][[:space:]]+/, ""); print }
  ' "$1"
}
kv() { sed -n "s/^$2:[[:space:]]*//p" "$1" | head -1 | sed 's/[[:space:]]*$//'; }
compact_section() { # file section -> the section's text without whitespace or HTML comments
  awk -v n="$2" '{ low = tolower($0) } low ~ "^## *" n "[[:space:]]*$" { insec = 1; next } /^## / { insec = 0 } insec' "$1" \
    | sed 's/<!--.*-->//g' | tr -d '[:space:]'
}

PROBLEMS=""
problem() { PROBLEMS="$PROBLEMS"$'\n'"  - $1"; }

[ "$(kv "$EVIDENCE" commit)" = "$HEAD_SHA" ] || problem "commit: must be exactly $HEAD_SHA"
SURFACE=$(kv "$EVIDENCE" surface)
case "$SURFACE" in
  ui)
    shot=$(kv "$EVIDENCE" screenshot)
    if [ -z "$shot" ] || [ ! -s "$ROOT/$shot" ]; then problem "surface: ui needs an existing screenshot file (screenshot: ${shot:-<empty>})"; fi
    [ -n "$(kv "$EVIDENCE" app_url)" ] || problem "surface: ui needs app_url"
    [ -n "$(bullets "$EVIDENCE" exercised)" ] || problem "surface: ui needs at least one bullet under ## exercised"
    ;;
  none)
    reason=$(kv "$EVIDENCE" none_reason)
    [ "${#reason}" -ge 10 ] || problem "surface: none needs a none_reason of at least 10 characters"
    ;;
  *) problem "surface: must be ui or none" ;;
esac

# allowed patterns: each needs a reason after '#', and none may match everything
ALLOWED=""
while IFS= read -r line; do
  [ -n "$line" ] || continue
  case "$line" in *'#'*) ;; *) problem "allowed pattern without a '# reason': $line"; continue ;; esac
  pat=$(printf '%s' "$line" | sed 's/[[:space:]]*#.*$//')
  if [ -z "$pat" ] || printf 'zz-sentinel-9f3a GET http://x/y 200' | grep -Eq -- "$pat"; then
    problem "allowed pattern is empty or matches everything: $line"; continue
  fi
  ALLOWED="$ALLOWED$pat"$'\n'
done < <(bullets "$EVIDENCE" allowed)

is_allowed() {
  local pat
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    if printf '%s' "$1" | grep -Eq -- "$pat"; then return 0; fi
  done <<<"$ALLOWED"
  return 1
}

CONSOLE=""; NETWORK=""
CONSOLE=$(block "$EVIDENCE" console) || problem "missing '## console' section with a fenced block"
NETWORK=$(block "$EVIDENCE" network) || problem "missing '## network' section with a fenced block"

while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != none ] || continue
  if printf '%s' "$line" | grep -Eiq '\[error\]|(^|[^[:alnum:]])error([^[:alnum:]]|$)|uncaught|unhandled|exception'; then
    is_allowed "$line" || problem "console error: $line"
  fi
done <<<"$CONSOLE"

while IFS= read -r line; do
  [ -n "${line//[[:space:]]/}" ] || continue
  [ "$(printf '%s' "$line" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" != none ] || continue
  last=${line##*[[:space:]]}
  status=$(printf '%s' "$last" | tr -d '[](),' | sed 's/^status=//')
  case "$status" in
    [0-9][0-9][0-9]) ;;
    *) problem "network line must end with an HTTP status: $line"; continue ;;
  esac
  case "$status" in
    2??|304) ;;
    *) is_allowed "$line" || problem "network request with status $status: $line" ;;
  esac
done <<<"$NETWORK"

ne=$(compact_section "$EVIDENCE" "not examined")
[ "${#ne}" -ge 10 ] || problem "## not examined needs at least 10 characters: what this verification did not check"

[ -z "$PROBLEMS" ] || fail "evidence file .agent/verify/$HEAD_SHA.md rejected:$PROBLEMS"

# 3b. review (D14): required unless GOAL.md says exactly "review: off" (only the user can write that)
if [ "$(goal_get "$GOAL" review)" = off ]; then
  echo "release-gate: review skipped by GOAL.md (review: off)"
else
  REVIEW="$AGENT_DIR/review/$HEAD_SHA.md"
  [ -f "$REVIEW" ] || fail "no review file at .agent/review/$HEAD_SHA.md. Dispatch a fresh read-only reviewer subagent with 'git diff origin/$BASE...HEAD' and the lenses in templates/review-lenses/, and have it write that file (format: templates/REVIEW.md)."
  RP=""
  [ "$(kv "$REVIEW" commit)" = "$HEAD_SHA" ] || RP="$RP"$'\n'"  - commit: must be exactly $HEAD_SHA"
  if [ "$(file_mtime "$REVIEW")" -lt "$(git log -1 --format=%ct HEAD)" ]; then RP="$RP"$'\n'"  - the review is older than the commit; review again"; fi
  rne=$(compact_section "$REVIEW" "not examined")
  [ "${#rne}" -ge 10 ] || RP="$RP"$'\n'"  - ## not examined needs at least 10 characters"
  nb=$(kv "$REVIEW" blocking)
  # more than 6 characters is never a real count; also keeps the numeric tests below from erroring
  case "$nb" in ''|*[!0-9]*|???????*) RP="$RP"$'\n'"  - blocking: must be a number"; nb=0 ;; esac
  # The [blocking] scan always runs, whatever blocking: says. A finding is a -, * or numbered (1. / 1))
  # bullet, optionally bold, tagged [blocking] in any case. Prints "<found> <unresolved>"; a finding is
  # unresolved unless a non-empty resolved: line follows before the next bullet or ## heading.
  scan=$(awk '
    { low = tolower($0) }
    low ~ /^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]*\**[[:space:]]*\[blocking\]/ { f++; if (p) n++; p = 1; next }
    p && /^[[:space:]]*resolved:[[:space:]]*[^[:space:]]/ { p = 0; next }
    p && /^[[:space:]]*([-*]|[0-9]+[.)])[[:space:]]/ { n++; p = 0 }
    /^## / { if (p) n++; p = 0 }
    END { if (p) n++; print f + 0, n + 0 }' "$REVIEW") || scan=""
  case "$scan" in
    [0-9]*" "[0-9]*) found=${scan% *}; unresolved=${scan#* } ;;
    *) found=0; unresolved=0; RP="$RP"$'\n'"  - could not scan the [blocking] findings" ;;
  esac
  [ "$found" -ge "$nb" ] || RP="$RP"$'\n'"  - blocking: $nb but only $found [blocking] bullets found"
  [ "$unresolved" -eq 0 ] || RP="$RP"$'\n'"  - $unresolved blocking finding(s) without a resolved: line"
  [ -z "$RP" ] || fail "review file .agent/review/$HEAD_SHA.md rejected:$RP"
fi

# 4. tests
OUT=$(mktemp "${TMPDIR:-/tmp}/ching-gate.XXXXXX")
trap 'rm -f "$OUT"' EXIT
rc=0
(cd "$ROOT" && perl -e 'alarm shift @ARGV; exec @ARGV' "${RELEASE_GATE_TIMEOUT:-1800}" bash -c "$TEST_CMD") >"$OUT" 2>&1 </dev/null || rc=$?
if [ "$rc" -ne 0 ]; then
  tail -n 30 "$OUT" >&2
  fail "test_command failed (exit $rc): $TEST_CMD"
fi

# 5. token or ready marker
rm -f "$TOKEN" "$READY"
ev release "$(jq -nc --arg s "$HEAD_SHA" --arg m "$RELEASE_MODE" '{sha:$s,outcome:("gate-pass-" + $m)}')"
if [ "$RELEASE_MODE" = auto ]; then
  write_signed "$TOKEN" release-token "$HEAD_SHA"
  echo "release-gate: PASS. Token minted for ${HEAD_SHA:0:7} (auto). Push with: git push $REMOTE HEAD:main"
else
  write_signed "$READY" release-ready "$HEAD_SHA"
  NOTIFY_CWD="$ROOT" "$SELF_DIR/notify.sh" ready "Release gate passed for ${HEAD_SHA:0:7}. Run release-gate.sh --approve to allow the push." </dev/null || true
  echo "release-gate: PASS (confirm mode). Waiting for the human: release-gate.sh --approve. Do NOT push yet."
fi
