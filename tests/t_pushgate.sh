#!/usr/bin/env bash
# The push gate switch (owner decision: "guard on, push rule off"). push_gate=on|off in $AGENT_HOME/config (lib.sh
# push_gate_on): OFF by default, and then a plain push or merge to main/default needs no release token (rule 3: the
# token for git push, gh pr merge, the gh api / GraphQL merge forms). Everything else keeps denying with the switch
# off AND on. With push_gate=on the old behaviour is exactly as before (the 1100 checks of t_guard*.sh and t_release.sh
# run with the switch on). The config file itself is a tamper path: a session cannot edit the switch.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CFG=$AGENT_HOME/config
gate_on() { printf 'push_gate=on\n' >"$CFG"; }
gate_off() { rm -f "$CFG"; }

GR=$(mk_repo pgate); GRP=$(cd "$GR" && pwd -P)
git -C "$GR" tag v1.0.0
git -C "$GR" branch feat-x
GC=$(mk_repo pgconf); write_goal "$GC" "true" confirm   # a repo whose GOAL.md says release_mode: confirm
mkdir -p "$AGENT_HOME/defaults"; printf '# Goal\nrelease_mode: confirm\nreview: required\n' >"$AGENT_HOME/defaults/GOAL.md"
GP="$WORK/plainfolder"; mkdir -p "$GP"

