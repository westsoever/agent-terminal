#!/usr/bin/env bash
# meta_set: the hooks and the watcher (agent-terminal-watch.sh) write the same meta file; concurrent writers must not
# lose keys, a writer that dies must not leave a lock behind, and nobody waits long.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

SESS_DIR="$AGENT_HOME/sessions/meta-1"
nkeys() { grep -c '=' "$SESS_DIR/meta" 2>/dev/null || echo 0; }
LOCKF="$SESS_DIR/.meta.flock"
HOLD_READY="$WORK/hold.ready"; HOLD_FREED="$WORK/hold.freed"
# hold LOCKF for SECS in the background; with "held" also append held=1 to meta while holding it. Returns once the
# holder has the lock (HOLD_READY); just before letting go the holder writes the time in ms to HOLD_FREED.
hold_lock() { # secs [held]
  rm -f "$HOLD_READY" "$HOLD_FREED"
  perl -MTime::HiRes=time -e 'use Fcntl ":flock"; my ($l, $m, $t, $h, $r, $f) = @ARGV;
    open(my $fh, ">>", $l) or die; flock($fh, LOCK_EX) or die;
    if ($h) { open(my $o, ">>", $m) or die; print $o "held=1\n"; close $o }
    open(my $rd, ">", $r) or die; close $rd;
    select undef, undef, undef, $t;
    open(my $fr, ">", "$f.tmp") or die; printf $fr "%d\n", time * 1000; close $fr; rename "$f.tmp", $f;' \
    "$LOCKF" "$SESS_DIR/meta" "$1" "${2:-}" "$HOLD_READY" "$HOLD_FREED" &
  local i=0; while [ ! -e "$HOLD_READY" ] && [ "$i" -lt 600 ]; do sleep 0.05; i=$((i + 1)); done   # up to 30 s
}
# one uncontended meta_set, in ms: what a write costs under the current load, without any lock wait
bare_write_ms() { local s e; s=$(ms); meta_set bare_write 1; e=$(ms); echo $((e - s)); }

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
assert_eq "concurrent writers: no temp file left behind" "" "$(ls -A "$SESS_DIR" | grep -v -e '^meta$' -e '^\.meta\.flock$' || true)"

# the same key written again keeps one line with the last value; a key is matched literally, not as a regex
meta_set w1k1 last
assert_eq "rewrite: one line per key" "1" "$(grep -c '^w1k1=' "$SESS_DIR/meta")"
assert_eq "rewrite: last value wins" "last" "$(meta_get "$SESS_DIR/meta" w1k1)"
meta_set 'w.k1' dot
assert_eq "a key with a dot does not replace other keys" "last" "$(meta_get "$SESS_DIR/meta" w1k1)"
printf 'nonl=1' >>"$SESS_DIR/meta"   # a last line without a newline is not glued to the next key
meta_set after_nonl yes
assert_eq "last line without newline: kept" "1" "$(meta_get "$SESS_DIR/meta" nonl)"
assert_eq "last line without newline: new key on its own line" "yes" "$(meta_get "$SESS_DIR/meta" after_nonl)"
# several pairs in one call: each key replaced once, the others kept
meta_set w1k1 multi w2k2 "two words" fresh ""
assert_eq "pairs: first key replaced" "multi" "$(meta_get "$SESS_DIR/meta" w1k1)"
assert_eq "pairs: value with a space" "two words" "$(meta_get "$SESS_DIR/meta" w2k2)"
assert_eq "pairs: empty value written" "1" "$(grep -c '^fresh=$' "$SESS_DIR/meta")"
assert_eq "pairs: one line per key" "1" "$(grep -c '^w2k2=' "$SESS_DIR/meta")"
assert_eq "pairs: other keys kept" "yes" "$(meta_get "$SESS_DIR/meta" after_nonl)"

# a live holder is waited for: the write lands after the holder lets go, and the holder's key is kept
hold_lock 1.5 held
meta_set after_hold yes; e=$(ms)
wait
freed=$(cat "$HOLD_FREED" 2>/dev/null || echo 99999999999999)
assert_eq "live lock: meta_set waited for the holder (returned after it let go)" "1" "$([ "$e" -ge "$freed" ] && echo 1 || echo 0)"
assert_eq "live lock: the holder's key is kept" "1" "$(meta_get "$SESS_DIR/meta" held)"
assert_eq "live lock: the waiting write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_hold)"

# a holder that hangs is waited for about 2 s at most (the UserPromptSubmit hook has 5 s), then the write goes ahead.
# The wait is the time beyond an uncontended write taken just before: under the parallel suite a bare perl start
# alone can cost hundreds of ms, which is load, not lock wait.
bare=$(bare_write_ms)
hold_lock 6
s=$(ms); meta_set after_hang yes; e=$(ms)
assert_eq "hung holder: the wait is capped (under 3 s; took $((e - s)) ms, an uncontended write $bare ms)" "1" "$([ $((e - s - bare)) -lt 3000 ] && echo 1 || echo 0)"
assert_eq "hung holder: the write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_hang)"
kill %1 2>/dev/null; wait

# a holder that dies holds nothing: the kernel drops the lock with the process, so there is no stale lock
hold_lock 60; pid=$!
kill -9 "$pid"; wait "$pid" 2>/dev/null
bare=$(bare_write_ms)
s=$(ms); meta_set after_death yes; e=$(ms)
assert_eq "dead holder: no wait (under 0.5 s; took $((e - s)) ms, an uncontended write $bare ms)" "1" "$([ $((e - s - bare)) -lt 500 ] && echo 1 || echo 0)"
assert_eq "dead holder: the write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_death)"

# a leftover mkdir lock directory from the previous meta_set does not block anything
mkdir -p "$SESS_DIR/.meta.lock"
meta_set after_old_lock yes
assert_eq "old lock directory: ignored" "yes" "$(meta_get "$SESS_DIR/meta" after_old_lock)"

# fast: 50 sequential writes cost about 2.5 bare perl starts each (idle about 8 ms a write). A fixed limit fails when
# the parallel suite loads the machine, so the limit is 4 times a bare-perl baseline plus 1 s, taken in 5 rounds of 10
# that alternate with the writes so both see the same load. Idle that is about 1.6 s against about 0.4 s of writes.
base=0; writes=0
for r in 1 2 3 4 5; do
  s=$(ms); for i in 1 2 3 4 5 6 7 8 9 10; do perl -e 1; done; e=$(ms); base=$((base + e - s))
  s=$(ms); for i in 1 2 3 4 5 6 7 8 9 10; do meta_set "seq$r$i" "$i"; done; e=$(ms); writes=$((writes + e - s))
done
assert_eq "50 writes take under 4 bare perl starts each plus 1 s (writes ${writes} ms, baseline ${base} ms)" "1" \
  "$([ "$writes" -lt $((4 * base + 1000)) ] && echo 1 || echo 0)"

# an unwritable session dir makes meta_set fail (the caller decides), without hanging
RO="$AGENT_HOME/sessions/meta-ro"; mkdir -p "$RO"; chmod 500 "$RO"
SESS_DIR=$RO
if meta_set k v 2>/dev/null; then r=0; else r=1; fi
chmod 700 "$RO"
assert_eq "unwritable session dir: meta_set fails" "1" "$r"
assert_no_file "unwritable session dir: no meta written" "$RO/meta"
exit 0
