#!/usr/bin/env bash
# t_learn_skills.sh - the skill-candidate miner bin/learn-skills.sh (Phase 6 spec 5.3, 8 "Miner"). The model is
# always the claude stub (tests/fixtures/learn/claude-stub); inputs are the golden .work files and the synthetic
# ones under tests/fixtures/learn/skills/.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
FX="$KIT/tests/fixtures/learn"
SK="$FX/skills"
MINER="$BIN/learn-skills.sh"
export TZ=UTC
export CHING_CLAUDE_BIN="$FX/claude-stub"
export CHING_PLUGINS_FILE="$WORK/no-plugins.json"   # never the real plugin list
unset CHING_SKILL_DIRS LEARN_SKILL_MAX LEARN_MAX_SNIPPETS LEARN_TOKEN_CAP LEARN_MODEL_DRAFT LEARN_DISABLE
GOLDEN_SEQ="git fetch > git rebase > bun test > git push"

# fresh AGENT_HOME per case: setup NAME TOOLSEQ [PROMPTS]
setup() {
  export AGENT_HOME="$WORK/$1/agent"
  export CLAUDE_DIR="$WORK/$1/claude"
  export CLAUDE_STUB_LOG="$WORK/$1/stub.log"
  mkdir -p "$AGENT_HOME/proposals/.work" "$CLAUDE_DIR/skills"
  [ -z "$2" ] || cp "$2" "$AGENT_HOME/proposals/.work/toolseq.jsonl"
  [ -z "${3:-}" ] || cp "$3" "$AGENT_HOME/proposals/.work/prompts.jsonl"
}
run_miner() { "$MINER" "$@" >"$WORK/out" 2>"$WORK/err"; echo $?; }
calls() { if [ -f "$CLAUDE_STUB_LOG" ]; then grep -c '^--- end of call' "$CLAUDE_STUB_LOG"; else echo 0; fi; }
last_run() { grep '"kind":"learn_run"' "$AGENT_HOME/events.jsonl" 2>/dev/null | tail -1 | jq -c '.data'; }
skill_files() { local f; for f in "$AGENT_HOME"/proposals/skill-*.md; do [ -f "$f" ] && printf '%s ' "${f##*/}"; done; }
seqs() { jq -r '.sequence | join(" > ")' "$WORK/out"; }
# seqline SID DAY TOKEN... -> one toolseq line with a prompt before token 0
seqline() {
  local sid=$1 day=$2; shift 2
  jq -nc --arg sid "$sid" --arg day "$day" '{sid:$sid, day:$day, cwd:"/Users/fixture/code/x",
    tokens:$ARGS.positional, prompts:[{i:0, ts:($day + "T12:00:00.000Z")}]}' --args "$@"
}

# ---------- golden fixtures: deterministic stage ----------
setup golden "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
rc=$(run_miner --dry-run)
assert_eq "dry run: exit 0" "0" "$rc"
assert_eq "golden: exactly one candidate (the 4-step sync sequence)" "$GOLDEN_SEQ" "$(seqs)"
assert_eq "golden: 3 sessions on 2 days, length 4" "3 2 4" "$(jq -r '"\(.sessions) \(.days) \(.length)"' "$WORK/out")"
assert_not_contains "golden: the 3-step subsequence with the same sessions is not listed" "$(seqs)" $'\n'
assert_eq "golden: each session carries the prompt that preceded the sequence" \
  "add a dark mode toggle to the settings page|fix the broken RSS feed link in the footer|rename the checkout button to Pay now" \
  "$(jq -r '[.evidence[] | .quote] | sort | join("|")' "$WORK/out")"
assert_eq "dry run: no model call" "0" "$(calls)"
assert_eq "dry run: no learn_run event" "" "$(last_run)"
assert_eq "dry run: no proposal written" "" "$(skill_files)"

