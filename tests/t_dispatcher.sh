#!/usr/bin/env bash
# Phase 4: the voice dispatcher. 4.1 the policy file, 4.2 the tool restriction (tool-gate.sh, settings, launcher,
# install path) and relay-log.sh. Nothing here starts a real session, calls a model or plays audio: the gate is
# driven with hook JSON, the launcher with a fake claude.
# The literal ~ in quotes is the point: these are command strings a model types, not paths for this shell.
# shellcheck disable=SC2088
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DISP="$KIT/dispatcher"
GATE="$DISP/tool-gate.sh"
RELAY="$DISP/relay-log.sh"
LAUNCH="$DISP/launch.sh"
for f in "$GATE" "$RELAY" "$LAUNCH"; do assert_file "exists: dispatcher/$(basename "$f")" "$f"; done
for f in "$DISP"/*.sh; do
  [ -f "$f" ] || continue
  assert_ok "bash -n dispatcher/$(basename "$f")" bash -n "$f"
  case "$(sed -n 1,40p "$f")" in *"set -euo pipefail"*) pass "strict mode: dispatcher/$(basename "$f")" ;; *) fail "strict mode: dispatcher/$(basename "$f")" "no set -euo pipefail" ;; esac
done
SC=$(command -v shellcheck || true); [ -n "$SC" ] || { [ -x /tmp/sc-venv/bin/shellcheck ] && SC=/tmp/sc-venv/bin/shellcheck; }
if [ -n "$SC" ]; then
  for f in "$DISP"/*.sh; do
    [ -f "$f" ] || continue
    out=$(cd "$DISP" && "$SC" -x -S warning "$(basename "$f")" 2>&1) && pass "shellcheck dispatcher/$(basename "$f")" || fail "shellcheck dispatcher/$(basename "$f")" "$out"
  done
else
  echo "shellcheck not installed: skipped" >"$T_ROOT/skipped.t_dispatcher"
fi

link_kit   # $CLAUDE_DIR/kaching -> the kit, like the real install
CH="$CLAUDE_DIR/kaching"

# ---------------- fixtures ----------------
PROJ="$WORK/proj"; mkdir -p "$PROJ/.agent" "$PROJ/other" "$PROJ/docs"
printf '# State\nstatus: working\n' >"$PROJ/.agent/STATE.md"
printf '# Next\n' >"$PROJ/.agent/NEXT.md"
printf '# Goal\ntest_command: true\n' >"$PROJ/.agent/GOAL.md"
printf 'secret\n' >"$PROJ/other/STATE.md"
printf 'not a state file\n' >"$PROJ/docs/STATE.md"
mkdir -p "$HOME/proj/.agent"; printf '# State\n' >"$HOME/proj/.agent/STATE.md"
mkdir -p "$AGENT_HOME/sessions/abc123"; printf '# State\n' >"$AGENT_HOME/sessions/abc123/STATE.md"; printf '# Next\n' >"$AGENT_HOME/sessions/abc123/NEXT.md"
printf 'state=working\n' >"$AGENT_HOME/sessions/abc123/meta"; printf 'hmac-secret\n' >"$AGENT_HOME/secret"
printf 'outside\n' >"$WORK/outside.txt"
mkdir -p "$WORK/proj-link/.agent"; ln -sf "$WORK/outside.txt" "$WORK/proj-link/.agent/STATE.md"
mkdir -p "$WORK/link-dir-target"; printf 'x\n' >"$WORK/link-dir-target/STATE.md"; ln -sfn "$WORK/link-dir-target" "$WORK/proj-link/.agent-dir"
printf '# State\n' >"$AGENT_HOME/sessions/abc123/STATE.md.bak"

# ---------------- the gate ----------------
gate_out() { # tool tool_input_json
  jq -n --arg t "$1" --argjson i "$2" '{hook_event_name:"PreToolUse",session_id:"disp-1",tool_name:$t,cwd:"/tmp",tool_input:$i}' | "$GATE" 2>&1
}
gate_rc() { jq -n --arg t "$1" --argjson i "$2" '{hook_event_name:"PreToolUse",tool_name:$t,cwd:"/tmp",tool_input:$i}' | "$GATE" >/dev/null 2>&1; echo $?; }
allow_t() { # name tool input
  local out; out=$(gate_out "$2" "$3"); local rc=$?
  if [ -z "$out" ] && [ "$rc" -eq 0 ]; then pass "allow: $1"; else fail "allow: $1" "  tool: $2 input: $3"$'\n'"  gate said (rc $rc): $out"; fi
}
deny_t() { # name tool input
  local out; out=$(gate_out "$2" "$3")
  if is_deny "$out"; then pass "deny: $1"; else fail "deny: $1" "  tool: $2 input: $3"$'\n'"  gate said: ${out:-<allowed>}"; fi
}
bash_in() { jq -nc --arg c "$1" '{command:$c}'; }
allow_b() { allow_t "$1" Bash "$(bash_in "$2")"; }
deny_b() { deny_t "$1" Bash "$(bash_in "$2")"; }
read_in() { jq -nc --arg p "$1" '{file_path:$p}'; }
DASH_ABS="$CH/bin/dash.sh"

# the tools it is for
allow_t "ListAgents" ListAgents '{}'
allow_t "SendMessage to a session" SendMessage '{"to":"miso-app","message":"run the tests again"}'
allow_t "ToolSearch (loads schemas only)" ToolSearch '{"query":"select:SendMessage","max_results":1}'
allow_t "converse, MCP server name" mcp__voicemode__converse '{"message":"hello","wait_for_response":false}'
allow_t "converse, plugin name" mcp__plugin_voicemode_voicemode__converse '{"message":"hello"}'

# dash.sh: the only command, with its own flags only
allow_b "dash.sh --speak via ~" '~/.claude/kaching/bin/dash.sh --speak'
allow_b "dash.sh --inbox via \$HOME" '$HOME/.claude/kaching/bin/dash.sh --inbox'
allow_b "dash.sh --next via the absolute installed path" "$DASH_ABS --next"
allow_b "dash.sh --hours 6 --all" '~/.claude/kaching/bin/dash.sh --hours 6 --all'
allow_b "dash.sh with no flag (the table)" '~/.claude/kaching/bin/dash.sh'
allow_b "dash.sh via the kit's own bin dir" "$KIT/bin/dash.sh --speak"
allow_b "dash.sh --route (the routing table)" '~/.claude/kaching/bin/dash.sh --route'
deny_b "dash.sh --route with an unknown flag after it" '~/.claude/kaching/bin/dash.sh --route --evil'
deny_b "dash.sh --route piped" '~/.claude/kaching/bin/dash.sh --route | head'
deny_b "an ordinary command" 'ls -la'
deny_b "rm -rf" 'rm -rf /tmp/x'
deny_b "reading .env through cat" 'cat ~/.miso/.env.local'
deny_b "git push" 'git push origin main'
deny_b "gh workflow run" 'gh workflow run deploy.yml'
deny_b "dash.sh then another command (;)" '~/.claude/kaching/bin/dash.sh --speak; ls'
deny_b "dash.sh then another command (&&)" '~/.claude/kaching/bin/dash.sh --speak && ls'
deny_b "dash.sh piped into a shell" '~/.claude/kaching/bin/dash.sh --speak | sh'
deny_b "dash.sh piped anywhere" '~/.claude/kaching/bin/dash.sh --speak | cat'
deny_b "dash.sh in the background (&)" '~/.claude/kaching/bin/dash.sh --speak &'
deny_b "dash.sh with a command substitution" '~/.claude/kaching/bin/dash.sh $(id)'
deny_b "dash.sh with backticks" '~/.claude/kaching/bin/dash.sh `id`'
deny_b "dash.sh with a redirect" '~/.claude/kaching/bin/dash.sh --speak > /tmp/out'
deny_b "dash.sh with an append redirect" '~/.claude/kaching/bin/dash.sh --speak >> ~/.zshrc'
deny_b "dash.sh with a newline and a second command" $'~/.claude/kaching/bin/dash.sh --speak\nrm -rf /tmp/x'
deny_b "dash.sh with a tab-separated second word" $'~/.claude/kaching/bin/dash.sh\t--speak'
deny_b "dash.sh with an unknown flag" '~/.claude/kaching/bin/dash.sh --evil'
deny_b "dash.sh with a non-numeric --hours" '~/.claude/kaching/bin/dash.sh --hours abc'
deny_b "dash.sh --hours without a value" '~/.claude/kaching/bin/dash.sh --hours'
deny_b "dash.sh with a path argument" '~/.claude/kaching/bin/dash.sh /etc/passwd'
deny_b "a sibling script in the same bin dir" '~/.claude/kaching/bin/notify.sh done'
deny_b "guard.sh itself" '~/.claude/kaching/bin/guard.sh'
deny_b "path traversal out of the bin dir" '~/.claude/kaching/bin/../bin/dash.sh --speak'
deny_b "a dash.sh that is somewhere else" '/tmp/dash.sh --speak'
deny_b "bash -c around dash.sh" "bash -c '~/.claude/kaching/bin/dash.sh --speak'"
deny_b "an env prefix before dash.sh" 'AGENT_HOME=/tmp/x ~/.claude/kaching/bin/dash.sh --speak'
deny_b "an empty command" ''
deny_t "Bash with no command key at all" Bash '{}'

# relay-log.sh: a quoted text, nothing else
allow_b "relay-log.sh with a single-quoted text" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'tell miso-app to run the tests again'"
allow_b "relay-log.sh unconfirmed" "~/.claude/kaching/dispatcher/relay-log.sh $AGENT_HOME/sessions/abc123 no 'push miso-workspace'"
allow_b "relay-log.sh with an apostrophe written as '\\''" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'don'\\''t push'"
allow_b "relay-log.sh with dollar signs and backticks inside single quotes" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'costs \$5 and \`id\` and \$(id)'"
deny_b "relay-log.sh with a double-quoted text" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes \"\$(id)\""
deny_b "relay-log.sh with an unquoted text" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes run the tests"
deny_b "relay-log.sh then a second command" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'x'; ls"
deny_b "relay-log.sh with a quote that closes early" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'x' 'y'"
deny_b "relay-log.sh with an early close then a command" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes 'x'; id; 'y'"
deny_b "relay-log.sh with a newline inside the quotes" "$(printf "~/.claude/kaching/dispatcher/relay-log.sh %s yes 'a\nb'" "$PROJ/.agent")"
deny_b "relay-log.sh with a confirmation that is not yes or no" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent maybe 'x'"
deny_b "relay-log.sh with a state dir holding a substitution" "~/.claude/kaching/dispatcher/relay-log.sh \$(id) yes 'x'"
deny_b "relay-log.sh with a state dir that has a space" "~/.claude/kaching/dispatcher/relay-log.sh /tmp/a\\ b yes 'x'"
deny_b "relay-log.sh with a text over 2000 characters" "~/.claude/kaching/dispatcher/relay-log.sh $PROJ/.agent yes '$(head -c 2100 /dev/zero | tr '\0' a)'"
deny_b "another script in dispatcher/" '~/.claude/kaching/dispatcher/launch.sh'

# Read: only STATE.md and NEXT.md of a session, wherever they really are
allow_t "Read of <repo>/.agent/STATE.md" Read "$(read_in "$PROJ/.agent/STATE.md")"
allow_t "Read of <repo>/.agent/NEXT.md" Read "$(read_in "$PROJ/.agent/NEXT.md")"
allow_t "Read of a session dir's STATE.md under AGENT_HOME" Read "$(read_in "$AGENT_HOME/sessions/abc123/STATE.md")"
allow_t "Read of a session dir's NEXT.md under AGENT_HOME" Read "$(read_in "$AGENT_HOME/sessions/abc123/NEXT.md")"
allow_t "Read through ~" Read "$(read_in '~/proj/.agent/STATE.md')"
allow_t "Read with offset and limit" Read "$(jq -nc --arg p "$PROJ/.agent/STATE.md" '{file_path:$p,offset:1,limit:20}')"
allow_t "Read through a harmless .. that lands on a real STATE.md" Read "$(read_in "$PROJ/.agent/../.agent/STATE.md")"
deny_t "Read of GOAL.md" Read "$(read_in "$PROJ/.agent/GOAL.md")"
deny_t "Read of a STATE.md outside .agent/" Read "$(read_in "$PROJ/docs/STATE.md")"
deny_t "Read of a STATE.md reached by .. out of .agent/" Read "$(read_in "$PROJ/.agent/../other/STATE.md")"
deny_t "Read of a STATE.md that is a symlink to another file" Read "$(read_in "$WORK/proj-link/.agent/STATE.md")"
deny_t "Read of the per-machine secret" Read "$(read_in "$AGENT_HOME/secret")"
deny_t "Read of a session meta file" Read "$(read_in "$AGENT_HOME/sessions/abc123/meta")"
deny_t "Read of events.jsonl" Read "$(read_in "$AGENT_HOME/events.jsonl")"
deny_t "Read of /etc/passwd" Read "$(read_in /etc/passwd)"
deny_t "Read of a private key" Read "$(read_in '~/.ssh/id_ed25519')"
deny_t "Read of a .env file" Read "$(read_in "$PROJ/.env.local")"
deny_t "Read of a relative path" Read "$(read_in '.agent/STATE.md')"
deny_t "Read with no path" Read '{}'
deny_t "Read of a STATE.md that does not exist" Read "$(read_in "$PROJ/.agent/gone/STATE.md")"
deny_t "Read of STATE.md.bak" Read "$(read_in "$AGENT_HOME/sessions/abc123/STATE.md.bak")"
deny_t "Read of state.md in lower case (not the same name for the gate)" Read "$(read_in "$PROJ/.agent/state.md")"
deny_t "Read of a directory named STATE.md's parent" Read "$(read_in "$PROJ/.agent")"
deny_t "Read of a session STATE.md two levels down" Read "$(read_in "$AGENT_HOME/sessions/abc123/x/STATE.md")"
deny_t "Read of a STATE.md straight under sessions/" Read "$(read_in "$AGENT_HOME/sessions/STATE.md")"

# every other tool, by name
for t in Edit Write MultiEdit NotebookEdit WebFetch WebSearch Agent Task TodoWrite Glob Grep Skill Monitor ReadNotifications \
         EnterWorktree CronCreate RemoteTrigger AskUserQuestion Workflow ShareOnboardingGuide SendUserFile \
         mcp__voicemode__pause_conversation mcp__plugin_voicemode_voicemode__service mcp__plugin_voicemode_voicemode__connect_status \
         mcp__claude_ai_Gmail__send_message mcp__claude_ai_Slack__authenticate mcp__supabase__execute_sql mcp__voicemode__converse2 \
         converse ListAgentsX Bash2 read; do
  deny_t "tool $t" "$t" '{"file_path":"'"$PROJ"'/.agent/STATE.md","command":"~/.claude/kaching/bin/dash.sh --speak","content":"x"}'
done
deny_t "an empty tool name" "" '{}'
deny_t "Edit of STATE.md (the one write the old policy allowed)" Edit "$(jq -nc --arg p "$PROJ/.agent/STATE.md" '{file_path:$p,old_string:"a",new_string:"b"}')"
deny_t "Write of a new file" Write '{"file_path":"/tmp/x","content":"x"}'

# fail closed: input the gate cannot read is a block, never an allow
out=$(printf 'not json' | "$GATE" 2>&1); rc=$?
if is_deny "$out" || [ "$rc" -eq 2 ]; then pass "malformed hook input is blocked"; else fail "malformed hook input is blocked" "  rc $rc, out: $out"; fi
out=$(printf '' | "$GATE" 2>&1); rc=$?
if is_deny "$out" || [ "$rc" -eq 2 ]; then pass "empty hook input is blocked"; else fail "empty hook input is blocked" "  rc $rc, out: $out"; fi
out=$(printf '{"tool_name":["Bash"]}' | "$GATE" 2>&1); rc=$?
if is_deny "$out" || [ "$rc" -eq 2 ]; then pass "a tool name that is not a string is blocked"; else fail "a tool name that is not a string is blocked" "  rc $rc, out: $out"; fi
out=$(printf '{"tool_name":"Bash","tool_input":{"command":["x"]}}' | "$GATE" 2>&1); rc=$?
if is_deny "$out" || [ "$rc" -eq 2 ]; then pass "a command that is not a string is blocked"; else fail "a command that is not a string is blocked" "  rc $rc, out: $out"; fi
assert_eq "every deny decision exits 0 (the JSON carries it)" "0" "$(gate_rc Edit '{}')"
# a deny names the way forward and is logged
out=$(gate_out Edit '{"file_path":"/tmp/x"}')
assert_contains "a deny reason names the dispatcher" "$out" "dispatcher"
assert_contains "a deny is logged as a deny event" "$(cat "$AGENT_HOME/events.jsonl" 2>/dev/null)" '"kind":"deny"'

# ---------------- the gate in eval mode (dispatcher/eval.sh) ----------------
EVX="$WORK/evalfx"; mkdir -p "$EVX/repos/miso/.agent" "$EVX/bin"
printf '# State\n' >"$EVX/repos/miso/.agent/STATE.md"
printf '#!/usr/bin/env bash\necho "stub $*"\n' >"$EVX/bin/dash.sh"; printf '#!/usr/bin/env bash\necho "relay $*"\n' >"$EVX/bin/relay-log.sh"
chmod +x "$EVX/bin/dash.sh" "$EVX/bin/relay-log.sh"
geval() { # tool tool_input_json [extra env...]
  local t=$1 i=$2; shift 2
  jq -n --arg t "$t" --argjson i "$i" '{hook_event_name:"PreToolUse",tool_name:$t,tool_input:$i}' |
    env DISPATCHER_GATE_EVAL=1 DISPATCHER_GATE_EVAL_LOG="$WORK/eval-gate.jsonl" DISPATCHER_GATE_EVAL_DASH="$EVX/bin/dash.sh" \
        DISPATCHER_GATE_EVAL_RELAY="$EVX/bin/relay-log.sh" DISPATCHER_GATE_EVAL_FIXTURE="$EVX" "$@" "$GATE" 2>&1
}
: >"$WORK/eval-gate.jsonl"
out=$(geval SendMessage '{"to":"miso-Sessions","message":"run the tests again"}')
assert_eq "eval gate: SendMessage is denied with the eval reason, nothing is sent" "deny|EVAL: recorded, not sent" "$(jq -r '.hookSpecificOutput | .permissionDecision + "|" + .permissionDecisionReason' <<<"$out")"
assert_eq "eval gate: ...and its target and text are logged" '{"kind":"sendmessage","to":"miso-Sessions","message":"run the tests again"}' "$(grep '"sendmessage"' "$WORK/eval-gate.jsonl")"
out=$(geval ListAgents '{}'); assert_ok "eval gate: ListAgents is denied (no live sessions offline)" is_deny "$out"
out=$(geval Bash "$(bash_in '~/.claude/kaching/bin/dash.sh --route')")
assert_eq "eval gate: dash.sh --route is allowed..." "allow" "$(jq -r '.hookSpecificOutput.permissionDecision' <<<"$out")"
assert_eq "eval gate: ...but runs the fixture stub with the same flags" "$EVX/bin/dash.sh --route" "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")"
assert_eq "eval gate: ...and the stub's command runs" "stub --route" "$(bash -c "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")")"
out=$(geval Bash "$(bash_in '~/.claude/kaching/bin/dash.sh')")
assert_eq "eval gate: dash.sh with no flag runs the stub too" "$EVX/bin/dash.sh" "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")"
out=$(geval Bash "$(bash_in "~/.claude/kaching/dispatcher/relay-log.sh $EVX/repos/miso/.agent no 'run the tests again'")")
assert_eq "eval gate: relay-log.sh runs the fixture stub, nothing is written" "$EVX/bin/relay-log.sh $EVX/repos/miso/.agent no 'run the tests again'" "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")"
out=$(geval Bash "$(bash_in '~/.claude/kaching/bin/dash.sh --route; ls')"); assert_ok "eval gate: the grammar still holds (a ; is denied)" is_deny "$out"
out=$(geval Bash "$(bash_in '~/.claude/kaching/bin/dash.sh --route | cat')"); assert_ok "eval gate: ...and a pipe" is_deny "$out"
out=$(geval Bash "$(bash_in 'ls')"); assert_ok "eval gate: ...and any other command" is_deny "$out"
out=$(geval Bash "$(bash_in '~/.claude/kaching/bin/dash.sh --route')" DISPATCHER_GATE_EVAL_DASH=/no/such/stub)
assert_ok "eval gate: no fixture stub: denied rather than running the real dash.sh" is_deny "$out"
out=$(geval Read "$(read_in "$EVX/repos/miso/.agent/STATE.md")"); assert_eq "eval gate: a fixture STATE.md can be read" "" "$out"
out=$(geval Read "$(read_in "$PROJ/.agent/STATE.md")"); assert_ok "eval gate: a real STATE.md outside the fixture is denied" is_deny "$out"
assert_contains "eval gate: ...as a file that does not exist" "$out" "that file does not exist"
out=$(geval Edit '{"file_path":"/tmp/x"}'); assert_ok "eval gate: every other tool is still denied" is_deny "$out"
out=$(geval mcp__voicemode__converse '{"message":"hi"}'); assert_eq "eval gate: converse is untouched" "" "$out"
assert_ok "eval gate: every decision line in the log is JSON" jq -e . "$WORK/eval-gate.jsonl"
out=$(jq -nc '{tool_name:"SendMessage",tool_input:{to:"x",message:"y"}}' | env DISPATCHER_GATE_EVAL=yes "$GATE"); assert_eq "eval gate: only DISPATCHER_GATE_EVAL=1 turns eval mode on" "" "$out"

# ---------------- relay-log.sh ----------------
mkdir -p "$WORK/r1/.agent"
cat >"$WORK/r1/.agent/STATE.md" <<'EOS'
# State

status: working

## Done
- a thing

## Relayed instructions
<!-- Dispatcher/voice instructions received, with who/when. -->
- (none)

## Recommended next step
- (none)
EOS
chmod 600 "$WORK/r1/.agent/STATE.md"
out=$("$RELAY" "$WORK/r1/.agent" yes 'tell miso-app to run the tests again' 2>&1); rc=$?
assert_eq "relay-log: exits 0" "0" "$rc"
S1=$(cat "$WORK/r1/.agent/STATE.md")
assert_contains "relay-log: the entry is under the section" "$(printf '%s\n' "$S1" | sed -n '/^## Relayed instructions/,/^## Recommended/p')" "| confirmed | tell miso-app to run the tests again"
assert_not_contains "relay-log: the (none) placeholder is replaced" "$(printf '%s\n' "$S1" | sed -n '/^## Relayed instructions/,/^## Recommended/p')" "(none)"
assert_contains "relay-log: the other sections are untouched" "$S1" "## Recommended next step
- (none)"
assert_contains "relay-log: the entry starts with a date and time" "$(printf '%s\n' "$S1" | grep 'run the tests again')" "- 20"
assert_eq "relay-log: the file mode is kept" "600" "$(stat -f %Lp "$WORK/r1/.agent/STATE.md")"
"$RELAY" "$WORK/r1/.agent" no 'push miso-workspace' >/dev/null 2>&1
sec=$(printf '%s\n' "$(cat "$WORK/r1/.agent/STATE.md")" | sed -n '/^## Relayed instructions/,/^## Recommended/p')
assert_contains "relay-log: a second entry is appended" "$sec" "| unconfirmed | push miso-workspace"
assert_eq "relay-log: both entries are there, in order" "tell miso-app to run the tests again
push miso-workspace" "$(printf '%s\n' "$sec" | sed -n 's/^- [0-9: -]* | [a-z]* | //p')"
assert_eq "relay-log: the section's comment line is still first" "<!-- Dispatcher/voice instructions received, with who/when. -->" "$(printf '%s\n' "$sec" | sed -n 2p)"
# a session state dir under AGENT_HOME
out=$("$RELAY" "$AGENT_HOME/sessions/abc123" yes 'summarize' 2>&1); assert_eq "relay-log: a session dir under AGENT_HOME is accepted" "0" "$?"
assert_contains "relay-log: a STATE.md without the section gets one at the end" "$(cat "$AGENT_HOME/sessions/abc123/STATE.md")" "## Relayed instructions"
assert_contains "relay-log: ...with the entry" "$(cat "$AGENT_HOME/sessions/abc123/STATE.md")" "| confirmed | summarize"
# text hygiene
"$RELAY" "$WORK/r1/.agent" yes "$(printf 'line one\nline two\twith\ttabs and \033[31mcolour')" >/dev/null 2>&1
assert_eq "relay-log: newlines, tabs and escapes become single spaces or are dropped" "1" "$(grep -c 'line one line two with tabs and' "$WORK/r1/.agent/STATE.md")"
assert_not_contains "relay-log: no escape byte reaches the file" "$(cat "$WORK/r1/.agent/STATE.md")" $'\033'
"$RELAY" "$WORK/r1/.agent" yes "$(head -c 900 /dev/zero | tr '\0' z)" >/dev/null 2>&1
longest=$(awk '{ if (length($0) > m) m = length($0) } END { print m }' "$WORK/r1/.agent/STATE.md")
assert_eq "relay-log: a long text is cut so a line stays under 400 characters" "ok" "$([ "$longest" -lt 400 ] && echo ok || echo "$longest")"
# refusals: nothing is written anywhere else
before=$(cd "$WORK" && find . -type f -newer "$WORK/outside.txt" | sort | tr '\n' ' ')
assert_fails "relay-log: a text-less call is refused" "$RELAY" "$WORK/r1/.agent" yes ""
assert_fails "relay-log: a confirmation that is not yes or no is refused" "$RELAY" "$WORK/r1/.agent" maybe 'x'
assert_fails "relay-log: a dir that is not a state dir is refused even with a STATE.md in it" "$RELAY" "$PROJ/other" yes 'x'
assert_eq "relay-log: ...that STATE.md is untouched" "secret" "$(cat "$PROJ/other/STATE.md")"
mkdir -p "$WORK/empty-agent/.agent"
assert_fails "relay-log: an .agent dir without a STATE.md is refused" "$RELAY" "$WORK/empty-agent/.agent" yes 'x'
assert_no_file "relay-log: ...and no STATE.md was created" "$WORK/empty-agent/.agent/STATE.md"
assert_fails "relay-log: a dir that is not a state dir is refused" "$RELAY" "$PROJ/docs" yes 'x'
assert_eq "relay-log: ...docs/STATE.md untouched" "not a state file" "$(cat "$PROJ/docs/STATE.md")"
assert_fails "relay-log: a state dir reached through a symlink to elsewhere is refused" "$RELAY" "$WORK/proj-link/.agent-dir" yes 'x'
assert_fails "relay-log: a STATE.md that is a symlink out of the dir is refused" "$RELAY" "$WORK/proj-link/.agent" yes 'x'
assert_eq "relay-log: ...the target of that symlink is untouched" "outside" "$(cat "$WORK/outside.txt")"
assert_fails "relay-log: the secret's folder is refused" "$RELAY" "$AGENT_HOME" yes 'x'
assert_eq "relay-log: ...the secret is untouched" "hmac-secret" "$(cat "$AGENT_HOME/secret")"
assert_fails "relay-log: no arguments is a usage error" "$RELAY"
after=$(cd "$WORK" && find . -type f -newer "$WORK/outside.txt" | sort | tr '\n' ' ')
assert_eq "relay-log: refused calls left no new file behind" "$before" "$after"
assert_eq "relay-log: no temp file is left in the state dir" "STATE.md" "$(find "$WORK/r1/.agent" -type f -exec basename {} \; | tr '\n' ' ' | sed 's/ $//')"
assert_contains "relay-log: each entry is an event too" "$(cat "$AGENT_HOME/events.jsonl")" '"kind":"relay"'

# ---------------- settings template and the install path ----------------
ST="$DISP/settings.json"
assert_file "dispatcher/settings.json exists" "$ST"
assert_ok "settings.json is valid JSON" jq -e . "$ST"
assert_eq "settings: dontAsk is the mode when someone starts claude in the folder by hand" "dontAsk" "$(jq -r '.permissions.defaultMode' "$ST")"
assert_eq "settings: the allow list is exactly the dispatcher's tools" "ListAgents
SendMessage
ToolSearch
mcp__plugin_voicemode_voicemode__converse
mcp__voicemode__converse" "$(jq -r '.permissions.allow[] | select(startswith("Bash(") or startswith("Read(") | not)' "$ST" | LC_ALL=C sort)"
assert_eq "settings: Bash is allowed for dash.sh and relay-log.sh only, each as ~ and as the installed path" "Bash(@KACHING@/bin/dash.sh:*)
Bash(@KACHING@/dispatcher/relay-log.sh:*)
Bash(~/.claude/kaching/bin/dash.sh:*)
Bash(~/.claude/kaching/dispatcher/relay-log.sh:*)" "$(jq -r '.permissions.allow[] | select(startswith("Bash("))' "$ST" | LC_ALL=C sort)"
assert_eq "settings: Read rules exist for STATE.md and NEXT.md only" "ok" "$(jq -r '[.permissions.allow[] | select(startswith("Read("))] as $r | if ($r | length) >= 2 and ($r | map(select(endswith("STATE.md)"))) | length) >= 1 and ($r | map(select(endswith("NEXT.md)"))) | length) >= 1 then "ok" else "no" end' "$ST")"
assert_eq "settings: every Read rule names STATE.md or NEXT.md" "0" "$(jq '[.permissions.allow[] | select(startswith("Read(") and (endswith("STATE.md)") or endswith("NEXT.md)") | not))] | length' "$ST")"
for t in Edit Write NotebookEdit WebFetch WebSearch Agent Skill Monitor; do   # MultiEdit is not a tool name in this Claude Code version (it warns)
  assert_eq "settings: $t is on the deny list" "1" "$(jq --arg t "$t" '[.permissions.deny[] | select(. == $t)] | length' "$ST")"
done
assert_eq "settings: one PreToolUse hook for every tool" "1" "$(jq '.hooks.PreToolUse | length' "$ST")"
assert_eq "settings: ...its matcher is empty, so it sees every tool" "" "$(jq -r '.hooks.PreToolUse[0].matcher' "$ST")"
assert_eq "settings: ...and it runs tool-gate.sh" "@KACHING@/dispatcher/tool-gate.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$ST")"
assert_eq "settings: ...under 15 s (a timed-out hook lets the call through)" "ok" "$(jq -r 'if .hooks.PreToolUse[0].hooks[0].timeout <= 10 then "ok" else "too long" end' "$ST")"
assert_eq "settings: no other hook events" '["PreToolUse"]' "$(jq -c '.hooks | keys' "$ST")"
assert_eq "settings: no enabled plugins" "null" "$(jq -c '.enabledPlugins' "$ST")"

MT="$DISP/mcp.json"
assert_file "dispatcher/mcp.json exists" "$MT"
assert_eq "mcp: only the voicemode server" '["voicemode"]' "$(jq -c '.mcpServers | keys' "$MT")"
assert_eq "mcp: voicemode exposes only converse" "--tools-enabled converse" "$(jq -r '.mcpServers.voicemode.args | join(" ")' "$MT")"

DD="$AGENT_HOME/dispatcher"
inst() { "$KIT/install.sh" "$@" </dev/null 2>&1; }
# the main install is not needed for this mode, and it never touches settings.json
printf '{"keep":"me"}\n' >"$CLAUDE_DIR/settings.json"; S_BEFORE=$(shasum -a 256 "$CLAUDE_DIR/settings.json" | cut -d' ' -f1)
out=$(inst --install-dispatcher --dry-run); rc=$?
assert_eq "install-dispatcher --dry-run exits 0" "0" "$rc"
assert_no_file "dry-run writes nothing" "$DD"
assert_contains "dry-run lists the settings file" "$out" "$DD/.claude/settings.json"
assert_contains "dry-run lists the mcp config" "$out" "$DD/mcp.json"
out=$(inst --install-dispatcher); rc=$?
assert_eq "no tty and no --yes: refuses" "1" "$rc"
assert_contains "...and says it needs a terminal or --yes" "$out" "not a terminal"
assert_no_file "...writing nothing" "$DD"
out=$(inst --install-dispatcher --yes); rc=$?
assert_eq "install-dispatcher --yes exits 0" "0" "$rc"
assert_file "installed: .claude/settings.json" "$DD/.claude/settings.json"
assert_file "installed: mcp.json" "$DD/mcp.json"
assert_eq "installed: AGENTS.md links to the kit's policy through the kaching link" "$CH/dispatcher/AGENTS.md" "$(readlink "$DD/AGENTS.md")"
assert_eq "installed: CLAUDE.md links to AGENTS.md" "AGENTS.md" "$(readlink "$DD/CLAUDE.md")"
assert_ok "installed settings are valid JSON" jq -e . "$DD/.claude/settings.json"
assert_not_contains "installed settings have no placeholder left" "$(cat "$DD/.claude/settings.json" "$DD/mcp.json")" "@"
assert_eq "installed hook command points at the gate through the kaching link" "$CH/dispatcher/tool-gate.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$DD/.claude/settings.json")"
assert_contains "installed Bash rule names the installed dash.sh" "$(jq -r '.permissions.allow[]' "$DD/.claude/settings.json")" "Bash($CH/bin/dash.sh:*)"
assert_eq "installed mcp command is a voicemode executable name or path" "voicemode" "$(basename "$(jq -r '.mcpServers.voicemode.command' "$DD/mcp.json")")"
assert_eq "install-dispatcher leaves settings.json alone" "$S_BEFORE" "$(shasum -a 256 "$CLAUDE_DIR/settings.json" | cut -d' ' -f1)"
assert_no_file "install-dispatcher makes no backup of settings.json" "$(ls "$CLAUDE_DIR"/settings.json.bak.kaching.* 2>/dev/null | head -1)"
assert_no_file "install-dispatcher does not load a launchd job" "$WORK/launchctl.log"
# the installed hook command works through the link, and the policy file it points at reads
HC=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$DD/.claude/settings.json")
out=$(jq -nc '{tool_name:"Edit",tool_input:{file_path:"/tmp/x"}}' | $HC); assert_contains "installed gate denies Edit through the link" "$out" '"permissionDecision": "deny"'
out=$(jq -nc --arg c "$DASH_ABS --speak" '{tool_name:"Bash",tool_input:{command:$c}}' | $HC); assert_eq "installed gate allows dash.sh through the link" "" "$out"
assert_contains "the policy file is readable through the installed link" "$(cat "$DD/AGENTS.md")" "dispatcher"
# idempotent
SUM() { find "$DD" -type f -o -type l | sort | while read -r f; do printf '%s %s\n' "$f" "$(shasum -a 256 <"$f" | cut -d' ' -f1)"; done | shasum | cut -d' ' -f1; }
B=$(SUM); out=$(inst --install-dispatcher --yes); assert_eq "second install exits 0" "0" "$?"
assert_contains "second install says nothing to do" "$out" "nothing to do"
assert_eq "second install changes no file" "$B" "$(SUM)"
# a hand-edited generated file is shown as a diff and replaced only with --yes
jq '.permissions.allow += ["Edit"]' "$DD/.claude/settings.json" >"$DD/.claude/s.t" && mv "$DD/.claude/s.t" "$DD/.claude/settings.json"
out=$(inst --install-dispatcher --dry-run); assert_contains "a drifted settings file shows its diff" "$out" '-      "Edit"'
out=$(inst --install-dispatcher); assert_eq "a drifted file without --yes: refuses" "1" "$?"
assert_contains "...and the drift is still there" "$(cat "$DD/.claude/settings.json")" '"Edit"'
out=$(inst --install-dispatcher --yes); assert_eq "--yes restores it" "0" "$?"
assert_not_contains "...the extra Edit rule is gone" "$(jq -r '.permissions.allow[]' "$DD/.claude/settings.json")" "Edit"
# a file in the way that is not ours is left alone
rm -f "$DD/AGENTS.md"; printf 'mine\n' >"$DD/AGENTS.md"
out=$(inst --install-dispatcher --yes); assert_contains "a foreign AGENTS.md is reported, not replaced" "$out" "not our symlink"
assert_eq "...and kept" "mine" "$(cat "$DD/AGENTS.md")"
rm -f "$DD/AGENTS.md"; inst --install-dispatcher --yes >/dev/null
# the real thing: the fixed paths with special characters survive rendering
XH="$WORK/we&ird#dir"; mkdir -p "$XH/claude" "$XH/agent"; ln -sfn "$KIT" "$XH/claude/kaching"
out=$(env CLAUDE_DIR="$XH/claude" AGENT_HOME="$XH/agent" SETTINGS_FILE="$XH/claude/settings.json" AGENT_REPOS_FILE="$XH/repos" "$KIT/install.sh" --install-dispatcher --yes </dev/null 2>&1); assert_eq "special characters in paths: install exits 0" "0" "$?"
assert_eq "special characters: the hook path survives rendering" "$XH/claude/kaching/dispatcher/tool-gate.sh" "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$XH/agent/dispatcher/.claude/settings.json")"

# ---------------- launcher ----------------
cat >"$WORK/fake-claude" <<'EOS'
#!/usr/bin/env bash
{ echo "PWD=$PWD"; printf 'ARG=%s\n' "$@"; } >"$(dirname "$0")/claude.args"
{ echo "EVAL=${DISPATCHER_GATE_EVAL:-unset} EVAL_DASH=${DISPATCHER_GATE_EVAL_DASH:-unset}"
  echo "AUTO_BG=${CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS:-unset} NO_TASK_BG=${CLAUDE_CODE_DISABLE_MCP_TASK_BACKGROUND:-unset}"; } >"$(dirname "$0")/claude.env"
EOS
chmod +x "$WORK/fake-claude"
la() { grep -c "^ARG=$1\$" "$WORK/claude.args" || true; }
out=$(CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" 2>&1); rc=$?
assert_eq "launch: exits with the fake claude's status" "0" "$rc"
ARGS=$(cat "$WORK/claude.args")
assert_eq "launch: starts in the dispatcher folder" "PWD=$DD" "$(sed -n 1p "$WORK/claude.args")"
assert_contains "launch: a small fast model by default" "$ARGS" "ARG=--model
ARG=haiku"
assert_contains "launch: only project settings are read (no user plugins, hooks or skills)" "$ARGS" "ARG=--setting-sources
ARG=project"
assert_contains "launch: MCP servers come only from the dispatcher's own config" "$ARGS" "ARG=--strict-mcp-config"
assert_contains "launch: ...which is the installed mcp.json" "$ARGS" "ARG=--mcp-config
ARG=$DD/mcp.json"
assert_contains "launch: built-in tools are limited to five" "$ARGS" "ARG=--tools
ARG=Bash,Read,ToolSearch,ListAgents,SendMessage"
assert_contains "launch: skills and slash commands are off" "$ARGS" "ARG=--disable-slash-commands"
assert_contains "launch: the session is named dispatcher" "$ARGS" "ARG=--name
ARG=dispatcher"
assert_contains "launch: same permission mode as the workers by default (a relay is not held for approval)" "$ARGS" "ARG=--permission-mode
ARG=bypassPermissions"
CLAUDE_BIN="$WORK/fake-claude" DISPATCHER_MODE=dontAsk DISPATCHER_MODEL=sonnet "$LAUNCH" --resume abc >/dev/null 2>&1
ARGS=$(cat "$WORK/claude.args")
assert_contains "launch: DISPATCHER_MODE overrides the mode" "$ARGS" "ARG=--permission-mode
ARG=dontAsk"
assert_contains "launch: DISPATCHER_MODEL overrides the model" "$ARGS" "ARG=--model
ARG=sonnet"
assert_contains "launch: extra arguments are passed through" "$ARGS" "ARG=--resume
ARG=abc"
CLAUDE_BIN="$WORK/fake-claude" DISPATCHER_GATE_EVAL=1 DISPATCHER_GATE_EVAL_DASH=/tmp/x DISPATCHER_NAME=dispatcher-eval "$LAUNCH" >/dev/null 2>&1
assert_eq "launch: eval mode never comes in from the caller's environment" "EVAL=unset EVAL_DASH=unset" "$(sed -n 1p "$WORK/claude.env")"
assert_eq "launch: MCP auto-backgrounding is off, so a 120 s listen stays in the foreground" "AUTO_BG=0 NO_TASK_BG=1" "$(sed -n 2p "$WORK/claude.env")"
assert_contains "launch: DISPATCHER_NAME renames the session (eval.sh)" "$(cat "$WORK/claude.args")" "ARG=--name
ARG=dispatcher-eval"
CLAUDE_BIN="$WORK/fake-claude" CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=900000 "$LAUNCH" >/dev/null 2>&1
assert_eq "launch: ...an auto-background limit the caller set is kept" "AUTO_BG=900000 NO_TASK_BG=1" "$(sed -n 2p "$WORK/claude.env")"
assert_eq "launch: no flag that widens the tool set is ever passed" "0" "$(printf '%s\n' "$ARGS" | grep -c -e '--allowedTools' -e '--dangerously' -e '--add-dir' -e '--plugin-dir' || true)"
# the launcher refuses to start a session whose gate is missing or does not deny
cp "$DD/.claude/settings.json" "$WORK/settings.good"
: >"$WORK/claude.args"
jq 'del(.hooks)' "$WORK/settings.good" >"$DD/.claude/settings.json"
out=$(CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" 2>&1); rc=$?
assert_eq "launch: no hook in settings: exits 1" "1" "$rc"
assert_contains "launch: ...and says why" "$out" "no working tool-gate.sh hook"
assert_eq "launch: ...and never started claude" "" "$(cat "$WORK/claude.args")"
jq '.hooks.PreToolUse[0].hooks[0].command = "/no/such/dispatcher/tool-gate.sh"' "$WORK/settings.good" >"$DD/.claude/settings.json"
out=$(CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" 2>&1); assert_eq "launch: a hook path that does not exist: exits 1" "1" "$?"
mkdir -p "$WORK/lazy-gate/dispatcher"; printf '#!/usr/bin/env bash\nexit 0\n' >"$WORK/lazy-gate/dispatcher/tool-gate.sh"
chmod +x "$WORK/lazy-gate/dispatcher/tool-gate.sh"
jq --arg c "$WORK/lazy-gate/dispatcher/tool-gate.sh" '.hooks.PreToolUse[0].hooks[0].command = $c' "$WORK/settings.good" >"$DD/.claude/settings.json"
out=$(CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" 2>&1); rc=$?
assert_eq "launch: a hook that allows everything: exits 1" "1" "$rc"
assert_contains "launch: ...because the canary Edit was not denied" "$out" "did not deny"
assert_eq "launch: ...and never started claude" "" "$(cat "$WORK/claude.args")"
cp "$WORK/settings.good" "$DD/.claude/settings.json"
n=$(wc -l <"$AGENT_HOME/events.jsonl")
CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" >/dev/null 2>&1
assert_eq "launch: the start-up canary does not write a deny event" "$n" "$(wc -l <"$AGENT_HOME/events.jsonl")"
# ---------------- eval.sh, offline: a fake claude plays one turn through the eval copy's real hook ----------------
EV="$DISP/eval.sh"
cat >"$WORK/eval-fake" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
prompt=${!#}
HOOK=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' .claude/settings.json)
emit() { jq -nc "$@"; }
call() { # name input: the hook decides; an allowed Bash runs the command the hook gave back
  local out
  emit --arg n "$1" --argjson i "$2" '{type:"assistant",message:{content:[{type:"tool_use",name:$n,input:$i}]}}'
  out=$(jq -nc --arg n "$1" --argjson i "$2" '{hook_event_name:"PreToolUse",tool_name:$n,tool_input:$i}' | "$HOOK")
  if [ "$1" = Bash ] && [ "$(printf '%s' "${out:-null}" | jq -r '.hookSpecificOutput.permissionDecision // ""')" = allow ]; then
    bash -c "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")" >>"$PWD/fake-ran.txt"
  fi
}
emit '{type:"system",subtype:"init",model:"fake-model"}'
call Bash '{"command":"~/.claude/kaching/bin/dash.sh --route"}'
case "$prompt" in
  "Tell miso"*) call SendMessage "$(jq -nc --arg t "${FAKE_TO:-miso-Sessions}" '{to:$t,message:"run the tests again"}')"; r="Told miso: run the tests again." ;;
  *) r="Which session?" ;;
esac
emit --arg r "$r" '{type:"result",result:$r,duration_ms:5}'
EOS
chmod +x "$WORK/eval-fake"
EO="$WORK/eval-out"
out=$(DISPATCHER_EVAL_OUT="$EO" CLAUDE_BIN="$WORK/eval-fake" "$EV" --model fake --case 3 2>&1); rc=$?
assert_eq "eval.sh: a right relay passes (exit 0)" "0" "$rc"
assert_contains "eval.sh: prints the summary table" "$out" "| 3 | Tell miso to run the tests again | PASS |"
REP=$(ls "$EO"/fake-*.md 2>/dev/null | head -1)
assert_file "eval.sh: writes the report as <model>-<time>.md" "$REP"
assert_contains "eval.sh: the report lists the tool calls" "$(cat "$REP")" 'SendMessage {"to":"miso-Sessions"'
assert_contains "eval.sh: ...the SendMessage the gate recorded instead of sending" "$(cat "$REP")" 'sendmessage: {"to":"miso-Sessions","message":"run the tests again"}'
assert_contains "eval.sh: ...the model the session reported" "$(cat "$REP")" "fake-model"
assert_contains "eval.sh: the eval copy's dash.sh is the fixture's route table" "$(cat "$(find "$EO" -name fake-ran.txt | head -1)")" "miso-Sessions"
assert_contains "eval.sh: ...and the stub recorded the call" "$(cat "$(find "$EO" -name dash-calls.log | head -1)")" "--route"
assert_eq "eval.sh: the eval copy has no MCP server (no microphone)" '{}' "$(jq -c '.mcpServers' "$(find "$EO" -path '*dispatcher-home/mcp.json' | head -1)")"
rm -rf "$EO"
out=$(DISPATCHER_EVAL_OUT="$EO" CLAUDE_BIN="$WORK/eval-fake" FAKE_TO=PicoNew "$EV" --model fake --case 3 2>&1); rc=$?
assert_eq "eval.sh: a relay to the wrong session fails (exit 1)" "1" "$rc"
assert_contains "eval.sh: ...naming the check" "$(cat "$EO"/fake-*.md)" "FAIL: SendMessage to miso's message_to"
out=$(DISPATCHER_EVAL_OUT="$EO" CLAUDE_BIN="$WORK/eval-fake" "$EV" --model fake --case 4 2>&1); rc=$?
assert_eq "eval.sh: an unnamed instruction that only asks fails case 4 (exit 1)" "1" "$rc"
out=$("$EV" --case 3 2>&1); assert_eq "eval.sh: --model is required (usage, 64)" "64" "$?"
out=$("$EV" --model haiku --case 7 2>&1); assert_eq "eval.sh: an unknown case is a usage error" "64" "$?"

rm -rf "$WORK/not-installed"
out=$(AGENT_HOME="$WORK/not-installed" CLAUDE_BIN="$WORK/fake-claude" "$LAUNCH" 2>&1); rc=$?
assert_eq "launch: not installed exits 1" "1" "$rc"
assert_contains "launch: ...and says how to install it" "$out" "install.sh --install-dispatcher"

# ---------------- the policy file (4.1) ----------------
P="$DISP/AGENTS.md"; pb=$(cat "$P")
assert_contains "4.1: spoken replies are short" "$pb" "Short spoken sentences"
assert_contains "4.1: never edits code" "$pb" "never edit code"
assert_contains "4.1: risky instructions are read back and need a spoken yes" "$pb" "READ BACK"
assert_contains "4.1: ...for destructive, deploy and push instructions" "$pb" "deploys or pushes"
for term in "force push" "release gate" "vercel" ".env" "migration" "publish" "tag" "close" "send" "GOAL.md"; do
  assert_contains "4.1: the refusal list covers $term" "$(printf '%s\n' "$pb" | sed -n '/^4\. Refuse/,/^5\./p')" "$term"
done
assert_contains "4.1: names the tool restriction" "$pb" "tool-gate"
assert_contains "4.1: the one write is relay-log.sh" "$pb" "relay-log.sh"
assert_not_contains "4.1: no longer claims a file edit of its own" "$pb" "That file edit is the only write you do"
assert_not_contains "4.1: no longer offers to write into NEXT.md (it cannot)" "$pb" "put the instruction in X's NEXT.md"
assert_contains "4.1: a denial is reported, not worked around" "$pb" "do not try another way"
# dispatcher v2: always listening, routing from dash.sh --route, no --inbox for one session
assert_contains "v2: routes from dash.sh --route" "$pb" "dash.sh --route"
assert_contains "v2: the route table's columns are spelled out" "$pb" "name  message_to  status  state  state_dir  notes  focus  branch"
assert_contains "v2: SendMessage goes to message_to exactly" "$pb" "SendMessage \`to\` is that row's message_to, exactly"
assert_contains "v2: an unnamed instruction goes to the focused tab" "$pb" "focus = focused"
assert_contains "v2: never --inbox for one session" "$pb" "Never run \`--inbox\` for a question about one session"
assert_contains "v2: notes = no is said, not guessed" "$pb" "notes = no"
assert_contains "v2: wakes on the shortcut" "$pb" "[shortcut] listen"
assert_contains "v2: every turn ends with a long listen" "$pb" "listen_duration_max: 120"
assert_contains "v2: an empty listen is answered by a silent listen" "$pb" "skip_tts: true"
assert_contains "v2: stops after 5 empty listens" "$pb" "After 5 empty listens"
assert_contains "v2: the tell-me-to mishear is asked about" "$pb" "Tell me to"
assert_not_contains "v2: no more guessed STATE.md paths" "$pb" "repo sessions use"
# ---------------- 4.3: the spoken acceptance script, and the owner-only steps ----------------
AC="$KIT/docs/dispatcher-acceptance.md"
assert_file "4.3: docs/dispatcher-acceptance.md exists" "$AC"
ab=$(cat "$AC" 2>/dev/null || true)
for phrase in "What's blocked?" "What did miso finish?" "Tell miso to run the tests again" "push miso-workspace"; do
  assert_contains "4.3: the script has the phrase: $phrase" "$ab" "\"$phrase\""
done
assert_eq "4.3: every phrase has a pass criterion" "ok" "$([ "$(grep -c '^\*\*Pass' "$AC")" -ge 4 ] && echo ok || echo "only $(grep -c '^\*\*Pass' "$AC")")"
assert_eq "4.3: every phrase has a fail criterion" "ok" "$([ "$(grep -c '^\*\*Fail' "$AC")" -ge 4 ] && echo ok || echo "only $(grep -c '^\*\*Fail' "$AC")")"
assert_contains "4.3: the risky phrase must not be relayed unconfirmed" "$ab" "never relayed"
assert_contains "4.3: the speed pass line is the one chosen in MANUAL-STEPS 0.6" "$ab" "pass line"
assert_contains "4.3: says the owner runs it" "$ab" "You run this"
assert_contains "4.3: tells how to check a relay and a denial afterwards" "$ab" "events.jsonl"
MS="$KIT/MANUAL-STEPS.md"; mb=$(cat "$MS")
assert_contains "MANUAL-STEPS has a dated section for 2026-10-16" "$mb" "2026-10-16"
for step in "0.6" "0.7" "4.3"; do
  assert_contains "MANUAL-STEPS 2026-10-16 section has step $step" "$(printf '%s\n' "$mb" | sed -n '/^## 2026-10-16/,$p')" "$step"
done
assert_contains "MANUAL-STEPS: step V1 (hear /dash) exists, voice.md points at it" "$(printf '%s\n' "$mb" | sed -n '/^## 2026-10-16/,$p')" "V1"
assert_contains "MANUAL-STEPS: the pass line is the owner's to pick" "$(printf '%s\n' "$mb" | sed -n '/^## 2026-10-16/,$p')" "pick"
assert_contains "the earlier 0.4/0.5 sections are kept" "$mb" "## - [x] 0.4 SessionStart hook fires in Desktop and VS Code"
exit 0
