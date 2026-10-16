#!/usr/bin/env bash
# t_learn_corrections.sh - the correction detector bin/learn-corrections.sh (Phase 6 spec 5.2 and 8 "Corrections")
# and the evaluation runner bin/learn-eval.sh, against the claude stub and synthetic fixtures only.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
FX="$KIT/tests/fixtures/learn"
CFX="$FX/corrections"
LC="$BIN/learn-corrections.sh"
export TZ=UTC
export CHING_CLAUDE_BIN="$FX/claude-stub"
export CHING_GH_BIN="$WORK/no-such-gh"   # no test reaches the real gh
VERSION_FP=$(proposal_fingerprint "do not bump the version number; the owner releases by hand")
DATES_FP=$(proposal_fingerprint "write dates as YYYY-MM-DD")

# fresh NAME: a new AGENT_HOME with the golden prompts in .work, the fixture global rules at ~/.agents/CLAUDE.md
fresh() {
  export AGENT_HOME="$WORK/$1/agent"
  export CLAUDE_STUB_LOG="$WORK/$1/stub.log"
  mkdir -p "$AGENT_HOME/proposals/.work" "$HOME/.agents"
  chmod 700 "$AGENT_HOME/proposals" "$AGENT_HOME/proposals/.work"
  cp "$FX/work/prompts.jsonl" "$AGENT_HOME/proposals/.work/prompts.jsonl"
  cp "$FX/agents-CLAUDE.md" "$HOME/.agents/CLAUDE.md"
  : >"$CLAUDE_STUB_LOG"
  P="$AGENT_HOME/proposals"
}
last_run() { grep '"kind":"learn_run"' "$AGENT_HOME/events.jsonl" | tail -n 1 | jq -c .data; }
run_field() { last_run | jq -r ".$1"; }
calls() { grep -c '^ARGS:' "$CLAUDE_STUB_LOG" || true; }
rules() { find "$P" -maxdepth 1 -name 'rule-*.md' | sort; }
nrules() { rules | grep -c . || true; }
# the prompt of the stub call for TASK
call_prompt() { awk -v t="ching-learn-task: $1" '$0 == t { on = 1 } on && /^--- end of call$/ { exit } on' "$CLAUDE_STUB_LOG"; }

# ---------- stage 1 (--stage1 filter) ----------
s1() { jq -nc --arg t "$1" --argjson a "${2:-false}" '{text: $t, after_interrupt: $a}' | "$LC" --stage1 | jq -c .stage1_hits; }
s1_hit()  { local h; h=$(s1 "$2" "${3:-false}"); if [ "$h" != "[]" ]; then pass "stage 1 hit: $1"; else fail "stage 1 hit: $1" "  no cue for: $2"; fi; }
s1_miss() { local h; h=$(s1 "$2"); assert_eq "stage 1 miss: $1" "[]" "$h"; }
s1_hit "leading no" "no, don't bump the version"
s1_hit "stop" "stop using npm here"
s1_hit "actually" "actually leave the version alone"
s1_hit "yourself" "run it yourself"
s1_hit "do it: from here" "the token is in .env.local, run the migration from here"
s1_hit "do it: for me" "can you not leave this for me every time"
s1_hit "do it: why do I have to" "why do I have to apply it by hand"
s1_hit "do it: you should be able to" "you should be able to apply the migration"
s1_hit "do it: don't ask" "go on and finish, don't ask"
s1_hit "do it: without asking" "push the fix without asking me first"
s1_hit "merged + main" "is everything merged into main now"
s1_hit "merging + main" "when merging to main keep both sides"
s1_hit "previous session" "the previous session already set that up"
s1_hit "curly apostrophe" "don’t touch the lockfile"
s1_hit "after an interrupt, whatever the text" "also add the feed to the sitemap" true
long=$(printf 'plan the next release step by step. %.0s' $(seq 1 15))
s1_hit "a cue after the first 400 characters" "${long}and merge to main without losing work"
s1_miss "a plain request" "add a dark mode toggle to the settings page"
s1_miss "no worries" "no worries, thanks for the summary"
s1_miss "nothing to correct" "rename the checkout button to Pay now"
assert_eq "stage 1: hits are named per cue" '["no_start","dont"]' "$(s1 "no, don't bump the version number")"
assert_eq "stage 1: keeps the other fields" '"x1"' "$(jq -nc '{id: "x1", text: "stop"}' | "$LC" --stage1 | jq -c .id)"
assert_eq "stage 1: a malformed line is skipped" "1" "$(printf 'not json\n{"text":"stop"}\n' | "$LC" --stage1 | grep -c .)"
assert_fails "usage: unknown flag" "$LC" --nope

