#!/usr/bin/env bash
# The menu bar dot (ui/menubar): the watcher's heartbeat and dash.sh --counts (no swiftc needed), then, with swiftc,
# the app bundle, the dot's state from fixture files (ChingBar --status-once), and install.sh --install-menubar in the
# sandbox HOME: plist content, dry run, idempotence, uninstall. Without swiftc the build half is skipped with a note.
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
AGENT_HOME="$HB_AH" SYNC_CHECK_INTERVAL_H=0 "$BIN/ching-watch.sh" >/dev/null 2>&1
assert_file "watcher tick writes watch.heartbeat" "$HB_AH/watch.heartbeat"
hb=$(cat "$HB_AH/watch.heartbeat" 2>/dev/null || echo 0)
if [ $((NOW - hb)) -le 60 ] && [ $((hb - NOW)) -le 60 ]; then pass "heartbeat holds the current time"; else fail "heartbeat holds the current time" "  got $hb, now $NOW"; fi
mkdir "$HB_AH/watch.lock"; touch -t "$(date -r $((NOW - 3600)) +%Y%m%d%H%M.%S)" "$HB_AH/watch.heartbeat"
AGENT_HOME="$HB_AH" SYNC_CHECK_INTERVAL_H=0 "$BIN/ching-watch.sh" >/dev/null 2>&1
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
APP="$OUT/ChingBar.app"; EXE="$APP/Contents/MacOS/ChingBar"; PL="$APP/Contents/Info.plist"
if [ "$rc" -ne 0 ]; then fail "build output" "$out"; exit 0; fi
assert_contains "build says where" "$out" "built: "
if [ -x "$EXE" ]; then pass "bundle has an executable"; else fail "bundle has an executable" "  missing $EXE"; fi
pget() { /usr/bin/plutil -extract "$1" raw "$PL" 2>/dev/null; }
assert_eq "Info.plist: bundle id" "org.ching.menubar" "$(pget CFBundleIdentifier)"
assert_eq "Info.plist: LSUIElement (no Dock icon)" "true" "$(pget LSUIElement)"
assert_eq "Info.plist: executable name" "ChingBar" "$(pget CFBundleExecutable)"
assert_eq "Info.plist: package type" "APPL" "$(pget CFBundlePackageType)"
assert_eq "Info.plist: source hash matches build.sh --hash" "$("$BUILD" --hash)" "$(pget ChingSourceHash)"
assert_contains "the binary is arm64" "$(file "$EXE")" "arm64"
m1=$(stat -f %m "$EXE"); i1=$(stat -f %i "$EXE")
out=$("$BUILD" "$OUT" 2>&1)
assert_contains "second build is a no-op" "$out" "up to date"
assert_eq "second build leaves the binary alone" "$m1 $i1" "$(stat -f %m "$EXE") $(stat -f %i "$EXE")"
assert_eq "no staging dirs left behind" "" "$(find "$OUT" -maxdepth 1 -name '.ChingBar.build.*')"
assert_fails "an unknown CLI argument is refused" "$EXE" --bogus

# ---------- the dot's state: ChingBar --status-once on fixtures ----------
S_AH="$WORK/st-agent"; S_LA="$WORK/st-launchagents"; mkdir -p "$S_AH/sessions" "$S_LA"
status() { AGENT_HOME="$S_AH" LAUNCH_AGENTS_DIR="$S_LA" CHING_DIR="$KIT" "$EXE" --status-once 2>&1; }
st_sess() { mkdir -p "$S_AH/sessions/$1"; printf 'cwd=%s\nstate=%s\nupdated=%s\n' "$WORK/plain" "$2" "$(date +%s)" >"$S_AH/sessions/$1/meta"; }
ago() { touch -t "$(date -r $(( $(date +%s) - $2 )) +%Y%m%d%H%M.%S)" "$1"; }

out=$(status)
assert_eq "status: nothing installed -> grey" "grey" "$(kv "$out" state)"
assert_eq "status: watcher not installed" "no" "$(kv "$out" watcher_installed)"
assert_contains "status: menu says the watcher is not installed" "$out" "menu=Watcher not installed (org.ching.watch) [info]"
: >"$S_LA/org.ching.watch.plist"
out=$(status)
assert_eq "status: plist but no heartbeat -> grey" "grey" "$(kv "$out" state)"
assert_eq "status: no heartbeat age" "none" "$(kv "$out" heartbeat_age)"
date +%s >"$S_AH/watch.heartbeat"
st_sess a working
out=$(status)
assert_eq "status: fresh heartbeat, nobody waiting -> green" "green" "$(kv "$out" state)"
assert_eq "status: running" "yes" "$(kv "$out" running)"
assert_eq "status: status line" "Ching running · 1 session · 0 need you" "$(kv "$out" status)"
assert_contains "status: Open inbox in the menu" "$out" "menu=Open inbox"
assert_contains "status: transcripts placeholder is disabled" "$out" "menu=Transcripts (coming soon) [disabled]"
assert_contains "status: Quit in the menu" "$out" "menu=Quit ChingBar"
assert_not_contains "status: no proposals line without proposals" "$out" "Proposals waiting"
st_sess b input
out=$(status)
assert_eq "status: a session waiting for input -> amber" "amber" "$(kv "$out" state)"
assert_eq "status: needs 1" "1" "$(kv "$out" needs)"
assert_eq "status: status line with one waiting" "Ching running · 2 sessions · 1 needs you" "$(kv "$out" status)"
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
assert_contains "status: stale says not running" "$(kv "$out" status)" "Ching not running"
assert_contains "status: stale says since when" "$out" "Watcher silent since 30m ago"
assert_eq "status: CHING_BAR_STALE_SECS widens the window" "amber" "$(kv "$(CHING_BAR_STALE_SECS=3600 status)" state)"
: >"$S_AH/watch.log"
assert_eq "status: a fresh watch.log counts as a heartbeat too" "amber" "$(kv "$(status)" state)"
ago "$S_AH/watch.log" 1800
rm -f "$S_LA/org.ching.watch.plist"; date +%s >"$S_AH/watch.heartbeat"
assert_eq "status: fresh heartbeat but no watcher plist -> grey" "grey" "$(kv "$(status)" state)"
: >"$S_LA/org.ching.watch.plist"
out=$(AGENT_HOME="$S_AH" LAUNCH_AGENTS_DIR="$S_LA" CHING_DIR="$WORK/no-kit" "$EXE" --status-once 2>&1)
assert_eq "status: no dash.sh -> still green/amber/grey from the heartbeat, counts unavailable" "unavailable" "$(kv "$out" counts)"
assert_eq "status: without counts a running Ching is green" "green" "$(kv "$out" state)"

