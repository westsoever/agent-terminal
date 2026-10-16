#!/usr/bin/env bash
# t_learn_plumbing.sh - Phase 6 plumbing (spec 5, 6, 7): bin/learn.sh (component order, lock, weekly stamp,
# LEARN_DISABLE, missing components, fail quiet), bin/ching-proposals (list, show, diff, approve at a TTY only,
# reject, snooze), the learn_model_call flags, and the registry-leak shape (spec question 10).
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
FX="$KIT/tests/fixtures/learn"
EVF="$AGENT_HOME/events.jsonl"
P="$AGENT_HOME/proposals"
L="$BIN/learn.sh"
CP="$BIN/ching-proposals"
evs() { jq -c 'select(.kind == "learn_run") | .data' "$EVF" 2>/dev/null; }
reset_ev() { rm -f "$EVF"; }

# ================= learn.sh =================
CD="$WORK/components"; mkdir -p "$CD"
mkcomp() { # name [exit code] [sleep secs]: a fake component that records its order, cwd and learner env
  cat >"$CD/learn-$1.sh" <<EOS
printf '%s cwd=%s learner=%s mem=%s\n' "$1" "\$(pwd -P)" "\${CHING_LEARNER:-}" "\${CLAUDE_MEM_INTERNAL:-}" >>"$WORK/order.log"
echo "output of $1"
${3:+sleep $3}
exit ${2:-0}
EOS
}
lrun() { env -u CHING_LEARNER -u CLAUDE_MEM_INTERNAL LEARN_COMPONENT_DIR="$CD" "$L" "$@" 2>&1; }

# no component exists yet: every one is skipped with outcome missing, the run still exits 0
reset_ev
out=$(lrun --weekly); rc=$?
assert_eq "learn: no components: exits 0" "0" "$rc"
assert_eq "learn: no components: four learn_run missing events, in order" "extract corrections skills report " \
  "$(evs | jq -r 'select(.outcome == "missing") | .component' | tr '\n' ' ')"
assert_contains "learn: prints one summary line" "$out" "learn: weekly run: extract=missing corrections=missing skills=missing report=missing"
assert_file "learn: writes .work/learn.log" "$P/.work/learn.log"
assert_contains "learn: the log names the missing file" "$(cat "$P/.work/learn.log")" "learn-corrections.sh does not exist"
assert_eq "learn: proposals root is 0700" "700" "$(stat -f %Lp "$P")"
assert_eq "learn: the lock is gone after the run" "" "$(ls -d "$P/.work/learn.lock" 2>/dev/null)"

# all four present: order, cwd, environment
for c in extract corrections skills report; do mkcomp "$c"; done
rm -f "$WORK/order.log" "$P/.work/weekly-stamp"; reset_ev
out=$(lrun); rc=$?
WORKP=$(cd "$P/.work" && pwd -P)
assert_eq "learn: first run of the week (no stamp) is weekly: all four in order" "extract corrections skills report " \
  "$(cut -d' ' -f1 "$WORK/order.log" | tr '\n' ' ')"
assert_eq "learn: every component runs in .work with CHING_LEARNER=1 and CLAUDE_MEM_INTERNAL=1" "4" \
  "$(grep -c "cwd=$WORKP learner=1 mem=1" "$WORK/order.log")"
assert_eq "learn: the weekly stamp holds this ISO week" "$(date +%G-W%V)" "$(cat "$P/.work/weekly-stamp")"
assert_contains "learn: component output goes to learn.log" "$(cat "$P/.work/learn.log")" "output of skills"
assert_not_contains "learn: component output is not printed" "$out" "output of"
assert_eq "learn: a clean run emits no learn_run events of its own" "" "$(evs)"
rm -f "$WORK/order.log"
lrun >/dev/null
assert_eq "learn: second run in the same week is nightly: extract and corrections only" "extract corrections " \
  "$(cut -d' ' -f1 "$WORK/order.log" | tr '\n' ' ')"
