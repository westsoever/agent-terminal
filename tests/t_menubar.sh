#!/usr/bin/env bash
# The menu bar dot (ui/menubar): the watcher's heartbeat and dash.sh --counts (no swiftc needed), then, with swiftc,
# the app bundle, the dot's state from fixture files (KachingBar --status-once), and install.sh --install-menubar in the
# sandbox HOME: plist content, dry run, idempotence, uninstall. Also the voice shortcut: the chord tap
# (--chord-test), its menu line, and one wake on fixture sessions (--wake-once, mostly --dry-run). Without swiftc the
# build half is skipped with a note.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NOW=$(date +%s)
mk_sess() { # sid state [updated] -> a registry entry
  mkdir -p "$AGENT_HOME/sessions/$1"
  printf 'cwd=%s\nstate=%s\nupdated=%s\n' "$WORK/plain" "$2" "${3:-$NOW}" >"$AGENT_HOME/sessions/$1/meta"
}
mkdir -p "$WORK/plain"
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }

# ---------- dash.sh --counts: the registry only, and read-only ----------
out=$("$BIN/dash.sh" --counts 2>&1)
assert_eq "counts: empty AGENT_HOME is all zeros" "sessions=0 active=0 blocked=0 input=0 needs=0 proposals=0" "$(printf '%s' "$out" | tr '\n' ' ' | sed 's/ $//')"
mk_sess s-work working
mk_sess s-input input
mk_sess s-block blocked
mk_sess s-done "done"
mk_sess s-ended ended
mk_sess s-old input $((NOW - 3 * 86400))                   # older than 24 h: not counted
mk_sess s-note working; printf '# State\n\n## Blocked\n- need the staging token\n' >"$AGENT_HOME/sessions/s-note/STATE.md"
mkdir -p "$CLAUDE_DIR/projects/-x"; printf '{"cwd":"/x"}\n' >"$CLAUDE_DIR/projects/-x/tr-only.jsonl"   # transcript-only: skipped by --counts
out=$("$BIN/dash.sh" --counts 2>&1)
assert_eq "counts: sessions = live registry entries of the last 24 h" "5" "$(kv "$out" sessions)"
assert_eq "counts: a STATE.md blocker makes a working session blocked" "2" "$(kv "$out" blocked)"
assert_eq "counts: input" "1" "$(kv "$out" input)"
assert_eq "counts: needs = blocked + input" "3" "$(kv "$out" needs)"
assert_eq "counts: active (working/blocked/input in the last 30 min)" "4" "$(kv "$out" active)"
assert_no_file "counts: never marks the inbox seen" "$AGENT_HOME/inbox.seen"
assert_contains "the default view still lists the transcript-only session" "$("$BIN/dash.sh")" "tr-only"
mkdir -p "$AGENT_HOME/proposals"
printf 'id: rule-x\nkind: rule\nstatus: open\nsessions: 3\ndays: 2\n\n## proposal\nAdd a rule.\n' >"$AGENT_HOME/proposals/rule-x.md"
printf 'id: rule-y\nkind: rule\nstatus: approved\nsessions: 3\ndays: 2\n\n## proposal\nDone.\n' >"$AGENT_HOME/proposals/rule-y.md"
assert_eq "counts: open proposals only" "1" "$(kv "$("$BIN/dash.sh" --counts)" proposals)"

# ---------- the watcher's heartbeat ----------
HB_AH="$WORK/hb-agent"; mkdir -p "$HB_AH"
AGENT_HOME="$HB_AH" SYNC_CHECK_INTERVAL_H=0 "$BIN/kaching-watch.sh" >/dev/null 2>&1
assert_file "watcher tick writes watch.heartbeat" "$HB_AH/watch.heartbeat"
hb=$(cat "$HB_AH/watch.heartbeat" 2>/dev/null || echo 0)
if [ $((NOW - hb)) -le 60 ] && [ $((hb - NOW)) -le 60 ]; then pass "heartbeat holds the current time"; else fail "heartbeat holds the current time" "  got $hb, now $NOW"; fi
mkdir "$HB_AH/watch.lock"; touch -t "$(date -r $((NOW - 3600)) +%Y%m%d%H%M.%S)" "$HB_AH/watch.heartbeat"
AGENT_HOME="$HB_AH" SYNC_CHECK_INTERVAL_H=0 "$BIN/kaching-watch.sh" >/dev/null 2>&1
if [ $(( $(date +%s) - $(stat -f %m "$HB_AH/watch.heartbeat") )) -le 60 ]; then pass "heartbeat is written even while the previous tick holds the lock"; else fail "heartbeat is written even while the previous tick holds the lock"; fi
rmdir "$HB_AH/watch.lock"

