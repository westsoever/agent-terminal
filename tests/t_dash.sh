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
# home folder: "~" is silent in text-to-speech, so it is said as "home"
reg sidH "$HOME" input
sp=$("$BIN/dash.sh" --speak)
assert_contains "speak: home folder said as Home" "$sp" "Home needs your input."
assert_not_contains "speak: no tilde read aloud" "$sp" "~"
reg sidH "$HOME" working "$((NOW + 60))"
assert_contains "speak: latest home said as home" "$("$BIN/dash.sh" --speak)" "Latest: home is working"
reg sidH "$HOME" working

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
mkdir -p "$C/.agent"; printf 'kind=release-ready\nsha=%s\n' "$(head_of "$C")" >"$C/.agent/release-ready"
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

# ---------- fix wave FD-2/3: inbox lanes: one entry per session, newest first; READY only for the current HEAD ----------
IAH="$WORK/ib-ah"; mkdir -p "$IAH"
ibmeta() { # sid folder state hours_old [blocker]  (a plain folder: the label is the folder name)
  local d="$IAH/sessions/$1"; mkdir -p "$d" "$WORK/$2"
  printf 'cwd=%s\nroot=\nbranch=main\nstate=%s\nupdated=%s\n' "$WORK/$2" "$3" "$((NOW - $4 * 3600))" >"$d/meta"
  if [ -n "${5:-}" ]; then printf '# State\n<!-- ching:checkpoint -->\nblocker: %s\nnext_action: none\n<!-- /ching:checkpoint -->\n' "$5" >"$d/STATE.md"; fi
}
ibrun() { AGENT_HOME="$IAH" CLAUDE_DIR="$WORK/ib-claude" AGENT_REPOS_FILE="${IB_REPOS:-$WORK/none}" DASH_NOW="$NOW" "$BIN/dash.sh" --inbox --hours 100; }
lane_of() { printf '%s\n' "$1" | sed -n "/^$2/,/^[A-Z]/p" | grep '^  ' || true; }   # lines of one lane (up to the next heading)
# two distinct sessions with the same folder, branch and blocker, plus a newer one with another name (sorts after it)
ibmeta sidDup1-long afirst blocked 3 "need the token"
ibmeta sidDup2-long afirst blocked 2 "need the token"
ibmeta sidZ-long zlast blocked 1 "need the other token"
ibmeta sidFin1-long fdone done 3; ibmeta sidFin2-long fdone done 2
ib=$(ibrun)
needs=$(lane_of "$ib" "NEEDS YOU")
assert_eq "inbox: three blocked sessions give three lines (equal label+note is not merged)" "3" "$(printf '%s\n' "$needs" | grep -c .)"
assert_eq "inbox: needs-you lane is newest first, not alphabetical" "zlast afirst afirst " "$(printf '%s\n' "$needs" | sed 's/^  \([^ ]*\) .*/\1/' | tr '\n' ' ')"
assert_contains "inbox: two equal lines get the short session id" "$needs" "afirst [main]: blocked -- need the token (sidDup1)"
assert_contains "inbox: the other equal line gets its own id" "$needs" "afirst [main]: blocked -- need the token (sidDup2)"
assert_not_contains "inbox: a unique line carries no id" "$(printf '%s\n' "$needs" | grep zlast)" "(sid"
fin=$(lane_of "$ib" "FINISHED")
assert_eq "inbox: two finished sessions with the same label are two entries" "2" "$(printf '%s\n' "$fin" | grep -c fdone)"
# worktree-only rows have no session id: two different worktrees must both stay
W1="$WORK/ibwt1"; W2="$WORK/ibwt2"; git init -q -b main "$W1"; git init -q -b main "$W2"
for w in "$W1" "$W2"; do mkdir -p "$w/.agent"; printf '# State\nstatus: blocked\n<!-- ching:checkpoint -->\nblocker: stuck on %s\nnext_action: none\n<!-- /ching:checkpoint -->\n' "$(basename "$w")" >"$w/.agent/STATE.md"; done
printf '%s\n%s\n' "$W1" "$W2" >"$WORK/ib-repos"
needs=$(IB_REPOS="$WORK/ib-repos" ibrun | sed -n '/^NEEDS YOU/,/^READY/p')
assert_contains "inbox: first worktree-only row is listed" "$needs" "ibwt1 [main]: blocked -- stuck on ibwt1"
assert_contains "inbox: second worktree-only row is listed" "$needs" "ibwt2 [main]: blocked -- stuck on ibwt2"

