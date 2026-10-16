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
LA="$LAUNCH_AGENTS_DIR/org.ching.watch.plist"   # LAUNCH_AGENTS_DIR is exported by lib.sh

# dry run: shows a diff, writes nothing
out=$(inst --dry-run); rc=$?
assert_eq "dry-run exits 0" "0" "$rc"
assert_contains "dry-run shows a unified diff" "$out" "+++ $D/settings.json (after install)"
assert_contains "dry-run lists the guard hook" "$out" "$D/ching/bin/guard.sh"
assert_eq "dry-run: settings untouched" "$BEFORE" "$(sum)"
assert_no_file "dry-run: no symlink" "$D/ching"
assert_no_file "dry-run: no backup" "$(ls "$D"/settings.json.bak.ching.* 2>/dev/null | head -1)"
assert_no_file "dry-run: no ~/.agent-repos" "$AGENT_REPOS_FILE"
assert_contains "dry-run lists the plist write and load" "$out" "would: write $LA and launchctl bootstrap it"
assert_contains "dry-run shows the plist diff header" "$out" "+++ $LA (after install)"
assert_contains "dry-run plist diff shows the interval" "$out" "+  <key>StartInterval</key><integer>300</integer>"
assert_contains "dry-run plist diff shows the script path" "$out" "$D/ching/bin/ching-watch.sh"
assert_no_file "dry-run: no plist" "$LA"
assert_no_file "dry-run: launchctl never called" "$WORK/launchctl.log"

# non-interactive apply needs --yes
out=$(inst); rc=$?
assert_eq "no tty and no --yes: refuses" "1" "$rc"
assert_eq "refusal leaves settings untouched" "$BEFORE" "$(sum)"
assert_contains "refusal says it needs a terminal or --yes" "$out" "not a terminal"
assert_contains "refusal previews the plist write" "$out" "would: write $LA and launchctl bootstrap it"
assert_contains "refusal shows the plist diff" "$out" "+++ $LA (after install)"
assert_no_file "refusal: no plist written" "$LA"
assert_no_file "refusal: launchctl never called" "$WORK/launchctl.log"
assert_no_file "refusal: no symlink" "$D/ching"

# apply
out=$(inst --yes); assert_eq "apply exits 0" "0" "$?"
S=$(cat "$SETTINGS_FILE")
for ev in SessionStart UserPromptSubmit SessionEnd PreCompact Stop PreToolUse Notification; do
  n=$(printf '%s' "$S" | jq --arg e "$ev" '[.hooks[$e][]?.hooks[]?.command | select(contains("/ching/bin/"))] | length')
  assert_eq "hook added for $ev" "1" "$n"
done
assert_eq "guard matcher covers Bash, Monitor, Read, Edit, Supabase and messaging MCP" "Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|Monitor|mcp__.*[Ss]upabase.*|mcp__.*([Gg]mail|[Ss]lack|[Dd]iscord|[Tt]elegram).*" \
  "$(printf '%s' "$S" | jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("guard.sh")) | .matcher')"
assert_eq "Notification entry uses the idle_prompt matcher" "idle_prompt" "$(printf '%s' "$S" | jq -r '.hooks.Notification[] | select(.hooks[0].command | contains("notify.sh")) | .matcher')"
assert_eq "vscode-session-manager entries untouched (5 of them)" "5" "$(printf '%s' "$S" | jq --arg v "$VS" '[.. | objects | select(.command? != null) | select(.command | startswith($v))] | length')"
assert_eq "popup still present by default" "1" "$(printf '%s' "$S" | jq '[.. | objects | select(.command? != null) | select(.command | contains("Session finished"))] | length')"
assert_eq "non-hook, non-allowlist settings untouched" "$(printf '%s' "$(cat "$D/settings.json.bak.ching."*)" | jq -S -c 'del(.hooks, .permissions.allow)')" "$(printf '%s' "$S" | jq -S -c 'del(.hooks, .permissions.allow)')"