# ---------- the app: skipped without swiftc ----------
SWIFTC_BIN=${SWIFTC:-}
[ -n "$SWIFTC_BIN" ] || { if [ -x /usr/bin/swiftc ]; then SWIFTC_BIN=/usr/bin/swiftc; else SWIFTC_BIN=$(command -v swiftc 2>/dev/null || true); fi; }
if [ -z "$SWIFTC_BIN" ] || ! "$SWIFTC_BIN" --version >/dev/null 2>&1; then
  echo "swiftc not found: t_menubar build, status and install checks skipped" >"$T_ROOT/skipped.t_menubar"
  exit 0
fi

BUILD="$KIT/ui/menubar/build.sh"
OUT="$WORK/build"
out=$("$BUILD" "$OUT" 2>&1); rc=$?
assert_eq "build exits 0" "0" "$rc"
APP="$OUT/KachingBar.app"; EXE="$APP/Contents/MacOS/KachingBar"; PL="$APP/Contents/Info.plist"
if [ "$rc" -ne 0 ]; then fail "build output" "$out"; exit 0; fi
assert_contains "build says where" "$out" "built: "
if [ -x "$EXE" ]; then pass "bundle has an executable"; else fail "bundle has an executable" "  missing $EXE"; fi
pget() { /usr/bin/plutil -extract "$1" raw "$PL" 2>/dev/null; }
assert_eq "Info.plist: bundle id" "org.kaching.menubar" "$(pget CFBundleIdentifier)"
assert_eq "Info.plist: LSUIElement (no Dock icon)" "true" "$(pget LSUIElement)"
assert_eq "Info.plist: executable name" "KachingBar" "$(pget CFBundleExecutable)"
assert_eq "Info.plist: package type" "APPL" "$(pget CFBundlePackageType)"
assert_eq "Info.plist: source hash matches build.sh --hash" "$("$BUILD" --hash)" "$(pget KachingSourceHash)"
assert_contains "the binary is arm64" "$(file "$EXE")" "arm64"
m1=$(stat -f %m "$EXE"); i1=$(stat -f %i "$EXE")
out=$("$BUILD" "$OUT" 2>&1)
assert_contains "second build is a no-op" "$out" "up to date"
assert_eq "second build leaves the binary alone" "$m1 $i1" "$(stat -f %m "$EXE") $(stat -f %i "$EXE")"
assert_eq "no staging dirs left behind" "" "$(find "$OUT" -maxdepth 1 -name '.KachingBar.build.*')"
assert_fails "an unknown CLI argument is refused" "$EXE" --bogus

# ---------- hotkeys (D39): KachingBar --hotkeys-check ----------
H_AH="$WORK/hk-agent"; mkdir -p "$H_AH"
hk() { AGENT_HOME="$H_AH" "$EXE" --hotkeys-check 2>&1; }
out=$(hk)
assert_contains "hotkeys: default ctrl+option+n runs next" "$out" "key=45 mods=6144 script=ui/raycast/kaching-next.sh"
assert_contains "hotkeys: default ctrl+option+t runs tile" "$out" "key=17 mods=6144 script=ui/raycast/kaching-tile.sh"
assert_contains "hotkeys: default ctrl+option+k opens kaching" "$out" "key=40 mods=6144 script=ui/raycast/kaching-open.sh"
printf '# mine\ncmd+shift+1  ~/bin/x.sh   # a comment\nctrl+q\nhyper+n  y.sh\n\n' >"$H_AH/hotkeys"
out=$(hk)
assert_eq "hotkeys: the file replaces the defaults" "key=18 mods=768 script=~/bin/x.sh
bad=ctrl+q
bad=hyper+n" "$out"

