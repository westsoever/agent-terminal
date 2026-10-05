#!/usr/bin/env bash
# notify.sh: repo/folder name in title, terminal-notifier -> osascript fallback, idle de-dup.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

R=$(mk_repo notifyrepo)
LOG="$AGENT_HOME/notify.log"
run_hook notify.sh "$(hook_json Notification "$R" n1)" >/dev/null 2>&1 || true
printf '%s' "$(hook_json Notification "$R" n1)" | "$BIN/notify.sh" input "Pick a colour"
assert_contains "title includes repo name" "$(cat "$LOG")" "notifyrepo"
assert_contains "title includes branch" "$(cat "$LOG")" "notifyrepo (main): Needs input"
assert_contains "message delivered" "$(cat "$LOG")" "Pick a colour"

P="$WORK/just a folder"; mkdir -p "$P"
printf '%s' "$(hook_json Notification "$P" n2)" | "$BIN/notify.sh" done
assert_contains "non-git folder name in title" "$(cat "$LOG")" "just a folder: Done"

# worktree: title uses the worktree directory name
git -C "$R" worktree add -q -b feat "$WORK/notifyrepo-wt" >/dev/null 2>&1
printf '%s' "$(hook_json Notification "$WORK/notifyrepo-wt" n3)" | "$BIN/notify.sh" done
assert_contains "worktree: its own name and branch" "$(cat "$LOG")" "notifyrepo-wt (feat): Done"

# delivery: osascript fallback gets title and message as argv (never as script source)
cat >"$WORK/fake-osa" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OUT"
EOS
chmod +x "$WORK/fake-osa"
export FAKE_OUT="$WORK/osa.out" NOTIFY_OSASCRIPT="$WORK/fake-osa"
unset NOTIFY_DRY_RUN
printf '%s' "$(hook_json Notification "$R" n4)" | "$BIN/notify.sh" blocked 'say "hi" & `rm -rf /`'
out=$(cat "$FAKE_OUT")
assert_contains "osascript fallback used when terminal-notifier is absent" "$out" "display notification"
assert_contains "osascript gets repo name in the title argv" "$out" "notifyrepo (main): Blocked"
assert_contains "osascript gets the message verbatim as argv" "$out" 'say "hi" & `rm -rf /`'
assert_contains "log says osascript" "$(cat "$LOG")" "osascript"

# delivery: terminal-notifier when present, click activates the Claude app
cat >"$WORK/fake-tn" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OUT_TN"
EOS
chmod +x "$WORK/fake-tn"
export FAKE_OUT_TN="$WORK/tn.out" NOTIFY_TERMINAL_NOTIFIER="$WORK/fake-tn"
printf '%s' "$(hook_json Notification "$R" n5)" | "$BIN/notify.sh" done "ok"
out=$(cat "$FAKE_OUT_TN")
assert_contains "terminal-notifier: title has repo name" "$out" "notifyrepo (main): Done"
assert_contains "terminal-notifier: -activate Claude desktop bundle id" "$out" "com.anthropic.claudefordesktop"
NOTIFY_ACTIVATE=com.microsoft.VSCode bash -c "printf '%s' '$(hook_json Notification "$R" n6)' | '$BIN/notify.sh' done ok"
assert_contains "NOTIFY_ACTIVATE overrides the click target" "$(cat "$FAKE_OUT_TN")" "com.microsoft.VSCode"

# idle de-dup: a Stop notification a moment ago suppresses the idle_prompt one
export NOTIFY_DRY_RUN=1; : >"$LOG"; rm -f "$AGENT_HOME/notify/"*.last
printf '%s' "$(hook_json Stop "$R" dd1)" | "$BIN/notify.sh" done "finished"
printf '%s' "$(hook_json Notification "$R" dd1)" | "$BIN/notify.sh" idle
assert_eq "idle right after done is suppressed" "1" "$(wc -l <"$LOG" | tr -d ' ')"
printf '%s' "$(hook_json Notification "$R" dd2)" | "$BIN/notify.sh" idle
assert_eq "idle for a session with no prior notice is delivered" "2" "$(wc -l <"$LOG" | tr -d ' ')"
assert_contains "idle label" "$(tail -1 "$LOG")" "Waiting"
exit 0
