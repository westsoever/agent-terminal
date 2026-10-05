#!/usr/bin/env bash
# SessionStart / UserPromptSubmit / SessionEnd / PreCompact in repos, plain folders and ~.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# --- repo that opted in (has .agent/GOAL.md) ---
R=$(mk_repo repo1)
write_goal "$R" "true"
printf '# State\nstatus: working\n\n## Done\n- shipped the widget\n' >"$R/.agent/STATE.md"
printf '# Next\nDo the thing with MARKER-NEXT-123\n' >"$R/.agent/NEXT.md"
out=$(run_hook session-start.sh "$(hook_json SessionStart "$R" s-repo '{"source":"startup","transcript_path":"/x/y.jsonl"}')")
assert_eq "repo: valid JSON, SessionStart event" "SessionStart" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
assert_contains "repo: STATE.md injected" "$ctx" "shipped the widget"
assert_contains "repo: NEXT.md injected" "$ctx" "MARKER-NEXT-123"
assert_contains "repo: GOAL.md injected" "$ctx" "test_command: true"
assert_contains "repo: names the repo" "$ctx" "repo1"
meta="$AGENT_HOME/sessions/s-repo/meta"
assert_file "repo: registry meta written" "$meta"
assert_contains "repo: meta has cwd" "$(cat "$meta")" "cwd=$(cd "$R" && pwd -P)"
assert_contains "repo: meta state working" "$(cat "$meta")" "state=working"
assert_contains "repo: meta keeps transcript path" "$(cat "$meta")" "transcript=/x/y.jsonl"

# retry counter is cleared on (re)start
mkdir -p "$AGENT_HOME/sessions/s-repo"; echo 3 >"$AGENT_HOME/sessions/s-repo/retries"
run_hook session-start.sh "$(hook_json SessionStart "$R" s-repo '{"source":"resume"}')" >/dev/null
assert_no_file "resume resets the retry counter" "$AGENT_HOME/sessions/s-repo/retries"

# --- plain non-git folder, nothing saved yet ---
P="$WORK/plainfolder"; mkdir -p "$P"
out=$(run_hook session-start.sh "$(hook_json SessionStart "$P" s-plain '{"source":"startup"}')")
ctx=$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)
assert_contains "non-git: still works and names the folder" "$ctx" "plainfolder"
assert_contains "non-git: points at machine-level state dir" "$ctx" "$AGENT_HOME/sessions/s-plain"
assert_not_contains "non-git: injects no files that do not exist" "$ctx" "## $AGENT_HOME/sessions/s-plain/STATE.md"
assert_contains "non-git: meta has no root" "$(cat "$AGENT_HOME/sessions/s-plain/meta")" "root="
# resumed session finds the state it wrote
printf '# State\n## Done\n- RESUMED-STATE-77\n' >"$AGENT_HOME/sessions/s-plain/STATE.md"
out=$(run_hook session-start.sh "$(hook_json SessionStart "$P" s-plain '{"source":"resume"}')")
assert_contains "non-git: resume injects session STATE.md" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "RESUMED-STATE-77"

# --- cwd is the home directory ---
out=$(run_hook session-start.sh "$(hook_json SessionStart "$HOME" s-home '{"source":"startup"}')")
assert_eq "home: hook succeeds with valid JSON" "SessionStart" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
assert_contains "home: session is named ~" "$(cat "$AGENT_HOME/sessions/s-home/meta")" "name=~"

# --- machine defaults GOAL.md is injected when there is no repo GOAL ---
mkdir -p "$AGENT_HOME/defaults"; printf '# Defaults\nDEFAULT-GOAL-LINE\n' >"$AGENT_HOME/defaults/GOAL.md"
out=$(run_hook session-start.sh "$(hook_json SessionStart "$P" s-def '{}')")
assert_contains "defaults GOAL.md injected for non-repo sessions" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.additionalContext)" "DEFAULT-GOAL-LINE"
rm -rf "$AGENT_HOME/defaults"

# --- no session id: a stable fallback key from the cwd ---
run_hook session-start.sh "$(jq -n --arg c "$P" '{cwd:$c}')" >/dev/null
assert_ok "missing session_id falls back to a cwd-keyed record" bash -c "ls '$AGENT_HOME'/sessions | grep -q '^nosession-'"