# ---------- the dot's state: KachingBar --status-once on fixtures ----------
S_AH="$WORK/st-agent"; S_LA="$WORK/st-launchagents"; mkdir -p "$S_AH/sessions" "$S_LA"
status() { AGENT_HOME="$S_AH" LAUNCH_AGENTS_DIR="$S_LA" KACHING_DIR="$KIT" "$EXE" --status-once 2>&1; }
st_sess() { mkdir -p "$S_AH/sessions/$1"; printf 'cwd=%s\nstate=%s\nupdated=%s\n' "$WORK/plain" "$2" "$(date +%s)" >"$S_AH/sessions/$1/meta"; }
ago() { touch -t "$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)" "$1"; }

out=$(status)
assert_eq "status: nothing installed -> grey" "grey" "$(kv "$out" state)"
assert_eq "status: watcher not installed" "no" "$(kv "$out" watcher_installed)"
assert_contains "status: menu says the watcher is not installed" "$out" "menu=Watcher not installed (org.kaching.watch) [info]"
: >"$S_LA/org.kaching.watch.plist"
out=$(status)
assert_eq "status: plist but no heartbeat -> grey" "grey" "$(kv "$out" state)"
assert_eq "status: no heartbeat age" "none" "$(kv "$out" heartbeat_age)"
date +%s >"$S_AH/watch.heartbeat"
st_sess a working
out=$(status)
assert_eq "status: fresh heartbeat, nobody waiting -> green" "green" "$(kv "$out" state)"
assert_eq "status: running" "yes" "$(kv "$out" running)"
assert_eq "status: status line" "Kaching running · 1 session · 0 need you" "$(kv "$out" status)"
assert_contains "status: Open inbox in the menu" "$out" "menu=Open inbox"
assert_contains "status: transcripts placeholder is disabled" "$out" "menu=Transcripts (coming soon) [disabled]"
assert_contains "status: Quit in the menu" "$out" "menu=Quit KachingBar"
assert_not_contains "status: no proposals line without proposals" "$out" "Proposals waiting"
st_sess b input
out=$(status)
assert_eq "status: a session waiting for input -> amber" "amber" "$(kv "$out" state)"
assert_eq "status: needs 1" "1" "$(kv "$out" needs)"
assert_eq "status: status line with one waiting" "Kaching running · 2 sessions · 1 needs you" "$(kv "$out" status)"
st_sess c blocked
assert_eq "status: blocked counts as needing you" "2" "$(kv "$(status)" needs)"
mkdir -p "$S_AH/proposals"
printf 'id: rule-x\nkind: rule\nstatus: open\nsessions: 3\ndays: 2\n\n## proposal\nAdd a rule.\n' >"$S_AH/proposals/rule-x.md"
out=$(status)
assert_contains "status: open proposals get a menu line" "$out" "menu=Proposals waiting: 1"
ago "$S_AH/watch.heartbeat" 600
assert_eq "status: heartbeat 10 min old is still running (two ticks)" "amber" "$(kv "$(status)" state)"
ago "$S_AH/watch.heartbeat" 1800
out=$(status)
assert_eq "status: stale heartbeat -> grey even with sessions waiting" "grey" "$(kv "$out" state)"
assert_contains "status: stale says not running" "$(kv "$out" status)" "Kaching not running"
assert_contains "status: stale says since when" "$out" "Watcher silent since 30m ago"
assert_eq "status: KACHING_BAR_STALE_SECS widens the window" "amber" "$(kv "$(KACHING_BAR_STALE_SECS=3600 status)" state)"
: >"$S_AH/watch.log"
assert_eq "status: a fresh watch.log counts as a heartbeat too" "amber" "$(kv "$(status)" state)"
ago "$S_AH/watch.log" 1800
rm -f "$S_LA/org.kaching.watch.plist"; date +%s >"$S_AH/watch.heartbeat"
assert_eq "status: fresh heartbeat but no watcher plist -> grey" "grey" "$(kv "$(status)" state)"
: >"$S_LA/org.kaching.watch.plist"
out=$(AGENT_HOME="$S_AH" LAUNCH_AGENTS_DIR="$S_LA" KACHING_DIR="$WORK/no-kit" "$EXE" --status-once 2>&1)
assert_eq "status: no dash.sh -> still green/amber/grey from the heartbeat, counts unavailable" "unavailable" "$(kv "$out" counts)"
assert_eq "status: without counts a running Kaching is green" "green" "$(kv "$out" state)"

