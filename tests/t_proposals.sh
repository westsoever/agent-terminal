#!/usr/bin/env bash
# t_proposals.sh - Phase 6 step 0 contracts (spec 4.2, 4.4, 8): learn_filter (the one exclusion definition),
# learn_redact, proposal_write (the only writer of proposal files) and its helpers, templates/PROPOSAL.md, the
# fixture transcripts and the claude stub that the learner components code against.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
FX="$KIT/tests/fixtures/learn"
PROJ="$FX/claude/projects"
FXHOME=/Users/fixture/.agent   # the fixture learner's AGENT_HOME: its .work transcript lives under it
# shellcheck disable=SC2206
ALL=( "$PROJ"/*/*.jsonl )

# ---------- learn_filter: path rules (jq module) ----------
cwd_ex() { jq -n --arg p "$1" --arg w "$FXHOME/proposals/.work" -L "$BIN" 'include "learn-filter"; $p | learn_cwd_excluded($w)'; }
ex()   { assert_eq "cwd excluded: $1" "true" "$(cwd_ex "$2")"; }
kept() { assert_eq "cwd kept: $1" "false" "$(cwd_ex "$2")"; }
ex "/tmp itself" /tmp
ex "under /tmp" /tmp/task9-cont-repo
ex "/private/tmp sandbox" /private/tmp/agent-sandbox-repo
ex "macOS temp" /var/folders/zz/x/T/probe
ex "private macOS temp" /private/var/folders/zz/x/T/probe
ex "task*-repo" /Users/fixture/eval/task3-repo
ex "inside task*-repo" /Users/fixture/eval/task12-repo/src
ex "claude-mem observer" /Users/fixture/.claude-mem/observer-sessions
ex "learner work dir" /Users/fixture/.agent/proposals/.work
ex "below the learner work dir" /Users/fixture/.agent/proposals/.work/sub
kept "home" /Users/fixture
kept "repo" /Users/fixture/code/shop
kept "proposals dir itself is not the work dir" /Users/fixture/.agent/proposals
kept "name only looks like tmp" /Users/fixture/tmpfiles
kept "task without -repo" /Users/fixture/task3
kept "empty cwd" ""

skipdir() { if learn_skip_project "$2"; then pass "project dir skipped: $1"; else fail "project dir skipped: $1" "  kept: $2"; fi; }
keepdir() { if learn_skip_project "$2"; then fail "project dir kept: $1" "  skipped: $2"; else pass "project dir kept: $1"; fi; }
export AGENT_HOME_SAVED=$AGENT_HOME
AGENT_HOME=$FXHOME
skipdir "observer" "$PROJ/-Users-fixture--claude-mem-observer-sessions"
skipdir "observer, real owner name" "-Users-clyde--claude-mem-observer-sessions"
skipdir "/private/tmp" "-private-tmp-agent-sandbox-repo"
skipdir "/tmp" "-tmp-task9-cont-repo"
skipdir "/private/var/folders" "-private-var-folders-zz-fx-T-probe"
skipdir "task*-repo" "-Users-fixture-eval-task3-repo"
skipdir "learner work dir" "-Users-fixture--agent-proposals--work"
keepdir "home" "-Users-fixture"
keepdir "repo" "$PROJ/-Users-fixture-code-shop"
keepdir "worktree" "-Users-fixture-code--worktrees-shop-a"

# ---------- learn_filter prompts: the counted human prompts of the fixture tree ----------
out=$(learn_filter prompts "${ALL[@]}" 2>"$WORK/filter.err"); rc=$?
assert_eq "filter prompts: exit 0 (a malformed line is skipped, not fatal)" "0" "$rc"
assert_eq "filter prompts: nothing on stderr" "" "$(cat "$WORK/filter.err")"
assert_eq "filter prompts: every output line is compact JSON" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" "$(printf '%s\n' "$out" | jq -c . | wc -l | tr -d ' ')"
assert_eq "filter prompts: 17 counted prompts" "17" "$(printf '%s\n' "$out" | grep -c .)"
sids=$(printf '%s\n' "$out" | jq -r .sessionId | sort -u | cut -c1-2 | tr '\n' ' ')
assert_eq "filter prompts: exactly the six plain CLI sessions" "a1 a2 a3 b1 b2 b3 " "$sids"
texts=$(printf '%s\n' "$out" | jq -r -L "$BIN" 'include "learn-filter"; learn_prompt_text')
assert_not_contains "filter: observer run excluded" "$texts" "memory observer"
assert_not_contains "filter: sdk-cli run excluded" "$texts" "Score each lead"
assert_not_contains "filter: /private/tmp sandbox excluded" "$texts" "hello.txt"
assert_not_contains "filter: task*-repo excluded" "$texts" "failing test pass"
assert_not_contains "filter: /private/var/folders excluded" "$texts" "temp folder"
assert_not_contains "filter: learner's own .work run excluded" "$texts" "ching-learn-task"
assert_not_contains "filter: isMeta line excluded" "$texts" "Caveat:"
assert_not_contains "filter: sidechain line excluded" "$texts" "Search the codebase"
assert_not_contains "filter: <command-name> prompt excluded" "$texts" "command-name"
assert_not_contains "filter: [Request interrupted excluded" "$texts" "Request interrupted"
assert_not_contains "filter: tool results excluded" "$(printf '%s\n' "$out" | jq -c .message.content)" "tool_result"
assert_contains "filter: plain CLI prompt counted" "$texts" "add a dark mode toggle to the settings page"
assert_contains "filter: array-of-text prompt counted" "$texts" "also add the feed to the sitemap"
assert_contains "filter: prompt in ~ counted" "$texts" "install the date library"
# the .work rule comes from AGENT_HOME: under another AGENT_HOME the same transcript is an ordinary session
AGENT_HOME=/Users/someone-else/.agent
assert_contains "filter: .work exclusion follows AGENT_HOME" "$(learn_filter prompts "$PROJ"/-Users-fixture--agent-proposals--work/*.jsonl | jq -r .sessionId)" "e6000000"
AGENT_HOME=$FXHOME

# callers run under strict mode; a skipped project directory is never opened (an unreadable file there is fine)
out2=$(bash -c 'set -euo pipefail; . "$1"; shift; learn_filter prompts "$@"' _ "$BIN/lib.sh" "${ALL[@]}" 2>&1); rc=$?
assert_eq "filter prompts: same 17 under set -euo pipefail" "0 17" "$rc $(printf '%s\n' "$out2" | grep -c .)"
mkdir -p "$WORK/proj/-Users-fixture--claude-mem-observer-sessions"
cp "$PROJ"/-Users-fixture--claude-mem-observer-sessions/*.jsonl "$WORK/proj/-Users-fixture--claude-mem-observer-sessions/x.jsonl"
chmod 000 "$WORK/proj/-Users-fixture--claude-mem-observer-sessions/x.jsonl"
out2=$(learn_filter prompts "$WORK/proj/-Users-fixture--claude-mem-observer-sessions/x.jsonl" 2>&1); rc=$?
assert_eq "filter: a skipped directory's files are not opened" "0|" "$rc|$out2"
chmod 600 "$WORK/proj/-Users-fixture--claude-mem-observer-sessions/x.jsonl"
assert_eq "filter: no files at all is fine" "0|" "$(learn_filter prompts; echo "$?|")"
assert_eq "lib.sh sourced by a relative path still finds its helpers after a cd" "MY_TOKEN=[REDACTED]" \
  "$(cd "$KIT" && bash -c '. bin/lib.sh; cd /; printf "MY_TOKEN=x" | learn_redact')"

# the golden extractor output (.work/prompts.jsonl) holds exactly the prompts the filter keeps
golden=$(jq -r '[.sid, .ts] | @tsv' "$FX/work/prompts.jsonl" | sort)
assert_eq "golden prompts.jsonl = filter output (sid, ts)" "$golden" "$(printf '%s\n' "$out" | jq -r '[.sessionId, .timestamp] | @tsv' | sort)"
assert_eq "golden prompts.jsonl: text is learn_prompt_text, redacted" \
  "$(jq -r .text "$FX/work/prompts.jsonl" | sort)" \
  "$(printf '%s\n' "$out" | jq -c -L "$BIN" 'include "learn-filter"; {t: learn_prompt_text}' | learn_redact --jsonl | jq -r .t | sort)"
assert_eq "golden toolseq.jsonl: one line per counted session" "a1 a2 a3 b1 b2 b3 " "$(jq -r .sid "$FX/work/toolseq.jsonl" | sort | cut -c1-2 | tr '\n' ' ')"
assert_eq "golden toolseq.jsonl: the 4-step sequence is in 3 sessions on 2 days" "3 2" \
  "$(jq -s -r '[.[] | select(.tokens | join(">") | contains("git fetch>git rebase>bun test>git push"))] | "\(length) \(map(.day) | unique | length)"' "$FX/work/toolseq.jsonl")"
assert_eq "golden toolseq.jsonl: every prompts[].ts is a golden prompt" "" \
  "$(comm -23 <(jq -r '.sid as $s | .prompts[] | "\($s)\t\(.ts)"' "$FX/work/toolseq.jsonl" | sort) <(printf '%s\n' "$golden"))"

# ---------- learn_filter lines: every countable transcript line (tool calls for the miner) ----------
lines=$(learn_filter lines "${ALL[@]}")
assert_contains "filter lines: tool calls of real sessions kept" "$lines" '"git rebase origin/main"'
assert_not_contains "filter lines: sidechain tool call dropped" "$lines" '"CHANGELOG"'
assert_not_contains "filter lines: sdk-cli lines dropped" "$lines" "e2000000"
assert_not_contains "filter lines: sandbox lines dropped" "$lines" "e3000000"
assert_eq "filter lines: only user and assistant lines" "assistant user " "$(printf '%s\n' "$lines" | jq -r .type | sort -u | tr '\n' ' ')"

# ---------- learn_filter events ----------
evs=$(learn_filter events "$FX/events.jsonl")
assert_eq "filter events: 4 kept (real cwd, plus learner bookkeeping)" "4" "$(printf '%s\n' "$evs" | grep -c .)"
assert_eq "filter events: kinds kept" "learn_run prompt proposal stop_ok " "$(printf '%s\n' "$evs" | jq -r .kind | sort | tr '\n' ' ')"
assert_not_contains "filter events: sandbox and .work sessions dropped" "$evs" "session_start"
assert_fails "filter: unknown mode fails" learn_filter bogus "$FX/events.jsonl"
AGENT_HOME=$AGENT_HOME_SAVED

# ---------- learn_redact ----------
red() { printf '%s' "$1" | learn_redact; }
# the guard's credential name patterns (var_is_secret in guard.sh) are all covered: drift check
gwords=$(grep '^var_is_secret()' "$BIN/guard.sh" | perl -ne 'while (/\\\$\*((?:\[..\]|_)+)\*/g) { (my $w = $1) =~ s/\[(.).\]/$1/g; print uc($w), "\n" }')
assert_eq "redact: found the guard's 5 credential words" "5" "$(printf '%s\n' "$gwords" | grep -c .)"
for w in $gwords; do
  assert_eq "redact: guard word $w as NAME=value" "export MY_${w}=[REDACTED] done" "$(red "export MY_${w}=abc123xyz done")"