rm -f "$WORK/order.log"; out=$(lrun --weekly)
assert_eq "learn: --weekly forces the weekly part" "4" "$(wc -l <"$WORK/order.log" | tr -d ' ')"
printf '1999-W01\n' >"$P/.work/weekly-stamp"; rm -f "$WORK/order.log"; out=$(lrun --nightly)
assert_eq "learn: --nightly leaves the weekly part out even when it is due" "2" "$(wc -l <"$WORK/order.log" | tr -d ' ')"
assert_eq "learn: --nightly does not touch the stamp" "1999-W01" "$(cat "$P/.work/weekly-stamp")"
rm -f "$WORK/order.log"; out=$(lrun)
assert_eq "learn: a stamp from an older week (a missed Monday) makes the next run weekly" "4" "$(wc -l <"$WORK/order.log" | tr -d ' ')"

# LEARN_DISABLE, from the environment and from the config file
rm -f "$WORK/order.log"; reset_ev
out=$(LEARN_DISABLE="skills, Report" lrun --weekly)
assert_eq "learn: LEARN_DISABLE skips the named components" "extract corrections " "$(cut -d' ' -f1 "$WORK/order.log" | tr '\n' ' ')"
assert_eq "learn: ... with learn_run disabled events" "skills report " "$(evs | jq -r 'select(.outcome == "disabled") | .component' | tr '\n' ' ')"
assert_eq "learn: event shape (component, scanned, candidates, proposals, outcome)" '{"component":"skills","scanned":0,"candidates":0,"proposals":0,"outcome":"disabled"}' \
  "$(evs | head -1)"
printf 'LEARN_DISABLE=all\n' >"$AGENT_HOME/config"; rm -f "$WORK/order.log"; out=$(lrun --weekly)
assert_no_file "learn: LEARN_DISABLE=all in the config runs nothing" "$WORK/order.log"
rm -f "$AGENT_HOME/config"

# a failing component: fail quiet, the others still run
mkcomp corrections 3
rm -f "$WORK/order.log"; reset_ev
out=$(lrun --weekly); rc=$?
assert_eq "learn: a failing component still exits 0" "0" "$rc"
assert_eq "learn: ... the components after it still run" "4" "$(wc -l <"$WORK/order.log" | tr -d ' ')"
assert_eq "learn: ... learn_run error with its exit code" '{"component":"corrections","scanned":0,"candidates":0,"proposals":0,"outcome":"error","rc":3}' "$(evs)"
assert_contains "learn: ... the summary says so" "$out" "corrections=error"
mkcomp corrections
mkcomp skills 0 5
reset_ev; out=$(LEARN_COMPONENT_TIMEOUT=1 lrun --weekly)
assert_eq "learn: a component past LEARN_COMPONENT_TIMEOUT is stopped (error, rc 142)" "skills 142" "$(evs | jq -r '"\(.component) \(.rc)"')"
assert_contains "learn: ... and the log says why" "$(cat "$P/.work/learn.log")" "stopped after 1s"
mkcomp skills

# TERM or INT to learn.sh (launchd stopping the job, ^C): the running component's whole process group (it runs in
# a group of its own) is killed before the lock is released, and the component gets an error event
cat >"$CD/learn-skills.sh" <<EOS
( sleep 30; echo late >>"$WORK/late.log" ) &
echo \$! >"$WORK/grandchild.pid"; echo \$\$ >"$WORK/comp.pid"
sleep 30
EOS
alive() { kill -0 "$1" 2>/dev/null && [ "$(ps -o stat= -p "$1" 2>/dev/null | cut -c1)" != Z ]; }
for sig in TERM INT; do
  rm -f "$WORK/comp.pid" "$WORK/grandchild.pid" "$WORK/late.log"; reset_ev
  # perl puts INT back to its default: a background job of a script starts with INT ignored, and then cannot trap it
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV' env -u CHING_LEARNER -u CLAUDE_MEM_INTERNAL LEARN_COMPONENT_DIR="$CD" "$L" --weekly >"$WORK/sig.out" 2>&1 &
  lp=$!
  for _ in $(seq 1 100); do [ -s "$WORK/grandchild.pid" ] && break; sleep 0.1; done
  cpid=$(cat "$WORK/comp.pid" 2>/dev/null); gpid=$(cat "$WORK/grandchild.pid" 2>/dev/null)
  assert_eq "learn $sig: the component is running" "yes yes" "$(alive "$cpid" && echo yes) $(alive "$gpid" && echo yes)"
  t0=$(date +%s); kill -"$sig" "$lp"; wait "$lp"; rc=$?
  assert_eq "learn $sig: exits 128 + the signal" "$([ $sig = TERM ] && echo 143 || echo 130)" "$rc"
  assert_eq "learn $sig: ... within a few seconds" "1" "$(( $(date +%s) - t0 < 5 ))"
  assert_eq "learn $sig: the component is gone" "" "$(alive "$cpid" && echo alive)"
  assert_eq "learn $sig: ... and its child too (the whole group)" "" "$(alive "$gpid" && echo alive)"
  assert_eq "learn $sig: ... nothing left in its process group" "" "$(kill -0 -"$cpid" 2>/dev/null && echo alive)"
  assert_no_file "learn $sig: the lock is released" "$P/.work/learn.lock"
  assert_eq "learn $sig: learn_run error for the component" "skills error $rc" "$(evs | jq -r '"\(.component) \(.outcome) \(.rc)"')"
  assert_contains "learn $sig: the log says so" "$(cat "$P/.work/learn.log")" "learn: SIG$sig while skills ran"