# ---------- the voice shortcut: the chord tap (KachingBar --chord-test EVENT...) ----------
# raw flags as macOS sends them: control 0x40000 + right-control bit 0x2000, option 0x80000 + left-option bit 0x20,
# 0x100 always set; command 0x100000 (left bit 0x8), shift 0x20000 (left bit 0x2), caps lock 0x10000
RC=0x42100; LO=0x80120; BOTH=0xC2120; NONE=0x100
chord() { "$EXE" --chord-test "$@" 2>&1; }
assert_eq "chord: tap (ctrl, option, let go of option, then ctrl) -> fires" "fire=1" "$(chord $RC $BOTH $RC $NONE)"
assert_eq "chord: tap in the other order -> fires" "fire=1" "$(chord $LO $BOTH $LO $NONE)"
assert_eq "chord: pressing alone does not fire (fires on release)" "fire=0" "$(chord $RC $BOTH)"
assert_eq "chord: one let go, the other still held -> not yet" "fire=0" "$(chord $RC $BOTH $RC)"
assert_eq "chord: a key while held (Ctrl+Option+N) -> no" "fire=0" "$(chord $RC $BOTH key $RC $NONE)"
assert_eq "chord: two taps -> fires twice" "fire=2" "$(chord $RC $BOTH $RC $NONE $RC $BOTH $RC $NONE)"
assert_eq "chord: a key before the chord does not matter" "fire=1" "$(chord key $RC $BOTH $RC $NONE)"
assert_eq "chord: right ctrl only -> no" "fire=0" "$(chord $RC $NONE)"
assert_eq "chord: left option only -> no" "fire=0" "$(chord $LO $NONE)"
assert_eq "chord: left ctrl + left option -> no" "fire=0" "$(chord 0x40101 0xC0121 0x40101 $NONE)"
assert_eq "chord: right ctrl + right option -> no" "fire=0" "$(chord $RC 0xC2140 $RC $NONE)"
assert_eq "chord: command held first -> no" "fire=0" "$(chord 0x142108 0x1C2128 0x142108 $NONE)"
assert_eq "chord: shift held first -> no" "fire=0" "$(chord 0x62102 0xE2122 0x62102 $NONE)"
assert_eq "chord: command joins while armed -> no" "fire=0" "$(chord $RC $BOTH 0x1C2128 $BOTH $RC $NONE)"
assert_eq "chord: left ctrl joins while armed -> no" "fire=0" "$(chord $RC $BOTH 0xC2121 $BOTH $RC $NONE)"
assert_eq "chord: caps lock on does not count" "fire=1" "$(chord 0x52100 0xD2120 0x52100 0x10100)"
assert_eq "chord: let go of one and press it again, then both up -> one tap" "fire=1" "$(chord $RC $BOTH $RC $BOTH $RC $NONE)"
assert_eq "chord: held 1.4 s -> fires" "fire=1" "$(chord $RC@10 $BOTH@10 $RC@11.4 $NONE@11.4)"
assert_eq "chord: held 2 s -> not a tap" "fire=0" "$(chord $RC@10 $BOTH@10 $RC@12 $NONE@12)"
assert_eq "chord: decimal flags work too" "fire=1" "$(chord 8224 0)"
assert_fails "chord: no events is refused" "$EXE" --chord-test
assert_fails "chord: a bad event is refused" "$EXE" --chord-test 0x2020 bogus
assert_fails "wake: unknown --wake-once option is refused" "$EXE" --wake-once --bogus