done
assert_eq "redact: quoted value" 'GH_TOKEN="[REDACTED]" x' "$(red 'GH_TOKEN="a b c" x')"
assert_eq "redact: json-style key" '"api_key": "[REDACTED]"' "$(red '"api_key": "abc123"')"
assert_eq "redact: yaml-style key" 'password: [REDACTED]' "$(red 'password: hunter2')"
# value shapes are built at run time so no secret-shaped literal sits in the repo (GitHub push protection)
for v in "sk-ant-api03-$(printf 'A%.0s' {1..30})" "gh""p_$(printf 'b%.0s' {1..36})" "github_""pat_$(printf 'c%.0s' {1..40})" \
         "AK""IA$(printf 'D%.0s' {1..16})" "xox""b-1234567890-abcdefghij" "sk_""live_$(printf 'e%.0s' {1..24})" \
         "ey""J$(printf 'f%.0s' {1..20}).ey""J$(printf 'g%.0s' {1..20}).$(printf 'h%.0s' {1..20})" "sb""p_$(printf '1%.0s' {1..40})"; do
  r=$(red "use $v now")
  assert_eq "redact: value shape ${v:0:6}..." "use [REDACTED] now" "$r"
done
assert_eq "redact: bearer header" "Authorization: Bearer [REDACTED]" "$(red "Authorization: Bearer $(printf 'z%.0s' {1..30})")"
assert_eq "redact: url credentials" "https://bob:[REDACTED]@example.com/x" "$(red 'https://bob:pa55word@example.com/x')"
assert_eq "redact: PEM private key block" "key: [REDACTED] end" "$(red $'key: -----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY----- end')"
assert_eq "redact: ordinary prose untouched" "merge to main without losing work" "$(red 'merge to main without losing work')"
assert_eq "redact: idempotent" "MY_TOKEN=[REDACTED]" "$(red 'MY_TOKEN=abc' | learn_redact)"
jl=$(printf '%s\n%s\n%s\n' '{"text":"MY_SECRET=abc def","n":1}' '{"text":"nothing here","n":2}' 'not json MY_TOKEN=abc' | learn_redact --jsonl)
assert_eq "redact --jsonl: string values redacted" "MY_SECRET=[REDACTED] def" "$(printf '%s\n' "$jl" | sed -n 1p | jq -r .text)"
assert_eq "redact --jsonl: unchanged line kept byte for byte" '{"text":"nothing here","n":2}' "$(printf '%s\n' "$jl" | sed -n 2p)"
assert_eq "redact --jsonl: a non-JSON line is redacted as text" "not json MY_TOKEN=[REDACTED]" "$(printf '%s\n' "$jl" | sed -n 3p)"

