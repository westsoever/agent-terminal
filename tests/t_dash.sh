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
# next_action sentinels ("(none)" from the template, "none" from finished sessions) are not real next actions.
# New sessions only, added after every ranking/lane assertion above so those keep their meaning.
BLK="$WORK/blockf"; DNF="$WORK/donef"; mkdir -p "$BLK" "$DNF"
reg sidK "$BLK" blocked; mkdir -p "$AGENT_HOME/sessions/sidK"
printf '# State\nstatus: blocked\n<!-- ching:checkpoint -->\nblocker: need the X token\nnext_action: (none)\n<!-- /ching:checkpoint -->\n' >"$AGENT_HOME/sessions/sidK/STATE.md"
reg sidF "$DNF" done; mkdir -p "$AGENT_HOME/sessions/sidF"
printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nblocker: none\nnext_action: none\n<!-- /ching:checkpoint -->\n' >"$AGENT_HOME/sessions/sidF/STATE.md"
# a worktree-only row (repoE has no session) goes through the other row producer
printf '# State\nstatus: blocked\n<!-- ching:checkpoint -->\nblocker: need the Y key\nnext_action: (None)\n<!-- /ching:checkpoint -->\n' >"$E/.agent/STATE.md"
nx2=$("$BIN/dash.sh" --next)
assert_contains "next: sentinel next_action falls back to the blocker" "$(printf '%s\n' "$nx2" | grep blockf)" "need the X token"
assert_not_contains "next: (none) next_action is not shown" "$(printf '%s\n' "$nx2" | grep blockf)" "(none)"
assert_contains "next: worktree row falls back to its blocker" "$(printf '%s\n' "$nx2" | grep repoE)" "need the Y key"
assert_not_contains "next: worktree row hides a (None) next_action" "$(printf '%s\n' "$nx2" | grep repoE)" "(None)"
rm -f "$AGENT_HOME/inbox.seen"
fin=$("$BIN/dash.sh" --inbox | sed -n '/^FINISHED/,$p')
assert_contains "inbox: done session with next_action none is listed" "$fin" "donef"
assert_not_contains "inbox: FINISHED omits a none next_action" "$(printf '%s\n' "$fin" | grep donef)" "next:"
# --inbox on a machine where ~/.agent does not exist yet must not die writing the marker
assert_ok "inbox: fresh machine (no AGENT_HOME yet) exits 0" env AGENT_HOME="$WORK/fresh-ah" CLAUDE_DIR="$WORK/empty-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh" --inbox
assert_file "inbox: fresh machine gets its inbox.seen" "$WORK/fresh-ah/inbox.seen"

# ---------- fix wave FC1-2: the registry loop reads each meta in one pass and skips ended ones early ----------
# (the 3000-file timing is not a unit test; this guards what the loop must keep listing and hiding)
FAH="$WORK/fc1-ah"; mkdir -p "$FAH/sessions"
fmeta() { # sid folder state updated_or_- meta_age_stamp(touch -t, "-" = now) transcript_or_- [extra raw text]
  local d="$FAH/sessions/$1"; mkdir -p "$d"
  { printf 'cwd=%s\nroot=\nname=%s\nbranch=main\nstate=%s\n' "$WORK/$2" "$2" "$3"
    if [ "$4" != - ]; then printf 'updated=%s\n' "$4"; fi
    if [ "$6" != - ]; then printf 'transcript=%s\n' "$6"; fi
    if [ -n "${7:-}" ]; then printf '%s' "$7"; fi; } >"$d/meta"
  if [ "$5" != - ]; then touch -t "$5" "$d/meta"; fi
}
OLDU=$((NOW - 10 * 86400)); OLDT=202001010000
FT="$WORK/fc1-fresh.jsonl"; printf '{}\n' >"$FT"
fmeta fe1 fcended1 ended "$OLDU" "$OLDT" -                   # ended and old
fmeta fe2 fcended2 ended "$NOW" - -                          # ended but recent: never listed
fmeta fw1 fcwork1 working "$NOW" - -                         # recent: listed
fmeta fo1 fcoldfresh working "$OLDU" "$OLDT" "$FT"           # old meta, fresh transcript: listed through the transcript
fmeta fo2 fcoldgone working "$OLDU" "$OLDT" -                # old meta, no transcript: outside the window
fmeta fo3 fcnoupd working - - -                              # no updated key: the file mtime is used
fmeta fd1 fcdup working "$NOW" - - $'state=ended\n'          # duplicate key: the first line wins, so not ended
fmeta fn1 fcnonl working "$NOW" - - 'ctx_level=healthy'      # last line without a newline is still read
out=$(AGENT_HOME="$FAH" CLAUDE_DIR="$WORK/fc1-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh")
assert_not_contains "registry: an old ended session is not listed" "$out" "fcended1"
assert_not_contains "registry: a recent ended session is not listed" "$out" "fcended2"
assert_contains "registry: a recent session is listed" "$out" "fcwork1 [main]"
assert_contains "registry: an old meta with a fresh transcript is listed" "$out" "fcoldfresh [main]"
assert_not_contains "registry: an old meta with no fresh transcript is outside the window" "$out" "fcoldgone"
assert_contains "registry: a meta without updated falls back to its file mtime" "$out" "fcnoupd [main]"
assert_contains "registry: the first of two state lines wins" "$out" "fcdup [main]"
assert_contains "registry: a last line without a newline is read" "$(printf '%s\n' "$out" | grep fcnonl)" "●"
assert_contains "registry: summary counts only the listed sessions" "$out" "5 session(s)"

