#!/usr/bin/env bash
# state-sync.sh: two "machines" (two AGENT_HOMEs) share one bare remote; nothing here reaches the network.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
S="$BIN/state-sync.sh"
export STATE_SYNC_FG=1
REMOTE="$WORK/state.git"; git init -q --bare -b main "$REMOTE"
A="$WORK/mac-a"; B="$WORK/mac-b"
on() { local h=$1; shift; AGENT_HOME="$h" STATE_SYNC_DIRS="$h" "$S" "$@"; }

# machine A: existing state, a secret and a log that must stay local
mkdir -p "$A/sessions/s-a" "$A/secret" "$A/tokens"
echo "status: done" >"$A/sessions/s-a/STATE.md"; : >"$A/sessions/s-a/.meta.flock"
echo "hunter2" >"$A/secret/key"; echo tok >"$A/tokens/t"; echo log >"$A/events.jsonl"
on "$A" init "$REMOTE" >/dev/null
files=$(git --git-dir="$REMOTE" ls-tree -r --name-only main)
assert_contains "init A: session state pushed" "$files" "sessions/s-a/STATE.md"
assert_not_contains "init A: secret/ stays local" "$files" "secret/"
assert_not_contains "init A: tokens/ stays local" "$files" "tokens/"
assert_not_contains "init A: events.jsonl stays local" "$files" "events.jsonl"
assert_not_contains "init A: lock files stay local" "$files" ".meta.flock"

# machine B: its own sessions, then init from the same remote
mkdir -p "$B/sessions/s-b"; echo "status: idle" >"$B/sessions/s-b/NEXT.md"
on "$B" init "$REMOTE" >/dev/null
assert_file "init B: gets A's session" "$B/sessions/s-a/STATE.md"
assert_contains "init B: pushes its own session" "$(git --git-dir="$REMOTE" ls-tree -r --name-only main)" "sessions/s-b/NEXT.md"

# a later change on B reaches A through the hooks' sync
echo "status: working" >"$B/sessions/s-b/STATE.md"
printf '{}' | on "$B" end
on "$A" sync
assert_file "sync: A gets B's new file" "$A/sessions/s-b/STATE.md"
assert_file "sync: A got B's init session" "$A/sessions/s-b/NEXT.md"

# the same file changed on both: rebase aborted, nothing forced, A keeps its version
echo "from A" >"$A/sessions/s-a/STATE.md"; echo "from B" >"$B/sessions/s-a/STATE.md"
on "$B" sync
on "$A" sync; rc=$?
assert_eq "conflict: sync reports failure" "1" "$rc"
assert_eq "conflict: A's file untouched" "from A" "$(cat "$A/sessions/s-a/STATE.md")"
assert_contains "conflict: logged" "$(cat "$A/state-sync.log")" "conflicts"
assert_eq "conflict: remote keeps B's version" "from B" "$(git --git-dir="$REMOTE" show main:sessions/s-a/STATE.md)"
assert_no_file "conflict: no rebase left open" "$A/.git/rebase-merge"

# stop is throttled; STATE_SYNC_OFF turns everything off
echo x >"$B/sessions/s-b/x"; printf '{}' | AGENT_HOME="$B" STATE_SYNC_DIRS="$B" STATE_SYNC_GAP=600 "$S" stop
echo y >"$B/sessions/s-b/y"; printf '{}' | AGENT_HOME="$B" STATE_SYNC_DIRS="$B" STATE_SYNC_GAP=600 "$S" stop
files=$(git --git-dir="$REMOTE" ls-tree -r --name-only main)
assert_contains "stop: first stop syncs" "$files" "sessions/s-b/x"
assert_not_contains "stop: second stop within the gap waits" "$files" "sessions/s-b/y"
echo z >"$B/sessions/s-b/z"; STATE_SYNC_OFF=1 on "$B" sync
assert_not_contains "off: nothing synced" "$(git --git-dir="$REMOTE" ls-tree -r --name-only main)" "sessions/s-b/z"

# a folder that is no git repo is left alone
mkdir -p "$WORK/plain"; on "$WORK/plain" sync; assert_eq "no repo: no-op" "0" "$?"
exit 0
