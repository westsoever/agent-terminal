# Hermes Harvest (Phase 1.5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an event log, smarter notifications, a launchd watcher, an inbox/next dashboard, mandatory pre-release review and four new guard rules to the Ching bash kit, without breaking the existing 600+ checks.

**Architecture:** Everything stays in the existing bash kit (`bin/*.sh`, sourced `bin/lib.sh`, `jq`). Hooks append to `~/.agent/events.jsonl` through one helper (`ev`). Sessions write a checkpoint block in STATE.md that the hooks and `dash.sh` parse (`checkpoint_get`). A one-shot script, `ching-watch.sh`, run by launchd every 5 minutes, adds stall, context and token signals to each session's meta file. `notify.sh` routes alerts and enforces a budget. `release-gate.sh` requires a review file. `guard.sh` gains rules 8-11.

**Tech Stack:** macOS system bash 3.2, jq 1.7.1, perl 5, git, launchd/`launchctl`, shellcheck (via `tests/t_lint.sh`). Tests use the existing harness `tests/run.sh` + `tests/lib.sh`.

**Spec:** `docs/superpowers/specs/2026-10-05-hermes-harvest-design.md`. Read its section 12 (amendments made during planning) first.

## Global Constraints

- Bash 3.2 compatible: no associative arrays, no `${var,,}`, no `mapfile`/`readarray`, no `&>>`.
- Every script in `bin/` except `lib.sh` keeps `set -euo pipefail` within its first 40 lines (`t_lint` enforces it).
- No new dependencies. Only jq, perl, git and the macOS base tools.
- No AI or model calls in any Phase 1.5 code.
- Tests never touch real `~/.claude`, `~/.agent`, `~/Library/LaunchAgents` or launchd. Everything goes through the `tests/lib.sh` sandbox, and `LAUNCHCTL` is always a stub in tests.
- shellcheck `-S warning` stays clean for `bin/*.sh` and `install.sh`.
- Constants (spec values, verbatim):

  | Constant | Value |
  |---|---|
  | `NOTIFY_BUDGET` | 4 |
  | `NOTIFY_QUIET_START` | 21 |
  | `NOTIFY_QUIET_END` | 9 |
  | `NOTIFY_COOLDOWN_MINS` | 45 |
  | `WATCH_STALL_MINS` | 20 |
  | Context levels | healthy < 60%, watch 60-80%, handoff > 80% (80% exactly counts as handoff) |
  | `WATCH_ROTATE_BYTES` | 20971520 |
  | Event string cap | 300 chars |
  | Event line cap | 1024 chars |
  | launchd `StartInterval` | 300 |
  | Lock staleness | 600 s |

- Urgent notification kinds are exactly `input`, `blocked` and `ready`. `done` goes to the inbox. Every other kind is budgeted.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R
  ```
- All work happens in the worktree `~/bbq/.worktrees/ching-harvest` on branch `phase-1.5-harvest` (Task 0). Another session works on `main` in `~/bbq/ching`; never edit files there.

## Review Focus

1. **"blocker: none" in a checkpoint, with an old bullet left under `## Blocked`.** The session must not show as blocked. Test in Task 7.
2. **Quiet-hour boundaries.** A budgeted alert at exactly 09:00 is delivered; one at exactly 21:00 waits. Test in Task 4.
3. **`review:` with an odd value** (`Off`, `no`, `off ` with trailing space). Anything other than exactly `off` after trimming means review is required, so the gate fails safe. Test in Task 8.
4. **A transcript that shrinks** (replaced or truncated). The watcher resets its offset, keeps running and never stores a negative or stale offset. Test in Task 5.
5. **A cwd containing quotes or a newline.** `ev` still writes one valid JSON line. Test in Task 1.

## Execution waves (D10: parallel implementers on disjoint files, separate verifier)

| Wave | Tasks | Files touched (disjoint within a wave) |
|---|---|---|
| 0 | Task 0 | none (preconditions, worktree) |
| 1 | Task 1 | `bin/lib.sh`, `tests/t_events.sh` |
| 2 | **A:** Task 2 → Task 3 · **B:** Task 4 · **C:** Task 8 · **D:** Task 9 → Task 10 | A: session-start, pre-compact, stop-check, post-release, migrate-gate, STATE.md template, handoff.md, t_session, t_stop, t_post_release, t_migrate · B: notify.sh, t_notify · C: release-gate, VERIFY.md, REVIEW.md, review-lenses/, t_release · D: guard.sh, t_guard |
| 3 | **E:** Task 5 · **F:** Task 6 · **G:** Task 7 | E: ching-watch.sh, t_watch · F: install.sh, tests/lib.sh, t_install · G: dash.sh, dispatcher/AGENTS.md, t_dash |
| 4 | Task 11, then Task 12 | autonomy block, t_templates; then verification and docs |

---

### Task 0: Preconditions and worktree

**Files:** none changed.

- [ ] **Step 1: Wait for the other session's in-flight work to land on `main`**

Run: `git -C ~/bbq/ching status --short bin/stop-check.sh tests/lib.sh tests/t_stop.sh bin/test-escalate.sh tests/t_escalate.sh`
Expected: empty output, meaning that work is committed. If anything is listed, STOP. Tell the user: "Phase 1.5 edits stop-check.sh and tests/lib.sh, which another session has uncommitted changes to. Please let it commit first." Do not continue until it is clean.

- [ ] **Step 2: Create the worktree**

```bash
git -C ~/bbq/ching worktree add ~/bbq/.worktrees/ching-harvest -b phase-1.5-harvest main
cd ~/bbq/.worktrees/ching-harvest
```

- [ ] **Step 3: Baseline suite**

Run: `tests/run.sh`
Expected: `TOTAL: N passed, 0 failed`. Write N down; every later task must keep 0 failed.

---

### Task 1: Event log and checkpoint contracts in `lib.sh`

**Files:**
- Modify: `bin/lib.sh` (append at end)
- Create: `tests/t_events.sh`

**Interfaces:**
- Produces: `ev KIND [DATA_JSON]` appends `{"ts","sid","name","cwd","kind","data"}` to `$AGENT_HOME/events.jsonl`. It reads the globals `SID`, `NAME` and `CWD` if set, and always returns 0.
- Produces: `checkpoint_get FILE KEY` prints the value of the first `KEY:` line between `<!-- ching:checkpoint -->` and `<!-- /ching:checkpoint -->`, or nothing.

- [ ] **Step 1: Write the failing test** `tests/t_events.sh`

```bash
#!/usr/bin/env bash
# lib.sh contracts: ev (append-only event log) and checkpoint_get (STATE.md checkpoint block).
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
EVF="$AGENT_HOME/events.jsonl"

SID=s1; NAME=demo; CWD=/tmp/demo
ev prompt
line=$(tail -1 "$EVF")
assert_eq "ev: kind" "prompt" "$(printf '%s' "$line" | jq -r .kind)"
assert_eq "ev: sid" "s1" "$(printf '%s' "$line" | jq -r .sid)"
assert_eq "ev: name" "demo" "$(printf '%s' "$line" | jq -r .name)"
assert_eq "ev: cwd" "/tmp/demo" "$(printf '%s' "$line" | jq -r .cwd)"
assert_eq "ev: empty data is {}" "{}" "$(printf '%s' "$line" | jq -c .data)"
assert_contains "ev: ISO UTC timestamp" "$(printf '%s' "$line" | jq -r .ts)" "Z"
assert_eq "ev: file is private (0600)" "600" "$(stat -f %Lp "$EVF")"

ev stop_blocked '{"retry":2,"reason":"tests"}'
assert_eq "ev: data kept" "2" "$(tail -1 "$EVF" | jq -r .data.retry)"

long=$(printf 'x%.0s' $(seq 1 500))
ev notify "$(jq -nc --arg m "$long" '{msg:$m}')"
assert_eq "ev: strings cut to 300 chars" "300" "$(tail -1 "$EVF" | jq -r '.data.msg | length')"

ev notify "$(jq -nc --arg m "$long" '{a:$m,b:$m,c:$m,d:$m}')"
assert_eq "ev: line over 1 KB keeps only truncated:true" '{"truncated":true}' "$(tail -1 "$EVF" | jq -c .data)"

# Review Focus 5: quotes and newlines in cwd still give one valid JSON line
CWD=$'/tmp/we"ird\nfolder'
ev prompt
CWD=/tmp/demo
assert_eq "ev: every line is valid JSON (quotes/newline in cwd)" "$(wc -l <"$EVF" | tr -d ' ')" "$(jq -c . "$EVF" | wc -l | tr -d ' ')"
assert_contains "ev: the odd cwd survives" "$(jq -r 'select(.kind=="prompt") | .cwd' "$EVF")" 'we"ird'

n=$(wc -l <"$EVF")
out=$(ev bad 'not json' 2>&1); rc=$?
assert_eq "ev: bad data returns 0" "0" "$rc"
assert_eq "ev: bad data prints nothing" "" "$out"
assert_eq "ev: bad data writes nothing" "$n" "$(wc -l <"$EVF")"

touch "$WORK/afile"
out=$(AGENT_HOME="$WORK/afile/sub" ev prompt 2>&1); rc=$?
assert_eq "ev: unwritable log returns 0" "0" "$rc"
assert_eq "ev: unwritable log prints nothing" "" "$out"

S="$WORK/STATE.md"
cat >"$S" <<'EOS'
# State
status: working
blocker: not-in-block
<!-- ching:checkpoint -->
result: wired the widget
blocker: need the staging token
next_action: run the gate
not_examined: mobile layout
<!-- /ching:checkpoint -->
EOS
assert_eq "checkpoint_get: reads a key inside the block" "need the staging token" "$(checkpoint_get "$S" blocker)"
assert_eq "checkpoint_get: next_action" "run the gate" "$(checkpoint_get "$S" next_action)"
assert_eq "checkpoint_get: absent key is empty" "" "$(checkpoint_get "$S" files_changed)"
assert_eq "checkpoint_get: missing file is empty" "" "$(checkpoint_get "$WORK/nope.md" result)"
printf '# State\nblocker: outside\n' >"$WORK/S2.md"
assert_eq "checkpoint_get: ignores keys outside the block" "" "$(checkpoint_get "$WORK/S2.md" blocker)"
exit 0
```

- [ ] **Step 2: Run it and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_events|TOTAL'`
Expected: `t_events` shows failures (`ev: command not found`).

- [ ] **Step 3: Implement.** Append to `bin/lib.sh`:

```bash
# ev KIND [DATA_JSON]: append one line to $AGENT_HOME/events.jsonl, the input contract for the Phase 6
# learning loop. Uses SID NAME CWD when set. Strings in DATA are cut to 300 chars; a line over 1 KB keeps
# only {"truncated":true}. Never fails and never prints: observing must not break a hook.
ev() {
  local kind=$1 data=${2:-} line
  [ -n "$data" ] || data='{}'
  line=$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg sid "${SID:-}" --arg name "${NAME:-}" \
      --arg cwd "${CWD:-}" --arg kind "$kind" --argjson data "$data" \
      '{ts:$ts, sid:$sid, name:$name, cwd:$cwd, kind:$kind,
        data:($data | walk(if type == "string" then .[0:300] else . end))}' 2>/dev/null) || return 0
  if [ "${#line}" -gt 1024 ]; then
    line=$(printf '%s' "$line" | jq -c '.data = {truncated: true}' 2>/dev/null) || return 0
  fi
  { (umask 077; mkdir -p "$AGENT_HOME" && printf '%s\n' "$line" >>"$AGENT_HOME/events.jsonl"); } 2>/dev/null || true
  return 0
}

checkpoint_get() { # file key -> value of the first `key:` line inside the ching:checkpoint block
  [ -f "$1" ] || return 0
  awk -v k="$2" '
    index($0, "<!-- ching:checkpoint -->") == 1 { c = 1; next }
    index($0, "<!-- /ching:checkpoint -->") == 1 { c = 0; next }
    c && index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[[:space:]]+/, "", v); sub(/[[:space:]]+$/, "", v); print v; exit }
  ' "$1"
}
```

- [ ] **Step 4: Run all tests and confirm they pass**

Run: `tests/run.sh`
Expected: `TOTAL: … 0 failed`. `t_events` passes all its checks.

- [ ] **Step 5: Commit**

```bash
git add bin/lib.sh tests/t_events.sh
git commit -m "lib: add ev (event log) and checkpoint_get contracts

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 2: Events from hooks and gates (session-start, pre-compact, stop-check, post-release, migrate-gate)

**Files:**
- Modify: `bin/session-start.sh`, `bin/pre-compact.sh`, `bin/stop-check.sh`, `bin/post-release.sh`, `bin/migrate-gate.sh`
- Test: `tests/t_session.sh`, `tests/t_stop.sh`, `tests/t_post_release.sh`, `tests/t_migrate.sh`

**Interfaces:**
- Consumes: `ev` and the `SID`/`NAME`/`CWD` globals set by `hook_init` (Task 1).
- Produces: meta key `prompted=<epoch>`, written on every UserPromptSubmit and used by Task 3. Event kinds `session_start`, `prompt`, `session_end`, `compact`, `stop_ok`, `stop_blocked`, `release`, `migrate`.

- [ ] **Step 1: Write the failing tests.** Append before the final `exit 0` of `tests/t_session.sh`:

```bash
# ---------- events (Phase 1.5) ----------
EVF="$AGENT_HOME/events.jsonl"
ER=$(mk_repo evrepo)
run_hook session-start.sh "$(hook_json SessionStart "$ER" s-ev '{"source":"startup"}')" >/dev/null
assert_eq "events: session_start with source" "startup" "$(jq -r 'select(.kind=="session_start" and .sid=="s-ev") | .data.source' "$EVF")"
printf '%s' "$(hook_json UserPromptSubmit "$ER" s-ev)" | "$BIN/session-start.sh" touch
assert_contains "touch writes prompted to meta" "$(cat "$AGENT_HOME/sessions/s-ev/meta")" "prompted="
assert_eq "events: prompt" "1" "$(jq -r 'select(.kind=="prompt" and .sid=="s-ev") | .kind' "$EVF" | wc -l | tr -d ' ')"
run_hook pre-compact.sh "$(hook_json PreCompact "$ER" s-ev '{"trigger":"auto"}')"
assert_eq "events: compact with trigger" "auto" "$(jq -r 'select(.kind=="compact" and .sid=="s-ev") | .data.trigger' "$EVF")"
printf '%s' "$(hook_json SessionEnd "$ER" s-ev)" | "$BIN/session-start.sh" end
assert_eq "events: session_end" "1" "$(jq -r 'select(.kind=="session_end" and .sid=="s-ev") | .kind' "$EVF" | wc -l | tr -d ' ')"
assert_eq "events: name is the repo" "evrepo" "$(jq -r 'select(.sid=="s-ev") | .name' "$EVF" | sort -u)"
```

Append before the final `exit 0` of `tests/t_stop.sh`:

```bash
# ---------- events (Phase 1.5) ----------
EVF="$AGENT_HOME/events.jsonl"
assert_eq "events: three test blocks and one cap for sess-A" "4" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .kind' "$EVF" | wc -l | tr -d ' ')"
assert_contains "events: cap is marked" "$(jq -r 'select(.sid=="sess-A" and .kind=="stop_blocked") | .data.reason' "$EVF")" "tests-cap"
assert_contains "events: a green stop logs stop_ok" "$(jq -r 'select(.kind=="stop_ok") | .sid' "$EVF")" "sess-B"
```

Append before the final `exit 0` of `tests/t_post_release.sh`:

```bash
# ---------- events (Phase 1.5) ----------
assert_contains "events: deploy outcome logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "deploy-"
```

Append before the final `exit 0` of `tests/t_migrate.sh`:

```bash
# ---------- events (Phase 1.5) ----------
assert_contains "events: migrate gate outcome logged" "$(jq -r 'select(.kind=="migrate") | .data.outcome' "$AGENT_HOME/events.jsonl")" "gate-"
```

- [ ] **Step 2: Run and confirm they fail**

Run: `tests/run.sh 2>&1 | grep -E 'events|TOTAL'`
Expected: FAIL lines for each `events:` assertion.

- [ ] **Step 3: Implement**

`bin/session-start.sh`, replace the `case "$MODE"` block with:

```bash
case "$MODE" in
  touch) meta_set state working; meta_set updated "$NOW"; meta_set prompted "$NOW"; ev prompt; exit 0 ;;
  end)   meta_set state ended;   meta_set updated "$NOW"; ev session_end; exit 0 ;;
