#!/usr/bin/env bash
# release-gate.sh (evidence parsing, tokens, confirm mode), guard.sh push rules with tokens, pre-push hook.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
link_kit
GATE="$BIN/release-gate.sh"

mk_review() { # repo commit blocking findings [not_examined]; the file is named after the repo's HEAD
  local d="$1/.agent/review"; mkdir -p "$d"
  { echo "commit: $2"; echo "reviewer: subagent"; echo "lenses: error-resilience, identity, simulation"; echo "blocking: $3"
    echo; echo "## findings"; if [ -n "$4" ]; then printf '%s\n' "$4"; fi
    echo; echo "## not examined"; printf '%s\n' "${5-did not load-test the endpoint}"; } >"$d/$(head_of "$1").md"
}

mk_evidence() { # repo ; env: EV_COMMIT EV_SURFACE EV_NONE EV_SHOT EV_CONSOLE EV_NETWORK EV_ALLOWED EV_EXERCISED EV_VERDICT EV_NOSHOT EV_NOTEX EV_NOREVIEW
  local repo=$1 sha dir
  sha=$(head_of "$repo"); dir="$repo/.agent/verify"; mkdir -p "$dir"
  if [ -z "${EV_NOSHOT:-}" ]; then printf 'png' >"$dir/$sha.png"; else rm -f "$dir/$sha.png"; fi
  {
    echo "commit: ${EV_COMMIT:-$sha}"
    echo "surface: ${EV_SURFACE:-ui}"
    echo "none_reason: ${EV_NONE:-}"
    echo "app_url: http://localhost:3000/view"
    echo "screenshot: ${EV_SHOT:-.agent/verify/$sha.png}"
    echo
    echo "Verdict: ${EV_VERDICT:-PASS, no errors}"
    echo "## console"; echo '```console'; printf '%s\n' "${EV_CONSOLE:-none}"; echo '```'
    echo "## network"; echo '```network'; printf '%s\n' "${EV_NETWORK:-GET http://localhost:3000/view 200}"; echo '```'
    echo "## allowed"; if [ -n "${EV_ALLOWED:-}" ]; then printf '%s\n' "$EV_ALLOWED"; fi
    echo "## not examined"; printf '%s\n' "${EV_NOTEX-did not test the mobile layout}"
    echo "## exercised"; printf '%s\n' "${EV_EXERCISED-- clicked the button, saw the count change}"
  } >"$dir/$sha.md"
  if [ -z "${EV_NOREVIEW:-}" ]; then mk_review "$repo" "$sha" 0 ""; else rm -f "$repo/.agent/review/$sha.md"; fi
}
gate() { (cd "$1" && "$GATE" 2>&1); }
verify() { (cd "$1" && "$GATE" --verify "${2:-}" 2>&1); }
reset_ev() { unset EV_COMMIT EV_SURFACE EV_NONE EV_SHOT EV_CONSOLE EV_NETWORK EV_ALLOWED EV_EXERCISED EV_VERDICT EV_NOSHOT EV_NOTEX EV_NOREVIEW; }

# ---------- opt-in: no GOAL.md means no gate ----------
R0=$(mk_repo nogoal)
out=$(gate "$R0"); rc=$?
assert_eq "no GOAL.md: gate refuses (opt-in)" "1" "$rc"
assert_contains "no GOAL.md: message says it is opt-in" "$out" "opt-in per repo"

# ---------- gate checks ----------
R=$(mk_repo rel); RP=$(cd "$R" && pwd -P)
write_goal "$R" "true" auto
commit_file "$R" a.txt "one"
out=$(gate "$R"); assert_contains "no evidence file: fails" "$out" "no evidence file"
echo dirty >"$R/dirty.txt"
out=$(gate "$R"); assert_contains "dirty tree: fails" "$out" "not clean"
rm "$R/dirty.txt"
mk_evidence "$R"
# behind origin
CL="$WORK/otherclone"; git clone -q "$WORK/rel.git" "$CL"; commit_file "$CL" other.txt x "other"; git -C "$CL" push -q origin main
out=$(gate "$R"); assert_contains "behind origin/main: fails" "$out" "not up to date"
git -C "$R" pull -q --rebase origin main
mk_evidence "$R"

