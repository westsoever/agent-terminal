#!/usr/bin/env bash
# post-release.sh with a fake `gh`.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R=$(mk_repo prrepo); write_goal "$R" true auto
printf '# State\n\n## Done\n- x\n\n## Releases\n- (none)\n\n## Recommended next step\n- y\n' >"$R/.agent/STATE.md"
cat >"$WORK/gh" <<'EOS'
#!/usr/bin/env bash
# fake gh: behaviour from $FAKE_GH (success|failure|none)
case "$1 $2" in
  "run list") [ "$FAKE_GH" = none ] && echo '[]' || echo '[{"databaseId":11,"workflowName":"Deploy","url":"https://ci.example/runs/11"}]' ;;
  "run watch") [ "$FAKE_GH" = failure ] && exit 1 || exit 0 ;;
  "run view")
    if [ "$FAKE_GH" = failure ]; then echo '{"conclusion":"failure","url":"https://ci.example/runs/11","workflowName":"Deploy"}'
    else echo '{"conclusion":"success","url":"https://ci.example/runs/11","workflowName":"Deploy"}'; fi ;;
esac
EOS
chmod +x "$WORK/gh"; export GH_BIN="$WORK/gh" POST_RELEASE_WAIT_RUN=0
pr() { (cd "$R" && "$BIN/post-release.sh" "$@" 2>&1); }

export FAKE_GH=success
out=$(pr); assert_eq "success: exit 0" "0" "$?"
assert_contains "success: reported" "$out" "SUCCESS"
st=$(cat "$R/.agent/STATE.md")
assert_contains "success: recorded under Releases with sha and url" "$st" "$(git -C "$R" rev-parse --short HEAD) | SUCCESS | https://ci.example/runs/11"
assert_not_contains "success: placeholder bullet replaced" "$st" "- (none)"$'\n'"
## Recommended"
assert_contains "success: Done notification with repo name" "$(cat "$AGENT_HOME/notify.log")" "prrepo (main): Done"
pr >/dev/null
assert_eq "idempotent: same release recorded once" "1" "$(grep -c '| SUCCESS |' "$R/.agent/STATE.md")"
assert_contains "other sections untouched" "$(cat "$R/.agent/STATE.md")" "## Recommended next step"

export FAKE_GH=failure; commit_file "$R" f.txt x "next"; : >"$AGENT_HOME/notify.log"
out=$(pr); rc=$?
assert_eq "failure: exit 1" "1" "$rc"
assert_contains "failure: reported" "$out" "FAILED"
assert_contains "failure: one-revert rule explained" "$out" "ONE revert commit"
assert_contains "failure: recorded" "$(cat "$R/.agent/STATE.md")" "| FAILED |"
assert_file "failure: marker file" "$R/.agent/release-failed"
assert_contains "failure: Blocked notification" "$(cat "$AGENT_HOME/notify.log")" "prrepo (main): Blocked"

export FAKE_GH=none; commit_file "$R" g.txt x "third"
out=$(pr); assert_eq "no CI run found: exit 0, UNKNOWN" "0" "$?"
assert_contains "no CI run: recorded UNKNOWN" "$(cat "$R/.agent/STATE.md")" "| UNKNOWN |"
GH_BIN="$WORK/no-such-gh" bash -c "cd '$R' && '$BIN/post-release.sh' --no-watch" >/dev/null 2>&1
assert_eq "no gh installed: still records" "0" "$?"
# state file is created when absent
R2=$(mk_repo prrepo2); (cd "$R2" && FAKE_GH=success "$BIN/post-release.sh" >/dev/null 2>&1)
assert_contains "STATE.md created when missing" "$(cat "$R2/.agent/STATE.md")" "## Releases"

# ---------- events (Phase 1.5) ----------
assert_contains "events: deploy outcome logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "deploy-"
exit 0
