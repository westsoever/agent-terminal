#!/usr/bin/env bash
# guard.sh: git aliases do not bypass the push and publish rules (CHECKPOINT-1.5 section 6, "Git aliases still bypass
# the push rules"). An alias is resolved where the guard can see it (this repo's config, a global config, `-c
# alias.x=...` on the same command, a `git config alias.x ...` earlier in the same command) and the rules run on what
# it expands to; defining an alias that would push to main, force-push, push a tag or publish is itself denied.
# The aliases live in the sandbox repos' local config (GIT_CONFIG_GLOBAL is /dev/null in tests).
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Rule 3 (a release token for a push or merge to main) applies only while the push gate is on, and it is off by
# default: these tests prove the rule, so they run with push_gate=on (t_pushgate.sh covers the switch itself).
printf 'push_gate=on\n' >"$AGENT_HOME/config"

AR=$(mk_repo aliasrepo); ARP=$(cd "$AR" && pwd -P)
git -C "$AR" tag v1.2.3
git -C "$AR" branch feat-x
defalias() { git -C "$AR" config "alias.$1" "$2"; }   # name body: a local alias in the sandbox repo

# the prefixes of the rules an alias expansion can hit (the alias note is appended, so the rule's own text stays first)
R2="force push is never allowed"
R3="push to main denied"
R8="rule 8:"

# ---------- an alias that is already in the config, used by name ----------
defalias p 'push origin HEAD:main'
defalias pf 'push --force'
defalias pt 'push origin v1.2.3'
defalias ptags 'push --tags'
defalias pall 'push --all'
defalias ship '!git push origin HEAD:main'
defalias shipf '!git push --force origin feat-x'
defalias pub '!npm publish'
defalias pubnp 'config core.hooksPath /dev/null'
defalias nv 'commit --no-verify'
defalias cn 'commit -n'
defalias a 'b'
defalias b 'push origin HEAD:main'
defalias chain1 'chain2'; defalias chain2 'chain3'; defalias chain3 'chain4'; defalias chain4 'p'
defalias pm 'push origin'
defalias pc '-c core.abbrev=9 push origin HEAD:main'
defalias pcwd '-C . push origin HEAD:main'
defalias go '!f() { git push origin "$@"; }; f'
defalias pushto '!git push origin $1'
defalias sh2 '!sh -c "git push origin HEAD:main"'
defalias semi '!echo hi; git push origin HEAD:main'
defalias both '!git status && npm publish'
defalias ghpr '!gh pr close 5'
gdeny_why "alias: push origin HEAD:main" "$AR" 'git p' "$R3"
gdeny_why "alias: the same through -C" "$AR" "git -C $ARP p" "$R3"
gdeny_why "alias: the same after cd" "$HOME" "cd $ARP && git p" "$R3"
mkdir -p "$AR/sub"
gdeny_why "alias: the same from a subfolder" "$AR" "cd sub && git p" "$R3"
gdeny_why "alias: the same behind env and a wrapper" "$AR" 'env GIT_TERMINAL_PROMPT=0 git p' "$R3"
gdeny_why "alias: the same in bash -c" "$AR" 'bash -c "git p"' "$R3"
gdeny_why "alias: the same in a subshell" "$AR" '(git p)' "$R3"
gdeny_why "alias: after a global option" "$AR" 'git --no-pager p' "$R3"
gdeny_why "alias: force push" "$AR" 'git pf origin feat-x' "$R2"
gdeny_why "alias: push a release tag" "$AR" 'git pt' "$R8"
gdeny_why "alias: push --tags" "$AR" 'git ptags' "$R8"
gdeny_why "alias: push --all" "$AR" 'git pall origin' "git push --all"
gdeny_why "alias: shell alias that pushes to main" "$AR" 'git ship' "$R3"
gdeny_why "alias: shell alias that force-pushes" "$AR" 'git shipf' "$R2"
gdeny_why "alias: shell alias that publishes" "$AR" 'git pub' "$R8"
gdeny_why "alias: shell alias with a publish after a harmless command" "$AR" 'git both' "$R8"
gdeny_why "alias: shell alias that closes a PR" "$AR" 'git ghpr' "rule 9:"
gdeny_why "alias: shell alias that pushes through sh -c" "$AR" 'git sh2' "$R3"
gdeny_why "alias: shell alias with a semicolon" "$AR" 'git semi' "$R3"
gdeny_why "alias: changes core.hooksPath" "$AR" 'git pubnp' "changing core.hooksPath"
gdeny_why "alias: commit --no-verify" "$AR" 'git nv -m x' "--no-verify skips"
gdeny_why "alias: commit -n" "$AR" 'git cn -m x' "git commit -n"
gdeny_why "alias: a chain of two" "$AR" 'git a' "$R3"
gdeny_why "alias: a chain of five" "$AR" 'git chain1' "$R3"
gdeny_why "alias: with arguments appended (push origin + main)" "$AR" 'git pm main' "$R3"
gdeny_why "alias: with arguments appended (push origin + a v tag)" "$AR" 'git pm v1.2.3' "$R8"
gdeny_why "alias: with arguments appended (push origin + --force)" "$AR" 'git pm --force feat-x' "$R2"
gdeny_why "alias: global options inside the expansion" "$AR" 'git pc' "$R3"
gdeny_why "alias: -C inside the expansion" "$AR" 'git pcwd' "$R3"
gdeny_why "alias: shell function taking the args (main)" "$AR" 'git go main' "$R3"
gdeny_why "alias: shell alias with \$1 (main)" "$AR" 'git pushto main' "$R3"
out=$(printf '%s' "$(bash_json "$AR" 'git p')" | "$BIN/guard.sh" 2>&1)
assert_contains "alias: the reason names the alias" "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason')" "git alias 'p'"
gdeny_why "alias: after a cd the guard cannot resolve" "$AR" 'cd $WHERE; git p' "git push after a cd the guard cannot resolve"
# a bare-push alias and one that pushes the current branch: decided by the branch, like the plain command
defalias pb 'push'
defalias pu 'push -u origin HEAD'
gdeny_why "alias: bare push on main" "$AR" 'git pb' "$R3"
gdeny_why "alias: push -u origin HEAD on main" "$AR" 'git pu' "$R3"
git -C "$AR" checkout -q feat-x
gallow "alias: bare push on a feature branch" "$AR" 'git pb'
gallow "alias: push -u origin HEAD on a feature branch" "$AR" 'git pu'
gdeny_why "alias: HEAD:main stays denied on a feature branch" "$AR" 'git p' "$R3"
git -C "$AR" checkout -q main