done
mkcomp skills

# the lock: a fresh one skips the run, a stale one is taken over
mkdir "$P/.work/learn.lock"; rm -f "$WORK/order.log"
out=$(lrun --weekly); rc=$?
assert_eq "learn: a held lock: exits 0" "0" "$rc"
assert_no_file "learn: a held lock: nothing runs" "$WORK/order.log"
assert_contains "learn: a held lock: says so" "$out" "another run is in progress"
assert_file "learn: a held lock is not removed" "$P/.work/learn.lock"
touch -t 202001010000 "$P/.work/learn.lock"
out=$(lrun --weekly)
assert_eq "learn: a stale lock is taken over" "4" "$(wc -l <"$WORK/order.log" | tr -d ' ')"
assert_no_file "learn: ... and released" "$P/.work/learn.lock"

# nothing is written outside proposals/ (and the events file)
assert_eq "learn: AGENT_HOME holds only proposals/ and events.jsonl" "events.jsonl proposals " "$(ls "$AGENT_HOME" | tr '\n' ' ')"
assert_eq "learn: bad argument exits 64" "64" "$(lrun --monthly >/dev/null; echo $?)"
assert_contains "learn: --help" "$("$L" --help)" "LEARN_DISABLE"

# a planted symlink as the proposals root: nothing runs, one error event
SL="$WORK/sl-ah"; mkdir -p "$SL" "$WORK/elsewhere"; ln -s "$WORK/elsewhere" "$SL/proposals"
rm -f "$WORK/order.log"
out=$(AGENT_HOME="$SL" lrun --weekly); rc=$?
assert_eq "learn: symlinked proposals root: exits 0" "0" "$rc"
assert_no_file "learn: symlinked proposals root: nothing runs" "$WORK/order.log"
assert_eq "learn: symlinked proposals root: learn_run error" "learn error" "$(jq -r 'select(.kind == "learn_run") | "\(.data.component) \(.data.outcome)"' "$SL/events.jsonl")"
assert_eq "learn: symlinked proposals root: nothing written through the link" "" "$(ls "$WORK/elsewhere")"

# the real components directory: whatever has landed runs, the rest is reported missing (no LEARN_COMPONENT_DIR)
reset_ev
out=$(LEARN_DISABLE=all "$L" --weekly 2>&1); rc=$?
assert_eq "learn: default component dir, all disabled: exits 0" "0" "$rc"

# ================= learn_model_call flags (the real-format check, 2026-10-17) =================
export CHING_CLAUDE_BIN="$FX/claude-stub" CLAUDE_STUB_LOG="$WORK/call.log"
printf 'ching-learn-task: skills\n' | learn_model_call haiku >/dev/null
assert_contains "model call: no MCP servers and no skills (--tools \"\" alone keeps MCP tools)" "$(cat "$WORK/call.log")" \
  "ARGS: -p --model haiku --tools  --output-format json --strict-mcp-config --disable-slash-commands"
unset CHING_CLAUDE_BIN CLAUDE_STUB_LOG

# ================= ching-proposals =================
reset_ev
FA="$WORK/fresh-ah"
out=$(AGENT_HOME="$FA" "$CP" list); rc=$?
assert_eq "cli: list with no proposals folder exits 0" "0" "$rc"
assert_contains "cli: ... and says so" "$out" "no proposals yet"
assert_no_file "cli: list does not create the folder" "$FA/proposals"
assert_eq "cli: no command: usage, exit 64" "64" "$("$CP" >/dev/null 2>&1; echo $?)"
assert_eq "cli: unknown command exits 64" "64" "$("$CP" frobnicate >/dev/null 2>&1; echo $?)"