# READY: the marker must be for the repo's current HEAD. Two sessions in one repo give one line.
RR=$(cd "$(mk_repo ibready)" && pwd -P)
for s in sidR1-long sidR2-long; do
  mkdir -p "$IAH/sessions/$s"
  printf 'cwd=%s\nroot=%s\nbranch=main\nstate=working\nupdated=%s\n' "$RR" "$RR" "$((NOW - 3600))" >"$IAH/sessions/$s/meta"
done
mkdir -p "$RR/.agent"
printf 'kind=release-ready\nsha=%s\ntime=1\nsig=x\n' "$(head_of "$RR")" >"$RR/.agent/release-ready"
ready=$(lane_of "$(ibrun)" "READY")
assert_eq "inbox: a marker for HEAD gives one READY line for two sessions of that repo" "1" "$(printf '%s\n' "$ready" | grep -c ibready)"
assert_contains "inbox: the READY line names the repo and the approve command" "$ready" "ibready: release gate passed; run release-gate.sh --approve in $RR"
commit_file "$RR" f.txt "new work" "move HEAD"
assert_eq "inbox: a marker for an older commit is not READY" "0" "$(lane_of "$(ibrun)" "READY" | grep -c ibready)"
printf 'kind=release-ready\ntime=1\nsig=x\n' >"$RR/.agent/release-ready"
assert_eq "inbox: a marker without a sha is not READY" "0" "$(lane_of "$(ibrun)" "READY" | grep -c ibready)"
printf 'kind=release-ready\nsha=%s\ntime=1\nsig=x\n' "$(head_of "$RR")" >"$RR/.agent/release-ready"
assert_eq "inbox: a marker for the new HEAD is READY again" "1" "$(lane_of "$(ibrun)" "READY" | grep -c ibready)"

# ---------- fix wave FD-4: an early-exit reader (grep -q, head) must not turn into a wrong answer under pipefail ----------
# 450 sessions with 235-char ids and cwds make the id list and the cwd column far larger than a pipe buffer.
# `printf ids | grep -q` and `cut cwd | grep -q` then die of SIGPIPE when grep stops at an early match, pipefail
# reports 141, and the membership test says "not found": a registered session listed again from its transcript,
# a worktree listed again next to the session that already sits in it.
SPA="$WORK/sp-ah"; SPC="$WORK/sp-claude"; mkdir -p "$SPA/sessions" "$SPC/projects/-enc-sp"
SPL=$(head -c 235 /dev/zero | tr '\0' 's')
SPW="$WORK/spwt"; git init -q -b main "$SPW"; mkdir -p "$SPW/.agent"; printf '# State\nstatus: idle\n' >"$SPW/.agent/STATE.md"
SPW=$(cd "$SPW" && pwd -P)
i=0
while [ "$i" -lt 450 ]; do
  sid="$SPL$(printf '%04d' "$i")"; mkdir -p "$SPA/sessions/$sid"
  cwd="$WORK/$SPL-c$i"; [ "$i" -gt 0 ] || cwd="$SPW"   # the first row sits in the worktree
  printf 'cwd=%s\nroot=\nbranch=main\nstate=working\nupdated=%s\n' "$cwd" "$NOW" >"$SPA/sessions/$sid/meta"
  i=$((i + 1))
done
for i in 0000 0001 0449; do printf '{"cwd":"%s"}\n' "$WORK/x" >"$SPC/projects/-enc-sp/$SPL$i.jsonl"; done
spdash() { AGENT_HOME="$SPA" CLAUDE_DIR="$SPC" AGENT_REPOS_FILE="$WORK/none" "$BIN/dash.sh" "$@"; }
rc=0; out=$(spdash 2>"$WORK/sp.err") || rc=$?
assert_eq "pipefail: 450 long rows exit 0" "0" "$rc"
assert_eq "pipefail: a registered session is not listed again from its transcript" "-- 450 session(s), 450 active" "$(printf '%s\n' "$out" | grep '^-- ')"
assert_eq "pipefail: the worktree holding a session gets no row of its own" "0" "$(printf '%s\n' "$out" | grep -c '^spwt .* idle ')"
assert_eq "pipefail: no broken-pipe noise on stderr" "" "$(cat "$WORK/sp.err")"

