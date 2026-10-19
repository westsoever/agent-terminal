#!/usr/bin/env bash
# t_libpaths.sh - lib.sh is_sandbox_path: which working directories reports exclude.
. "$(dirname "$0")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

yes() { if is_sandbox_path "$2"; then pass "sandbox: $1"; else fail "sandbox: $1" "  not excluded: $2"; fi; }
no()  { if is_sandbox_path "$2"; then fail "real: $1" "  wrongly excluded: $2"; else pass "real: $1"; fi; }

yes "/tmp itself" /tmp
yes "under /tmp" /tmp/agent-terminal-tests.abc/repo
yes "private tmp" /private/tmp/agent-sandbox/repo
yes "private tmp itself" /private/tmp
yes "macOS temp" /var/folders/zz/abc/T/x
yes "private macOS temp" /private/var/folders/zz/abc/T/x
yes "task repo" /Users/clyde/bbq/eval/task3-repo
yes "inside task repo" /Users/clyde/bbq/eval/task12-repo/src
no "home" /Users/clyde
no "repo" /Users/clyde/bbq/miso
no "worktree" /Users/clyde/bbq/.worktrees/ching-a
no "name only looks like tmp" /Users/clyde/bbq/tmpfiles
no "tmp as a later component" /Users/clyde/bbq/tmp/x
no "task without -repo" /Users/clyde/bbq/task3
no "empty" ""

AGENT_TERMINAL_INCLUDE_SANDBOX=1 is_sandbox_path /tmp/x && fail "override" "  still excluded" || pass "override: AGENT_TERMINAL_INCLUDE_SANDBOX=1 includes everything"