# ---------- voice permissions (Phase 3.1): converse is allowed, nothing else is added ----------
CONV1=mcp__voicemode__converse; CONV2=mcp__plugin_voicemode_voicemode__converse
assert_eq "allowlist: the existing entry stays first, both converse names follow" "mcp__pencil $CONV1 $CONV2" "$(printf '%s' "$S" | jq -r '.permissions.allow | join(" ")')"
assert_eq "allowlist: defaultMode untouched" "bypassPermissions" "$(printf '%s' "$S" | jq -r '.permissions.defaultMode')"
assert_eq "allowlist: no deny list appears" "null" "$(printf '%s' "$S" | jq -c '.permissions.deny')"
assert_contains "apply output: the diff names the allowlist addition" "$out" "+      \"$CONV1\""
assert_eq "exactly one backup" "1" "$(ls "$D"/settings.json.bak.ching.* | wc -l | tr -d ' ')"
KITP=$(cd "$KIT" && pwd -P)   # install.sh links the physical path; a kit under a symlinked folder (/tmp) must not fail
assert_eq "ching symlink points at the kit" "$KITP" "$(readlink "$D/ching")"
assert_eq "handoff command linked" "$KITP/commands/handoff.md" "$(readlink "$D/commands/handoff.md")"
assert_eq "next command linked" "$KITP/commands/next.md" "$(readlink "$D/commands/next.md")"
assert_eq "dash command linked" "$KITP/commands/dash.md" "$(readlink "$D/commands/dash.md")"
assert_file "optional ~/.agent-repos created" "$AGENT_REPOS_FILE"
assert_not_contains "~/.agent-repos starts with no active repo" "$(grep -v '^#' "$AGENT_REPOS_FILE")" "/"

# idempotence: running twice changes nothing
AFTER=$(sum)
out=$(inst --yes); assert_eq "second run exits 0" "0" "$?"
assert_contains "second run reports nothing to do" "$out" "nothing to do"
assert_eq "second run: settings byte-identical" "$AFTER" "$(sum)"
assert_eq "second run: still one backup" "1" "$(ls "$D"/settings.json.bak.ching.* | wc -l | tr -d ' ')"
out=$(inst --yes --dry-run); assert_contains "dry-run after install: nothing to do" "$out" "nothing to do"

# ---------- launchd watcher (Phase 1.5) ----------
assert_file "watcher plist installed" "$LA"
assert_contains "plist runs every 300 s" "$(cat "$LA")" "<integer>300</integer>"
assert_contains "plist points at the kit symlink" "$(cat "$LA")" "/ching/bin/ching-watch.sh"
assert_ok "plist is valid XML plist" plutil -lint "$LA"
assert_contains "launchctl bootstrap called" "$(cat "$WORK/launchctl.log")" "bootstrap gui/"
n=$(wc -l <"$WORK/launchctl.log")
inst --yes >/dev/null
assert_eq "re-run with identical plist: launchctl not called again" "$n" "$(wc -l <"$WORK/launchctl.log")"

# Nothing else is out of date, only the plist. Without a tty and without --yes the launchd job is neither
# replaced nor loaded: the run shows the plist diff, says it needs --yes and exits non-zero. --dry-run shows it too.
psum() { shasum -a 256 "$LA" | cut -d' ' -f1; }
GOODP=$(psum)
sed 's|<integer>300</integer>|<integer>999</integer>|' "$LA" >"$LA.t" && mv "$LA.t" "$LA"
BADP=$(psum)
n=$(wc -l <"$WORK/launchctl.log")
out=$(inst); rc=$?
assert_eq "plist differs, no tty and no --yes: refuses" "1" "$rc"
assert_contains "plist-only refusal says it needs a terminal or --yes" "$out" "not a terminal"
assert_contains "plist-only refusal shows the old plist line" "$out" "-  <key>StartInterval</key><integer>999</integer>"
assert_contains "plist-only refusal shows the new plist line" "$out" "+  <key>StartInterval</key><integer>300</integer>"
assert_contains "plist-only refusal previews the replace" "$out" "would: write $LA and launchctl bootstrap it"
assert_eq "plist-only refusal leaves the plist as it was" "$BADP" "$(psum)"
assert_eq "plist-only refusal does not call launchctl" "$n" "$(wc -l <"$WORK/launchctl.log")"
out=$(inst --dry-run); rc=$?
assert_eq "plist differs: dry-run exits 0" "0" "$rc"
assert_contains "plist differs: dry-run shows the diff" "$out" "-  <key>StartInterval</key><integer>999</integer>"
assert_eq "plist differs: dry-run leaves the plist" "$BADP" "$(psum)"
assert_eq "plist differs: dry-run does not call launchctl" "$n" "$(wc -l <"$WORK/launchctl.log")"
rm -f "$LA"
out=$(inst); rc=$?
assert_eq "plist missing, no tty and no --yes: refuses" "1" "$rc"
assert_no_file "plist missing, refused: not recreated" "$LA"
assert_eq "plist missing, refused: launchctl not called" "$n" "$(wc -l <"$WORK/launchctl.log")"
out=$(inst --yes); assert_eq "plist missing: --yes repairs it" "0" "$?"
assert_eq "plist missing: --yes restores the same plist" "$GOODP" "$(psum)"
assert_contains "plist missing: --yes loads it" "$(tail -n +$((n + 1)) "$WORK/launchctl.log")" "bootstrap gui/"
assert_contains "guard matcher covers messaging MCP tools" "$(jq -r '.hooks.PreToolUse[].matcher' "$SETTINGS_FILE")" "[Gg]mail"
jq '(.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh")) | .matcher) = "Bash"' "$SETTINGS_FILE" >"$SETTINGS_FILE.t" && mv "$SETTINGS_FILE.t" "$SETTINGS_FILE"
inst --yes >/dev/null
assert_contains "re-install widens an old guard matcher" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh")) | .matcher' "$SETTINGS_FILE")" "[Ss]lack"
assert_eq "re-install keeps a single guard entry" "1" "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh"))] | length' "$SETTINGS_FILE")"

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

