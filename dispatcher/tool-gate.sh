#!/usr/bin/env bash
# tool-gate.sh - PreToolUse hook for the voice dispatcher session ONLY (PLAN 4.2). Deny by default.
#
# The dispatcher may use exactly: ListAgents, SendMessage, ToolSearch, VoiceMode's converse (either tool name),
# Bash for dash.sh and relay-log.sh with their own arguments and nothing else, and Read of a session's STATE.md or
# NEXT.md. Every other tool, and every other use of these, is denied. This hook is the control that holds in any
# permission mode, including bypassPermissions (hooks and deny rules still fire there, PHASE0-RESULTS 0.1); the
# permissions block in settings.json is the second layer for a launch in another mode, and launch.sh's --tools
# list the third.
#
# Reads the hook JSON on stdin; prints {"hookSpecificOutput":{...,"permissionDecision":"deny",...}} (exit 0) or
# allows silently. Fails CLOSED: any internal error exits 2, which blocks the call. A hook that is slow or
# missing lets a call through, so this does no git, no network and no model calls.
#
# Bash grammar (a command that does not match it exactly is denied; no shell is involved in the decision):
#   <dash.sh> [--speak|--inbox|--next|--all|--hours N]...       single spaces, flags from this list only
#   <dash.sh> --route                                           the routing list; alone, with no other flag
#   <relay-log.sh> <state dir> yes|no '<single-quoted text>'    text: no quote inside except '\'' , at most 2000 chars
# where <dash.sh> / <relay-log.sh> is one of ~/.claude/agent-terminal/..., $HOME/.claude/agent-terminal/..., $CLAUDE_DIR/agent-terminal/...
# or this kit's own directory. No ;, &, |, <, >, $(), backticks, newlines or tabs can get through: the flags are
# compared as whole words and the text can only be a single-quoted string, which the shell never expands.
#
# Eval mode (dispatcher/eval.sh only): DISPATCHER_GATE_EVAL=1, set by the eval copy's hook wrapper. launch.sh
# unsets it, so a real dispatcher never runs in this mode. Every rule above still applies, and nothing real is touched:
#   SendMessage  denied with "EVAL: recorded, not sent"; the target and text are logged
#   ListAgents   denied (there are no live sessions offline; dash.sh --route is the session list)
#   dash.sh / relay-log.sh   a call the grammar allows runs DISPATCHER_GATE_EVAL_DASH / _RELAY (fixture stubs) with
#                the same arguments instead (the hook's updatedInput)
#   Read         only inside DISPATCHER_GATE_EVAL_FIXTURE; anything else is denied as a file that does not exist
# Every eval decision is one JSON line in DISPATCHER_GATE_EVAL_LOG.
set -euo pipefail

for dep in jq perl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "DISPATCHER GATE: $dep is not installed; failing closed" >&2; exit 2; }
done
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT_L=$(cd "$SELF_DIR/.." && pwd)
KIT_P=$(cd "$SELF_DIR/.." && pwd -P)
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
# shellcheck disable=SC2088
BASES=("~/.claude/agent-terminal" '$HOME/.claude/agent-terminal' "$CLAUDE_DIR/agent-terminal" "$KIT_L" "$KIT_P"
       "~/.claude/kaching" '$HOME/.claude/kaching' "$CLAUDE_DIR/kaching"   # the link's name before D65
       "~/.claude/ching" '$HOME/.claude/ching' "$CLAUDE_DIR/ching")   # and before D35
INPUT=$(cat)
DECIDED=0
TOOL=""
EVAL=0
if [ "${DISPATCHER_GATE_EVAL:-}" = 1 ]; then EVAL=1; fi

eval_log() { # kind json-object: one line in the eval log (eval mode only; never changes a decision)
  if [ "$EVAL" -eq 1 ] && [ -n "${DISPATCHER_GATE_EVAL_LOG:-}" ]; then
    jq -nc --arg k "$1" --argjson d "$2" '{kind:$k} + $d' >>"$DISPATCHER_GATE_EVAL_LOG" 2>/dev/null || true
  fi
}