# ---------- golden run: version 3 sessions/2 days -> one rule; pnpm 3 sessions/1 day -> none; dates covered ----------
fresh golden
out=$("$LC" 2>&1); rc=$?
assert_eq "golden: exit 0" "0" "$rc"
assert_eq "golden: prints nothing" "" "$out"
assert_eq "golden: exactly one rule proposal" "$P/rule-no-version-bump.md" "$(rules)"
F="$P/rule-no-version-bump.md"
assert_eq "golden: kind rule" "rule" "$(proposal_get "$F" kind)"
assert_eq "golden: component" "corrections" "$(proposal_get "$F" component)"
assert_eq "golden: fingerprint of the normalised pattern" "$VERSION_FP" "$(proposal_get "$F" fingerprint)"
assert_eq "golden: 3 sessions" "3" "$(proposal_get "$F" sessions)"
assert_eq "golden: 2 days" "2" "$(proposal_get "$F" days)"
# shellcheck disable=SC2088 # the literal target text
assert_eq "golden: two places -> the global target" "~/.agents/CLAUDE.md" "$(proposal_get "$F" target)"
evid=$(proposal_section "$F" evidence)
assert_eq "golden: one evidence line per session" "3" "$(printf '%s\n' "$evid" | grep -c '^- ')"
assert_contains "golden: evidence quotes the owner" "$evid" 'a2000000 2026-10-12 /Users/fixture/code/blog "stop bumping the version in package.json, releases are manual"'
assert_contains "golden: evidence from day two" "$evid" "a3000000 2026-10-13"
assert_contains "golden: proposal text from the draft" "$(proposal_section "$F" proposal)" "never bump the version number"
mkdir -p "$WORK/golden/apply"; cp "$FX/agents-CLAUDE.md" "$WORK/golden/apply/CLAUDE.md"
assert_ok "golden: the patch applies to the global rules file" patch -p1 -s --dry-run -d "$WORK/golden/apply" -i "$(proposal_patch "$F" >"$WORK/golden/p.diff"; echo "$WORK/golden/p.diff")"
assert_eq "golden: no pnpm proposal (one day only)" "" "$(grep -l pnpm "$P"/*.md 2>/dev/null)"
assert_eq "golden: no dates proposal (covered)" "" "$(grep -l "$DATES_FP" "$P"/*.md 2>/dev/null)"
assert_eq "golden: learn_run" '{"component":"corrections","scanned":17,"candidates":10,"proposals":1,"outcome":"ok","covered":1}' "$(last_run)"
assert_eq "golden: two model calls" "2" "$(calls)"
assert_contains "golden: classify uses LEARN_MODEL_CLASSIFY" "$(grep '^ARGS:' "$CLAUDE_STUB_LOG" | head -n 1)" "--model haiku"
assert_contains "golden: draft uses LEARN_MODEL_DRAFT" "$(grep '^ARGS:' "$CLAUDE_STUB_LOG" | tail -n 1)" "--model sonnet"
cp_=$(call_prompt corrections-classify)
assert_contains "golden: stage-1 hits go to the classifier" "$cp_" "stop bumping the version in package.json"
assert_contains "golden: prompts after an interrupt go too" "$cp_" "also add the feed to the sitemap"
assert_not_contains "golden: stage-1 misses do not" "$cp_" "add a dark mode toggle"
assert_contains "golden: labelling policy in the prompt (product feedback)" "$cp_" "feedback on the product being built"
assert_contains "golden: labelling policy (previous session context)" "$cp_" "previous session's context"
assert_not_contains "golden: no unfilled placeholder" "$cp_" "{{"
dp=$(call_prompt corrections-draft)
assert_contains "golden: draft sees the global rules" "$dp" "Write dates as YYYY-MM-DD."
assert_contains "golden: draft gets the version cluster" "$dp" '"pattern":"do not bump the version number; the owner releases by hand"'
assert_contains "golden: draft gets the dates cluster" "$dp" '"pattern":"write dates as YYYY-MM-DD"'
assert_not_contains "golden: the one-day pnpm cluster is not drafted" "$dp" "pnpm, not npm\""
assert_eq "golden: every prompt is in the label cache" "17" "$(grep -c . "$P/.work/corrections-labels.jsonl")"
assert_eq "golden: cache files are private" "600" "$(stat -f %Lp "$P/.work/corrections-labels.jsonl" 2>/dev/null || stat -c %a "$P/.work/corrections-labels.jsonl")"
assert_contains "golden: covered is logged" "$(cat "$P/.work/learn.log")" "covered: write dates as YYYY-MM-DD"