# ---------- the voice shortcut's menu line (Accessibility forced with KACHING_BAR_AX_TRUSTED) ----------
assert_contains "voice: trusted -> the shortcut is shown" "$(KACHING_BAR_AX_TRUSTED=1 status)" "menu=Voice: Right Ctrl + Left Option [info]"
out=$(KACHING_BAR_AX_TRUSTED=0 status)
assert_contains "voice: not trusted -> the menu asks for Accessibility" "$out" "menu=Voice shortcut off: re-add KachingBar in Accessibility (needed after each rebuild)"
assert_not_contains "voice: not trusted -> no 'Voice:' line" "$out" "menu=Voice: Right Ctrl"

# ---------- one wake: KachingBar --wake-once [--dry-run] on fixture sessions ----------
W_CD="$WORK/wake-claude"; W_AH="$WORK/wake-agent"; mkdir -p "$W_CD/sessions" "$W_AH/dispatcher"
wake() { CLAUDE_DIR="$W_CD" AGENT_HOME="$W_AH" KACHING_DIR="$KIT" KACHING_BAR_NO_CUE=1 KACHING_BAR_DISPATCHER_TTY="${W_TTY-ttys009}" \
  KACHING_BAR_PGREP="${W_PGREP:-/usr/bin/false}" "$EXE" --wake-once "$@" 2>&1; }   # false: no dispatcher process being started
w_sess() { # file pid name cwd status
  printf '{"pid":%s,"sessionId":"x","cwd":"%s","name":"%s","status":"%s","updatedAt":1}\n' "$2" "$4" "$3" "$5" >"$W_CD/sessions/$1.json"
}
sleep 300 & LIVE=$!
sleep 0 & DEAD=$!; wait "$DEAD" 2>/dev/null

out=$(KACHING_BAR_FRONT_TTY=ttys003 wake --dry-run)
assert_eq "wake: no sessions -> dispatcher absent" "absent" "$(kv "$out" dispatcher)"
assert_eq "wake: absent -> start" "start" "$(kv "$out" action)"
assert_contains "wake: start opens launch.sh in a new Terminal window" "$(kv "$out" command)" "/usr/bin/osascript -e 'tell application \"Terminal\" to do script \"export AGENT_HOME="
assert_contains "wake: start runs the kit's launch.sh" "$(kv "$out" command)" "$KIT/dispatcher/launch.sh"
assert_contains "wake: start passes the wake text" "$(kv "$out" command)" "[shortcut] listen"
assert_eq "wake: focus tty from KACHING_BAR_FRONT_TTY" "ttys003" "$(kv "$out" focus_tty)"
if printf '%s\n' "$(kv "$out" focus_line)" | grep -Eq '^ttys003 [0-9]{10}$'; then pass "wake: focus line is '<tty> <epoch>'"; else fail "wake: focus line is '<tty> <epoch>'" "  got: $(kv "$out" focus_line)"; fi
assert_eq "wake: dry run says so" "yes" "$(kv "$out" dry_run)"
assert_no_file "wake: dry run writes no focus file" "$W_AH/dispatcher/focus"
assert_no_file "wake: dry run writes no log" "$W_AH/dispatcher/shortcut.log"
assert_contains "wake: start brings Terminal to the front" "$(kv "$out" command)" "-e 'tell application \"Terminal\" to activate'"

# a start already under way: no second window
date +%s >"$W_AH/dispatcher/starting"
out=$(wake --dry-run)
assert_eq "wake: start requested under 20 s ago -> starting" "starting" "$(kv "$out" dispatcher)"
assert_eq "wake: starting -> cue only" "cue" "$(kv "$out" action)"
assert_eq "wake: starting -> no command" "none" "$(kv "$out" command)"
assert_contains "wake: starting says why" "$(kv "$out" reason)" "start requested"
echo $(( $(date +%s) - 60 )) >"$W_AH/dispatcher/starting"
assert_eq "wake: a start requested a minute ago is over -> start again" "start" "$(kv "$(wake --dry-run)" action)"
out=$(W_PGREP=/usr/bin/true wake --dry-run)
assert_eq "wake: a launch.sh / claude --name dispatcher process -> starting" "starting" "$(kv "$out" dispatcher)"
assert_eq "wake: the process is the reason" "a dispatcher process is starting" "$(kv "$out" reason)"
assert_contains "wake: for real, no launch.sh -> error, nothing run" "$(CLAUDE_DIR="$W_CD" AGENT_HOME="$W_AH" KACHING_DIR="$WORK/no-kit" KACHING_BAR_NO_CUE=1 KACHING_BAR_FRONT_TTY= KACHING_BAR_PGREP=/usr/bin/false "$EXE" --wake-once 2>&1)" "result=error no launch.sh at $WORK/no-kit/dispatcher/launch.sh"
rm -f "$W_AH/dispatcher/starting" "$W_AH/dispatcher/shortcut.log"