# ---------- the alias is defined and used on the same command line ----------
gdeny_why "-c alias: push origin HEAD:main" "$AR" "git -c alias.x='push origin HEAD:main' x" "$R3"
gdeny_why "-c alias: double-quoted value" "$AR" 'git -c alias.x="push origin HEAD:main" x' "$R3"
gdeny_why "-c alias: the quote before the key" "$AR" "git -c 'alias.x=push origin HEAD:main' x" "$R3"
gdeny_why "-c alias: force push" "$AR" "git -c alias.x='push --force' x origin feat-x" "$R2"
gdeny_why "-c alias: unquoted value, the target as arguments" "$AR" 'git -c alias.x=push x origin HEAD:main' "$R3"
gdeny_why "-c alias: release tag" "$AR" "git -c alias.x='push origin v1.2.3' x" "$R8"
gdeny_why "-c alias: shell alias" "$AR" "git -c alias.x='!git push origin HEAD:main' x" "$R3"
gdeny_why "-c alias: shell alias that publishes" "$AR" "git -c alias.x='!npm publish' x" "$R8"
gdeny_why "-c alias: upper-case section" "$AR" "git -c Alias.x='push --force' x origin feat-x" "$R2"
gdeny_why "-c alias: bare push on main" "$AR" "git -c alias.x=push x" "$R3"
gdeny_why "-c alias: behind -C" "$AR" "git -C $ARP -c alias.x='push origin HEAD:main' x" "$R3"
gdeny_why "-c alias: in bash -c" "$AR" "bash -c \"git -c alias.x='push origin HEAD:main' x\"" "$R3"
gdeny_why "-c alias: after another -c" "$AR" "git -c color.ui=never -c alias.x='push origin HEAD:main' x" "$R3"
gdeny_why "GIT_CONFIG_COUNT alias" "$AR" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0='push origin HEAD:main' git x" "$R3"
gdeny_why "GIT_CONFIG_COUNT alias, force push" "$AR" "GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.x GIT_CONFIG_VALUE_0='push --force' git x origin feat-x" "$R2"
gdeny_why "GIT_CONFIG_PARAMETERS alias" "$AR" "GIT_CONFIG_PARAMETERS=\"'alias.x=push origin HEAD:main'\" git x" "$R3"
gdeny "--config-env alias (the value is in the environment, the guard cannot read it)" "$AR" 'XV="push origin HEAD:main" git --config-env=alias.x=XV x'
gdeny "--config-env alias, separate word" "$AR" 'XV="push --force" git --config-env alias.x=XV x origin feat-x'