# the commands the switch gates, with the rule text each one carries while the gate is on
PUSH_ON="push to main denied"
gated=(
  'git push origin main|'"$PUSH_ON"
  'git push origin HEAD:main|'"$PUSH_ON"
  'git push origin HEAD:refs/heads/main|'"$PUSH_ON"
  'git push -u origin main|'"$PUSH_ON"
  'git push origin feat-x main|'"$PUSH_ON"
  'git push|'"$PUSH_ON"
  'git push origin|'"$PUSH_ON"
  "git -C $GRP push origin HEAD:main|$PUSH_ON"
  "cd $GRP && git push origin main|$PUSH_ON"
  'bash -c "git push origin HEAD:main"|'"$PUSH_ON"
  'git push --all origin|git push --all would push the protected branch'
  'gh pr merge 12 --squash|push to gh pr merge denied'
  'gh pr merge 12|push to gh pr merge denied'
  'gh pr merge 12 --squash --match-head-commit 0000000000000000000000000000000000000000|push to gh pr merge denied'
  'gh api -X PUT repos/o/r/pulls/1/merge|gh api call that merges'
  'gh api --method=PUT repos/o/r/pulls/1/merge -f merge_method=squash|gh api call that merges'
  'gh api -X POST repos/o/r/merges -f base=main -f head=feat|gh api call that merges'
  "gh api graphql -f query='mutation(\$id:ID!){mergePullRequest(input:{pullRequestId:\$id}){clientMutationId}}' -f id=x|rule 3/9: a GraphQL mutation"
)
# what must be refused whatever the switch says (the prefix is the rule's text)
fixed=(
  'git push --force origin main|force push is never allowed'
  'git push -f origin main|force push is never allowed'
  'git push --force-with-lease origin main|force push is never allowed'
  'git push --force-with-lease=main:abc origin main|force push is never allowed'
  'git push origin +main|force push is never allowed'
  'git push origin +HEAD:main|force push is never allowed'
  'git push --force origin feat-x|force push is never allowed'
  'git push origin +feat-x|force push is never allowed'
  'git push --mirror origin|force push is never allowed'
  'git push origin :main|deleting the protected branch main is not allowed'
  'git push --delete origin main|deleting the protected branch main is not allowed'
  'git push -d origin main|deleting the protected branch main is not allowed'
  'git push origin :master|deleting the protected branch master is not allowed'
  'git push --no-verify origin main|--no-verify skips the git hooks'
  'git push --no-verify origin feat-x|--no-verify skips the git hooks'
  'git commit --no-verify -m x|--no-verify skips the git hooks'
  'git commit -n -m x|git commit -n is --no-verify'
  'git push origin v1.0.0|rule 8:'
  'git push origin refs/tags/v1.0.0|rule 8:'
  'git push --tags|rule 8:'
  'git push origin --tags|rule 8:'
  'git push --follow-tags origin feat-x|rule 8:'
  'git push origin :refs/tags/v1.0.0|rule 8:'
  'rm -rf /|recursive delete'
  'rm -rf /etc|recursive delete'
  'vercel deploy --prod|the vercel CLI'
  'gh workflow run deploy.yml|starting or re-running workflows'
  'gh run rerun 123|starting or re-running workflows'
  'gh api -X POST repos/o/r/actions/workflows/x.yml/dispatches -f ref=main|gh api call that merges'
  'gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=abc|gh api call that merges'
  'gh api -X PUT repos/o/r/contents/x.md -f message=m -f content=Zg==|gh api call that merges'
  'gh api -X POST repos/o/r/git/refs -f ref=refs/heads/x -f sha=abc|gh api call that merges'
  'gh api -X POST repos/o/r/releases -f tag_name=v1|rule 8:'
  'gh api -X PATCH repos/o/r/issues/7 -f state=closed|rule 9:'
  "gh api graphql -f query='mutation{closePullRequest(input:{pullRequestId:\"x\"}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  "gh api graphql -f query='mutation{closeIssue(input:{issueId:\"x\"}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  "gh api graphql -f query='mutation{deleteRef(input:{refId:\"x\"}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  "gh api graphql -f query='mutation{updateRef(input:{refId:\"x\",oid:\"y\"}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  "gh api graphql -f query='mutation{createCommitOnBranch(input:{}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  "gh api graphql -f query='mutation{mergePullRequest(input:{pullRequestId:\"x\",commitHeadline:\"close and delete\"}){clientMutationId}}'|rule 3/9: a GraphQL mutation"
  'gh api graphql --input q.json|gh api graphql --input'
  'gh pr close 5|rule 9:'
  'gh issue close 7|rule 9:'
  'gh release create v1.0.0|rule 8:'
  'gh repo delete me/x --yes|rule 8:'
  'npm publish|rule 8:'
  'pnpm publish|rule 8:'
  'cat .env|reading or copying .env'
  'cat apps/web/.env.local|reading or copying .env'
  'bun scripts/db-migrate.ts --record-only 0003_x|db-migrate --record-only'
  'supabase db push|supabase CLI'
  "echo x > $HOME/.claude/settings.json|editing hooks, settings or the guard"
  'rm .git/hooks/pre-push|editing hooks, settings or the guard'
  'git config core.hooksPath /dev/null|changing core.hooksPath'
  'echo abc > .agent/release-token|release/migration tokens'
  "$CLAUDE_DIR/ching/bin/release-gate.sh --approve|release approval is for the human"
)
# ordinary commands that were never gated
ordinary=(
  'git status' 'git fetch origin' 'git pull' 'git pull --rebase origin main' 'git merge feat-x' 'git merge --ff-only origin/main'
  'git rebase main' 'git checkout main' 'git switch -c topic' 'git commit -m "update docs"' 'git push origin feat-x'
  'git push -u origin HEAD:feat-x' 'git push origin v1.0.0-rc1:refs/heads/rc1' 'git log --oneline -5' 'git diff main...HEAD'
  'git branch -D old' 'git reset --hard HEAD~1' 'git commit --amend --no-edit' 'git tag v1.0.1' 'git stash' 'gh pr create --title x --body y' 'gh pr view 12' 'gh pr comment 12 --body ok'
  'gh pr checks 12' 'gh pr list' 'gh run list' 'gh api repos/o/r/pulls/1' 'gh api graphql -f query="query{viewer{login}}"'
  'npm test' 'npm run build' 'pnpm install' 'yarn build' 'bun test' 'git config user.name x' 'git config alias.co checkout'
  'cat ~/.agent/config' 'cat README.md' 'rm -rf node_modules' 'ls -la'
)

run_set() { # label: run every gated/fixed/ordinary command in every repo the label is about
  local label=$1 repo=$2 item c w
  for item in "${fixed[@]}"; do c=${item%%|*}; w=${item#*|}; gdeny_why "$label: stays denied: $c" "$repo" "$c" "$w"; done
  for c in "${ordinary[@]}"; do gallow "$label: ordinary: $c" "$repo" "$c"; done
}

# ---------- switch OFF (no config file): a plain push or merge to main needs no token ----------
gate_off
for repo in "$GR" "$GC" "$GP"; do
  for item in "${gated[@]}"; do
    c=${item%%|*}
    gallow "off: $(basename "$repo"): $c" "$repo" "$c"
  done
done
git -C "$GR" checkout -q -b tracker origin/main
gallow "off: bare git push from a branch that tracks origin/main" "$GR" 'git push'
git -C "$GR" checkout -q main
gallow "off: git push on main with an upstream (and an old token file is not needed)" "$GR" 'git push'
# the GOAL.md of the repo says release_mode: confirm, and so does the defaults file: neither turns the gate back on
assert_contains "setup: the repo GOAL.md says release_mode: confirm" "$(cat "$GC/.agent/GOAL.md")" "release_mode: confirm"
assert_contains "setup: the defaults GOAL.md says release_mode: confirm" "$(cat "$AGENT_HOME/defaults/GOAL.md")" "release_mode: confirm"
run_set "off" "$GR"
run_set "off (confirm repo)" "$GC"

# ---------- garbage, unreadable and other settings mean off ----------
for v in 'push_gate=maybe' 'push_gate=' 'push_gate=0' 'push_gate=1' 'push_gate=yes' 'push_gate=true' 'push_gate=off' '# push_gate=on' 'xpush_gate=on' 'push_gate=on_not'; do
  printf '%s\n' "$v" >"$CFG"
  gallow "setting '$v' is off: push origin main" "$GR" 'git push origin main'
  gallow "setting '$v' is off: gh pr merge" "$GR" 'gh pr merge 12 --squash'
done
printf 'push_gate=on\n' >"$CFG"; chmod 000 "$CFG"
gallow "an unreadable config file means off: push origin main" "$GR" 'git push origin main'
gallow "an unreadable config file means off: gh pr merge" "$GR" 'gh pr merge 12 --squash'
chmod 600 "$CFG"; gate_off
printf 'push_gate=off\n' >"$CFG"
gallow "a directory where the file should be means off" "$GR" 'git push origin main'
rm -f "$CFG"; mkdir "$CFG"
gallow "a config path that is a directory means off" "$GR" 'git push origin main'
rmdir "$CFG"

# ---------- switch ON: exactly the old behaviour, same rule text ----------
gate_on
for repo in "$GR" "$GC"; do
  for item in "${gated[@]}"; do
    c=${item%%|*}; w=${item#*|}
    gdeny_why "on: $(basename "$repo"): $c" "$repo" "$c" "$w"
  done
done
gdeny "on: a plain folder cannot be verified" "$GP" 'git push origin HEAD:main'
for v in 'push_gate=on' 'push_gate = ON' 'PUSH_GATE=on' 'push_gate="on"' "push_gate='On'" 'push_gate=on # the owner asked' 'push_gate=off
push_gate=on' '  push_gate=on  '; do
  printf '%s\n' "$v" >"$CFG"
  case "$v" in PUSH_GATE*) gallow "setting 'PUSH_GATE=on' (wrong case of the key) is off" "$GR" 'git push origin main'; continue ;; esac
  gdeny_why "setting '$(printf '%s' "$v" | tr '\n' '|')' is on" "$GR" 'git push origin main' "$PUSH_ON"
done
gate_on
printf 'push_gate=on\npush_gate=off\n' >"$CFG"
gallow "the last assignment wins (off)" "$GR" 'git push origin main'
gate_on
run_set "on" "$GR"
run_set "on (confirm repo)" "$GC"
# the deny tells the session how the switch works (a human edit)
out=$(printf '%s' "$(bash_json "$GR" 'git push origin main')" | "$BIN/guard.sh" 2>&1)
why=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')
assert_contains "on: the push deny names the switch" "$why" "push_gate"
assert_contains "on: the push deny says where it lives" "$why" "config"
out=$(printf '%s' "$(bash_json "$GR" 'gh pr merge 12 --squash')" | "$BIN/guard.sh" 2>&1)
assert_contains "on: the merge deny names the switch" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "push_gate"
# a valid release token still opens the gate when it is on (the old flow), and only then
gate_on
# the gate turned off is not a back door for the other pushes
gate_off
gdeny_why "off: a force push to a feature branch" "$GR" 'git push --force origin feat-x' "force push is never allowed"
gate_on
gdeny_why "on: a force push to a feature branch" "$GR" 'git push --force origin feat-x' "force push is never allowed"

# ---------- merging stays allowed with the switch off, closing and deleting do not ----------
gate_off
gallow "off: gh pr merge --admin --squash --delete-branch" "$GR" 'gh pr merge 12 --admin --squash --delete-branch'
gallow "off: gh pr merge with a repo flag" "$GR" 'gh pr merge -R o/r 12 --merge'
gallow "off: gh pr -R o/r merge" "$GR" 'gh pr -R o/r merge 5'
gallow "off: gh api enablePullRequestAutoMerge" "$GR" "gh api graphql -f query='mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"x\"}){clientMutationId}}'"
gdeny_why "off: gh pr merge piped into a close is still a close" "$GR" 'gh pr merge 12 && gh pr close 13' "rule 9:"
gdeny_why "off: a merge request body the guard cannot read (--input with a mutating method)" "$GR" 'gh api -X PUT repos/o/r/pulls/1/merge --input body.json' "gh api with a mutating method and --input"

# ---------- the switch is a tamper path: a session cannot edit it, it can read it ----------
for state in off on; do
  if [ "$state" = on ]; then gate_on; else gate_off; fi
  for target in "$HOME/.agent/config" "$AGENT_HOME/config" '~/.agent/config' '$HOME/.agent/config' '$AGENT_HOME/config' '${AGENT_HOME}/config' "$HOME/.agent/CONFIG"; do
    for c in "echo push_gate=off > $target" "echo push_gate=on >> $target" "printf 'push_gate=off\n' >$target" "tee $target <<< push_gate=off" \
             "sed -i '' 's/on/off/' $target" "cp /tmp/x $target" "mv /tmp/x $target" "rm $target" "truncate -s 0 $target" "echo x | tee -a $target" \
             "perl -pi -e 's/on/off/' $target" "ln -sf /dev/null $target" "dd of=$target if=/tmp/x" "install -m 600 /tmp/x $target"; do
      gdeny_why "$state: config is a tamper path: $c" "$GR" "$c" "editing hooks, settings or the guard"
    done
  done
  for p in "$HOME/.agent/config" "$AGENT_HOME/config"; do
    tdeny "$state: Edit tool on $p" Edit "$GR" "$(jq -n --arg p "$p" '{file_path:$p,old_string:"on",new_string:"off"}')"
    tdeny "$state: Write tool on $p" Write "$GR" "$(jq -n --arg p "$p" '{file_path:$p,content:"push_gate=off\n"}')"
    tdeny "$state: MultiEdit tool on $p" MultiEdit "$GR" "$(jq -n --arg p "$p" '{file_path:$p,edits:[{old_string:"on",new_string:"off"}]}')"
    tallow "$state: Read tool on $p" Read "$GR" "$(jq -n --arg p "$p" '{file_path:$p}')"
  done
  for c in 'cat ~/.agent/config' "cat $AGENT_HOME/config" 'cat $AGENT_HOME/config' "cat $HOME/.agent/config" "grep push_gate $AGENT_HOME/config" "ls -la $HOME/.agent" \
           "head -1 $AGENT_HOME/config" 'cat tsconfig.json' 'cat jest.config.js' "echo hello > $GRP/config" "echo '{}' > $GRP/tsconfig.json" \
           'git config --get push.default' "cat $GRP/.git/config" 'cat ~/.ssh/config' "echo x > $GRP/.agent-notes/config"; do
    gallow "$state: config can be read, other config files are not touched: $c" "$GR" "$c"
  done
done
gate_off

# ---------- git aliases follow the switch: a push to main through an alias is rule 3, the rest is not ----------
for kv in 'ap=push origin HEAD:main' 'apf=push --force origin feat-x' 'apt=push origin v1.0.0' 'apall=push --all' 'apub=!npm publish' 'apm=!git push origin HEAD:main'; do
  git -C "$GR" config "alias.${kv%%=*}" "${kv#*=}"
done
gate_off
gallow "off: alias to push origin HEAD:main" "$GR" 'git ap'
gallow "off: shell alias to push origin HEAD:main" "$GR" 'git apm'
gallow "off: alias to push --all" "$GR" 'git apall'
gallow "off: defining an alias that pushes to main" "$GR" "git config alias.zq 'push origin HEAD:main'"
gdeny_why "off: alias to a force push" "$GR" 'git apf' "force push is never allowed"
gdeny_why "off: alias to a tag push" "$GR" 'git apt' "rule 8:"
gdeny_why "off: shell alias that publishes" "$GR" 'git apub' "rule 8:"
gdeny_why "off: defining an alias that force-pushes" "$GR" "git config alias.zq 'push --force origin x'" "force push is never allowed"
gdeny_why "off: -c alias that force-pushes" "$GR" "git -c alias.x='push -f origin main' x" "force push is never allowed"
gate_on
gdeny_why "on: alias to push origin HEAD:main" "$GR" 'git ap' "$PUSH_ON"
gdeny_why "on: shell alias to push origin HEAD:main" "$GR" 'git apm' "$PUSH_ON"
gdeny_why "on: defining an alias that pushes to main" "$GR" "git config alias.zq 'push origin HEAD:main'" "$PUSH_ON"
gate_off

# ---------- the pre-push hook has its own tests (t_release.sh); here only that guard.sh never reads GOAL.md for this ----------
write_goal "$GC" "true" auto
gallow "off: release_mode: auto changes nothing either" "$GC" 'git push origin HEAD:main'
exit 0
