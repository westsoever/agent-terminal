#!/usr/bin/env bash
# sync-check.sh: the read-only git sync report. Every fixture is a local repo with a local bare remote built
# under this test's sandbox (tests/lib.sh mk_repo); nothing here can reach a real repo or the network.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
export CHING_INCLUDE_SANDBOX=1   # the fixtures live under /tmp, which the real run excludes
export SYNC_NO_FETCH=1           # offline unless a test uses scf (fetch on)
S="$BIN/sync-check.sh"
NOW=$(date +%s)
NOON=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 12:00:00" +%s)   # inside the banner window (09:00-21:00)
DAY=86400
SPOKEN="$WORK/spoken.log"; : >"$SPOKEN"
cat >"$WORK/speak-rec" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$SPOKEN"
EOF
chmod +x "$WORK/speak-rec"; export SPEAK_CMD="$WORK/speak-rec"   # the feature must never speak: this stays empty

new_ah() { # name -> fresh AGENT_HOME ($AH), repos file ($RF), snapshot ($SNAP), event log ($EVF)
  AH="$WORK/ah-$1"; RF="$WORK/repos-$1"; rm -rf "$AH" "$RF"; mkdir -p "$AH"
  SNAP="$AH/sync-check.md"; EVF="$AH/events.jsonl"
}
sc() { AGENT_HOME="$AH" AGENT_REPOS_FILE="$RF" "$S" "$@"; }                          # offline
scf() { env -u SYNC_NO_FETCH AGENT_HOME="$AH" AGENT_REPOS_FILE="$RF" "$S" "$@"; }   # with fetch
phys() { (cd "$1" && pwd -P); }
mk() { phys "$(mk_repo "$1")"; }            # fixture repo, physical path
repos() { printf '%s\n' "$@" >"$RF"; }
sec() { awk -v n="$1" '/^## /{ p = ($2 == n) } p' "$SNAP"; }   # the snapshot section of repo n
nsec() { grep -c '^## ' "$SNAP" || true; }
sync_ev() { jq -c 'select(.kind=="sync")' "$EVF" 2>/dev/null || true; }
nev() { sync_ev | grep -c . || true; }
evq() { sync_ev | jq -r --arg n "$1" "select(.name==\$n) | $2"; }   # field of repo n's sync event
dirty() { printf 'u\n' >"$1/untracked.txt"; }
ago() { printf '%s +0000' $((NOW - $1 * DAY)); }                    # GIT_COMMITTER_DATE value N days ago
put_event() { ( AGENT_HOME="$AH"; CWD="$1"; NAME=x; SID=s1; ev stop_ok '{}' ); }
put_meta() { mkdir -p "$AH/sessions/$1"; printf 'cwd=%s\nstate=done\nupdated=%s\n' "$2" "$NOW" >"$AH/sessions/$1/meta"; }

# ---------- the header documents the ages and the read-only promise ----------
head=$(sed -n '1,/^set -euo/p' "$S" 2>/dev/null || true)
assert_contains "header: read-only" "$head" "READ-ONLY"
assert_contains "header: unpushed age" "$head" "committer date of the oldest commit not on the upstream"
assert_contains "header: behind age" "$head" "oldest commit you are missing"
assert_contains "header: uncommitted age" "$head" "oldest mtime"
assert_contains "header: stash age" "$head" "oldest entry"
assert_not_contains "never calls the voice script" "$(cat "$S" 2>/dev/null)" "speak.sh"

# ---------- clean repo ----------
R=$(mk clean1); new_ah clean; repos "$R"
rc=0; out=$(sc 2>&1) || rc=$?
assert_eq "clean: exit 0" "0" "$rc"
case "$(head -1 "$SNAP" 2>/dev/null)" in
  generated:\ 20[0-9][0-9]-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z) pass "snapshot starts with generated: <UTC ISO>" ;;
  *) fail "snapshot starts with generated: <UTC ISO>" "  first line: $(head -1 "$SNAP" 2>/dev/null)" ;;
esac
assert_contains "snapshot has a human line" "$(sed -n 2p "$SNAP" 2>/dev/null)" "Git sync check"
assert_eq "clean: no repo section" "0" "$(nsec)"
assert_contains "clean: listed on the clean line" "$(grep '^clean:' "$SNAP" 2>/dev/null)" "clean1"
assert_eq "clean: no sync event" "0" "$(nev)"
assert_contains "on demand: one-line summary" "$out" "0 repos need attention"
assert_contains "on demand: prints the snapshot path" "$out" "$SNAP"
assert_eq "--quiet prints nothing" "" "$(sc --quiet 2>&1)"
assert_ok "--no-fetch is accepted" sc --no-fetch --quiet
rc=0; sc --bogus >/dev/null 2>&1 || rc=$?
assert_eq "unknown argument: exit 64" "64" "$rc"

