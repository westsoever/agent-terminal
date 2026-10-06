#!/usr/bin/env bash
# notify.sh: repo/folder name in title, terminal-notifier -> osascript fallback, idle de-dup.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
export NOTIFY_NOW; NOTIFY_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 12:00:00" +%s)

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
printf '%s' "$(hook_json Notification "$R" n5)" | "$BIN/notify.sh" blocked "ok"
out=$(cat "$FAKE_OUT_TN")
assert_contains "terminal-notifier: title has repo name" "$out" "notifyrepo (main): Blocked"
assert_contains "terminal-notifier: -activate Claude desktop bundle id" "$out" "com.anthropic.claudefordesktop"
NOTIFY_ACTIVATE=com.microsoft.VSCode bash -c "printf '%s' '$(hook_json Notification "$R" n6)' | '$BIN/notify.sh' blocked ok"
assert_contains "NOTIFY_ACTIVATE overrides the click target" "$(cat "$FAKE_OUT_TN")" "com.microsoft.VSCode"

# idle de-dup: a Stop notification a moment ago suppresses the idle_prompt one
export NOTIFY_DRY_RUN=1; : >"$LOG"; rm -f "$AGENT_HOME/notify/"*.last
printf '%s' "$(hook_json Stop "$R" dd1)" | "$BIN/notify.sh" done "finished"
printf '%s' "$(hook_json Notification "$R" dd1)" | "$BIN/notify.sh" idle
assert_eq "idle right after done is suppressed" "1" "$(wc -l <"$LOG" | tr -d ' ')"
printf '%s' "$(hook_json Notification "$R" dd2)" | "$BIN/notify.sh" idle
assert_eq "idle for a session with no prior notice is delivered" "2" "$(wc -l <"$LOG" | tr -d ' ')"
assert_contains "idle label" "$(tail -1 "$LOG")" "Waiting"

