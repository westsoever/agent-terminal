#!/usr/bin/env bash
# Phase 3 (voice level A): the /dash slash command and docs/voice.md. No test calls a voice tool or plays audio.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CMD="$KIT/commands/dash.md"
assert_file "3.2: commands/dash.md exists" "$CMD"
body=$(cat "$CMD" 2>/dev/null || true)
fm=$(awk 'NR == 1 && $0 == "---" { f = 1; next } f && $0 == "---" { exit } f { print }' "$CMD")
assert_contains "3.2: frontmatter has a description" "$fm" "description:"
assert_contains "3.2: frontmatter allows dash.sh through Bash" "$fm" "Bash(~/.claude/ching/bin/dash.sh:*)"
assert_contains "3.2: frontmatter allows converse (MCP server name)" "$fm" "mcp__voicemode__converse"
assert_contains "3.2: frontmatter allows converse (plugin name)" "$fm" "mcp__plugin_voicemode_voicemode__converse"
assert_not_contains "3.2: no broad Bash allowance" "$fm" "Bash(*"
assert_contains "3.2: runs the installed dash.sh" "$body" "~/.claude/ching/bin/dash.sh"
assert_contains "3.2: default mode is the spoken summary" "$body" "dash.sh --speak"
assert_contains "3.2: speaks without listening" "$body" "wait_for_response"
assert_contains "3.2: a refused or missing voice is not retried" "$body" "currently holds the voice channel"
assert_contains "3.2: only listed flags reach the shell" "$body" "only these flags"
assert_contains "3.2: --inbox side effect is stated" "$body" "marks FINISHED as seen"
assert_contains "3.2: --text prints without speaking" "$body" '`--text`'
# every flag the command can hand to dash.sh is one dash.sh accepts (nothing here speaks: dash.sh only prints)
for fl in --speak --inbox --next --all; do
  assert_contains "3.2: command names $fl" "$body" "\`$fl\`"
  out=$("$BIN/dash.sh" "$fl" 2>&1); rc=$?
  assert_eq "3.2: dash.sh $fl exits 0 on an empty machine" "0" "$rc"
done
assert_contains "3.2: dash.sh --speak output is a plain sentence" "$("$BIN/dash.sh" --speak)" "No Claude sessions"
# --text is the command's own word, never passed to dash.sh
assert_fails "3.2: dash.sh itself rejects --text, so the command must map it" "$BIN/dash.sh" --text

# the installer links every file in commands/, so a new command needs no installer edit
D="$WORK/voice-claude"; mkdir -p "$D"; printf '{}\n' >"$D/settings.json"
out=$(env SETTINGS_FILE="$D/settings.json" CLAUDE_DIR="$D" AGENT_REPOS_FILE="$WORK/voice-repos" LAUNCH_AGENTS_DIR="$WORK/voice-la" "$KIT/install.sh" --yes </dev/null 2>&1)
assert_eq "3.2: install links the dash command" "$KIT/commands/dash.md" "$(readlink "$D/commands/dash.md")"
for c in "$KIT"/commands/*.md; do
  assert_eq "install links $(basename "$c")" "$c" "$(readlink "$D/commands/$(basename "$c")")"
done

# docs/voice.md (3.3)
V="$KIT/docs/voice.md"
assert_file "3.3: docs/voice.md exists" "$V"
vb=$(cat "$V" 2>/dev/null || true)
assert_contains "3.3: covers the /voice push-to-talk fallback" "$vb" "/voice"
assert_contains "3.3: says /voice is dictation only (no spoken replies)" "$vb" "dictation"
assert_contains "3.3: shows how to hear the status" "$vb" "/dash"
assert_contains "3.3: names the voice lock" "$vb" "conch"
assert_contains "3.3: says workers stay silent" "$vb" "silent"
exit 0
