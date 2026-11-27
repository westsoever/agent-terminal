#!/usr/bin/env bash
# BSD and GNU userland: lib.sh file_mtime and epoch_date, notify.sh dates and delivery, queue.sh off macOS.
# The machine's own tools run as they are. Then a GNU coreutils and a BSD userland are imitated by shims on PATH, so both
# branches are covered on either OS. The shims model only what the hooks use:
#   GNU: stat --version, stat -c %Y, stat -f (filesystem status: prints a block of text and does not fail like BSD), date
#        --version, date -d @EPOCH, date -r FILE (a file, not an epoch);
#   BSD: stat -f %m, no stat -c, no --version, date -r EPOCH, and a date -d that must never be called.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"

export TZ=UTC
NOON=1699964000   # 2023-11-14 12:13:20 UTC
LATE=1700000000   # 2023-11-14 22:13:20 UTC, in the quiet hours
F="$WORK/mtime-file"; : >"$F"; touch -t 202311142213.20 "$F"
export REAL_DATE REAL_UNAME
REAL_DATE=$(command -v date); REAL_UNAME=$(command -v uname)

mk_shims() { # GNU|BSD -> the shim directory (SHIM_LOG records the calls that must not happen)
  local d="$WORK/shim-$1"; mkdir -p "$d"
  if [ "$1" = GNU ]; then
    cat >"$d/stat" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "stat (GNU coreutils) 9.4" ;;
  -c) printf 'gnu-stat -c\n' >>"$SHIM_LOG"
      [ "${2:-}" = %Y ] || exit 1
      perl -e '@s = stat($ARGV[0]) or do { print STDERR "stat: cannot statx $ARGV[0]\n"; exit 1 }; print "$s[9]\n"' "${3:-}" ;;
  -f) # file system status: %m is taken as a file name, the real file gets the default block; FAKE_STAT_F_RC is the exit status
      printf 'gnu-stat -f\n' >>"$SHIM_LOG"
      echo "stat: cannot read file system information for '${2:-}': No such file or directory" >&2
      printf '  File: "%s"\n    ID: 0        Namelen: 255     Type: ext2/ext3\nBlock size: 4096\n' "${3:-}"
      exit "${FAKE_STAT_F_RC:-0}" ;;
  *) exit 1 ;;
esac
EOS
    cat >"$d/date" <<'EOS'
#!/usr/bin/env bash
fmt() { perl -MPOSIX -e 'print strftime(substr($ARGV[1], 1), localtime($ARGV[0])), "\n"' "$1" "$2"; }
case "${1:-}" in
  --version) echo "date (GNU coreutils) 9.4" ;;
  -d) printf 'gnu-date -d\n' >>"$SHIM_LOG"
      case "${2:-}" in @*) fmt "${2#@}" "${3:-+%s}" ;; *) exit 1 ;; esac ;;
  -r) printf 'gnu-date -r\n' >>"$SHIM_LOG"   # a FILE: no such file, unless a test made one
      [ -e "${2:-}" ] || { echo "date: ${2:-}: No such file or directory" >&2; exit 1; }
      fmt "$(perl -e '@s = stat($ARGV[0]); print $s[9]' "$2")" "${3:-+%s}" ;;
  *) exec "$REAL_DATE" "$@" ;;
esac
EOS
  else
    cat >"$d/stat" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  -f) printf 'bsd-stat -f\n' >>"$SHIM_LOG"
      [ "${2:-}" = %m ] || exit 1
      perl -e '@s = stat($ARGV[0]) or exit 1; print "$s[9]\n"' "${3:-}" ;;
  *) echo "stat: illegal option -- ${1#-}" >&2; exit 1 ;;
esac
EOS
    cat >"$d/date" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in
  --version) echo "date: illegal option -- -" >&2; exit 1 ;;
  -d) printf 'bsd-date -d\n' >>"$SHIM_LOG"; exit 1 ;;   # BSD: a DST flag, never the epoch
  -r) perl -MPOSIX -e 'print strftime(substr($ARGV[1], 1), localtime($ARGV[0])), "\n"' "${2:-}" "${3:-+%s}" ;;
  *) exec "$REAL_DATE" "$@" ;;
esac
EOS
  fi
  chmod +x "$d/stat" "$d/date"
  printf '%s' "$d"
}
GNU=$(mk_shims GNU); BSD=$(mk_shims BSD)
export SHIM_LOG="$WORK/shim.log"; : >"$SHIM_LOG"