rm -rf "$P"
mkdir -p "$HOME/.agents"; cp "$FX/agents-CLAUDE.md" "$HOME/.agents/CLAUDE.md"
ORIG_RULES=$(cat "$HOME/.agents/CLAUDE.md")
FP_RULE=$(proposal_fingerprint "do not bump the version number")
mkrule() { # slug fingerprint [sessions] [patch]
  jq -c --arg fp "$2" --argjson n "${3:-3}" --arg patch "${4:-}" '.rules[0] | {component: "corrections", fingerprint: $fp, sessions: $n, days: 2,
      target, proposal, evidence: [{sid: "a1000000-0000-4000-8000-00000000a001", day: "2026-10-12", cwd: "/Users/fixture/code/shop", quote: "no"}],
      patch: (if $patch == "" then .patch else $patch end), why_not_covered}' "$FX/stub/corrections-draft.json" | proposal_write "rule-$1.md" >/dev/null
}
mkother() { # kind slug fingerprint-text sessions proposal
  jq -nc --arg fp "$(proposal_fingerprint "$3")" --argjson n "$4" --arg p "$5" --arg c "$( [ "$1" = skill ] && echo skills || echo lessons)" \
    '{component: $c, fingerprint: $fp, sessions: $n, days: 2, target: "sync-rebase-test", proposal: $p, evidence: [], why_not_covered: "Checked the installed skills."}' \
    | proposal_write "$1-$2.md" >/dev/null
}
mkrule no-version-bump "$FP_RULE" 3
mkother skill sync-rebase "git fetch > git rebase > bun test > git push" 5 "Make a skill for the sync loop. It repeats in five sessions."
mkother lesson short-commits "short commits" 1 "Keep commits short. Two sessions."
printf 'weekly\n' >"$P/report-2026-W41.md"
ls_out=$("$CP" list)
assert_eq "cli: list: open proposals, most sessions first, kind id: first sentence (sessions/days)" \
  "  skill skill-sync-rebase: Make a skill for the sync loop. (5 sessions/2 days)
  rule rule-no-version-bump: Add a rule that sessions never bump the version number. (3 sessions/2 days)
  lesson lesson-short-commits: Keep commits short. (1 sessions/2 days)
latest weekly report: $(cd "$P" && pwd -P)/report-2026-W41.md" "$ls_out"

# show: the whole file, the patch coloured only when asked (or at a terminal)
plain=$(CHING_COLOR=never "$CP" show rule-no-version-bump)
assert_eq "cli: show prints the file as it is" "$(cat "$P/rule-no-version-bump.md")" "$plain"
col=$(CHING_COLOR=always "$CP" show rule-no-version-bump)
assert_contains "cli: show colours added patch lines green" "$col" $'\033[32m+## Versions'
assert_not_contains "cli: show leaves the evidence uncoloured" "$(printf '%s\n' "$col" | sed -n '/## evidence/,/## patch/p')" $'\033[3'
assert_not_contains "cli: show to a pipe is not coloured by default" "$("$CP" show rule-no-version-bump)" $'\033['
assert_eq "cli: show of a bad id exits 2" "2" "$("$CP" show ../../etc/passwd >/dev/null 2>&1; echo $?)"
assert_eq "cli: show of an unknown id exits 1" "1" "$("$CP" show rule-nope >/dev/null 2>&1; echo $?)"

# diff: the patch applied to a copy of the live target
d=$(CHING_COLOR=never "$CP" diff rule-no-version-bump); rc=$?
assert_eq "cli: diff exits 0" "0" "$rc"
assert_contains "cli: diff labels the live target" "$d" "--- ~/.agents/CLAUDE.md (now)"
assert_contains "cli: diff shows the added rule" "$d" "+Never bump the version number. The owner releases by hand."
assert_eq "cli: diff changes nothing" "$ORIG_RULES" "$(cat "$HOME/.agents/CLAUDE.md")"
assert_eq "cli: diff of a skill exits 2" "2" "$("$CP" diff skill-sync-rebase >/dev/null 2>&1; echo $?)"