reset_ev
EV_CONSOLE='[error] Failed to load resource: the server responded with a status of 404 ()'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "console error rejected even though the verdict says PASS" "$out" "console error"
reset_ev; EV_CONSOLE='Uncaught TypeError: x is not a function'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "uncaught exception rejected" "$out" "console error"
reset_ev; EV_CONSOLE=$'[log] hello\n[warn] deprecated thing\n[log] all good'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "warnings and logs alone pass the console check" "$out" "PASS"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/view 200\nGET http://localhost:3000/favicon.ico 404'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "404 request rejected" "$out" "status 404"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/api/x 500'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "500 request rejected" "$out" "status 500"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/ 302'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "3xx other than 304 rejected" "$out" "status 302"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/ 200\nGET http://localhost:3000/a.js 304\nPOST http://localhost:3000/api 201'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "2xx and 304 pass" "$out" "PASS"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/ [200]\nGET http://localhost:3000/b 200,'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "[200] / trailing comma status forms are accepted" "$out" "PASS"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/ 200\nGET http://localhost:3000/favicon.ico 404'; EV_ALLOWED='- favicon\.ico  # no favicon in dev'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "allowed pattern with a reason accepts the favicon 404" "$out" "PASS"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/favicon.ico 404'; EV_ALLOWED='- favicon\.ico'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "allowed pattern without a reason is rejected" "$out" "without a '# reason'"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/x 500'; EV_ALLOWED='- .*  # everything is fine'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "catch-all allowed pattern rejected" "$out" "matches everything"
reset_ev; EV_NETWORK=$'GET http://localhost:3000/x 500'; EV_ALLOWED='- favicon  # only the icon'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "allowed pattern does not hide other failures" "$out" "status 500"
reset_ev; EV_NETWORK='GET http://localhost:3000/ ok'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "network line without a status rejected" "$out" "must end with an HTTP status"
reset_ev; EV_COMMIT=0123456789012345678901234567890123456789
mk_evidence "$R"; out=$(gate "$R"); assert_contains "evidence for another commit rejected" "$out" "commit: must be exactly"
reset_ev; EV_NOSHOT=1
mk_evidence "$R"; out=$(gate "$R"); assert_contains "surface ui without screenshot rejected" "$out" "screenshot"
reset_ev; EV_EXERCISED=''
mk_evidence "$R"; out=$(gate "$R"); assert_contains "surface ui without exercised bullets rejected" "$out" "## exercised"
reset_ev; EV_SURFACE=none; EV_NONE='short'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "surface none with a thin reason rejected" "$out" "none_reason"
reset_ev; EV_SURFACE=none; EV_NONE='docs-only change, no UI surface'
mk_evidence "$R"; out=$(gate "$R"); assert_contains "surface none with a real reason passes" "$out" "PASS"
reset_ev; EV_SURFACE=banana
mk_evidence "$R"; out=$(gate "$R"); assert_contains "unknown surface rejected" "$out" "surface: must be ui or none"
reset_ev
mk_evidence "$R"; sed -i.bak '/^## network/,/^## allowed/d' "$R/.agent/verify/$(head_of "$R").md"
out=$(gate "$R"); assert_contains "missing network section rejected" "$out" "missing '## network'"
reset_ev

# failing tests block the gate
write_goal "$R" "false" auto
mk_evidence "$R"; out=$(gate "$R"); assert_contains "failing test_command: gate fails" "$out" "test_command failed"
write_goal "$R" "true" auto