# ---------- defining an alias that would do any of that ----------
# (a push of the current branch is allowed to be defined: whether it is allowed to run depends on the branch, and the
# alias is checked again when it is used)
gdeny_why "define: push origin HEAD:main" "$AR" "git config alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: --global" "$AR" "git config --global alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: --local" "$AR" "git config --local alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: --file" "$AR" "git config --file $WORK/other.cfg alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: git config set" "$AR" "git config set alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: --add" "$AR" "git config --add alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: --replace-all" "$AR" "git config --replace-all alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define: unquoted value" "$AR" "git config alias.q push origin HEAD:main" "$R3"
gdeny_why "define: double-quoted value" "$AR" 'git config alias.q "push origin HEAD:main"' "$R3"
gdeny_why "define: force push" "$AR" "git config alias.q 'push --force'" "$R2"
gdeny_why "define: force push with a remote" "$AR" "git config alias.q 'push -f origin feat-x'" "$R2"
gdeny_why "define: push --tags" "$AR" "git config alias.q 'push --tags'" "$R8"
gdeny_why "define: push a release tag" "$AR" "git config alias.q 'push origin v1.2.3'" "$R8"
gdeny_why "define: push --all" "$AR" "git config alias.q 'push --all'" "git push --all"
gdeny_why "define: shell alias that pushes to main" "$AR" "git config alias.q '!git push origin HEAD:main'" "$R3"
gdeny_why "define: shell alias that force-pushes" "$AR" "git config alias.q '!git push -f origin feat-x'" "$R2"
gdeny_why "define: shell alias that publishes" "$AR" "git config alias.q '!npm publish'" "$R8"
gdeny_why "define: shell alias that publishes with pnpm" "$AR" "git config alias.q '!pnpm publish'" "$R8"
gdeny_why "define: shell alias that closes a PR" "$AR" "git config alias.q '!gh pr close 5'" "rule 9:"
gdeny_why "define: shell alias with a function" "$AR" "git config alias.q '!f() { git push origin HEAD:main; }; f'" "$R3"
gdeny_why "define: commit --no-verify" "$AR" "git config alias.q 'commit --no-verify'" "--no-verify skips"
gdeny_why "define: core.hooksPath" "$AR" "git config alias.q 'config core.hooksPath /dev/null'" "changing core.hooksPath"
gdeny_why "define: an alias of an alias that pushes to main" "$AR" "git config alias.q 'b'" "$R3"
gdeny_why "define: in bash -c" "$AR" "bash -c \"git config alias.q 'push origin HEAD:main'\"" "$R3"
gdeny_why "define: -C" "$AR" "git -C $ARP config alias.q 'push origin HEAD:main'" "$R3"
gdeny_why "define then use, one command" "$AR" "git config alias.q 'push origin HEAD:main' && git q" "$R3"
gdeny_why "define then use, one command (use is what pushes)" "$AR" "git config alias.q push && git q origin HEAD:main" "$R3"
gdeny_why "define in two steps, then use" "$AR" "git config alias.q1 push && git config alias.q2 'q1 origin HEAD:main' && git q2" "$R3"
gdeny_why "define a benign alias, then use it to force push" "$AR" "git config alias.q push; git q --force origin feat-x" "$R2"
gdeny_why "define a benign alias, then use it to push a tag" "$AR" "git config alias.q 'push origin' && git q v1.2.3" "$R8"
gdeny_why "define a shell alias, then use it (publish)" "$AR" "git config alias.q '!npm' && git q publish" "$R8"