# approve without a TTY (a session's Bash tool): refused before anything happens
n_before=$(wc -l <"$EVF" 2>/dev/null | tr -d ' '); n_before=${n_before:-0}
out=$("$CP" approve rule-no-version-bump </dev/null 2>&1); rc=$?
assert_eq "cli: approve without a TTY exits 1" "1" "$rc"
assert_contains "cli: ... and says it is for a person at a terminal" "$out" "person at a terminal"
assert_file "cli: ... the proposal stays open" "$P/rule-no-version-bump.md"
assert_eq "cli: ... the target is untouched" "$ORIG_RULES" "$(cat "$HOME/.agents/CLAUDE.md")"
assert_eq "cli: ... no event" "$n_before" "$(wc -l <"$EVF" 2>/dev/null | tr -d ' ' || echo 0)"
out=$(echo y | "$CP" approve skill-sync-rebase 2>&1 | cat); rc=$?
assert_contains "cli: approve with stdin piped and stdout piped is refused too" "$out" "person at a terminal"

# reject: fingerprint and reason in rejected.txt, file archived, event, never proposed again
out=$("$CP" reject lesson-short-commits "not my style" 2>&1); rc=$?
assert_eq "cli: reject exits 0" "0" "$rc"
assert_eq "cli: reject appends the fingerprint and the reason" "$(proposal_fingerprint "short commits") not my style" "$(cat "$P/rejected.txt")"
assert_eq "cli: rejected.txt is 0600" "600" "$(stat -f %Lp "$P/rejected.txt")"
assert_no_file "cli: reject moves the file away" "$P/lesson-short-commits.md"
assert_eq "cli: the archived copy says rejected" "rejected" "$(proposal_get "$P/archive/lesson-short-commits.md" status)"
assert_eq "cli: the archived copy is 0600" "600" "$(stat -f %Lp "$P/archive/lesson-short-commits.md")"
assert_eq "cli: reject emits a proposal event" '{"id":"lesson-short-commits","action":"rejected"}' "$(jq -c 'select(.kind == "proposal") | .data' "$EVF" | tail -1)"
out=$(jq -nc --arg fp "$(proposal_fingerprint "short commits")" '{component: "lessons", fingerprint: $fp, sessions: 9, days: 9, target: "x", proposal: "again", evidence: []}' | proposal_write lesson-short-commits-2.md)
assert_contains "cli: a rejected fingerprint is not proposed again" "$out" "skipped rejected"
assert_contains "cli: reject of a decided id says so" "$("$CP" reject lesson-short-commits 2>&1)" "already decided"
assert_contains "cli: list --all shows decided ones with their status" "$("$CP" list --all)" "[rejected] lesson lesson-short-commits"

# snooze: status snoozed:<date>, archived, event, blocks until then
want=$(date -v+3d +%Y-%m-%d)
mkother skill other-loop "a > b > c" 3 "Another loop."
out=$("$CP" snooze skill-other-loop 3); rc=$?
assert_eq "cli: snooze exits 0" "0" "$rc"
assert_eq "cli: snooze sets status snoozed:<today + days>" "snoozed:$want" "$(proposal_get "$P/archive/skill-other-loop.md" status)"
assert_no_file "cli: snooze hides it from the top" "$P/skill-other-loop.md"
assert_eq "cli: snooze emits a proposal event" '{"id":"skill-other-loop","action":"snoozed"}' "$(jq -c 'select(.kind == "proposal") | .data' "$EVF" | tail -1)"
out=$(jq -nc --arg fp "$(proposal_fingerprint "a > b > c")" '{component: "skills", fingerprint: $fp, sessions: 4, days: 3, target: "x", proposal: "again", evidence: [], why_not_covered: "w"}' | proposal_write skill-other-loop.md)
assert_contains "cli: a snoozed fingerprint is skipped until the date" "$out" "skipped snoozed"
assert_not_contains "cli: list hides the snoozed one" "$("$CP" list)" "other-loop"
assert_eq "cli: snooze needs whole days" "2" "$("$CP" snooze skill-sync-rebase 0 >/dev/null 2>&1; echo $?)"
assert_eq "cli: snooze rejects junk days" "2" "$("$CP" snooze skill-sync-rebase 3x >/dev/null 2>&1; echo $?)"
# a snooze that ran out: the learner proposes it again, and deciding it again keeps both archived copies
sed -i '' "s/^status: .*/status: snoozed:2000-01-01/" "$P/archive/skill-other-loop.md"
out=$(jq -nc --arg fp "$(proposal_fingerprint "a > b > c")" '{component: "skills", fingerprint: $fp, sessions: 4, days: 3, target: "x", proposal: "Back again.", evidence: [], why_not_covered: "w"}' | proposal_write skill-other-loop.md)
assert_contains "cli: an expired snooze is proposed again" "$out" "written"
"$CP" reject skill-other-loop >/dev/null
assert_eq "cli: deciding the same id twice keeps both archived copies" "2" "$(ls "$P"/archive/skill-other-loop*.md | wc -l | tr -d ' ')"