# ---------- fix wave FD-5: --inbox marks FINISHED as seen, and the docs say so ----------
help=$("$BIN/dash.sh" --help)
assert_contains "help: --inbox marks FINISHED as seen" "$help" "--inbox marks FINISHED as seen"
assert_contains "help: the whole header is printed (ends with the Env line)" "$help" "DASH_ACTIVE_MINS (30)"
assert_not_contains "help: does not print code" "$help" "set -euo pipefail"
assert_contains "dispatcher doc: --inbox marks FINISHED as seen" "$(cat "$KIT/dispatcher/AGENTS.md")" "marks FINISHED as seen"
assert_contains "kaching-functions.md: reading the inbox marks finished work as seen" "$(cat "$KIT/kaching-functions.md")" "marks it as seen"

# ---------- git sync: a SYNC lane in --inbox and one line in the default view ----------
# The snapshot is bin/sync-check.sh's sync-check.md. Written by hand here so these checks do not depend on it;
# one check at the end runs the real script.
SYA="$WORK/sy-ah"; SYC="$WORK/sy-claude"; mkdir -p "$SYA/sessions/sy1" "$SYC"
SYF="$WORK/syfolder"; mkdir -p "$SYF"
printf 'cwd=%s\nroot=\nbranch=main\nstate=working\nupdated=%s\n' "$SYF" "$NOW" >"$SYA/sessions/sy1/meta"
sydash() { AGENT_HOME="$SYA" CLAUDE_DIR="$SYC" AGENT_REPOS_FILE="$WORK/none" DASH_NOW="$NOW" "$BIN/dash.sh" "$@"; }
isoz() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
snap() { # seconds_ago [clean] : write the snapshot; two repos need attention (alpha 3 d, beta 5 h) unless "clean"
  { printf 'generated: %s\nGit sync check: test snapshot.\n\n' "$(isoz $((NOW - $1)))"
    if [ "${2:-}" != clean ]; then
      printf '## alpha -- oldest 3d\npath: /x/alpha\nneeds: 2 unpushed commits, 1 dirty worktree\nage_h: 72\n- unpushed: main +2 (3d)\n\n'
      printf '## beta -- oldest 5h\npath: /x/beta\nneeds: 1 stash\nage_h: 5\n- stash: 1 entry (5h)\n\n'
      printf 'clean: gamma, delta\n'
    else printf 'clean: gamma, delta\n'; fi
  } >"$SYA/sync-check.md"
}
rm -f "$SYA/sync-check.md"
base=$(sydash)
assert_not_contains "sync: no snapshot, the default view says nothing about it" "$base" "sync"
assert_contains "sync: no snapshot, the table still ends with its summary line" "$(printf '%s\n' "$base" | tail -1)" "-- 1 session(s), 1 active"
assert_contains "sync: no snapshot: --inbox says never run" "$(sydash --inbox | sed -n '/^SYNC/,$p')" "never run"
snap 3600
out=$(sydash)
assert_eq "sync: a fresh snapshot adds exactly one line, at the end" "$base"$'\n'"sync: 2 repos need attention (oldest 3d) - bin/dash.sh --inbox" "$out"
snap 3600; printf '## solo -- oldest 2h\npath: /x/solo\nneeds: 1 dirty worktree\nage_h: 2\n' >"$WORK/solo.txt"
{ sed -n '1,3p' "$SYA/sync-check.md"; cat "$WORK/solo.txt"; } >"$SYA/sync-check.md.new"; mv "$SYA/sync-check.md.new" "$SYA/sync-check.md"
assert_contains "sync: one repo is singular" "$(sydash | tail -1)" "sync: 1 repo needs attention (oldest 2h) - bin/dash.sh --inbox"
snap 3600
ib=$(sydash --inbox)
sy=$(printf '%s\n' "$ib" | sed -n '/^SYNC/,$p')
assert_eq "sync: the SYNC lane comes after FINISHED" "yes" "$([ "$(printf '%s\n' "$ib" | grep -n '^FINISHED' | cut -d: -f1)" -lt "$(printf '%s\n' "$ib" | grep -n '^SYNC' | cut -d: -f1)" ] && echo yes || echo no)"
assert_eq "sync: lane heading says the order and the snapshot age" "SYNC (oldest first; snapshot 1h old)" "$(printf '%s\n' "$sy" | head -1)"
assert_eq "sync: one line per repo, oldest first" "  alpha: 2 unpushed commits, 1 dirty worktree (oldest 3d)"$'\n'"  beta: 1 stash (oldest 5h)" "$(printf '%s\n' "$sy" | sed -n '2,$p')"
snap 3600 clean
assert_eq "sync: a clean snapshot prints nothing in the default view" "$base" "$(sydash)"
assert_eq "sync: a clean snapshot: the lane says (nothing)" "(nothing)" "$(sydash --inbox | sed -n '/^SYNC/,$p' | sed -n 2p | sed 's/^ *//')"
snap $((23 * 3600))
assert_not_contains "sync: 23 h old is not stale" "$(sydash --inbox | sed -n '/^SYNC/,$p')" "stale"
snap $((30 * 3600))
out=$(sydash)
assert_contains "sync: a snapshot older than 24 h is shown as stale in the default view" "$(printf '%s\n' "$out" | tail -1)" "sync: stale snapshot (30h old): 2 repos need attention (oldest 3d) - bin/dash.sh --inbox"
assert_eq "sync: ... and the lane heading says stale snapshot" "SYNC (oldest first; stale snapshot, 30h old: run bin/sync-check.sh)" "$(sydash --inbox | sed -n '/^SYNC/p')"
snap $((30 * 3600)) clean
assert_contains "sync: a stale clean snapshot is still worth a line" "$(sydash | tail -1)" "sync: stale snapshot (30h old): clean when last run - bin/dash.sh --inbox"
assert_not_contains "sync: --speak never mentions it" "$(sydash --speak)" "sync"
assert_not_contains "sync: --next never mentions it" "$(sydash --next)" "sync"
printf 'not a snapshot\n' >"$SYA/sync-check.md"
rc=0; out=$(sydash --inbox 2>&1) || rc=$?
assert_eq "sync: an unreadable snapshot does not break --inbox" "0" "$rc"
rc=0; out=$(sydash 2>&1) || rc=$?
assert_eq "sync: ... nor the default view" "0" "$rc"
rm -f "$SYA/sync-check.md"
assert_eq "sync: removing the snapshot brings the old output back, byte for byte" "$base" "$(sydash)"
# the real script and the real dash together
SYR=$(cd "$(mk_repo syrepo)" && pwd -P); printf 'u\n' >"$SYR/untracked.txt"
printf '%s\n' "$SYR" >"$WORK/sy-repos"
KACHING_INCLUDE_SANDBOX=1 SYNC_NO_FETCH=1 AGENT_HOME="$SYA" AGENT_REPOS_FILE="$WORK/sy-repos" "$BIN/sync-check.sh" --quiet
assert_contains "sync: sync-check.sh then dash.sh: the count line" "$(sydash | tail -1)" "sync: 1 repo needs attention (oldest <1h) - bin/dash.sh --inbox"
assert_contains "sync: ... and the lane" "$(sydash --inbox | sed -n '/^SYNC/,$p')" "  syrepo: 1 dirty worktree (oldest <1h)"

