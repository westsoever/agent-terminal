#!/usr/bin/env bash
# dash.sh: machine-wide discovery across unrelated repos, plain folders and ~; --speak.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOW=$(date +%s)
reg() { # sid cwd state [updated]
  local d="$AGENT_HOME/sessions/$1"; mkdir -p "$d"
  local root; root=$(git -C "$2" rev-parse --show-toplevel 2>/dev/null || true)
  local name; if [ -n "$root" ]; then name=$(basename "$root"); else name=$(basename "$2"); fi
  printf 'cwd=%s\nroot=%s\nname=%s\nbranch=%s\nstate=%s\nupdated=%s\n' "$(cd "$2" && pwd -P)" "$root" "$name" \
    "$(git -C "$2" symbolic-ref --short -q HEAD 2>/dev/null || true)" "$3" "${4:-$NOW}" >"$d/meta"
}
transcript() { # sid cwd [touch -t stamp]
  local d="$CLAUDE_DIR/projects/-enc-$(basename "$2")"; mkdir -p "$d"
  printf '{"type":"user","cwd":"%s","sessionId":"%s"}\n' "$(cd "$2" && pwd -P)" "$1" >"$d/$1.jsonl"
  if [ -n "${3:-}" ]; then touch -t "$3" "$d/$1.jsonl"; fi
}

# four unrelated locations plus two repos known only from transcripts
A=$(mk_repo repoA); B=$(mk_repo repoB); C=$(mk_repo repoC); D=$(mk_repo repoD); E=$(mk_repo repoE); OLD=$(mk_repo repoOld)
PLAIN="$WORK/plainf"; mkdir -p "$PLAIN"
reg sidA "$A" working; reg sidB "$B" working; reg sidP "$PLAIN" done; reg sidH "$HOME" working; reg sidEnded "$OLD" ended
mkdir -p "$AGENT_HOME/sessions/sidB"; printf '# State\n\n## Blocked\n- need the staging token\n' >"$AGENT_HOME/sessions/sidB/STATE.md"
transcript sidC "$C"; transcript sidD "$D"            # unregistered: discovered from transcripts only
transcript sidA "$A"                                   # already registered: must not be listed twice
transcript sidOld "$OLD" 202001010000                  # months old: outside the window
# worktree of repoA holding repo state but no session; repoE only via ~/.agent-repos
git -C "$A" worktree add -q -b wt1 "$WORK/repoA-wt1" >/dev/null 2>&1
mkdir -p "$WORK/repoA-wt1/.agent"; printf '# State\nstatus: idle\n' >"$WORK/repoA-wt1/.agent/STATE.md"
mkdir -p "$E/.agent"; printf '# State\nstatus: idle\n' >"$E/.agent/STATE.md"
printf '# extra repos\n%s\n' "$E" >"$AGENT_REPOS_FILE"

out=$("$BIN/dash.sh")
assert_contains "lists a registered repo session" "$out" "repoA [main]"
assert_contains "lists a second unrelated repo" "$out" "repoB [main]"
assert_contains "discovers an unregistered repo from transcripts" "$out" "repoC"
assert_contains "discovers another unregistered repo from transcripts" "$out" "repoD"
assert_contains "lists a plain non-git folder" "$out" "plainf"
assert_contains "lists the home directory as ~" "$out" "$(printf '~ ')"
assert_not_contains "ended sessions are hidden" "$out" "repoOld"
assert_eq "a session in both registry and transcripts is listed once" "1" "$(printf '%s\n' "$out" | grep -c 'repoA \[main\] sidA')"
assert_contains "worktree with repo state but no session is listed" "$out" "repoA-wt1 [wt1]"
assert_contains "repo from ~/.agent-repos is listed (optional extra)" "$out" "repoE"
assert_contains "blocked session shows its blocker" "$(printf '%s\n' "$out" | grep repoB)" "need the staging token"
assert_contains "blocked state is shown" "$(printf '%s\n' "$out" | grep repoB)" "blocked"
assert_contains "done state is shown" "$(printf '%s\n' "$out" | grep plainf)" "done"
assert_contains "summary counts sessions and active ones" "$out" "8 session(s), 5 active"
assert_not_contains "no warning at 5 active" "$out" "WARNING"

sp=$("$BIN/dash.sh" --speak)
assert_contains "speak: active count" "$sp" "5 active sessions out of 8."
assert_contains "speak: names the blocked session and why" "$sp" "repoB is blocked: need the staging token."
assert_contains "speak: finished count" "$sp" "1 finished."
assert_not_contains "speak: no paths read aloud" "$sp" "$WORK"
assert_not_contains "speak: no slashes at all" "$sp" "/"
assert_not_contains "speak: no warning at 5" "$sp" "more than five"
assert_eq "speak: one short paragraph (single line)" "1" "$(printf '%s\n' "$sp" | wc -l | tr -d ' ')"

