#!/usr/bin/env bash
# meta_set: the hooks and the watcher (ching-watch.sh) write the same meta file; concurrent writers must not
# lose keys, and a lock left behind by a dead writer must not hang anyone.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

SESS_DIR="$AGENT_HOME/sessions/meta-1"
nkeys() { grep -c '=' "$SESS_DIR/meta" 2>/dev/null || echo 0; }

# 4 writers x 8 keys at once, 10 rounds: every round must keep all 32 keys (unlocked, the probe lost keys in 39 of 40)
lost=0
for round in 1 2 3 4 5 6 7 8 9 10; do
  rm -rf "$SESS_DIR"
  for w in 1 2 3 4; do
    ( for k in 1 2 3 4 5 6 7 8; do meta_set "w${w}k$k" "$round"; done ) &
  done
  wait
  [ "$(nkeys)" -eq 32 ] || lost=$((lost + 1))
done
assert_eq "concurrent writers: no round lost a key (4 writers x 8 keys, 10 rounds)" "0" "$lost"
assert_eq "concurrent writers: no lock left behind" "" "$(ls -A "$SESS_DIR" | grep -v '^meta$' || true)"

# the same key written again keeps one line with the last value
meta_set w1k1 last
assert_eq "rewrite: one line per key" "1" "$(grep -c '^w1k1=' "$SESS_DIR/meta")"
assert_eq "rewrite: last value wins" "last" "$(meta_get "$SESS_DIR/meta" w1k1)"

# a lock left by a writer that died (older than the stale limit) is taken over, not waited on forever
mkdir "$SESS_DIR/.meta.lock"; touch -t 202001010000 "$SESS_DIR/.meta.lock"
s=$(date +%s); meta_set stale ok; e=$(date +%s)
assert_eq "stale lock: the write goes through" "ok" "$(meta_get "$SESS_DIR/meta" stale)"
assert_eq "stale lock: taken over quickly (under 3 s)" "1" "$([ $((e - s)) -lt 3 ] && echo 1 || echo 0)"
assert_no_file "stale lock: released after the write" "$SESS_DIR/.meta.lock"

# a live holder is waited for: the write lands after the holder lets go, and nothing it wrote is lost
mkdir "$SESS_DIR/.meta.lock"
( sleep 1; printf 'held=1\n' >>"$SESS_DIR/meta"; rmdir "$SESS_DIR/.meta.lock" ) &
meta_set after_hold yes
wait
assert_eq "live lock: waited, the holder's key is kept" "1" "$(meta_get "$SESS_DIR/meta" held)"
assert_eq "live lock: the waiting write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_hold)"

# fast: 50 sequential writes well under 5 s
s=$(date +%s); for i in $(seq 1 50); do meta_set "seq$i" "$i"; done; e=$(date +%s)
assert_eq "50 writes take under 5 s" "1" "$([ $((e - s)) -lt 5 ] && echo 1 || echo 0)"

# an unwritable session dir makes meta_set fail (the caller decides), without leaving a lock or hanging
RO="$AGENT_HOME/sessions/meta-ro"; mkdir -p "$RO"; chmod 500 "$RO"
SESS_DIR=$RO
if meta_set k v 2>/dev/null; then r=0; else r=1; fi
chmod 700 "$RO"
assert_eq "unwritable session dir: meta_set fails" "1" "$r"
assert_no_file "unwritable session dir: no lock left" "$RO/.meta.lock"
exit 0