# uninstall needs --yes without a tty too, and then changes nothing (settings, plist, launchd)
BEFOREU=$(sum); n=$(wc -l <"$WORK/launchctl.log")
out=$(inst --uninstall); rc=$?
assert_eq "uninstall: no tty and no --yes refuses" "1" "$rc"
assert_contains "uninstall refusal previews the plist removal" "$out" "would: launchctl bootout and remove $LA"
assert_eq "uninstall refusal leaves settings untouched" "$BEFOREU" "$(sum)"
assert_file "uninstall refusal keeps the plist" "$LA"
assert_eq "uninstall refusal does not call launchctl" "$n" "$(wc -l <"$WORK/launchctl.log")"

# uninstall removes only our entries
out=$(inst --uninstall --yes); assert_eq "uninstall exits 0" "0" "$?"
S=$(cat "$SETTINGS_FILE")
assert_eq "uninstall: no ching entries left" "0" "$(printf '%s' "$S" | jq '[.. | objects | select(.command? != null) | select(.command | contains("/ching/bin/"))] | length')"
assert_eq "uninstall: vscode entries kept" "5" "$(printf '%s' "$S" | jq --arg v "$VS" '[.. | objects | select(.command? != null) | select(.command | startswith($v))] | length')"
assert_eq "uninstall: empty events removed" "false" "$(printf '%s' "$S" | jq 'has("hooks") and (.hooks | has("PreCompact"))')"
assert_eq "uninstall: the converse allowlist entries are left in place" "mcp__pencil $CONV1 $CONV2" "$(printf '%s' "$S" | jq -r '.permissions.allow | join(" ")')"
assert_contains "uninstall: says the allowlist entries stay" "$out" "permissions.allow"
assert_no_file "uninstall removes the watcher plist" "$HOME/Library/LaunchAgents/org.ching.watch.plist"
assert_contains "uninstall boots the watcher out (last launchctl call)" "$(tail -1 "$WORK/launchctl.log")" "bootout gui/"

# a failed launchctl bootstrap must not leave a plist that makes the next run say "nothing to do"
n=$(wc -l <"$WORK/launchctl.log")
out=$(LAUNCHCTL_FAIL_BOOTSTRAP=1 inst --yes); rc=$?
assert_eq "failed bootstrap: install exits non-zero" "nonzero" "$([ "$rc" -ne 0 ] && echo nonzero || echo "$rc")"
assert_contains "failed bootstrap: says so and that the next run retries" "$out" "launchctl bootstrap failed"
assert_no_file "failed bootstrap: plist removed" "$LA"
assert_contains "failed bootstrap: bootstrap was attempted" "$(tail -n +$((n + 1)) "$WORK/launchctl.log")" "bootstrap gui/"
n=$(wc -l <"$WORK/launchctl.log")
out=$(inst --yes); assert_eq "retry after a failed bootstrap exits 0" "0" "$?"
assert_file "retry after a failed bootstrap: plist installed" "$LA"
assert_contains "retry after a failed bootstrap: bootstrap called again" "$(tail -n +$((n + 1)) "$WORK/launchctl.log")" "bootstrap gui/"
# The flag is injected by the environment of one call only. The fake launchctl records every bootstrap it
# failed on purpose: exactly one (the failing call), and the retry above, run without the flag, succeeded.
assert_eq "failure flag: exactly one bootstrap was made to fail" "1" "$(wc -l <"$WORK/launchctl.failed" | tr -d ' ')"
assert_eq "failure flag: not left in the test environment" "" "$(env | grep '^LAUNCHCTL_FAIL_BOOTSTRAP=' || true)"