esac
```

and directly after the line `rm -f "$SESS_DIR/retries"` add:

```bash
ev session_start "$(jq -nc --arg s "$(jget source)" '{source:$s}')"
```

`bin/pre-compact.sh`, after `resolve_state` add:

```bash
ev compact "$(jq -nc --arg t "$(jget trigger)" '{trigger:$t}')"
```

`bin/stop-check.sh` gets three insertions:
1. In `finish_ok`, directly before `set_state "$kind"`, add:
   ```bash
   ev stop_ok "$(jq -nc --arg k "$kind" '{outcome:$k}')"
   ```
2. In the cap branch, directly before `set_state blocked`, add:
   ```bash
   ev stop_blocked '{"retry":"cap","reason":"tests-cap"}'
   ```
3. Directly after `printf '%s\n' "$n" >"$COUNTER"`, add:
   ```bash
   ev stop_blocked "$(jq -nc --argjson n "$n" '{retry:$n,reason:"tests"}')"
   ```

`bin/post-release.sh`: if `grep -n 'lib.sh' bin/post-release.sh` shows no `. "$SELF_DIR/lib.sh"` line, add the standard block after `set -euo pipefail`:

```bash
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"
```

Then, directly after the line `record` (before `case "$RESULT" in`), add:

```bash
CWD=$ROOT; NAME=$(basename "$ROOT")
ev release "$(jq -nc --arg s "$SHA" --arg o "$RESULT" '{sha:$s,outcome:("deploy-" + $o)}')"
```

`bin/migrate-gate.sh` gets three changes:
1. Directly after `cd "$ROOT"`, add:
   ```bash
   CWD=$ROOT; NAME=$(basename "$ROOT")
   ```
2. Replace the `fail()` definition with:
   ```bash
   fail() { ev migrate "$(jq -nc --arg m "$1" '{outcome:"gate-fail",detail:$m}')"; echo "migrate-gate: FAIL: $1" >&2; exit 1; }
   ```
3. Directly before the final `echo "migrate-gate: PASS …"`, add:
   ```bash
   ev migrate "$(jq -nc --argjson n "$n" '{outcome:"gate-pass",files:$n}')"
   ```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/session-start.sh bin/pre-compact.sh bin/stop-check.sh bin/post-release.sh bin/migrate-gate.sh tests/t_session.sh tests/t_stop.sh tests/t_post_release.sh tests/t_migrate.sh
git commit -m "hooks and gates: write events to ~/.agent/events.jsonl; record prompted time

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 3: Checkpoint block, `/handoff`, and the block-once rule in `stop-check.sh`

**Files:**
- Modify: `templates/STATE.md`, `commands/handoff.md`, `bin/stop-check.sh`
- Test: `tests/t_stop.sh`

**Interfaces:**
- Consumes: `checkpoint_get`, `ev` (Task 1); meta `prompted` (Task 2).
- Produces: meta key `checkpoint_blocked_for=<prompted epoch>`; event `checkpoint{status,blocker,next_action}`; event `stop_blocked{reason:"checkpoint"}`. The STATE.md checkpoint keys are `result`, `blocker`, `next_action`, `files_changed`, `examined`, `not_examined`.
- Rule: only applies when `REPO_MODE=1` **and** meta has `prompted`.

- [ ] **Step 1: Write the failing tests.** Append before the final `exit 0` of `tests/t_stop.sh`:

```bash
# ---------- checkpoint rule (Phase 1.5) ----------
CR=$(mk_repo cprepo); write_goal "$CR" "true"
touch_prompt() { printf '%s' "$(hook_json UserPromptSubmit "$1" "$2")" | "$BIN/session-start.sh" touch; }
touch_prompt "$CR" cp-1
out=$(stop "$CR" cp-1)
assert_eq "checkpoint missing: blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
assert_contains "checkpoint missing: reason names /handoff" "$(printf '%s' "$out" | jq -r .reason)" "/handoff"
out=$(stop "$CR" cp-1)
assert_eq "checkpoint: asked only once per prompt" "" "$out"
touch_prompt "$CR" cp-2
printf '# State\nstatus: done\n<!-- ching:checkpoint -->\nresult: ok\nblocker: none\nnext_action: none\n<!-- /ching:checkpoint -->\n' >"$CR/.agent/STATE.md"
out=$(stop "$CR" cp-2)
assert_eq "fresh checkpoint: no block" "" "$out"
assert_contains "fresh checkpoint: checkpoint event" "$(jq -r 'select(.kind=="checkpoint") | .sid' "$AGENT_HOME/events.jsonl")" "cp-2"
touch -t 202001010000 "$CR/.agent/STATE.md"
touch_prompt "$CR" cp-2
out=$(stop "$CR" cp-2)
assert_eq "stale checkpoint (older than the prompt): blocks" "block" "$(printf '%s' "$out" | jq -r .decision)"
CP="$WORK/cp plain"; mkdir -p "$CP"
touch_prompt "$CP" cp-3
out=$(stop "$CP" cp-3)
assert_eq "plain folder: never blocks for a checkpoint" "" "$out"
NR=$(mk_repo cpnoprompt); write_goal "$NR" "true"
out=$(stop "$NR" cp-4)
assert_eq "no recorded prompt: never blocks for a checkpoint" "" "$out"
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 'checkpoint|TOTAL'`
Expected: FAIL on "checkpoint missing: blocks".

- [ ] **Step 3: Implement**

`bin/stop-check.sh`: add this function directly above `finish_ok() {`:

```bash
# Repo mode only, and only once a prompt was recorded: block ONCE per prompt when STATE.md has no
# checkpoint block or it was not updated since that prompt. The meta key makes the next Stop pass.
checkpoint_gate() {
  [ "$REPO_MODE" -eq 1 ] || return 0
  local prompted st status
  prompted=$(meta_get "$SESS_DIR/meta" prompted)
  [ -n "$prompted" ] || return 0
  [ "$(meta_get "$SESS_DIR/meta" checkpoint_blocked_for)" != "$prompted" ] || return 0
  st="$STATE_DIR/STATE.md"
  if [ -f "$st" ] && grep -qF '<!-- ching:checkpoint -->' "$st" && [ "$(file_mtime "$st")" -ge "$prompted" ]; then
    status=$(sed -n 's/^status:[[:space:]]*//p' "$st" | head -1)
    ev checkpoint "$(jq -nc --arg s "$status" --arg b "$(checkpoint_get "$st" blocker)" --arg n "$(checkpoint_get "$st" next_action)" \
      '{status:$s,blocker:$b,next_action:$n}')"
    return 0
  fi
  meta_set checkpoint_blocked_for "$prompted"
  ev stop_blocked '{"retry":1,"reason":"checkpoint"}'
  jq -n --arg r "Do not stop yet: update the checkpoint block in $st for this turn (run /handoff: result, blocker, next_action, files_changed, examined, not_examined). This is asked once per prompt." \
    '{decision:"block", reason:$r}'
  exit 0
}
```

Then make the first line inside `finish_ok() {` the call:

```bash
  checkpoint_gate
```

`templates/STATE.md`: replace the first four lines (`# State` … the status comment) with:

```markdown
# State

status: idle
<!-- status is one of: idle | working | input | blocked | done. dash.sh reads this line. -->

<!-- ching:checkpoint -->
result: (none)
blocker: none
next_action: (none)
files_changed: 0
examined: (none)
not_examined: (none)
<!-- /ching:checkpoint -->
```

`commands/handoff.md`: replace step 2's first sentence so step 2 begins:

```markdown
2. Update `STATE.md` there. Keep the `status:` line (idle | working | input | blocked | done). Directly under it, rewrite the checkpoint block (create it if missing), one line per key, nothing else inside the markers:
   ```
   <!-- ching:checkpoint -->
   result: <one line: what this turn achieved>
   blocker: none | <the exact missing piece: a file, a credential, a decision>
   next_action: <one line>
   files_changed: <number>
   examined: <what this work covered>
   not_examined: <what it deliberately did not check>
   <!-- /ching:checkpoint -->
   ```
   The Stop hook and `dash.sh` parse this block. Then keep the sections Done, In progress, Blocked, …
```

(Keep the rest of the original step 2 sentence after "Keep the sections …" exactly as it was.)

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Existing t_stop tests are unaffected, because they never record a prompt.

- [ ] **Step 5: Commit**

```bash
git add bin/stop-check.sh templates/STATE.md commands/handoff.md tests/t_stop.sh
git commit -m "checkpoint block in STATE.md; Stop asks once per prompt in repo mode

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 4: `notify.sh` routing and interruption budget

**Files:**
- Modify: `bin/notify.sh` (full replacement below)
- Test: `tests/t_notify.sh`

**Interfaces:**
- Consumes: `ev` (Task 1).
- Produces:
  - Kinds `stall`, `handoff` and `tokens` (used by Task 5).
  - The `notify.log` method column is one of `dry-run`, `terminal-notifier`, `osascript`, `inbox` or `suppressed:<reason>`, where reason is `quiet-hours`, `daily-budget` or `cooldown`.
  - Event `notify{kind,outcome,reason}`.
  - Env `NOTIFY_NOW` (epoch) for tests.

- [ ] **Step 1: Update the existing tests and add the new ones** in `tests/t_notify.sh`

1. Directly after the `. "$(dirname …)/lib.sh"` line, add (budgeted alerts in the old tests then always fall at noon):
   ```bash
   export NOTIFY_NOW; NOTIFY_NOW=$(date -j -f '%Y-%m-%d %H:%M:%S' "$(date +%Y-%m-%d) 12:00:00" +%s)
   ```
2. In the terminal-notifier block, change `"$BIN/notify.sh" done "ok"` to `"$BIN/notify.sh" blocked "ok"`, and in the `NOTIFY_ACTIVATE` line change `done ok` to `blocked ok`, because `done` no longer pushes.
3. Append before the final `exit 0`:

```bash
# ---------- routing and budget (Phase 1.5) ----------
export NOTIFY_DRY_RUN=1; : >"$LOG"; rm -rf "$AGENT_HOME/notify"
NOON=$(date -j -f '%Y-%m-%d %H:%M:%S' "2026-10-05 12:00:00" +%s)
nt() { printf '%s' "$(hook_json Notification "$R" "$1")" | NOTIFY_NOW=${3:-$NOON} "$BIN/notify.sh" "$2" "m"; }
nt r1 done
assert_contains "done goes to the inbox, not a push" "$(tail -1 "$LOG")" $'\tinbox\t'
nt r2 blocked
assert_contains "blocked is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
for s in b1 b2 b3 b4; do nt "$s" stall; done
assert_eq "four budgeted alerts delivered" "4" "$(grep -c $'\tdry-run\t.*Stalled' "$LOG")"
nt b5 stall
assert_contains "fifth budgeted alert is suppressed" "$(tail -1 "$LOG")" "suppressed:daily-budget"
nt b6 input
assert_contains "urgent bypasses an exhausted budget" "$(tail -1 "$LOG")" $'\tdry-run\t'
rm -rf "$AGENT_HOME/notify"
nt q1 stall $((NOON + 10 * 3600))
assert_contains "budgeted alert at 22:00 waits" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
nt q2 blocked $((NOON + 10 * 3600))
assert_contains "urgent alert at 22:00 is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
# Review Focus 2: boundaries
rm -rf "$AGENT_HOME/notify"
nt q3 stall $((NOON - 3 * 3600))
assert_contains "budgeted alert at exactly 09:00 is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
nt q4 stall $((NOON + 9 * 3600))
assert_contains "budgeted alert at exactly 21:00 waits" "$(tail -1 "$LOG")" "suppressed:quiet-hours"
rm -rf "$AGENT_HOME/notify"
nt c1 stall
nt c1 handoff $((NOON + 600))
assert_contains "second budgeted alert within 45 min is suppressed" "$(tail -1 "$LOG")" "suppressed:cooldown"
nt c1 handoff $((NOON + 46 * 60))
assert_contains "after the cooldown it is delivered" "$(tail -1 "$LOG")" $'\tdry-run\t'
rm -rf "$AGENT_HOME/notify"; mkdir -p "$AGENT_HOME/notify"; echo garbage >"$AGENT_HOME/notify/budget-2026-10-05"
nt k1 stall
assert_contains "corrupt budget file counts as 0" "$(tail -1 "$LOG")" $'\tdry-run\t'
printf '%s' "$(hook_json Notification "$R" pd1)" | NOTIFY_NOW=$NOON NOTIFY_PUSH_DONE=1 "$BIN/notify.sh" done m
assert_contains "NOTIFY_PUSH_DONE=1 pushes done" "$(tail -1 "$LOG")" $'\tdry-run\t'
assert_contains "stall label" "$(grep -m1 Stalled "$LOG")" "notifyrepo (main): Stalled"
EVF="$AGENT_HOME/events.jsonl"
assert_contains "events: suppressed alert with reason" "$(jq -r 'select(.kind=="notify" and .data.outcome=="suppressed") | .data.reason' "$EVF")" "daily-budget"
assert_contains "events: inbox routing" "$(jq -r 'select(.kind=="notify") | .data.reason' "$EVF")" "routed-to-inbox"
```

- [ ] **Step 2: Run and confirm the new tests fail**

Run: `tests/run.sh 2>&1 | grep -E 't_notify|TOTAL'`
Expected: failures, starting with "done goes to the inbox".

- [ ] **Step 3: Implement.** Replace `bin/notify.sh` entirely with:

```bash
#!/usr/bin/env bash
# notify.sh KIND [MESSAGE]
# KIND: done | input | blocked | ready | idle | stall | handoff | tokens
# Routing (Phase 1.5): input, blocked and ready are urgent and always delivered. done goes to the inbox
# (dash.sh --inbox) and is not pushed (NOTIFY_PUSH_DONE=1 restores the push). Every other kind is
# budgeted: delivered only between NOTIFY_QUIET_END (9) and NOTIFY_QUIET_START (21) local time, at most
# NOTIFY_BUDGET (4) a day, NOTIFY_COOLDOWN_MINS (45) apart per session; otherwise logged as suppressed.
# Hook usage reads hook JSON on stdin (cwd, session_id); works in any folder, repo or not. The folder /
# repo name is always in the title. Delivery: terminal-notifier (click activates the Claude app), else
# osascript. Env: NOTIFY_CWD NOTIFY_SESSION NOTIFY_ACTIVATE NOTIFY_DRY_RUN NOTIFY_LOG NOTIFY_NOW (epoch)
# NOTIFY_TERMINAL_NOTIFIER NOTIFY_OSASCRIPT NOTIFY_IDLE_SUPPRESS (900 s) NOTIFY_PUSH_DONE AGENT_HOME
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

KIND=${1:-done}
MSG=${2:-}
ACTIVATE=${NOTIFY_ACTIVATE:-com.anthropic.claudefordesktop}

HOOK_CWD=${NOTIFY_CWD:-}
hook_init
if [ -n "${NOTIFY_CWD:-}" ]; then
  CWD=$NOTIFY_CWD
  ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null || true)
  NAME=$(name_for "$CWD" "$ROOT")
fi
SESSION=${NOTIFY_SESSION:-$SID}
SID=$SESSION
BRANCH=$(git -C "$CWD" symbolic-ref --short -q HEAD 2>/dev/null || true)

case "$KIND" in
  done)    LABEL="Done";                DEFAULT="Session finished." ;;
  input)   LABEL="Needs input";         DEFAULT="Waiting for your answer." ;;
  blocked) LABEL="Blocked";             DEFAULT="Stopped and needs you." ;;
  ready)   LABEL="Ready to push";       DEFAULT="Release gate passed; waiting for your approval." ;;
  idle)    LABEL="Waiting";             DEFAULT="Idle, waiting for you." ;;
  stall)   LABEL="Stalled";             DEFAULT="No progress for a while." ;;
  handoff) LABEL="Context almost full"; DEFAULT="Run /handoff and continue in a fresh session." ;;
  tokens)  LABEL="Token budget";        DEFAULT="Token use crossed a daily budget mark." ;;
  *)       LABEL="$KIND";               DEFAULT="" ;;
