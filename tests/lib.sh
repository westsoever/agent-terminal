# shellcheck shell=bash
# Test helpers. Sourced by tests/t_*.sh. Every test runs in its own sandbox under $T_ROOT with HOME,
# AGENT_HOME and CLAUDE_DIR redirected, so nothing here can touch the real machine state.
set -uo pipefail

KIT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
BIN=$KIT/bin
: "${T_ROOT:?run via tests/run.sh}"
TNAME=${TNAME:-$(basename "${0%.sh}")}
WORK=$T_ROOT/$TNAME
RESULTS=$T_ROOT/results.$TNAME
mkdir -p "$WORK/home"
: >"$RESULTS"

export HOME="$WORK/home"
export AGENT_HOME="$WORK/agent-home"
export CLAUDE_DIR="$WORK/claude"
export AGENT_REPOS_FILE="$WORK/agent-repos"
export LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"   # install.sh writes its plist here; set explicitly so no test relies on HOME by accident
export NOTIFY_DRY_RUN=1
export NOTIFY_TERMINAL_NOTIFIER="$WORK/no-such-terminal-notifier"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export CHING_TEST_MODELS=""   # tests never call a real model; t_escalate.sh sets its own fake
unset TMPDIR CHING_ALLOW_PUSH CHING_STOP_CHECK_RUNNING CHING_ESCALATING   # recursion markers inherited from a live stop-check.sh run
unset CLAUDE_CODE_ENTRYPOINT CHING_NO_CHECKPOINT   # the session running the tests must not switch the checkpoint gate off
unset CHING_LEARNER   # learner mode makes the session hooks exit at once and the guard deny; a test sets it where it means it
mkdir -p "$AGENT_HOME" "$CLAUDE_DIR"

# install.sh calls $LAUNCHCTL: a test must never reach the real launchd
cat >"$WORK/fake-launchctl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/launchctl.log"
# a test sets LAUNCHCTL_FAIL_BOOTSTRAP to make only the bootstrap subcommand fail
if [ -n "${LAUNCHCTL_FAIL_BOOTSTRAP:-}" ] && [ "${1:-}" = bootstrap ]; then printf '%s\n' "$*" >>"$(dirname "$0")/launchctl.failed"; exit 5; fi
EOS
chmod +x "$WORK/fake-launchctl"
export LAUNCHCTL="$WORK/fake-launchctl"

# Safe defaults for the nudge: no test can reach the real voice, the real idle read (ioreg) or the real
# VoiceMode conch, whatever it forgets to set. A test that needs its own value sets it after sourcing this file.
export SPEAK_CMD="${SPEAK_CMD:-true}"                        # no audio
export HID_IDLE_CMD="${HID_IDLE_CMD:-echo 99999}"            # away from the keyboard
export VOICEMODE_CONCH="${VOICEMODE_CONCH:-$WORK/no-such-conch}"
export IOREG_CMD="${IOREG_CMD:-true}"                        # prints nothing: unreadable
export SYNC_CHECK_CMD="${SYNC_CHECK_CMD:-true}"                  # the watcher starts no real git sync check in a test; t_watch and t_sync set their own

pass() { printf 'PASS\t%s\t%s\n' "$TNAME" "$1" >>"$RESULTS"; }
fail() { printf 'FAIL\t%s\t%s\n' "$TNAME" "$1" >>"$RESULTS"; printf 'FAIL [%s]: %s\n%s\n' "$TNAME" "$1" "${2:-}" >&2; }

assert_eq() { # name expected actual
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "  expected: $2"$'\n'"  actual:   $3"; fi
}
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) pass "$1" ;; *) fail "$1" "  missing: $3"$'\n'"  in: $2" ;; esac
}
assert_not_contains() { # name haystack needle
  case "$2" in *"$3"*) fail "$1" "  unexpected: $3"$'\n'"  in: $2" ;; *) pass "$1" ;; esac
}
assert_ok() { # name cmd...
  local n=$1; shift
  local out; if out=$("$@" 2>&1); then pass "$n"; else fail "$n" "  command failed: $*"$'\n'"$out"; fi
}
assert_fails() { # name cmd...
  local n=$1; shift
  local out; if out=$("$@" 2>&1); then fail "$n" "  command unexpectedly succeeded: $*"$'\n'"$out"; else pass "$n"; fi
}
assert_file() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "  missing file $2"; fi; }
assert_no_file() { if [ ! -e "$2" ]; then pass "$1"; else fail "$1" "  unexpected file $2"; fi; }

