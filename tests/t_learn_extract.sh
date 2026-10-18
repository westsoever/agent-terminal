#!/usr/bin/env bash
# t_learn_extract.sh - the learner's extractor (spec 5.1, docs/learn-contracts.md section 6): the golden .work
# output over the fixture tree, byte offsets (incremental, partial lines, a shrunk transcript reads again from 0),
# malformed lines, cd strip, plumbing drop, duplicate collapse, Skill tokens, after_interrupt, the cumulative
# prompts.jsonl and the events files (rotation included). Everything runs in the sandbox; TZ pins local days.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
export TZ=UTC
FX="$KIT/tests/fixtures/learn"
X="$BIN/learn-extract.sh"
WD="$AGENT_HOME/proposals/.work"
P="$CLAUDE_DIR/projects"

# The fixture tree, copied. The e6 transcript is the learner's own run under /Users/fixture/.agent; it is moved
# to this sandbox's .work (directory name and cwd), so it is excluded here exactly as under the fixture home.
setup_tree() {
  rm -rf "$P"; mkdir -p "$P"
  cp -R "$FX/claude/projects/." "$P/"
  local enc; enc=$(printf '%s' "$WD" | sed 's/[^A-Za-z0-9]/-/g')
  mkdir -p "$P/$enc"
  sed "s#/Users/fixture/.agent/proposals/.work#$WD#g" "$P"/-Users-fixture--agent-proposals--work/*.jsonl \
    >"$P/$enc/e6000000-0000-4000-8000-00000000e006.jsonl"
  rm -rf "$P/-Users-fixture--agent-proposals--work"
}
put_events() { sed "s#/Users/fixture/.agent/proposals/.work#$WD#g" "$FX/events.jsonl" >"$1"; }   # the same move for events
run_x() { "$X" 2>"$WORK/x.err"; }
canon() { jq -S -c . "$1" | sort; }   # a JSONL file as a set of lines, key order ignored
A1="$P/-Users-fixture-code-shop/a1000000-0000-4000-8000-00000000a001.jsonl"
A2="$P/-Users-fixture-code-blog/a2000000-0000-4000-8000-00000000a002.jsonl"
B3="$P/-Users-fixture-code-blog/b3000000-0000-4000-8000-00000000b003.jsonl"
SID2=a2000000-0000-4000-8000-00000000a002

# line ts sid cwd type content_json [extra_json]: one transcript line in Claude Code's shape
line() {
  local x=${7:-}; [ -n "$x" ] || x='{}'
  jq -nc --arg ts "$1" --arg sid "$2" --arg cwd "$3" --arg t "$4" --argjson c "$5" --argjson x "$x" \
    '{parentUuid:null, isSidechain:false, userType:"external", cwd:$cwd, sessionId:$sid, version:"2.1.300",
      entrypoint:"cli", uuid:("u-" + $ts), timestamp:$ts, type:$t, message:{role:$t, content:$c}} + $x'
}
say()  { line "$1" "$2" "$3" user "$(jq -nc --arg s "$4" '$s')"; }                                   # a typed prompt
text() { line "$1" "$2" "$3" assistant "$(jq -nc --arg s "$4" '[{type:"text", text:$s}]')"; }         # assistant text
tool() { line "$1" "$2" "$3" assistant "$(jq -nc --arg n "$4" --argjson i "$5" '[{type:"tool_use", id:"t", name:$n, input:$i}]')"; }
bash_() { tool "$1" "$2" "$3" Bash "$(jq -nc --arg c "$4" '{command:$c}')"; }

# ---------- first run: the golden output ----------
setup_tree
put_events "$AGENT_HOME/events.jsonl"
run_x; rc=$?
assert_eq "first run: exit 0" "0" "$rc"
assert_eq "first run: nothing on stderr" "" "$(cat "$WORK/x.err")"
assert_eq "prompts.jsonl = golden (as a set, key order ignored)" "$(canon "$FX/work/prompts.jsonl")" "$(canon "$WD/prompts.jsonl")"
assert_eq "toolseq.jsonl = golden (as a set, key order ignored)" "$(canon "$FX/work/toolseq.jsonl")" "$(canon "$WD/toolseq.jsonl")"
assert_eq "prompts.jsonl: keys in the contract order" '["sid","ts","cwd","text","prev_assistant_tail","after_interrupt"]' \
  "$(head -1 "$WD/prompts.jsonl" | jq -c keys_unsorted)"
assert_eq "toolseq.jsonl: keys in the contract order" '["sid","day","cwd","tokens","prompts"]' \
  "$(head -1 "$WD/toolseq.jsonl" | jq -c keys_unsorted)"
assert_not_contains "the learner's own .work run is not extracted" "$(cat "$WD/prompts.jsonl")" "ching-learn-task"
assert_not_contains "the API_TOKEN value is redacted" "$(cat "$WD/prompts.jsonl")" "fixture-not-a-real-secret"
assert_eq "events.jsonl: the 4 countable events" "learn_run prompt proposal stop_ok " \
  "$(jq -r .kind "$WD/events.jsonl" | sort | tr '\n' ' ')"
assert_eq ".work is 0700" "700" "$(stat -f %Lp "$WD")"
assert_eq "every .work file is 0600" "600 600 600 600 600" \
  "$(for f in prompts.jsonl toolseq.jsonl events.jsonl offsets extract-state.json; do stat -f %Lp "$WD/$f"; done | tr '\n' ' ' | sed 's/ $//')"
assert_eq "offsets: every counted transcript is read to its end" "$(wc -c <"$A2" | tr -d ' ')" \
  "$(awk -F'\t' -v p="$A2" '$1 == "path" && $7 == p { print $4 }' "$WD/offsets")"
assert_eq "offsets: a skipped project directory is never listed" "" \
  "$(grep -E 'observer-sessions|private-tmp|var-folders|task3-repo' "$WD/offsets" || true)"
assert_eq "state: the sdk-cli session counts as seen, not countable" "true null" \
  "$(jq -r '.sessions["e2000000-0000-4000-8000-00000000e002"] | "\(.seen) \(.ok)"' "$WD/extract-state.json")"
assert_eq "no scratch files are left in .work" "" "$(find "$WD" -name '.extract-new.*')"

# ---------- a rerun with nothing new changes nothing ----------
cp "$WD/prompts.jsonl" "$WORK/p1"; cp "$WD/toolseq.jsonl" "$WORK/t1"; cp "$WD/events.jsonl" "$WORK/e1"
run_x
assert_eq "rerun: prompts.jsonl unchanged" "$(cat "$WORK/p1")" "$(cat "$WD/prompts.jsonl")"
assert_eq "rerun: toolseq.jsonl unchanged" "$(cat "$WORK/t1")" "$(cat "$WD/toolseq.jsonl")"
assert_eq "rerun: events.jsonl unchanged" "$(cat "$WORK/e1")" "$(cat "$WD/events.jsonl")"

# ---------- incremental: only the new bytes are read ----------
# a malformed line, a tool call equal to the session's last token (collapsed across runs), then a plumbing call,
# an interrupt and a new prompt; the tail comes from the last assistant text of the earlier run
{
  echo '{"broken": '
  bash_ 2026-10-12T13:04:00.000Z "$SID2" /Users/fixture/code/blog "git push origin main"
  tool 2026-10-12T13:04:10.000Z "$SID2" /Users/fixture/code/blog TodoWrite '{}'
  bash_ 2026-10-12T13:04:20.000Z "$SID2" /Users/fixture/code/blog "git push"
  bash_ 2026-10-12T13:04:30.000Z "$SID2" /Users/fixture/code/blog "cd /Users/fixture/code/blog; bun run build"
  line 2026-10-12T13:04:40.000Z "$SID2" /Users/fixture/code/blog user '[{"type":"text","text":"[Request interrupted by user]"}]'
} >>"$A2"
run_x
assert_eq "incremental: no new prompt yet" "17" "$(grep -c . "$WD/prompts.jsonl")"
assert_eq "incremental: tokens appended, a repeat of the last token collapsed across runs" \
  '["git fetch","git rebase","bun test","git push","bun run"]' \
  "$(jq -c --arg s "$SID2" 'select(.sid == $s) | .tokens' "$WD/toolseq.jsonl")"
say 2026-10-12T13:05:00.000Z "$SID2" /Users/fixture/code/blog "now deploy it" >>"$A2"
run_x
new=$(jq -c --arg s "$SID2" 'select(.sid == $s and .ts == "2026-10-12T13:05:00.000Z")' "$WD/prompts.jsonl")
assert_eq "incremental: the new prompt is appended once" "1" "$(printf '%s\n' "$new" | grep -c .)"
assert_eq "incremental: tail from a line read in an earlier run" "Added the feed to the sitemap." \
  "$(printf '%s' "$new" | jq -r .prev_assistant_tail)"
assert_eq "incremental: an interrupt read in an earlier run sets after_interrupt" "true" \
  "$(printf '%s' "$new" | jq -r .after_interrupt)"
assert_eq "incremental: the prompt mark is at the end of the tokens" '{"i":5,"ts":"2026-10-12T13:05:00.000Z"}' \
  "$(jq -c --arg s "$SID2" 'select(.sid == $s) | .prompts | last' "$WD/toolseq.jsonl")"
assert_eq "incremental: earlier prompts untouched (order kept)" "$(cat "$WORK/p1")" "$(head -17 "$WD/prompts.jsonl")"

# ---------- a line still being written is read once it is whole ----------
part=$(say 2026-10-12T13:06:00.000Z "$SID2" /Users/fixture/code/blog "and tag the release")
printf '%s' "${part:0:40}" >>"$A2"
run_x
assert_eq "partial line: not read yet" "18" "$(grep -c . "$WD/prompts.jsonl")"
printf '%s\n' "${part:40}" >>"$A2"
run_x
assert_eq "partial line: read whole on the next run" "1" \
  "$(jq -c 'select(.text == "and tag the release")' "$WD/prompts.jsonl" | grep -c .)"
assert_eq "partial line: the offset is the file size" "$(wc -c <"$A2" | tr -d ' ')" \
  "$(awk -F'\t' -v p="$A2" '$1 == "path" && $7 == p { print $4 }' "$WD/offsets")"

# ---------- a shrunk transcript is read again from 0, its old lines dropped first ----------
SID1=a1000000-0000-4000-8000-00000000a001
head -12 "$A1" >"$WORK/a1.short"; cat "$WORK/a1.short" >"$A1"     # same inode, fewer bytes: up to the ToolSearch call
run_x
assert_eq "shrunk: only the prompts still in the file" "2026-10-12T12:00:30.000Z" \
  "$(jq -r --arg s "$SID1" 'select(.sid == $s) | .ts' "$WD/prompts.jsonl")"
assert_eq "shrunk: tokens rebuilt from 0" '["Read","Edit","git fetch"]' \
  "$(jq -c --arg s "$SID1" 'select(.sid == $s) | .tokens' "$WD/toolseq.jsonl")"
cp "$FX/claude/projects/-Users-fixture-code-shop/a1000000-0000-4000-8000-00000000a001.jsonl" "$A1"
run_x
assert_eq "regrown: the session matches the golden line again" \
  "$(jq -S -c --arg s "$SID1" 'select(.sid == $s)' "$FX/work/toolseq.jsonl")" \
  "$(jq -S -c --arg s "$SID1" 'select(.sid == $s)' "$WD/toolseq.jsonl")"
assert_eq "regrown: no duplicate (sid, ts)" "0" \
  "$(jq -r '"\(.sid)@\(.ts)"' "$WD/prompts.jsonl" | sort | uniq -d | grep -c . || true)"
# a file rewritten in place, same length, other first bytes (the head hash), is read again too
sed -e '1s/"version":"2.1.300"/"version":"2.1.301"/' -e 's/add a dark mode toggle/add a DARK mode toggle/' "$A1" >"$WORK/a1.rw"; cat "$WORK/a1.rw" >"$A1"
run_x
assert_eq "rewritten in place: read again" "add a DARK mode toggle to the settings page" \
  "$(jq -r --arg s "$SID1" 'select(.sid == $s and .ts == "2026-10-12T12:00:30.000Z") | .text' "$WD/prompts.jsonl")"
assert_eq "rewritten in place: still 3 prompts for the session" "3" \
  "$(jq -r --arg s "$SID1" 'select(.sid == $s) | .ts' "$WD/prompts.jsonl" | grep -c .)"

# ---------- cumulative: a transcript that disappears keeps its prompts ----------
rm -f "$B3"
run_x
assert_eq "deleted transcript: its prompts stay" "2" "$(jq -r 'select(.sid | startswith("b3")) | .ts' "$WD/prompts.jsonl" | grep -c .)"
assert_eq "deleted transcript: its toolseq line stays" "1" "$(jq -r 'select(.sid | startswith("b3")) | .sid' "$WD/toolseq.jsonl" | grep -c .)"

# ---------- deleting .work rebuilds from what is on disk ----------
setup_tree
rm -rf "$WD"
run_x
assert_eq "rebuild: prompts.jsonl = golden" "$(canon "$FX/work/prompts.jsonl")" "$(canon "$WD/prompts.jsonl")"
assert_eq "rebuild: toolseq.jsonl = golden" "$(canon "$FX/work/toolseq.jsonl")" "$(canon "$WD/toolseq.jsonl")"
# offsets from another run than the state (a crash between writes): everything is read again, nothing doubled
sed -i '' '1s/.*/# gen 999/' "$WD/offsets"
run_x
assert_eq "generation mismatch: rebuilt, no duplicates" "$(canon "$FX/work/prompts.jsonl")" "$(canon "$WD/prompts.jsonl")"

# ---------- tokens: cd strip, flags, NAME=value, git -C, plumbing, Skill, collapse; text and tail caps ----------
S=c1000000-0000-4000-8000-00000000c001; C=/Users/fixture/code/tok
mkdir -p "$P/-Users-fixture-code-tok"
long=$(printf 'word %.0s' $(seq 1 200))                  # 1000 characters
ghp="gh""p_$(printf 'A%.0s' $(seq 1 36))"                # built at run time: no token-shaped literal in the repo
{
  say 2026-10-15T09:00:00.000Z $S $C "set up the build"
  bash_ 2026-10-15T09:00:10.000Z $S $C 'cd "/Users/fixture/code/my tok" && npm run build'
  bash_ 2026-10-15T09:00:20.000Z $S $C 'cd a && cd b; git -C /Users/fixture/code/tok status --short'
  bash_ 2026-10-15T09:00:30.000Z $S $C 'FOO=1 BAR=2 bun --silent test'
  tool 2026-10-15T09:00:40.000Z $S $C TaskCreate '{}'
  tool 2026-10-15T09:00:50.000Z $S $C mcp__claude-in-chrome__tabs_context_mcp '{}'
  tool 2026-10-15T09:01:00.000Z $S $C ToolSearch '{}'
  bash_ 2026-10-15T09:01:10.000Z $S $C 'bun test'
  tool 2026-10-15T09:01:20.000Z $S $C Skill '{"skill":"superpowers:writing-plans","args":"x"}'
  tool 2026-10-15T09:01:30.000Z $S $C mcp__x__y '{}'
  bash_ 2026-10-15T09:01:40.000Z $S $C 'ls'
  bash_ 2026-10-15T09:01:50.000Z $S $C '   '
  text 2026-10-15T09:02:00.000Z $S $C "${long}token $ghp end"
  say 2026-10-15T09:02:10.000Z $S $C "$long"
} >"$P/-Users-fixture-code-tok/$S.jsonl"
run_x
assert_eq "tokens: cd strip, flags and NAME=value dropped, git -C skips its argument, plumbing dropped, collapse" \
  '["npm run","git status","bun test","Skill:superpowers:writing-plans","mcp__x__y","ls","Bash"]' \
  "$(jq -c --arg s $S 'select(.sid == $s) | .tokens' "$WD/toolseq.jsonl")"
assert_eq "tokens: day is the local date of the first kept call" "2026-10-15" "$(jq -r --arg s $S 'select(.sid == $s) | .day' "$WD/toolseq.jsonl")"
lp=$(jq -c --arg s $S 'select(.sid == $s and .ts == "2026-10-15T09:02:10.000Z")' "$WD/prompts.jsonl")
assert_eq "text is cut to 600 characters" "600" "$(printf '%s' "$lp" | jq '.text | length')"
assert_eq "the tail is the last 300 characters" "300" "$(printf '%s' "$lp" | jq '.prev_assistant_tail | length')"
assert_not_contains "the tail is redacted" "$lp" "$ghp"
assert_contains "the tail ends where the text ends" "$lp" 'end"'

# ---------- local days follow TZ ----------
S2=c2000000-0000-4000-8000-00000000c002
{ say 2026-10-15T23:30:00.000Z $S2 $C "late"; bash_ 2026-10-15T23:30:10.000Z $S2 $C "make"; } >"$P/-Users-fixture-code-tok/$S2.jsonl"
rm -rf "$WD"
TZ=Asia/Tokyo "$X"
assert_eq "day: UTC 23:30 is the next day in Tokyo" "2026-10-16" "$(jq -r --arg s $S2 'select(.sid == $s) | .day' "$WD/toolseq.jsonl")"
assert_eq "ts: kept exactly as written (UTC)" "2026-10-15T23:30:00.000Z" "$(jq -r --arg s $S2 'select(.sid == $s) | .ts' "$WD/prompts.jsonl")"
rm -rf "$P/-Users-fixture-code-tok"

# ---------- events: incremental, rotation, sandbox filter ----------
setup_tree
rm -rf "$WD"
LOG="$AGENT_HOME/events.jsonl"
put_events "$LOG"
run_x
evl() { jq -nc --arg ts "$1" --arg cwd "$2" --arg k "$3" '{ts:$ts, sid:"s9", name:"x", cwd:$cwd, kind:$k, data:{}}'; }
evl 2026-10-15T10:00:00Z /Users/fixture/code/shop stall >>"$LOG"
evl 2026-10-15T10:01:00Z /private/tmp/x stall >>"$LOG"
run_x
assert_eq "events: an appended countable line is added once, a sandbox one is not" "5" "$(grep -c . "$WD/events.jsonl")"
evl 2026-10-15T10:02:00Z /Users/fixture/code/shop deny >>"$LOG"         # written after the last run, before rotation
mv "$LOG" "$AGENT_HOME/events-20261015-100300.jsonl"
evl 2026-10-15T10:04:00Z /Users/fixture/code/shop context >"$LOG"
run_x
assert_eq "rotation: the rotated file carries on from its offset, the new live file starts at 0" \
  "prompt learn_run stop_ok proposal stall deny context" "$(jq -r .kind "$WD/events.jsonl" | tr '\n' ' ' | sed 's/ $//')"
run_x
assert_eq "rotation: a rerun adds nothing" "7" "$(grep -c . "$WD/events.jsonl")"
rm -f "$AGENT_HOME/events-20261015-100300.jsonl"
run_x
assert_eq "events: a deleted rotated file keeps what was extracted" "7" "$(grep -c . "$WD/events.jsonl")"
rm -rf "$WD"
put_events "$AGENT_HOME/events-20261001-000000.jsonl"
run_x
assert_eq "events: a first run reads rotated files (oldest first) and the live one" "prompt learn_run stop_ok proposal context" \
  "$(jq -r .kind "$WD/events.jsonl" | tr '\n' ' ' | sed 's/ $//')"
rm -f "$AGENT_HOME"/events-*.jsonl

# ---------- robustness ----------
rm -rf "$WD"
out=$(bash -c 'set -euo pipefail; "$1"' _ "$X" 2>&1); rc=$?
assert_eq "strict caller: exit 0, quiet" "0|" "$rc|$out"
mv "$P" "$WORK/projects.away"
rm -rf "$WD"
run_x; rc=$?
assert_eq "no projects directory: exit 0" "0" "$rc"
assert_eq "no projects directory: empty prompts.jsonl" "0" "$(grep -c . "$WD/prompts.jsonl" || true)"
mv "$WORK/projects.away" "$P"
rm -rf "$AGENT_HOME/proposals"; ln -s "$WORK" "$AGENT_HOME/proposals"
run_x; rc=$?
assert_eq "a symlinked proposals root is refused (exit 3)" "3" "$rc"
rm -f "$AGENT_HOME/proposals"
exit 0