# ---------- helpers ----------
fp1=$(proposal_fingerprint "Do not bump the version;  the owner releases by hand ")
assert_eq "fingerprint: 40 hex" "40" "$(printf '%s' "$fp1" | grep -cE '^[0-9a-f]{40}$' | sed 's/^1$/40/')"
assert_eq "fingerprint: case and blanks normalised" "$fp1" "$(proposal_fingerprint "do not bump the VERSION; the owner releases by hand")"
assert_eq "fingerprint: different pattern differs" "1" "$([ "$fp1" != "$(proposal_fingerprint 'use pnpm')" ] && echo 1)"
assert_eq "slug: plain words" "do-not-bump-the-version" "$(proposal_slug "Do NOT bump the version!")"
s=$(proposal_slug "$(printf 'word %.0s' {1..30})")
assert_eq "slug: capped at 50 chars, no trailing dash" "1" "$([ "${#s}" -le 50 ] && [ "${s%-}" = "$s" ] && echo 1)"
assert_eq "learn_setting: D26 default model" "haiku" "$(learn_setting LEARN_MODEL_CLASSIFY)"
assert_eq "learn_setting: D26 draft model" "sonnet" "$(learn_setting LEARN_MODEL_DRAFT)"
assert_eq "learn_setting: D26 token cap" "200000" "$(learn_setting LEARN_TOKEN_CAP)"
assert_eq "learn_setting: D26 skill cap" "3" "$(learn_setting LEARN_SKILL_MAX)"
assert_eq "learn_setting: snippet cap" "200" "$(learn_setting LEARN_MAX_SNIPPETS)"
printf 'LEARN_SKILL_MAX=5\n' >"$AGENT_HOME/config"
assert_eq "learn_setting: config overrides default" "5" "$(learn_setting LEARN_SKILL_MAX)"
assert_eq "learn_setting: env overrides config" "7" "$(LEARN_SKILL_MAX=7 learn_setting LEARN_SKILL_MAX)"
rm -f "$AGENT_HOME/config"
assert_fails "learn_setting: refuses a non-LEARN_ name" learn_setting HOME
assert_eq "learn_work_dir" "$AGENT_HOME/proposals/.work" "$(learn_work_dir)"

# ---------- proposal_write: a new rule proposal ----------
P="$AGENT_HOME/proposals"
long=$(printf 'q%.0s' {1..400})
pj() { # fingerprint [evidence-quote] [patch] -> a valid rule proposal JSON
  jq -nc --arg fp "$1" --arg q "${2:-no, do not bump the version}" --arg long "$long" --arg patch "${3:-$'--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1 +1,2 @@\n # Rules\n+- Never bump the version; the owner releases by hand.'}" '{
    component: "corrections", fingerprint: $fp, sessions: 3, days: 2, target: "~/.agents/CLAUDE.md",
    proposal: "Add a rule: never bump the version number.\nThe owner releases by hand.\n## not a section",
    evidence: [
      {sid: "a1000000-0000-4000-8000-00000000a001", day: "2026-10-12", cwd: "/Users/fixture/code/shop", quote: $q},
      {sid: "a2000000-0000-4000-8000-00000000a002", day: "2026-10-12", cwd: "/Users/fixture/code/blog", quote: ("line one\nline two " + $long)},
      {sid: "a3000000-0000-4000-8000-00000000a003", day: "2026-10-13", cwd: "/Users/fixture/code/shop", quote: "MY_API_KEY=abc123 leaked"}],
    patch: $patch,
    why_not_covered: "Checked ~/.agents/CLAUDE.md: it has no rule about version numbers."}'
}
J1=$(pj "$fp1")
# the success path must also run under the strict mode every bin script uses
out=$(printf '%s' "$J1" | bash -c 'set -euo pipefail; . "$1"; proposal_write rule-no-version-bump.md' _ "$BIN/lib.sh" 2>&1); rc=$?
F="$P/rule-no-version-bump.md"
assert_eq "write: exit 0 under set -euo pipefail" "0" "$rc"
assert_eq "write: prints 'written <path>'" "written $(cd "$P" && pwd -P)/rule-no-version-bump.md" "$out"
assert_file "write: file created" "$F"
assert_eq "write: dir mode 0700" "700" "$(stat -f %Lp "$P")"
assert_eq "write: file mode 0600" "600" "$(stat -f %Lp "$F")"
assert_eq "write: header keys in spec 4.2 order" "id kind status created component fingerprint sessions days target " \
  "$(sed '/^$/q' "$F" | sed -n 's/^\([a-z_]*\): .*/\1/p' | tr '\n' ' ')"