# ---------- (a) commits not pushed ----------
R=$(mk ahead1); new_ah ahead; repos "$R"
commit_file "$R" f.txt one "local only"
sc --quiet
assert_eq "ahead: one section" "1" "$(nsec)"
assert_contains "ahead: names the branch and the count" "$(sec ahead1 | grep 'unpushed:')" "main +1"
assert_eq "ahead: one sync event" "1" "$(nev)"
assert_eq "ahead: event counts the commit" "1" "$(evq ahead1 '.data.unpushed_commits')"
assert_eq "ahead: event cwd is the repo" "$R" "$(evq ahead1 '.cwd')"
assert_eq "ahead: a fresh commit is under an hour old" "0" "$(evq ahead1 '.data.oldest_age_h')"
R=$(mk ahead2); new_ah ahead2; repos "$R"
GIT_COMMITTER_DATE=$(ago 3) commit_file "$R" f.txt one "three days old"
sc --quiet
assert_eq "ahead: age is the committer date of the oldest unpushed commit (72 h)" "72" "$(evq ahead2 '.data.oldest_age_h')"
assert_contains "ahead: heading shows the oldest age" "$(grep '^## ahead2' "$SNAP")" "oldest 3d"

# ---------- (b) behind origin, only after a fetch ----------
R=$(mk behind1); new_ah behind; repos "$R"
git clone -q "$WORK/behind1.git" "$WORK/behind1-other"
GIT_COMMITTER_DATE=$(ago 2) commit_file "$WORK/behind1-other" r.txt remote "remote work"
git -C "$WORK/behind1-other" push -q origin main
sc --quiet
assert_eq "behind: without a fetch nothing is known" "0" "$(nsec)"
scf --quiet
assert_eq "behind: after the fetch there is one section" "1" "$(nsec)"
assert_contains "behind: names the branch and the count" "$(sec behind1 | grep 'behind origin:')" "main -1"
assert_eq "behind: age of the oldest commit you are missing (48 h)" "48" "$(evq behind1 '.data.oldest_age_h')"
assert_eq "behind: event counts the commit" "1" "$(evq behind1 '.data.behind_commits')"
assert_eq "behind: the local branch was not moved" "init" "$(git -C "$R" log -1 --format=%s)"
assert_no_file "behind: the working tree got nothing from the remote" "$R/r.txt"

# ---------- no upstream ----------
R=$(mk noup1); new_ah noup; repos "$R"
git -C "$R" checkout -q -b scratch; commit_file "$R" s.txt s "scratch work"; commit_file "$R" s2.txt s2 "more scratch"
git -C "$R" checkout -q main
git -C "$R" checkout -q -b pushed-nouv; commit_file "$R" p.txt p "pushed without -u"; git -C "$R" push -q origin pushed-nouv
git -C "$R" checkout -q main
git -C "$R" branch -q fresh-branch
sc --quiet
line=$(sec noup1 | grep 'no upstream:')
assert_contains "no upstream: says no upstream" "$line" "scratch"
assert_contains "no upstream: counts commits on no remote branch" "$line" "2 commits"
assert_not_contains "no upstream: a branch that is on a remote branch is fine" "$line" "pushed-nouv"
assert_not_contains "no upstream: a branch with nothing of its own is fine" "$line" "fresh-branch"
assert_eq "no upstream: event counts the branch" "1" "$(evq noup1 '.data.no_upstream_branches')"
assert_eq "no upstream: event counts its commits" "2" "$(evq noup1 '.data.no_upstream_commits')"