# ---------- Phase 6: the PROPOSALS lane (spec 6.1) ----------
PAH="$WORK/pr-ah"; PCL="$WORK/pr-claude"; mkdir -p "$PAH" "$PCL"
prdash() { AGENT_HOME="$PAH" CLAUDE_DIR="$PCL" AGENT_REPOS_FILE="$WORK/none" DASH_NOW="$NOW" "$BIN/dash.sh" "$@"; }
assert_eq "proposals: no proposals folder: the lane says (nothing)" "  (nothing)" "$(lane_of "$(prdash --inbox)" PROPOSALS)"
assert_no_file "proposals: dash never creates the proposals folder" "$PAH/proposals"
assert_eq "proposals: the lane sits between FINISHED and SYNC" "FINISHED PROPOSALS SYNC" \
  "$(prdash --inbox | grep -oE '^(FINISHED|PROPOSALS|SYNC)' | tr '\n' ' ' | sed 's/ $//')"
assert_not_contains "proposals: none, --speak says nothing about them" "$(prdash --speak)" "proposal"
PP="$PAH/proposals"; mkdir -p "$PP/archive"
mkprop() { # file status sessions days first-sentences
  local id=${1%.md}
  printf 'id: %s\nkind: %s\nstatus: %s\ncreated: 2026-10-14T05:31:02Z\ncomponent: corrections\nfingerprint: %s\nsessions: %s\ndays: %s\ntarget: ~/.agents/CLAUDE.md\n\n## proposal\n%s\n\n## evidence\n- (none)\n' \
    "$id" "${id%%-*}" "$2" "$(printf '%s' "$id" | shasum | cut -c1-40)" "$3" "$4" "$5" >"$PP/$1"
}
mkprop rule-no-version-bump.md open 3 2 "Add a rule that sessions never bump the version. The owner releases by hand."
mkprop skill-sync-loop.md open 5 2 "Make a skill for the sync loop!
It repeats."
mkprop rule-later.md "snoozed:2999-01-01" 9 9 "Snoozed until later."
mkprop rule-back.md "snoozed:2000-01-01" 1 1 "A snooze that ran out."
mkprop rule-done.md approved 7 7 "Already approved at the top."
cp "$PP/rule-no-version-bump.md" "$PP/archive/rule-old.md"
printf 'weekly report\n' >"$PP/report-2026-W41.md"
pl=$(lane_of "$(prdash --inbox)" PROPOSALS)
assert_eq "proposals: open ones, most sessions first, as kind id: first sentence (sessions/days)" \
  "  skill skill-sync-loop: Make a skill for the sync loop! (5 sessions/2 days)
  rule rule-no-version-bump: Add a rule that sessions never bump the version. (3 sessions/2 days)
  rule rule-back: A snooze that ran out. (1 sessions/1 days)" "$pl"
