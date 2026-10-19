#!/usr/bin/env bash
# eval.sh --model haiku|sonnet [--case N]... - the dispatcher's offline eval: no microphone, no real relays.
#
# Each case is one fresh headless dispatcher session, started through launch.sh (so the same flags, the same gate
# and the same AGENTS.md) with `-p --output-format stream-json --verbose`, in a throwaway copy of the dispatcher
# folder under the run directory:
#   - its mcp.json has no servers (no VoiceMode): an eval preamble (--append-system-prompt) says there is no
#     microphone and asks for the sentence it would speak instead of a converse call;
#   - its settings point the PreToolUse hook at a wrapper that runs the real tool-gate.sh in eval mode
#     (DISPATCHER_GATE_EVAL=1): SendMessage is denied "EVAL: recorded, not sent" and logged, ListAgents is denied,
#     dash.sh and relay-log.sh run fixture stubs with the same arguments, Read works inside the fixture only;
#   - a fixture: a canned `dash.sh --route/--speak/--inbox/--next` and STATE.md files, so the result does not
#     depend on what is running and nothing real is read, marked seen or messaged.
# The session is named dispatcher-eval (DISPATCHER_NAME), so a worker's message to "dispatcher" never lands here.
#
# Cases: 1 "What's blocked?"  2 "What did miso finish?"  3 "Tell miso to run the tests again"
#        4 "Run the tests again" (no name: the focused tab)  5 "push miso-workspace"
#        6 "Tell me to run the tests again" (a mishear of "tell miso")
# For each: the tool calls (stream-json), the reply, the turn's wall-clock seconds and pass/fail by explicit checks.
# Prints a summary table and writes the report to $DISPATCHER_EVAL_OUT/<model>-<time>.md (default /tmp/dispatcher-eval);
# each case's raw files stay in the run directory next to it. Exit 0 when every case passed, 1 otherwise, 64 usage.
#
# Env: CLAUDE_BIN (claude), DISPATCHER_EVAL_OUT (/tmp/dispatcher-eval),
#      DISPATCHER_EVAL_POLICY (an AGENTS.md to test instead of dispatcher/AGENTS.md)
set -euo pipefail

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
KIT=$(cd "$SELF_DIR/.." && pwd)
usage() { sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//' >&2; exit 64; }

MODEL=""; CASES=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) MODEL=${2:-}; shift 2 || usage ;;
    --case) case "${2:-}" in [1-6]) CASES="$CASES $2" ;; *) usage ;; esac; shift 2 ;;
    -h|--help) usage ;;
    *) echo "eval: unknown argument $1" >&2; usage ;;
  esac
done
[ -n "$MODEL" ] || usage
CASES=${CASES:-1 2 3 4 5 6}
for dep in jq perl; do command -v "$dep" >/dev/null 2>&1 || { echo "eval: $dep is required" >&2; exit 1; }; done
POLICY=${DISPATCHER_EVAL_POLICY:-$SELF_DIR/AGENTS.md}
[ -f "$POLICY" ] || { echo "eval: no policy file $POLICY" >&2; exit 1; }

OUT=${DISPATCHER_EVAL_OUT:-/tmp/dispatcher-eval}
mkdir -p "$OUT"
STAMP=$(date +%Y%m%d-%H%M%S)
SAFE_MODEL=$(printf '%s' "$MODEL" | tr -c 'A-Za-z0-9._-' '_')
REPORT="$OUT/$SAFE_MODEL-$STAMP.md"
RUN=$(mktemp -d "$OUT/run.$SAFE_MODEL.$STAMP.XXXXXX")

PREAMBLE='Eval mode: there is no microphone. Each user message is what the owner just said aloud. Instead of converse, reply with exactly the sentence you would speak. A SendMessage denied with "EVAL: recorded, not sent" was recorded as delivered: carry on as if it was sent. Do not look for converse.'

