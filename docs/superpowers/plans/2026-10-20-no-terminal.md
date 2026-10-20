# No Terminal windows: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every Claude Code session runs in the background and is managed from agterm; a Terminal window opens only for a moment when the owner needs Claude Code's own screen.

**Architecture:** reuse what agterm already does for background sessions (`bg.go`: `bgStart`, `bgSend`, `bgSteps`, `claude attach`). Add one short-lived window helper and route every place that opens a long-lived Terminal window through `claude --bg` plus that helper. No new dependencies.

**Tech Stack:** Go 1.27, Bubble Tea, JXA (`terminal/send.js`) and AppleScript through `osascript`, bash (`install.sh`, `bin/`).

**Spec:** `docs/superpowers/specs/2026-10-20-no-terminal-design.md` (phases 0-4; phase 5 stays later).

## Global Constraints

- Owner decisions (spec, "The owner's decisions"): move running Terminal sessions to the background, idle ones only; the full screen opens in "a short-lived Terminal window that closes when you leave it, NOT inside agterm's own window"; sessions started by hand use "a new `cl` shell command that starts a background session and selects it in agterm".
- Open questions 1-4 take the spec's recommended defaults: trust answered in a short-lived window (agterm never writes `~/.claude.json`); nothing new on monitor 2; PC `t` becomes "background session, then its short-lived window at once"; the voice dispatcher stays in its Terminal window.
- Phase 0 facts (spec, "Phase 0 answers"): `Ctrl+Z` ends `claude attach` with exit 0, `←` does not; `claude --bg` starts with no prompt; `claude --bg --resume <id>` keeps the session id, job id and name but not model or permission mode, so pass `--model`/`--permission-mode` explicitly; background sessions write `~/.agent/usage/<sid>.json`; a typed `!cmd` runs as a shell command; the owner's Terminal profile has no `shellExitAction`, so agterm closes the window itself.
- Repo rules: one PR per phase with its own `DECISIONS.md` entry (next free number on `origin/main` at commit time), manual (`docs/agent-terminal-manual.md`), `?` help (`helpLines` in `view.go`), footer and keys.toml comments updated in the same PR. Comments plain and short like the surrounding code.
- Tests: `cd terminal && LC_ALL=en_US.UTF-8 go test -race ./...` and `gofmt -l .` empty; shell changes: `LC_ALL=en_US.UTF-8 tests/run.sh`. External commands (`claude`, `osascript`) go through function variables that tests replace, as `transmitFn`, `bgStartFn`, `osascriptRun` do today.
- Git: never force-push, stage explicit paths, don't merge PRs.

## Review Focus

1. A short-lived window whose attach was ended with `←` (agent view) instead of `Ctrl+Z`: the shell is still busy, so agterm must not close it. Test: `closeIdle` leaves a busy tab open (Task 1).
2. `g` pressed twice on one background session: one window, raised the second time. Test in Task 1.
3. `/BG` on a session that turns busy or shows a menu between the check and `/exit`: nothing is typed when the fresh screen shows a menu or the session is busy at send time. Test in Task 5.
4. `cl` run in a folder Claude Code doesn't trust: `cl` prints Claude Code's error and exits non-zero, and writes no select file. Test in Task 3.
5. The select file names a session that never shows up (start failed later): agterm drops it after 30 s instead of selecting something else. Test in Task 3.

---

### Task 1: Short-lived window for a background session (phase 1, spec A)