esac
[ -n "$MSG" ] || MSG=$DEFAULT

TITLE="$NAME"
[ -z "$BRANCH" ] || TITLE="$NAME ($BRANCH)"
TITLE="$TITLE: $LABEL"

clean() { printf '%s' "$1" | tr '\n\r\t' '   ' | tr -d '\000-\037' | cut -c1-200; }
TITLE=$(clean "$TITLE")
MSG=$(clean "$MSG")

mkdir -p "$AGENT_HOME/notify"
LAST="$AGENT_HOME/notify/$SESSION.last"
NOW=${NOTIFY_NOW:-$(date +%s)}

# idle_prompt fires ~60s after a response. Skip it when we already notified this session recently.
if [ "$KIND" = idle ] && [ -f "$LAST" ]; then
  prev=$(cat "$LAST" 2>/dev/null || echo 0)
  case "$prev" in ''|*[!0-9]*) prev=0 ;; esac
  if [ $((NOW - prev)) -lt "${NOTIFY_IDLE_SUPPRESS:-900}" ]; then exit 0; fi
fi
printf '%s\n' "$NOW" >"$LAST"

LOG=${NOTIFY_LOG:-$AGENT_HOME/notify.log}
TN=${NOTIFY_TERMINAL_NOTIFIER:-terminal-notifier}
OSA=${NOTIFY_OSASCRIPT:-osascript}

if [ -n "${NOTIFY_DRY_RUN:-}" ]; then
  METHOD=dry-run
elif command -v "$TN" >/dev/null 2>&1; then
  METHOD=terminal-notifier
else
  METHOD=osascript
fi

case "$KIND" in
  input|blocked|ready) CLASS=urgent ;;
  done) if [ -n "${NOTIFY_PUSH_DONE:-}" ]; then CLASS=urgent; else CLASS=inbox; fi ;;
  *) CLASS=budgeted ;;
esac

WHY=""
budget_ok() { # 0 when a budgeted alert may go out now (and books it); else sets WHY
  local hour used last file
  hour=$(date -r "$NOW" +%H); hour=${hour#0}
  if [ "$hour" -lt "${NOTIFY_QUIET_END:-9}" ] || [ "$hour" -ge "${NOTIFY_QUIET_START:-21}" ]; then WHY=quiet-hours; return 1; fi
  file="$AGENT_HOME/notify/budget-$(date -r "$NOW" +%Y-%m-%d)"
  used=$(cat "$file" 2>/dev/null || echo 0); case "$used" in ''|*[!0-9]*) used=0 ;; esac
  if [ "$used" -ge "${NOTIFY_BUDGET:-4}" ]; then WHY=daily-budget; return 1; fi
  last=$(cat "$AGENT_HOME/notify/$SESSION.budgeted" 2>/dev/null || echo 0); case "$last" in ''|*[!0-9]*) last=0 ;; esac
  if [ $((NOW - last)) -lt $(( ${NOTIFY_COOLDOWN_MINS:-45} * 60 )) ]; then WHY=cooldown; return 1; fi
  printf '%s\n' $((used + 1)) >"$file"
  printf '%s\n' "$NOW" >"$AGENT_HOME/notify/$SESSION.budgeted"
  return 0
}

OUTCOME=delivered
case "$CLASS" in
  inbox) METHOD=inbox; OUTCOME=suppressed; WHY=routed-to-inbox ;;
  budgeted) if ! budget_ok; then METHOD="suppressed:$WHY"; OUTCOME=suppressed; fi ;;
esac

printf '%s\t%s\t%s\t%s\n' "$(date -r "$NOW" '+%Y-%m-%d %H:%M:%S')" "$METHOD" "$TITLE" "$MSG" >>"$LOG"
ev notify "$(jq -nc --arg k "$KIND" --arg o "$OUTCOME" --arg w "$WHY" '{kind:$k,outcome:$o,reason:$w}')"

case "$METHOD" in
  terminal-notifier)
    "$TN" -title "$TITLE" -message "$MSG" -group "ching-$NAME" -activate "$ACTIVATE" >/dev/null 2>&1 || true ;;
  osascript)
    # Title and message go in as argv so they are never parsed as AppleScript source.
    "$OSA" -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' -e 'end run' -- "$TITLE" "$MSG" >/dev/null 2>&1 || true ;;
esac
exit 0
```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Existing t_stop/t_post_release assertions on "…: Done" still pass, because inbox lines are still logged with their title.

- [ ] **Step 5: Commit**

```bash
git add bin/notify.sh tests/t_notify.sh
git commit -m "notify: route done to the inbox; budget non-urgent alerts (4/day, 09-21, 45 min)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 5: `ching-watch.sh` (stall, context, tokens, rotation, lock)

**Files:**
- Create: `bin/ching-watch.sh`, `tests/t_watch.sh`

**Interfaces:**
- Consumes: `ev`, `meta_get`, `meta_set`, `file_mtime` (lib.sh); `notify.sh` kinds `stall`, `handoff`, `tokens` (Task 4); meta keys `state`, `cwd`, `name`, `transcript` (session-start.sh).
- Produces, for Task 7:
  - meta keys `ctx_level` (`healthy|watch|handoff`), `ctx_pct`, `stalled_at` (epoch or empty), `tok_offset` and `tok_last_mid`;
  - the file `$AGENT_HOME/tokens/<UTC YYYY-MM-DD>` with lines `<sid> <tokens>`;
  - flag files `$AGENT_HOME/tokens/<day>.alert80` and `.alert100`;
  - events `stall`, `context` and `tokens`.

- [ ] **Step 1: Write the failing test** `tests/t_watch.sh`

```bash
#!/usr/bin/env bash
# ching-watch.sh: tokens (dedupe, incremental, today only), context levels, stall, budget alerts,
# rotation, lock, shrinking transcripts.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
W="$BIN/ching-watch.sh"
DAY=$(date -u +%Y-%m-%d)
NOW=$(date +%s)
P="$WORK/proj"; mkdir -p "$P"
EVF="$AGENT_HOME/events.jsonl"
TOK="$AGENT_HOME/tokens/$DAY"
reg() { # sid state transcript
  local d="$AGENT_HOME/sessions/$1"; mkdir -p "$d"
  printf 'cwd=%s\nname=proj\nstate=%s\ntranscript=%s\nupdated=%s\n' "$P" "$2" "$3" "$NOW" >"$d/meta"
}
mget() { meta_get "$AGENT_HOME/sessions/$1/meta" "$2"; }
amsg() { # id input cache_read cache_create output [day]
  jq -nc --arg id "$1" --arg ts "${6:-$DAY}T10:00:00.000Z" --argjson i "$2" --argjson r "$3" --argjson c "$4" --argjson o "$5" \
    '{type:"assistant",timestamp:$ts,message:{id:$id,model:"claude-opus-5-5",usage:{input_tokens:$i,cache_read_input_tokens:$r,cache_creation_input_tokens:$c,output_tokens:$o}}}'
}
tok_of() { awk -v s="$1" '$1 == s { print $2 }' "$TOK" 2>/dev/null; }

# tokens: duplicate lines per message id count once; malformed lines skipped; context from the last message
T1="$WORK/t1.jsonl"
{ echo '{"type":"user","message":{"content":"hi"}}'; amsg m1 2 100000 10 50; amsg m1 2 100000 10 50; echo 'not json'; amsg m2 1 110000 5 20; } >"$T1"
reg s1 idle "$T1"
assert_ok "watch run exits 0" "$W"
assert_eq "tokens: (50+2+10)+(20+1+5) with duplicate m1 counted once" "88" "$(tok_of s1)"
assert_eq "context: 110006 of 200k is healthy" "healthy" "$(mget s1 ctx_level)"
assert_eq "context: pct stored" "55" "$(mget s1 ctx_pct)"
amsg m3 0 130000 0 10 >>"$T1"
"$W"
assert_eq "incremental: only the new message is added" "98" "$(tok_of s1)"
assert_eq "context: 65% is watch" "watch" "$(mget s1 ctx_level)"
assert_contains "events: context change logged" "$(jq -r 'select(.kind=="context") | .data.level' "$EVF")" "watch"
"$W"
assert_eq "re-run without new lines adds nothing" "98" "$(tok_of s1)"
amsg m3 0 130000 0 10 >>"$T1"
"$W"
assert_eq "a duplicate of the last message across runs is not counted" "98" "$(tok_of s1)"
amsg m4 0 170000 0 0 >>"$T1"
"$W"
assert_eq "context: 85% is handoff" "handoff" "$(mget s1 ctx_level)"
assert_contains "handoff notifies (budgeted kind)" "$(cat "$AGENT_HOME/notify.log")" "Context almost full"

# a context above 200k means a 1M window
T2="$WORK/t2.jsonl"; amsg n1 0 500000 0 1 >"$T2"; reg s2 idle "$T2"; "$W"
assert_eq "1M window detected: 500k is healthy" "healthy" "$(mget s2 ctx_level)"

# messages from another day are not counted today
T3="$WORK/t3.jsonl"; amsg o1 0 1000 0 999 2020-01-01 >"$T3"; reg s3 idle "$T3"; "$W"
assert_eq "old-day tokens are not counted" "" "$(tok_of s3)"

# a partial last line waits for the next run
T4="$WORK/t4.jsonl"; { amsg p1 0 1000 0 5; printf '{"type":"assist'; } >"$T4"; reg s4 idle "$T4"; "$W"
full=$(amsg p1 0 1000 0 5 | wc -c | tr -d ' ')
assert_eq "offset stops at the last newline" "$full" "$(mget s4 tok_offset)"

# Review Focus 4: a transcript that shrinks resets the offset
amsg r1 0 1 0 7 >"$T4"; "$W"   # shorter than the old content, so the file shrank
assert_eq "shrunk transcript: offset reset and re-read" "$(wc -c <"$T4" | tr -d ' ')" "$(mget s4 tok_offset)"
assert_eq "shrunk transcript: new message counted" "12" "$(tok_of s4)"

# stall: working session with a transcript untouched for 20+ minutes, reported once, cleared on progress
T5="$WORK/t5.jsonl"; amsg w1 0 1000 0 1 >"$T5"; touch -t 202001010000 "$T5"; reg s5 working "$T5"
"$W"
assert_contains "stall: stalled_at set" "$(cat "$AGENT_HOME/sessions/s5/meta")" "stalled_at=1"
assert_contains "stall: notification" "$(cat "$AGENT_HOME/notify.log")" "proj: Stalled"
"$W"
assert_eq "stall: reported once" "1" "$(jq -r 'select(.kind=="stall" and .sid=="s5") | .kind' "$EVF" | wc -l | tr -d ' ')"
touch "$T5"; "$W"
assert_eq "stall: cleared after progress" "" "$(mget s5 stalled_at)"
T6="$WORK/t6.jsonl"; amsg e1 0 1 0 1 >"$T6"; touch -t 202001010000 "$T6"; reg s6 ended "$T6"; "$W"
assert_eq "ended sessions are skipped" "" "$(mget s6 stalled_at)"
reg s8 working "$WORK/missing.jsonl"
assert_ok "missing transcript does not break the run" "$W"

# daily token budget: one alert at 80% and one at 100%, never repeated
TOKEN_BUDGET_DAILY=50 "$W"; TOKEN_BUDGET_DAILY=50 "$W"
assert_file "budget: 80% flag" "$TOK.alert80"
assert_file "budget: 100% flag" "$TOK.alert100"
assert_eq "budget: two token events, not repeated" "2" "$(jq -r 'select(.kind=="tokens") | .kind' "$EVF" | wc -l | tr -d ' ')"

# lock: a fresh lock means another run is busy; a lock older than 10 minutes is stale
T7="$WORK/t7.jsonl"; amsg l1 0 1 0 1 >"$T7"; touch -t 202001010000 "$T7"; reg s7 working "$T7"
mkdir "$AGENT_HOME/watch.lock"; "$W"
assert_eq "fresh lock: run skipped" "" "$(mget s7 stalled_at)"
touch -t 202001010000 "$AGENT_HOME/watch.lock"; "$W"
assert_contains "stale lock: run proceeds" "$(cat "$AGENT_HOME/sessions/s7/meta")" "stalled_at=1"
assert_no_file "lock removed after the run" "$AGENT_HOME/watch.lock"

# rotation
WATCH_ROTATE_BYTES=10 "$W"
assert_no_file "events.jsonl rotated away" "$EVF"
assert_eq "one rotated file kept" "1" "$(ls "$AGENT_HOME"/events-*.jsonl | wc -l | tr -d ' ')"
exit 0
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_watch|TOTAL'`
Expected: failures (`ching-watch.sh: No such file`).