# approve at a terminal: script(1) gives the CLI a pty (macOS; skipped where it is missing)
if [ "$(uname)" = Darwin ] && printf '' | script -q /dev/null true >/dev/null 2>&1; then
  tty_cp() { # answer cmd args...: run ching-proposals under a pty, answer its prompt once it shows (or right away)
    local ans=$1 i=0; shift
    : >"$WORK/tty.out"
    { while [ "$i" -lt 50 ] && ! grep -q '\[y/N\]\|Approved\|approved' "$WORK/tty.out"; do sleep 0.2; i=$((i + 1)); done
      printf '%s\n' "$ans"; sleep 0.5; } \
      | script -q /dev/null "$CP" "$@" >"$WORK/tty.out" 2>&1
    return "${PIPESTATUS[1]}"   # the CLI's status: the answering side may die of SIGPIPE when nothing reads it
  }
  tty_cp n approve rule-no-version-bump; rc=$?
  assert_eq "tty: rule approve, answer n: exits 1" "1" "$rc"
  assert_contains "tty: rule approve shows the change before asking" "$(cat "$WORK/tty.out")" "+Never bump the version number"
  assert_eq "tty: answer n: target untouched" "$ORIG_RULES" "$(cat "$HOME/.agents/CLAUDE.md")"
  assert_file "tty: answer n: proposal still open" "$P/rule-no-version-bump.md"
  # the target is reached through a symlink, as ~/.claude/CLAUDE.md links to ~/.agents/CLAUDE.md
  mkdir -p "$WORK/real-agents"; mv "$HOME/.agents/CLAUDE.md" "$WORK/real-agents/CLAUDE.md"; ln -s "$WORK/real-agents/CLAUDE.md" "$HOME/.agents/CLAUDE.md"
  chmod 640 "$WORK/real-agents/CLAUDE.md"
  tty_cp y approve rule-no-version-bump; rc=$?
  assert_eq "tty: rule approve, answer y: exits 0" "0" "$rc"
  assert_contains "tty: answer y: the rule is in the target" "$(cat "$WORK/real-agents/CLAUDE.md")" "## Versions"
  assert_ok "tty: answer y: the link stays a link" test -L "$HOME/.agents/CLAUDE.md"
  assert_eq "tty: answer y: the target keeps its mode" "640" "$(stat -f %Lp "$WORK/real-agents/CLAUDE.md")"
  assert_eq "tty: answer y: the old version is kept in archive/" "$ORIG_RULES" "$(cat "$P/archive/rule-no-version-bump.target-before")"
  assert_eq "tty: answer y: archived as approved" "approved" "$(proposal_get "$P/archive/rule-no-version-bump.md" status)"
  assert_eq "tty: answer y: proposal event" '{"id":"rule-no-version-bump","action":"approved"}' "$(jq -c 'select(.kind == "proposal") | .data' "$EVF" | tail -1)"
  # a patch that no longer applies (the rule is already there) is refused before the question
  mkrule no-version-bump-again "$(proposal_fingerprint other)" 2
  tty_cp y approve rule-no-version-bump-again; rc=$?
  assert_eq "tty: a patch that no longer applies: exits 1" "1" "$rc"
  assert_contains "tty: ... and says so" "$(cat "$WORK/tty.out")" "does not apply"
  assert_file "tty: ... the proposal stays open" "$P/rule-no-version-bump-again.md"
  "$CP" reject rule-no-version-bump-again >/dev/null
  # a patch that touches two files is refused
  two=$'--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1 +1 @@\n-# Owner rules (fixture)\n+# Owner rules\n--- a/other.md\n+++ b/other.md\n@@ -1 +1 @@\n-x\n+y'
  mkrule two-files "$(proposal_fingerprint two)" 2 "$two"
  assert_contains "cli: a patch for two files is refused (diff)" "$("$CP" diff rule-two-files 2>&1)" "exactly one file"
  # skill: nothing in ~/.claude/skills, the skill-creator prompt is printed
  tty_cp "" approve skill-sync-rebase; rc=$?
  assert_eq "tty: skill approve exits 0" "0" "$rc"
  assert_contains "tty: skill approve prints the skill-creator prompt" "$(cat "$WORK/tty.out")" 'Use the skill-creator skill to create a new skill named "sync-rebase-test"'
  assert_no_file "tty: skill approve writes nothing into ~/.claude/skills" "$HOME/.claude/skills"
  assert_no_file "tty: ... nor into CLAUDE_DIR/skills" "$CLAUDE_DIR/skills"
  assert_eq "tty: skill archived as approved" "approved" "$(proposal_get "$P/archive/skill-sync-rebase.md" status)"
  # lesson: appended to the profile
  mkother lesson plain-words "plain words" 2 "Use plain words."
  tty_cp "" approve lesson-plain-words; rc=$?
  assert_eq "tty: lesson approve exits 0" "0" "$rc"
  assert_eq "tty: lesson approve appends to profile/lessons.jsonl" "lesson-plain-words Use plain words." \
    "$(jq -r '"\(.id) \(.text)"' "$AGENT_HOME/profile/lessons.jsonl")"