# ---------- (c) uncommitted changes ----------
R=$(mk dirty1); new_ah dirty; repos "$R"
echo more >>"$R/README.md"; touch -t "$(date -r $((NOW - 3 * DAY)) +%Y%m%d%H%M.%S)" "$R/README.md"
echo s >"$R/staged.txt"; git -C "$R" add staged.txt
echo u >"$R/untracked.txt"
mkdir -p "$R/.agent"; echo x >"$R/.agent/ignored.txt"      # .agent/ is git-excluded by mk_repo: not counted
sc --quiet
line=$(sec dirty1 | grep 'uncommitted:')
assert_contains "dirty: counts modified" "$line" "1 modified"
assert_contains "dirty: counts staged" "$line" "1 staged"
assert_contains "dirty: counts untracked (ignored files are not counted)" "$line" "1 untracked"
assert_eq "dirty: age is the oldest mtime among the changed files (72 h)" "72" "$(evq dirty1 '.data.oldest_age_h')"
assert_eq "dirty: event counts" "1 1 1 1" "$(evq dirty1 '[.data.dirty_worktrees,.data.modified,.data.staged,.data.untracked]|map(tostring)|join(" ")')"
# a linked worktree is judged on its own
R=$(mk dirtywt); new_ah dirtywt; repos "$R"
git -C "$R" worktree add -q -b wtb "$WORK/dirtywt-wtb"; WTB=$(phys "$WORK/dirtywt-wtb")
echo u >"$WTB/only-here.txt"
sc --quiet
assert_contains "dirty worktree: the line names the worktree path" "$(sec dirtywt | grep 'uncommitted:')" "$WTB"
assert_eq "dirty worktree: the main checkout is clean, one dirty worktree" "1" "$(evq dirtywt '.data.dirty_worktrees')"
# a file git ignores through .gitignore is not a change either
R=$(mk dirtyign); new_ah dirtyign; repos "$R"
printf 'build.log\n' >"$R/.gitignore"; git -C "$R" add .gitignore; git -C "$R" commit -q -m ignore; git -C "$R" push -q origin main
echo l >"$R/build.log"
sc --quiet
assert_eq "gitignore: an ignored file alone leaves the repo clean" "0" "$(nsec)"

# ---------- (d) merged worktrees ----------
R=$(mk mrg1); new_ah mrg; repos "$R"
git -C "$R" worktree add -q -b merged-feat "$WORK/mrg1-wt-merged"
GIT_COMMITTER_DATE=$(ago 5) commit_file "$WORK/mrg1-wt-merged" m.txt m "feature work"
git -C "$R" merge -q --no-ff merged-feat -m "merge feature"; git -C "$R" push -q origin main
git -C "$R" worktree add -q -b open-feat "$WORK/mrg1-wt-open"; commit_file "$WORK/mrg1-wt-open" o.txt o "still open"
git -C "$R" worktree add -q -b fresh-feat "$WORK/mrg1-wt-fresh"
sc --quiet
line=$(sec mrg1 | grep 'merged worktrees:')
assert_contains "merged: the merged worktree is listed" "$line" "merged-feat"
assert_not_contains "merged: an unmerged worktree is not" "$line" "open-feat"
assert_not_contains "merged: a branch still at the base tip is not" "$line" "fresh-feat"
assert_not_contains "merged: the main checkout is never listed" "$line" "(branch main,"
assert_eq "merged: event counts one merged worktree" "1" "$(evq mrg1 '.data.merged_worktrees')"
assert_eq "merged: age is the committer date of the branch tip (120 h)" "120" "$(evq mrg1 '.data.oldest_age_h')"

# ---------- (e) stash ----------
R=$(mk stash1); new_ah stash; repos "$R"
echo change >>"$R/README.md"; GIT_COMMITTER_DATE=$(ago 9) git -C "$R" stash push -q
sc --quiet
assert_contains "stash: counted" "$(sec stash1 | grep 'stash:')" "1 entry"
assert_eq "stash: event counts it" "1" "$(evq stash1 '.data.stashes')"
assert_eq "stash: age is the date of the oldest entry (216 h)" "216" "$(evq stash1 '.data.oldest_age_h')"