# more than 5 active: warn
for i in 1 2 3 4; do reg "sidX$i" "$A" working; done
assert_contains "plain output warns above 5 active" "$("$BIN/dash.sh")" "WARNING: 9 active sessions"
assert_contains "speak warns above 5 active" "$("$BIN/dash.sh" --speak)" "more than five active sessions"

# needs-input and nothing blocked
rm -rf "$AGENT_HOME/sessions/sidX"* "$AGENT_HOME/sessions/sidB/STATE.md"; reg sidB "$B" input
assert_contains "speak: needs-input session" "$("$BIN/dash.sh" --speak)" "repoB needs your input."
reg sidB "$B" working
assert_contains "speak: nothing blocked summary" "$("$BIN/dash.sh" --speak)" "Nothing is blocked."

# a fresh machine
out=$(AGENT_HOME="$WORK/empty-ah" CLAUDE_DIR="$WORK/empty-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh")
assert_contains "no sessions: friendly line" "$out" "no Claude sessions"
out=$(AGENT_HOME="$WORK/empty-ah" CLAUDE_DIR="$WORK/empty-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh" --speak)
assert_contains "no sessions: spoken line" "$out" "No Claude sessions"
# sessions from transcripts alone (no hooks installed yet) across two unrelated repos
out=$(AGENT_HOME="$WORK/empty-ah" CLAUDE_DIR="$CLAUDE_DIR" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh")
assert_contains "transcript-only discovery: repoC" "$out" "repoC"
assert_contains "transcript-only discovery: repoD" "$out" "repoD"

# ---------- Phase 1.5: columns, checkpoint, inbox, next ----------
DAY=$(date -u +%Y-%m-%d)
printf 'ctx_level=handoff\n' >>"$AGENT_HOME/sessions/sidA/meta"
mkdir -p "$AGENT_HOME/tokens"; printf 'sidA 1234567\n' >"$AGENT_HOME/tokens/$DAY"
out=$("$BIN/dash.sh")
assert_contains "ctx column: handoff shows ○" "$(printf '%s\n' "$out" | grep 'repoA \[main\] sidA')" "○"
assert_contains "tok column: 1.2M" "$(printf '%s\n' "$out" | grep 'repoA \[main\] sidA')" "1.2M"
printf '# State\nstatus: blocked\n<!-- ching:checkpoint -->\nblocker: need the Supabase token\nnext_action: rerun the gate\n<!-- /ching:checkpoint -->\n\n## Blocked\n- old bullet\n' >"$AGENT_HOME/sessions/sidB/STATE.md"
reg sidB "$B" blocked
assert_contains "checkpoint blocker wins over the Blocked list" "$(printf '%s\n' "$("$BIN/dash.sh")" | grep repoB)" "need the Supabase token"
# Review Focus 1: "blocker: none" with a stale bullet is not blocked
mkdir -p "$AGENT_HOME/sessions/sidH"
printf '# State\nstatus: working\n<!-- ching:checkpoint -->\nblocker: none\n<!-- /ching:checkpoint -->\n\n## Blocked\n- stale bullet from yesterday\n' >"$AGENT_HOME/sessions/sidH/STATE.md"
assert_not_contains "blocker: none is not blocked" "$(printf '%s\n' "$("$BIN/dash.sh")" | grep '^~ ')" "blocked"
reg sidP "$PLAIN" done
mkdir -p "$C/.agent"; printf 'kind=release-ready\n' >"$C/.agent/release-ready"
ib=$("$BIN/dash.sh" --inbox)
assert_contains "inbox: needs-you lane" "$ib" "repoB [main]: blocked -- need the Supabase token"
assert_contains "inbox: ready lane from a release-ready marker" "$(printf '%s\n' "$ib" | sed -n '/^READY/,/^FINISHED/p')" "repoC"
assert_contains "inbox: finished lane" "$(printf '%s\n' "$ib" | sed -n '/^FINISHED/,$p')" "plainf"
ib2=$("$BIN/dash.sh" --inbox)
assert_not_contains "inbox: finished clears after a look" "$(printf '%s\n' "$ib2" | sed -n '/^FINISHED/,$p')" "plainf"
nx=$("$BIN/dash.sh" --next)
assert_contains "next: blocked session ranks first" "$(printf '%s\n' "$nx" | head -1)" "repoB"
assert_contains "next: shows the checkpoint next action" "$nx" "rerun the gate"
assert_eq "next: at most 5 lines" "yes" "$([ "$(printf '%s\n' "$nx" | wc -l | tr -d ' ')" -le 5 ] && echo yes || echo no)"
assert_contains "speak: leads with how many need you" "$("$BIN/dash.sh" --speak)" "needs you."
# --inbox on a machine where ~/.agent does not exist yet must not die writing the marker
assert_ok "inbox: fresh machine (no AGENT_HOME yet) exits 0" env AGENT_HOME="$WORK/fresh-ah" CLAUDE_DIR="$WORK/empty-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh" --inbox
assert_file "inbox: fresh machine gets its inbox.seen" "$WORK/fresh-ah/inbox.seen"
exit 0