assert_not_contains "proposals: a snooze that has not run out is hidden" "$pl" "rule-later"
assert_not_contains "proposals: archived ones are hidden" "$pl" "rule-old"
assert_not_contains "proposals: decided ones are hidden" "$pl" "rule-done"
assert_not_contains "proposals: the weekly report is not a proposal" "$pl" "report"
sp=$(prdash --speak)
assert_contains "proposals: --speak adds one sentence with the count" "$sp" "3 proposals waiting."
assert_eq "proposals: --speak says it once" "1" "$(printf '%s' "$sp" | grep -o 'proposals waiting' | wc -l | tr -d ' ')"
rm -f "$PP/skill-sync-loop.md" "$PP/rule-back.md"
assert_contains "proposals: one waiting is singular" "$(prdash --speak)" "1 proposal waiting."
assert_not_contains "proposals: the default view does not list them" "$(prdash)" "no-version-bump"
assert_not_contains "proposals: dash never sends a notification (it does not call notify.sh)" "$(grep -v '^#' "$BIN/dash.sh")" "notify.sh"

# ---------------- --route: the dispatcher's routing list (live Claude Code sessions only) ----------------
# Its own AGENT_HOME and CLAUDE_DIR so the registry fixtures above do not leak in. Live pids are background
# sleeps (each needs its own tty for the focus tests); the tty lookup is a fake ps (DASH_PS_TTY_CMD) that maps
# pid -> tty from $WORK/route-ttys and logs each call.
RAH="$WORK/route-ah"; RCD="$WORK/route-claude"; mkdir -p "$RAH/sessions"
RNOW=1792250000
cat >"$WORK/fake-ps" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/fake-ps.log"
f="$(dirname "$0")/route-ttys"; [ -f "$f" ] || exit 0
IFS=, read -r -a want <<<"$1"
while read -r p t; do for w in "${want[@]}"; do if [ "$p" = "$w" ]; then printf '%5s %s\n' "$p" "$t"; fi; done; done <"$f"
EOS
chmod +x "$WORK/fake-ps"
route() { AGENT_HOME="$RAH" CLAUDE_DIR="$RCD" DASH_NOW="$RNOW" DASH_PS_TTY_CMD="$WORK/fake-ps" "$BIN/dash.sh" --route; }
rjson() { # file pid sid cwd name status(''= absent) [kind]
  jq -nc --argjson p "$2" --arg s "$3" --arg c "$4" --arg n "$5" --arg st "$6" --arg k "${7:-interactive}" \
    '{pid:$p,sessionId:$s,cwd:$c,name:$n,status:$st,kind:$k,startedAt:1} | if $st == "" then del(.status) else . end' \
    >"$RCD/sessions/$1.json"
}
rt() { local IFS=$'\t'; printf '%s' "$*"; }   # one expected TSV line
RHDR=$(rt name message_to status state state_dir notes focus branch)
assert_eq "route: no sessions folder at all prints the header only" "$RHDR" "$(route)"
mkdir -p "$RCD/sessions"
assert_eq "route: an empty sessions folder prints the header only" "$RHDR" "$(route)"