# ---------- a second run: nothing new, no model call, still one file ----------
"$LC"
assert_eq "rerun: still one rule file" "1" "$(nrules)"
assert_eq "rerun: no model call" "2" "$(calls)"
assert_eq "rerun: nothing-new" '{"component":"corrections","scanned":0,"candidates":0,"proposals":0,"outcome":"nothing-new","covered":0}' "$(last_run)"

# ---------- a new prompt repeats the pattern: the open proposal is refreshed, not duplicated ----------
cat "$CFX/prompts-extra.jsonl" >>"$P/.work/prompts.jsonl"
CLAUDE_STUB_RESPONSE="$CFX/classify-extra.json" "$LC"
assert_eq "refresh: still one rule file" "$P/rule-no-version-bump.md" "$(rules)"
assert_eq "refresh: 4 sessions" "4" "$(proposal_get "$F" sessions)"
assert_eq "refresh: 3 days" "3" "$(proposal_get "$F" days)"
assert_contains "refresh: the new evidence is in" "$(proposal_section "$F" evidence)" "c1000000 2026-10-15"
assert_eq "refresh: one more call (classify only; covered and open clusters need no draft)" "3" "$(calls)"
assert_eq "refresh: learn_run" '{"component":"corrections","scanned":1,"candidates":1,"proposals":0,"outcome":"ok","covered":1}' "$(last_run)"
assert_contains "refresh: known patterns go to the classifier" "$(tail -n 40 "$CLAUDE_STUB_LOG")" "use pnpm, not npm"

# ---------- a rejected fingerprint is never proposed again ----------
fresh rejected
printf '%s owner said no\n' "$VERSION_FP" >"$P/rejected.txt"
"$LC"
assert_eq "rejected: no rule file" "0" "$(nrules)"
assert_not_contains "rejected: not even drafted" "$(call_prompt corrections-draft)" "bump the version"
assert_eq "rejected: learn_run" '{"component":"corrections","scanned":17,"candidates":10,"proposals":0,"outcome":"ok","covered":1}' "$(last_run)"
# an archived approved one blocks too
fresh approved
mkdir -p "$P/archive"; sed 's/^status: open$/status: approved/' "$KIT/templates/PROPOSAL.md" >"$P/archive/rule-no-version-bump.md"
"$LC"
assert_eq "approved in archive: no new rule file" "0" "$(nrules)"

# ---------- no prompts, failures, cap, truncation ----------
fresh empty
rm "$P/.work/prompts.jsonl"
"$LC"; rc=$?
assert_eq "no prompts file: exit 0" "0" "$rc"
assert_eq "no prompts file: no model call" "0" "$(calls)"
assert_eq "no prompts file: nothing-new" "nothing-new" "$(run_field outcome)"
assert_eq "no prompts file: no proposal" "0" "$(nrules)"