# ---------- token flow: none / valid / stale / forged ----------
rm -f "$R/.agent/release-token"
HEAD1=$(head_of "$R")
out=$(verify "$R"); rc=$?
assert_eq "no token: verify fails" "1" "$rc"
assert_contains "no token: message" "$out" "no release-token"
gallow "(setup) a push to a feature branch needs no token" "$R" 'git push origin HEAD:feat1'
gdeny "no token: push to main denied" "$R" 'git push origin HEAD:main'
mk_evidence "$R"; out=$(gate "$R"); rc=$?
assert_eq "valid evidence + green tests: gate passes" "0" "$rc"
assert_contains "auto mode mints a token" "$out" "Token minted for ${HEAD1:0:7}"
assert_file "token file exists" "$R/.agent/release-token"
out=$(verify "$R"); assert_eq "valid token: verify passes" "0" "$?"
gallow "valid token: push origin HEAD:main allowed" "$R" 'git push origin HEAD:main'
gallow "valid token: bare 'git push' on main allowed" "$R" 'git push'
gallow "valid token: git -C ... push allowed" "$R" "git -C $RP push origin HEAD:main"
gallow "valid token: cd && push allowed" "$R" "cd $RP && git push origin main"
H=$(head_of "$R")
gdeny "valid token: gh pr merge without --match-head-commit denied" "$R" 'gh pr merge 12 --squash'
gdeny "valid token: gh pr merge pinned to another commit denied" "$R" 'gh pr merge 12 --squash --match-head-commit 0000000000000000000000000000000000000000'
gallow "valid token: gh pr merge pinned to the released commit allowed" "$R" "gh pr merge 12 --squash --match-head-commit $H"
gallow "valid token: gh pr merge with =form pin allowed" "$R" "gh pr merge 12 --match-head-commit=$H"
gdeny "valid token still never allows force" "$R" 'git push --force origin HEAD:main'
gdeny "valid token: --no-verify denied" "$R" 'git push --no-verify origin HEAD:main'
gdeny "valid token: obfuscated target still denied (cannot resolve)" "$R" 'git push origin HEAD:m""ain$X'
# pushing a different commit than the token is for
git -C "$R" checkout -q -b other-work; commit_file "$R" b.txt two "two"; git -C "$R" checkout -q main
gdeny "token is for HEAD but another branch tip is pushed" "$R" 'git push origin other-work:main'
git -C "$R" branch -q -D other-work
# stale: a new commit invalidates the token
commit_file "$R" c.txt three "three"
out=$(verify "$R"); assert_eq "stale token (new commit): verify fails" "1" "$?"
assert_contains "stale token: message names both commits" "$out" "re-run release-gate.sh"
gdeny "stale token: push to main denied" "$R" 'git push origin HEAD:main'
gdeny "stale token: gh pr merge denied even when pinned" "$R" "gh pr merge 12 --match-head-commit $(head_of "$R")"
# forged / edited tokens
HEAD3=$(head_of "$R")
printf '%s\n' "$HEAD3" >"$R/.agent/release-token"
out=$(verify "$R"); assert_eq "hand-written token (plain sha): rejected" "1" "$?"
gdeny "hand-written token: push denied" "$R" 'git push origin HEAD:main'
mk_evidence "$R"; gate "$R" >/dev/null
sed -i.bak "s/^sha=.*/sha=$HEAD1/" "$R/.agent/release-token"
out=$(verify "$R" "$HEAD1"); assert_contains "edited token sha: signature invalid" "$out" "signature invalid"
gate "$R" >/dev/null   # re-mint properly

# ---------- the real git pre-push hook as the second layer ----------
out=$(CLAUDE_DIR="$CLAUDE_DIR" "$KIT/install.sh" --install-prepush "$R"); assert_contains "pre-push installed" "$out" "write"
assert_file "pre-push hook file" "$R/.git/hooks/pre-push"
assert_contains "hook points at the kit via the symlink" "$(cat "$R/.git/hooks/pre-push")" "$CLAUDE_DIR/ching/bin"
out=$(CLAUDE_DIR="$CLAUDE_DIR" "$KIT/install.sh" --install-prepush "$R"); assert_contains "pre-push install is idempotent" "$out" "already installed"
out=$(git -C "$R" push origin HEAD:main 2>&1); rc=$?
assert_eq "hook: push to main with a valid token succeeds" "0" "$rc"
commit_file "$R" d.txt four "four"
out=$(git -C "$R" push origin HEAD:main 2>&1); rc=$?
assert_eq "hook: push to main with a stale token is blocked" "1" "$rc"
assert_contains "hook: message" "$out" "pre-push: push to main blocked"
out=$(git -C "$R" push origin 'HEAD:ma''in' 2>&1); assert_eq "hook sees resolved refs (any spelling)" "1" "$?"
B=main; out=$(git -C "$R" push origin "HEAD:$B" 2>&1); assert_eq "hook: variable-expanded target also blocked" "1" "$?"
out=$(git -C "$R" push origin HEAD:feat2 2>&1); assert_eq "hook: non-protected branch unaffected" "0" "$?"
out=$(git -C "$R" push origin :main 2>&1); assert_eq "hook: deleting main blocked" "1" "$?"
# existing foreign pre-push hook is preserved
R4=$(mk_repo foreign); printf '#!/bin/sh\nexit 0\n' >"$R4/.git/hooks/pre-push"; chmod +x "$R4/.git/hooks/pre-push"
out=$(CLAUDE_DIR="$CLAUDE_DIR" "$KIT/install.sh" --install-prepush "$R4")
assert_contains "foreign hook: not overwritten, side file written" "$out" "pre-push.ching"
assert_eq "foreign hook content intact" '#!/bin/sh' "$(head -1 "$R4/.git/hooks/pre-push")"
# honours core.hooksPath
R5=$(mk_repo hp); mkdir -p "$R5/.githooks"; git -C "$R5" config core.hooksPath .githooks
CLAUDE_DIR="$CLAUDE_DIR" "$KIT/install.sh" --install-prepush "$R5" >/dev/null
assert_file "hook installed into core.hooksPath dir" "$R5/.githooks/pre-push"
# the documented human bypass exists, and the guard denies it for agents (tested above)
out=$(git -C "$R" push --no-verify origin HEAD:main 2>&1); assert_eq "human --no-verify bypass works (documented)" "0" "$?"