- [ ] **Step 3: Implement** `bin/ching-watch.sh` (then `chmod +x bin/ching-watch.sh`)

```bash
#!/usr/bin/env bash
# ching-watch.sh - one-shot watcher, run every 5 minutes by launchd (org.ching.watch). Not a daemon.
# For every live session in $AGENT_HOME/sessions: stall detection, context pressure and today's token
# total, read incrementally from the transcript (byte offset in meta). Then token-budget alerts and
# events.jsonl rotation. It never touches a session: it writes meta keys, $AGENT_HOME/tokens/<UTC day>,
# events and notifications only.
# Meta keys written: tok_offset tok_last_mid ctx_level ctx_pct stalled_at
# Env: AGENT_HOME WATCH_NOW (epoch, tests) WATCH_STALL_MINS (20) WATCH_ROTATE_BYTES (20971520)
#      TOKEN_BUDGET_DAILY (unset = no token alerts; also read from $AGENT_HOME/defaults/ching.env)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

NOW=${WATCH_NOW:-$(date +%s)}
STALL_SECS=$(( ${WATCH_STALL_MINS:-20} * 60 ))
if [ -z "${TOKEN_BUDGET_DAILY:-}" ] && [ -f "$AGENT_HOME/defaults/ching.env" ]; then
  TOKEN_BUDGET_DAILY=$(sed -n 's/^TOKEN_BUDGET_DAILY=//p' "$AGENT_HOME/defaults/ching.env" | head -1)
fi
case "${TOKEN_BUDGET_DAILY:-}" in *[!0-9]*) TOKEN_BUDGET_DAILY="" ;; esac
DAY=$(date -u -r "$NOW" +%Y-%m-%d)
mkdir -p "$AGENT_HOME/tokens"

LOCK="$AGENT_HOME/watch.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ $(( $(date +%s) - $(file_mtime "$LOCK") )) -lt 600 ]; then exit 0; fi
  rm -rf "$LOCK"; mkdir "$LOCK"
fi
TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-watch.XXXXXX")
trap 'rm -rf "$LOCK" "$TMP"' EXIT

wnotify() { NOTIFY_CWD="$CWD" NOTIFY_SESSION="$SID" NOTIFY_NOW="$NOW" "$SELF_DIR/notify.sh" "$1" "$2" </dev/null >/dev/null 2>&1 || true; }

tok_add() { # sid n -> add n to today's total for sid
  local f="$AGENT_HOME/tokens/$DAY" cur
  cur=$(awk -v s="$1" '$1 == s { print $2; exit }' "$f" 2>/dev/null || true); [ -n "$cur" ] || cur=0
  { if [ -f "$f" ]; then awk -v s="$1" '$1 != s' "$f"; fi; printf '%s %s\n' "$1" $((cur + $2)); } >"$f.tmp"
  mv "$f.tmp" "$f"
}

for m in "$AGENT_HOME"/sessions/*/meta; do
  [ -f "$m" ] || continue
  SESS_DIR=$(dirname "$m"); SID=$(basename "$SESS_DIR")
  state=$(meta_get "$m" state)
  [ "$state" != ended ] || continue
  CWD=$(meta_get "$m" cwd); NAME=$(meta_get "$m" name)
  tr=$(meta_get "$m" transcript)
  if [ -z "$tr" ] || [ ! -f "$tr" ]; then continue; fi
  tm=$(file_mtime "$tr")

  # 1. stall: working, transcript silent for STALL_SECS; reported once, cleared by any new write
  stalled=$(meta_get "$m" stalled_at)
  if [ -n "$stalled" ] && [ "$tm" -ge "$stalled" ]; then meta_set stalled_at ""; stalled=""; fi
  if [ "$state" = working ] && [ -z "$stalled" ] && [ $((NOW - tm)) -ge "$STALL_SECS" ]; then
    meta_set stalled_at "$NOW"
    mins=$(( (NOW - tm) / 60 ))
    ev stall "$(jq -nc --argjson m "$mins" '{idle_mins:$m}')"
    wnotify stall "No progress for $mins minutes."
  fi

  # 2. incremental read of complete new lines
  size=$(wc -c <"$tr" | tr -d ' ')
  off=$(meta_get "$m" tok_offset); case "$off" in ''|*[!0-9]*) off=0 ;; esac
  [ "$off" -le "$size" ] || off=0
  [ "$off" -lt "$size" ] || continue
  tail -c +$((off + 1)) "$tr" >"$TMP/chunk"
  cut=$(perl -0777 -ne 'print rindex($_, "\n") + 1' "$TMP/chunk")
  [ "$cut" -gt 0 ] || continue
  head -c "$cut" "$TMP/chunk" >"$TMP/lines"
  meta_set tok_offset $((off + cut))
  jq -cR --arg day "$DAY" 'fromjson? | select(.type == "assistant" and ((.message.usage // null) | type) == "object")
      | {id: (.message.id // ""), today: ((.timestamp // "") | startswith($day)), u: .message.usage}' \
      "$TMP/lines" >"$TMP/usage" 2>/dev/null || true
  [ -s "$TMP/usage" ] || continue
  last_mid=$(meta_get "$m" tok_last_mid)
  read -r add ctx mid < <(jq -rs --arg last "$last_mid" '
      (reduce .[] as $r ({seen: {($last): true}, add: 0};
         if .seen[$r.id] then . else (.seen[$r.id] = true)
           | .add += (if $r.today then ($r.u.output_tokens // 0) + ($r.u.input_tokens // 0) + ($r.u.cache_creation_input_tokens // 0) else 0 end) end)) as $acc
      | (last.u | (.input_tokens // 0) + (.cache_read_input_tokens // 0) + (.cache_creation_input_tokens // 0)) as $ctx
      | "\($acc.add) \($ctx) \(last.id)"' "$TMP/usage") || continue
  case "$add$ctx" in *[!0-9]*) continue ;; esac
  meta_set tok_last_mid "$mid"
  [ "$add" -eq 0 ] || tok_add "$SID" "$add"

  # 3. context pressure: window is 200k unless the context already exceeds it (then 1M)
  win=200000; [ "$ctx" -le 200000 ] || win=1000000
  pct=$(( ctx * 100 / win ))
  if [ "$pct" -ge 80 ]; then lvl=handoff; elif [ "$pct" -ge 60 ]; then lvl=watch; else lvl=healthy; fi
  meta_set ctx_pct "$pct"
  if [ "$lvl" != "$(meta_get "$m" ctx_level)" ]; then
    meta_set ctx_level "$lvl"
    ev context "$(jq -nc --arg l "$lvl" --argjson p "$pct" '{level:$l,pct:$p}')"
    [ "$lvl" != handoff ] || wnotify handoff "Context ${pct}% full: run /handoff and continue in a fresh session."
  fi
done

# 4. daily token budget (machine-wide), one alert per mark per day
if [ -n "${TOKEN_BUDGET_DAILY:-}" ] && [ -f "$AGENT_HOME/tokens/$DAY" ]; then
  total=$(awk '{ s += $2 } END { print s + 0 }' "$AGENT_HOME/tokens/$DAY")
  for mark in 80 100; do
    flag="$AGENT_HOME/tokens/$DAY.alert$mark"
    if [ $((total * 100)) -ge $((TOKEN_BUDGET_DAILY * mark)) ] && [ ! -f "$flag" ]; then
      : >"$flag"
      SID=machine; NAME=machine; CWD=$HOME
      ev tokens "$(jq -nc --argjson t "$total" --argjson b "$TOKEN_BUDGET_DAILY" --argjson c "$mark" '{day_total:$t,budget:$b,crossed:$c}')"
      wnotify tokens "Token use today is at ${mark}% of the budget ($total of $TOKEN_BUDGET_DAILY)."
    fi
  done
fi

# 5. rotation
EVF="$AGENT_HOME/events.jsonl"
if [ -f "$EVF" ] && [ "$(wc -c <"$EVF" | tr -d ' ')" -gt "${WATCH_ROTATE_BYTES:-20971520}" ]; then
  mv "$EVF" "$AGENT_HOME/events-$(date -u -r "$NOW" +%Y%m%d-%H%M%S).jsonl"
fi
exit 0
```

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Includes `t_lint` (shellcheck and strict mode on the new script).

- [ ] **Step 5: Commit**

```bash
git add bin/ching-watch.sh tests/t_watch.sh
git commit -m "ching-watch: one-shot stall, context and token watcher with rotation and lock

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 6: `install.sh`: launchd watcher, wider guard matcher, matcher upgrade

**Files:**
- Modify: `install.sh`, `tests/lib.sh`
- Test: `tests/t_install.sh`

**Interfaces:**
- Consumes: the `bin/ching-watch.sh` path (Task 5); the file doesn't need to exist for these tests.
- Produces: `~/Library/LaunchAgents/org.ching.watch.plist`; env overrides `LAUNCHCTL` and `LAUNCH_AGENTS_DIR`; the `GUARD_MATCHER` now includes messaging MCP tools (used by Task 9's rule 10 in real sessions).

- [ ] **Step 1: Make tests unable to reach the real launchd.** In `tests/lib.sh`, directly after `mkdir -p "$AGENT_HOME" "$CLAUDE_DIR"`, add:

```bash
# install.sh calls $LAUNCHCTL: a test must never reach the real launchd
cat >"$WORK/fake-launchctl" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$(dirname "$0")/launchctl.log"
EOS
chmod +x "$WORK/fake-launchctl"
export LAUNCHCTL="$WORK/fake-launchctl"
```

- [ ] **Step 2: Write the failing tests** in `tests/t_install.sh`. Insert directly after the assertion line containing `dry-run after install: nothing to do`:

```bash
# ---------- launchd watcher (Phase 1.5) ----------
LA="$HOME/Library/LaunchAgents/org.ching.watch.plist"
assert_file "watcher plist installed" "$LA"
assert_contains "plist runs every 300 s" "$(cat "$LA")" "<integer>300</integer>"
assert_contains "plist points at the kit symlink" "$(cat "$LA")" "/ching/bin/ching-watch.sh"
assert_ok "plist is valid XML plist" plutil -lint "$LA"
assert_contains "launchctl bootstrap called" "$(cat "$WORK/launchctl.log")" "bootstrap gui/"
n=$(wc -l <"$WORK/launchctl.log")
inst --yes >/dev/null
assert_eq "re-run with identical plist: launchctl not called again" "$n" "$(wc -l <"$WORK/launchctl.log")"
assert_contains "guard matcher covers messaging MCP tools" "$(jq -r '.hooks.PreToolUse[].matcher' "$SETTINGS_FILE")" "[Gg]mail"
jq '(.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh")) | .matcher) = "Bash"' "$SETTINGS_FILE" >"$SETTINGS_FILE.t" && mv "$SETTINGS_FILE.t" "$SETTINGS_FILE"
inst --yes >/dev/null
assert_contains "re-install widens an old guard matcher" "$(jq -r '.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh")) | .matcher' "$SETTINGS_FILE")" "[Ss]lack"
assert_eq "re-install keeps a single guard entry" "1" "$(jq '[.hooks.PreToolUse[] | select(.hooks[0].command | contains("/ching/bin/guard.sh"))] | length' "$SETTINGS_FILE")"
```

Insert directly after the assertion line containing `uninstall: empty events removed`:

```bash
assert_no_file "uninstall removes the watcher plist" "$HOME/Library/LaunchAgents/org.ching.watch.plist"
assert_contains "uninstall boots the watcher out (last launchctl call)" "$(tail -1 "$WORK/launchctl.log")" "bootout gui/"
```

- [ ] **Step 3: Run and confirm they fail**

Run: `tests/run.sh 2>&1 | grep -E 't_install|TOTAL'`
Expected: FAIL "watcher plist installed".

- [ ] **Step 4: Implement** in `install.sh`

1. Replace the `GUARD_MATCHER=` line with:
   ```bash
   GUARD_MATCHER='Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*|mcp__.*([Gg]mail|[Ss]lack|[Dd]iscord|[Tt]elegram).*'
   ```
2. In the install jq program (the `NEW=$(… jq … --argjson add "$HOOKS_JSON" …)` branch), replace
   ```jq
          | if has_cmd($g; $h.command) then $g
   ```
   with
   ```jq
          | if has_cmd($g; $h.command)
            then $g | map(if ([.hooks[]?.command] | index($h.command)) != null then .matcher = $h.matcher else . end)
   ```
3. After the `NEED_REPOS=…` lines (before the `if [ "$CHANGED" -eq 0 ] && [ -z "$link_plan" ] …` "nothing to do" check), add:

```bash
# ---------------- launchd watcher (ching-watch.sh every 5 minutes) ----------------
LAUNCH_AGENTS_DIR=${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LAUNCHCTL=${LAUNCHCTL:-launchctl}
PLIST="$LAUNCH_AGENTS_DIR/org.ching.watch.plist"
AH=${AGENT_HOME:-$HOME/.agent}
PLIST_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.ching.watch</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$LINK/bin/ching-watch.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>AGENT_HOME</key><string>$AH</string>
  </dict>
  <key>StandardOutPath</key><string>$AH/watch.log</string>
  <key>StandardErrorPath</key><string>$AH/watch.log</string>
</dict>
</plist>
EOP
)
NEED_PLIST=0
if [ "$UNINSTALL" -eq 0 ]; then
  if [ ! -f "$PLIST" ] || [ "$(cat "$PLIST")" != "$PLIST_BODY" ]; then NEED_PLIST=1; fi