# uninstall when the plist is already gone: the hooks go, nothing is created, no bootstrap
rm -f "$LA"; n=$(wc -l <"$WORK/launchctl.log")
out=$(inst --uninstall --yes); rc=$?
assert_eq "uninstall with an absent plist exits 0" "0" "$rc"
assert_eq "uninstall with an absent plist: no ching entries left" "0" "$(jq '[.. | objects | select(.command? != null) | select(.command | contains("/ching/bin/"))] | length' "$SETTINGS_FILE")"
assert_no_file "uninstall with an absent plist: no plist appears" "$LA"
assert_no_file "uninstall with an absent plist: no stray temp plist" "$LA.tmp"
assert_not_contains "uninstall with an absent plist: launchctl never bootstraps" "$(tail -n +$((n + 1)) "$WORK/launchctl.log" 2>/dev/null)" "bootstrap"
assert_not_contains "uninstall with an absent plist: no error printed" "$out" "install:"

# a fresh machine: settings.json absent
rm -rf "$D" "$WORK/fixture-agent-repos"; mkdir -p "$D"; rm -f "$SETTINGS_FILE"
out=$(inst --yes); assert_eq "no settings.json yet: created" "0" "$?"
assert_eq "created file is valid and has the hooks" "7" "$(jq '[.hooks | to_entries[] | .key] | length' "$SETTINGS_FILE")"
# the real settings file is never the target in tests
assert_not_contains "tests never reference the real settings path" "$(cat "$D/settings.json")" "/Users/clyde/.claude"

# the allowlist merge on other shapes of settings.json
PD="$WORK/perm-claude"; mkdir -p "$PD"
pinst() { env SETTINGS_FILE="$PD/settings.json" CLAUDE_DIR="$PD" AGENT_REPOS_FILE="$WORK/perm-repos" LAUNCH_AGENTS_DIR="$WORK/perm-la" "$KIT/install.sh" "$@" </dev/null 2>&1; }
printf '{}\n' >"$PD/settings.json"; pinst --yes >/dev/null
assert_eq "allowlist: settings without a permissions key get exactly the two converse names" "$CONV1 $CONV2" "$(jq -r '.permissions.allow | join(" ")' "$PD/settings.json")"
assert_eq "allowlist: nothing else is created under permissions" '["allow"]' "$(jq -c '.permissions | keys' "$PD/settings.json")"
psum() { shasum -a 256 "$PD/settings.json" | cut -d' ' -f1; }
P1=$(psum); pinst --yes >/dev/null
assert_eq "allowlist: a second run leaves the file byte-identical" "$P1" "$(psum)"
printf '{"permissions":{"allow":["Bash(ls)","%s"],"deny":["Bash(rm:*)"]}}\n' "$CONV1" >"$PD/settings.json"; pinst --yes >/dev/null
assert_eq "allowlist: an entry the user already had is not duplicated, the missing one is appended" "Bash(ls) $CONV1 $CONV2" "$(jq -r '.permissions.allow | join(" ")' "$PD/settings.json")"
assert_eq "allowlist: an existing deny list is untouched" '["Bash(rm:*)"]' "$(jq -c '.permissions.deny' "$PD/settings.json")"
printf '{"permissions":{"allow":"mcp__pencil"}}\n' >"$PD/settings.json"; pinst --yes >/dev/null
assert_eq "allowlist: an allow that is not a list is left alone" '"mcp__pencil"' "$(jq -c '.permissions.allow' "$PD/settings.json")"
printf '{"permissions":{"allow":["%s","%s"]}}\n' "$CONV2" "$CONV1" >"$PD/settings.json"; pinst --yes >/dev/null
assert_eq "allowlist: both names already present in another order stay in that order" "$CONV2 $CONV1" "$(jq -r '.permissions.allow | join(" ")' "$PD/settings.json")"