**Files:**
- Modify: `terminal/bg.go` (`bgAttachWindow`), `terminal/send.js` (new `closeidle` command), `terminal/send.go`, `terminal/ui.go` (`K.Goto`, `K.Here` cases; `tickMsg`), `terminal/findui.go` (`termScript` returns the tab's tty)
- Test: `terminal/bg_test.go` (new), `terminal/findui_test.go` or existing `termScript` test

**Interfaces:**
- Produces: `shortWindow(job string) (tty string, err error)` in `bg.go`: runs `claude attach <job>; exit` in a new Terminal window via AppleScript `do script`, returns the new tab's tty (`tty of (do script ...)`). `m.short map[string]string` (job → tty) on the model. `closeIdle(tty string) bool` in `send.go` → `osa("closeidle", tty)`: closes the window of that tab when the tab is not busy, true when closed or gone. `m.openShort(a Agent) tea.Cmd`: raises the window when `m.short[a.Job]` is a live tab (`raiseTab`), else calls `shortWindow` and records the tty.
- Consumes: `termWindow`/`osascriptRun`, `raiseTab`, `terminalTabs`.

- [ ] **Step 1: Write the failing tests.** `TestShortWindowScript`: the AppleScript from `shortWindow` contains `claude attach 'abc'; exit` (quoted with `shQuote`) and asks for `tty of`. `TestOpenShortOnce`: with `osascriptRun` replaced to return `/dev/ttys042`, `openShort` twice for job `abc` opens once and raises the second time (count the scripts). `TestTickClosesIdleShort`: tick with `m.short = {"abc": "ttys042"}` and a replaced `closeIdleFn` returning true removes the entry; returning false keeps it.
- [ ] **Step 2: Run** `go test -run 'ShortWindow|OpenShort|ClosesIdleShort' ./...`. Expected: FAIL (undefined).
- [ ] **Step 3: Implement.** `send.js closeidle <tty>`: find the tab with `findTab`; if none return `ok`; if `tab.busy()` return `busy`; else close its window and return `ok`. `g` and `h` on a `Bg` agent call `m.openShort`. The tick calls `closeIdleFn` for each entry in `m.short` (in the tick's command, not in Update) and drops closed ones. Footer for a background agent: `g opens its screen (ctrl+z closes it)`.
- [ ] **Step 4: Run** the tests and the full suite. Expected: PASS.
- [ ] **Step 5: Live check.** Start `claude --bg -n p1probe --model haiku` in the repo, press `g` in a built agterm, `Ctrl+Z` in the window: the window closes within one tick (2 s). Stop the probe.
- [ ] **Step 6: Docs and commit.** D-entry "g/h on a background session open a short-lived window", manual 1.2 (`g`, `h`), help, footer. Commit, push, PR.

### Task 2: Every start is a background one (phase 2, spec B and C)

**Files:**
- Modify: `terminal/findui.go` (`findResume`), `terminal/ui.go` (`nw:` send path with empty text; command `LOGIN`), `terminal/pchand.go` (`termStart` for PC `t`), `terminal/bg.go`
- Test: `terminal/find_test.go`, `terminal/pchand_test.go`, `terminal/bg_test.go`

**Interfaces:**
- Consumes: `m.openShort` and `shortWindow` (Task 1), `bgStartFn`.
- Produces: `bgResume(dir, id string, o nwOpts) (job string, err error)`: `claude --bg --resume <id>` plus `o`'s `--model`/`--permission-mode`/`--effort`, in `dir`. `trustNeeded(err error) bool`: true when the error text contains `not trusted`. `termShort(cmd string) (tty string, err error)`: the generic form of `shortWindow` for any shell line (`shortWindow(job)` becomes `termShort("claude attach " + shQuote(job))`).

- [ ] **Step 1: Write the failing tests.** `TestFindResumeBackground`: `r` on an ended hit calls a replaced `bgResumeFn` with the hit's folder and id and opens no window. `TestNWEmptyOpensWindow`: Enter with an empty box on an `nw:` target calls `bgStartFn` with prompt `""` and then `openShort`. `TestTrustAsk`: `bgStartFn` failing with "Workspace not trusted" puts the command line in a yes/no ask (`Trust <folder>? enter yes`); `enter` opens `termShort("cd '<dir>' && claude")`; when that window is gone at a later tick, the start is retried once. `TestPCTerminalIsBackground`: PC `t` calls `bgStartFn` then `openShort`, not `termWindow`.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.** `claude --bg` with an empty prompt: `nwOpts.args("")` must omit `-- ""`. `bgResume` reads model from the transcript the way `modelTag` does when `o.Model` is empty. `LOGIN` opens `termShort("claude auth login")`. Logged-out detection: run `claude auth status` at start and every 5 minutes (in a command, with a 10 s timeout); a non-zero exit shows an orange `logged out: /LOGIN` line in the status area.
- [ ] **Step 4: Run** the tests and the full suite. Expected: PASS.
- [ ] **Step 5: Docs and commit.** D-entry, manual 6.15 (NW), 6.19 (FIND `r`), PC `t`, `LOGIN`; help. Commit, push, PR.

### Task 3: The `cl` command (phase 2, spec B, decision 3)

**Files:**
- Create: `bin/cl`
- Modify: `install.sh` (link `~/.local/bin/cl` → `bin/cl`, also in `--uninstall`), `terminal/ui.go` (tick reads the select file)
- Test: `tests/t_cl.sh` (new, picked up by `tests/run.sh`), `terminal/terminal_test.go`

**Interfaces:**
- Produces: `cl [name] [prompt...]`: runs `claude --bg -n <name>` (default: the folder's base name) in `$PWD` with `nw_model`/`nw_effort`/`nw_permission` read from `~/.agent/terminal/keys.toml` when set, then the prompt after `--` if given. Parses the job id from Claude Code's `backgrounded · <id>` line (the regex in `bg.go` `bgStartedRe`), writes `<job> <unix time>` to `~/.agent/terminal/select`, prints the job id. Exit code is claude's.
- Consumes: agterm side: `m.selectFile()`: on each tick, read the file; when an agent with that `Job` is listed, select it and delete the file; when the time is older than 30 s, delete it.

- [ ] **Step 1: Write the failing tests.** `t_cl.sh` with a fake `claude` on `PATH` (prints `backgrounded · 1a2b3c4d`): `cl` writes `1a2b3c4d <time>` to the select file and passes `-n <basename>`; `cl hlp do x` passes `-n hlp -- do x`; a fake `claude` that exits 1 with "Workspace not trusted" makes `cl` exit 1, print it, and write no file. Go: `TestSelectFile` selects agent with `Job` `1a2b3c4d` and deletes the file; a 31 s old entry is deleted without selecting.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** `bin/cl` (bash, `set -euo pipefail`, same header style as `bin/*.sh`) and `m.selectFile()`.
- [ ] **Step 4: Run** `tests/run.sh` and the Go suite. Expected: PASS.
- [ ] **Step 5: Docs and commit.** README "Quick install" mentions `cl`, manual section on starting sessions, D-entry. Commit, push, PR (may share the Task 2 PR).

### Task 4: Move running Terminal sessions to the background (phase 3, spec E, decision 1)

**Files:**
- Create: `terminal/move.go`
- Modify: `terminal/ui.go` (commands `BG` and `BG ALL`)
- Test: `terminal/move_test.go`

**Interfaces:**
- Consumes: `bgResume` (Task 2), `sendText`, `screenOf`, `parsePrompt`, `closeIdle` (Task 1).
- Produces (only the `/BG` command, no extra `B` key, to keep the desk keys free): `moveToBg(a Agent, o nwOpts) (job string, err error)`: refuses when `a.Busy`, when `!a.InTerminal`, or when a fresh `screenOf(a.TTY)` parses to a prompt with options; else types `/exit` + Enter, waits up to 20 s for the agent's `~/.claude/sessions/<pid>.json` to go, runs `bgResume(a.Cwd, a.SID, o)` with `-n a.Name` and the model from its transcript, then `closeIdle(a.TTY)`. A `moveFn` variable for tests. `BG` moves the selected agent; `BG ALL` moves every idle Terminal agent in turn and reports `moved N · skipped: name (busy), name (menu)`.

- [ ] **Step 1: Write the failing tests.** `TestMoveRefusesBusy`, `TestMoveRefusesMenu` (fresh screen with a numbered menu: nothing typed), `TestMoveOrder` (replaced send/wait/resume functions record `/exit`, wait, resume with `-n` and model, close, in that order), `TestBGAllReport` (one busy, one menu, two idle → two moves and the skipped list).
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement** `move.go` and the two commands; the moves run one after the other in a command, never in Update.
- [ ] **Step 4: Run** the tests and the full suite. Expected: PASS.
- [ ] **Step 5: Live check** with one throwaway Terminal session (`claude --model haiku` in the repo): `/BG` moves it, the tab closes, it shows as `bg` with the same name and id. Stop it.
- [ ] **Step 6: Docs and commit.** D-entry listing what a moved session loses (spec E), manual, help. Commit, push, PR.

### Task 5: `/` commands that open their own screen (phase 4, spec D)

**Files:**
- Modify: `terminal/editor.go` (one table `screenCommands`), `terminal/ui.go` (send path for `Bg` agents)
- Test: `terminal/editor_test.go` or `terminal/terminal_test.go`

**Interfaces:**
- Consumes: `m.openShort` (Task 1), `deliver`.
- Produces: `screenCommand(text string) bool`: true for `/config`, `/model` (no argument), `/mcp`, `/permissions`, `/agents`, `/hooks`, `/plugin`, `/memory`, `/resume`, `/rewind`, `/status`, `/context`, `/doctor`, `/login`; false for `/model sonnet`, `/compact`, `/clear`, plain text.

- [ ] **Step 1: Write the failing tests.** `TestScreenCommand` with the cases above. `TestScreenCommandOpensWindow`: sending `/config` to a `Bg` agent types it (replaced `transmitFn`) and then opens its short-lived window; sending it to a Terminal agent goes as today.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.** For a background agent, a screen command is typed as today and, when the send is `ok`, the session's short-lived window opens on it (spec D).
- [ ] **Step 4: Run** the tests and the full suite. Expected: PASS.
- [ ] **Step 5: Docs and commit.** D-entry, manual, help. Commit, push, PR.