# ---------- install.sh --install-menubar in the sandbox HOME ----------
export CHING_APPS_DIR="$HOME/Applications"
IAPP="$CHING_APPS_DIR/ChingBar.app"; MBP="$LAUNCH_AGENTS_DIR/org.ching.menubar.plist"
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

out=$(inst --install-menubar --yes); rc=$?
assert_eq "menubar install exits 0" "0" "$rc"
[ "$rc" -eq 0 ] || fail "menubar install output" "$out"
assert_file "menubar install builds the app" "$IAPP/Contents/MacOS/ChingBar"
assert_file "menubar install writes the plist" "$MBP"
assert_ok "menubar plist is valid" /usr/bin/plutil -lint "$MBP"
mget() { /usr/bin/plutil -extract "$1" raw "$MBP" 2>/dev/null; }
assert_eq "menubar plist: label" "org.ching.menubar" "$(mget Label)"
assert_eq "menubar plist: runs the app's executable" "$IAPP/Contents/MacOS/ChingBar" "$(mget ProgramArguments.0)"
assert_eq "menubar plist: RunAtLoad" "true" "$(mget RunAtLoad)"
assert_eq "menubar plist: KeepAlive restarts it unless it quit cleanly" "false" "$(mget KeepAlive.SuccessfulExit)"
assert_eq "menubar plist: GUI sessions only" "Aqua" "$(mget LimitLoadToSessionType)"
assert_eq "menubar plist: AGENT_HOME" "$AGENT_HOME" "$(mget EnvironmentVariables.AGENT_HOME)"
assert_eq "menubar plist: CHING_DIR is the kit link" "$CLAUDE_DIR/ching" "$(mget EnvironmentVariables.CHING_DIR)"
assert_contains "menubar install bootstraps the job" "$(cat "$WORK/launchctl.log")" "bootstrap gui/$(id -u) $MBP"
assert_contains "menubar install warns when the kit link is missing" "$out" "is not the kit's symlink yet"
assert_no_file "menubar install never writes the settings file" "$CLAUDE_DIR/settings.json"

n=$(lc_lines); m1=$(stat -f %m "$IAPP/Contents/MacOS/ChingBar")
out=$(inst --install-menubar --yes); rc=$?
assert_eq "menubar second run exits 0" "0" "$rc"
assert_contains "menubar second run: nothing to do" "$out" "nothing to do"
assert_eq "menubar second run: launchctl not called" "$n" "$(lc_lines)"
assert_eq "menubar second run: app not rebuilt" "$m1" "$(stat -f %m "$IAPP/Contents/MacOS/ChingBar")"

# a stale app (other source hash) with an unchanged plist: rebuilt, then restarted with kickstart
/usr/bin/plutil -replace ChingSourceHash -string stale "$IAPP/Contents/Info.plist"
out=$(inst --install-menubar --yes)
assert_contains "stale app: shows the hash change" "$out" "installed: stale"
assert_eq "stale app: rebuilt with the current hash" "$("$KIT/ui/menubar/build.sh" --hash)" "$(/usr/bin/plutil -extract ChingSourceHash raw "$IAPP/Contents/Info.plist")"
assert_contains "stale app: restarted, not re-bootstrapped" "$(tail -1 "$WORK/launchctl.log")" "kickstart -k gui/$(id -u)/org.ching.menubar"

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
assert_contains "uninstall boots the menubar job out" "$(cat "$WORK/launchctl.log")" "bootout gui/$(id -u)/org.ching.menubar"
out=$(inst --uninstall --yes)
assert_contains "second uninstall: nothing to do" "$out" "nothing to do"

# somebody else's ChingBar.app is never replaced or removed
mkdir -p "$IAPP/Contents"
printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.other</string></dict></plist>\n' >"$IAPP/Contents/Info.plist"
out=$(inst --install-menubar --yes); rc=$?
assert_eq "foreign app: install refuses" "1" "$rc"
assert_contains "foreign app: says why" "$out" "is not ChingBar"
out=$(inst --uninstall --yes)
assert_file "foreign app: uninstall leaves it" "$IAPP/Contents/Info.plist"
assert_contains "foreign app: uninstall warns" "$out" "is not ChingBar"
exit 0
