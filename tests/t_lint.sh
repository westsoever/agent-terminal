#!/usr/bin/env bash
# Syntax check of every script; shellcheck when available.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
for f in "$KIT"/bin/*.sh "$KIT"/bin/cl "$KIT"/install.sh "$KIT"/tests/*.sh "$KIT"/templates/pre-push "$KIT"/ui/menubar/build.sh; do
  assert_ok "bash -n $(basename "$f")" bash -n "$f"
done
for f in "$KIT"/bin/*.pl; do
  assert_ok "perl -c $(basename "$f")" perl -c "$f"
done
for f in "$KIT"/bin/*.sh "$KIT"/bin/cl "$KIT"/install.sh "$KIT"/templates/pre-push "$KIT"/ui/menubar/build.sh; do
  [ "$(basename "$f")" = lib.sh ] && continue
  head=$(sed -n 1,40p "$f")
  case "$head" in *"set -euo pipefail"*) pass "strict mode: $(basename "$f")" ;; *) fail "strict mode: $(basename "$f")" "no set -euo pipefail in the first lines" ;; esac
done
SC=$(command -v shellcheck || true); [ -n "$SC" ] || { [ -x /tmp/sc-venv/bin/shellcheck ] && SC=/tmp/sc-venv/bin/shellcheck; }
if [ -n "$SC" ]; then
  for f in "$KIT"/bin/*.sh "$KIT"/bin/cl "$KIT"/install.sh "$KIT"/ui/menubar/build.sh; do
    out=$(cd "$(dirname "$f")" && "$SC" -x -S warning "$(basename "$f")" 2>&1) && pass "shellcheck $(basename "$f")" || fail "shellcheck $(basename "$f")" "$out"
  done
else
  echo "shellcheck not installed: skipped" >"$T_ROOT/skipped.t_lint"
fi
exit 0