assert_eq "write: id" "rule-no-version-bump" "$(sed -n 1p "$F" | sed 's/^id: //')"
assert_eq "write: kind from the file name" "rule" "$(proposal_get "$F" kind)"
assert_eq "write: status open" "open" "$(proposal_get "$F" status)"
assert_eq "write: created is ISO 8601 UTC" "1" "$(proposal_get "$F" created | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$')"
assert_eq "write: fingerprint" "$fp1" "$(proposal_get "$F" fingerprint)"
assert_eq "write: sessions" "3" "$(proposal_get "$F" sessions)"
assert_eq "write: days" "2" "$(proposal_get "$F" days)"
# shellcheck disable=SC2088 # a literal ~ is what the header holds
assert_eq "write: target" "~/.agents/CLAUDE.md" "$(proposal_get "$F" target)"
assert_eq "write: line 10 is blank, line 11 is ## proposal" "|## proposal" "$(sed -n 10p "$F")|$(sed -n 11p "$F")"
assert_eq "write: sections in spec order" "## proposal|## evidence|## patch|## why this is not already covered|" "$(grep '^## ' "$F" | tr '\n' '|')"
assert_contains "write: a '## ' line inside the text is demoted" "$(proposal_section "$F" proposal)" "### not a section"
ev1=$(proposal_section "$F" evidence)
assert_contains "write: evidence line format" "$ev1" '- a1000000 2026-10-12 /Users/fixture/code/shop "no, do not bump the version"'
assert_eq "write: one evidence line per item" "3" "$(printf '%s\n' "$ev1" | grep -c '^- ')"
q2=$(printf '%s\n' "$ev1" | sed -n 2p | sed 's/^- a2000000 2026-10-12 \/Users\/fixture\/code\/blog "//; s/"$//')
assert_eq "write: quote capped at 300 characters" "300" "${#q2}"
assert_contains "write: newlines in a quote become spaces" "$q2" "line one line two"
assert_contains "write: secret in a quote redacted" "$ev1" 'MY_API_KEY=[REDACTED] leaked'
assert_not_contains "write: secret value gone from the file" "$(cat "$F")" "abc123"
assert_eq "write: patch is a fenced diff" '```diff' "$(proposal_section "$F" patch | head -1)"
assert_eq "write: proposal_patch gives the raw diff back" "$(jq -r .patch <<<"$J1")" "$(proposal_patch "$F")"
assert_contains "write: why section" "$(proposal_section "$F" 'why this is not already covered')" "no rule about version numbers"

# ---------- proposal_write: rerun, rejected, archived ----------
created1=$(proposal_get "$F" created)
J1b=$(pj "$fp1" "stop bumping the version" | jq -c '.sessions = 4 | .days = 3 | .proposal = "Different wording."')
out=$(printf '%s' "$J1b" | proposal_write rule-other-slug.md); rc=$?
assert_eq "rerun: exit 0" "0" "$rc"
assert_eq "rerun: refreshes the open proposal with the same fingerprint" "refreshed $(cd "$P" && pwd -P)/rule-no-version-bump.md" "$out"
assert_no_file "rerun: no duplicate under the new slug" "$P/rule-other-slug.md"
assert_eq "rerun: one file per fingerprint" "1" "$(grep -l "^fingerprint: $fp1" "$P"/*.md | wc -l | tr -d ' ')"
assert_eq "rerun: sessions refreshed" "4" "$(proposal_get "$F" sessions)"
assert_eq "rerun: days refreshed" "3" "$(proposal_get "$F" days)"
assert_contains "rerun: evidence refreshed" "$(proposal_section "$F" evidence)" '"stop bumping the version"'
assert_eq "rerun: created kept" "$created1" "$(proposal_get "$F" created)"
assert_contains "rerun: proposal text kept (the owner may be reading it)" "$(proposal_section "$F" proposal)" "never bump the version"
assert_eq "rerun: patch kept" "$(jq -r .patch <<<"$J1")" "$(proposal_patch "$F")"
assert_eq "rerun: still 0600" "600" "$(stat -f %Lp "$F")"

fp2=$(proposal_fingerprint "use pnpm not npm")
printf '%s rejected 2026-10-15: not a rule\n' "$fp2" >"$P/rejected.txt"
out=$(pj "$fp2" | proposal_write rule-use-pnpm.md); rc=$?
assert_eq "rejected: exit 0" "0" "$rc"
assert_eq "rejected: says skipped" "skipped rejected $fp2" "$out"
assert_no_file "rejected: never re-proposed" "$P/rule-use-pnpm.md"