# ---------- more shapes: behind in a linked worktree and via the origin twin, merged on the remote only ----------
R=$(mk behwt); new_ah behwt; repos "$R"
git -C "$R" worktree add -q -b wtup "$WORK/behwt-wt"; commit_file "$WORK/behwt-wt" w.txt w "wt work"; git -C "$WORK/behwt-wt" push -q -u origin wtup
git clone -q "$WORK/behwt.git" "$WORK/behwt-other"; git -C "$WORK/behwt-other" checkout -q wtup
GIT_COMMITTER_DATE=$(ago 2) commit_file "$WORK/behwt-other" w2.txt w2 "more on wtup"; git -C "$WORK/behwt-other" push -q origin wtup
commit_file "$WORK/behwt-other" b.txt b "remote main work"; git -C "$WORK/behwt-other" checkout -q main
commit_file "$WORK/behwt-other" m.txt m "remote main"; git -C "$WORK/behwt-other" push -q origin main
git -C "$R" branch -q --unset-upstream main                  # the base has no configured upstream: origin/main is its twin
scf --quiet
line=$(sec behwt | grep 'behind origin:')
assert_contains "behind: the branch checked out in a linked worktree counts" "$line" "wtup -1"
assert_contains "behind: a base branch without a configured upstream is compared with origin/<base>" "$line" "main -1"
R=$(mk mrgrem); new_ah mrgrem; repos "$R"
git -C "$R" worktree add -q -b remote-merged "$WORK/mrgrem-wt"
GIT_COMMITTER_DATE=$(ago 4) commit_file "$WORK/mrgrem-wt" m.txt m "work"; git -C "$WORK/mrgrem-wt" push -q origin remote-merged
git clone -q "$WORK/mrgrem.git" "$WORK/mrgrem-other"
git -C "$WORK/mrgrem-other" merge -q --no-ff origin/remote-merged -m "merge on the remote"; git -C "$WORK/mrgrem-other" push -q origin main
sc --quiet
assert_not_contains "merged on the remote only: unknown until the fetch" "$(sec mrgrem)" "merged worktrees"
scf --quiet
assert_contains "merged on the remote only: after the fetch it is merged into origin/main" "$(sec mrgrem | grep 'merged worktrees:')" "remote-merged, merged into origin/main"
assert_eq "merged on the remote only: aged by its tip (96 h)" "96" "$(evq mrgrem '.data.oldest_age_h')"
# odd shapes must not break the run
R=$(mk 'sp ace'); echo u >"$R/new file.txt"; new_ah space; repos "$R"
sc --quiet
assert_eq "spaces: a repo path with a space is one section" "1" "$(grep -c '^## sp ace -- oldest' "$SNAP")"
assert_contains "spaces: ... its path is whole" "$(grep '^path:' "$SNAP")" "sp ace"
assert_contains "spaces: ... and the untracked file is counted" "$(grep 'uncommitted:' "$SNAP")" "1 untracked"
R="$WORK/unborn"; git init -q -b main "$R"; echo u >"$R/f"; R=$(phys "$R"); new_ah unborn; repos "$R"
rc=0; sc --quiet 2>"$WORK/unborn.err" || rc=$?
assert_eq "no commits yet: exit 0, quiet" "0:" "$rc:$(cat "$WORK/unborn.err")"
assert_contains "no commits yet: the untracked file is still reported" "$(sec unborn)" "1 untracked"
R=$(mk detach1); new_ah detach; repos "$R"
git -C "$R" worktree add -q --detach "$WORK/detach1-wt"; echo u >"$WORK/detach1-wt/x.txt"
rc=0; sc --quiet 2>"$WORK/detach.err" || rc=$?
assert_eq "detached worktree: exit 0, quiet" "0:" "$rc:$(cat "$WORK/detach.err")"
assert_contains "detached worktree: its changes are reported" "$(sec detach1 | grep 'uncommitted:')" "detach1-wt"
assert_not_contains "detached worktree: it is not 'merged'" "$(sec detach1)" "merged worktrees"
assert_contains "--help prints the header" "$(sc --help)" "READ-ONLY"
assert_not_contains "--help does not print code" "$(sc --help)" "set -euo pipefail"

# ---------- discovery ----------
# every discovery fixture carries an untracked file so that it shows up as a section
R=$(mk disc-ev); dirty "$R"; new_ah disc_ev; put_event "$R"
sc --quiet
assert_eq "discovery: a repo known only from an events cwd is reported" "1" "$(nsec)"
assert_contains "discovery: ... under its name" "$(grep '^## ' "$SNAP")" "disc-ev"

R=$(mk disc-file); dirty "$R"; new_ah disc_file
printf '# my repos\n\n   \n%s\n' "$R" >"$RF"
sc --quiet
assert_eq "discovery: a repo known only from the repos file (comments and blanks skipped)" "1" "$(nsec)"
mv "$R" "$HOME/disc-tilde"; new_ah disc_tilde; printf '~/disc-tilde\n' >"$RF"
sc --quiet
assert_contains "discovery: ~ in the repos file is the home folder" "$(grep '^## ' "$SNAP")" "disc-tilde"

R=$(mk disc-meta); dirty "$R"; new_ah disc_meta; put_meta m1 "$R"
sc --quiet
assert_eq "discovery: a repo known only from a session meta is reported" "1" "$(nsec)"

