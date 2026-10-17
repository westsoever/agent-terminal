#!/usr/bin/env bash
# meta_set: the hooks and the watcher (kaching-watch.sh) write the same meta file; concurrent writers must not
# lose keys, a writer that dies must not leave a lock behind, and nobody waits long.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

SESS_DIR="$AGENT_HOME/sessions/meta-1"
nkeys() { grep -c '=' "$SESS_DIR/meta" 2>/dev/null || echo 0; }
ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }
LOCKF="$SESS_DIR/.meta.flock"
# hold LOCKF for SECS in the background; with "held" also append held=1 to meta while holding it
hold_lock() { # secs [held]
  perl -e 'use Fcntl ":flock"; my ($l, $m, $t, $h) = @ARGV; open(my $fh, ">>", $l) or die; flock($fh, LOCK_EX) or die;
    if ($h) { open(my $o, ">>", $m) or die; print $o "held=1\n"; close $o }
    select undef, undef, undef, $t;' "$LOCKF" "$SESS_DIR/meta" "$1" "${2:-}" &
  sleep 0.3   # let it take the lock first
}

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

# a live holder is waited for: the write lands after the holder lets go, and the holder's key is kept
hold_lock 1.5 held
s=$(ms); meta_set after_hold yes; e=$(ms)
wait
assert_eq "live lock: meta_set waited for the holder (at least 1 s)" "1" "$([ $((e - s)) -ge 1000 ] && echo 1 || echo 0)"
assert_eq "live lock: the holder's key is kept" "1" "$(meta_get "$SESS_DIR/meta" held)"
assert_eq "live lock: the waiting write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_hold)"

# a holder that hangs is waited for about 2 s at most (the UserPromptSubmit hook has 5 s), then the write goes ahead
hold_lock 6
s=$(ms); meta_set after_hang yes; e=$(ms)
assert_eq "hung holder: the wait is capped (under 3 s)" "1" "$([ $((e - s)) -lt 3000 ] && echo 1 || echo 0)"
assert_eq "hung holder: the write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_hang)"
kill %1 2>/dev/null; wait

# a holder that dies holds nothing: the kernel drops the lock with the process, so there is no stale lock
hold_lock 60; pid=$!
kill -9 "$pid"; wait "$pid" 2>/dev/null
s=$(ms); meta_set after_death yes; e=$(ms)
assert_eq "dead holder: no wait (under 0.5 s)" "1" "$([ $((e - s)) -lt 500 ] && echo 1 || echo 0)"
assert_eq "dead holder: the write landed" "yes" "$(meta_get "$SESS_DIR/meta" after_death)"

# a leftover mkdir lock directory from the previous meta_set does not block anything
mkdir -p "$SESS_DIR/.meta.lock"
meta_set after_old_lock yes
assert_eq "old lock directory: ignored" "yes" "$(meta_get "$SESS_DIR/meta" after_old_lock)"

# fast: 50 sequential writes well under 2 s (about 10 ms each)
s=$(ms); for i in $(seq 1 50); do meta_set "seq$i" "$i"; done; e=$(ms)
assert_eq "50 writes take under 2 s" "1" "$([ $((e - s)) -lt 2000 ] && echo 1 || echo 0)"

# an unwritable session dir makes meta_set fail (the caller decides), without hanging
RO="$AGENT_HOME/sessions/meta-ro"; mkdir -p "$RO"; chmod 500 "$RO"
SESS_DIR=$RO
if meta_set k v 2>/dev/null; then r=0; else r=1; fi
chmod 700 "$RO"
assert_eq "unwritable session dir: meta_set fails" "1" "$r"
assert_no_file "unwritable session dir: no meta written" "$RO/meta"
exit 0