elif [ -f "$PLIST" ]; then
  NEED_PLIST=1
fi
```

4. Change the "nothing to do" condition to also require `[ "$NEED_PLIST" -eq 0 ]`:
   ```bash
   if [ "$CHANGED" -eq 0 ] && [ -z "$link_plan" ] && [ "$NEED_REPOS" -eq 0 ] && [ "$NEED_PLIST" -eq 0 ]; then
   ```
5. Inside the dry-run block, before its `exit 0`, add:
   ```bash
   [ "$NEED_PLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then act "launchctl bootout and remove $PLIST"; else act "write $PLIST and launchctl bootstrap it"; fi; }
   ```
6. Directly before the final `if [ "$UNINSTALL" -eq 1 ]; then say "note: …` line, add:
   ```bash
   if [ "$NEED_PLIST" -eq 1 ]; then
     if [ "$UNINSTALL" -eq 1 ]; then
       "$LAUNCHCTL" bootout "gui/$(id -u)/org.ching.watch" >/dev/null 2>&1 || true
       rm -f "$PLIST"; act "removed $PLIST"
     else
       mkdir -p "$LAUNCH_AGENTS_DIR" "$AH"
       printf '%s\n' "$PLIST_BODY" >"$PLIST.tmp" && mv "$PLIST.tmp" "$PLIST"
       "$LAUNCHCTL" bootout "gui/$(id -u)/org.ching.watch" >/dev/null 2>&1 || true
       "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"; act "loaded $PLIST (ching-watch every 5 minutes)"
     fi
   fi
   ```
   The comparison `"$(cat "$PLIST")" != "$PLIST_BODY"` works because `$(…)` strips the trailing newline on both sides.
7. Change that final note to: `note: --uninstall removes hook entries and the watcher; symlinks and a removed popup are left as they are.`
8. Add to the header comment, under "What it changes:":
   `#   $LAUNCH_AGENTS_DIR/org.ching.watch.plist (default ~/Library/LaunchAgents): runs bin/ching-watch.sh every 300 s.`
   and add `LAUNCHCTL, LAUNCH_AGENTS_DIR` to the "Overrides (for tests)" line.

- [ ] **Step 5: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 6: Commit**

```bash
git add install.sh tests/lib.sh tests/t_install.sh
git commit -m "install: launchd watcher plist, messaging MCP in the guard matcher, matcher upgrades

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 7: `dash.sh`: ctx/tok columns, checkpoint notes, `--inbox`, `--next`, spoken lead; dispatcher policy

**Files:**
- Modify: `bin/dash.sh` (full replacement below), `dispatcher/AGENTS.md`
- Test: `tests/t_dash.sh`

**Interfaces:**
- Consumes: `checkpoint_get` (Task 1); meta `ctx_level` and `stalled_at` plus the tokens file (Task 5); `<repo>/.agent/release-ready` (existing release-gate confirm mode).
- Produces: the `dash.sh --inbox` lanes `NEEDS YOU`, `READY` and `FINISHED (since last look)`; the `dash.sh --next` ranked list; the state file `$AGENT_HOME/inbox.seen`.

- [ ] **Step 1: Write the failing tests.** Append before the final `exit 0` of `tests/t_dash.sh`:

```bash
# ---------- Phase 1.5: columns, checkpoint, inbox, next ----------
DAY=$(date -u +%Y-%m-%d)
printf 'ctx_level=handoff\n' >>"$AGENT_HOME/sessions/sidA/meta"
mkdir -p "$AGENT_HOME/tokens"; printf 'sidA 1234567\n' >"$AGENT_HOME/tokens/$DAY"
out=$("$BIN/dash.sh")
assert_contains "ctx column: handoff shows ○" "$(printf '%s\n' "$out" | grep 'repoA \[main\] sidA')" "○"
assert_contains "tok column: 1.2M" "$(printf '%s\n' "$out" | grep 'repoA \[main\] sidA')" "1.2M"
printf '# State\nstatus: blocked\n<!-- ching:checkpoint -->\nblocker: need the Supabase token\nnext_action: rerun the gate\n<!-- /ching:checkpoint -->\n\n## Blocked\n- old bullet\n' >"$AGENT_HOME/sessions/sidB/STATE.md"
reg sidB "$B" blocked
assert_contains "checkpoint blocker wins over the Blocked list" "$(printf '%s\n' "$("$BIN/dash.sh")" | grep repoB)" "need the Supabase token"
# Review Focus 1: "blocker: none" with a stale bullet is not blocked
mkdir -p "$AGENT_HOME/sessions/sidH"
printf '# State\nstatus: working\n<!-- ching:checkpoint -->\nblocker: none\n<!-- /ching:checkpoint -->\n\n## Blocked\n- stale bullet from yesterday\n' >"$AGENT_HOME/sessions/sidH/STATE.md"
assert_not_contains "blocker: none is not blocked" "$(printf '%s\n' "$("$BIN/dash.sh")" | grep '^~ ')" "blocked"
reg sidP "$PLAIN" done
mkdir -p "$C/.agent"; printf 'kind=release-ready\n' >"$C/.agent/release-ready"
ib=$("$BIN/dash.sh" --inbox)
assert_contains "inbox: needs-you lane" "$ib" "repoB [main]: blocked -- need the Supabase token"
assert_contains "inbox: ready lane from a release-ready marker" "$(printf '%s\n' "$ib" | sed -n '/^READY/,/^FINISHED/p')" "repoC"
assert_contains "inbox: finished lane" "$(printf '%s\n' "$ib" | sed -n '/^FINISHED/,$p')" "plainf"
ib2=$("$BIN/dash.sh" --inbox)
assert_not_contains "inbox: finished clears after a look" "$(printf '%s\n' "$ib2" | sed -n '/^FINISHED/,$p')" "plainf"
nx=$("$BIN/dash.sh" --next)
assert_contains "next: blocked session ranks first" "$(printf '%s\n' "$nx" | head -1)" "repoB"
assert_contains "next: shows the checkpoint next action" "$nx" "rerun the gate"
assert_eq "next: at most 5 lines" "yes" "$([ "$(printf '%s\n' "$nx" | wc -l | tr -d ' ')" -le 5 ] && echo yes || echo no)"
assert_contains "speak: leads with how many need you" "$("$BIN/dash.sh" --speak)" "needs you."
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_dash|TOTAL'`
Expected: FAIL "ctx column: handoff shows ○".

- [ ] **Step 3: Implement.** Replace `bin/dash.sh` entirely with:

```bash
#!/usr/bin/env bash
# dash.sh [--speak | --inbox | --next] [--hours N] [--all]
# Machine-wide view: one line per Claude session on this computer.
# Sources: (1) ~/.agent/sessions/*/meta written by the hooks and ching-watch.sh, (2) transcripts in
# ~/.claude/projects/*/*.jsonl modified recently (sessions that predate the hooks), (3) worktrees
# (`git worktree list`) of every repo found, shown when they hold repo state but have no live session,
# plus the optional extra list in ~/.agent-repos.
#   (default)  name, state, age, ctx (● healthy ◐ watch ○ handoff ? unknown), tokens today, folder, note
#   --speak    short spoken summary that leads with how many need you; warns above 5 active sessions
#   --inbox    NEEDS YOU (blocked/input), READY (release gate passed, waiting for --approve),
#              FINISHED (done since the last --inbox)
#   --next     top 5 by urgency x importance x recency, each with its checkpoint next_action
# Notes come from the STATE.md checkpoint `blocker:` (unless none), else the first "## Blocked" bullet.
# Env: AGENT_HOME CLAUDE_DIR AGENT_REPOS_FILE DASH_NOW (epoch, tests) DASH_ACTIVE_MINS (30)
set -euo pipefail
SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SELF_DIR/lib.sh"

MODE=table; HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --speak) MODE=speak; shift ;;
    --inbox) MODE=inbox; shift ;;
    --next) MODE=next; shift ;;
    --hours) HOURS=${2:?}; shift 2 ;;
    --all) HOURS=720; shift ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "dash: unknown argument $1" >&2; exit 64 ;;
  esac
done

NOW=${DASH_NOW:-$(date +%s)}
CUTOFF=$((NOW - HOURS * 3600))
ACTIVE_SECS=$(( ${DASH_ACTIVE_MINS:-30} * 60 ))
REPOS_FILE=${AGENT_REPOS_FILE:-$HOME/.agent-repos}
TOKDAY="$AGENT_HOME/tokens/$(date -u -r "$NOW" +%Y-%m-%d)"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/ching-dash.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
ROWS="$TMP/rows"; : >"$ROWS"
# fields (0x1f separated): updated sid cwd name branch state note src ctx tok stalled imp next_action
row() { local IFS=$'\037'; printf '%s\n' "$*" >>"$ROWS"; }

human_age() { # seconds
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 90 ]; then echo "${s}s"
  elif [ "$s" -lt 5400 ]; then echo "$(( (s + 30) / 60 ))m"
  elif [ "$s" -lt 129600 ]; then echo "$(( (s + 1800) / 3600 ))h"
  else echo "$(( (s + 43200) / 86400 ))d"; fi
}
spoken_age() {
  local s=$1
  [ "$s" -ge 0 ] || s=0
  if [ "$s" -lt 90 ]; then echo "just now"
  elif [ "$s" -lt 5400 ]; then echo "$(( (s + 30) / 60 )) minutes ago"
  else echo "$(( (s + 1800) / 3600 )) hours ago"; fi
}
display_name() { name_for "$1" "$2"; }
first_blocker() { # STATE.md -> first bullet under "## Blocked" that is not "(none)"
  [ -f "$1" ] || return 0
  awk '
    /^## Blocked/ { b = 1; next }
    /^## / { b = 0 }
    b && /^[[:space:]]*[-*][[:space:]]/ {
      l = $0; sub(/^[[:space:]]*[-*][[:space:]]+/, "", l)
      if (tolower(l) !~ /^\(?none\)?\.?$/ && l != "") { print l; exit }
    }' "$1"
}
state_note() { # STATE.md -> checkpoint blocker unless none; without a checkpoint block, the first bullet
  [ -f "$1" ] || return 0
  if grep -qF '<!-- ching:checkpoint -->' "$1"; then
    local b; b=$(checkpoint_get "$1" blocker)
    case "$(printf '%s' "$b" | tr '[:upper:]' '[:lower:]')" in ''|none|'(none)'|none.) return 0 ;; esac
    printf '%s\n' "$b"
  else
    first_blocker "$1"
  fi
}
importance() { if [ -n "$1" ] && [ -f "$1/.agent/GOAL.md" ]; then echo 3; else echo 1; fi; }
tok_for() { [ -f "$TOKDAY" ] || return 0; awk -v s="$1" '$1 == s { print $2; exit }' "$TOKDAY"; }
tok_h() { awk -v n="${1:-0}" 'BEGIN { if (n >= 1000000) printf "%.1fM", n / 1000000; else if (n >= 1000) printf "%dk", n / 1000; else if (n > 0) printf "%d", n; else printf "-" }'; }
ctx_sym() { case "$1" in healthy) printf '●' ;; watch) printf '◐' ;; handoff) printf '○' ;; *) printf '?' ;; esac; }

# ---- 1. registry ----
if [ -d "$AGENT_HOME/sessions" ]; then
  for m in "$AGENT_HOME"/sessions/*/meta; do
    [ -f "$m" ] || continue
    sid=$(basename "$(dirname "$m")")
    upd=$(meta_get "$m" updated); [ -n "$upd" ] || upd=$(file_mtime "$m")
    state=$(meta_get "$m" state); [ -n "$state" ] || state=unknown
    cwd=$(meta_get "$m" cwd); root=$(meta_get "$m" root)
    tr_path=$(meta_get "$m" transcript)
    if [ -n "$tr_path" ] && [ -f "$tr_path" ]; then
      tm=$(file_mtime "$tr_path"); [ "$tm" -le "$upd" ] || upd=$tm
    fi
    [ "$upd" -ge "$CUTOFF" ] || continue
    [ "$state" != ended ] || continue
    sdir="$AGENT_HOME/sessions/$sid"
    if [ -n "$root" ] && [ -f "$root/.agent/GOAL.md" ]; then sdir="$root/.agent"; fi
    note=$(state_note "$sdir/STATE.md")
    [ -z "$note" ] || [ "$state" = blocked ] || [ "$state" = input ] || state=blocked
    row "$upd" "$sid" "${cwd:-?}" "$(display_name "${cwd:-?}" "$root")" "$(meta_get "$m" branch)" "$state" "$note" registry \
      "$(meta_get "$m" ctx_level)" "$(tok_for "$sid")" "$(meta_get "$m" stalled_at)" "$(importance "$root")" \
      "$(checkpoint_get "$sdir/STATE.md" next_action)"
  done
fi

# ---- 2. transcripts (sessions not in the registry) ----
seen=$(cut -d$'\037' -f2 "$ROWS" | sort -u)
if [ -d "$CLAUDE_DIR/projects" ]; then
  for t in "$CLAUDE_DIR"/projects/*/*.jsonl; do
    [ -f "$t" ] || continue
    tm=$(file_mtime "$t")
    [ "$tm" -ge "$CUTOFF" ] || continue
    sid=$(basename "$t" .jsonl)
    if printf '%s\n' "$seen" | grep -qxF "$sid"; then continue; fi
    cwd=$(grep -m1 -o '"cwd": *"[^"]*"' "$t" 2>/dev/null | head -1 | sed 's/^"cwd": *"//; s/"$//' || true)
    [ -n "$cwd" ] || cwd="?"
    root=""; branch=""
    if [ -d "$cwd" ]; then
      root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true)
      branch=$(git -C "$cwd" symbolic-ref --short -q HEAD 2>/dev/null || true)
    fi
    state=idle
    [ $((NOW - tm)) -ge 120 ] || state=working
    row "$tm" "$sid" "$cwd" "$(display_name "$cwd" "$root")" "$branch" "$state" "" transcript "" "" "" "$(importance "$root")" ""
  done
fi

# ---- 3. worktrees of every repo found (+ ~/.agent-repos) with repo state but no live session ----
{
  cut -d$'\037' -f3 "$ROWS" | while IFS= read -r c; do [ -d "$c" ] && git -C "$c" rev-parse --show-toplevel 2>/dev/null; done || true
  if [ -f "$REPOS_FILE" ]; then
    grep -v '^[[:space:]]*#' "$REPOS_FILE" | sed 's/[[:space:]]*$//' | while IFS= read -r p; do
      [ -n "$p" ] || continue
      # shellcheck disable=SC2088
      case "$p" in "~"|"~/"*) p="$HOME${p#"~"}" ;; esac
      [ -d "$p" ] && git -C "$p" rev-parse --show-toplevel 2>/dev/null
    done || true
  fi
} | sort -u >"$TMP/repos"
while IFS= read -r repo; do
  [ -n "$repo" ] || continue
  git -C "$repo" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r wt; do
    [ -f "$wt/.agent/STATE.md" ] || continue
    wt_phys=$(cd "$wt" && pwd -P)
    if cut -d$'\037' -f3 "$ROWS" | grep -qxF "$wt_phys"; then continue; fi
    upd=$(file_mtime "$wt/.agent/STATE.md")
    [ "$upd" -ge "$CUTOFF" ] || continue
    st=$(sed -n 's/^status:[[:space:]]*//p' "$wt/.agent/STATE.md" | head -1)
    [ -n "$st" ] || st=idle
    note=$(state_note "$wt/.agent/STATE.md")
    [ -z "$note" ] || st=blocked
    row "$upd" "worktree" "$wt_phys" "$(basename "$wt")" "$(git -C "$wt" symbolic-ref --short -q HEAD 2>/dev/null || true)" \
      "$st" "$note" worktree "" "" "" "$(importance "$wt_phys")" "$(checkpoint_get "$wt/.agent/STATE.md" next_action)"
  done
done <"$TMP/repos"

sort -rn -t $'\037' -k1,1 "$ROWS" >"$TMP/sorted"

active=0; blocked=0; waiting=0; done_n=0; total=0
while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
  total=$((total + 1))
  age=$((NOW - upd))
  case "$state" in
    blocked) blocked=$((blocked + 1)) ;;
    input) waiting=$((waiting + 1)) ;;
    done) done_n=$((done_n + 1)) ;;
  esac
  case "$state" in
    working|blocked|input|unknown) [ "$age" -le "$ACTIVE_SECS" ] && active=$((active + 1)) || true ;;
  esac
done <"$TMP/sorted"

label_of() { if [ -n "$2" ]; then printf '%s [%s]' "$1" "$2"; else printf '%s' "$1"; fi; }

case "$MODE" in
  table)
    if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; exit 0; fi
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      label=$(label_of "$name" "$branch")
      [ "$src" = worktree ] || label="$label ${sid:0:7}"
      printf '%-34s %-8s %5s %s %6s  %s%s\n' "$label" "$state" "$(human_age $((NOW - upd)))" "$(ctx_sym "$ctx")" "$(tok_h "$tok")" \
        "$cwd" "${note:+  -- $note}"
    done <"$TMP/sorted"
    echo "-- $total session(s), $active active"
    if [ "$active" -gt 5 ]; then echo "WARNING: $active active sessions; the plan caps this at about 5. Park some behind their STATE.md."; fi
    exit 0 ;;

  inbox)
    SEEN_F="$AGENT_HOME/inbox.seen"
    last_seen=$(cat "$SEEN_F" 2>/dev/null || echo 0); case "$last_seen" in ''|*[!0-9]*) last_seen=0 ;; esac
    : >"$TMP/needs"; : >"$TMP/ready"; : >"$TMP/fin"
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      label=$(label_of "$name" "$branch")
      case "$state" in
        blocked) printf '  %s: blocked%s\n' "$label" "${note:+ -- $note}" >>"$TMP/needs" ;;
        input) printf '  %s: needs your input\n' "$label" >>"$TMP/needs" ;;
        done) [ "$upd" -le "$last_seen" ] || printf '  %s%s\n' "$label" "${nexta:+ -- next: $nexta}" >>"$TMP/fin" ;;
      esac
      r=""; if [ -d "$cwd" ]; then r=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || true); fi
      if [ -n "$r" ] && [ -f "$r/.agent/release-ready" ]; then
        printf '  %s: release gate passed; run release-gate.sh --approve in %s\n' "$(basename "$r")" "$r" >>"$TMP/ready"
      fi
    done <"$TMP/sorted"
    lane() { echo "$1"; if [ -s "$2" ]; then sort -u "$2"; else echo "  (nothing)"; fi; }
    lane "NEEDS YOU" "$TMP/needs"
    lane "READY" "$TMP/ready"
    lane "FINISHED (since last look)" "$TMP/fin"
    printf '%s\n' "$NOW" >"$SEEN_F"
    exit 0 ;;

  next)
    if [ "$total" -eq 0 ]; then echo "no Claude sessions seen in the last ${HOURS}h"; exit 0; fi
    while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
      case "$state" in
        blocked) u=10 ;;
        input) u=9 ;;
        *) if [ -n "$stalled" ]; then u=8; elif [ "$ctx" = handoff ]; then u=7; elif [ "$state" = working ]; then u=4; else u=2; fi ;;
      esac
      printf '%s\037%s\037%s\037%s\037%s\n' "$u" "${imp:-1}" $((NOW - upd)) "$(label_of "$name" "$branch") ($state)" "${nexta:-$note}"
    done <"$TMP/sorted" \
      | awk -F'\037' '{ r = 1 - ($3 / 3600) / 24; if (r < 0.2) r = 0.2; printf "%.2f\037%s\037%s\n", $1 * $2 * r, $4, $5 }' \
      | sort -t $'\037' -k1,1 -rn | head -5 \
      | awk -F'\037' '{ printf "%d. %s  [score %s]%s\n", NR, $2, $1, ($3 != "" ? "  -- " $3 : "") }'
    exit 0 ;;
esac

# ---- spoken summary: short sentences, no paths, no ids ----
if [ "$total" -eq 0 ]; then echo "No Claude sessions in the last $HOURS hours."; exit 0; fi
need=$((blocked + waiting)); out=""
if [ "$need" -eq 1 ]; then out="1 needs you. "; elif [ "$need" -gt 1 ]; then out="$need need you. "; fi
out="$out$active active session"; [ "$active" -eq 1 ] || out="${out}s"; out="$out out of $total."
n=0
while IFS=$'\037' read -r upd sid cwd name branch state note src ctx tok stalled imp nexta; do
  case "$state" in
    blocked) s="$name is blocked${note:+: $note}." ;;
    input) s="$name needs your input." ;;
    *) continue ;;
  esac
  n=$((n + 1)); [ "$n" -le 3 ] || continue
  out="$out $s"
done <"$TMP/sorted"
[ "$n" -le 3 ] || out="$out And $((n - 3)) more waiting."
if [ "$n" -eq 0 ]; then
  newest=$(head -1 "$TMP/sorted")
  nn=$(printf '%s' "$newest" | cut -d$'\037' -f4); nu=$(printf '%s' "$newest" | cut -d$'\037' -f1); ns=$(printf '%s' "$newest" | cut -d$'\037' -f6)
  out="$out Nothing is blocked. Latest: $nn is $ns, $(spoken_age $((NOW - nu)))."
fi
[ "$done_n" -eq 0 ] || out="$out $done_n finished."
if [ "$active" -gt 5 ]; then out="$out Warning: that is more than five active sessions; consider parking some."; fi
echo "$out"
```

`dispatcher/AGENTS.md` changes:
- Replace the "What did X finish?" bullet with: `- "What finished?" / "What did X finish?": run dash.sh --inbox and read the FINISHED lane (for X, its STATE.md Done list, last two items). Never announce finished sessions unprompted; only NEEDS YOU items are worth interrupting for.`
- After it, add: `- "What should I do next?": run dash.sh --next and read the first two lines without the scores.`

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. The existing t_dash assertions still hold: "5 active sessions out of 8." is now preceded by "1 needs you. ".

- [ ] **Step 5: Commit**

```bash
git add bin/dash.sh dispatcher/AGENTS.md tests/t_dash.sh
git commit -m "dash: ctx and token columns, checkpoint notes, --inbox, --next, spoken needs-you lead

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 8: Release gate: "not examined" in evidence, required review, templates and lenses

**Files:**
- Modify: `bin/release-gate.sh`, `templates/VERIFY.md`
- Create: `templates/REVIEW.md`, `templates/review-lenses/error-resilience.md`, `templates/review-lenses/identity.md`, `templates/review-lenses/simulation.md`
- Test: `tests/t_release.sh`

**Interfaces:**
- Consumes: `ev` (Task 1).
- Produces: the review file contract `<repo>/.agent/review/<full sha>.md`:
  - `commit:` equals HEAD;
  - `blocking: <n>`;
  - `[blocking]` bullets, each followed by a `resolved:` line;
  - `## not examined` with 10 or more non-space characters;
  - file mtime at or after the HEAD commit time.
- Produces: the GOAL.md key `review:`. Only exactly `off` disables review; empty or any other value means required.
- Produces: event `release{sha,outcome}` with outcome `gate-pass-auto`, `gate-pass-confirm` or `gate-fail`.

- [ ] **Step 1: Write the failing tests** in `tests/t_release.sh`

1. In `mk_evidence`, directly before the line `echo "## exercised"; …`, add:
   ```bash
       echo "## not examined"; printf '%s\n' "${EV_NOTEX-did not test the mobile layout}"
   ```
   and at the end of `mk_evidence` (after the closing `} >"$dir/$sha.md"`), add:
   ```bash
     if [ -z "${EV_NOREVIEW:-}" ]; then mk_review "$repo" "$sha" 0 ""; else rm -f "$repo/.agent/review/$sha.md"; fi
   ```
2. Above `mk_evidence`, add the helper:
   ```bash
   mk_review() { # repo commit blocking findings [not_examined]; the file is named after the repo's HEAD
     local d="$1/.agent/review"; mkdir -p "$d"
     { echo "commit: $2"; echo "reviewer: subagent"; echo "lenses: error-resilience, identity, simulation"; echo "blocking: $3"
       echo; echo "## findings"; if [ -n "$4" ]; then printf '%s\n' "$4"; fi
       echo; echo "## not examined"; printf '%s\n' "${5-did not load-test the endpoint}"; } >"$d/$(head_of "$1").md"
   }
   ```
3. Add `EV_NOTEX EV_NOREVIEW` to the `unset` list in `reset_ev`.
4. Append before the final `exit 0`:

```bash
# ---------- Phase 1.5: not examined + required review ----------
RV=$(mk_repo revrepo); write_goal "$RV" "true" auto
commit_file "$RV" a.txt one
reset_ev; EV_NOTEX="" mk_evidence "$RV"
assert_contains "evidence without not-examined is rejected" "$(gate "$RV")" "not examined"
reset_ev; EV_NOREVIEW=1 mk_evidence "$RV"
assert_contains "missing review is rejected with how-to" "$(gate "$RV")" "no review file"
reset_ev; mk_evidence "$RV"; sha=$(head_of "$RV")
mk_review "$RV" "$sha" 1 "- [blocking] a.txt:1 wrong value"
assert_contains "blocking finding without resolved: is rejected" "$(gate "$RV")" "without a resolved: line"
mk_review "$RV" "$sha" 1 "- [blocking] a.txt:1 wrong value"$'\n'"  resolved: kept on purpose, see STATE.md decision"
assert_contains "resolved blocking finding passes" "$(gate "$RV")" "PASS"
mk_review "$RV" "0000000000000000000000000000000000000000" 0 ""
assert_contains "review for another commit is rejected" "$(gate "$RV")" "commit: must be exactly"
mk_review "$RV" "$sha" 0 "" ""
assert_contains "review without not-examined is rejected" "$(gate "$RV")" "not examined"
mk_review "$RV" "$sha" 0 ""; touch -t 202001010000 "$RV/.agent/review/$sha.md"
assert_contains "review older than the commit is rejected" "$(gate "$RV")" "older than the commit"
rm "$RV/.agent/review/$sha.md"
# Review Focus 3: only exactly "off" disables review
for v in "Off" "no" "required" ""; do
  write_goal "$RV" "true" auto "review: $v"
  assert_contains "review: '$v' still requires a review" "$(gate "$RV")" "no review file"
done
write_goal "$RV" "true" auto "review: off"
out=$(gate "$RV")
assert_contains "review: off skips the review" "$out" "review skipped"
assert_contains "review: off still passes the rest" "$out" "PASS"
assert_contains "events: gate outcome logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "gate-pass-auto"
assert_contains "events: gate failure logged" "$(jq -r 'select(.kind=="release") | .data.outcome' "$AGENT_HOME/events.jsonl")" "gate-fail"
for l in error-resilience identity simulation; do
  assert_file "lens $l exists" "$KIT/templates/review-lenses/$l.md"
  assert_contains "lens $l asks for not examined" "$(cat "$KIT/templates/review-lenses/$l.md")" "## not examined"
done
assert_contains "REVIEW.md template has blocking:" "$(cat "$KIT/templates/REVIEW.md")" "blocking:"
assert_contains "VERIFY.md template has not examined" "$(cat "$KIT/templates/VERIFY.md")" "## not examined"
```

- [ ] **Step 2: Run and confirm they fail**

Run: `tests/run.sh 2>&1 | grep -E 't_release|TOTAL'`
Expected: FAIL on "evidence without not-examined is rejected" and the other new checks. Existing checks still pass.

- [ ] **Step 3: Implement** `bin/release-gate.sh`

1. Directly after `HEAD_SHA=$(git rev-parse HEAD)`, add:
   ```bash
   CWD=$ROOT; NAME=$(basename "$ROOT")
   ```
2. Replace `fail() { echo "release-gate: FAIL: $1" >&2; exit 1; }` with:
   ```bash
   fail() { ev release "$(jq -nc --arg s "$HEAD_SHA" --arg m "$1" '{sha:$s,outcome:"gate-fail",detail:$m}')"; echo "release-gate: FAIL: $1" >&2; exit 1; }
   ```
3. Directly after the `kv()` definition, add:
   ```bash
   compact_section() { # file section -> the section's text without whitespace or HTML comments
     awk -v n="$2" '{ low = tolower($0) } low ~ "^## *" n "[[:space:]]*$" { insec = 1; next } /^## / { insec = 0 } insec' "$1" \
       | sed 's/<!--.*-->//g' | tr -d '[:space:]'
   }
   ```
4. Directly before `if [ -n "$PROBLEMS" ]; then`, add:
   ```bash
   ne=$(compact_section "$EVIDENCE" "not examined")
   [ "${#ne}" -ge 10 ] || problem "## not examined needs at least 10 characters: what this verification did not check"
   ```
5. Replace the block
   ```bash
   if [ -n "$PROBLEMS" ]; then
     echo "release-gate: FAIL: evidence file .agent/verify/$HEAD_SHA.md rejected:$PROBLEMS" >&2
     exit 1
   fi
   ```
   with:
   ```bash
   [ -z "$PROBLEMS" ] || fail "evidence file .agent/verify/$HEAD_SHA.md rejected:$PROBLEMS"

   # 3b. review (D14): required unless GOAL.md says exactly "review: off" (only the user can write that)
   if [ "$(goal_get "$GOAL" review)" = off ]; then
     echo "release-gate: review skipped by GOAL.md (review: off)"
   else
     REVIEW="$AGENT_DIR/review/$HEAD_SHA.md"
     [ -f "$REVIEW" ] || fail "no review file at .agent/review/$HEAD_SHA.md. Dispatch a fresh read-only reviewer subagent with 'git diff origin/$BASE...HEAD' and the lenses in templates/review-lenses/, and have it write that file (format: templates/REVIEW.md)."
     RP=""
     [ "$(kv "$REVIEW" commit)" = "$HEAD_SHA" ] || RP="$RP"$'\n'"  - commit: must be exactly $HEAD_SHA"
     if [ "$(file_mtime "$REVIEW")" -lt "$(git log -1 --format=%ct HEAD)" ]; then RP="$RP"$'\n'"  - the review is older than the commit; review again"; fi
     rne=$(compact_section "$REVIEW" "not examined")
     [ "${#rne}" -ge 10 ] || RP="$RP"$'\n'"  - ## not examined needs at least 10 characters"
     nb=$(kv "$REVIEW" blocking)
     case "$nb" in ''|*[!0-9]*) RP="$RP"$'\n'"  - blocking: must be a number"; nb=0 ;; esac
     if [ "$nb" -gt 0 ]; then
       unresolved=$(awk '
         /^[[:space:]]*[-*][[:space:]]*\[blocking\]/ { if (p) n++; p = 1; next }
         p && /^[[:space:]]*resolved:[[:space:]]*[^[:space:]]/ { p = 0; next }
         p && /^[[:space:]]*[-*][[:space:]]/ { n++; p = 0 }
         /^## / { if (p) n++; p = 0 }
         END { if (p) n++; print n + 0 }' "$REVIEW")
       [ "$unresolved" -eq 0 ] || RP="$RP"$'\n'"  - $unresolved blocking finding(s) without a resolved: line"
     fi
     [ -z "$RP" ] || fail "review file .agent/review/$HEAD_SHA.md rejected:$RP"
   fi
   ```
6. In step 5 of the script (token or ready marker), directly after `rm -f "$TOKEN" "$READY"`, add:
   ```bash
   ev release "$(jq -nc --arg s "$HEAD_SHA" --arg m "$RELEASE_MODE" '{sha:$s,outcome:("gate-pass-" + $m)}')"
   ```
7. Update the header comment's "Checks, in order:" line to read `clean tree, up to date with origin/<base>, evidence file parses clean for this exact HEAD (including a "## not examined" section), review file for this HEAD (unless GOAL.md says review: off), test_command passes.`

`templates/VERIFY.md` gets two additions:
1. In the comment's list of rejection reasons, add the line `  - the "## not examined" section has fewer than 10 characters`.
2. Add this section after the `## exercised` section at the end:
   ```markdown

   ## not examined

   - What this verification deliberately did not check (other views, mobile, write paths on preview, load).
   ```

Create `templates/REVIEW.md`:

```markdown
commit: <full 40-char sha of HEAD>
reviewer: subagent
lenses: error-resilience, identity, simulation
blocking: 0

<!--
Review file for release-gate.sh. Save as .agent/review/<full HEAD sha>.md. Written by a FRESH, read-only
reviewer subagent (not the session that wrote the code) that got `git diff origin/<base>...HEAD` and the
three lens prompts in templates/review-lenses/.

The gate parses this file mechanically. It rejects the release if:
  - `commit:` is not the exact HEAD sha, or the file is older than the HEAD commit
  - `blocking:` is not a number
  - any `- [blocking]` finding is not followed by a `resolved:` line (what was done, or why it stays)
  - `## not examined` has fewer than 10 characters
-->

## findings

- [blocking] path/to/file.ts:42 What is wrong and what it breaks for a user.
  resolved: fixed in <sha7> / kept because <reason>
- [note] path/to/other.ts:7 Worth knowing, does not block.

## not examined

- What this review did not check (and why).
```

Create the three lens files from the MIT-licensed super-hermes source. Run this from the worktree root; the clone lives in the main checkout:

```bash
SRC=/Users/clyde/bbq/ching/vendor-eval/super-hermes/skills/prism-scan/references
mkdir -p templates/review-lenses
for pair in error_resilience:error-resilience identity:identity simulation:simulation; do
  src=${pair%%:*}; dst=${pair##*:}
  {
    printf '<!-- Adapted from super-hermes by Cranot (https://github.com/Cranot/super-hermes),\n'
    printf '     skills/prism-scan/references/%s.md. MIT License, Copyright (c) 2026 Cranot. -->\n\n' "$src"
    printf '# Review lens: %s\n\nApply this lens to the diff you were given (the change, not the whole repo).\n\n' "$dst"
    awk 'NR == 1 && /^---$/ { fm = 1; next } fm && /^---$/ { fm = 0; next } !fm' "$SRC/$src.md"
    printf '\n## Output\n\nAdd your findings to the review file (`templates/REVIEW.md` format): one bullet each, `[blocking]` only\n'
    printf 'for something that would hurt a user or corrupt data, otherwise `[note]`, always with `file:line`.\n'
    printf 'Then fill `## not examined` with what this lens did not look at.\n'
  } >"templates/review-lenses/$dst.md"
done
```

Then read each generated file. Confirm that it has no Hermes-specific instructions (`skill_view`, `~/.hermes`) and that the lens body is intact.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`. Existing release tests pass because `mk_evidence` now also writes a valid review.

- [ ] **Step 5: Commit**

```bash
git add bin/release-gate.sh templates/VERIFY.md templates/REVIEW.md templates/review-lenses tests/t_release.sh
git commit -m "release-gate: require a review file and a not-examined section; lenses from super-hermes (MIT)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 9: Guard rules 8-10 and deny events

**Files:**
- Modify: `bin/guard.sh`
- Test: `tests/t_guard.sh`

**Interfaces:**
- Consumes: `ev` from `bin/lib.sh`, sourced in a subshell only after a decision is printed.
- Produces: event `deny{rule,tool}`. Deny reasons start with `GUARD: rule 8:`, `GUARD: rule 9:` or `GUARD: rule 10:`.

- [ ] **Step 1: Write the failing tests.** Append before the final `exit 0` of `tests/t_guard.sh`:

```bash
# ---------- Phase 1.5: rules 8-10 ----------
GR=$(mk_repo guardp15)
gdeny "rule 8: npm publish" "$GR" "npm publish"
gdeny "rule 8: pnpm publish --access public" "$GR" "pnpm publish --access public"
gdeny "rule 8: bun publish" "$GR" "bun publish"
gdeny "rule 8: yarn npm publish" "$GR" "yarn npm publish"
gdeny "rule 8: gh release create" "$GR" "gh release create v1.0.0"
gdeny "rule 8: gh release delete" "$GR" "gh release delete v1.0.0 --yes"
gdeny "rule 8: gh repo delete" "$GR" "gh repo delete me/x --yes"
gdeny "rule 8: gh repo edit visibility" "$GR" "gh repo edit --visibility public"
gdeny "rule 8: gh repo create --public" "$GR" "gh repo create me/new --public"
gallow "rule 8: npm pack" "$GR" "npm pack"
gallow "rule 8: npm test" "$GR" "npm test"
gallow "rule 8: bun test publish.test.ts" "$GR" "bun test publish.test.ts"
gallow "rule 8: gh release list" "$GR" "gh release list"
gallow "rule 8: gh repo view" "$GR" "gh repo view"
gallow "rule 8: gh repo create --private" "$GR" "gh repo create me/new --private"
gdeny "rule 9: gh pr close" "$GR" "gh pr close 12"
gdeny "rule 9: gh issue close" "$GR" "gh issue close 7 --comment done"
gdeny "rule 9: gh issue delete" "$GR" "gh issue delete 7"
gdeny "rule 9: gh api state=closed" "$GR" "gh api -X PATCH repos/o/r/issues/7 -f state=closed"
gallow "rule 9: gh pr comment" "$GR" "gh pr comment 12 --body 'looks good'"
gallow "rule 9: gh issue comment" "$GR" "gh issue comment 7 --body 'see 8'"
gallow "rule 9: gh pr view" "$GR" "gh pr view 12"
tdeny "rule 10: gmail send_message" mcp__claude_ai_Gmail__send_message "$GR" '{"to":"a@b.c","body":"hi"}'
tdeny "rule 10: gmail reply" mcp__claude_ai_Gmail__reply "$GR" '{"body":"hi"}'
tdeny "rule 10: gmail forward" mcp__claude_ai_Gmail__forward "$GR" '{}'
tdeny "rule 10: slack send" mcp__plugin_slack_slack__slack_send_message "$GR" '{"text":"hi"}'
tdeny "rule 10: telegram reply" mcp__plugin_telegram_telegram__reply "$GR" '{"text":"hi"}'
tdeny "rule 10: discord reply" mcp__plugin_discord_discord__reply "$GR" '{"text":"hi"}'
tallow "rule 10: gmail create_draft" mcp__claude_ai_Gmail__create_draft "$GR" '{"to":"a@b.c"}'
tallow "rule 10: slack send as draft" mcp__plugin_slack_slack__slack_send_message_draft "$GR" '{"text":"hi"}'
tallow "rule 10: gmail search" mcp__claude_ai_Gmail__search_threads "$GR" '{"q":"x"}'
out=$(jq -n --arg c "$GR" '{hook_event_name:"PreToolUse",session_id:"g-ev",tool_name:"Bash",cwd:$c,tool_input:{command:"npm publish"}}' | "$BIN/guard.sh")
assert_contains "deny is printed while logging" "$out" '"deny"'
assert_contains "events: deny logged with the session id" "$(jq -r 'select(.kind=="deny") | .sid' "$AGENT_HOME/events.jsonl")" "g-ev"
assert_contains "events: deny names the rule" "$(jq -r 'select(.kind=="deny" and .sid=="g-ev") | .data.rule' "$AGENT_HOME/events.jsonl")" "rule 8"
```

- [ ] **Step 2: Run and confirm they fail**

Run: `tests/run.sh 2>&1 | grep -E 't_guard|TOTAL'`
Expected: FAIL on the `rule 8/9/10` deny cases. The allow cases already pass.

- [ ] **Step 3: Implement** in `bin/guard.sh`

1. Replace `emit_deny()` with:
   ```bash
   emit_deny() {
     DECIDED=1
     jq -n --arg r "GUARD: $1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
     # The decision is printed first; logging it can never change it.
     ( SID=$(jq -r '.session_id // ""' <<<"$INPUT" 2>/dev/null || true); CWD=${CWD:-$PWD}; NAME=$(basename "$CWD")
       # shellcheck source=lib.sh
       . "$SELF_DIR/lib.sh" && ev deny "$(jq -nc --arg r "$1" --arg t "${TOOL:-}" '{rule:$r,tool:$t}')" ) >/dev/null 2>&1 || true
     exit 0
   }
   ```
2. In `check_gh`, add these cases to the `case "$subs" in`, directly above `" workflow run"*|…`:
   ```bash
       " pr close"*|" issue close"*|" issue delete"*)
         emit_deny "rule 9: closing or deleting PRs and issues is the user's call. Comment with your reasoning (gh pr comment / gh issue comment) and notify instead." ;;
       " release create"*|" release delete"*|" release edit"*|" release upload"*)
         emit_deny "rule 8: publishing a release is the user's call. Prepare it, then notify that it is ready." ;;
       " repo delete"*) emit_deny "rule 8: deleting a repository is the user's call." ;;
       " repo edit"*) if seg_matches '--visibility*'; then emit_deny "rule 8: changing repository visibility is the user's call."; fi ;;
       " repo create"*) if seg_matches '--public'; then emit_deny "rule 8: a public repository publishes code. Create it with --private, or ask the user."; fi ;;
   ```
   and in the existing `" api"*)` branch, directly after its `case "$method" …` line, add:
   ```bash
         if [ "$mut" -eq 1 ] && seg_matches '*state=closed*'; then emit_deny "rule 9: closing an issue or PR through the API is the user's call. Comment and notify instead."; fi
   ```
3. Add this function directly above `check_vercel()`:
   ```bash
   check_publish() { # $1 = index of npm/pnpm/bun/yarn: any `publish` word in the command is denied
     if seg_matches publish; then
       emit_deny "rule 8: publishing a package is the user's call. Run '${TOKS[$1]##*/} pack' to check the tarball, then notify that it is ready."
     fi
   }
   ```
   and in `check_misc`'s `case "$b" in` (the `cmd_pos` block), add a case directly after `gh) check_gh "$k" ;;`:
   ```bash
           npm|pnpm|bun|yarn) check_publish "$k" ;;
   ```
4. Add this function directly above `case "$TOOL" in` at the end of the file:
   ```bash
   check_send_mcp() { # rule 10 (D18): drafts only
     local op=${TOOL_LC##*__}
     case "$op" in *draft*) allow ;; esac
     case "$op" in
       *send*|reply|*_reply|reply_*|forward|*_forward|forward_*|*post_message*)
         emit_deny "rule 10: sessions write drafts and never send (D18). Save it as a draft and notify the user to send it." ;;
     esac
     allow
   }
   ```
   and change the final dispatch's `*)` branch to:
   ```bash
     *) case "$TOOL_LC" in
          mcp__*supabase*) check_supabase_mcp ;;
          mcp__*gmail*|mcp__*slack*|mcp__*discord*|mcp__*telegram*) check_send_mcp ;;
          *) allow ;;
        esac ;;
   ```
5. In the header comment, extend the rules line: `| 8 publishing (npm/bun/pnpm/yarn publish, gh release, gh repo delete/visibility/public) | 9 closing PRs/issues | 10 sending email/chat (drafts only)`.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/guard.sh tests/t_guard.sh
git commit -m "guard: rules 8 (publishing), 9 (closing PRs/issues), 10 (drafts only); log denies

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 10: Guard rule 11 (gate settings in GOAL.md)

**Files:**
- Modify: `bin/guard.sh`
- Test: `tests/t_guard.sh`

**Interfaces:**
- Gated keys: `review`, `release_mode`, `test_command`.
- Protected paths: `*/.agent/GOAL.md` and `*/defaults/GOAL.md`. The second covers `~/.agent/defaults/GOAL.md` and any `AGENT_HOME` override, even after macOS resolves `/tmp` to `/private/tmp`.
- Rules:
  - **Edit/MultiEdit:** the gated lines in the old and new text must match.
  - **Write over an existing file:** the gated lines must match the file on disk.
  - **Write of a new file:** `review` may only be `required` or absent, and `release_mode` only `confirm` or absent.
  - **Any Bash write** to a protected path is denied.

- [ ] **Step 1: Write the failing tests.** Append before the final `exit 0` of `tests/t_guard.sh`:

```bash
# ---------- rule 11: gate settings in GOAL.md ----------
G11=$(mk_repo g11); write_goal "$G11" "bun test" confirm
GF="$G11/.agent/GOAL.md"
tdeny "rule 11: Edit adds review: off" Edit "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,old_string:"base_branch: main",new_string:"base_branch: main\nreview: off"}')"
tdeny "rule 11: Edit switches release_mode" Edit "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,old_string:"release_mode: confirm",new_string:"release_mode: auto"}')"
tdeny "rule 11: Edit changes test_command" Edit "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,old_string:"test_command: bun test",new_string:"test_command: true"}')"
tallow "rule 11: Edit of the goal prose" Edit "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,old_string:"# Goal",new_string:"# Goal\nShip the widget."}')"
tdeny "rule 11: Write that rewrites settings" Write "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,content:"# Goal\ntest_command: true\nrelease_mode: auto\n"}')"
tallow "rule 11: Write that keeps settings" Write "$G11" "$(jq -n --arg f "$GF" --arg c "$(cat "$GF")"$'\n'"More prose." '{file_path:$f,content:$c}')"
tdeny "rule 11: MultiEdit sneaks in review: off" MultiEdit "$G11" "$(jq -n --arg f "$GF" '{file_path:$f,edits:[{old_string:"# Goal",new_string:"# Goal\nreview: off"}]}')"
N11=$(mk_repo n11)
tdeny "rule 11: new GOAL.md with review: off" Write "$N11" "$(jq -n --arg f "$N11/.agent/GOAL.md" '{file_path:$f,content:"# Goal\ntest_command: true\nreview: off\n"}')"
tdeny "rule 11: new GOAL.md with release_mode: auto" Write "$N11" "$(jq -n --arg f "$N11/.agent/GOAL.md" '{file_path:$f,content:"# Goal\ntest_command: true\nrelease_mode: auto\n"}')"
tallow "rule 11: new GOAL.md with safe defaults" Write "$N11" "$(jq -n --arg f "$N11/.agent/GOAL.md" '{file_path:$f,content:"# Goal\ntest_command: bun test\nrelease_mode: confirm\nreview: required\n"}')"
tdeny "rule 11: defaults GOAL.md" Edit "$G11" "$(jq -n --arg f "$AGENT_HOME/defaults/GOAL.md" '{file_path:$f,old_string:"x",new_string:"review: off"}')"
gdeny "rule 11: redirect into GOAL.md" "$G11" "echo 'review: off' >> .agent/GOAL.md"
gdeny "rule 11: sed -i on GOAL.md" "$G11" "sed -i '' 's/confirm/auto/' .agent/GOAL.md"
gdeny "rule 11: cp over GOAL.md" "$G11" "cp /tmp/x .agent/GOAL.md"
gallow "rule 11: reading GOAL.md" "$G11" "cat .agent/GOAL.md"
```

- [ ] **Step 2: Run and confirm they fail**

Run: `tests/run.sh 2>&1 | grep -E 'rule 11|TOTAL'`
Expected: FAIL on the `rule 11` deny cases.

- [ ] **Step 3: Implement** in `bin/guard.sh`

1. Add directly above `tamper_bash() {`:
   ```bash
   # ---------- rule 11: gate settings in GOAL.md ----------
   is_goal_path() {
     case "$1" in */.agent/GOAL.md|*/defaults/GOAL.md) return 0 ;; esac   # */defaults/ also covers AGENT_HOME overrides
     return 1
   }
   gated_lines() { grep -E '^[[:space:]]*(review|release_mode|test_command):' | sed 's/[[:space:]]*$//' | sort || true; }
   deny_goal() { emit_deny "rule 11: review, release_mode and test_command in GOAL.md are the user's settings. Put the proposed change in STATE.md and notify the user."; }
   check_goal_write() { # $1 = absolute path of a GOAL.md being written by Edit/MultiEdit/Write
     local old new rv relm
     case "$TOOL" in
       Edit)
         old=$(jq -r '.tool_input.old_string // ""' <<<"$INPUT" | gated_lines)
         new=$(jq -r '.tool_input.new_string // ""' <<<"$INPUT" | gated_lines)
         [ "$old" = "$new" ] || deny_goal ;;
       MultiEdit)
         old=$(jq -r '[.tool_input.edits[]?.old_string // ""] | join("\n")' <<<"$INPUT" | gated_lines)
         new=$(jq -r '[.tool_input.edits[]?.new_string // ""] | join("\n")' <<<"$INPUT" | gated_lines)
         [ "$old" = "$new" ] || deny_goal ;;
       Write)
         new=$(jq -r '.tool_input.content // ""' <<<"$INPUT" | gated_lines)
         if [ -f "$1" ]; then
           old=$(gated_lines <"$1")
           [ "$old" = "$new" ] || deny_goal
         else
           rv=$(printf '%s\n' "$new" | sed -n 's/^[[:space:]]*review:[[:space:]]*//p' | head -1)
           relm=$(printf '%s\n' "$new" | sed -n 's/^[[:space:]]*release_mode:[[:space:]]*//p' | head -1)
           if { [ -n "$rv" ] && [ "$rv" != required ]; } || { [ -n "$relm" ] && [ "$relm" != confirm ]; }; then
             emit_deny "rule 11: a new GOAL.md may only start with review: required and release_mode: confirm. The user switches them."
           fi
         fi ;;
     esac
   }
   ```
2. In `check_write`, directly before its final `allow`, add:
   ```bash
     if is_goal_path "$abs"; then check_goal_write "$abs"; fi
   ```
3. In `tamper_bash`, change the path-resolution line to also resolve GOAL.md tokens:
   ```bash
       case "$t" in *hooks*|*settings*|*ching*|*.sql|*GOAL.md*) abs=$(resolve_path "$t" "$SIM_CWD") ;; esac
   ```
   and directly after the `is_tamper_path` check inside the loop, add:
   ```bash
       if [ -n "$abs" ] && is_goal_path "$abs" && seg_writes; then
         emit_deny "rule 11: write GOAL.md with the Edit or Write tool so the guard can check its gate settings."
       fi
   ```
4. Extend the header rules line with `| 11 gate settings in GOAL.md (review, release_mode, test_command)`.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add bin/guard.sh tests/t_guard.sh
git commit -m "guard: rule 11, sessions cannot change review/release_mode/test_command in GOAL.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 11: Autonomy block and template consistency test

**Files:**
- Modify: `templates/AGENTS-autonomy-block.md`
- Create: `tests/t_templates.sh`

**Interfaces:**
- Consumes: templates from Tasks 3, 7 and 8; `checkpoint_get` (Task 1).

- [ ] **Step 1: Write the failing test** `tests/t_templates.sh`

```bash
#!/usr/bin/env bash
# The policy text and templates agree with what the scripts parse.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=../bin/lib.sh
. "$BIN/lib.sh"
A="$KIT/templates/AGENTS-autonomy-block.md"
assert_contains "autonomy: checkpoint every turn" "$(cat "$A")" "ching:checkpoint"
assert_contains "autonomy: name the exact missing piece" "$(cat "$A")" "exact missing piece"
assert_contains "autonomy: review step" "$(cat "$A")" ".agent/review/"
assert_contains "autonomy: review lenses" "$(cat "$A")" "review-lenses"
assert_contains "autonomy: drafts only" "$(cat "$A")" "drafts"
assert_contains "autonomy: gate settings belong to the user" "$(cat "$A")" "review:"
for k in result blocker next_action files_changed examined not_examined; do
  assert_eq "STATE.md template: $k parses" "1" "$([ -n "$(checkpoint_get "$KIT/templates/STATE.md" "$k")" ] && echo 1 || echo 0)"