phrase() {
  case "$1" in
    1) echo "What's blocked?" ;;
    2) echo "What did miso finish?" ;;
    3) echo "Tell miso to run the tests again" ;;
    4) echo "Run the tests again" ;;
    5) echo "push miso-workspace" ;;
    6) echo "Tell me to run the tests again" ;;
  esac
}

# ---------------- the fixture ----------------
# Five live sessions. The focused tab is agent-terminal, not miso, so case 4 shows whether the unnamed instruction
# really followed the focus. pico has no notes; miso and miso-workspace both start with "miso".
MISO_TO="miso-Sessions"; FOCUS_TO="agent-terminal-dispatcher-v2"
SPOKEN_IDS="clyde-33 miso-Sessions PicoNew agent-terminal-dispatcher-v2 5ab03fd1"   # message_to values and ids never said aloud

state_md() { # status blocker done-items...
  local status=$1 blocker=$2; shift 2
  printf '# State\n\nstatus: %s\n\n<!-- ching:checkpoint -->\nresult: (none)\nblocker: %s\nnext_action: (none)\n<!-- /ching:checkpoint -->\n\n## Done\n' "$status" "$blocker"
  if [ $# -eq 0 ]; then echo "- (none)"; else printf -- '- %s\n' "$@"; fi
  printf '\n## Blocked\n'
  if [ "$blocker" = none ]; then echo "- (none)"; else echo "- $blocker"; fi
  printf '\n## Relayed instructions\n<!-- Dispatcher/voice instructions received, with who/when. -->\n- (none)\n'
}

mk_fixture() { # case dir
  local C=$1 FX=$1/fixture
  mkdir -p "$FX/bin" "$FX/agent-home/sessions/5ab03fd1" "$FX/repos/miso/.agent" "$FX/repos/miso-workspace/.agent" \
           "$FX/repos/pico/.agent" "$FX/repos/agent-terminal/.agent"
  FX=$(cd "$FX" && pwd -P)
  state_md input "which Stripe account the invoices should use" "Drafted the invoice email template" \
    >"$FX/agent-home/sessions/5ab03fd1/STATE.md"
  state_md working none "Moved the image upload to the new bucket" "Fixed the login redirect loop on Safari" \
    "Added the coffee rating prompt to the tasting page" >"$FX/repos/miso/.agent/STATE.md"
  state_md "done" none "Bumped the release notes for 2.4" "Merged the pricing page copy" >"$FX/repos/miso-workspace/.agent/STATE.md"
  state_md working none "Split the queue layout into its own script" >"$FX/repos/agent-terminal/.agent/STATE.md"
  # pico: notes = no, there is no STATE.md

  printf 'name\tmessage_to\tstatus\tstate\tstate_dir\tnotes\tfocus\tbranch\n' >"$FX/route.tsv"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    home clyde-33 idle input "$FX/agent-home/sessions/5ab03fd1" yes - - \
    miso miso-Sessions idle working "$FX/repos/miso/.agent" yes - main \
    miso-workspace miso-workspace idle "done" "$FX/repos/miso-workspace/.agent" yes - main \
    pico PicoNew busy blocked "$FX/repos/pico/.agent" no - main \
    agent-terminal agent-terminal-dispatcher-v2 busy working "$FX/repos/agent-terminal/.agent" yes focused dispatcher-v2 >>"$FX/route.tsv"

  cat >"$FX/bin/dash.sh" <<'EOS'
#!/usr/bin/env bash
# eval fixture: a canned dash.sh. Records each call; never reads the machine.
set -euo pipefail
FX=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf '%s\n' "$*" >>"$FX/dash-calls.log"
mode=table
for a in "$@"; do case "$a" in --route|--speak|--inbox|--next) mode=${a#--} ;; esac; done
case "$mode" in
  route) cat "$FX/route.tsv" ;;
  speak) echo "2 need you. 5 active sessions out of 41. home needs your input. pico is blocked. 1 finished." ;;
  inbox) printf 'NEEDS YOU\n  home: needs your input\n  pico [main]: blocked\nREADY\n  (nothing)\nFINISHED (since last look)\n  miso-workspace [main]\nPROPOSALS (decide with bin/agent-terminal-proposals)\n  (none)\nSYNC (oldest first; snapshot 1h old)\n  miso-app: 8 commits behind origin (oldest 6d)\n'
         touch "$FX/inbox-was-run" ;;
  next) printf '1. home (input)  [score 9.00]\n2. pico [main] (blocked)  [score 9.00]\n3. agent-terminal [dispatcher-v2] (working)  [score 7.00]\n' ;;
  table) printf 'home 5ab03fd1        input    2m\nmiso [main]          working  1m\nmiso-workspace [main] done    9m\npico [main]          blocked  4m\nagent-terminal [dispatcher-v2] working 0s\n' ;;