sleep 600 & L1=$!; sleep 600 & L2=$!; sleep 600 & L3=$!; sleep 600 & L4=$!
sleep 600 & DEAD=$!; kill "$DEAD"; wait "$DEAD" 2>/dev/null
trap 'kill $L1 $L2 $L3 $L4 2>/dev/null' EXIT
printf '%s ttys001\n%s ttys002\n%s ttys003\n%s ??\n%s ttys009\n' "$L1" "$L2" "$L3" "$L4" "$$" >"$WORK/route-ttys"

RA=$(mk_repo routeA); RB=$(mk_repo routeB); RA=$(cd "$RA" && pwd -P); RB=$(cd "$RB" && pwd -P)
HP=$(cd "$HOME" && pwd -P); RPLAIN="$WORK/routeplain"; mkdir -p "$RPLAIN"; RPLAIN=$(cd "$RPLAIN" && pwd -P)
git -C "$RB" checkout -q -b feat
# s1: repo A, meta says working, STATE.md in the agent sessions dir (it wins over the repo's .agent/STATE.md)
rjson s1 "$L1" sid-r1 "$RA" routeA-Sessions idle
mkdir -p "$RAH/sessions/sid-r1"; printf 'cwd=%s\nroot=%s\nbranch=metabranch\nstate=working\n' "$RA" "$RA" >"$RAH/sessions/sid-r1/meta"
printf '# State\n' >"$RAH/sessions/sid-r1/STATE.md"
mkdir -p "$RA/.agent"; printf '# State\n' >"$RA/.agent/STATE.md"
# s2: the home folder, busy, no meta, no STATE.md anywhere
rjson s2 "$L2" sid-r2 "$HP" homeChat busy
# s3: repo B, meta without root or branch: root and branch from git, STATE.md in the repo's .agent
rjson s3 "$L3" sid-r3 "$RB" routeB-x busy
mkdir -p "$RB/.agent"; printf '# State\n' >"$RB/.agent/STATE.md"
mkdir -p "$RAH/sessions/sid-r3"; printf 'state=input\n' >"$RAH/sessions/sid-r3/meta"
# s8: a plain folder, no status in the json, no tty
rjson s8 "$L4" sid-r8 "$RPLAIN" plainS ""
# not listed: a dead pid, the dispatcher (by name, and by cwd), a claude-mem observer session, unreadable json
rjson s4 "$DEAD" sid-r4 "$RA" deadOne idle
rjson s5 "$$" sid-r5 "$RA" dispatcher idle
mkdir -p "$RAH/dispatcher"; rjson s6 "$$" sid-r6 "$RAH/dispatcher" disp2 idle
mkdir -p "$WORK/.claude-mem/observer-sessions/77"; rjson s7 "$$" sid-r7 "$WORK/.claude-mem/observer-sessions/77" 77-ab idle
printf '{not json' >"$RCD/sessions/bad.json"
printf '{"peerToken":"x","procStart":"y"}\n' >"$RCD/sessions/nopid.json"