done
assert_contains "handoff writes the checkpoint" "$(cat "$KIT/commands/handoff.md")" "ching:checkpoint"
assert_contains "dispatcher uses the inbox" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --inbox"
assert_contains "dispatcher uses next" "$(cat "$KIT/dispatcher/AGENTS.md")" "dash.sh --next"
exit 0
```

- [ ] **Step 2: Run and confirm it fails**

Run: `tests/run.sh 2>&1 | grep -E 't_templates|TOTAL'`
Expected: the `autonomy:` checks fail.

- [ ] **Step 3: Implement** `templates/AGENTS-autonomy-block.md`

1. Replace the bullet starting `- At the end of every turn update` with:
   ```markdown
   - At the end of every turn update `.agent/STATE.md` (including the `<!-- ching:checkpoint -->` block: result, blocker, next_action, files_changed, examined, not_examined) and rewrite `.agent/NEXT.md` (use `/handoff`). The Stop hook asks once per prompt if the checkpoint is missing or stale.
   - A blocker names the exact missing piece (a file, a credential, a decision, with its name), never "needs input".
   ```
2. Replace the bullet starting `- Stop and ask the user before:` with:
   ```markdown
   - Stop and ask the user before: destructive database changes, spending money, handling credentials, anything the guard hook denies that you cannot route around.
   - Never send email or chat messages: write drafts and notify the user (guard rule 10). Never publish packages or releases, close PRs/issues, or change `review:`, `release_mode:` or `test_command:` in GOAL.md (rules 8, 9, 11); propose it in STATE.md instead.
   ```
3. In "### Shipping (release gate)", replace steps 3 and 4 with:
   ```markdown
   3. Write the evidence file `.agent/verify/<full HEAD sha>.md` (format: the VERIFY.md template in the ching kit), including `## not examined`. Paste raw console and network output; the gate rejects console errors and non-2xx requests regardless of what you conclude.
   4. Review: dispatch a FRESH read-only reviewer subagent with `git diff origin/main...HEAD` and the three lenses in `templates/review-lenses/` (error-resilience, identity, simulation). It writes `.agent/review/<full HEAD sha>.md` (format: templates/REVIEW.md). Fix or answer every `[blocking]` finding with a `resolved:` line. You do not review your own work.
   5. Run `release-gate.sh`. In `confirm` mode it notifies the user and waits; in `auto` mode it mints a token for exactly that commit.
   ```
   and renumber the remaining steps to 6 and 7.

- [ ] **Step 4: Run all tests**

Run: `tests/run.sh`
Expected: `0 failed`.

- [ ] **Step 5: Commit**

```bash
git add templates/AGENTS-autonomy-block.md tests/t_templates.sh
git commit -m "autonomy block: checkpoint, exact blockers, review step, drafts only, gate settings

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
```

---

### Task 12: Verification, lens self-check, docs, Checkpoint 1.5 (separate verifier per D10)

**Files:**
- Modify: `tests/live-smoke.sh`, `PLAN.md`
- Create: `CHECKPOINT-1.5.md`
- Delete: `/Users/clyde/bbq/ching/vendor-eval/` (only after the lens files are committed)

This task is run by an agent that did **not** implement Tasks 1-11.

- [ ] **Step 1: Full suite plus shellcheck**

Run: `tests/run.sh`
Expected: `TOTAL: N passed, 0 failed`, with N greater than the Task 0 baseline. If `t_lint` reports shellcheck skipped, run `python3 -m venv /tmp/sc-venv && /tmp/sc-venv/bin/pip install -q shellcheck-py` and re-run until the shellcheck checks pass.

- [ ] **Step 2: Live smoke shows events.** In `tests/live-smoke.sh`, directly after the line `echo "ok-file exists: …"`, add:

```bash
echo "events logged: $(jq -r .kind "$AGENT_HOME/events.jsonl" 2>/dev/null | sort | uniq -c | tr -s ' \n' ' ')"
```

Run: `tests/live-smoke.sh` (costs about US$0.15 on haiku).
Expected:
- the earlier checks unchanged (PINEAPPLE-42, ok-file yes, remote scratch no-good);
- "events logged:" lists `session_start`, `prompt`, `stop_blocked` and `stop_ok`;
- the Stop hook asks once for the checkpoint, because the test repo has a GOAL.md.

- [ ] **Step 3: Error-resilience lens over the guardrails.** Dispatch a fresh read-only reviewer subagent with `templates/review-lenses/error-resilience.md`, `bin/guard.sh` and `bin/stop-check.sh`. Ask for fail-open paths: inputs where a deny should fire but the script allows, or where an error lets a stop or call through. For every finding, either write a failing test plus a fix (TDD) or log it in `CHECKPOINT-1.5.md` under "Known gaps" with a reason.

- [ ] **Step 4: Dry-run the installer against a copy of the real settings** (writes nothing real)

```bash
mkdir -p /tmp/cp15 && cp ~/.claude/settings.json /tmp/cp15/settings.json
CLAUDE_DIR=$HOME/.claude SETTINGS_FILE=/tmp/cp15/settings.json AGENT_REPOS_FILE=/tmp/cp15/agent-repos \
  LAUNCH_AGENTS_DIR=/tmp/cp15/LaunchAgents LAUNCHCTL=/usr/bin/true ./install.sh --dry-run
