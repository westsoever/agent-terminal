#!/usr/bin/env bash
# launch.sh [claude args...] - start the voice dispatcher: one slim, restricted claude session (PLAN 4.2).
#
# Runs in $AGENT_HOME/dispatcher (made by `install.sh --install-dispatcher`) with:
#   --setting-sources project   only that folder's .claude/settings.json: none of your user plugins, hooks or skills
#   --strict-mcp-config --mcp-config mcp.json   only VoiceMode's server, exposing only the converse tool
#   --tools Bash,Read,ToolSearch,ListAgents,SendMessage   the built-in tools it can see at all
#   --disable-slash-commands    no skills
# and tool-gate.sh (a PreToolUse hook from that folder's settings) narrowing Bash to dash.sh and relay-log.sh and
# Read to STATE.md/NEXT.md. Before it starts claude it runs the installed hook command once with an Edit call and
# refuses to start unless that is denied: a settings file that lost the hook must not give a shell.
#
# The permission mode defaults to bypassPermissions, the same as the worker sessions, because SendMessage to a
# session in a different mode may be held for approval instead of delivered (not verified here). The restriction
# does not depend on the mode. DISPATCHER_MODE=dontAsk runs it under the settings file's permission rules instead.
#
# Always listening: AGENTS.md ends every turn with a converse listen of up to 120 s. Claude Code moves an MCP call that
# runs longer than its auto-background limit (about 120 s) into a background task, and a listen plus speech plus
# transcription goes past that; the owner's first run lost the conversation that way. So this switches MCP
# auto-backgrounding off for the dispatcher (CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=0 and
# CLAUDE_CODE_DISABLE_MCP_TASK_BACKGROUND=1, unless already set). A stdio MCP call may stay silent for 30 minutes
# before Claude Code aborts it, far above one listen.
#
# Models: haiku by default. To compare, start the same session on Sonnet:
#   DISPATCHER_MODEL=sonnet ~/.claude/agent-terminal/dispatcher/launch.sh "[shortcut] listen"
# Any model name or alias claude --model takes is passed through as is. dispatcher/eval.sh runs the offline eval.
#
# Env: AGENT_HOME, DISPATCHER_DIR, CLAUDE_BIN (claude), DISPATCHER_MODEL (haiku), DISPATCHER_MODE (bypassPermissions),
#      DISPATCHER_NAME (dispatcher; eval.sh uses another name so no worker message reaches an eval run)
set -euo pipefail

AGENT_HOME=${AGENT_HOME:-$HOME/.agent}
DIR=${DISPATCHER_DIR:-$AGENT_HOME/dispatcher}
CLAUDE_BIN=${CLAUDE_BIN:-claude}
SETTINGS=$DIR/.claude/settings.json

if [ ! -f "$SETTINGS" ] || [ ! -f "$DIR/mcp.json" ]; then
  echo "launch: the dispatcher is not installed in $DIR. Run: ~/.claude/agent-terminal/install.sh --install-dispatcher" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "launch: jq is required" >&2; exit 1; }

# The hook must be there, executable, and must deny a tool the dispatcher is not allowed to use.
HOOK=$(jq -r '[.hooks.PreToolUse[]?.hooks[]?.command // empty | select(endswith("/dispatcher/tool-gate.sh"))] | first // ""' "$SETTINGS" 2>/dev/null || true)
if [ -z "$HOOK" ] || [ ! -x "$HOOK" ]; then
  echo "launch: $SETTINGS has no working tool-gate.sh hook; refusing to start. Re-run install.sh --install-dispatcher --yes." >&2
  exit 1
fi
canary=$(printf '%s' '{"hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":"/tmp/dispatcher-canary"}}' | DISPATCHER_GATE_CANARY=1 "$HOOK" 2>/dev/null || true)
case "$canary" in
  *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) ;;
  *) echo "launch: the tool gate did not deny a test Edit call; refusing to start." >&2; exit 1 ;;
esac

# Eval mode is for dispatcher/eval.sh's own hook wrapper only; it never comes in from the caller's environment.
unset DISPATCHER_GATE_EVAL DISPATCHER_GATE_EVAL_LOG DISPATCHER_GATE_EVAL_DASH DISPATCHER_GATE_EVAL_RELAY DISPATCHER_GATE_EVAL_FIXTURE
export CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS=${CLAUDE_CODE_MCP_AUTO_BACKGROUND_MS:-0}
export CLAUDE_CODE_DISABLE_MCP_TASK_BACKGROUND=${CLAUDE_CODE_DISABLE_MCP_TASK_BACKGROUND:-1}

cd "$DIR"
exec "$CLAUDE_BIN" --name "${DISPATCHER_NAME:-dispatcher}" --model "${DISPATCHER_MODEL:-haiku}" --setting-sources project \
  --strict-mcp-config --mcp-config "$DIR/mcp.json" --tools "Bash,Read,ToolSearch,ListAgents,SendMessage" \
  --permission-mode "${DISPATCHER_MODE:-bypassPermissions}" --disable-slash-commands "$@"