mkdir -p "$P/archive"
fp3=$(proposal_fingerprint "approved pattern"); fp4=$(proposal_fingerprint "snoozed pattern"); fp5=$(proposal_fingerprint "old snooze")
for x in "$fp3:approved:rule-appr" "$fp4:snoozed\\:2999-01-01:rule-snz" "$fp5:snoozed\\:2000-01-01:rule-old"; do
  f=${x%%:*}; rest=${x#*:}; st=${rest%:*}; id=${rest##*:}
  pj "$f" | proposal_write "$id.md" >/dev/null
  sed "s/^status: open\$/status: ${st//\\/}/" "$P/$id.md" >"$P/archive/$id.md"; rm "$P/$id.md"
done
assert_eq "archived approved: skipped" "skipped approved $fp3" "$(pj "$fp3" | proposal_write rule-appr-2.md)"
assert_eq "archived snoozed until a future date: skipped" "skipped snoozed $fp4" "$(pj "$fp4" | proposal_write rule-snz-2.md)"
assert_eq "archived snooze that has run out: proposed again" "written $(cd "$P" && pwd -P)/rule-old-2.md" "$(pj "$fp5" | proposal_write rule-old-2.md)"

out=$(pj "$(proposal_fingerprint 'another pattern')" | proposal_write rule-no-version-bump.md 2>&1); rc=$?
assert_eq "id taken by another fingerprint: exit 4" "4" "$rc"
assert_eq "id taken: the existing proposal is untouched" "$fp1" "$(proposal_get "$F" fingerprint)"

# ---------- proposal_write: path safety (exit 3, nothing written) ----------
fpx=$(proposal_fingerprint "path probe")
JX=$(pj "$fpx")
mkdir -p "$WORK/outside"
refuse() { # name path
  local r; printf '%s' "$JX" | proposal_write "$2" >/dev/null 2>&1; r=$?
  assert_eq "path refused (exit 3): $1" "3" "$r"
}
refuse "../ escape" "../rule-escape.md"
refuse "deep ../ escape" "archive/../../rule-escape.md"
refuse "absolute path outside" "$WORK/outside/rule-escape.md"
refuse "absolute path with ../ that lands outside" "$P/../rule-escape.md"
refuse "subdirectory (proposals sit at the top)" "archive/rule-sub.md"
refuse "empty path" ""
refuse "the root itself" "$P"
refuse "dot component" "./rule-dot.md"
assert_no_file "path refused: nothing at AGENT_HOME" "$AGENT_HOME/rule-escape.md"
assert_eq "path refused: nothing written outside" "" "$(ls -A "$WORK/outside")"
ln -s "$WORK/outside/victim.md" "$P/rule-link.md"
refuse "a symlink at the target" "rule-link.md"
assert_no_file "symlink target: the link target was not created" "$WORK/outside/victim.md"
rm "$P/rule-link.md"
assert_eq "absolute path inside the root (as AGENT_HOME spells it) is fine" "written $(cd "$P" && pwd -P)/rule-abs.md" \
  "$(pj "$(proposal_fingerprint abs)" | proposal_write "$P/rule-abs.md")"
assert_eq "absolute path inside the root (canonical spelling) is fine" "written $(cd "$P" && pwd -P)/rule-abs2.md" \
  "$(pj "$(proposal_fingerprint abs2)" | proposal_write "$(cd "$P" && pwd -P)/rule-abs2.md")"
# proposal_safe_path: the shared check for other learner writes (.work, the weekly report)
assert_eq "safe_path: relative subpath allowed, parents made 0700" "$(cd "$P" && pwd -P)/.work/x/prompts.jsonl" "$(proposal_safe_path .work/x/prompts.jsonl)"
assert_eq "safe_path: made dir is 0700" "700" "$(stat -f %Lp "$P/.work/x")"
assert_fails "safe_path: ../ refused" proposal_safe_path ../x
ln -s "$WORK/outside" "$P/.work/out"
assert_fails "safe_path: symlinked directory inside the root refused" proposal_safe_path .work/out/prompts.jsonl
# a symlinked root (planted to redirect the learner) is refused outright
AH2="$WORK/agent2"; mkdir -p "$AH2" "$WORK/elsewhere"; ln -s "$WORK/elsewhere" "$AH2/proposals"
out=$(printf '%s' "$JX" | AGENT_HOME=$AH2 proposal_write rule-x.md 2>&1); rc=$?
assert_eq "symlinked proposals root: exit 3" "3" "$rc"
assert_eq "symlinked proposals root: nothing written" "" "$(ls -A "$WORK/elsewhere")"
# a root that already existed with a looser mode is tightened
AH3="$WORK/agent3"; mkdir -p "$AH3/proposals"; chmod 755 "$AH3/proposals"
printf '%s' "$JX" | AGENT_HOME=$AH3 proposal_write rule-x.md >/dev/null
assert_eq "existing root tightened to 0700" "700" "$(stat -f %Lp "$AH3/proposals")"

# ---------- proposal_write: bad input (exit 2, nothing written) ----------
bad() { # name path json
  local r; printf '%s' "$3" | proposal_write "$2" >/dev/null 2>&1; r=$?
  assert_eq "bad input (exit 2): $1" "2" "$r"
  assert_no_file "bad input: no file for $1" "$P/$2"
}
bad "not JSON" rule-b1.md "not json"
bad "no fingerprint" rule-b2.md "$(jq -c 'del(.fingerprint)' <<<"$JX")"
bad "fingerprint not 40 hex" rule-b3.md "$(jq -c '.fingerprint = "abc"' <<<"$JX")"
bad "unknown kind in the file name" report-2026-W42.md "$JX"
bad "unknown kind (foo)" foo-bar.md "$JX"
bad "upper-case slug" rule-Bad.md "$JX"
bad "no .md suffix" rule-b4 "$JX"
bad "kind in JSON disagrees with the file name" rule-b5.md "$(jq -c '.kind = "skill"' <<<"$JX")"
bad "rule without a patch" rule-b6.md "$(jq -c 'del(.patch)' <<<"$JX")"
bad "unknown component" rule-b7.md "$(jq -c '.component = "vibes"' <<<"$JX")"
bad "sessions not an integer" rule-b8.md "$(jq -c '.sessions = "3"' <<<"$JX")"
bad "evidence day not YYYY-MM-DD" rule-b9.md "$(jq -c '.evidence[0].day = "12/10/2026"' <<<"$JX")"
bad "empty proposal text" rule-b10.md "$(jq -c '.proposal = ""' <<<"$JX")"
bad "skill without why_not_covered" skill-b11.md "$(jq -c 'del(.why_not_covered) | del(.patch) | .component = "skills"' <<<"$JX")"
# a rule's patch must be unified-diff syntax: a "## " line would end the ## patch section early, prose is no patch
bad "patch with a '## ' line" rule-b12.md "$(jq -c '.patch = "--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1 +1,2 @@\n # Rules\n## why this is not already covered\n+- x"' <<<"$JX")"
bad "patch that is prose" rule-b13.md "$(jq -c '.patch = "Add a line saying never bump the version."' <<<"$JX")"
bad "patch with no hunk" rule-b14.md "$(jq -c '.patch = "--- a/CLAUDE.md\n+++ b/CLAUDE.md"' <<<"$JX")"
bad "patch with no file header" rule-b15.md "$(jq -c '.patch = "@@ -1 +1,2 @@\n # Rules\n+- x"' <<<"$JX")"
err=$(jq -c '.patch = "Add a line."' <<<"$JX" | proposal_write rule-b16.md 2>&1 >/dev/null)
assert_contains "bad patch: the message says unified diff" "$err" "unified diff"
# what a real diff may hold: git headers, a blank context line, '\ No newline', '+## ' (a heading the patch adds)
okpatch=$'diff --git a/CLAUDE.md b/CLAUDE.md\nindex 1111111..2222222 100644\n--- a/CLAUDE.md\n+++ b/CLAUDE.md\n@@ -1,2 +1,4 @@\n # Rules\n\n+## Versions\n+Never bump it.\n\\ No newline at end of file'
out=$(jq -c --arg p "$okpatch" '.patch = $p | .fingerprint = "'"$(proposal_fingerprint okpatch)"'"' <<<"$JX" | proposal_write rule-okpatch.md 2>&1); rc=$?
assert_eq "patch: git headers, blank context, \\ No newline and +## are accepted" "0" "$rc"
assert_eq "patch: ... and come back unchanged" "$okpatch" "$(proposal_patch "$P/rule-okpatch.md")"
assert_eq "patch: ... a +## line ends no section" "## proposal|## evidence|## patch|## why this is not already covered|" "$(grep '^## ' "$P/rule-okpatch.md" | tr '\n' '|')"
# control characters (a newline in a sid, an escape in a cwd, a CR in the target) never reach a header or evidence line
cj=$(jq -c --arg fp "$(proposal_fingerprint ctrl)" '.fingerprint = $fp | .target = "~/.agents/CLA\rUDE\u001b[31m.md"
  | .evidence = [{sid: "c1\n## patch\nc2000000", day: "2026-10-12", cwd: "/tmp/a\u001b[2Jb", quote: "say\u0007 hi\u001b[0m"}]' <<<"$JX")
out=$(printf '%s' "$cj" | proposal_write rule-ctrl.md 2>&1); rc=$?
assert_eq "control chars: written" "0" "$rc"
FC="$P/rule-ctrl.md"
assert_eq "control chars: no control character left in the file (tabs and newlines aside)" "0" "$(LC_ALL=C tr -d '\n\t' <"$FC" | LC_ALL=C tr -cd '\000-\037\177' | wc -c | tr -d ' ')"
assert_eq "control chars: the sid's newline does not start a section" "## proposal|## evidence|## patch|## why this is not already covered|" "$(grep '^## ' "$FC" | tr '\n' '|')"
assert_eq "control chars: one evidence line" "1" "$(proposal_section "$FC" evidence | grep -c .)"
assert_contains "control chars: the evidence line keeps its shape" "$(proposal_section "$FC" evidence)" '- c1##patc 2026-10-12 /tmp/a [2Jb "say  hi [0m"'
# shellcheck disable=SC2088 # a literal ~ is what the header holds
assert_eq "control chars: target cleaned" "~/.agents/CLA UDE [31m.md" "$(proposal_get "$FC" target)"
# a skill proposal has no patch section
out=$(jq -c 'del(.patch) | .component = "skills" | .target = "sync-and-ship"' <<<"$JX" | proposal_write skill-sync-and-ship.md)
assert_eq "skill: written" "written $(cd "$P" && pwd -P)/skill-sync-and-ship.md" "$out"
assert_eq "skill: no patch section" "## proposal|## evidence|## why this is not already covered|" "$(grep '^## ' "$P/skill-sync-and-ship.md" | tr '\n' '|')"

# ---------- templates/PROPOSAL.md: the filled example parses with the same helpers ----------
T="$KIT/templates/PROPOSAL.md"
assert_eq "template: header keys in spec order" "id kind status created component fingerprint sessions days target " \
  "$(sed '/^$/q' "$T" | sed -n 's/^\([a-z_]*\): .*/\1/p' | tr '\n' ' ')"
assert_eq "template: kind matches the id" "rule" "$(proposal_get "$T" kind)"
assert_eq "template: fingerprint is 40 hex" "1" "$(proposal_get "$T" fingerprint | grep -cE '^[0-9a-f]{40}$')"
assert_eq "template: sections in spec order" "## proposal|## evidence|## patch|## why this is not already covered|" "$(grep '^## ' "$T" | tr '\n' '|')"
assert_contains "template: patch is a unified diff" "$(proposal_patch "$T")" "+++ "
bad_ev() { perl -ne '$n++ unless /^- [0-9a-f]{8} [0-9]{4}-[0-9]{2}-[0-9]{2} [^ ]+ ".{1,300}"$/; END { print $n + 0 }'; }   # bash 3.2 misparses this inside "$(...)"
assert_eq "template: evidence lines match the format" "0" "$(proposal_section "$T" evidence | bad_ev)"

# ---------- the claude stub ----------
STUB="$FX/claude-stub"
assert_ok "stub: executable" test -x "$STUB"
env1=$(printf 'ching-learn-task: corrections-classify\nsnippets...\n' | CLAUDE_STUB_LOG="$WORK/stub.log" "$STUB" -p --model haiku --tools "" --output-format json); rc=$?
assert_eq "stub: exit 0" "0" "$rc"
assert_eq "stub: envelope type" "result success false" "$(jq -r '"\(.type) \(.subtype) \(.is_error)"' <<<"$env1")"
assert_eq "stub: usage tokens present" "number" "$(jq -r '.usage.input_tokens | type' <<<"$env1")"
assert_eq "stub: .result is the canned JSON" "$(jq -c . "$FX/stub/corrections-classify.json")" "$(jq -r .result <<<"$env1" | jq -c .)"
assert_contains "stub: logs its arguments" "$(cat "$WORK/stub.log")" "--model haiku"
assert_contains "stub: logs the prompt" "$(cat "$WORK/stub.log")" "ching-learn-task: corrections-classify"
for t in corrections-draft skills; do
  assert_eq "stub: task $t" "$(jq -c . "$FX/stub/$t.json")" "$(printf 'ching-learn-task: %s\n' "$t" | "$STUB" -p | jq -r .result | jq -c .)"
done
printf '{"x":1}' >"$WORK/canned.json"
assert_eq "stub: CLAUDE_STUB_RESPONSE overrides" '{"x":1}' "$(printf 'ching-learn-task: skills\n' | CLAUDE_STUB_RESPONSE="$WORK/canned.json" "$STUB" -p | jq -r .result | jq -c .)"
out=$(printf 'ching-learn-task: skills\n' | CLAUDE_STUB_EXIT=1 "$STUB" -p); rc=$?
assert_eq "stub: CLAUDE_STUB_EXIT sets the exit code" "1" "$rc"
assert_eq "stub: a failed call is an error envelope" "true" "$(jq -r .is_error <<<"$out")"
assert_eq "stub: CLAUDE_STUB_TOKENS sets input tokens" "999" "$(printf 'ching-learn-task: skills\n' | CLAUDE_STUB_TOKENS=999 "$STUB" -p | jq -r .usage.input_tokens)"
assert_fails "stub: unknown task fails" bash -c "printf 'ching-learn-task: nope\n' | '$STUB' -p"
assert_fails "stub: no task line fails" bash -c "printf 'hello\n' | '$STUB' -p"
# ---------- learn_model_call: the one model call every component makes (spec 5.6), against the stub ----------
export CHING_CLAUDE_BIN="$STUB" CLAUDE_STUB_LOG="$WORK/call.log"
ncalls() { grep -c '^ARGS:' "$WORK/call.log" 2>/dev/null || echo 0; }
TOKF="$P/.work/tokens-$(date +%Y-%m-%d)"
rm -f "$TOKF"
out=$(printf 'ching-learn-task: skills\nsequences...\n' | learn_model_call sonnet); rc=$?
assert_eq "model call: exit 0" "0" "$rc"
assert_eq "model call: prints the model's JSON answer" "$(jq -c . "$FX/stub/skills.json")" "$out"
log=$(cat "$WORK/call.log")
assert_contains "model call: flags (-p, model, no tools, json)" "$log" 'ARGS: -p --model sonnet --tools  --output-format json'
assert_contains "model call: runs in the learner's .work" "$log" "PWD: $(cd "$P" && pwd -P)/.work"
assert_contains "model call: CHING_LEARNER=1 and CLAUDE_MEM_INTERNAL=1" "$log" "ENV: CHING_LEARNER=1 CLAUDE_MEM_INTERNAL=1"
assert_contains "model call: prompt on stdin" "$log" "sequences..."
assert_eq "model call: tokens counted for the local day" "1500" "$(cat "$TOKF")"
assert_contains "model call: logged" "$(cat "$P/.work/learn.log")" "model=sonnet rc=0 tokens=1500"
# shellcheck disable=SC2016 # a markdown fence, not a command substitution
printf '```json\n{"fenced":true}\n```\n' >"$WORK/fenced.json"
assert_eq "model call: a \`\`\`json fence around the answer is removed" '{"fenced":true}' \
  "$(printf 'x\n' | CLAUDE_STUB_RESPONSE="$WORK/fenced.json" learn_model_call haiku)"
printf 'I could not do that.' >"$WORK/prose.json"
out=$(printf 'x\n' | CLAUDE_STUB_RESPONSE="$WORK/prose.json" learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "model call: an answer that is not JSON exits 2" "2" "$rc"
out=$(printf 'ching-learn-task: skills\n' | CLAUDE_STUB_EXIT=1 learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "model call: a failed call exits 1" "1" "$rc"
out=$(printf 'ching-learn-task: skills\n' | CLAUDE_STUB_SLEEP=5 LEARN_CALL_TIMEOUT=1 learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "model call: a call over LEARN_CALL_TIMEOUT is cut and exits 1" "1" "$rc"
n=$(ncalls)
out=$(printf 'ching-learn-task: skills\n' | LEARN_TOKEN_CAP=1000 learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "model call: daily token cap reached exits 5" "5" "$rc"
assert_eq "model call: capped means no call at all" "$n" "$(ncalls)"
assert_fails "model call: a model name is required" learn_model_call ""
# ---------- learn_model_call: isolation from the owner's settings, hooks and plugins (stage 6a fix F1) ----------
# a wrapper records the argv one per line, so an empty argument and the --settings JSON can be checked exactly
cat >"$WORK/argv-stub" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$@" >"$WORK/argv.txt"
exec "$STUB" "\$@"
EOS
chmod +x "$WORK/argv-stub"
rm -f "$TOKF"
printf 'ching-learn-task: skills\n' | CHING_CLAUDE_BIN="$WORK/argv-stub" learn_model_call haiku >/dev/null
argv=$(cat "$WORK/argv.txt")
assert_contains "isolation: --no-session-persistence" "$argv" "--no-session-persistence"
assert_contains "isolation: --setting-sources \"\" (no user, project or local settings: no user hooks, no plugins)" "$argv" $'--setting-sources\n\n--settings'
assert_contains "isolation: --strict-mcp-config" "$argv" "--strict-mcp-config"
assert_contains "isolation: --disable-slash-commands" "$argv" "--disable-slash-commands"
settings=$(sed -n '/^--settings$/{n;p;}' "$WORK/argv.txt")
assert_eq "isolation: --settings is JSON" "object" "$(jq -r type <<<"$settings")"
assert_eq "isolation: --settings defines only a PreToolUse hook" "PreToolUse" "$(jq -r '.hooks | keys | join(",")' <<<"$settings")"
assert_eq "isolation: ... for every tool, running guard.sh beside lib.sh (learner mode stays the second layer)" \
  "*|$(printf '%q' "$BIN/guard.sh")" "$(jq -r '.hooks.PreToolUse[0] | "\(.matcher)|\(.hooks[0].command)"' <<<"$settings")"
assert_eq "isolation: auto-memory off (no ~/.claude/projects/<.work>/memory)" "false" "$(jq -r .autoMemoryEnabled <<<"$settings")"
# a guard path with a space still runs as one command
lib_sp="$WORK/lib with space"; mkdir -p "$lib_sp"; cp "$BIN"/*.sh "$BIN"/*.pl "$BIN"/*.jq "$lib_sp/" 2>/dev/null
cmd=$( (. "$lib_sp/lib.sh"; printf 'ching-learn-task: skills\n' | CHING_CLAUDE_BIN="$WORK/argv-stub" learn_model_call haiku >/dev/null; \
  sed -n '/^--settings$/{n;p;}' "$WORK/argv.txt" | jq -r '.hooks.PreToolUse[0].hooks[0].command') )
assert_eq "isolation: the guard path is shell-quoted" "$lib_sp/guard.sh" "$(eval "printf '%s' $cmd")"

# ---------- learn_model_call: the cap is checked against an estimate of the call, under a lock (stage 6a fix F1) ----------
rm -f "$TOKF"
assert_eq "budget: learn_budget_left is the cap when nothing is spent" "200000" "$(learn_budget_left)"
printf '150000\n' >"$TOKF"
assert_eq "budget: learn_budget_left is what is left today" "50000" "$(learn_budget_left)"
printf '250000\n' >"$TOKF"
assert_eq "budget: learn_budget_left is never negative" "0" "$(learn_budget_left)"
assert_eq "budget: ... and reads LEARN_TOKEN_CAP" "0" "$(LEARN_TOKEN_CAP=1000 learn_budget_left)"
assert_eq "estimate: 0 bytes is the per-call overhead (default 4000)" "4000" "$(printf '' | learn_estimate_tokens)"
assert_eq "estimate: bytes / 2.4 rounded up, a quarter for the answer, plus the overhead" "4005" "$(printf 'abcdefgh' | learn_estimate_tokens)"
assert_eq "estimate: LEARN_CALL_OVERHEAD" "15" "$(printf 'abcdefgh' | LEARN_CALL_OVERHEAD=10 learn_estimate_tokens)"
assert_eq "estimate: 2400 bytes are 1000 tokens in, 250 for the answer" "5250" "$(head -c 2400 /dev/zero | tr '\0' x | learn_estimate_tokens)"
# a call whose estimate does not fit what is left is refused before it starts (the cap was soft: 219k against 200k)
printf '190000\n' >"$TOKF"; n=$(ncalls)
big=$(head -c 70000 /dev/zero | tr '\0' 'x')   # about 20k tokens
out=$(printf 'ching-learn-task: skills\n%s\n' "$big" | learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "budget: a call that would pass the cap exits 5" "5" "$rc"
assert_eq "budget: ... and no call is made" "$n" "$(ncalls)"
assert_eq "budget: ... and nothing is added to the day" "190000" "$(cat "$TOKF")"
est=$(printf 'ching-learn-task: skills\n%s\n' "$big" | learn_estimate_tokens)
assert_contains "budget: ... logged with the estimate" "$(tail -1 "$P/.work/learn.log")" "rc=capped tokens=0 estimate=$est"
out=$(printf 'ching-learn-task: skills\nsmall\n' | learn_model_call haiku 2>/dev/null); rc=$?
assert_eq "budget: a small call that fits still runs" "0" "$rc"
assert_eq "budget: ... and the day total is the real usage, not the estimate" "191500" "$(cat "$TOKF")"
# the read-modify-write of tokens-<day> is locked: parallel calls lose no tokens
rm -f "$TOKF"
for _ in 1 2 3 4 5 6 7 8; do (printf 'ching-learn-task: skills\n' | learn_model_call haiku >/dev/null 2>&1) & done; wait
assert_eq "budget: 8 parallel calls count 8 x 1500 tokens" "12000" "$(cat "$TOKF")"
# parallel calls cannot all pass one check: each reserves its estimate before it starts
printf '0\n' >"$TOKF"; : >"$WORK/call.log"
for _ in 1 2 3 4 5 6; do (printf 'ching-learn-task: skills\n' | CLAUDE_STUB_SLEEP=3 LEARN_TOKEN_CAP=12000 learn_model_call haiku >/dev/null 2>&1) & done; wait
assert_eq "budget: 6 parallel calls against room for 2 estimates: only 2 run" "2" "$(ncalls)"
assert_eq "budget: ... and the day holds their real usage" "3000" "$(cat "$TOKF")"
# a failed call gives its reservation back (only what the envelope reports is counted)
printf '0\n' >"$TOKF"
printf 'ching-learn-task: skills\n' | CLAUDE_STUB_EXIT=1 learn_model_call haiku >/dev/null 2>&1
assert_eq "budget: a failed call counts what it reported" "1500" "$(cat "$TOKF")"
unset CHING_CLAUDE_BIN CLAUDE_STUB_LOG

# the canned labels speak about the golden prompts (id = <sid>@<ts>)
assert_eq "stub: every classify id is a golden prompt" "" \
  "$(comm -23 <(jq -r '.labels[].id' "$FX/stub/corrections-classify.json" | sort) <(jq -r '"\(.sid)@\(.ts)"' "$FX/work/prompts.jsonl" | sort))"
assert_eq "stub: every golden prompt has a label" "17" "$(jq '.labels | length' "$FX/stub/corrections-classify.json")"

# ---------- no real owner data in the fixtures (they are pushed to GitHub) ----------
assert_eq "fixtures: no /Users/<real user> paths" "" "$(grep -rhoE '/Users/[A-Za-z0-9._-]+' "$FX" | grep -v '^/Users/fixture$' | sort -u)"
assert_eq "fixtures: no -Users-<real user> project dirs" "" "$(find "$PROJ" -mindepth 1 -maxdepth 1 -name '-Users-*' ! -name '-Users-fixture' ! -name '-Users-fixture-*')"
exit 0
