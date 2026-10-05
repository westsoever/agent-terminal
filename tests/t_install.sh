#!/usr/bin/env bash
# install.sh against a fixture settings.json under the settings override: dry run, apply, idempotence,
# popup opt-in, uninstall, and the installed hook commands actually working through the symlink.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

D="$WORK/fixture-claude"; mkdir -p "$D"
VS="/Users/someone/.claude/vscode-session-manager-hook.sh"
cat >"$D/settings.json" <<EOS
{
  "env": {"X": "1"},
  "permissions": {"allow": ["mcp__pencil"], "defaultMode": "bypassPermissions"},
  "hooks": {
    "SessionEnd": [{"hooks": [{"type": "command", "command": "python3 ~/title.py", "timeout": 60}]},
                   {"matcher": "", "hooks": [{"type": "command", "command": "$VS end"}]}],
    "Stop": [{"matcher": "", "hooks": [{"type": "command", "command": "$VS stop"},
                                       {"type": "command", "command": "osascript -e 'display notification \"Session finished\" with title \"Claude Code\"'", "timeout": 5}]}],
    "PreToolUse": [{"matcher": "", "hooks": [{"type": "command", "command": "$VS resume"}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command", "command": "$VS start"}]}],
    "Notification": [{"matcher": "idle_prompt", "hooks": [{"type": "command", "command": "$VS stop"}]}]
  },
  "statusLine": {"type": "command", "command": "sh ~/statusline.sh"}
}
EOS
export SETTINGS_FILE="$D/settings.json"
unset CLAUDE_DIR
export AGENT_REPOS_FILE="$WORK/fixture-agent-repos"
sum() { shasum -a 256 "$SETTINGS_FILE" | cut -d' ' -f1; }
inst() { "$KIT/install.sh" "$@" </dev/null 2>&1; }
BEFORE=$(sum)

# dry run: shows a diff, writes nothing
out=$(inst --dry-run); rc=$?
assert_eq "dry-run exits 0" "0" "$rc"
assert_contains "dry-run shows a unified diff" "$out" "+++ $D/settings.json (after install)"
assert_contains "dry-run lists the guard hook" "$out" "$D/ching/bin/guard.sh"
assert_eq "dry-run: settings untouched" "$BEFORE" "$(sum)"
assert_no_file "dry-run: no symlink" "$D/ching"
assert_no_file "dry-run: no backup" "$(ls "$D"/settings.json.bak.ching.* 2>/dev/null | head -1)"
assert_no_file "dry-run: no ~/.agent-repos" "$AGENT_REPOS_FILE"

# non-interactive apply needs --yes
out=$(inst); rc=$?
assert_eq "no tty and no --yes: refuses" "1" "$rc"
assert_eq "refusal leaves settings untouched" "$BEFORE" "$(sum)"

# apply
out=$(inst --yes); assert_eq "apply exits 0" "0" "$?"
S=$(cat "$SETTINGS_FILE")
for ev in SessionStart UserPromptSubmit SessionEnd PreCompact Stop PreToolUse Notification; do
  n=$(printf '%s' "$S" | jq --arg e "$ev" '[.hooks[$e][]?.hooks[]?.command | select(contains("/ching/bin/"))] | length')
  assert_eq "hook added for $ev" "1" "$n"
done
assert_eq "guard matcher covers Bash, Read, Edit, Supabase MCP" "Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*" \
  "$(printf '%s' "$S" | jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("guard.sh")) | .matcher')"
assert_eq "Notification entry uses the idle_prompt matcher" "idle_prompt" "$(printf '%s' "$S" | jq -r '.hooks.Notification[] | select(.hooks[0].command | contains("notify.sh")) | .matcher')"
assert_eq "vscode-session-manager entries untouched (5 of them)" "5" "$(printf '%s' "$S" | jq --arg v "$VS" '[.. | objects | select(.command? != null) | select(.command | startswith($v))] | length')"
assert_eq "popup still present by default" "1" "$(printf '%s' "$S" | jq '[.. | objects | select(.command? != null) | select(.command | contains("Session finished"))] | length')"
assert_eq "non-hook settings untouched" "$(printf '%s' "$(cat "$D/settings.json.bak.ching."*)" | jq -S -c 'del(.hooks)')" "$(printf '%s' "$S" | jq -S -c 'del(.hooks)')"
assert_eq "exactly one backup" "1" "$(ls "$D"/settings.json.bak.ching.* | wc -l | tr -d ' ')"
assert_eq "ching symlink points at the kit" "$KIT" "$(readlink "$D/ching")"
assert_eq "handoff command linked" "$KIT/commands/handoff.md" "$(readlink "$D/commands/handoff.md")"
assert_eq "next command linked" "$KIT/commands/next.md" "$(readlink "$D/commands/next.md")"
assert_file "optional ~/.agent-repos created" "$AGENT_REPOS_FILE"
assert_not_contains "~/.agent-repos starts with no active repo" "$(grep -v '^#' "$AGENT_REPOS_FILE")" "/"

# idempotence: running twice changes nothing
AFTER=$(sum)
out=$(inst --yes); assert_eq "second run exits 0" "0" "$?"
assert_contains "second run reports nothing to do" "$out" "nothing to do"
assert_eq "second run: settings byte-identical" "$AFTER" "$(sum)"
assert_eq "second run: still one backup" "1" "$(ls "$D"/settings.json.bak.ching.* | wc -l | tr -d ' ')"
out=$(inst --yes --dry-run); assert_contains "dry-run after install: nothing to do" "$out" "nothing to do"

# installed commands work through the symlink path that settings.json references
GCMD=$(printf '%s' "$S" | jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("guard.sh")) | .hooks[0].command')
out=$(printf '%s' "$(bash_json "$WORK" 'git push --force origin x')" | $GCMD)
assert_contains "installed guard command denies through the symlink" "$out" '"permissionDecision": "deny"'
out=$(printf '%s' "$(bash_json "$WORK" 'ls')" | $GCMD); assert_eq "installed guard command allows ls" "" "$out"
SCMD=$(printf '%s' "$S" | jq -r '.hooks.SessionStart[] | select(.hooks[0].command | contains("ching")) | .hooks[0].command')
out=$(printf '%s' "$(hook_json SessionStart "$WORK" via-install '{}')" | $SCMD)
assert_eq "installed SessionStart command runs through the symlink" "SessionStart" "$(printf '%s' "$out" | jq -r .hookSpecificOutput.hookEventName)"
TCMD=$(printf '%s' "$S" | jq -r '.hooks.UserPromptSubmit[] | select(.hooks[0].command | contains("ching")) | .hooks[0].command')
printf '%s' "$(hook_json UserPromptSubmit "$WORK" via-install)" | $TCMD
assert_contains "installed touch hook works" "$(cat "$AGENT_HOME/sessions/via-install/meta")" "state=working"

# --replace-popup is opt-in and removes only the popup
out=$(inst --yes --replace-popup); assert_eq "--replace-popup exits 0" "0" "$?"
S=$(cat "$SETTINGS_FILE")
assert_eq "popup removed with the flag" "0" "$(printf '%s' "$S" | jq '[.. | objects | select(.command? != null) | select(.command | contains("Session finished"))] | length')"
assert_eq "vscode entries still all there" "5" "$(printf '%s' "$S" | jq --arg v "$VS" '[.. | objects | select(.command? != null) | select(.command | startswith($v))] | length')"
assert_eq "ching Stop hook still there" "1" "$(printf '%s' "$S" | jq '[.hooks.Stop[].hooks[] | select(.command | contains("stop-check.sh"))] | length')"
AFTER=$(sum); inst --yes --replace-popup >/dev/null; assert_eq "--replace-popup is idempotent" "$AFTER" "$(sum)"

# uninstall removes only our entries
out=$(inst --uninstall --yes); assert_eq "uninstall exits 0" "0" "$?"
S=$(cat "$SETTINGS_FILE")
assert_eq "uninstall: no ching entries left" "0" "$(printf '%s' "$S" | jq '[.. | objects | select(.command? != null) | select(.command | contains("/ching/bin/"))] | length')"
assert_eq "uninstall: vscode entries kept" "5" "$(printf '%s' "$S" | jq --arg v "$VS" '[.. | objects | select(.command? != null) | select(.command | startswith($v))] | length')"
assert_eq "uninstall: empty events removed" "false" "$(printf '%s' "$S" | jq 'has("hooks") and (.hooks | has("PreCompact"))')"

# a fresh machine: settings.json absent
rm -rf "$D" "$WORK/fixture-agent-repos"; mkdir -p "$D"; rm -f "$SETTINGS_FILE"
out=$(inst --yes); assert_eq "no settings.json yet: created" "0" "$?"
assert_eq "created file is valid and has the hooks" "7" "$(jq '[.hooks | to_entries[] | .key] | length' "$SETTINGS_FILE")"
# the real settings file is never the target in tests
assert_not_contains "tests never reference the real settings path" "$(cat "$D/settings.json")" "/Users/clyde/.claude"
exit 0