# ---------- file_mtime and epoch_date ----------
calls() { grep -c "^$1\$" "$SHIM_LOG" || true; }   # how often a shim logged that call
check_clock() { # label shimdir-or-empty
  local p=$PATH
  [ -z "$2" ] || PATH="$2:$PATH"
  hash -r
  assert_eq "$1: file_mtime reads the mtime as an integer" "$LATE" "$(file_mtime "$F")"
  assert_eq "$1: file_mtime of a missing file is 0" "0" "$(file_mtime "$WORK/no-such-file")"
  assert_eq "$1: epoch_date formats an epoch (hour and minute)" "12:13" "$(epoch_date "$NOON" +%H:%M)"
  assert_eq "$1: epoch_date formats an epoch (date and time)" "2023-11-14 12:13:20" "$(epoch_date "$NOON" '+%Y-%m-%d %H:%M:%S')"
  PATH=$p; hash -r
}
check_clock "this machine" ""
check_clock "BSD tools" "$BSD"
assert_eq "BSD tools: the BSD stat ran" "true" "$([ "$(calls 'bsd-stat -f')" -gt 0 ] && echo true || echo false)"
assert_eq "BSD tools: date -d is never called" "0" "$(calls 'bsd-date -d')"
FAKE_STAT_F_RC=0 check_clock "GNU tools (stat -f exits 0)" "$GNU"
FAKE_STAT_F_RC=1 check_clock "GNU tools (stat -f exits 1)" "$GNU"
assert_eq "GNU tools: stat -f was tried and refused, then stat -c answered" "true" \
  "$([ "$(calls 'gnu-stat -f')" -gt 0 ] && [ "$(calls 'gnu-stat -c')" -gt 0 ] && echo true || echo false)"
assert_eq "GNU tools: the epoch went through date -d @EPOCH" "true" "$([ "$(calls 'gnu-date -d')" -gt 0 ] && echo true || echo false)"
# GNU date -r takes a file: a file in the folder that is named like the epoch must not be read in its place
mkdir -p "$WORK/trap"; : >"$WORK/trap/$NOON"; touch -t 200101010101.01 "$WORK/trap/$NOON"
assert_eq "GNU tools: an epoch is never given to date -r" "12:13" "$(cd "$WORK/trap" && PATH="$GNU:$PATH" && hash -r && epoch_date "$NOON" +%H:%M)"
assert_eq "GNU tools: date -r is never called" "0" "$(calls 'gnu-date -r')"

# ---------- notify.sh: the quiet-hours clock, budget and log timestamps on either userland ----------
R=$(mk_repo portablerepo)
LOG="$AGENT_HOME/notify.log"
nt() { # shimdir session kind epoch
  printf '%s' "$(hook_json Notification "$R" "$2")" | PATH="$1:$PATH" NOTIFY_NOW=$4 "$BIN/notify.sh" "$3" m 2>"$WORK/nt.err"
}
for T in GNU BSD; do
  case "$T" in GNU) S=$GNU ;; *) S=$BSD ;; esac
  rm -rf "$AGENT_HOME/notify"; : >"$LOG"
  nt "$S" "p-$T-1" stall "$NOON"
  assert_contains "notify on $T tools: a budgeted alert by day is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
  assert_not_contains "notify on $T tools: not held back as no-clock" "$(cat "$LOG")" "no-clock"
  assert_contains "notify on $T tools: the log line has the time" "$(tail -1 "$LOG")" "2023-11-14 12:13:20"
  assert_eq "notify on $T tools: the day's budget is booked under the right date" "1" "$(cat "$AGENT_HOME/notify/budget-2023-11-14" 2>/dev/null)"
  nt "$S" "p-$T-2" stall "$LATE"
  assert_contains "notify on $T tools: 22:13 is the quiet hours" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
  assert_eq "notify on $T tools: no error output" "" "$(cat "$WORK/nt.err")"
done

