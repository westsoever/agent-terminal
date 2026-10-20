#!/usr/bin/env bash
# t_cl.sh - bin/cl: starts a background session with keys.toml's nw_* options and writes the select file agterm
# reads (D73). A fake claude on PATH records its arguments and folder.
. "$(dirname "$0")/lib.sh"

FAKE=$WORK/fakebin
mkdir -p "$FAKE" "$WORK/proj one"
cat >"$FAKE/claude" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$PWD" >"$(dirname "$0")/cwd"
printf '%s\n' "$@" >"$(dirname "$0")/args"
if [ -n "${FAKE_CLAUDE_FAIL:-}" ]; then echo "Error: Workspace not trusted. Run claude in this folder first." >&2; exit 1; fi
if [ -n "${FAKE_CLAUDE_NOJOB:-}" ]; then echo "something else"; exit 0; fi
printf 'session started\n\033[2mbackgrounded · 1a2b3c4d\033[0m\nclaude attach 1a2b3c4d\n'
EOS
chmod +x "$FAKE/claude"
export PATH="$FAKE:$PATH"
SEL=$AGENT_HOME/terminal/select
args() { tr '\n' ' ' <"$FAKE/args"; }

# no keys.toml: just the name, no prompt and no "--"
out=$(cd "$WORK/proj one" && "$BIN/cl" 2>/dev/null); rc=$?
assert_eq "cl exits 0" 0 "$rc"
assert_eq "cl prints the job id" 1a2b3c4d "$out"
assert_eq "cl passes --bg and the folder's name" "--bg -n proj one " "$(args)"
assert_eq "cl runs claude in the current folder" "$(cd "$WORK/proj one" && pwd)" "$(cat "$FAKE/cwd")"
now=$(date +%s); read -r job at <"$SEL"
assert_eq "the select file names the job" 1a2b3c4d "$job"
[ $((now - at)) -le 5 ] && pass "the select file holds the time" || fail "the select file holds the time" "  at=$at now=$now"

# keys.toml's nw_* options; [keys] lines don't count; the permission word maps to Claude Code's mode
mkdir -p "$AGENT_HOME/terminal"
cat >"$AGENT_HOME/terminal/keys.toml" <<'EOS'
nw_model = "claude-sonnet-5-5"
nw_effort = "high"
nw_permission = "bypass"   # a comment
[keys]
nw_model = "haiku"
EOS
rm -f "$SEL"
(cd "$WORK/proj one" && "$BIN/cl" hlp do x >/dev/null 2>&1)
assert_eq "cl hlp do x: name, keys.toml options, prompt after --" \
  "--bg -n hlp --model claude-sonnet-5-5 --effort high --permission-mode bypassPermissions -- do x " "$(args)"
assert_file "cl hlp writes the select file" "$SEL"

printf 'nw_model = ""\nnw_effort = ""\nnw_permission = ""\n' >"$AGENT_HOME/terminal/keys.toml"
(cd "$WORK/proj one" && "$BIN/cl" hlp -leading dash >/dev/null 2>&1)
assert_eq "empty options are left out; the prompt may start with -" "--bg -n hlp -- -leading dash " "$(args)"

# a folder Claude Code doesn't trust: claude's words, its exit code, no select file
rm -f "$SEL"
err=$(cd "$WORK/proj one" && FAKE_CLAUDE_FAIL=1 "$BIN/cl" 2>&1 >/dev/null); rc=$?
assert_eq "cl exits with claude's code" 1 "$rc"
assert_contains "cl prints claude's error" "$err" "Workspace not trusted"
assert_no_file "a failed start writes no select file" "$SEL"

# claude exits 0 but prints no job id: cl fails and writes nothing
err=$(cd "$WORK/proj one" && FAKE_CLAUDE_NOJOB=1 "$BIN/cl" 2>&1 >/dev/null); rc=$?
assert_eq "no job id: cl exits 1" 1 "$rc"
assert_contains "no job id: cl prints what claude said" "$err" "something else"
assert_no_file "no job id: no select file" "$SEL"

out=$("$BIN/cl" --help); rc=$?
assert_eq "cl --help exits 0" 0 "$rc"
assert_contains "cl --help shows the usage" "$out" "cl [name] [prompt...]"
