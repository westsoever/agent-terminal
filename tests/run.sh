#!/usr/bin/env bash
# tests/run.sh - run every tests/t_*.sh in parallel, each in its own sandbox under a /tmp dir, and print
# pass/fail counts. Exit status is non-zero when anything failed. Set KEEP=1 to keep the sandbox.
set -uo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
T_ROOT=$(mktemp -d /tmp/ching-tests.XXXXXX)
export T_ROOT
[ -z "${KEEP:-}" ] && trap 'rm -rf "$T_ROOT"' EXIT

pids=""
for f in "$HERE"/t_*.sh; do
  name=$(basename "$f" .sh)
  ( TNAME=$name bash "$f" >"$T_ROOT/$name.log" 2>&1; echo $? >"$T_ROOT/$name.rc" ) &
  pids="$pids $!"
done
# shellcheck disable=SC2086
wait $pids

total_pass=0; total_fail=0
printf '%-14s %6s %6s\n' file pass fail
for f in "$HERE"/t_*.sh; do
  name=$(basename "$f" .sh)
  p=0; fl=0
  if [ -f "$T_ROOT/results.$name" ]; then
    p=$(grep -c '^PASS' "$T_ROOT/results.$name" || true)
    fl=$(grep -c '^FAIL' "$T_ROOT/results.$name" || true)
  fi
  rc=$(cat "$T_ROOT/$name.rc" 2>/dev/null || echo 99)
  if [ "$rc" != 0 ]; then
    fl=$((fl + 1))
    printf 'FAIL\t%s\tscript exited %s\n' "$name" "$rc" >>"$T_ROOT/results.$name"
  fi
  printf '%-14s %6s %6s\n' "$name" "$p" "$fl"
  total_pass=$((total_pass + p)); total_fail=$((total_fail + fl))
done
if [ "$total_fail" -gt 0 ]; then
  echo; echo "== failures"
  grep -h '^FAIL' "$T_ROOT"/results.* | cut -f2- | sed 's/\t/: /'
  echo; echo "== details (stderr of failing tests)"
  for f in "$HERE"/t_*.sh; do
    name=$(basename "$f" .sh)
    if grep -q '^FAIL' "$T_ROOT/results.$name" 2>/dev/null; then cat "$T_ROOT/$name.log"; fi
  done
fi
skipped=$(cat "$T_ROOT"/skipped.* 2>/dev/null | wc -l | tr -d ' ')
echo
echo "TOTAL: $total_pass passed, $total_fail failed${skipped:+, $skipped skipped}"
[ -z "${KEEP:-}" ] || echo "sandbox kept: $T_ROOT"
[ "$total_fail" -eq 0 ]