# one repo from four sources, plus its worktree, is one section
R=$(mk disc-dup); dirty "$R"; new_ah disc_dup
git -C "$R" worktree add -q -b dupwt "$WORK/disc-dup-wt"; DW=$(phys "$WORK/disc-dup-wt")
repos "$R" "$R/"; put_event "$R"; put_event "$DW"; put_meta m1 "$R"; put_meta m2 "$DW"
sc --quiet
assert_eq "discovery: the same repo from every source is shown once" "1" "$(nsec)"
assert_eq "discovery: ... with one event" "1" "$(nev)"
# a worktree cwd resolves to its main checkout (the repo name, not the worktree folder)
R=$(mk disc-main); new_ah disc_wt
git -C "$R" worktree add -q -b wtonly "$WORK/disc-wtonly-folder"; WT=$(phys "$WORK/disc-wtonly-folder")
echo u >"$WT/x.txt"; put_event "$WT"
sc --quiet
assert_contains "discovery: a worktree cwd is reported under its main repo" "$(grep '^## ' "$SNAP")" "disc-main"
assert_not_contains "discovery: ... not under the worktree folder name" "$(grep '^## ' "$SNAP")" "disc-wtonly-folder"
assert_eq "discovery: ... as the repo path" "$R" "$(sec disc-main | sed -n 's/^path: //p')"
# a path that is gone, a plain folder and a missing repos file are skipped quietly
new_ah disc_skip; GONE="$WORK/gone-repo"; mkdir -p "$GONE"; git init -q "$GONE"; rm -rf "$GONE"
PLAIN="$WORK/plain-folder"; mkdir -p "$PLAIN"
put_event "$GONE"; put_event "$PLAIN"; put_meta m1 "$GONE"; put_meta m2 "$PLAIN"; printf '%s\n%s\n' "$GONE" "$PLAIN" >"$RF"
rc=0; out=$(sc 2>&1) || rc=$?
assert_eq "skip: deleted path and non-repo: exit 0" "0" "$rc"
assert_eq "skip: nothing reported" "0" "$(nsec)"
assert_contains "skip: summary says no repos" "$out" "0 repos"
assert_eq "skip: no stderr noise" "" "$(sc 2>&1 >/dev/null)"
# a repos file that does not exist at all
new_ah disc_nofile; rm -f "$RF"
assert_ok "no repos file: runs" sc --quiet
# sync events do not feed discovery: a repo that was reported once is not found again through its own event
R=$(mk disc-self); dirty "$R"; new_ah disc_self; repos "$R"
sc --quiet; rm -f "$RF"; sc --quiet
assert_eq "discovery: a repo is not re-discovered from its own sync event" "0" "$(nsec)"
# sandbox paths are skipped unless CHING_INCLUDE_SANDBOX is set (the fixtures live in /tmp)
R=$(mk disc-sbx); dirty "$R"; new_ah disc_sbx; repos "$R"; put_event "$R"
env -u CHING_INCLUDE_SANDBOX AGENT_HOME="$AH" AGENT_REPOS_FILE="$RF" "$S" --quiet
assert_eq "sandbox: a repo under /tmp is skipped without CHING_INCLUDE_SANDBOX" "0" "$(nsec)"
assert_eq "sandbox: ... and gives no event" "0" "$(nev)"
sc --quiet
assert_eq "sandbox: CHING_INCLUDE_SANDBOX=1 includes it" "1" "$(nsec)"