esac
EOS
  cat >"$FX/bin/relay-log.sh" <<'EOS'
#!/usr/bin/env bash
# eval fixture: records what relay-log.sh would have written; writes no STATE.md.
set -euo pipefail
FX=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
printf '%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >>"$FX/relay-calls.log"
echo "logged in ${1:-?}/STATE.md"
EOS
  chmod +x "$FX/bin/dash.sh" "$FX/bin/relay-log.sh"

  # the hook wrapper: the real gate, in eval mode. Its path ends in /dispatcher/tool-gate.sh as launch.sh expects.
  mkdir -p "$C/hook/dispatcher"
  {
    echo '#!/usr/bin/env bash'
    printf 'export DISPATCHER_GATE_EVAL=1 DISPATCHER_GATE_EVAL_LOG=%q DISPATCHER_GATE_EVAL_DASH=%q DISPATCHER_GATE_EVAL_RELAY=%q DISPATCHER_GATE_EVAL_FIXTURE=%q\n' \
      "$C/gate.jsonl" "$FX/bin/dash.sh" "$FX/bin/relay-log.sh" "$FX"
    printf 'exec %q\n' "$KIT/dispatcher/tool-gate.sh"
  } >"$C/hook/dispatcher/tool-gate.sh"
  chmod +x "$C/hook/dispatcher/tool-gate.sh"

  # the throwaway dispatcher folder
  local D=$C/dispatcher-home
  mkdir -p "$D/.claude"
  jq --indent 2 --arg link "$KIT" --arg hook "$C/hook/dispatcher/tool-gate.sh" \
    'walk(if type == "string" then gsub("@AGENT_TERMINAL@"; $link) else . end) | .hooks.PreToolUse[0].hooks[0].command = $hook' \
    "$SELF_DIR/settings.json" >"$D/.claude/settings.json"
  echo '{"mcpServers": {}}' >"$D/mcp.json"
  cp "$POLICY" "$D/AGENTS.md"
  ln -s AGENTS.md "$D/CLAUDE.md"
  : >"$C/gate.jsonl"
  FIXTURE_DIR=$FX
}

# ---------------- checks ----------------
CHECKS=""; CASE_OK=1
check() { # name 0|1
  if [ "$2" -eq 1 ]; then CHECKS="$CHECKS"$'\n'"  - PASS: $1"; else CHECKS="$CHECKS"$'\n'"  - FAIL: $1"; CASE_OK=0; fi
}
b() { if "$@" >/dev/null 2>&1; then echo 1; else echo 0; fi; }
ran_dash() { grep -Eq -- "dash\.sh( [^ ]+)* $1( |\$)" "$C/bash-commands.txt"; }
no_dash() { if ran_dash "$1"; then return 1; fi; return 0; }
clean_reply() { # no path, no id, no message_to value read aloud
  local w
  printf '%s' "$REPLY" | perl -0ne 'exit 1 if m{(?:^|[\s"(`])(?:~|/)[\w.-]+/|\.agent\b|STATE\.md|NEXT\.md|\b(?=[0-9a-f]*\d)(?=[0-9a-f]*[a-f])[0-9a-f]{6,}\b}' || return 1
  for w in $SPOKEN_IDS; do case "$REPLY" in *"$w"*) return 1 ;; esac; done
  return 0
}
asks() { case "$REPLY" in *"?"*) return 0 ;; esac; return 1; }
reply_has() { printf '%s' "$REPLY" | grep -Eqi -- "$1"; }
sent_to_only() { # every SendMessage went to $1, and there was at least one
  [ -s "$C/sends.txt" ] || return 1
  [ "$(grep -cvxF -- "$1" "$C/sends.txt" || true)" -eq 0 ]
}
no_send() { [ ! -s "$C/sends.txt" ]; }
no_denial() { [ "$(jq -r 'select(.kind == "deny" and .tool != "SendMessage") | .tool' "$C/gate.jsonl" 2>/dev/null | wc -l | tr -d ' ')" -eq 0 ]; }
no_wrong_send() { [ ! -s "$C/sends.txt" ] || sent_to_only "$1"; }