# ---------- notify.sh delivery: osascript, else notify-send, else nothing shown ----------
cat >"$WORK/fake-notify-send" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OUT_NS"
EOS
cat >"$WORK/fake-osa2" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$FAKE_OUT_OSA"
EOS
chmod +x "$WORK/fake-notify-send" "$WORK/fake-osa2"
export FAKE_OUT_NS="$WORK/ns.out" FAKE_OUT_OSA="$WORK/osa2.out"
deliver() { # osascript notify-send kind message
  printf '%s' "$(hook_json Notification "$R" "d$RANDOM")" |
    NOTIFY_DRY_RUN='' NOTIFY_OSASCRIPT=$1 NOTIFY_NOTIFY_SEND=$2 NOTIFY_NOW=$NOON "$BIN/notify.sh" "$3" "$4" >"$WORK/dl.out" 2>&1
}
: >"$LOG"; : >"$FAKE_OUT_NS"; : >"$FAKE_OUT_OSA"
deliver "$WORK/no-such-osascript" "$WORK/fake-notify-send" blocked 'say "hi" & `rm -rf /`'
out=$(cat "$FAKE_OUT_NS")
assert_contains "no osascript: notify-send gets the title as argv" "$out" "portablerepo (main): Blocked"
assert_contains "no osascript: notify-send gets the message verbatim as argv" "$out" 'say "hi" & `rm -rf /`'
assert_contains "no osascript: the dash-dash keeps the title from being read as an option" "$(printf '%s' "$out" | tr '\n' ' ')" "-a agent-terminal -- "
assert_contains "no osascript: the log says notify-send" "$(tail -1 "$LOG")" $'\tnotify-send\t'
assert_eq "no osascript: nothing is printed" "" "$(cat "$WORK/dl.out")"
: >"$FAKE_OUT_NS"
deliver "$WORK/fake-osa2" "$WORK/fake-notify-send" blocked "both"
assert_contains "osascript present: it is used, as before" "$(cat "$FAKE_OUT_OSA")" "display notification"
assert_eq "osascript present: notify-send is not used" "" "$(cat "$FAKE_OUT_NS")"
assert_contains "osascript present: the log says osascript" "$(tail -1 "$LOG")" $'\tosascript\t'
: >"$LOG"
deliver "$WORK/no-such-osascript" "$WORK/no-such-notify-send" blocked "nobody home"; rc=$?
assert_eq "no notifier at all: exit 0" "0" "$rc"
assert_eq "no notifier at all: silent" "" "$(cat "$WORK/dl.out")"
assert_contains "no notifier at all: logged as none" "$(tail -1 "$LOG")" $'\tnone\t'
assert_eq "no notifier at all: not counted as delivered" "suppressed no-notifier" \
  "$(jq -r 'select(.kind=="notify") | "\(.data.outcome) \(.data.reason)"' "$AGENT_HOME/events.jsonl" | tail -1)"

# ---------- queue.sh: macOS only (osascript drives Terminal.app and Ghostty) ----------
cat >"$WORK/shim-GNU/uname" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in -s) echo Linux ;; *) exec "$REAL_UNAME" "$@" ;; esac
EOS
mkdir -p "$WORK/shim-mac"
cat >"$WORK/shim-mac/uname" <<'EOS'
#!/usr/bin/env bash
case "${1:-}" in -s) echo Darwin ;; *) exec "$REAL_UNAME" "$@" ;; esac
EOS
for d in "$WORK/shim-GNU" "$WORK/shim-mac"; do
  printf '#!/usr/bin/env bash\nprintf "osascript %%s\\n" "$*" >>"$SHIM_LOG"\n' >"$d/osascript"
  chmod +x "$d/uname" "$d/osascript"
done
: >"$SHIM_LOG"; rm -rf "$AGENT_HOME/queue"
out=$(unset QUEUE_TERM; PATH="$WORK/shim-GNU:$PATH" "$BIN/queue.sh" tile 2>&1); rc=$?
assert_eq "queue.sh off macOS: exit 0" "0" "$rc"
assert_eq "queue.sh off macOS: no output" "" "$out"
assert_no_file "queue.sh off macOS: no queue folder is made" "$AGENT_HOME/queue"
assert_eq "queue.sh off macOS: osascript is never run" "" "$(cat "$SHIM_LOG")"
out=$(unset QUEUE_TERM; PATH="$WORK/shim-mac:$PATH" "$BIN/queue.sh" status 2>&1); rc=$?
assert_eq "queue.sh on macOS: still runs" "0" "$rc"
assert_file "queue.sh on macOS: the queue folder is made" "$AGENT_HOME/queue"
rm -rf "$AGENT_HOME/queue"
PATH="$WORK/shim-GNU:$PATH" "$BIN/queue.sh" status >/dev/null 2>&1   # QUEUE_TERM (a helper) set, as in every other test: still runs off macOS
assert_file "queue.sh with a QUEUE_TERM helper runs off macOS too" "$AGENT_HOME/queue"
exit 0