fresh capped
printf '500\n' >"$P/.work/tokens-$(date +%Y-%m-%d)"
LEARN_TOKEN_CAP=100 "$LC"; rc=$?
assert_eq "capped: exit 0" "0" "$rc"
assert_eq "capped: outcome" "capped" "$(run_field outcome)"
assert_eq "capped: no call made" "0" "$(calls)"
assert_eq "capped: only stage-1 misses are cached" "7" "$(grep -c . "$P/.work/corrections-labels.jsonl")"
"$LC"
assert_eq "capped: the next run sends the hits again" "10" "$(run_field candidates)"
assert_eq "capped: and proposes" "1" "$(nrules)"

fresh failed
CLAUDE_STUB_EXIT=1 "$LC"; rc=$?
assert_eq "failed call: exit 0" "0" "$rc"
assert_eq "failed call: outcome error" "error" "$(run_field outcome)"
assert_eq "failed call: no proposal" "0" "$(nrules)"

fresh truncated
LEARN_MAX_SNIPPETS=4 "$LC"
assert_eq "truncated: outcome" "truncated" "$(run_field outcome)"
assert_eq "truncated: 4 sent" "4" "$(run_field candidates)"
assert_eq "truncated: the rest is not cached" "11" "$(grep -c . "$P/.work/corrections-labels.jsonl")"
LEARN_MAX_SNIPPETS=4 "$LC"
assert_eq "truncated: the next run sends the next 4" "4" "$(run_field candidates)"
assert_eq "truncated: scanned counts what was not cached" "6" "$(run_field scanned)"

# ---------- a draft patch that does not apply is dropped ----------
fresh badpatch
printf '# Other rules\n\nNothing about dates here.\n' >"$HOME/.agents/CLAUDE.md"
"$LC"
assert_eq "bad patch: no rule file" "0" "$(nrules)"
assert_contains "bad patch: logged" "$(cat "$P/.work/learn.log")" "does not apply"
cp "$FX/agents-CLAUDE.md" "$HOME/.agents/CLAUDE.md"

# ---------- CHING_GLOBAL_RULES overrides the global file ----------
fresh override
mkdir -p "$WORK/override/rules"; cp "$FX/agents-CLAUDE.md" "$WORK/override/rules/CLAUDE.md"
printf '# not this one\n' >"$HOME/.agents/CLAUDE.md"
CHING_GLOBAL_RULES="$WORK/override/rules/CLAUDE.md" "$LC"
assert_eq "override: target is that file" "$WORK/override/rules/CLAUDE.md" "$(proposal_get "$P/rule-no-version-bump.md" target)"
assert_contains "override: draft sees it" "$(call_prompt corrections-draft)" "Write dates as YYYY-MM-DD."
cp "$FX/agents-CLAUDE.md" "$HOME/.agents/CLAUDE.md"

# ---------- slug taken by another fingerprint: the next free slug ----------
fresh slug
sed "s/^fingerprint: .*/fingerprint: $(proposal_fingerprint something else)/" "$KIT/templates/PROPOSAL.md" >"$P/rule-no-version-bump.md"
"$LC"
assert_file "slug taken: written as -2" "$P/rule-no-version-bump-2.md"
assert_eq "slug taken: -2 has our fingerprint" "$VERSION_FP" "$(proposal_get "$P/rule-no-version-bump-2.md" fingerprint)"

