#!/usr/bin/env bash
# migrate-gate.sh: additive passes, destructive blocked, lint, token vs guard on db-migrate --apply.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
link_kit
MG="$BIN/migrate-gate.sh"

M=$(mk_repo mig); MP=$(cd "$M" && pwd -P)
write_goal "$M" "true" auto
GOOD=$'create table public.notes (id uuid primary key, body text);\nalter table public.notes enable row level security;\ngrant select, insert on public.notes to authenticated;'
commit_file "$M" db/migrations/0001_init.sql "$GOOD"
git -C "$M" push -q origin main; git -C "$M" fetch -q origin
mgate() { (cd "$M" && "$MG" "$@" 2>&1); }
newmig() { mkdir -p "$M/db/migrations"; printf '%s\n' "$2" >"$M/db/migrations/$1"; }
reset() { rm -f "$M"/db/migrations/0002_* "$M"/db/migrations/0003_* "$M"/db/migrations/0004_*; rm -rf "$M/db/rollback" "$M/.agent/migrate-token" "$M/.agent/migrate-confirmed"; write_goal "$M" "true" auto; }
expect_pass() { reset; newmig 0002_t.sql "$2"; out=$(mgate); assert_eq "$1" "0" "$?"; assert_contains "$1 (message)" "$out" "PASS"; }
expect_fail() { reset; newmig 0002_t.sql "$3"; out=$(mgate); rc=$?; assert_eq "$1" "1" "$rc"; assert_contains "$1 (reason)" "$out" "$2"; }

# ---------- additive changes pass autonomously ----------
expect_pass "additive: new table with RLS and grants" $'create table public.t2 (id int primary key);\nalter table public.t2 enable row level security;\ngrant select on public.t2 to authenticated;'
expect_pass "additive: add column" 'alter table public.notes add column tag text;'
expect_pass "additive: add index" 'create index notes_body_idx on public.notes (body);'
expect_pass "additive: create policy (mentions 'for update' and 'for delete')" $'create policy p1 on public.notes for update to authenticated using (true);\ncreate policy p2 on public.notes for delete to authenticated using (true);'
expect_pass "additive: DELETE with a WHERE clause" "delete from public.notes where body = 'x';"
expect_pass "additive: UPDATE with a WHERE clause" "update public.notes set body = 'y' where id is not null;"
expect_pass "additive: drop constraint is not data loss" 'alter table public.notes drop constraint notes_pkey;'
expect_pass "additive: comments mentioning destructive words are ignored" $'-- we do NOT drop table notes here\n/* truncate would be bad */\nalter table public.notes add column c int;'
expect_pass "additive: function body with a scoped delete" $'create or replace function public.f() returns void language plpgsql as $$ begin delete from public.notes where body is null; end $$;'
expect_pass "additive: quoted schema/table names" $'create table "public"."t3" (id int);\nalter table "public"."t3" enable row level security;\ngrant select on table "public"."t3" to authenticated;'

# ---------- lint failures ----------
expect_fail "lint: table without RLS" "ENABLE ROW LEVEL SECURITY" $'create table public.t4 (id int);\ngrant select on public.t4 to authenticated;'
expect_fail "lint: table without an explicit grant" "missing explicit GRANT" $'create table public.t5 (id int);\nalter table public.t5 enable row level security;'
expect_fail "lint: anon role" "anon" $'alter table public.notes add column z int;\ngrant select on public.notes to anon;'
expect_fail "lint: top-level BEGIN/COMMIT" "transaction control" $'begin;\nalter table public.notes add column q int;\ncommit;'

# ---------- destructive: blocked until rollback file AND human confirm ----------
reset; newmig 0002_drop.sql 'drop table public.notes;'
out=$(mgate); rc=$?
assert_eq "destructive DROP TABLE: blocked" "1" "$rc"
assert_contains "destructive: says BLOCKED and names the rollback file" "$out" "needs db/rollback/0002_drop.down.sql"
assert_no_file "destructive: no token minted" "$M/.agent/migrate-token"
assert_contains "destructive: notifies the human (Blocked + repo name)" "$(cat "$AGENT_HOME/notify.log")" "mig (main): Blocked"
mkdir -p "$M/db/rollback"; echo 'create table public.notes (id uuid primary key, body text);' >"$M/db/rollback/0002_drop.down.sql"
out=$(mgate); assert_eq "destructive with rollback file but no confirmation: still blocked" "1" "$?"
assert_contains "destructive: waits for the human" "$out" "waiting for the human"
gdeny "the agent cannot confirm (guard)" "$M" "$MG --confirm db/migrations/0002_drop.sql"
out=$(cd "$M" && "$MG" --confirm db/migrations/0002_drop.sql 2>&1); assert_eq "human --confirm succeeds" "0" "$?"
out=$(mgate); assert_eq "destructive with rollback and human confirmation: passes" "0" "$?"
echo '-- edited after confirmation' >>"$M/db/migrations/0002_drop.sql"
out=$(mgate); assert_eq "confirmation is bound to the file contents (edit -> blocked again)" "1" "$?"
# forged confirmation
reset; newmig 0002_drop.sql 'drop table public.notes;'; mkdir -p "$M/db/rollback" "$M/.agent/migrate-confirmed"; echo x >"$M/db/rollback/0002_drop.down.sql"
h=$(shasum -a 256 "$M/db/migrations/0002_drop.sql" | cut -d' ' -f1); echo forged >"$M/.agent/migrate-confirmed/$h"
out=$(mgate); assert_eq "forged confirmation file rejected" "1" "$?"
for spec in "truncate:truncate public.notes;" "DROP COLUMN:alter table public.notes drop column body;" "DROP COLUMN (no COLUMN keyword):alter table public.notes drop body;" \
            "DELETE without WHERE:delete from public.notes;" "UPDATE without WHERE:update public.notes set body = null;" \
            "ALTER COLUMN TYPE:alter table public.notes alter column body type varchar(3);" \
            "DROP TABLE:drop table if exists public.notes cascade;" "DROP/TRUNCATE inside a DO:do \$\$ begin drop table public.notes; end \$\$;" ; do
  reset; newmig 0002_d.sql "${spec#*:}"; out=$(mgate); rc=$?
  assert_eq "destructive (${spec%%:*}): blocked" "1" "$rc"
  assert_contains "destructive (${spec%%:*}): flagged as BLOCKED" "$out" "BLOCKED, destructive"