# ---------- routing and budget (Phase 1.5) ----------
export NOTIFY_DRY_RUN=1; : >"$LOG"; rm -rf "$AGENT_HOME/notify"
NOON=$(date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-05 12:00:00" +%s)
nt() { printf '%s' "$(hook_json Notification "$R" "$1")" | NOTIFY_NOW=${3:-$NOON} "$BIN/notify.sh" "$2" "m"; }
nt r1 done
assert_contains "done goes to the inbox, not a push" "$(tail -1 "$LOG")" $'\tinbox\t'
nt r2 blocked
assert_contains "blocked is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
for s in b1 b2 b3 b4; do nt "$s" stall; done
assert_eq "four budgeted alerts delivered" "4" "$(grep -c $'\tdry-run\t.*Stalled' "$LOG")"
nt b5 stall
assert_contains "fifth budgeted alert is suppressed" "$(tail -1 "$LOG")" "suppressed:daily-budget"
nt b6 input
assert_contains "urgent bypasses an exhausted budget" "$(tail -1 "$LOG")" $'\tdry-run\t'
rm -rf "$AGENT_HOME/notify"
nt q1 stall $((NOON + 10 * 3600))
assert_contains "budgeted alert at 22:00 waits" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
nt q2 blocked $((NOON + 10 * 3600))
assert_contains "urgent alert at 22:00 is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
# Review Focus 2: boundaries
rm -rf "$AGENT_HOME/notify"
nt q3 stall $((NOON - 3 * 3600))
assert_contains "budgeted alert at exactly 09:00 is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt q4 stall $((NOON + 9 * 3600))
assert_contains "budgeted alert at exactly 21:00 waits" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
rm -rf "$AGENT_HOME/notify"
nt c1 stall
nt c1 tokens $((NOON + 600))
assert_contains "second budgeted alert within 45 min is suppressed" "$(tail -1 "$LOG")" "suppressed:cooldown"
nt c1 tokens $((NOON + 46 * 60))
assert_contains "after the cooldown it is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
# handoff is the alert worth keeping (context almost full, once per crossing of 80%): it is not counted
# against the daily budget and does not start or obey the per-session cooldown. Quiet hours still apply.
rm -rf "$AGENT_HOME/notify"
for s in h1 h2 h3 h4; do nt "$s" stall; done
nt h5 handoff
assert_contains "handoff is delivered with the daily budget used up" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt h5 stall
assert_contains "a stall for that session is still suppressed by the daily budget" "$(tail -1 "$LOG")" "suppressed:daily-budget"
assert_eq "handoff did not use any of the daily budget" "4" "$(cat "$AGENT_HOME/notify/budget-2026-10-05")"
rm -rf "$AGENT_HOME/notify"
nt h6 handoff
nt h6 stall $((NOON + 60))
assert_contains "handoff does not start the cooldown for the next alert" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt h6b stall; nt h6b handoff $((NOON + 120))
assert_contains "handoff ignores the cooldown a stall just started" "$(tail -1 "$LOG")" $'\tdry-run\t'
assert_eq "only the stalls used the budget" "2" "$(cat "$AGENT_HOME/notify/budget-2026-10-05")"
# but handoff has its own per-session cooldown (NOTIFY_HANDOFF_COOLDOWN_MINS, default 120): a context level
# that wobbles around 80% must not push a notice every time it crosses again
rm -rf "$AGENT_HOME/notify"
nt h8 handoff
nt h8 handoff $((NOON + 60))
assert_contains "a second handoff for the session within 2 h is suppressed" "$(tail -1 "$LOG")" "suppressed:handoff-cooldown"
nt h9 handoff $((NOON + 60))
assert_contains "the handoff cooldown is per session" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt h8 handoff $((NOON + 2 * 3600 + 60))
assert_contains "after 2 h the handoff is delivered again" "$(tail -1 "$LOG")" $'\tdry-run\t'
printf '%s' "$(hook_json Notification "$R" h10)" | NOTIFY_NOW=$NOON NOTIFY_HANDOFF_COOLDOWN_MINS=1 "$BIN/notify.sh" handoff m
printf '%s' "$(hook_json Notification "$R" h10)" | NOTIFY_NOW=$((NOON + 61)) NOTIFY_HANDOFF_COOLDOWN_MINS=1 "$BIN/notify.sh" handoff m
assert_contains "NOTIFY_HANDOFF_COOLDOWN_MINS sets the handoff cooldown" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt h11 handoff $((NOON - 3 * 3600 - 60))
nt h11 handoff $((NOON - 3 * 3600))
assert_contains "a handoff held back by quiet hours does not start the cooldown" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt h7 handoff $((NOON + 10 * 3600))
assert_contains "handoff at 22:00 waits for the morning" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
nt h7 handoff $((NOON - 3 * 3600 - 60))
assert_contains "handoff at 08:59 waits too" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
rm -rf "$AGENT_HOME/notify"; mkdir -p "$AGENT_HOME/notify"; echo garbage >"$AGENT_HOME/notify/budget-2026-10-05"
nt k1 stall
assert_contains "corrupt budget file counts as 0" "$(tail -1 "$LOG")" $'\tdry-run\t'
printf '%s' "$(hook_json Notification "$R" pd1)" | NOTIFY_NOW=$NOON NOTIFY_PUSH_DONE=1 "$BIN/notify.sh" done m
assert_contains "NOTIFY_PUSH_DONE=1 pushes done" "$(tail -1 "$LOG")" $'\tdry-run\t'
assert_contains "stall label" "$(grep -m1 Stalled "$LOG")" "notifyrepo (main): Stalled"
EVF="$AGENT_HOME/events.jsonl"
assert_contains "events: suppressed alert with reason" "$(jq -r 'select(.kind=="notify" and .data.outcome=="suppressed") | .data.reason' "$EVF")" "daily-budget"
assert_contains "events: inbox routing" "$(jq -r 'select(.kind=="notify") | .data.reason' "$EVF")" "routed-to-inbox"

# ---------- fix wave FC1-3: when the hour cannot be read the quiet-hours check fails closed ----------
# A `date` that rejects -r (a non-BSD date on PATH) used to leave the hour empty and let the alert through.
mkdir -p "$WORK/shim-noclock"
cat >"$WORK/shim-noclock/date" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in -r) exit 1 ;; esac
exec /bin/date "$@"
EOS
chmod +x "$WORK/shim-noclock/date"
rm -rf "$AGENT_HOME/notify"; : >"$LOG"
printf '%s' "$(hook_json Notification "$R" nc1)" | PATH="$WORK/shim-noclock:$PATH" NOTIFY_NOW=$NOON "$BIN/notify.sh" stall m 2>"$WORK/nc.err"
assert_contains "no clock: a budgeted alert is suppressed as no-clock" "$(tail -1 "$LOG")" "suppressed:no-clock"
assert_eq "no clock: nothing is delivered" "0" "$(grep -c $'\tdry-run\t' "$LOG" || true)"
assert_eq "no clock: no budget is booked" "0" "$(ls "$AGENT_HOME/notify" | grep -c '^budget' || true)"
assert_no_file "no clock: no cooldown is booked" "$AGENT_HOME/notify/nc1.budgeted"
assert_eq "no clock: no error output" "" "$(cat "$WORK/nc.err")"
assert_contains "no clock: the event carries the reason" "$(jq -r 'select(.kind=="notify") | .data.reason' "$EVF" | tail -1)" "no-clock"
printf '%s' "$(hook_json Notification "$R" nc2)" | PATH="$WORK/shim-noclock:$PATH" NOTIFY_NOW=$NOON "$BIN/notify.sh" blocked m
assert_contains "no clock: an urgent alert is still delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
exit 0