emit_deny() { # reason [raw: no "DISPATCHER GATE: " prefix]
  local reason=$1 prefix="DISPATCHER GATE: "
  if [ "${2:-}" = raw ]; then prefix=""; fi
  if [ "${#reason}" -gt 400 ]; then reason="${reason:0:400}..."; fi
  if [ "$EVAL" -eq 1 ] && [ -z "${DISPATCHER_GATE_CANARY:-}" ]; then eval_log deny "$(jq -nc --arg t "$TOOL" --arg r "$reason" '{tool:$t,reason:$r}')"; fi
  if ! jq -n --arg r "$prefix$reason" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'; then
    echo "DISPATCHER GATE: could not print the deny decision; failing closed" >&2
    exit 2
  fi
  DECIDED=1
  # logged after the decision is printed; logging can never change it. launch.sh's start-up canary is not logged.
  if [ -z "${DISPATCHER_GATE_CANARY:-}" ]; then
  ( SID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null || true); CWD=$PWD; NAME=dispatcher
    # shellcheck source=../bin/lib.sh
    . "$SELF_DIR/../bin/lib.sh" && ev deny "$(jq -nc --arg r "dispatcher gate: $reason" --arg t "$TOOL" '{rule:$r,tool:$t}')" ) >/dev/null 2>&1 || true
  fi
  exit 0
}
allow() { DECIDED=1; exit 0; }
allow_as() { # stub args: eval mode only. Allow this Bash call, with its command replaced by the stub and the same args
  local stub=$1 args=$2 q new
  if [ -z "$stub" ] || [ ! -x "$stub" ]; then emit_deny "EVAL: no fixture stub to run instead"; fi
  printf -v q '%q' "$stub"
  new="$q${args:+ $args}"
  eval_log bash "$(jq -nc --arg c "$(jstr '.tool_input.command')" --arg r "$new" '{command:$c,ran:$r}')"
  if ! jq -n --arg c "$new" --argjson i "$(jq -c '.tool_input' <<<"$INPUT")" \
      '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"allow",permissionDecisionReason:"EVAL: fixture stub",updatedInput:($i + {command:$c})}}'; then
    echo "DISPATCHER GATE: could not print the eval decision; failing closed" >&2
    exit 2
  fi
  DECIDED=1; exit 0
}
# shellcheck disable=SC2329
on_exit() {
  local rc=$?
  if [ "$DECIDED" -eq 0 ] && [ "$rc" -ne 0 ]; then
    echo "DISPATCHER GATE: internal error (exit $rc); failing closed." >&2
    exit 2
  fi
}
trap on_exit EXIT

jstr() { # jq filter that yields a string or "" (never a number, array or object)
  jq -r "if ($1 | type) == \"string\" then $1 else \"\" end" <<<"$INPUT"
}

is_script() { # word suffix: is the word <one of the known agent-terminal dirs>/<suffix>
  local w=$1 suffix=$2 b
  for b in "${BASES[@]}"; do
    if [ "$w" = "$b/$suffix" ]; then return 0; fi
  done
  return 1
}

allow_dash() { if [ "$EVAL" -eq 1 ]; then allow_as "${DISPATCHER_GATE_EVAL_DASH:-}" "$1"; fi; allow; }

check_dash_args() { # everything after the dash.sh word
  local args=$1 tok want_num=0 toks=()
  if [ -z "$args" ] || [ "$args" = "--route" ]; then allow_dash "$args"; fi
  local IFS=' '
  read -r -a toks <<<"$args"
  if [ "${toks[*]}" != "$args" ]; then emit_deny "dash.sh arguments must be single-space separated flags"; fi
  for tok in "${toks[@]}"; do
    if [ "$want_num" -eq 1 ]; then
      [[ "$tok" =~ ^[0-9]{1,4}$ ]] || emit_deny "--hours takes a number of hours"
      want_num=0; continue
    fi
    case "$tok" in
      --speak|--inbox|--next|--all) ;;
      --hours) want_num=1 ;;
      --route) emit_deny "dash.sh --route takes no other flag; run it alone" ;;
      *) emit_deny "the dispatcher may run dash.sh with --route alone, or with --speak, --inbox, --next, --all and --hours N only" ;;
    esac
  done
  if [ "$want_num" -eq 1 ]; then emit_deny "--hours takes a number of hours"; fi
  allow_dash "$args"
}

check_relay_args() { # everything after the relay-log.sh word: <state dir> yes|no '<text>'
  local args=$1 dir conf text r1 sq="'"
  local re_dir='^(~/)?[A-Za-z0-9_./@+][A-Za-z0-9_./@+-]*$'
  local re_text="^${sq}([^${sq}]|${sq}\\\\${sq}${sq})*${sq}\$"
  dir=${args%% *}
  if [ "$dir" = "$args" ]; then emit_deny "relay-log.sh needs a state dir, yes or no, and a quoted text"; fi
  r1=${args#* }
  conf=${r1%% *}
  if [ "$conf" = "$r1" ]; then emit_deny "relay-log.sh needs a state dir, yes or no, and a quoted text"; fi
  text=${r1#* }
  [[ "$dir" =~ $re_dir ]] || emit_deny "relay-log.sh: the state dir must be a plain path"
  case "$conf" in yes|no) ;; *) emit_deny "relay-log.sh: the second argument is yes or no" ;; esac
  if [ "${#text}" -gt 2000 ]; then emit_deny "relay-log.sh: the text is too long"; fi
  [[ "$text" =~ $re_text ]] || emit_deny "relay-log.sh: the text must be one single-quoted string (write an apostrophe as '\\'')"
  if [ "$EVAL" -eq 1 ]; then allow_as "${DISPATCHER_GATE_EVAL_RELAY:-}" "$args"; fi
  allow
}