# ---------- fetch trouble ----------
R=$(mk ff1); dirty "$R"; new_ah ff; repos "$R"; rm -rf "$WORK/ff1.git"
rc=0; scf --quiet || rc=$?
assert_eq "fetch failure: exit 0" "0" "$rc"
assert_contains "fetch failure: recorded" "$(sec ff1)" "fetch failed"
assert_contains "fetch failure: the rest still reports" "$(sec ff1)" "1 untracked"
assert_eq "fetch failure: event carries it" "failed" "$(evq ff1 '.data.fetch')"
R=$(mk ff2); new_ah ff2; repos "$R"; rm -rf "$WORK/ff2.git"
scf --quiet
assert_contains "fetch failure on a clean repo: noted on the clean line" "$(grep '^clean:' "$SNAP")" "ff2 (fetch failed)"
# no remote: not fetched, no failure, local commits are not "unpushed"
R="$WORK/noremote"; git init -q -b main "$R"; echo a >"$R/a"; git -C "$R" add a; git -C "$R" commit -q -m one; R=$(phys "$R")
dirty "$R"; new_ah noremote; repos "$R"
scf --quiet
assert_not_contains "no remote: not a fetch failure" "$(cat "$SNAP")" "fetch failed"
assert_contains "no remote: the dirty tree is reported" "$(sec noremote)" "1 untracked"
assert_not_contains "no remote: local commits are not unpushed" "$(sec noremote)" "unpushed"
assert_not_contains "no remote: nor 'no upstream'" "$(sec noremote)" "no upstream"
# a hung fetch is cut at the timeout and does not take the run with it
mkdir -p "$WORK/shim"
cat >"$WORK/shim/git" <<'EOF'
#!/bin/bash
# test shim: a git whose fetch is slow (SHIM_SLEEP seconds); everything else is the real git
for a in "$@"; do if [ "$a" = fetch ]; then sleep "${SHIM_SLEEP:-3}"; break; fi; done
exec /usr/bin/git "$@"
EOF
chmod +x "$WORK/shim/git"
R=$(mk hang1); dirty "$R"; new_ah hang; repos "$R"
t0=$(date +%s)
PATH="$WORK/shim:$PATH" SHIM_SLEEP=23 SYNC_FETCH_TIMEOUT=1 scf --quiet
t1=$(date +%s)
assert_contains "timeout: reported as fetch failed" "$(sec hang1)" "fetch failed"
assert_contains "timeout: the rest still reports" "$(sec hang1)" "1 untracked"
assert_eq "timeout: the run was cut short (under 10 s)" "yes" "$([ $((t1 - t0)) -lt 10 ] && echo yes || echo no)"
assert_eq "timeout: the hung fetch (and its sleep) is gone" "0" "$(pgrep -f 'sleep 23' | wc -l | tr -d ' ')"
# the time budget for all fetches together: 0 skips every fetch
R=$(mk bud1); dirty "$R"; new_ah bud; repos "$R"
PATH="$WORK/shim:$PATH" SHIM_SLEEP=23 SYNC_FETCH_BUDGET=0 scf --quiet
assert_contains "fetch budget spent: the fetch is skipped, said so" "$(sec bud1)" "fetch skipped"
assert_eq "fetch budget spent: event says skipped" "skipped" "$(evq bud1 '.data.fetch')"