# ---- fixtures ----
mk_repo() { # name -> path of a repo on branch main with a bare origin; .agent/ is git-excluded
  local name=$1 r="$WORK/$1"
  git init -q -b main "$r"
  git init -q --bare -b main "$WORK/$name.git"
  git -C "$r" remote add origin "$WORK/$name.git"
  printf '.agent/\n' >>"$r/.git/info/exclude"
  echo "# $name" >"$r/README.md"
  git -C "$r" add README.md
  git -C "$r" commit -q -m init
  git -C "$r" push -q origin main
  git -C "$r" fetch -q origin
  git -C "$r" branch -q --set-upstream-to=origin/main main
  printf '%s' "$r"
}
write_goal() { # repo test_command [release_mode] [extra lines]
  mkdir -p "$1/.agent"
  {
    echo "# Goal"
    echo "test_command: $2"
    echo "release_mode: ${3:-auto}"
    echo "base_branch: main"
    if [ -n "${4:-}" ]; then printf '%s\n' "$4"; fi
  } >"$1/.agent/GOAL.md"
}
commit_file() { # repo file content msg
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add "$2"
  git -C "$1" commit -q -m "${4:-add $2}"
}
head_of() { git -C "$1" rev-parse HEAD; }

# ---- hook invocation ----
hook_json() { # event cwd [session_id] [extra jq object]
  local x=${4:-}; [ -n "$x" ] || x='{}'
  jq -n --arg e "$1" --arg c "$2" --arg s "${3:-sess-1}" --argjson x "$x" \
    '{hook_event_name:$e,cwd:$c,session_id:$s} + $x'
}
run_hook() { printf '%s' "$2" | "$BIN/$1"; }

guard_json() { # tool cwd tool_input_json
  jq -n --arg t "$1" --arg c "$2" --argjson i "$3" '{hook_event_name:"PreToolUse",tool_name:$t,cwd:$c,tool_input:$i}'
}
bash_json() { guard_json Bash "$1" "$(jq -n --arg c "$2" '{command:$c}')"; }
is_deny() { case "$1" in *'"permissionDecision": "deny"'*|*'"permissionDecision":"deny"'*) return 0 ;; esac; return 1; }

gdeny() { # name cwd command
  local out; out=$(printf '%s' "$(bash_json "$2" "$3")" | "$BIN/guard.sh" 2>&1)
  if is_deny "$out"; then pass "deny: $1"; else fail "deny: $1" "  command: $3"$'\n'"  guard said: ${out:-<allowed>}"; fi
}
gdeny_why() { # name cwd command prefix: denied, and the reason starts with "GUARD: <prefix>" (pins the rule)
  local out why; out=$(printf '%s' "$(bash_json "$2" "$3")" | "$BIN/guard.sh" 2>&1)
  why=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason // ""' 2>/dev/null || true)
  case "$why" in "GUARD: $4"*) pass "deny ($4): $1" ;; *) fail "deny ($4): $1" "  command: $3"$'\n'"  guard said: ${out:-<allowed>}" ;; esac
}
gallow() {
  local out; out=$(printf '%s' "$(bash_json "$2" "$3")" | "$BIN/guard.sh" 2>&1)
  if [ -z "$out" ]; then pass "allow: $1"; else fail "allow: $1" "  command: $3"$'\n'"  guard said: $out"; fi
}
tdeny() { # name tool cwd tool_input_json
  local out; out=$(printf '%s' "$(guard_json "$2" "$3" "$4")" | "$BIN/guard.sh" 2>&1)
  if is_deny "$out"; then pass "deny: $1"; else fail "deny: $1" "  input: $4"$'\n'"  guard said: ${out:-<allowed>}"; fi
}
tallow() {
  local out; out=$(printf '%s' "$(guard_json "$2" "$3" "$4")" | "$BIN/guard.sh" 2>&1)
  if [ -z "$out" ]; then pass "allow: $1"; else fail "allow: $1" "  input: $4"$'\n'"  guard said: $out"; fi
}

link_kit() { ln -sfn "$KIT" "$CLAUDE_DIR/ching"; }   # hooks and pre-push hooks call $CLAUDE_DIR/ching/bin