# plist values are XML-escaped: paths with & < > still give a valid plist that carries the real paths
XD="$WORK/x&y<z>"; XA="$WORK/a&b<c>"; XLA="$WORK/la-escape"; mkdir -p "$XD"; printf '{}\n' >"$XD/settings.json"
xinst() { env SETTINGS_FILE="$XD/settings.json" CLAUDE_DIR="$XD" AGENT_HOME="$XA" AGENT_REPOS_FILE="$WORK/escape-repos" LAUNCH_AGENTS_DIR="$XLA" "$KIT/install.sh" "$@" </dev/null 2>&1; }
out=$(xinst --yes); assert_eq "special characters in paths: install exits 0" "0" "$?"
XP="$XLA/org.ching.watch.plist"
assert_ok "special characters: the plist is valid" plutil -lint "$XP"
assert_eq "special characters: AGENT_HOME survives the round trip" "$XA" "$(plutil -extract EnvironmentVariables.AGENT_HOME raw -o - "$XP")"
assert_eq "special characters: the script path survives the round trip" "$XD/ching/bin/ching-watch.sh" "$(plutil -extract ProgramArguments.1 raw -o - "$XP")"
assert_eq "special characters: the log path survives the round trip" "$XA/watch.log" "$(plutil -extract StandardOutPath raw -o - "$XP")"
assert_contains "special characters: the file holds the escaped form" "$(cat "$XP")" "a&amp;b&lt;c&gt;/watch.log"
assert_not_contains "special characters: no raw ampersand-path in the file" "$(cat "$XP")" "a&b"
out=$(xinst --yes); assert_contains "special characters: a second run is a no-op" "$out" "nothing to do"

# the --help header is printed whole, and says what happens without a terminal
help=$("$KIT/install.sh" --help)
assert_contains "help: explains the non-terminal refusal" "$help" "exits 1"
assert_contains "help: ends with the overrides line" "$help" "LAUNCHCTL, LAUNCH_AGENTS_DIR."
assert_not_contains "help: does not print code" "$help" "set -euo pipefail"

# At a terminal the prompt covers everything: settings, symlinks and the launchd job. A pty from script(1) gives
# install.sh a tty on stdin; the answer is sent once the prompt shows (macOS script; skipped where it is missing).
if [ "$(uname)" = Darwin ] && printf '' | script -q /dev/null true >/dev/null 2>&1; then
  TD="$WORK/tty-claude"; TLA="$WORK/tty-la"; mkdir -p "$TD"; printf '{}\n' >"$TD/settings.json"
  tty_inst() { # answer [install.sh args]: run under a pty and answer the prompt
    local ans=$1 i=0; shift
    : >"$WORK/tty.out"
    { while [ "$i" -lt 50 ] && ! grep -q 'Apply these changes' "$WORK/tty.out"; do sleep 0.2; i=$((i + 1)); done
      printf '%s\n' "$ans"; sleep 0.5; } \
      | env SETTINGS_FILE="$TD/settings.json" CLAUDE_DIR="$TD" AGENT_REPOS_FILE="$WORK/tty-repos" LAUNCH_AGENTS_DIR="$TLA" \
        script -q /dev/null "$KIT/install.sh" "$@" >"$WORK/tty.out" 2>&1
  }
  n=$(wc -l <"$WORK/launchctl.log")
  tty_inst n; rc=$?
  assert_eq "tty, answer n: exits 1" "1" "$rc"
  assert_contains "tty, answer n: says aborted" "$(cat "$WORK/tty.out")" "aborted"
  assert_contains "tty: the prompt follows the plist diff" "$(cat "$WORK/tty.out")" "+++ $TLA/org.ching.watch.plist (after install)"
  assert_eq "tty, answer n: settings untouched" "{}" "$(jq -c . "$TD/settings.json")"
  assert_no_file "tty, answer n: no plist" "$TLA/org.ching.watch.plist"
  assert_no_file "tty, answer n: no symlink" "$TD/ching"
  assert_eq "tty, answer n: launchctl not called" "$n" "$(wc -l <"$WORK/launchctl.log")"
  tty_inst y; rc=$?
  assert_eq "tty, answer y: exits 0" "0" "$rc"
  assert_file "tty, answer y: plist written" "$TLA/org.ching.watch.plist"
  assert_eq "tty, answer y: hooks installed" "1" "$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(contains("/ching/bin/guard.sh"))] | length' "$TD/settings.json")"
  assert_contains "tty, answer y: launchctl bootstrap called" "$(tail -n +$((n + 1)) "$WORK/launchctl.log")" "bootstrap gui/"