# --- touch / end ---
run_hook session-start.sh "$(hook_json UserPromptSubmit "$P" s-plain)" >/dev/null 2>&1
bash -c "printf '%s' '$(hook_json SessionEnd "$P" s-plain)' | '$BIN/session-start.sh' end"
assert_contains "SessionEnd marks the session ended" "$(cat "$AGENT_HOME/sessions/s-plain/meta")" "state=ended"
printf '%s' "$(hook_json UserPromptSubmit "$P" s-plain)" | "$BIN/session-start.sh" touch
assert_contains "UserPromptSubmit marks it working again" "$(cat "$AGENT_HOME/sessions/s-plain/meta")" "state=working"

# --- PreCompact ---
echo "dirty" >"$R/dirty.txt"
run_hook pre-compact.sh "$(hook_json PreCompact "$R" s-repo)"
st=$(cat "$R/.agent/STATE.md")
assert_contains "precompact(repo): snapshot written into repo STATE.md" "$st" "ching:snapshot:begin"
assert_contains "precompact(repo): branch recorded" "$st" "branch: main"
assert_contains "precompact(repo): uncommitted file listed" "$st" "dirty.txt"
assert_contains "precompact(repo): narrative content preserved" "$st" "shipped the widget"
run_hook pre-compact.sh "$(hook_json PreCompact "$R" s-repo)"
assert_eq "precompact is idempotent (one snapshot block)" "1" "$(grep -c 'ching:snapshot:begin' "$R/.agent/STATE.md")"
run_hook pre-compact.sh "$(hook_json PreCompact "$P" s-plain)"
assert_contains "precompact(non-git): snapshot in session STATE.md" "$(cat "$AGENT_HOME/sessions/s-plain/STATE.md")" "not a git repository"
assert_contains "precompact(non-git): earlier notes preserved" "$(cat "$AGENT_HOME/sessions/s-plain/STATE.md")" "RESUMED-STATE-77"
run_hook pre-compact.sh "$(hook_json PreCompact "$HOME" s-home)"
assert_file "precompact(home): works in ~" "$AGENT_HOME/sessions/s-home/STATE.md"

# --- a repo WITHOUT .agent/GOAL.md uses machine-level state, not repo state ---
R2=$(mk_repo repo2)
run_hook session-start.sh "$(hook_json SessionStart "$R2" s-r2 '{}')" >/dev/null
assert_no_file "repo without GOAL.md gets no .agent/ dir created" "$R2/.agent/STATE.md"
assert_file "repo without GOAL.md is still registered" "$AGENT_HOME/sessions/s-r2/meta"

# ---------- events (Phase 1.5) ----------
EVF="$AGENT_HOME/events.jsonl"
ER=$(mk_repo evrepo)
run_hook session-start.sh "$(hook_json SessionStart "$ER" s-ev '{"source":"startup"}')" >/dev/null
assert_eq "events: session_start with source" "startup" "$(jq -r 'select(.kind=="session_start" and .sid=="s-ev") | .data.source' "$EVF")"
printf '%s' "$(hook_json UserPromptSubmit "$ER" s-ev)" | "$BIN/session-start.sh" touch
assert_contains "touch writes prompted to meta" "$(cat "$AGENT_HOME/sessions/s-ev/meta")" "prompted="
assert_eq "events: prompt" "1" "$(jq -r 'select(.kind=="prompt" and .sid=="s-ev") | .kind' "$EVF" | wc -l | tr -d ' ')"
run_hook pre-compact.sh "$(hook_json PreCompact "$ER" s-ev '{"trigger":"auto"}')"
assert_eq "events: compact with trigger" "auto" "$(jq -r 'select(.kind=="compact" and .sid=="s-ev") | .data.trigger' "$EVF")"
printf '%s' "$(hook_json SessionEnd "$ER" s-ev)" | "$BIN/session-start.sh" end
assert_eq "events: session_end" "1" "$(jq -r 'select(.kind=="session_end" and .sid=="s-ev") | .kind' "$EVF" | wc -l | tr -d ' ')"
assert_eq "events: name is the repo" "evrepo" "$(jq -r 'select(.sid=="s-ev") | .name' "$EVF" | sort -u)"
exit 0