# ---------- golden fixtures: full run with the stub ----------
rc=$(run_miner)
assert_eq "run: exit 0" "0" "$rc"
assert_eq "run: one model call" "1" "$(calls)"
log=$(cat "$CLAUDE_STUB_LOG")
assert_contains "run: the draft model is used" "$log" "--model sonnet"
assert_contains "run: tools off, json out" "$log" '--tools  --output-format json'
assert_eq "run: the prompt's first line names the task" "ching-learn-task: skills" "$(sed -n '4p' "$CLAUDE_STUB_LOG")"
assert_contains "run: the prompt holds the candidate" "$log" '"git fetch","git rebase","bun test","git push"'
assert_contains "run: the prompt holds the preceding human prompt" "$log" "fix the broken RSS feed link in the footer"
assert_not_contains "run: a two-step sequence is never sent" "$log" '"npm install","pnpm add"'
assert_eq "run: one skill proposal, named by the model's slug" "skill-sync-test-push.md " "$(skill_files)"
P="$AGENT_HOME/proposals/skill-sync-test-push.md"
assert_eq "proposal: kind skill" "skill" "$(proposal_get "$P" kind)"
assert_eq "proposal: component skills" "skills" "$(proposal_get "$P" component)"
assert_eq "proposal: fingerprint of the token sequence" "$(proposal_fingerprint "$GOLDEN_SEQ")" "$(proposal_get "$P" fingerprint)"
assert_eq "proposal: sessions and days" "3 2" "$(proposal_get "$P" sessions) $(proposal_get "$P" days)"
assert_eq "proposal: target is the proposed skill name" "sync-test-push" "$(proposal_get "$P" target)"
assert_eq "proposal: the draft SKILL.md description, without its description: key" "Bring the branch up to date" \
  "$(proposal_section "$P" proposal | head -1 | cut -c1-27)"
assert_not_contains "proposal: no description: key anywhere" "$(proposal_section "$P" proposal)" "description:"
assert_contains "run: each candidate carries an id" "$log" '"id":"c1"' 
assert_contains "proposal: names the steps seen" "$(proposal_section "$P" proposal)" "$GOLDEN_SEQ"
ev_lines=$(proposal_section "$P" evidence)
assert_eq "proposal: one evidence line per session" "3" "$(printf '%s\n' "$ev_lines" | grep -c '^- ')"
assert_contains "proposal: evidence quotes the preceding prompt" "$ev_lines" '- a2000000 2026-10-12 /Users/fixture/code/blog "fix the broken RSS feed link in the footer"'
assert_contains "proposal: why not covered" "$(proposal_section "$P" 'why this is not already covered')" "commit-commands"
assert_eq "event: learn_run for skills" \
  '{"candidates":1,"component":"skills","outcome":"ok","proposals":1,"scanned":6}' "$(last_run | jq -cS .)"

# a rerun on the same input makes no model call and no second file
rc=$(run_miner)
assert_eq "rerun: exit 0" "0" "$rc"
assert_eq "rerun, same input: no new model call" "1" "$(calls)"
assert_eq "rerun, same input: outcome nothing-new" "nothing-new" "$(last_run | jq -r .outcome)"
assert_eq "rerun: still one file" "skill-sync-test-push.md " "$(skill_files)"
# new data: the call is made again and the open proposal is refreshed, not duplicated
seqline a4000000-0000-4000-8000-00000000a004 2026-10-14 "git fetch" "git rebase" "bun test" "git push" >>"$AGENT_HOME/proposals/.work/toolseq.jsonl"
rc=$(run_miner)
assert_eq "new data: a second model call" "2" "$(calls)"
assert_eq "new data: still one file" "skill-sync-test-push.md " "$(skill_files)"
assert_eq "new data: counts refreshed" "4 3" "$(proposal_get "$P" sessions) $(proposal_get "$P" days)"
assert_eq "new data: a refreshed proposal is not counted as new" "0" "$(last_run | jq -r .proposals)"

# ---------- no candidates: no model call ----------
setup none "" ""
grep '"sid":"b' "$FX/work/toolseq.jsonl" >"$AGENT_HOME/proposals/.work/toolseq.jsonl"
rc=$(run_miner)
assert_eq "no candidates: exit 0" "0" "$rc"
assert_eq "no candidates: no model call" "0" "$(calls)"
assert_eq "no candidates: event" '{"candidates":0,"component":"skills","outcome":"nothing-new","proposals":0,"scanned":3}' "$(last_run | jq -cS .)"
setup missing "" ""
rc=$(run_miner)
assert_eq "no toolseq file: exit 0" "0" "$rc"
assert_eq "no toolseq file: no call, scanned 0" "0 0 nothing-new" "$(calls) $(last_run | jq -r '"\(.scanned) \(.outcome)"')"