# ---------- fix wave FC1-4: --next must not die of SIGPIPE when many rows reach head ----------
FAH2="$WORK/fc1-many-ah"; mkdir -p "$FAH2"
LONGN=$(head -c 250 /dev/zero | tr '\0' 'x')
mkdir -p "$FAH2"/sessions/m{1..300}
i=1
while [ "$i" -le 300 ]; do
  printf 'cwd=%s\nroot=\nname=n\nbranch=main\nstate=working\nupdated=%s\n' "$WORK/${LONGN}$i" "$NOW" >"$FAH2/sessions/m$i/meta"
  i=$((i + 1))
done
rc=0; out=$(AGENT_HOME="$FAH2" CLAUDE_DIR="$WORK/fc1-claude" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh" --next --all 2>/dev/null) || rc=$?
assert_eq "next: 300 long rows exit 0 (no SIGPIPE under pipefail)" "0" "$rc"
assert_eq "next: 300 long rows still print exactly 5 lines" "5" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_contains "next: first line is numbered 1" "$(printf '%s\n' "$out" | sed -n 1p)" "1. xxxx"
assert_contains "next: fifth line is numbered 5 with its score" "$(printf '%s\n' "$out" | sed -n 5p)" "5. xxxx"
assert_contains "next: lines carry the score" "$(printf '%s\n' "$out" | sed -n 5p)" "[score "

# ---------- fix wave FD-1: --next ranking: blocked above working, recency clamped ----------
NXC="$WORK/nx-claude"; mkdir -p "$NXC"
nxmeta() { # AGENT_HOME sid name state hours_old [goal] [extra raw meta text]
  local d="$1/sessions/$2" root=""; mkdir -p "$d"
  if [ "${6:-}" = goal ]; then root="$WORK/nxroot-$3"; mkdir -p "$root/.agent"; : >"$root/.agent/GOAL.md"; fi
  printf 'cwd=%s\nroot=%s\nbranch=main\nstate=%s\nupdated=%s\n%s' "$WORK/$3" "$root" "$4" "$((NOW - $5 * 3600))" "${7:-}" >"$d/meta"
}
nxrun() { AGENT_HOME="$1" CLAUDE_DIR="$NXC" AGENT_REPOS_FILE="$WORK/none" DASH_NOW="$NOW" "$BIN/dash.sh" --next --hours 400; }
nxorder() { sed -n 's/^[0-9]*\. \([^ ]*\) .*/\1/p' | tr '\n' ' '; }
# A: equal importance. A blocked session stays on top however long it has waited (it used to score below a fresh working one at 15 h).
NA="$WORK/nx-a"
nxmeta "$NA" a1 nblk blocked 20; nxmeta "$NA" a2 ninp input 20; nxmeta "$NA" a3 nstall working 0 "" "stalled_at=$NOW"$'\n'
nxmeta "$NA" a4 nhand working 0 "" $'ctx_level=handoff\n'; nxmeta "$NA" a5 nwork working 0
assert_eq "next: blocked 20 h > input 20 h > stalled > handoff > working at equal importance" "nblk ninp nstall nhand nwork " "$(nxrun "$NA" | nxorder)"
NA2="$WORK/nx-a2"
nxmeta "$NA2" a1 nblkold blocked 300; nxmeta "$NA2" a2 nwork working 0
assert_eq "next: a session blocked for 300 h still beats a fresh working one" "nblkold nwork " "$(nxrun "$NA2" | nxorder)"
# B: importance 3 (GOAL.md) still counts: a goal-backed working session beats an ordinary blocked one, but not a goal-backed blocked one
NB="$WORK/nx-b"
nxmeta "$NB" b1 nbg blocked 30 goal; nxmeta "$NB" b2 nwg working 0 goal; nxmeta "$NB" b3 nbl blocked 20
assert_eq "next: blocked goal > working goal > blocked plain" "nxroot-nbg nxroot-nwg nbl " "$(nxrun "$NB" | nxorder)"
# C: recency is clamped to 1: a future-dated row (clock skew) scores like a fresh one
NC="$WORK/nx-c"
nxmeta "$NC" c1 nfutw working -10; nxmeta "$NC" c2 nfutb blocked -10
out=$(nxrun "$NC")
assert_contains "next: a future-dated working row scores 4.00, not more" "$(printf '%s\n' "$out" | grep nfutw)" "[score 4.00]"
assert_contains "next: a future-dated blocked row scores 10.00, not more" "$(printf '%s\n' "$out" | grep nfutb)" "[score 10.00]"
# D: equal scores (both past the floor) fall back to newest first
ND="$WORK/nx-d"
nxmeta "$ND" d1 nb50 blocked 50; nxmeta "$ND" d2 nb30 blocked 30; nxmeta "$ND" d3 nb40 blocked 40
assert_eq "next: blocked sessions at the same score list the newest first" "nb30 nb40 nb50 " "$(nxrun "$ND" | nxorder)"
exit 0