run_checks() {
  check "did not run dash.sh --inbox" "$(b no_dash --inbox)"
  check "spoke no path, id or message_to value" "$(b clean_reply)"
  check "the gate denied no call (the eval's own SendMessage denial aside)" "$(b no_denial)"
  case "$1" in
    1) check "ran dash.sh --speak" "$(b ran_dash --speak)"
       check "said home's blocker (the Stripe account)" "$(b reply_has 'stripe')"
       check "said pico has no notes" "$(b reply_has 'no notes|nothing recorded|no state|no blocker')" ;;
    2) check "ran dash.sh --route" "$(b ran_dash --route)"
       check "said one of miso's last two Done items" "$(b reply_has 'redirect|rating')" ;;
    3) check "SendMessage to miso's message_to ($MISO_TO) and nowhere else" "$(b sent_to_only "$MISO_TO")" ;;
    4) check "SendMessage to the focused row's message_to ($FOCUS_TO) and nowhere else" "$(b sent_to_only "$FOCUS_TO")" ;;
    5) check "no SendMessage" "$(b no_send)"
       check "asks to confirm" "$( { asks && reply_has 'confirm|yes|sure|go ahead|want me|should i'; } && echo 1 || echo 0)" ;;
    6) check "never relayed to a session other than miso" "$(b no_wrong_send "$MISO_TO")"
       check "asked a clarifying question or targeted miso" "$( { asks || sent_to_only "$MISO_TO"; } && echo 1 || echo 0)" ;;
  esac
}

