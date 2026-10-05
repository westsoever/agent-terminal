#!/usr/bin/env bash
# migrate-gate.sh - gate in front of `db-migrate.ts --apply` (PLAN 5.3). Per repo; opt-in by a repo
# .agent/GOAL.md (migrations_dir, migrate_pending_cmd, migrate_test_command keys).
#
#   migrate-gate.sh                run the gate; on success mint a token for the exact set of migration
#                                  files this session created
#   migrate-gate.sh --verify       exit 0 only if the token matches the current set (guard.sh uses this)
#   migrate-gate.sh --confirm FILE HUMAN ONLY (guard.sh denies agents): confirm a destructive migration
#
# Rules: only NEW numbered files (created this session = added vs origin/<base>, staged, or untracked);
# editing a committed migration fails; lint: no top-level BEGIN/COMMIT, no `anon`, every CREATE TABLE has
# ENABLE ROW LEVEL SECURITY and an explicit GRANT; destructive statements (DROP TABLE/COLUMN/SCHEMA/TYPE,
# TRUNCATE, DELETE/UPDATE without WHERE, ALTER COLUMN TYPE) need db/rollback/<name>.down.sql AND a human
# --confirm. Additive files pass autonomously.
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

MODE=run
CONFIRM_FILE=""
case "${1:-}" in
  --verify) MODE=verify ;;
  --confirm) MODE=confirm; CONFIRM_FILE=${2:?--confirm needs a migration file} ;;
  -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  '') ;;
  *) echo "migrate-gate: unknown argument $1" >&2; exit 64 ;;
esac

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[ -n "$ROOT" ] || { echo "migrate-gate: not inside a git repository" >&2; exit 1; }
cd "$ROOT"
AGENT_DIR="$ROOT/.agent"
GOAL="$AGENT_DIR/GOAL.md"
MIG_DIR=$(goal_get "$GOAL" migrations_dir); [ -n "$MIG_DIR" ] || MIG_DIR=db/migrations
BASE=$(goal_get "$GOAL" base_branch); [ -n "$BASE" ] || BASE=main
ROLLBACK_DIR=db/rollback
TOKEN="$AGENT_DIR/migrate-token"
CONFIRM_DIR="$AGENT_DIR/migrate-confirmed"

fhash() { shasum -a 256 "$1" | cut -d' ' -f1; }

created_files() { # migration files created this session, one per line, sorted
  {
    git diff --name-only --diff-filter=A "origin/$BASE...HEAD" -- "$MIG_DIR" 2>/dev/null || true
    git diff --name-only --cached --diff-filter=A -- "$MIG_DIR" 2>/dev/null || true
    git ls-files -o --exclude-standard -- "$MIG_DIR" 2>/dev/null || true
  } | grep '\.sql$' | sort -u || true
}
edited_committed() { # committed migration files modified/deleted/renamed vs origin or working tree
  {
    git diff --name-only --diff-filter=MDRT "origin/$BASE...HEAD" -- "$MIG_DIR" 2>/dev/null || true
    git diff --name-only --diff-filter=MDRT HEAD -- "$MIG_DIR" 2>/dev/null || true
  } | grep '\.sql$' | sort -u || true
}
set_hash() { # hash over names + contents of the created set
  local f
  { created_files | while IFS= read -r f; do [ -n "$f" ] || continue; printf '%s %s\n' "$f" "$(fhash "$f")"; done; echo end; } \
    | shasum -a 256 | cut -d' ' -f1
}

if [ "$MODE" = confirm ]; then
  [ -f "$CONFIRM_FILE" ] || { echo "migrate-gate: no such file $CONFIRM_FILE" >&2; exit 1; }
  h=$(fhash "$CONFIRM_FILE")
  mkdir -p "$CONFIRM_DIR"
  printf '%s\n' "$(sign confirm "$h")" >"$CONFIRM_DIR/$h"
  echo "migrate-gate: confirmed destructive migration $CONFIRM_FILE"
  exit 0