# ---------- ordinary work stays allowed ----------
git -C "$AR" config --unset-all alias.q 2>/dev/null || true
defalias co checkout
defalias st status
defalias lg 'log --oneline --graph --decorate'
defalias ci commit
defalias br branch
defalias cleanup '!git branch --merged | grep -v main | xargs git branch -d'
defalias sync '!git fetch origin && git rebase origin/main'
defalias hi '!echo hi'
defalias pfeat 'push origin feat-x'
defalias pushfeat '!git push origin $1'
defalias gofeat '!f() { git push origin "$@"; }; f'
defalias recent 'for-each-ref --sort=-committerdate --count=5 refs/heads/'
defalias loop1 'loop2'; defalias loop2 'loop1'
defalias status 'push origin HEAD:main'   # a built-in name: git ignores an alias that hides a command
for c in 'git co main' 'git co -b new-branch' 'git st' 'git lg -5' 'git ci -m "fix the parser"' 'git br -a' 'git cleanup' 'git sync' 'git hi' \
         'git pfeat' 'git pushfeat feat-x' 'git gofeat feat-x' 'git recent' 'git status' 'git -C . st' 'git --no-pager lg' \
         'git config user.name x' 'git config alias.zz checkout' 'git config --global alias.zz status' 'git config alias.zz2 "log --oneline"' \
         'git config alias.zz3 "!git branch --merged | xargs git branch -d"' 'git config alias.zz4 "!git fetch && git rebase origin/main"' \
         'git config alias.zz5 push' 'git config alias.zz6 "push -u origin HEAD"' 'git config alias.zz7 "push origin feat-x"' \
         'git config alias.zz8 "!git push origin $1"' 'git config alias.zz9 "!npm test"' 'git config alias.zz10 "!npm publish --dry-run"' \
         "git config alias.pb '!git push origin \$(git branch --show-current)'" "git config alias.pv '!git push origin \$BRANCH'" \
         'git config --get alias.p' 'git config --unset alias.zz' 'git config --get-regexp "^alias"' 'git config --list' 'git config -l | grep alias' \
         'git config --global --unset alias.p' 'git config alias.p' 'git config core.editor vim' 'git config --file x.cfg user.name y' \
         "git -c alias.l='log --oneline' l" "git -c alias.co=checkout co main" "git -c alias.pf='push origin feat-x' pf" 'git -c color.ui=always status' \
         'git -c user.name=x commit --allow-empty -m x' 'git lfs pull' 'git flow init' 'git frobnicate' 'git zz-nothing' 'git loop1' \
         'env GIT_TERMINAL_PROMPT=0 git co main' 'bash -c "git co main"' 'git push origin feat-x' 'git push -u origin HEAD:feat-x' 'git fetch --all' \
         'git log --oneline' 'git add -A' 'git commit -m "alias p push"' 'git commit -m "git config alias.p push origin HEAD:main"' \
         'echo git config alias.p push origin HEAD:main' 'grep alias.p .git/config' 'git help -a'; do
  gallow "ordinary: $c" "$AR" "$c"
done
# the deny list of the ordinary commands above must not have been a lucky miss: the same alias denies once it is dangerous
defalias co 'push origin HEAD:main'
gdeny_why "alias co turned into a push to main is denied" "$AR" 'git co' "$R3"
defalias co checkout

# ---------- what the guard cannot resolve is allowed, as it was before ----------
P="$WORK/plain"; mkdir -p "$P"
gallow "a plain folder: an unknown git word" "$P" 'git p'
gallow "an unreadable directory (-C a missing folder)" "$AR" 'git -C /nonexistent-kaching-dir p'
printf '[alias\nbroken = \n' >"$WORK/broken.cfg"
out=$(printf '%s' "$(bash_json "$AR" 'git p2')" | GIT_CONFIG_GLOBAL="$WORK/broken.cfg" "$BIN/guard.sh" 2>&1)
assert_eq "a global config that does not parse: an unknown word is allowed (as before)" "" "$out"
# a global alias is visible in real life: GIT_CONFIG_GLOBAL points at it here
printf '[alias]\n\tgp = push origin HEAD:main\n\tgpt = !npm publish\n\tgok = status\n' >"$WORK/global.cfg"
for c in 'git gp' 'git gpt'; do
  out=$(printf '%s' "$(bash_json "$P" "$c")" | GIT_CONFIG_GLOBAL="$WORK/global.cfg" "$BIN/guard.sh" 2>&1)
  if is_deny "$out"; then pass "deny: a global alias in a plain folder: $c"; else fail "deny: a global alias in a plain folder: $c" "$out"; fi
done
out=$(printf '%s' "$(bash_json "$P" 'git gok')" | GIT_CONFIG_GLOBAL="$WORK/global.cfg" "$BIN/guard.sh" 2>&1)
assert_eq "a harmless global alias is allowed" "" "$out"
out=$(printf '%s' "$(bash_json "$AR" 'git gp')" | GIT_CONFIG_GLOBAL="$WORK/global.cfg" "$BIN/guard.sh" 2>&1)
if is_deny "$out"; then pass "deny: a global alias in a repo"; else fail "deny: a global alias in a repo" "$out"; fi

# ---------- limits ----------
# an alias loop is git's own error ("alias loop detected"), nothing runs; a chain longer than the limit is refused
for i in 1 2 3 4 5 6 7 8; do defalias "deep$i" "deep$((i + 1))"; done
defalias deep9 'push origin HEAD:main'
gdeny "an alias chain longer than the limit is refused" "$AR" 'git deep1'
gallow "an alias loop is allowed (git itself stops it)" "$AR" 'git loop1'
# the lookup costs nothing for a command that is not an alias and the guard stays inside its time limit
start=$(date +%s)
for i in 1 2 3 4 5 6 7 8 9 10; do printf '%s' "$(bash_json "$AR" 'git zz-nothing')" | "$BIN/guard.sh" >/dev/null 2>&1; done
assert_eq "ten lookups of an unknown git word stay well under the ceiling" "1" "$([ $(( $(date +%s) - start )) -lt 20 ] && echo 1 || echo 0)"
exit 0