check_bash() {
  local cmd first rest
  cmd=$(jstr '.tool_input.command')
  if [ -z "$cmd" ]; then emit_deny "empty or unreadable command"; fi
  if [ "${#cmd}" -gt 2400 ]; then emit_deny "command too long"; fi
  case "$cmd" in *$'\n'*|*$'\r'*|*$'\t'*) emit_deny "no multi-line commands or tabs" ;; esac
  first=${cmd%% *}
  rest=""
  if [ "$cmd" != "$first" ]; then rest=${cmd#* }; fi
  if is_script "$first" bin/dash.sh; then check_dash_args "$rest"; fi
  if is_script "$first" dispatcher/relay-log.sh; then check_relay_args "$rest"; fi
  emit_deny "the dispatcher runs only ~/.claude/agent-terminal/bin/dash.sh and ~/.claude/agent-terminal/dispatcher/relay-log.sh. Tell the user what you could not do."
}

real_path() { perl -MCwd=abs_path -e 'my $p = abs_path($ARGV[0]); print $p if defined $p' -- "$1" 2>/dev/null || true; }

check_read() {
  local fp real base dir ah fx
  fp=$(jstr '.tool_input.file_path')
  if [ -z "$fp" ]; then emit_deny "Read needs a file path"; fi
  # shellcheck disable=SC2088
  case "$fp" in "~/"*) fp="$HOME/${fp#"~/"}" ;; esac
  case "$fp" in /*) ;; *) emit_deny "Read needs an absolute path" ;; esac
  case "$fp" in *$'\n'*) emit_deny "bad path" ;; esac
  real=$(real_path "$fp")
  if [ -z "$real" ] || [ ! -f "$real" ]; then emit_deny "the dispatcher reads only STATE.md and NEXT.md of a session; that file does not exist"; fi
  if [ "$EVAL" -eq 1 ]; then
    fx=$(real_path "${DISPATCHER_GATE_EVAL_FIXTURE:-/nonexistent}")
    case "$real" in "$fx"/*) eval_log read "$(jq -nc --arg p "$fp" '{file_path:$p}')" ;; *) emit_deny "the dispatcher reads only STATE.md and NEXT.md of a session; that file does not exist" ;; esac
  fi
  base=${real##*/}; dir=${real%/*}
  case "$base" in STATE.md|NEXT.md) ;; *) emit_deny "the dispatcher reads only STATE.md and NEXT.md of a session, not $base" ;; esac
  if [ "${dir##*/}" = ".agent" ]; then allow; fi
  ah=$(real_path "${AGENT_HOME:-$HOME/.agent}")
  if [ -n "$ah" ] && [ "${dir%/*}" = "$ah/sessions" ]; then allow; fi
  emit_deny "the dispatcher reads only the STATE.md and NEXT.md in a .agent/ folder or a sessions/<id>/ folder"
}

TOOL=$(jstr '.tool_name')
case "$TOOL" in
  "") emit_deny "no tool name in the hook input" ;;
  SendMessage)
    if [ "$EVAL" -eq 1 ]; then
      eval_log sendmessage "$(jq -c '.tool_input | {to:(.to // .recipient // null), message:(.message // .content // null)}' <<<"$INPUT")"
      emit_deny "EVAL: recorded, not sent" raw
    fi
    allow ;;
  ListAgents)
    if [ "$EVAL" -eq 1 ]; then emit_deny "EVAL: ListAgents is offline here; dash.sh --route lists the sessions" raw; fi
    allow ;;
  ToolSearch|mcp__voicemode__converse|mcp__plugin_voicemode_voicemode__converse) allow ;;
  Bash) check_bash ;;
  Read) check_read ;;
  *) emit_deny "$TOOL is not one of the dispatcher's tools (dash.sh, STATE.md/NEXT.md reads, ListAgents, SendMessage, converse). Tell the user what you could not do; do not try another way." ;;
esac