# ---------- the snapshot is replaced atomically ----------
R=$(mk atom1); dirty "$R"; new_ah atom; repos "$R"
printf 'generated: OLD SNAPSHOT\n' >"$SNAP"
( PATH="$WORK/shim:$PATH" SHIM_SLEEP=3 scf --quiet ) &
bg=$!
i=0; while [ ! -d "$AH/sync-check.lock" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.5
assert_eq "atomic: while the run works the old snapshot is intact" "generated: OLD SNAPSHOT" "$(cat "$SNAP")"
wait "$bg"
assert_contains "atomic: then it is the new one, whole" "$(head -1 "$SNAP")" "generated: 20"
assert_eq "atomic: no temp files left behind" "0" "$(ls -A "$AH" | grep -c '^\.sync-check\|sync-check.md\.' || true)"
assert_no_file "atomic: the lock is released" "$AH/sync-check.lock"

# ---------- events: one per repo with findings, none for clean repos, counts only ----------
RA=$(mk evA); RB=$(mk evB); RC=$(mk evC); new_ah evs; repos "$RA" "$RB" "$RC"
dirty "$RA"; commit_file "$RB" f.txt b "unpushed on B"
sc --quiet
assert_eq "events: one per repo with findings" "2" "$(nev)"
assert_eq "events: the clean repo has none" "0" "$(sync_ev | jq -r 'select(.name=="evC") | .name' | wc -l | tr -d ' ')"
assert_eq "events: kind is sync, name and cwd set" "evA $RA" "$(sync_ev | jq -r 'select(.name=="evA") | "\(.name) \(.cwd)"')"
assert_eq "events: every line stays under the 1 KB cap" "0" "$(awk 'length($0) > 1024 { n++ } END { print n + 0 }' "$EVF")"
assert_eq "events: data is counts, no file lists (all numbers or the fetch word)" "true" \
  "$(sync_ev | jq -s 'all(.[]; .data | to_entries | all(.[]; (.value | type) == "number" or .key == "fetch"))')"
assert_eq "events: the clean repo is on the clean line" "evC" "$(sed -n 's/^clean: //p' "$SNAP")"

# ---------- read-only: nothing but remote-tracking refs changes ----------
state() { # repo -> everything a sync check must leave alone (remote-tracking refs excluded); a linked worktree works too
  local r=$1 gd cd_
  gd=$(git -C "$r" rev-parse --absolute-git-dir); cd_=$(cd "$r" && git rev-parse --path-format=absolute --git-common-dir)
  {
    git -C "$r" for-each-ref --format='%(refname) %(objectname)' | grep -v '^refs/remotes/' || true
    git -C "$r" rev-parse HEAD
    GIT_OPTIONAL_LOCKS=0 git -C "$r" status --porcelain
    git -C "$r" worktree list --porcelain
    git -C "$r" stash list --format='%H %gs'
    git -C "$r" ls-files -s
    git -C "$r" config --list
    shasum "$gd/index" | cut -d' ' -f1
    (cd "$r" && find . -path ./.git -prune -o -type f -print | sort | xargs shasum)
    (cd "$r" && find . -path ./.git -prune -o -type f -print | sort | xargs stat -f '%N %m')
    find "$gd" "$cd_" -name '*.lock'
  } | shasum | cut -d' ' -f1
}
R=$(mk ro1); new_ah ro; repos "$R"
git clone -q "$WORK/ro1.git" "$WORK/ro1-other"; commit_file "$WORK/ro1-other" r.txt remote "remote work"; git -C "$WORK/ro1-other" push -q origin main
git -C "$WORK/ro1-other" tag v9; git -C "$WORK/ro1-other" push -q origin v9             # a tag on the remote: the fetch must not bring it
commit_file "$R" ahead.txt a "ahead"
git -C "$R" checkout -q -b noup; commit_file "$R" n.txt n "no upstream"; git -C "$R" checkout -q main
git -C "$R" worktree add -q -b rowt "$WORK/ro1-wt"; commit_file "$WORK/ro1-wt" w.txt w "wt work"
echo m >>"$R/README.md"; git -C "$R" stash push -q; echo s >"$R/staged.txt"; git -C "$R" add staged.txt; dirty "$R"
touch -t 202001010000 "$R/README.md"                  # stat-dirty tracked file (same content): a plain `git status` would rewrite the index
full_refs() { git -C "$R" for-each-ref --format='%(refname) %(objectname)' | shasum | cut -d' ' -f1; }
b_state=$(state "$R"); b_refs=$(full_refs); b_wt=$(state "$WORK/ro1-wt")
sc --quiet
assert_eq "read-only (no fetch): repo state is identical" "$b_state" "$(state "$R")"
assert_eq "read-only (no fetch): not even a remote-tracking ref changed" "$b_refs" "$(full_refs)"
assert_eq "read-only (no fetch): the linked worktree is identical" "$b_wt" "$(state "$WORK/ro1-wt")"
scf --quiet
assert_eq "read-only (fetch): repo state is identical" "$b_state" "$(state "$R")"
assert_eq "read-only (fetch): the linked worktree is identical" "$b_wt" "$(state "$WORK/ro1-wt")"
assert_eq "read-only (fetch): remote-tracking refs are what moved" "changed" "$([ "$b_refs" != "$(full_refs)" ] && echo changed || echo same)"
assert_eq "read-only: the fetch fetched (origin/main has the remote commit)" "remote work" "$(git -C "$R" log -1 --format=%s origin/main)"
assert_eq "read-only: no tags were fetched or created" "0" "$(git -C "$R" tag | wc -l | tr -d ' ')"
assert_eq "read-only: the stash is still there" "1" "$(git -C "$R" stash list | wc -l | tr -d ' ')"

# a global fetch.prune=true (common) must not make our fetch delete remote-tracking refs
R=$(mk prune1); new_ah prune; repos "$R"; dirty "$R"
git -C "$R" push -q origin main:refs/heads/doomed; git -C "$R" fetch -q origin
git --git-dir="$WORK/prune1.git" update-ref -d refs/heads/doomed   # deleted on the remote itself; origin/doomed is still here
printf '[fetch]\n\tprune = true\n\tpruneTags = true\n' >"$WORK/prune-gitconfig"
GIT_CONFIG_GLOBAL="$WORK/prune-gitconfig" scf --quiet
assert_eq "no prune: a remote-tracking ref of a deleted remote branch is kept, even with fetch.prune=true" "yes" \
  "$(git -C "$R" show-ref --verify --quiet refs/remotes/origin/doomed && echo yes || echo no)"
assert_eq "no prune: sanity: plain git fetch --prune with that config would have removed it" "no" \
  "$(GIT_CONFIG_GLOBAL="$WORK/prune-gitconfig" git -C "$R" fetch -q --prune origin; git -C "$R" show-ref --verify --quiet refs/remotes/origin/doomed && echo yes || echo no)"

# ---------- banner: at most one a day, only for a finding older than 24 h, never spoken ----------
nlog() { local n; n=$(grep -c $'\tdry-run\t.*sync' "$AH/notify.log" 2>/dev/null) || n=0; echo "$n"; }
# fresh findings only: no banner
R=$(mk ban0); dirty "$R"; commit_file "$R" f.txt f "fresh"; new_ah ban0; repos "$R"
SYNC_NOW=$NOON sc --quiet
assert_eq "banner: fresh findings (under 24 h) give none" "0" "$(nlog)"
assert_no_file "banner: and no day stamp" "$AH/sync-banner.day"
# an old unpushed commit: one banner, then none the same day even when the notify budget is wiped
R=$(mk ban1); new_ah ban1; repos "$R"
GIT_COMMITTER_DATE=$(ago 3) commit_file "$R" f.txt f "three days old"
SYNC_NOW=$NOON sc --quiet
assert_eq "banner: a finding older than 24 h gives one banner" "1" "$(nlog)"
last=$(tail -1 "$AH/notify.log" 2>/dev/null || true)
assert_contains "banner: names the repo count" "$last" "1 repo"
assert_contains "banner: names the oldest age" "$last" "oldest 3d"
assert_contains "banner: points at the inbox" "$last" "bin/dash.sh --inbox"
assert_eq "banner: stamped with the local day" "$(date -r "$NOON" +%Y-%m-%d)" "$(cat "$AH/sync-banner.day" 2>/dev/null)"
SYNC_NOW=$((NOON + 3600)) sc --quiet
rm -rf "$AH/notify"                                   # the notify budget and cooldown files are gone: only our stamp is left
SYNC_NOW=$((NOON + 7200)) sc --quiet
assert_eq "banner: no second banner the same day (own stamp, not the notify budget)" "1" "$(nlog)"
SYNC_NOW=$((NOON + DAY)) sc --quiet
assert_eq "banner: the next day brings the next one" "2" "$(nlog)"
assert_eq "banner: it never spoke" "0" "$(wc -l <"$SPOKEN" | tr -d ' ')"
assert_eq "banner: goes through notify.sh as the budgeted kind sync" "sync" "$(jq -r 'select(.kind=="notify" and .data.kind=="sync") | .data.kind' "$EVF" | sort -u)"
# quiet hours: the attempt is suppressed by notify.sh, so the day is not used up and a later run delivers
R=$(mk ban2); new_ah ban2; repos "$R"
GIT_COMMITTER_DATE=$(ago 3) commit_file "$R" f.txt f "three days old"
THREE=$((NOON - 9 * 3600))
SYNC_NOW=$THREE sc --quiet
assert_contains "banner: at 03:00 notify.sh holds it back" "$(cat "$AH/notify.log")" "suppressed:quiet-hours"
assert_no_file "banner: a suppressed banner does not use up the day" "$AH/sync-banner.day"
SYNC_NOW=$NOON sc --quiet
assert_eq "banner: at noon it is delivered" "1" "$(nlog)"
assert_file "banner: and the day is stamped" "$AH/sync-banner.day"
# a behind-origin or stash finding older than 24 h counts too (any of the five)
R=$(mk ban3); new_ah ban3; repos "$R"
echo c >>"$R/README.md"; GIT_COMMITTER_DATE=$(ago 4) git -C "$R" stash push -q
SYNC_NOW=$NOON sc --quiet
assert_eq "banner: an old stash is enough" "1" "$(nlog)"
assert_eq "banner: nothing was ever spoken" "0" "$(wc -l <"$SPOKEN" | tr -d ' ')"

# ---------- lock ----------
R=$(mk lk1); dirty "$R"; new_ah lk; repos "$R"
mkdir "$AH/sync-check.lock"
rc=0; out=$(sc 2>&1) || rc=$?
assert_eq "lock: a fresh lock means another run is busy: exit 0" "0" "$rc"
assert_no_file "lock: and nothing was written" "$SNAP"
assert_contains "lock: it says why" "$out" "already running"
touch -t 202001010000 "$AH/sync-check.lock"
sc --quiet
assert_file "lock: a stale lock does not block" "$SNAP"
assert_no_file "lock: and is cleaned up" "$AH/sync-check.lock"

# ---------- the per-run output on a busy machine stays one line ----------
R=$(mk sum1); dirty "$R"; R2=$(mk sum2); new_ah sum; repos "$R" "$R2"
out=$(sc)
assert_eq "summary: two lines (summary, snapshot path)" "2" "$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
assert_contains "summary: 1 repo needs attention, 1 clean" "$(printf '%s\n' "$out" | head -1)" "1 repo needs attention, 1 clean"
exit 0