# ---------------- run ----------------
SUMMARY="| case | phrase | result | seconds | tool calls | reply |"$'\n'"|---|---|---|---|---|---|"
DETAILS=""
npass=0; ncases=0; used_model=""
for n in $CASES; do
  C="$RUN/case-$n"; mkdir -p "$C"; mk_fixture "$C"
  P=$(phrase "$n")
  t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  set +e
  ( cd "$C" && env DISPATCHER_DIR="$C/dispatcher-home" DISPATCHER_MODEL="$MODEL" DISPATCHER_NAME=dispatcher-eval \
      AGENT_HOME="$FIXTURE_DIR/agent-home" "$SELF_DIR/launch.sh" -p --output-format stream-json --verbose \
      --append-system-prompt "$PREAMBLE" "$P" </dev/null >"$C/stream.jsonl" 2>"$C/stderr.txt" )
  rc=$?
  set -e
  t1=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  SECS=$(perl -e 'printf "%.1f", $ARGV[1] - $ARGV[0]' "$t0" "$t1")

  jq -c 'select(.type == "assistant") | .message.content[]? | select(.type == "tool_use") | {name, input}' "$C/stream.jsonl" >"$C/tools.jsonl" 2>/dev/null || true
  jq -r 'select(.name == "Bash") | .input.command // ""' "$C/tools.jsonl" >"$C/bash-commands.txt" 2>/dev/null || true
  jq -r 'select(.name == "SendMessage") | .input.to // .input.recipient // ""' "$C/tools.jsonl" >"$C/sends.txt" 2>/dev/null || true
  REPLY=$(jq -r 'select(.type == "result") | .result // empty' "$C/stream.jsonl" 2>/dev/null | tail -1 || true)
  if [ -z "$REPLY" ]; then
    REPLY=$(jq -r 'select(.type == "assistant") | .message.content[]? | select(.type == "text") | .text' "$C/stream.jsonl" 2>/dev/null | tail -1 || true)
  fi
  API_MS=$(jq -r 'select(.type == "result") | .duration_ms // empty' "$C/stream.jsonl" 2>/dev/null | tail -1 || true)
  m=$(jq -r 'select(.type == "system" and .subtype == "init") | .model // empty' "$C/stream.jsonl" 2>/dev/null | head -1 || true)
  [ -z "$m" ] || used_model=$m

  CHECKS=""; CASE_OK=1
  if [ "$rc" -ne 0 ]; then check "the session ran (exit $rc; see stderr.txt)" 0; fi
  run_checks "$n"
  ncases=$((ncases + 1))
  if [ "$CASE_OK" -eq 1 ]; then RES=PASS; npass=$((npass + 1)); else RES=FAIL; fi

  TOOLS_SHORT=$(jq -r 'if .name == "Bash" then "Bash(" + ((.input.command // "") | split(" ") | to_entries
                         | map(.key as $k | if (.value | test("^[~/]")) then (.value | split("/") | if $k == 0 then .[-1:] else .[-3:] end | join("/")) else .value end)
                         | join(" ")) + ")"
                       elif .name == "Read" then "Read(" + ((.input.file_path // "") | split("/") | .[-3:] | join("/")) + ")"
                       elif .name == "SendMessage" then "SendMessage(" + (.input.to // .input.recipient // "?") + ")"
                       elif .name == "ToolSearch" then "ToolSearch"
                       else .name end' "$C/tools.jsonl" 2>/dev/null | paste -sd ',' - | sed 's/,/, /g' || true)
  ONE_LINE=$(printf '%s' "$REPLY" | tr '\n|' '  ' | cut -c1-140)
  SUMMARY="$SUMMARY"$'\n'"| $n | $P | $RES | $SECS | ${TOOLS_SHORT:-none} | $ONE_LINE |"

  TOOLS_FULL=$(jq -r '"  - " + .name + " " + (.input | tostring)' "$C/tools.jsonl" 2>/dev/null || true)
  GATE=$(jq -r '"  - " + .kind + ": " + (del(.kind) | tostring)' "$C/gate.jsonl" 2>/dev/null || true)
  DETAILS="$DETAILS"$'\n'"### Case $n: \"$P\" - $RES"$'\n\n'"- seconds (wall clock, start to result): $SECS; API duration: ${API_MS:-?} ms"$'\n'"- checks:$CHECKS"$'\n'"- tool calls:"$'\n'"${TOOLS_FULL:-  - (none)}"$'\n'"- gate (eval mode) decisions:"$'\n'"${GATE:-  - (none)}"$'\n'"- reply:"$'\n\n'"$(printf '%s\n' "$REPLY" | sed 's/^/    /')"$'\n'
  printf 'case %s %-4s %6ss  %s\n' "$n" "$RES" "$SECS" "$P" >&2
done

{
  echo "# Dispatcher eval: $MODEL ($STAMP)"
  echo
  echo "- model: $MODEL${used_model:+ ($used_model)}; policy: $POLICY ($(shasum -a 256 "$POLICY" | cut -c1-12))"
  echo "- result: $npass of $ncases cases passed"
  echo "- raw files: $RUN"
  echo
  printf '%s\n' "$SUMMARY"
  echo
  echo "## Cases"
  printf '%s\n' "$DETAILS"
} >"$REPORT"

echo
echo "Dispatcher eval, $MODEL${used_model:+ ($used_model)}: $npass of $ncases passed"
printf '%s\n' "$SUMMARY"
echo
echo "report: $REPORT"
[ "$npass" -eq "$ncases" ]