w_sess dead "$DEAD" dispatcher "$W_AH/dispatcher" idle
assert_eq "wake: a dead pid counts as absent" "absent" "$(kv "$(wake --dry-run)" dispatcher)"
rm -f "$W_CD/sessions/dead.json"
w_sess other "$LIVE" worker "$WORK/plain" idle
assert_eq "wake: another session is not the dispatcher" "absent" "$(kv "$(wake --dry-run)" dispatcher)"

w_sess d "$LIVE" dispatcher /somewhere/else idle
out=$(KACHING_BAR_FRONT_TTY=/dev/ttys004 wake --dry-run)
assert_eq "wake: named dispatcher, idle" "idle" "$(kv "$out" dispatcher)"
assert_eq "wake: its pid" "$LIVE" "$(kv "$out" dispatcher_pid)"
assert_eq "wake: idle -> wake" "wake" "$(kv "$out" action)"
assert_eq "wake: types the wake text through send.js" "/usr/bin/osascript -l JavaScript $KIT/terminal/send.js text ttys009 '[shortcut] listen'" "$(kv "$out" command)"
assert_eq "wake: /dev/ is stripped from the focus tty" "ttys004" "$(kv "$out" focus_tty)"
w_sess d "$LIVE" 76281-bf "$W_AH/dispatcher" idle
assert_eq "wake: found by cwd \$AGENT_HOME/dispatcher too" "wake" "$(kv "$(wake --dry-run)" action)"
out=$(W_TTY= wake --dry-run)
assert_eq "wake: idle but no tty -> cue only" "cue" "$(kv "$out" action)"
assert_eq "wake: no tty is the reason" "dispatcher has no tty" "$(kv "$out" reason)"
w_sess d "$LIVE" dispatcher "$W_AH/dispatcher" busy
out=$(KACHING_BAR_FRONT_TTY= wake --dry-run)
assert_eq "wake: busy dispatcher" "busy" "$(kv "$out" dispatcher)"
assert_eq "wake: busy -> cue only" "cue" "$(kv "$out" action)"
assert_eq "wake: busy -> nothing typed" "none" "$(kv "$out" command)"
assert_eq "wake: Terminal not in front -> focus none" "none" "$(kv "$out" focus_tty)"
assert_eq "wake: Terminal not in front -> no focus line" "" "$(kv "$out" focus_line)"