# ---------- one repo (worktrees and subfolders included) -> that repo's AGENTS.md ----------
REPO=$(mk_repo repo-one)
printf '# repo-one\n\n## Rules\nKeep commits small.\n' >"$REPO/AGENTS.md"
git -C "$REPO" add AGENTS.md; git -C "$REPO" commit -q -m agents
mkdir -p "$REPO/src"
git -C "$REPO" worktree add -q "$WORK/repo-one-wt" -b wt 2>/dev/null
REPO=$(cd "$REPO" && pwd -P); WT=$(cd "$WORK/repo-one-wt" && pwd -P)
repo_run() { # name [env...]
  fresh "$1"; shift
  sed -e "s#@REPO@#$REPO#g" -e "s#@WT@#$WT#g" "$CFX/repo-prompts.jsonl" >"$P/.work/prompts.jsonl"
  env CLAUDE_STUB_DIR="$CFX/repo" "$@" "$LC"
  R="$P/rule-run-migrations-yourself.md"
}
repo_run repo
assert_file "one repo: proposal written" "$R"
assert_eq "one repo: target is the repo AGENTS.md" "$REPO/AGENTS.md" "$(proposal_get "$R" target)"
assert_contains "one repo: draft sees the repo AGENTS.md" "$(call_prompt corrections-draft)" "Keep commits small."
assert_contains "one repo: draft is told the patch paths" "$(call_prompt corrections-draft)" "(patch paths a/AGENTS.md and b/AGENTS.md)"
assert_ok "one repo: the patch applies from the repo" bash -c "cd '$REPO' && patch -p1 -s --dry-run -i <(. '$BIN/lib.sh'; proposal_patch '$R')"
assert_not_contains "one repo: a private repo gets no public note" "$(proposal_section "$R" proposal)" "public"
repo_run listed LEARN_PUBLIC_REPOS="other, repo-one"
assert_contains "public (listed): said in the first sentence" "$(proposal_section "$R" proposal | head -c 120)" "The target repo repo-one is public"
cat >"$WORK/fake-gh" <<'EOS'
#!/usr/bin/env bash
[ "$*" = "repo view fixture/repo-one --json visibility --jq .visibility" ] && echo PUBLIC
EOS
chmod +x "$WORK/fake-gh"
git -C "$REPO" remote add pub https://github.com/fixture/repo-one.git
repo_run gh CHING_GH_BIN="$WORK/fake-gh"
assert_contains "public (github remote): said in the first sentence" "$(proposal_section "$R" proposal | head -c 140)" "has a public remote (github.com/fixture/repo-one)"
git -C "$REPO" remote remove pub

# ---------- learn-eval.sh ----------
EV="$BIN/learn-eval.sh"
out=$("$EV" --labels "$CFX/labels.jsonl" 2>&1); rc=$?
assert_eq "eval: exit 0" "0" "$rc"
assert_contains "eval: counts" "$out" "(8 items, 4 corrections)"
assert_contains "eval: stage-1 recall and precision" "$out" "stage 1: 5 hits; recall 3/4 = 75.0%; precision 3/5 = 60.0%"
assert_contains "eval: per-cue line" "$out" "after_interrupt"
assert_not_contains "eval: no misses unless asked" "$out" "e03"
assert_contains "eval: --misses lists the missed correction" "$("$EV" --labels "$CFX/labels.jsonl" --misses)" "e03  please write the tests first next time"
assert_fails "eval: unreadable labels file" "$EV" --labels "$WORK/none.jsonl"
assert_fails "eval: unknown flag" "$EV" --nope
fresh eval
out=$(CLAUDE_STUB_RESPONSE="$CFX/eval-classify.json" "$EV" --labels "$CFX/labels.jsonl" --stage2 2>&1); rc=$?
assert_eq "eval stage 2: exit 0" "0" "$rc"
assert_contains "eval stage 2: what was sent" "$out" "5 sent, 3 of them corrections, 3 labelled correction"
assert_contains "eval stage 2: precision and recall" "$out" "precision 2/3 = 66.7%; recall 2/3 = 66.7%"
assert_contains "eval stage 2: end to end" "$out" "end to end: recall 2/4 = 50.0%"
assert_contains "eval stage 2: the classify task and template" "$(cat "$CLAUDE_STUB_LOG")" "ching-learn-task: corrections-classify"
assert_not_contains "eval stage 2: stage-1 misses are not sent" "$(cat "$CLAUDE_STUB_LOG")" "write the tests first"
assert_eq "eval stage 2: no proposal and no label cache" "0 no" "$(nrules) $([ -e "$P/.work/corrections-labels.jsonl" ] && echo yes || echo no)"
out=$(CLAUDE_STUB_EXIT=1 "$EV" --labels "$CFX/labels.jsonl" --stage2 2>&1); rc=$?
assert_eq "eval stage 2: a failed call exits 1" "1" "$rc"
exit 0