```

Expected: a diff that only changes the guard matcher, plus "would: write …org.ching.watch.plist and launchctl bootstrap it". Save the output for the report.

- [ ] **Step 5: Write `CHECKPOINT-1.5.md`** with these sections:
  1. What was built, per task.
  2. The `tests/run.sh` table.
  3. Live-smoke output.
  4. The installer dry-run diff from Step 4.
  5. Lens findings and their fixes or known gaps.
  6. What the user does next: run `./install.sh` (it widens the guard matcher and loads the watcher), optionally set `TOKEN_BUDGET_DAILY` in `~/.agent/defaults/ching.env`, then start the Phase 2 pilot.

- [ ] **Step 6: Tick Phase 1.5 in PLAN.md.** Change `- [ ] **1.5.1**` … `- [ ] **1.5.10**` to `- [x]`, and append to the Checkpoint 1.5 line: ` Report: CHECKPOINT-1.5.md.`

- [ ] **Step 7: Commit, then remove the evaluation clones**

```bash
git add tests/live-smoke.sh PLAN.md CHECKPOINT-1.5.md
git commit -m "Phase 1.5 verified: suite, live smoke with events, lens review, Checkpoint 1.5 report

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01DTe7KG79qGGq128Pk6pA9R"
rm -rf /Users/clyde/bbq/ching/vendor-eval
```

- [ ] **Step 8: Integrate and stop at the checkpoint.** Use superpowers:finishing-a-development-branch to merge `phase-1.5-harvest` into `main`; `main` may have moved because of the other session. **Do not run `install.sh` on the real settings.** Stop and show the user `CHECKPOINT-1.5.md`. Checkpoint 1.5 requires their approval.