R1=$(rt routeA routeA-Sessions idle working "$RAH/sessions/sid-r1" yes - metabranch)
R2=$(rt home homeChat busy - "$RAH/sessions/sid-r2" no - -)
R3=$(rt routeB routeB-x busy input "$RB/.agent" yes - feat)
R8=$(rt routeplain plainS - - "$RAH/sessions/sid-r8" no - -)
: >"$WORK/fake-ps.log"
out=$(route)
assert_eq "route: header, then busy before idle, then by name; no focus file" "$RHDR
$R2
$R3
$R1
$R8" "$out"
assert_eq "route: one ps call for every tty" "1" "$(grep -c . "$WORK/fake-ps.log")"
assert_not_contains "route: a dead pid is not listed" "$out" "deadOne"
assert_not_contains "route: the dispatcher is not listed (by name)" "$out" "dispatcher	"
assert_not_contains "route: the dispatcher is not listed (by cwd)" "$out" "disp2"
assert_not_contains "route: claude-mem observer sessions are hidden" "$out" "77-ab"
assert_contains "route: the home folder is named home, not ~" "$(printf '%s\n' "$out" | grep homeChat)" "$(rt home homeChat)"
assert_not_contains "route: no ~ anywhere" "$out" "~"
assert_eq "route: message_to is the json name" "routeA-Sessions" "$(printf '%s\n' "$out" | awk -F'\t' '$1 == "routeA" { print $2 }')"
assert_not_contains "route: no ANSI escapes" "$out" $'\033'

# focus: fresh vs stale vs absent
printf 'ttys001 %s\n' "$((RNOW - 30))" >"$RAH/dispatcher/focus"
F1=$(rt routeA routeA-Sessions idle working "$RAH/sessions/sid-r1" yes focused metabranch)
assert_eq "route: a fresh focus file puts its session first, marked focused" "$RHDR
$F1
$R2
$R3
$R8" "$(route)"
printf 'ttys003 %s\n' "$((RNOW - 600))" >"$RAH/dispatcher/focus"
assert_eq "route: focus at exactly the max age still counts" "focused" "$(route | awk -F'\t' '$1 == "routeB" { print $7 }')"
printf 'ttys003 %s\n' "$((RNOW - 601))" >"$RAH/dispatcher/focus"
assert_not_contains "route: a stale focus file marks nothing" "$(route)" "focused"
printf 'ttys003 %s\n' "$((RNOW - 100))" >"$RAH/dispatcher/focus"
assert_not_contains "route: DASH_FOCUS_MAX_AGE shortens the window" "$(DASH_FOCUS_MAX_AGE=60 route)" "focused"
assert_eq "route: DASH_FOCUS_MAX_AGE lengthens it too" "focused" "$(DASH_FOCUS_MAX_AGE=200 route | awk -F'\t' '$1 == "routeB" { print $7 }')"
printf '/dev/ttys002 %s\n' "$((RNOW - 5))" >"$RAH/dispatcher/focus"
assert_eq "route: a /dev/ prefix on the focus tty still matches" "home" "$(route | sed -n 2p | cut -f1)"
printf '?? %s\n' "$((RNOW - 5))" >"$RAH/dispatcher/focus"
assert_not_contains "route: a session without a tty is never focused" "$(route)" "focused"
rm -f "$RAH/dispatcher/focus"
assert_not_contains "route: no focus file marks nothing" "$(route)" "focused"

# state_dir choice: sessions dir with STATE.md (above) > repo .agent with STATE.md > sessions dir (notes no)
rm -f "$RAH/sessions/sid-r1/STATE.md"
assert_eq "route: a repo .agent/STATE.md (root from meta) is used when the sessions dir has none" \
  "$RA/.agent	yes" "$(route | awk -F'\t' '$1 == "routeA" { print $5 "\t" $6 }')"
rm -f "$RA/.agent/STATE.md"
assert_eq "route: without any STATE.md, state_dir is the sessions dir and notes no" \
  "$RAH/sessions/sid-r1	no" "$(route | awk -F'\t' '$1 == "routeA" { print $5 "\t" $6 }')"

assert_eq "route: 8 non-empty fields on every line" "" \
  "$(route | awk -F'\t' 'NF != 8 { print "NF " NF ": " $0 } { for (i = 1; i <= NF; i++) if ($i == "") print "empty " i ": " $0 }')"
assert_not_contains "route: the default view does not read the Claude Code session files" \
  "$(AGENT_HOME="$RAH" CLAUDE_DIR="$RCD" DASH_NOW="$RNOW" "$BIN/dash.sh")" "routeA-Sessions"
err=$("$BIN/dash.sh" --bogus 2>&1 >/dev/null); rc=$?
assert_eq "an unknown flag exits 64" "64" "$rc"
assert_contains "the unknown-flag text lists --route" "$err" "--route"
assert_contains "--help lists --route" "$("$BIN/dash.sh" --help)" "--route"
kill $L1 $L2 $L3 $L4 2>/dev/null
exit 0