else
  echo "no usable script(1) pty: tty prompt tests skipped" >"$T_ROOT/skipped.t_install"
fi

# ---------- Phase 6: the learner job (org.ching.learn) and the claude-mem exclusion (D27) ----------
LD="$WORK/learn-claude"; LLA="$WORK/learn-la"; LAH="$WORK/learn-ah"; CMS="$WORK/cm/settings.json"
mkdir -p "$LD" "$WORK/cm"; printf '{}\n' >"$LD/settings.json"
linst() { env SETTINGS_FILE="$LD/settings.json" CLAUDE_DIR="$LD" AGENT_HOME="$LAH" AGENT_REPOS_FILE="$WORK/learn-repos" \
  LAUNCH_AGENTS_DIR="$LLA" CLAUDE_MEM_SETTINGS="$CMS" "$KIT/install.sh" "$@" </dev/null 2>&1; }
LP="$LLA/org.ching.learn.plist"
# claude-mem is not installed: its settings are neither created nor mentioned as a change
out=$(linst --dry-run); rc=$?
assert_eq "learn: dry-run exits 0" "0" "$rc"
assert_contains "learn: dry-run shows the learner plist diff" "$out" "+++ $LP (after install)"
assert_contains "learn: dry-run lists the write and load" "$out" "would: write $LP and launchctl bootstrap it"
assert_no_file "learn: dry-run writes no plist" "$LP"
assert_not_contains "learn: no claude-mem settings: nothing planned for it" "$out" "CLAUDE_MEM_EXCLUDED_PROJECTS"
n=$(wc -l <"$WORK/launchctl.log")
out=$(linst --yes); rc=$?
assert_eq "learn: install exits 0" "0" "$rc"
assert_ok "learn: the plist is valid" plutil -lint "$LP"
assert_eq "learn: label" "org.ching.learn" "$(plutil -extract Label raw -o - "$LP")"
assert_eq "learn: runs learn.sh through the kit link" "$LD/ching/bin/learn.sh" "$(plutil -extract ProgramArguments.1 raw -o - "$LP")"
assert_eq "learn: no argument (learn.sh decides the weekly part)" "2" "$(plutil -extract ProgramArguments raw -o - "$LP")"
assert_eq "learn: every day at 05:30" "5 30" "$(plutil -extract StartCalendarInterval.Hour raw -o - "$LP") $(plutil -extract StartCalendarInterval.Minute raw -o - "$LP")"
assert_eq "learn: no weekday (daily)" "" "$(plutil -extract StartCalendarInterval.Weekday raw -o - "$LP" 2>/dev/null)"
assert_eq "learn: not run at load" "" "$(plutil -extract RunAtLoad raw -o - "$LP" 2>/dev/null)"
assert_eq "learn: CHING_LEARNER=1" "1" "$(plutil -extract EnvironmentVariables.CHING_LEARNER raw -o - "$LP")"
assert_eq "learn: CLAUDE_MEM_INTERNAL=1" "1" "$(plutil -extract EnvironmentVariables.CLAUDE_MEM_INTERNAL raw -o - "$LP")"
assert_eq "learn: AGENT_HOME" "$LAH" "$(plutil -extract EnvironmentVariables.AGENT_HOME raw -o - "$LP")"
assert_contains "learn: PATH reaches claude in ~/.local/bin" "$(plutil -extract EnvironmentVariables.PATH raw -o - "$LP")" "$HOME/.local/bin"
assert_eq "learn: launchd output goes to AGENT_HOME/learn.log" "$LAH/learn.log" "$(plutil -extract StandardOutPath raw -o - "$LP")"
assert_contains "learn: bootstrapped" "$(tail -n +$((n + 1)) "$WORK/launchctl.log")" "bootstrap gui/$(id -u) $LP"
assert_file "learn: the watcher is installed too" "$LLA/org.ching.watch.plist"
n=$(wc -l <"$WORK/launchctl.log")
out=$(linst --yes)
assert_contains "learn: a second run has nothing to do" "$out" "nothing to do"
assert_eq "learn: a second run does not call launchctl" "$n" "$(wc -l <"$WORK/launchctl.log")"
sed 's|<integer>30</integer>|<integer>45</integer>|' "$LP" >"$LP.t" && mv "$LP.t" "$LP"
out=$(linst); rc=$?
assert_eq "learn: a changed plist without a tty or --yes is refused" "1" "$rc"
assert_contains "learn: ... the diff shows the old minute" "$out" "<integer>45</integer>"
linst --yes >/dev/null
assert_eq "learn: --yes restores the minute" "30" "$(plutil -extract StartCalendarInterval.Minute raw -o - "$LP")"