# ---------- confirm mode ----------
RC=$(mk_repo conf); write_goal "$RC" "true" confirm
commit_file "$RC" a.txt one one; mk_evidence "$RC"; : >"$AGENT_HOME/notify.log"
out=$(gate "$RC"); rc=$?
assert_eq "confirm mode: gate passes" "0" "$rc"
assert_contains "confirm mode: tells the agent to wait" "$out" "Waiting for the human"
assert_no_file "confirm mode: no token yet" "$RC/.agent/release-token"
assert_file "confirm mode: ready marker" "$RC/.agent/release-ready"
assert_contains "confirm mode: notifies 'Ready to push' with repo name" "$(cat "$AGENT_HOME/notify.log")" "conf (main): Ready to push"
gdeny "confirm mode: push denied before approval" "$RC" 'git push origin HEAD:main'
out=$(verify "$RC"); assert_eq "confirm mode: verify fails before approval" "1" "$?"
gdeny "confirm mode: the agent cannot approve" "$RC" "$BIN/release-gate.sh --approve"
out=$(cd "$RC" && "$GATE" --approve 2>&1); rc=$?
assert_eq "human --approve succeeds" "0" "$rc"
gallow "after approval the push is allowed" "$RC" 'git push origin HEAD:main'
commit_file "$RC" b.txt two two
out=$(cd "$RC" && "$GATE" --approve 2>&1); assert_eq "approve for a new commit without a gate run fails" "1" "$?"
# a hand-written ready marker is not accepted
printf 'kind=release-ready\nsha=%s\ntime=1\nsig=bad\n' "$(head_of "$RC")" >"$RC/.agent/release-ready"
out=$(cd "$RC" && "$GATE" --approve 2>&1); assert_eq "forged ready marker rejected" "1" "$?"

# ---------- Phase 1.5: not examined + required review ----------
RV=$(mk_repo revrepo); write_goal "$RV" "true" auto
commit_file "$RV" a.txt one
reset_ev; EV_NOTEX="" mk_evidence "$RV"
assert_contains "evidence without not-examined is rejected" "$(gate "$RV")" "not examined"
reset_ev; EV_NOREVIEW=1 mk_evidence "$RV"
assert_contains "missing review is rejected with how-to" "$(gate "$RV")" "no review file"
reset_ev; mk_evidence "$RV"; sha=$(head_of "$RV")
mk_review "$RV" "$sha" 1 "- [blocking] a.txt:1 wrong value"
assert_contains "blocking finding without resolved: is rejected" "$(gate "$RV")" "without a resolved: line"
mk_review "$RV" "$sha" 1 "- [blocking] a.txt:1 wrong value"$'\n'"  resolved: kept on purpose, see STATE.md decision"
assert_contains "resolved blocking finding passes" "$(gate "$RV")" "PASS"
mk_review "$RV" "0000000000000000000000000000000000000000" 0 ""
assert_contains "review for another commit is rejected" "$(gate "$RV")" "commit: must be exactly"
mk_review "$RV" "$sha" 0 "" ""
assert_contains "review without not-examined is rejected" "$(gate "$RV")" "not examined"
mk_review "$RV" "$sha" 0 ""; touch -t 202001010000 "$RV/.agent/review/$sha.md"
assert_contains "review older than the commit is rejected" "$(gate "$RV")" "older than the commit"
rm "$RV/.agent/review/$sha.md"
# Review Focus 3: only exactly "off" disables review
for v in "Off" "no" "required" ""; do
  write_goal "$RV" "true" auto "review: $v"
  assert_contains "review: '$v' still requires a review" "$(gate "$RV")" "no review file"
done
write_goal "$RV" "true" auto "review: off"
out=$(gate "$RV")
assert_contains "review: off skips the review" "$out" "review skipped"
assert_contains "review: off still passes the rest" "$out" "PASS"
assert_contains "events: gate outcome logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "gate-pass-auto"
assert_contains "events: gate failure logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "gate-fail"
for l in error-resilience identity simulation; do
  assert_file "lens $l exists" "$KIT/templates/review-lenses/$l.md"
  assert_contains "lens $l asks for not examined" "$(cat "$KIT/templates/review-lenses/$l.md")" "## not examined"
done
assert_contains "REVIEW.md template has blocking:" "$(cat "$KIT/templates/REVIEW.md")" "blocking:"
assert_contains "VERIFY.md template has not examined" "$(cat "$KIT/templates/VERIFY.md")" "## not examined"
exit 0
