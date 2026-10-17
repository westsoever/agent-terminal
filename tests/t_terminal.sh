#!/usr/bin/env bash
# The agent terminal (terminal/, D33): its Go unit tests (transcript parsing, options, mentioned files, keys.toml,
# every view's geometry at several sizes, the Paperclip client against a fake server) and a syntax check of the
# Raycast opener. Without go the Go half is skipped with a note. Go's caches are kept out of the sandbox HOME: the
# build cache goes to $WORK, modules are read from the real user's cache with the network off.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

bash -n "$KIT/ui/raycast/kaching-open.sh" && pass "kaching-open.sh syntax" || fail "kaching-open.sh syntax"
grep -q '^# @raycast.title Open Agent Terminal' "$KIT/ui/raycast/kaching-open.sh" && pass "raycast title" || fail "raycast title"

GO=$(command -v go || ls /opt/homebrew/bin/go 2>/dev/null || true)
if [ -z "$GO" ]; then
  echo "go not installed: Go tests skipped" >"$T_ROOT/skipped.t_terminal"
  exit 0
fi
REAL_HOME=$(eval echo "~$(id -un)")
out=$(cd "$KIT/terminal" && GOCACHE="$WORK/gocache" GOPATH="$WORK/gopath" GOMODCACHE="$REAL_HOME/go/pkg/mod" \
  GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local "$GO" test ./... 2>&1) \
  && pass "go test terminal/" || fail "go test terminal/" "$out"
out=$(cd "$KIT/terminal" && GOCACHE="$WORK/gocache" GOPATH="$WORK/gopath" GOMODCACHE="$REAL_HOME/go/pkg/mod" \
  GOFLAGS=-mod=readonly GOPROXY=off GOTOOLCHAIN=local "$GO" vet ./... 2>&1) \
  && pass "go vet terminal/" || fail "go vet terminal/" "$out"
exit 0