# claude-mem installed: the learner's .work joins CLAUDE_MEM_EXCLUDED_PROJECTS, with a backup first
printf '{\n  "CLAUDE_MEM_RUNTIME": "worker",\n  "CLAUDE_MEM_EXCLUDED_PROJECTS": "/Users/x/secret/**"\n}\n' >"$CMS"; chmod 640 "$CMS"
CM_BEFORE=$(cat "$CMS")
out=$(linst --dry-run)
assert_contains "claude-mem: dry-run shows the settings diff" "$out" "+++ $CMS (after install)"
assert_contains "claude-mem: dry-run says what it adds" "$out" "would: back up $CMS and add $LAH/proposals/.work to CLAUDE_MEM_EXCLUDED_PROJECTS"
assert_eq "claude-mem: dry-run leaves the file" "$CM_BEFORE" "$(cat "$CMS")"
out=$(linst); rc=$?
assert_eq "claude-mem: without a tty or --yes it is refused" "1" "$rc"
assert_eq "claude-mem: ... and the file is left" "$CM_BEFORE" "$(cat "$CMS")"
out=$(linst --yes); rc=$?
assert_eq "claude-mem: install exits 0" "0" "$rc"
assert_eq "claude-mem: the entry is appended, the old one kept" "/Users/x/secret/**,$LAH/proposals/.work" "$(jq -r .CLAUDE_MEM_EXCLUDED_PROJECTS "$CMS")"
assert_eq "claude-mem: other settings untouched" "worker" "$(jq -r .CLAUDE_MEM_RUNTIME "$CMS")"
assert_eq "claude-mem: a backup holds the old file" "$CM_BEFORE" "$(cat "$CMS".bak.ching.*)"
assert_eq "claude-mem: the file keeps its mode" "640" "$(stat -f %Lp "$CMS")"
CMA=$(cat "$CMS")
out=$(linst --yes)
assert_contains "claude-mem: a second run has nothing to do" "$out" "nothing to do"
assert_eq "claude-mem: ... and leaves the file byte for byte" "$CMA" "$(cat "$CMS")"
assert_eq "claude-mem: ... with one backup" "1" "$(ls "$CMS".bak.ching.* | wc -l | tr -d ' ')"
printf '{"CLAUDE_MEM_RUNTIME":"worker"}\n' >"$CMS"; linst --yes >/dev/null
assert_eq "claude-mem: no key yet: the key is created" "$LAH/proposals/.work" "$(jq -r .CLAUDE_MEM_EXCLUDED_PROJECTS "$CMS")"
printf '{"CLAUDE_MEM_EXCLUDED_PROJECTS":["not","a string"]}\n' >"$CMS"; CMODD=$(cat "$CMS")
out=$(linst --yes)
assert_contains "claude-mem: a value of another type: a warning" "$out" "leaving it alone"
assert_eq "claude-mem: ... and the file is untouched" "$CMODD" "$(cat "$CMS")"
printf 'not json\n' >"$CMS"; out=$(linst --yes); rc=$?
assert_eq "claude-mem: a broken settings file does not stop the install" "0" "$rc"
assert_eq "claude-mem: ... nor gets rewritten" "not json" "$(cat "$CMS")"
printf '{"CLAUDE_MEM_EXCLUDED_PROJECTS":"/a,%s"}\n' "$LAH/proposals/.work" >"$CMS"
out=$(linst --uninstall --yes); rc=$?
assert_eq "learn: uninstall exits 0" "0" "$rc"
assert_no_file "learn: uninstall removes the learner plist" "$LP"
assert_contains "learn: uninstall boots the learner out" "$(cat "$WORK/launchctl.log")" "bootout gui/$(id -u)/org.ching.learn"
assert_eq "claude-mem: uninstall takes only our entry out" "/a" "$(jq -r .CLAUDE_MEM_EXCLUDED_PROJECTS "$CMS")"
assert_not_contains "learn: the real claude-mem settings are never the target in tests" "$CMS" "/Users/clyde/.claude-mem"
exit 0