# for real, busy: only the focus file and the log are written (no osascript runs on this path)
out=$(KACHING_BAR_FRONT_TTY=ttys003 wake)
assert_eq "wake: busy, for real -> result busy" "busy" "$(kv "$out" result)"
assert_file "wake: focus file written" "$W_AH/dispatcher/focus"
f=$(cat "$W_AH/dispatcher/focus" 2>/dev/null)
fe=${f#ttys003 }
if [ "${f%% *}" = ttys003 ] && [ "$(wc -l <"$W_AH/dispatcher/focus" | tr -d ' ')" = 1 ] && [ $(( $(date +%s) - fe )) -le 60 ]; then
  pass "wake: focus file is one line '<tty> <now>'"; else fail "wake: focus file is one line '<tty> <now>'" "  got: $f"; fi
assert_eq "wake: no temp files left next to it" "focus shortcut.log" "$(ls "$W_AH/dispatcher" | tr '\n' ' ' | sed 's/ $//')"
assert_contains "wake: logged" "$(cat "$W_AH/dispatcher/shortcut.log" 2>/dev/null)" " busy dispatcher=busy pid=$LIVE tty=ttys009 focus=ttys003"
printf 'ttys001 1\n' >"$W_AH/dispatcher/focus"
KACHING_BAR_FRONT_TTY= wake >/dev/null
assert_eq "wake: Terminal not in front leaves the older focus file" "ttys001 1" "$(cat "$W_AH/dispatcher/focus")"
assert_eq "wake: one log line per chord" "2" "$(wc -l <"$W_AH/dispatcher/shortcut.log" | tr -d ' ')"
rm -f "$W_AH/dispatcher/focus"; mkdir "$W_AH/dispatcher/focus"   # a focus file that cannot be written
out=$(KACHING_BAR_FRONT_TTY=ttys003 wake)
assert_contains "wake: a failed focus write does not stop the wake" "$(kv "$out" result)" "busy (focus not written:"
assert_contains "wake: the failed focus write is logged" "$(tail -1 "$W_AH/dispatcher/shortcut.log")" "(focus not written:"
rmdir "$W_AH/dispatcher/focus"
kill "$LIVE" 2>/dev/null; wait "$LIVE" 2>/dev/null

# ---------- install.sh --install-menubar in the sandbox HOME ----------
export KACHING_APPS_DIR="$HOME/Applications"
IAPP="$KACHING_APPS_DIR/KachingBar.app"; MBP="$LAUNCH_AGENTS_DIR/org.kaching.menubar.plist"
inst() { "$KIT/install.sh" "$@" </dev/null 2>&1; }
lc_lines() { if [ -f "$WORK/launchctl.log" ]; then wc -l <"$WORK/launchctl.log" | tr -d ' '; else echo 0; fi; }

out=$(inst --install-menubar --dry-run); rc=$?
assert_eq "menubar dry-run exits 0" "0" "$rc"
assert_contains "menubar dry-run shows the plist diff" "$out" "+++ $MBP (after install)"
assert_contains "menubar dry-run plans the build" "$out" "would: build $IAPP"
assert_contains "menubar dry-run plans the load" "$out" "would: write $MBP and launchctl bootstrap it"
assert_no_file "menubar dry-run: no app" "$IAPP"
assert_no_file "menubar dry-run: no plist" "$MBP"
assert_eq "menubar dry-run: launchctl never called" "0" "$(lc_lines)"

out=$(inst --install-menubar); rc=$?
assert_eq "menubar: no tty and no --yes refuses" "1" "$rc"
assert_contains "menubar refusal says why" "$out" "not a terminal"
assert_no_file "menubar refusal: no app" "$IAPP"
assert_no_file "menubar refusal: no plist" "$MBP"

# the dot under its name before D35 (ChingBar.app, org.ching.menubar) is replaced by this install
OAPP="$KACHING_APPS_DIR/ChingBar.app"; OMBP="$LAUNCH_AGENTS_DIR/org.ching.menubar.plist"
mkdir -p "$OAPP/Contents" "$LAUNCH_AGENTS_DIR"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.ching.menubar</string></dict></plist>\n' >"$OAPP/Contents/Info.plist"
printf '<plist>old dot</plist>\n' >"$OMBP"
out=$(inst --install-menubar --yes); rc=$?
assert_eq "menubar install exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || fail "menubar install output" "$out"
assert_no_file "rename: the old dot's job is removed" "$OMBP"
assert_no_file "rename: the old ChingBar.app is removed" "$OAPP"
assert_contains "rename: the old dot was booted out" "$(cat "$WORK/launchctl.log")" "bootout gui/$(id -u)/org.ching.menubar"
assert_file "menubar install builds the app" "$IAPP/Contents/MacOS/KachingBar"
assert_file "menubar install writes the plist" "$MBP"
assert_ok "menubar plist is valid" /usr/bin/plutil -lint "$MBP"
mget() { /usr/bin/plutil -extract "$1" raw "$MBP" 2>/dev/null; }
assert_eq "menubar plist: label" "org.kaching.menubar" "$(mget Label)"
assert_eq "menubar plist: runs the app's executable" "$IAPP/Contents/MacOS/KachingBar" "$(mget ProgramArguments.0)"
assert_eq "menubar plist: RunAtLoad" "true" "$(mget RunAtLoad)"
assert_eq "menubar plist: KeepAlive restarts it unless it quit cleanly" "false" "$(mget KeepAlive.SuccessfulExit)"
assert_eq "menubar plist: GUI sessions only" "Aqua" "$(mget LimitLoadToSessionType)"
assert_eq "menubar plist: AGENT_HOME" "$AGENT_HOME" "$(mget EnvironmentVariables.AGENT_HOME)"
assert_eq "menubar plist: KACHING_DIR is the kit link" "$CLAUDE_DIR/kaching" "$(mget EnvironmentVariables.KACHING_DIR)"
assert_contains "menubar install bootstraps the job" "$(cat "$WORK/launchctl.log")" "bootstrap gui/$(id -u) $MBP"
assert_contains "menubar install warns when the kit link is missing" "$out" "is not the kit's symlink yet"
assert_no_file "menubar install never writes the settings file" "$CLAUDE_DIR/settings.json"

n=$(lc_lines); m1=$(stat -f %m "$IAPP/Contents/MacOS/KachingBar")
out=$(inst --install-menubar --yes); rc=$?
assert_eq "menubar second run exits 0" "0" "$rc"
assert_contains "menubar second run: nothing to do" "$out" "nothing to do"
assert_eq "menubar second run: launchctl not called" "$n" "$(lc_lines)"
assert_eq "menubar second run: app not rebuilt" "$m1" "$(stat -f %m "$IAPP/Contents/MacOS/KachingBar")"

# a stale app (other source hash) with an unchanged plist: rebuilt, then restarted with kickstart
/usr/bin/plutil -replace KachingSourceHash -string stale "$IAPP/Contents/Info.plist"
out=$(inst --install-menubar --yes)
assert_contains "stale app: shows the hash change" "$out" "installed: stale"
assert_eq "stale app: rebuilt with the current hash" "$("$KIT/ui/menubar/build.sh" --hash)" "$(/usr/bin/plutil -extract KachingSourceHash raw "$IAPP/Contents/Info.plist")"
assert_contains "stale app: restarted, not re-bootstrapped" "$(tail -1 "$WORK/launchctl.log")" "kickstart -k gui/$(id -u)/org.kaching.menubar"

# a changed plist is shown as a diff and replaced
sed -i '' 's#<key>RunAtLoad</key><true/>#<key>RunAtLoad</key><false/>#' "$MBP"
out=$(inst --install-menubar --dry-run)
assert_contains "changed plist: dry-run diff shows the fix" "$out" "+  <key>RunAtLoad</key><true/>"
inst --install-menubar --yes >/dev/null
assert_eq "changed plist: restored" "true" "$(mget RunAtLoad)"

assert_eq "--install-menubar with --uninstall is refused" "64" "$(inst --install-menubar --uninstall >/dev/null; echo $?)"

# uninstall removes the job and the app
out=$(inst --uninstall --dry-run)
assert_contains "uninstall dry-run plans the menubar removal" "$out" "would: launchctl bootout and remove $MBP"
assert_contains "uninstall dry-run plans the app removal" "$out" "would: remove $IAPP"
assert_file "uninstall dry-run keeps the app" "$IAPP"
out=$(inst --uninstall --yes); rc=$?
assert_eq "uninstall exits 0" "0" "$rc"
assert_no_file "uninstall removes the menubar plist" "$MBP"
assert_no_file "uninstall removes the app" "$IAPP"
assert_contains "uninstall boots the menubar job out" "$(cat "$WORK/launchctl.log")" "bootout gui/$(id -u)/org.kaching.menubar"
out=$(inst --uninstall --yes)
assert_contains "second uninstall: nothing to do" "$out" "nothing to do"

# somebody else's KachingBar.app is never replaced or removed
mkdir -p "$IAPP/Contents"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>\n' >"$IAPP/Contents/Info.plist"
out=$(inst --install-menubar --yes); rc=$?
assert_eq "foreign app: install refuses" "1" "$rc"
assert_contains "foreign app: says why" "$out" "is not KachingBar"
out=$(inst --uninstall --yes)
assert_file "foreign app: uninstall leaves it" "$IAPP/Contents/Info.plist"
assert_contains "foreign app: uninstall warns" "$out" "is not KachingBar"
exit 0