# ---------- the deterministic bar ----------
setup bar "" ""
TS="$AGENT_HOME/proposals/.work/toolseq.jsonl"
{ seqline s1 2026-10-01 a b c; seqline s2 2026-10-01 a b c; seqline s3 2026-10-01 a b c; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: 3 sessions on 1 day is not a candidate" "" "$(seqs)"
{ seqline s1 2026-10-01 a b c; seqline s2 2026-10-02 a b c; seqline s3 2026-10-02 x y z; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: 2 sessions on 2 days is not a candidate" "" "$(seqs)"
{ seqline s1 2026-10-01 a b c; seqline s2 2026-10-02 a b c; seqline s3 2026-10-02 a b c; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: 3 sessions on 2 days is a candidate" "a > b > c" "$(seqs)"
{ seqline s1 2026-10-01 a b; seqline s2 2026-10-02 a b; seqline s3 2026-10-03 a b; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: 2 steps is too short" "" "$(seqs)"
{ seqline s1 2026-10-01 a b a b a b a; seqline s2 2026-10-02 a b a b a b a; seqline s3 2026-10-03 a b a b a b a; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: at most 6 steps (a 7-step repeat gives its two 6-step windows)" "a > b > a > b > a > b|b > a > b > a > b > a" "$(seqs | sort | paste -sd '|' -)"
{ seqline s1 2026-10-01 Read Grep Edit Write; seqline s2 2026-10-02 Read Grep Edit Write; seqline s3 2026-10-03 Read Grep Edit Write; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: a pure Read/Edit/Grep/Glob/Write sequence is dropped" "" "$(seqs)"
{ seqline s1 2026-10-01 Read Edit "bun test"; seqline s2 2026-10-02 Read Edit "bun test"; seqline s3 2026-10-03 Read Edit "bun test"; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "bar: Read/Edit plus a command is kept" "Read > Edit > bun test" "$(seqs)"
printf 'not json\n{"sid":"broken"\n' >>"$TS"
rc=$(run_miner --dry-run)
assert_eq "bar: malformed toolseq lines are skipped" "0 Read > Edit > bun test" "$rc $(seqs)"

# maximal: a subsequence with the same session set is folded into the longer one; with another set it stays
{ seqline s1 2026-10-01 a b c d; seqline s2 2026-10-02 a b c d; seqline s3 2026-10-02 a b c d; seqline s4 2026-10-03 a b c; } >"$TS"
run_miner --dry-run >/dev/null
assert_eq "maximal: b > c > d (same sessions as a > b > c > d) is not listed; a > b > c (one more session) is" \
  "a > b > c|a > b > c > d" "$(seqs | sort | paste -sd '|' -)"

# ---------- installed skills ----------
setup installed "" ""
TS="$AGENT_HOME/proposals/.work/toolseq.jsonl"
for s in 1 2 3; do seqline "s$s" "2026-10-0$s" "Skill:deploy-check" "bun test" "git push"; done >"$TS"
for s in 4 5 6; do seqline "s$s" "2026-10-0$s" "Skill:myplug:ship-it" "git tag" "git push"; done >>"$TS"
run_miner --dry-run >/dev/null
assert_eq "skills: sequences with skills nobody installed are candidates" "2" "$(seqs | grep -c .)"
mkdir -p "$CLAUDE_DIR/skills/deploy-check"
printf -- '---\nname: deploy-check\ndescription: Check a deploy.\n---\n' >"$CLAUDE_DIR/skills/deploy-check/SKILL.md"
run_miner --dry-run >/dev/null
assert_eq "skills: a sequence using an installed skill (~/.claude/skills) is dropped" "Skill:myplug:ship-it > git tag > git push" "$(seqs)"
mkdir -p "$WORK/plug/skills/ship-it"
printf -- '---\nname: ship-it\ndescription: |\n  Ship it.\n---\n' >"$WORK/plug/skills/ship-it/SKILL.md"
jq -n --arg p "$WORK/plug" '{version:2, plugins:{"myplug@market":[{scope:"user", installPath:$p}]}}' >"$WORK/plugins.json"
CHING_PLUGINS_FILE="$WORK/plugins.json" run_miner --dry-run >/dev/null
assert_eq "skills: a sequence using an installed plugin skill is dropped" "" "$(seqs)"
CHING_SKILL_DIRS="$WORK/elsewhere" CHING_PLUGINS_FILE="$WORK/plugins.json" run_miner --dry-run >/dev/null
assert_eq "skills: CHING_SKILL_DIRS replaces the skill directories" "Skill:deploy-check > bun test > git push" "$(seqs)"

# ---------- ranking, the shortlist and LEARN_SKILL_MAX ----------
setup cap "$SK/toolseq.jsonl" "$SK/prompts.jsonl"
run_miner --dry-run >/dev/null
assert_eq "rank: sessions x length, then days" \
  "gh pr view > gh pr diff > Read > bun test > gh pr review > gh pr merge|supabase db > supabase migration > bun test > git add > git commit|wrangler build > wrangler deploy > mcp__probe__health > git tag|pandoc notes.md > Write > open notes.pdf|sqlite3 data.db > jq . > Write" \
  "$(seqs | paste -sd '|' -)"
assert_eq "rank: score shown" "30 20 12 9 9" "$(jq -r .score "$WORK/out" | paste -sd ' ' -)"
rc=$(CLAUDE_STUB_RESPONSE="$SK/answer-all.json" run_miner)
assert_eq "cap: exit 0" "0" "$rc"
assert_eq "cap: at most LEARN_SKILL_MAX (3) files, the best-ranked kept ones" \
  "skill-apply-migration.md skill-deploy-and-tag.md skill-review-and-merge-pr.md " "$(skill_files)"
assert_eq "cap: event" '{"candidates":5,"component":"skills","outcome":"ok","proposals":3,"scanned":5}' "$(last_run | jq -cS .)"
assert_not_contains "cap: a sequence the model made up is never written" "$(cat "$AGENT_HOME"/proposals/*.md)" "made up"
assert_contains "cap: evidence of the 5-session candidate holds its prompt" \
  "$(proposal_section "$AGENT_HOME/proposals/skill-review-and-merge-pr.md" evidence)" "review the open pull request and merge it if the tests pass"
setup cap1 "$SK/toolseq.jsonl" "$SK/prompts.jsonl"
LEARN_SKILL_MAX=1 CLAUDE_STUB_RESPONSE="$SK/answer-all.json" run_miner >/dev/null
assert_eq "cap: LEARN_SKILL_MAX=1 gives one file" "skill-review-and-merge-pr.md " "$(skill_files)"
setup cap0 "$SK/toolseq.jsonl" "$SK/prompts.jsonl"
LEARN_SKILL_MAX=0 run_miner >/dev/null
assert_eq "cap: LEARN_SKILL_MAX=0 makes no call" "0 disabled" "$(calls) $(last_run | jq -r .outcome)"

# snippets: LEARN_MAX_SNIPPETS caps the prompts sent (each fixture candidate has one distinct prompt); hitting it is
# logged as truncated
setup trunc "$SK/toolseq.jsonl" "$SK/prompts.jsonl"
LEARN_MAX_SNIPPETS=1 CLAUDE_STUB_RESPONSE="$SK/answer-all.json" run_miner >/dev/null
assert_eq "truncated: outcome" "truncated" "$(last_run | jq -r .outcome)"
assert_contains "truncated: the top candidate is sent" "$(cat "$CLAUDE_STUB_LOG")" '"gh pr view","gh pr diff"'
assert_not_contains "truncated: candidates past the cap are not sent" "$(cat "$CLAUDE_STUB_LOG")" '"wrangler build"'
assert_eq "truncated: only sent candidates become proposals" "skill-review-and-merge-pr.md " "$(skill_files)"

# ---------- what the model's answer may not do ----------
setup answer "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
mkdir -p "$CLAUDE_DIR/skills/sync-test-push"
printf -- '---\nname: sync-test-push\ndescription: x\n---\n' >"$CLAUDE_DIR/skills/sync-test-push/SKILL.md"
run_miner >/dev/null
assert_eq "answer: a drafted name that is already an installed skill is dropped" "" "$(skill_files)"
assert_contains "answer: the installed skill list is in the prompt" "$(cat "$CLAUDE_STUB_LOG")" '{"name":"sync-test-push","description":"x"}'
setup answer2 "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
jq '.skills[0].keep = false | .skills[0].reason = "a habit"' "$FX/stub/skills.json" >"$WORK/keepfalse.json"
CLAUDE_STUB_RESPONSE="$WORK/keepfalse.json" run_miner >/dev/null
assert_eq "answer: keep false writes nothing" "" "$(skill_files)"
assert_eq "answer: keep false still ok" "ok 0" "$(last_run | jq -r '"\(.outcome) \(.proposals)"')"
setup answer3 "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
jq '.skills[0].slug = "../../Evil Name!!" | .skills[0].name = "Evil Name!!"' "$FX/stub/skills.json" >"$WORK/badslug.json"
CLAUDE_STUB_RESPONSE="$WORK/badslug.json" run_miner >/dev/null
assert_eq "answer: a hostile slug is made safe" "skill-evil-name.md " "$(skill_files)"
assert_eq "answer: and so is the target name" "evil-name" "$(proposal_get "$AGENT_HOME/proposals/skill-evil-name.md" target)"
setup answer4 "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
printf '{"rules":[]}' >"$WORK/noskills.json"
rc=$(CLAUDE_STUB_RESPONSE="$WORK/noskills.json" run_miner)
assert_eq "answer: no skills array is an error" "1 error" "$rc $(last_run | jq -r .outcome)"
# the slug is taken by a proposal with another fingerprint: the next free one is used
setup collide "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
printf '{"component":"skills","fingerprint":"%s","sessions":3,"days":2,"target":"other","proposal":"p","evidence":[],"why_not_covered":"w"}' \
  "$(proposal_fingerprint other)" | proposal_write skill-sync-test-push.md >/dev/null
run_miner >/dev/null
assert_eq "collide: the next free slug is used" "skill-sync-test-push-2.md skill-sync-test-push.md " "$(skill_files)"

# a drafted SKILL.md with front matter: only the description is kept
setup frontmatter "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
jq '.skills[0].proposal = "---\nname: sync-test-push\ndescription: \"Sync, test and push. Use when shipping.\"\n---\n"' "$FX/stub/skills.json" >"$WORK/fm.json"
CLAUDE_STUB_RESPONSE="$WORK/fm.json" run_miner >/dev/null
P="$AGENT_HOME/proposals/skill-sync-test-push.md"
assert_eq "front matter: the description only" "Sync, test and push. Use when shipping." "$(proposal_section "$P" proposal | head -1)"
assert_not_contains "front matter: no --- or name:" "$(proposal_section "$P" proposal)" "name:"
setup fmblock "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
jq '.skills[0].proposal = "---\nname: sync-test-push\ndescription: >\n  Sync, test\n  and push.\n---\n\nUse when shipping."' "$FX/stub/skills.json" >"$WORK/fmb.json"
CLAUDE_STUB_RESPONSE="$WORK/fmb.json" run_miner >/dev/null
P="$AGENT_HOME/proposals/skill-sync-test-push.md"
assert_eq "front matter: a folded description, then the body" "Sync, test and push.|Use when shipping." \
  "$(proposal_section "$P" proposal | grep . | head -2 | paste -sd '|' -)"

# ---------- a candidate with a redactable token: the model sees it redacted, and its answer still matches ----------
SECRET="sk-""$(printf 'a%.0s' $(seq 1 24))"
setup redact "" ""
for s in 1 2 3; do seqline "r$s" "2026-10-0$s" "deploy $SECRET" "bun test" "git push"; done >"$AGENT_HOME/proposals/.work/toolseq.jsonl"
jq -n '{skills: [{sequence: ["deploy [REDACTED]", "bun test", "git push"], keep: true, slug: "deploy-test-push", name: "deploy-test-push",
  proposal: "Deploy, test and push. Use when shipping.", why_not_covered: "none covers it"}]}' >"$WORK/redacted.json"
CLAUDE_STUB_RESPONSE="$WORK/redacted.json" run_miner >/dev/null
assert_not_contains "redact: the model never sees the token" "$(cat "$CLAUDE_STUB_LOG")" "$SECRET"
assert_eq "redact: the answer, on the redacted sequence, is matched" "skill-deploy-test-push.md " "$(skill_files)"
assert_eq "redact: the fingerprint is still the raw sequence's" "$(proposal_fingerprint "deploy $SECRET > bun test > git push")" \
  "$(proposal_get "$AGENT_HOME/proposals/skill-deploy-test-push.md" fingerprint)"
assert_not_contains "redact: the proposal file holds no token" "$(cat "$AGENT_HOME/proposals/skill-deploy-test-push.md")" "$SECRET"
setup byid "" ""
for s in 1 2 3; do seqline "r$s" "2026-10-0$s" "deploy $SECRET" "bun test" "git push"; done >"$AGENT_HOME/proposals/.work/toolseq.jsonl"
jq -n '{skills: [{id: "c1", sequence: ["deploy", "(the model shortened it)"], keep: true, slug: "deploy-by-id", name: "deploy-by-id",
  proposal: "Deploy. Use when shipping.", why_not_covered: "none"}, {id: "c9", sequence: ["x", "y", "z"], keep: true, slug: "no-such", name: "no-such",
  proposal: "p", why_not_covered: "w"}]}' >"$WORK/byid.json"
CLAUDE_STUB_RESPONSE="$WORK/byid.json" run_miner >/dev/null
assert_eq "id: an answer is matched on its id; an id that was not sent is ignored" "skill-deploy-by-id.md " "$(skill_files)"

# ---------- files under .work are private whatever the caller's umask ----------
setup perms "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
(umask 022; CLAUDE_STUB_EXIT=1 "$MINER" >/dev/null 2>&1)
assert_file "perms: learn.log written" "$AGENT_HOME/proposals/.work/learn.log"
assert_eq "perms: every .work file the miner wrote is 0600" "" \
  "$(find "$AGENT_HOME/proposals/.work" -type f ! -perm 600 ! -name prompts.jsonl ! -name toolseq.jsonl)"

# ---------- decided fingerprints are not sent again ----------
setup rejected "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
printf '%s owner said no\n' "$(proposal_fingerprint "$GOLDEN_SEQ")" >"$AGENT_HOME/proposals/rejected.txt"
rc=$(run_miner)
assert_eq "rejected: exit 0" "0" "$rc"
assert_eq "rejected: no model call when the only candidate was rejected" "0" "$(calls)"
assert_eq "rejected: nothing-new" "nothing-new" "$(last_run | jq -r .outcome)"
assert_eq "rejected: no file" "" "$(skill_files)"

# ---------- model failures fail quiet ----------
setup fail "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
rc=$(CLAUDE_STUB_EXIT=1 run_miner)
assert_eq "failed call: exit 1, outcome error" "1 error" "$rc $(last_run | jq -r .outcome)"
assert_eq "failed call: no file" "" "$(skill_files)"
rc=$(run_miner)
assert_eq "after a failed call, the next run calls again" "0 ok" "$rc $(last_run | jq -r .outcome)"
setup capped "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
echo 500 >"$AGENT_HOME/proposals/.work/tokens-$(date +%Y-%m-%d)"
rc=$(LEARN_TOKEN_CAP=100 run_miner)
assert_eq "capped: exit 0, outcome capped, no call" "0 capped 0" "$rc $(last_run | jq -r .outcome) $(calls)"
setup notjson "$FX/work/toolseq.jsonl" "$FX/work/prompts.jsonl"
printf 'I could not find any skills.' >"$WORK/prose.txt"
rc=$(CLAUDE_STUB_RESPONSE="$WORK/prose.txt" run_miner)
assert_eq "prose answer: outcome error" "1 error" "$rc $(last_run | jq -r .outcome)"

# ---------- usage ----------
rc=$(run_miner --bogus)
assert_eq "unknown flag: exit 64" "64" "$rc"
rc=$(run_miner --help)
assert_eq "help: exit 0" "0" "$rc"
assert_contains "help: usage text" "$(cat "$WORK/out")" "learn-skills.sh"
exit 0