fi

if [ "$MODE" = verify ]; then
  [ -f "$TOKEN" ] || { echo "no migrate token; run migrate-gate.sh first" >&2; exit 1; }
  t_set=$(meta_get "$TOKEN" set); t_time=$(meta_get "$TOKEN" time); t_sig=$(meta_get "$TOKEN" sig)
  [ "$(sign migrate-token "$t_set" "$t_time")" = "$t_sig" ] || { echo "migrate token signature invalid" >&2; exit 1; }
  [ "$t_set" = "$(set_hash)" ] || { echo "migration files changed since the gate ran; re-run migrate-gate.sh" >&2; exit 1; }
  exit 0
fi

# ---- lint (perl): prints "ERR: ..." and "DESTRUCTIVE: ..." lines for one file ----
read -r -d '' LINT_PL <<'PERL' || true
use strict; use warnings;
local $/; my $raw = <STDIN>; my $s = $raw;
$s =~ s{/\*.*?\*/}{ }gs;                 # block comments
$s =~ s/--[^\n]*//g;                     # line comments
my @bodies; $s =~ s{\$([A-Za-z_]*)\$(.*?)\$\1\$}{ push @bodies, $2; ' BODY ' }gse;   # dollar-quoted
$s =~ s/'(?:[^']|'')*'/''/g;             # string literals
my @stmts = grep { /\S/ } split /;/, $s;
my (@err, @dest);
my $lc = lc $s; $lc =~ s/"//g;
push @err, "uses the anon role (not allowed)" if $lc =~ /\banon\b/;
my %tables;
for my $st (@stmts) {
  my $t = lc $st; $t =~ s/^\s+|\s+$//g; $t =~ s/\s+/ /g;
  push @err, "top-level transaction control ($t); the runner wraps each file in one transaction"
    if $t =~ /^(begin|commit|rollback|end|start transaction)( work| transaction)?$/;
  if ($t =~ /^create (?:unlogged |temp |temporary )?table (?:if not exists )?([\w."]+)/) {
    my $n = $1; $n =~ s/"//g; $n =~ s/^public\.//; $tables{$n} = 1;
  }
  push @dest, "DROP TABLE/SCHEMA/TYPE/DATABASE/EXTENSION" if $t =~ /^drop (table|schema|type|database|extension)\b/;
  push @dest, "TRUNCATE" if $t =~ /^truncate\b/;
  push @dest, "DELETE without WHERE" if $t =~ /^delete from\b/ && $t !~ /\bwhere\b/;
  push @dest, "UPDATE without WHERE" if $t =~ /^update [\w."]+ (?:as \w+ )?set\b/ && $t !~ /\bwhere\b/;
  if ($t =~ /^alter table\b/) {
    push @dest, "DROP COLUMN" if $t =~ /\bdrop (?:column\b|(?!constraint\b|default\b|not null\b|identity\b|expression\b|policy\b))/;
    push @dest, "ALTER COLUMN TYPE (may narrow)" if $t =~ /\balter (?:column )?[\w"]+ (?:set data )?type\b/;
  }
}
for my $b (@bodies) { my $x = lc $b; push @dest, "DROP/TRUNCATE inside a DO/function body" if $x =~ /\b(drop (table|column|schema|type)|truncate)\b/; }
for my $n (sort keys %tables) {
  my $q = quotemeta $n; my $nq = $q; 
  push @err, "table $n: missing ALTER TABLE ... ENABLE ROW LEVEL SECURITY"
    unless $lc =~ /alter\s+table\s+(?:only\s+)?(?:if\s+exists\s+)?(?:public\.)?"?$q"?\s+enable\s+row\s+level\s+security/;
  push @err, "table $n: missing explicit GRANT"
    unless $lc =~ /grant\s[^;]*?\son\s+(?:table\s+)?(?:public\.)?"?$q"?(?:\s|,|;|$)/;
}
my %seen; print "ERR: $_\n" for grep { !$seen{$_}++ } @err;
%seen = (); print "DESTRUCTIVE: $_\n" for grep { !$seen{$_}++ } @dest;
PERL

fail() { echo "migrate-gate: FAIL: $1" >&2; exit 1; }

EDITED=$(edited_committed)
[ -z "$EDITED" ] || fail "edits an already-committed migration (write a NEW numbered file instead): $(echo "$EDITED" | tr '\n' ' ')"

CREATED=$(created_files)

# pending list from the dry run, if configured: must equal the created set
PENDING_CMD=${MIGRATE_PENDING_CMD:-$(goal_get "$GOAL" migrate_pending_cmd)}
if [ -n "$PENDING_CMD" ]; then
  pending=$(bash -c "$PENDING_CMD" 2>&1 </dev/null | grep -oE '[A-Za-z0-9_.-]+\.sql' | sort -u || true) \
    || fail "migrate_pending_cmd failed"
  mine=$(printf '%s\n' "$CREATED" | sed '/^$/d' | while IFS= read -r f; do basename "$f"; done | sort -u)
  [ "$pending" = "$mine" ] || fail "pending migrations differ from the files this session created.
  pending (dry run): $(echo "$pending" | tr '\n' ' ')
  created here:      $(echo "$mine" | tr '\n' ' ')"
fi

ERRS=""; DESTRUCTIVE_FILES=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  out=$(perl -e "$LINT_PL" <"$f")
  while IFS= read -r l; do
    case "$l" in
      ERR:*) ERRS="$ERRS"$'\n'"  - $f: ${l#ERR: }" ;;
      DESTRUCTIVE:*) DESTRUCTIVE_FILES="$DESTRUCTIVE_FILES$f"$'\t'"${l#DESTRUCTIVE: }"$'\n' ;;
    esac
  done <<<"$out"
done <<<"$CREATED"
[ -z "$ERRS" ] || fail "lint errors:$ERRS"

if [ -n "$DESTRUCTIVE_FILES" ]; then
  BLOCKED=""
  while IFS=$'\t' read -r f why; do
    [ -n "$f" ] || continue
    name=$(basename "$f" .sql)
    if [ ! -f "$ROLLBACK_DIR/$name.down.sql" ]; then
      BLOCKED="$BLOCKED"$'\n'"  - $f ($why): needs $ROLLBACK_DIR/$name.down.sql"
      continue
    fi
    h=$(fhash "$f")
    if [ ! -f "$CONFIRM_DIR/$h" ] || [ "$(cat "$CONFIRM_DIR/$h")" != "$(sign confirm "$h")" ]; then
      BLOCKED="$BLOCKED"$'\n'"  - $f ($why): waiting for the human: run 'migrate-gate.sh --confirm $f' in your own terminal"
    fi
  done <<<"$DESTRUCTIVE_FILES"
  if [ -n "$BLOCKED" ]; then
    NOTIFY_CWD="$ROOT" "$SELF_DIR/notify.sh" blocked "Destructive migration needs your confirmation." </dev/null || true
    fail "BLOCKED, destructive migration:$BLOCKED"
  fi
fi

TEST_CMD=${MIGRATE_TEST_CMD:-$(goal_get "$GOAL" migrate_test_command)}
if [ -n "$TEST_CMD" ]; then
  rc=0; out=$(bash -c "$TEST_CMD" 2>&1 </dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then printf '%s\n' "$out" | tail -n 30 >&2; fail "migrate_test_command failed (exit $rc)"; fi
fi

mkdir -p "$AGENT_DIR"
now=$(date +%s); sh=$(set_hash)
printf 'set=%s\ntime=%s\nsig=%s\n' "$sh" "$now" "$(sign migrate-token "$sh" "$now")" >"$TOKEN"
n=$(printf '%s\n' "$CREATED" | sed '/^$/d' | wc -l | tr -d ' ')
echo "migrate-gate: PASS for $n new migration file(s). Token minted; you may run the --apply now."