else
  echo "no usable script(1) pty: ching-proposals tty tests skipped" >"$T_ROOT/skipped.t_learn_plumbing"
fi

# ================= lint: ching-proposals has no .sh suffix, so t_lint does not see it =================
assert_ok "lint: bash -n ching-proposals" bash -n "$CP"
assert_contains "lint: ching-proposals runs in strict mode" "$(sed -n 1,40p "$CP")" "set -euo pipefail"
SC=$(command -v shellcheck || true); [ -n "$SC" ] || { [ -x /tmp/sc-venv/bin/shellcheck ] && SC=/tmp/sc-venv/bin/shellcheck; }
if [ -n "$SC" ]; then
  out=$(cd "$BIN" && "$SC" -x -S warning ching-proposals 2>&1) && pass "lint: shellcheck ching-proposals" || fail "lint: shellcheck ching-proposals" "$out"
fi

# ================= registry leak (spec question 10) =================
# The 4,615 /private/tmp registry entries of 2026-10-05 were real `claude -p` titling runs (cwd /tmp, source startup,
# about every 2.5 s) whose hooks saw the real HOME and no AGENT_HOME. The hooks write wherever AGENT_HOME points, and
# fall back to $HOME/.agent: the suite must always give them a sandbox (tests/run.sh checks a sentinel "real" home).
FAKE_REAL="$WORK/fake-real-home"; mkdir -p "$FAKE_REAL/.agent/sessions/sentinel"; printf 'cwd=/sentinel\n' >"$FAKE_REAL/.agent/sessions/sentinel/meta"
j=$(jq -nc '{hook_event_name: "SessionStart", cwd: "/private/tmp", session_id: "6f947810-1425-4d52-afd2-135a7dfe4690", source: "startup"}')
printf '%s' "$j" | HOME="$FAKE_REAL" AGENT_HOME="$WORK/leak-sandbox" "$BIN/session-start.sh" >/dev/null
assert_eq "leak: with AGENT_HOME set, the hook leaves the real registry alone" "sentinel" "$(ls "$FAKE_REAL/.agent/sessions" | tr '\n' ' ' | sed 's/ $//')"
assert_file "leak: ... and writes the sandbox" "$WORK/leak-sandbox/sessions/6f947810-1425-4d52-afd2-135a7dfe4690/meta"
printf '%s' "$j" | env -u AGENT_HOME HOME="$FAKE_REAL" "$BIN/session-start.sh" >/dev/null
assert_file "leak: without AGENT_HOME it falls back to \$HOME/.agent (how the real registry filled up)" "$FAKE_REAL/.agent/sessions/6f947810-1425-4d52-afd2-135a7dfe4690/meta"
assert_contains "leak: tests/run.sh checks the suite against a sentinel real home" "$(cat "$KIT/tests/run.sh")" "sentinel"
exit 0