done

# ---------- the set of files: edits to committed migrations, pending list, tests ----------
reset; echo '-- tweak' >>"$M/db/migrations/0001_init.sql"
out=$(mgate); assert_eq "editing a committed migration fails the gate" "1" "$?"
assert_contains "edit: tells the agent to write a new file" "$out" "NEW numbered file"
git -C "$M" checkout -q db/migrations/0001_init.sql
reset; newmig 0002_a.sql 'alter table public.notes add column a int;'
write_goal "$M" "true" auto "migrate_pending_cmd: printf 'pending: db/migrations/0002_a.sql\n'"
out=$(mgate); assert_eq "pending list equals files created here: passes" "0" "$?"
write_goal "$M" "true" auto "migrate_pending_cmd: printf 'pending: db/migrations/0002_a.sql\npending: db/migrations/0009_someone_else.sql\n'"
out=$(mgate); assert_eq "pending list has files this session did not create: fails" "1" "$?"
assert_contains "pending mismatch lists both" "$out" "0009_someone_else.sql"
write_goal "$M" "true" auto "migrate_test_command: false"
out=$(mgate); assert_eq "failing migration tests: fails" "1" "$?"
write_goal "$M" "true" auto "migrate_test_command: true"
out=$(mgate); assert_eq "passing migration tests: passes" "0" "$?"

# ---------- token vs guard on --apply ----------
APPLY='bun scripts/db-migrate.ts --apply'
reset; newmig 0002_a.sql 'alter table public.notes add column a int;'
gdeny "--apply without a token" "$M" "$APPLY"
mgate >/dev/null
gallow "--apply with a valid token" "$M" "$APPLY"
gallow "--apply with a valid token via cd" "/tmp" "cd $MP && $APPLY"
newmig 0003_b.sql 'alter table public.notes add column b int;'
gdeny "--apply after another migration file appeared (token stale)" "$M" "$APPLY"
mgate >/dev/null; gallow "re-gated: --apply allowed again" "$M" "$APPLY"
echo '-- changed' >>"$M/db/migrations/0003_b.sql"
gdeny "--apply after a file changed (token stale)" "$M" "$APPLY"
printf 'set=x\ntime=1\nsig=y\n' >"$M/.agent/migrate-token"
gdeny "--apply with a forged token" "$M" "$APPLY"

# ---------- guardrail 7: committed migrations are never edited ----------
reset
tdeny "Edit tool on a committed migration" Edit "$M" "$(jq -n --arg p "$MP/db/migrations/0001_init.sql" '{file_path:$p,old_string:"a",new_string:"b"}')"
tdeny "Write tool over a committed migration" Write "$M" "$(jq -n --arg p "$MP/db/migrations/0001_init.sql" '{file_path:$p,content:"x"}')"
tdeny "Write tool, relative path" Write "$M" "$(jq -n '{file_path:"db/migrations/0001_init.sql",content:"x"}')"
tdeny "MultiEdit tool on a committed migration" MultiEdit "$M" "$(jq -n --arg p "$MP/db/migrations/0001_init.sql" '{file_path:$p,edits:[]}')"
gdeny "sed -i on a committed migration" "$M" "sed -i '' 's/notes/n/' db/migrations/0001_init.sql"
gdeny "append to a committed migration" "$M" 'echo "-- x" >> db/migrations/0001_init.sql'
gdeny "rm a committed migration" "$M" 'rm db/migrations/0001_init.sql'
gdeny "mv a committed migration" "$M" 'mv db/migrations/0001_init.sql db/migrations/0001_renamed.sql'
gdeny "tee into a committed migration" "$M" 'echo x | tee db/migrations/0001_init.sql'
gdeny "edit committed migration via cd" "/tmp" "cd $MP/db/migrations && sed -i '' 's/a/b/' 0001_init.sql"
tallow "Write tool: a NEW migration file is fine" Write "$M" "$(jq -n --arg p "$MP/db/migrations/0005_new.sql" '{file_path:$p,content:"select 1;"}')"
tallow "Edit tool on an uncommitted migration" Edit "$M" "$(jq -n --arg p "$MP/db/migrations/0002_a.sql" '{file_path:$p,old_string:"a",new_string:"b"}')"
newmig 0004_x.sql 'select 1;'
gallow "append to an uncommitted migration" "$M" 'echo "-- x" >> db/migrations/0004_x.sql'
gallow "create a new migration with a heredoc" "$M" $'cat > db/migrations/0006_new.sql <<EOF\nalter table t add column c int;\nEOF'
gallow "reading a committed migration" "$M" 'cat db/migrations/0001_init.sql'
gallow "migrations in a plain folder with no repo" "$WORK" 'echo x > /tmp/some/migrations/0001.sql'
exit 0
