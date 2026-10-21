# Ching decision log

Newest first. PLAN.md holds D1-D9 and the v3 scope note; later decisions are recorded here and folded into PLAN.md once the Phase 1 build finishes (the build agent is editing PLAN.md now).

## D78 (2026-10-21): / suggestions anywhere in a message, not only at its start

**Decision (owner):** "Commands only work when they are at the beginning of the conversation but they should also be (as in the terminal) recognized when they are mid-text of a prompt" (`cos/00-Inbox/2026-10-21-fix-for-agent-terminal.md`).

**Built:** `editor.go` `complete`: a `/word` after a space or new line gets suggestions like `@Name` does (D70), the last word of the text. Later in the text only the skills and commands of the folder and the owner are offered, since Claude Code runs its own commands (`/compact`) only at the start of a message. A word with a second `/` is a path (`/Users/x`), not a command, and gets no suggestions at the start either. The text is still typed into the session unchanged, so Claude Code itself runs the skill. Test: `TestEditorSlashSuggestionsMidText`.

**Not built:** a colour for a recognised command inside the sent text.

## D77 (2026-10-20): a / command with a screen of its own, sent to a background agent, opens its screen (no-Terminal phase 4)

**Decision (owner):** "build it" for the no-Terminal design (plan Task 5, spec D).

**Built:** `editor.go` `screenCommand`: `/config`, `/model` with no name, `/mcp`, `/permissions`, `/agents`, `/hooks`, `/plugin`, `/memory`, `/resume`, `/rewind`, `/status`, `/context`, `/doctor`, `/login`. Sent to a background agent, the command is typed as before and then the agent's short-lived window (D74) opens on it, so the screen is not left open on a pty nobody sees. The window opens even when the typing failed (you then type it there). To a Terminal agent nothing changes. D76 is the `/BG` move (plan Task 4), built in parallel.

## D76 (2026-10-20): BG moves a Terminal session to the background; BG ALL moves every idle one (no-Terminal phase 3)

**Decision (owner, no-Terminal design decision 1):** move running Terminal sessions to the background, "idle sessions only, accepting the losses you listed" (plan Task 4). Only the `BG` command, no `B` key, so the desk keys stay free.

**Built (`move.go`):**
- `BG` on the selected Terminal session. Agent Terminal refuses (the command line says why) when the session is busy, shows a menu, has text typed in its box and not sent (`/exit` would join that text), is already in the background, or is not Claude Code. The screen is read fresh, and the session's busy state is read again from `~/.claude/sessions/<pid>.json` right before anything is typed.
- The move: type `/exit` into the tab, wait up to 20 s for the process to end (its session record goes), run `claude --bg --resume <id>` in its folder with its own name and the model, effort and permission mode that its transcript names last (keys.toml's `nw_*` only fill what the transcript doesn't say), then close the tab once only the shell runs in it (`send.js closetab`: the window when it is its only tab, else the shell is told to `exit`, so the other tabs of a window stay). It shows in the list as `bg` with the same id and name.
- `BG ALL` moves every idle Terminal session in turn and reports `moved N to the background · skipped: name (busy), name (menu)`. The moves run one after the other in a command, never in Update.
- A session that does not end within 20 s is left as it is (its tab shows why, for example a question of Claude Code's); a resume that fails reports Claude Code's words and `claude --resume <id>` to open it by hand. Nothing is lost but the running process.

**What a moved session loses (the owner accepted this):** background shells and monitors it started, a running `/loop`, subagents in flight, permissions granted "for this session", its scrollback. The conversation, memory files and its folder stay. Its next turn starts with a cold prompt cache.

**Checked live:** a throwaway `claude --model haiku` Terminal session in this repo moved in 1.6 s. It came back as `bg` with the same id, name and job, its window closed, and its next turn ran on `claude-haiku-5-5` with `bypassPermissions`.

**Not built:** a `B` key; moving opencode sessions or the voice dispatcher.

## D75 (2026-10-20): every start is a background one: FIND r, an empty NW, PC t, the trust question, LOGIN (no-Terminal phase 2)

**Decision (owner):** "build it" for the no-Terminal design with its recommended defaults (plan Task 2): no session gets a Terminal window of its own; trust is answered in a short-lived window (agterm never writes `~/.claude.json`); PC `t` stays as "background session, then its short-lived window at once".

**Built (`start.go`):** FIND `r` runs `claude --bg --resume <id>` in the session's folder, on the model its transcript names when `nw_model` is unset (phase 0: the id, job and name stay). `NW` with an empty box starts the agent with no first message (`nwOpts.args("")` passes no `--`) and opens its screen (D74). PC `t` is PC `b` plus its screen. A start that Claude Code refuses as "not trusted" (NW, FIND `r`) asks `Trust it?`; yes opens `cd <folder> && claude` in a short-lived window, and when that window closes the start runs again (`m.after`). `/LOGIN` opens `claude auth login` in one; `claude auth status` runs at start and every 5 minutes, and logged out replaces the usage in the footer. Gone: `resumeWindow`, `termStart`, `termCommand`. Other starts (PR, RP, @helpers, PC `b`) still report "not trusted" as an error.

## D74 (2026-10-20): g and h on a background agent open its screen in a short-lived window (no-Terminal phase 1)

**Decision (owner):** Claude Code's full screen opens in "a short-lived Terminal window that closes when you leave it, NOT inside agterm's own window" (design `docs/superpowers/specs/2026-10-20-no-terminal-design.md`, decision 2; plan `docs/superpowers/plans/2026-10-20-no-terminal.md`, Task 1).

**Built:** `g` and `h` on a background agent run `claude attach <job>; exit` in a new Terminal window (`bg.go` `shortWindow`, `termShort`) and keep its tty. `Ctrl+Z` ends the attach (phase 0: exit 0, the session keeps running) and so the shell; Terminal keeps the window open by default, so every tick asks `send.js closeidle <tty>`, which closes the window once its tab runs no process and leaves it while anything runs (`←` goes to Claude Code's agent view and keeps the attach running). `g` again raises the open window; a second `g` while it opens does nothing. Before, `g` opened a window that stayed after the attach ended. Tests: `bg_test.go`.

## D73 (2026-10-20): cl starts a background session from a shell and selects it in agterm

**Decision (owner, no-Terminal design decision 3):** sessions started by hand use "a new `cl` shell command that starts a background session and selects it in agterm".

**Built:**
- `bin/cl [name] [prompt...]` runs `claude --bg -n <name>` in the current folder (name left out: the folder's name), with `nw_model`, `nw_effort` and `nw_permission` from `keys.toml` when set (the same words as `NW`; `bypass` becomes `bypassPermissions`), and the prompt after `--` when given. With no prompt the session starts and waits.
- On success it prints the job id and writes `<job> <unix time>` to `~/.agent/terminal/select`. On failure (a folder Claude Code doesn't trust yet, for example) it prints Claude Code's words, exits with its code and writes nothing.
- agterm reads the select file on every tick (`selectfile.go`): it selects the background session with that job once it is listed and deletes the file; an entry older than 30 s, or one it can't read, is deleted without selecting anything, so a start that failed later never moves the selection.
- `install.sh` links `~/.local/bin/cl` (next to `agterm`) to `bin/cl`; `--uninstall` removes that link when it leads to this kit. A `cl` that isn't ours is left alone.
- Plain `claude` still starts a Terminal session as before.

**Not built:** opening the session's screen from `cl` (`g` in agterm does that); a `cl` for other CLIs.

## D72 (2026-10-20): o numbers the links on screen and 1-9 opens one; a plan to drop Terminal windows (design only)

**Decision (owner):** clicking links in agterm does nothing. "If we end up managing all sessions in agent-terminal and have no open terminals, that's completely fine." Trackpad scrolling is not a priority; drag-to-select text must keep working.

**Why clicking did nothing:** the links are OSC 8 hyperlinks (`links.go`), and Terminal.app (2.15 on macOS 26.5) does not know OSC 8. Its binary has URL detection on plain text (data detectors, `_clickedURL`) and OSC 6/7 (the tab's document and folder), but nothing that keeps a link per cell, and the escape is dropped. Its own URL detection needs the whole address on screen and a right-click or cmd+double-click, and fails on an address cut with `…`. So cmd+click works in iTerm2 or Ghostty and never in Terminal.app.

**Built:** `o` (the open-file key) now also numbers the links on screen: each link shows its number (1-9, accent background) on its first character, so no line moves or changes width, and `1`-`9` opens that link in the default browser (`open`). `a`-`i` still open the agent's files; `esc` or any other key cancels. The links are read from the drawn screen (the OSC 8 targets), so every panel with links works without its own code: the conversation, the recap, the PR and PC panels, a zoomed agent. A link cut with `…` opens its whole address. More than 9 links: the lowest 9 (the newest) get a number. The command line says `open: 1-9 the link with that number · a-i a file`. `links.go` `screenLinks`, `numberLinks`; the footers of the desk, PR and PC say `o`.

**Chosen over mouse mode:** Bubble Tea's mouse mode (`tea.WithMouseCellMotion`) would make a click open a link, but then agterm gets every mouse event: drag-to-select and copy in Terminal.app stop working (only with a modifier held, and only in some terminals), and each panel would have to map a click's cell back to the link under it. The keyboard picker costs one key press more, keeps the mouse the terminal's, and works the same in every terminal and over ssh. The OSC 8 links stay, for the terminals that know them.

**Not built:** mouse clicks and trackpad scrolling; links in the list views (they have `enter`). In PC, while a question takes your own answer, `o` stays "own answer" and the links can't be picked.

**Design only (not built):** `docs/superpowers/specs/2026-10-20-no-terminal-design.md`: what still needs a Terminal.app window today and how agterm could take each over (every new session a background one, adopting Terminal sessions), with a phased order. The owner decided: move idle Terminal sessions to the background (`B`, `BG ALL`); Claude Code's full screen opens in "a short-lived Terminal window that closes when you leave it, NOT inside agterm's own window"; a `cl` shell command starts a background session and selects it in agterm. The other questions carry a recommended default; building waits for the owner's approval.

## D71 (2026-10-20): CL opens the changelog

**Decision (owner):** "Something that would be good to have is a \"CL\" command, which opens the changelog".

**Built:**
- `CL` (or `CHANGELOG`) on the command line opens a scrolling page, newest first: a heading per day, one line per decision (`D70`, its title) from `DECISIONS.md`. It has no tab, like FIND, and scrolls like HELP (same keys, `esc` goes back).
- `DECISIONS.md` is read from the kit folder each time CL opens, so a merged decision shows without rebuilding agterm.
- HELP and the manual list it.
- Backticks are dropped from the titles (the page shows no markdown), and the footer of CL and HELP shows the scroll keys (↑↓, pgup pgdown, home end, esc) instead of the desk's.

**Not built:** the Built/Not built text of each decision (the title is the changelog line; `DECISIONS.md` has the rest), a separate CHANGELOG.md to maintain.

## D70 (2026-10-20): @NewName in a message starts a helper session; z zooms on the desk; ↑↓ scroll a third of a page

**Decision (owner):** the owner still tabbed out of agterm to Terminal for two things: to start a new session to hand work to ("the steps to create a new subagent for that main session take too long and I still have to manually connect them by mentioning the session with @"; `/NW` "didn't come to my mind"), and to read one session on its own. "If we end up managing all sessions in agent-terminal and have no open terminals, that's completely fine." Trackpad scrolling is not the focus: "adjust the lines an up/down key scrolls per press to start with". Clicking links and replacing Terminal entirely come later.

**Built:**
- `@Name` anywhere in a message to an agent, where Name is no live session, no `REMOTE` session and no file in the agent's folder: `Enter` starts it first as a background agent (`claude --bg -n Name`, `NW`'s model, effort and mode) in that folder, briefed to wait for the agent, and then sends the message unchanged to the agent, which briefs the helper itself. The box shows `@Name → new background agent in <folder>` in orange before you send. When a start fails nothing is sent and the text stays the agent's draft. `@Name` at the start of a message still goes to that live session (6.18). `broadcast.go` `helpers`, `startHelpers`, `helpersStarted`.
- `z` on the desk shows the selected agent's panel on the full screen (the wall's zoom); `z` or `Esc` goes back.
- The scroll keys move a third of the visible conversation (at least 3 lines) instead of 3 lines, in the agent panel and the side panels.

**Not built:** mouse or trackpad scrolling, clickable links, a replacement for Terminal windows.

## D69 (2026-10-20): AgentTerminalBar re-tiles monitor 2 while agterm is open, and agterm's own window holds no cell (amends D68)

**Decision (owner):** "Currently, the agent-terminal window resizing doesn't work. Why is that happening again? Make sure that whenever agterm is running, the windows on the other screen get resized and ordered correctly. For that, you can even use a checker in the AgentTerminalBar."

**Why it happened again:** D68 fixed the session-start path and was merged to `origin/main` (PR #14), but `~/.claude/agent-terminal` links to the main checkout, and its `main` was still at the commit before D68. The fix was merged, not live. D68 also named two gaps it did not close: a window opened or closed with no session start (and a desktop switched to) is not laid out until the next session start or hotkey; and a window agterm itself sits in, once dragged to the main display, stayed parked with a reserved cell on monitor 2, so 3 agent windows got a 2x2 grid with a hole.

**Built:** `TileTrigger` in `AgentTerminalBar.swift`, run by the 0.5 s window watcher: while agterm is open (a live pid in `~/.agent/terminal/open`) it runs `queue.sh tile auto` once agterm has just opened, and once the set of on-screen Terminal windows has changed and held still for 2 ticks. Tiling moves windows but never changes the set, so it cannot trigger itself; a window you resize by hand stays until the set changes again. `tile auto` is `tile` that honours `queue_tile=off` (the hotkey, plain `tile`, still tiles then). `queue.sh` drops the parked record of agterm's own window (`self_tty` in the open file) before it lays out. Tests: `tests/t_queue.sh` (tile auto, own window), `tests/t_menubar.sh` (`--tile-check`).

**Not built:** the checker does nothing while agterm is closed (the session-start retile covers that case, as before).

## D68 (2026-10-20): the grid on monitor 2 is laid out while agterm is open too (amends D38)

**Decision (owner):** "Sometimes (e.g. now) the resizing of the terminals doesn't happen, tell me why that's the case and fix it."

**Why it happened:** D38 said "agterm open: no automatic moves at all". `queue.sh` enforced that by having `reconcile` return before `flush`, and the grid is laid out in `flush`. So while agterm ran, a new session's `retile` did nothing, and a window opened or closed on monitor 2 never got its cell. "Sometimes" was "while agterm is open". A second, smaller cause, by design: a window on a desktop (Space) not shown now is left out of the grid until that desktop is shown and something retiles.

**Built:** with agterm open, `reconcile` still lays out the grid (and applies a `send_back` move, which the `back` job used to flush on its own). What D38 was about stays the same: nothing comes over to monitor 1 and nothing goes back on its own while agterm is open. The main display is never laid out. Test in `tests/t_queue.sh`.

**Not built:** retiling a desktop when you switch to it (it waits for the next session start, or the `tile` hotkey).

## D67 (2026-10-19): x dismisses an idle agent too

**Decision (owner):** "Currently, I can only dismiss waiting sessions, allow me to also remove idle sessions from the agent-terminal so that I can keep a clean slate if I want to."

**Built:** `x` works on an agent in IDLE as it does on one in INPUT (D50): the row goes, and the agent stays out until it works again or has a newer event. A working agent still can't be dismissed. The session keeps running; `x` does not close it.

## D66 (2026-10-19): on a light terminal background every color takes a darker shade; `background` in keys.toml overrides the terminal's answer

**Decision (owner):** "Anything in the light mode (clear light) terminal, doesn't have enough contrast … this needs to be fixed so it works on light and dark terminals."

**Why:** the palette was made for a dark background. White (231) text, the greys (248, 253) and the light accents nearly vanished on a light one.

**Built (`theme.go`):**
- The greys, the prompt band, the text on a selected row, the reply box and the usage colours are variables now, as the accent already was. `applyTheme` sets them from one of two palettes. The dark palette is the one agterm always had, so a dark terminal looks the same as before.
- The light palette: black (16) for white, 235 for agent text, 240 for grey, 243 for dark (as before), band 253, white text on a selected row, usage 28/94/160. Every text color is 3.9:1 or more against #eeeeee.
- Each theme has a light shade, a 256-color number so it looks the same in a terminal without truecolor (two hex shades fell onto the same 256 color): orange 130, amber 94, green 28, cyan 24, blue 26, violet 92, magenta 127, red 160. Each is at least 4.1:1 against #eeeeee and 4.7:1 against white, and no two are the same.
- `background = "auto" | "dark" | "light"` in keys.toml. Auto (the default, and the fallback for any other value) is the terminal's answer to the background query (`lipgloss.HasDarkBackground`), asked once before the screen starts. A terminal that doesn't answer counts as dark. The THEME picker says which background it draws for and why.

**Not built:** a `THEME light` command (the keys.toml line is enough for now), and a full custom palette.

## D65 (2026-10-19): Kaching is renamed Agent Terminal; the command is `agterm`

**Decision (owner):** the kit is shared as an app a friend can install, branded "The Bloomberg Terminal for agent work". It is called Agent Terminal, the command you type is `agterm` ("a bit shorter"), and the README starts with a quick install. Same approach as D35: new names everywhere, the old ones keep working, text that describes the past keeps the old name.

**What changed:** the link is `~/.claude/agent-terminal` and install.sh writes the hooks under it; the jobs are `org.agent-terminal.watch`, `org.agent-terminal.learn` and `org.agent-terminal.menubar`; the dot is `AgentTerminalBar.app`; the CLI is `agent-terminal-proposals` and the watcher `agent-terminal-watch.sh`; the Raycast scripts are `agent-terminal-next.sh`, `-tile.sh` and `-open.sh`; environment variables are `AGENT_TERMINAL_*`; the Go module is `github.com/clyde/agent-terminal`; the manual is `docs/agent-terminal-manual.md`; the command is `~/.local/bin/agterm` (terminal/build.sh). The `terminal/` folder keeps its name.

**Kept working through the switch:** `~/.claude/kaching` and `~/.claude/ching` stay as more links to the kit (install.sh points them here again; it makes none on a machine that never had them), so hook entries, launchd jobs, pre-push hooks and running sessions that still use an old path keep running the same code. `bin/kaching-proposals`, `bin/kaching-watch.sh` and the D35 wrappers `bin/ching-*` run the new names, and the guard treats `kaching-proposals approve` and `ching-proposals approve` exactly like `agent-terminal-proposals approve`, and the old links like the new one as protected paths. A `KACHING_*` or `CHING_*` variable still counts when its `AGENT_TERMINAL_*` name is unset (lib.sh, the early learner checks, the terminal's `legacyEnv`, the dot); `KACHING_*` wins over `CHING_*`. install.sh replaces the hook entries under either old link with the same entries under the new one (no hook runs twice), replaces the `org.kaching.*` and `org.ching.*` jobs after their successors have loaded, and `--install-menubar` replaces KachingBar and ChingBar. terminal/build.sh turns an old `~/.local/bin/kaching` into a link to `agterm`. A `~/.agent/hotkeys` file that names `ui/raycast/kaching-*.sh` still runs the renamed script. The Raycast scripts and ui.go look for the kit under all three link names.

**Not renamed, on purpose (stored data and history):** the markers of D35 (`<!-- ching:checkpoint -->`, `ching-learn-task:`, `ching.env`, `ching-prepush-marker`), everything under `~/.agent/` (the terminal's state is `~/.agent/terminal/`), this log, the checkpoints, `PLAN.md`, `OPEN-ITEMS-2026-10-05.md`, `PHASE0-RESULTS.md`, `MANUAL-STEPS.md` before D65 and the dated specs and plans. The GitHub repository (`westsoever/ching`) and the local folder (`~/bbq/kaching`) keep their names until this change is merged; renaming them first would leave main and the other worktrees inconsistent. Steps: `MANUAL-STEPS.md`, "2026-10-19: Agent Terminal".

**Needs the owner:** macOS sees AgentTerminalBar as a new app (new bundle id `org.agent-terminal.menubar`), so the Accessibility grant for the voice shortcut must be given again.

## D64 (2026-10-19): opencode sessions sit in the AGENTS list next to Claude Code's

Owner: show the sessions of other CLIs too, opencode first. A running `opencode` TUI (a tty, not `serve` or `run`) is an agent named `oc <session title>`; its session is the newest top-level one in `~/.local/share/opencode/opencode.db` for the process's folder, read with `sqlite3 -readonly`. Working while the session's newest message is not opencode's `idle` marker, else DONE. The right panel shows its conversation from the database and says `· opencode` in the title. Typing into it works as for any Terminal tab; the screen is not read for menus (those parsers are Claude Code's) and `bring here` only raises the tab (the monitor queue places Claude Code windows only). Known limit: two TUIs in one folder, or a TUI that resumed an older session, may be paired with the wrong session.

## D63 (2026-10-19): `THEME` picks the accent color from 8; the choice is the `theme` line of keys.toml

**Decision (user):** "add a /THEME command to the kaching terminal that lets the user pick one of 8 accent colors … The current orange stays the default."

**Why:** the one orange was fixed in the code. The terminal.shop palette (grey, white, one accent) stays; only the accent changes.

**Built (`theme.go`, so the edits to other files stay small):**
- `cOrange` and `cSel` in `render.go` were already the only places that name the accent, and they are variables: a theme reassigns them, so the ~80 drawing sites did not change. The reply box takes the color through `editor.restyle()`.
- 8 themes: orange `#ff5f00` (256-color 202, as before; the default), amber `#d9930d`, green `#2ea043`, cyan `#12a8b8`, blue `#3b82f6`, violet `#8b6cf0`, magenta `#d946b4`, red `#e5484d`. Each is at least 4.3:1 against `#1c1c1c` and 2.2:1 against white (amber is the lowest on white) and carries the black text of a selected row at 5.4:1 or more.
- `THEME` opens a picker: swatch, name and hex per row; the cursor applies the color to the whole screen at once; Enter saves, Esc restores. `THEME green` sets one without the picker. The picker takes all keys, so no preview is left unsaved.
- The choice is `theme = "<id>"` in `keys.toml`. Saving replaces that line, or writes it above the first `[table]`, and keeps the rest of the file (comments included) as it was. A missing, empty or unknown value is orange.

**Not built:** a custom hex value, and a light variant of the whole palette (the greys stay as they are).

## D62 (2026-10-19): NW never guesses its folder; the box says where the folder came from

**Decision (user):** "it often starts in the wrong folder … maybe create some more clarity there", then "go ahead with the changes that you recommended".

**Why:** `NW` took the selected agent's folder and fell back to the home folder with no word (a selected REMOTE session counts as no selection). A bare name tried `~/bbq/<name>` first, then the first agent whose name started with it, and an agent in a linked worktree gave the worktree path. A relative path (`./x`) was an error.

**Built (`nwfolder.go`):**
- `NW` with no folder and no selected agent is an error, not `~`. `NW ~` still works when the home folder is meant.
- `.`, `..`, `./x` and `../x` start at the selected agent's folder.
- A name is matched against the folders of `~/bbq` and the agents together. An exact `~/bbq/<name>` wins; more than one other folder is an error that lists them; an agent in a linked worktree stands for its repo's main checkout.
- The box shows `new background agent in <folder> (<branch>) · <model>`, a line `folder: <how it was found>`, and an orange `⚠` line for the home folder, a folder that is not a git repo, or a linked worktree (the selected agent's own worktree is kept, only flagged).

**Not built:** a folder picker. The error for an ambiguous name lists the choices instead.

## D61 (2026-10-19): the RP list is the 10 repos worked on last, then the others A–Z; the keys only in the footer

**Decision (user):** "Show the top 10 most recent repositories, and then list the remaining repositories, just sorted A to Z", with a line or space that says which part is which; and the keys in the list's title are "already below the overview, so please don't show it twice".

**Built:** "worked on" is the newest of the clone's `.git/logs/HEAD` and its worktrees' (`.git/worktrees/*/logs/HEAD`): commits, checkouts, merges, resets. Not `.git/index`, which a `git status` from the sync check or another session can touch. For a repo with a GitHub twin, its `pushedAt` counts too (the newer wins); a repo on GitHub only has `pushedAt` alone. The parts are headed `MOST RECENT · the 10 worked on last` and, after an empty line, `ALL REPOSITORIES · the others, A–Z`; the top 10 are not listed again below. A new column shows the age. The repos with sync-check findings are no longer first: they are in their place in the order, still orange (and `!` in the narrow list). The list's title is `REPOS` and GitHub's read state only; the keys are in the footer, which got `i copy path`.

## D60 (2026-10-19): `b` in RP lists a repo's branches, `w` its worktrees; `g` opens GitHub

**Decision (user):** "B actually opens all the branches attached to the repository. K lets me view the files of the repository, and G opens the GitHub for it", "see all local and remote branches on each repository. Once I am selecting a branch of the repository, I can, same as for the pull request, review it, merge it, or fix it", so "I always know how many branches are currently alive locally ... specifically when we have worktrees", and "on W to open the worktrees that are attached with the local repository".

**Built:** `branches.go`. The RP list shows each clone's local branches and worktrees (`3 br · 2 wt`), read from `.git` without running git. `b` opens a panel with the local branches and, under `ON ORIGIN ONLY`, the branches on origin with no local branch of that name or upstream. Each row: `⌂` when it is checked out in a worktree, against the default branch (`origin/HEAD`, else main/master: `+ahead −behind`, `merged`, `default`), against its upstream (`not pushed`, `gone`, `↑` to push, `↓` to pull, `pushed`), age and last subject; the default branch first, then those with work the default branch lacks, the newest first. The title counts local, origin-only, not-in-default and worktrees. `w` shows `git worktree list` with each worktree's branch, changed files (`git status`, with `GIT_OPTIONAL_LOCKS=0` so it never takes another session's index lock), and its branch against the default. `1` review, `2` merge, `3` fix and `k` (own task) each start a background agent in the branch's worktree (the clone's folder when it has none) with the branch's state and the task, like `1` and `k` in the PR panel. `f` runs `git fetch --prune origin`; kaching does not fetch by itself. `g` (and Option+Enter) is what `b` was: the repo, or in the panel the branch, on GitHub. A repo on GitHub only lists its branch names from `gh api`; the actions need a clone.

**Why merge is an agent here, not kaching itself (unlike `2` in PR, D55):** a local branch has no checks and no mergeability from GitHub, it can conflict, and the main checkout often has another session's uncommitted work. The agent gets the owner's merge rules in its task (fetch first, no force push, keep both sides on a conflict, check nothing from origin was dropped). `2` refuses the default branch and a branch with nothing the default branch lacks.

## D59 (2026-10-19): REMOTE leaves out the sessions that run on this Mac

**Decision (user):** every new Claude terminal gets a Remote Control connection, so each one showed twice, as an agent and under REMOTE: "I would like to only see the local sessions", either a check that hides it or no duplicates.

**Built:** Claude Code writes `bridgeSessionId` into `~/.claude/sessions/<pid>.json` for a terminal with a Remote Control connection. `remoteLocal` (remote.go) collects those ids from the processes that are still alive (`kill -0`), and `dropLocal` removes them from the REMOTE list. Checked against the live list: all 6 active remote sessions were windows of this Mac, so REMOTE is empty here. A session on another Mac has no pid file here and stays. If a local terminal quits while its connection is still up, it shows under REMOTE until the connection drops, which is correct: there is no window left.

## D58 (2026-10-19): a REMOTE section below DONE lists the active remote sessions; messages go out through the CLI

**Decision (user):** "add any remote sessions that are running and show them below the DONE in the left sidebar so I can directly interact with them from kaching"; then "it should run with auto-discover and only show active sessions so we don't lose overview"; then "Priority are the connected sessions". The owner approved one test message to `cos-worker`.

**Findings:** the `claude` CLI has no command that lists them. The list claude.ai/code shows is `GET https://api.anthropic.com/v1/sessions?beta=true` with the owner's own Claude login (keychain item `Claude Code-credentials`), `anthropic-beta: ccr-byoc-2025-07-29` and `x-organization-uuid` from `~/.claude.json`. It is undocumented and may change. These are Remote Control sessions (`environment_kind: bridge`), not cloud containers. Reading or sending through `/v1/sessions/<id>/events` is refused (403 `elevated session requires a trusted device`); that gate is server side and is not worked around. `claude -p "…" --cloud <id>` is the CLI's own way to message a session and worked: "Sent to cloud session", and the session's `updated_at` moved at that moment.

**Built:** `remote.go`. Every 30 s (and after a send) kaching reads the list and keeps the sessions that are connected and not archived, the last updated first. They show under a `REMOTE` header below DONE (`◇` mark; `working`, `reply` when it answered and is unread, `asks`, `idle`; `reply` and `asks` are orange). `j`/`l` walk from the agents into the section on the desk (not the wall). The right side shows model, context used and the last `post_turn_summary`. `k` writes a message, sent with `claude -p … --cloud <id>` run outside any project, 120 s limit, a text that starts with `-` gets a space in front. Enter opens `https://claude.ai/code/<id>` in the default browser to read the reply. A failed read keeps the last list and shows the error in the header line. The token goes to api.anthropic.com only and is never logged or shown.

**Not built, and why:** showing a remote session's messages, and typing from kaching without the CLI. Both need this Mac to be a trusted device for the account, which only the owner can do. A terminal opened with `claude --cloud <id>` was not used: it would not give kaching the session's state.

## D57 (2026-10-19): links in the text are OSC 8 hyperlinks; the usage bar needs the statusline writer

**Decision (user):** "make links in the chat clickable with cmd+click and then open in the default browser", and "the local app doesn't show the app usage in the bottom corner (it only shows 'claude usage: no statusline reading yet')".

**Why (usage):** `~/.claude/statusline-command.sh` had lost the lines that write `~/.agent/usage/<session id>.json`, so the directory did not exist and `loadUsage` found nothing. The lines are back (they write `.rate_limits` only when it changes, through a temp file and `mv`). That script is outside this repo; the manual now says what to check.

**Built (links):** `row` renders every `http(s)://` URL in a seg as an OSC 8 hyperlink (`links.go`), so the terminal opens it with cmd+click in the default browser. The target is the whole URL even when the row cuts it with `…` (the `…` is inside the link), and `wrap` no longer hard-cuts a URL into two rows, which would have broken the link. Trailing `.,;:!?` and an unmatched `)` are not part of the URL. Rows keep their exact width: the escape codes add no cells. kaching sets no mouse mode, so the terminal's own cmd+click is what opens the link; the browser is whatever macOS has as default.

## D56 (2026-10-19): `3` in PR closes at once, with no agent

**Decision (user):** "Currently kaching doesn't have the "close" function ... Implement the function in the kaching app so with 3 or similar, I can close a PR".

**Built:** `3` in the PR panel runs `gh pr close <url>` from kaching itself, outside any local clone, like `2` (D55). No confirm step, as for merge: the owner wants one key, and `gh pr reopen` or the GitHub button undoes it. Unlike merge, it does not wait for the panel to load and does not refuse drafts, conflicts or failed checks (those are the usual reasons to close). A gh refusal shows in the status line as `not closed: <ref>: gh pr close: …`. A closed pull request leaves the list at once. `prQuick` got an `act` field (`merge`, `close`, or empty for an agent comment) instead of reading an empty text as "merge".

## D55 (2026-10-18): `2` in PR merges at once, with no agent

**Decision (user):** "Currently, if I click K and then 2 to merge it, an agent gets sent off to merge it. I would want this to become just a terminal action where I merge it right away, without an agent merging it."

**Built:** `2` in the PR panel runs `gh pr merge <url> --<method> --match-head-commit <sha>` from kaching itself, outside any local clone. The commit is the head that the panel read (`headRefOid`), so a push after that makes GitHub refuse. The method is a merge commit when the repo allows one, else squash, else rebase (`gh repo view`). The branch is kept. Kaching refuses before it calls gh, with the reason in the status line, when the panel has not loaded, the pull request is a draft, it has conflicts, or checks failed or still run (the same rule the merge agent had). A gh refusal shows in the status line. A merged pull request leaves the list at once. `1` still starts a review agent. No confirm step: the owner wants one key.

## D54 (2026-10-18): HELP scrolls and starts with what is new

**Decision (user):** "Add them to the HELP section in the app so I have an overview of what I can now do with kaching".

**Why:** the help page was 80 to 90 lines and the body shows about 55 on a 62-row terminal, so its last third (Wall, the fixed messages with their space keys, the keys.toml note) could not be seen at all, and anything added would have been cut off too.

**Built:** HELP scrolls (up and down 3 lines, pgup and pgdown a page, home, end; the title says so and "more below") and opens at the top each time. A "New on 2026-10-18" block follows the view codes: the space leader and `space space` (D53), `x` (D50), the `/NW` defaults read from keys.toml (D51), `b` and `t` in PC (D52), `i` in RP (D49), the DONE section (D47). The `x` line now says it does not close the session. Add a block like this for the next batch and drop the old one when it stops being news.

## D53 (2026-10-18): space waits for its second key; `space space` jumps to the longest INPUT

**Decision (user):** the `space m` and `space c` messages "don't wait too long, so I have to input the m too quickly. Since the space overlaps with opening the most recent session, that can become very tricky - maybe we change the hotkey for that but I'd like to have a longer waiting time or just waiting for input until I put the e.g. m or Esc to abort the command".

**Why:** space alone was "the INPUT agent that has waited the longest", so kaching could only tell it from the start of `space m` by a 450 ms timer. Too slow a second key and the selection jumped.

**Built:** space starts the leader and waits with no timer. The status line lists the keys behind it (`space… m merge · c commit · w new worktree · space longest input · esc cancel`). Esc cancels, a key that is bound to nothing ends it with a message and is not passed on (so `space x` can never dismiss), a `space <k>` reply is sent. The jump to the longest INPUT agent is `space space`; `next_waiting = " "` in keys.toml now means that, and any other key there is a direct key with no leader. The leader starts only in the desk and the wall; before, it also started in the other views and moved the selection after the timer.

## D52 (2026-10-18): PC hands an issue to an agent with the owner's permissions (b, t, @Name)

**Decision (user):** the request itself is not in the logs I could search. The owner tried it on 2026-10-18: "pressing b has now moved it to the inbox and is working on it".

**Built (0cd5b50):** in the PC view `b` hands the selected issue to a new background agent, `t` to a new session in a Terminal window, and a box text that starts with `@Name` to a session that already runs. The agent gets a short first message and a briefing file in `~/.agent/terminal/handoff/` (description, thread, the request that waits, the folder from the issue's `repo:` line, and how to report through Paperclip's local API: one comment, status `in_review`, never `done`). It starts with the model, effort and mode of `/NW` (D51).

## D51 (2026-10-18): agents kaching starts run Sonnet 5.5 at high effort

**Decision (user):** "which model are the sessions running when i activate them with agent or background? - for me it shows opus but the standard should be sonnet 5.5 high".

**Why:** `nw_model` and `nw_effort` in keys.toml were empty, so every agent started from kaching (`/NW`, the PR comment, `b` and `t` in PC) took Claude Code's own default, which is `opus[1m]` at `xhigh` from `~/.claude/settings.json`.

**Built:** a new keys.toml has `nw_model = "claude-sonnet-5-5"` and `nw_effort = "high"`; the owner's keys.toml has the same two lines. Words after `/NW` still win, and an empty value still leaves it to Claude Code. `~/.claude/settings.json` is untouched, so sessions the owner starts by hand stay on Opus.

## D50 (2026-10-18): x takes a waiting agent out of the queue, background agents too

**Decision (user):** "this session is still sitting at INPUT, even though it has been completed (pressing x should actually remove it from this view - so please fix that)".

**Why:** `x` only called `queue.sh dismiss`, which forgets the window of a Terminal tab. A background agent has no tab, so it answered `Unknown session` and nothing changed; and for a tab, the row stayed anyway because the sections come from the agent's state, not from the window queue.

**Built:** `x` writes the session and the time to `~/.agent/terminal/dismissed.json` and takes the row out at once. The agent stays out while it is waiting and its last event is not newer than the dismissal; when it works again or finishes another turn it is listed again. A Terminal tab also leaves the window queue as before. Not yet changed: why the agent that prompted this sat in INPUT. Its last turn said nothing was left, but a bullet in it read "It's waiting for you to review it", which `bin/ask-check.sh` took for a request (D41).

## D49 (2026-10-18): `i` in RP copies a path

**Decision (user):** "One hotkey to create is 'i' to copy the file path" (after trying the PR and RP views).

**Built:** in `RP`, `i` copies the full path of the repo's folder; in the folder panel it copies the selected file or folder (`..` gives the folder the panel shows). A repo without a clone, and its folders on GitHub, give the GitHub address instead. The status line says what was copied. Not added to the PR panel: its files are text lines, not paths on this Mac.

## D48 (2026-10-18): the terminal finds a transcript that moved with its session

**Decision (user):** "I don't see any messages of the background agent ... Maybe fix that first to actually have the text of the chat from this background agent show up here as well."

**Why:** meta `transcript=` is written when the session starts. A session that changes folder (EnterWorktree, cd) gets its transcript under the new folder's project dir, so the recorded file was gone and the right panel showed an empty chat. Every background session that works in a worktree was affected.

**Built:** `findTranscript` keeps the recorded path while the file exists, else tries the current cwd's project dir, else any `~/.claude/projects/*/<sid>.jsonl`. The bash hooks still record the start path; only the terminal resolves it.

## D47 (2026-10-18): kaching lists finished agents with nothing left under DONE (amends D41)

**Decision (user):** "There should be another section for the agents on the left, that is DONE - it puts a session there when it has finished its task and is just completed and there's nothing left to wait for."

**Built:** the queue has five sections: INPUT, WAITING, WORKING, IDLE, DONE. A session whose turn ended as `done` is DONE when its checkpoint (`STATE.md`, in the repo's `.agent` with a GOAL.md, else the session folder) has no `next_action` and no `blocker` (empty, `none`, `(none)` and `none.` count as empty) and its `NEXT.md` is empty or missing. That is the test `kaching-watch.sh` already uses to leave a finished session alone. A finished session with something open stays in WAITING. DONE is last and newest first, so what the owner can ignore stays out of the way; a family sits in its most urgent member's section. `Group()` is unchanged, so DONE agents still count as waiting in the tab badge and `x` can dismiss them.

**Also (user):** "even when empty, keep the INPUT and other sections there - just empty but so that I can more easily see if there's nothing that needs input." All five headers are always drawn; the "no live agents" line in the queue is gone (the right panel keeps its own).

## D46 (2026-10-18): RP becomes a repo list you can open and browse

**Decision (user):** "For the RP, the repositories or repos here, I would love to also be able to cycle through them or switch through them. When I hit Enter, I want the local folder to open. If there's no local folder, then there should be a question saying, 'No local folder. Do you want to open it in GitHub?' Then, with a confirmation, I can confirm it again. Also, find another way, maybe Shift+Enter, where I can directly open the repository on the website. When I click K on it, it shouldn't open the repository locally, but it should open it in the side panel and just show the folder structure of it. Then I can cycle through the folder structure, so I can actually go through the folders. Meaning, just naturally navigating with K, I open the folder. For example (and on a file, opens the file)"

**Built:** `RP` lists the git clones one level under `~/bbq` and `~` (not the folders macOS guards, such as `~/Library`), the repos in `~/.agent-repos` and the sync check's repos, then the GitHub repos of `westsoever` and `technobbq` that have no clone here (`gh repo list --no-archived`, read in the background each time the view opens; a failed read keeps the last list and shows its error). Each line: name, `owner/name`, folder or `github only`, and the sync check's `needs:` in orange; repos with findings first, in the sync check's order. `j`/`l` move; Enter opens the folder, and for a GitHub-only repo asks "No local folder. Open it on GitHub?" in the command line (Enter or `y` opens, any other key does not). `b` and Option+Enter open the repo on GitHub. Shift+Enter does too where the terminal sends it apart from Enter (CSI u, or xterm's modifyOtherKeys); Terminal.app sends a plain Return for it, and Bubble Tea v1 has no shift+enter key, so there it acts as Enter. `k` opens a side panel with the repo's folders (folders first, `.git` hidden): `k` goes into a folder or opens a file with `open_cmd`, `..`/`h`/Backspace go up, Enter shows it in Finder, `b` opens that folder on GitHub, Esc closes the panel (a second Esc goes to the desk). A GitHub-only repo's panel reads its folders with `gh api repos/o/n/contents`, and a file opens on GitHub. No key in RP acts on the agent selected behind it.

## D45 (2026-10-18): A pull request opens on the right in kaching, and a comment on it starts an agent (amends D44)

**Decision (user):** "When I press K, I would want the side panel to open that holds the content of the pull request … I can press again on the side panel, and then I can comment on this … once I hit Enter, it gets sent off to a new session that works through this pull request."

**Built:** in `PR`, `k` opens the selected pull request on the right (`gh pr view`: branches, size, conflicts, checks, review state, description, files, comments and reviews), starting at the top; `j`/`l` keep moving and the panel follows; `↑`/`↓` scroll. `k` again opens the comment box: Enter starts a background agent (`claude --bg`, as `/NW`) in the repo's local clone (found by its origin under `~/bbq` and `~`; home when there is none) with the pull request, its branch and the comment as the task. The agent works in its own worktree and reports back; it comments on GitHub only when asked. `1` review it and `2` merge it are ready-made comments. Approving is left to the agent's report and the owner: GitHub does not let the owner approve their own pull requests, which most of these are. Number keys in `PR` never answer an agent's menu. `esc` closes the box, then the panel, then goes to the desk.

## D44 (2026-10-18): kaching gets a PR view for pull requests; proposals move to PO; the AG tab goes (amends D33)

**Decision (user):** "Create the PR section here for pull requests. Make me access it with /pr, call it Pull Requests, and rename the Proposals one. Maybe make it PO instead. For now, you can remove or hide the AG Agents section. I'm not using it, and it's not really helpful because it does exactly the same as the inbox."

**Built:** `PR` (pull requests) lists the open GitHub pull requests that involve the owner, from `gh search prs --state open --involves @me --sort updated`, the last updated first; Enter opens one in the browser. It is read every 30 s while the view is open and every 2 min for the tab's count (GitHub's search quota is 30 a minute); a failed read keeps the last list and shows its error above it, and the selection stays on its pull request when the order changes. Proposals keep their keys under `PO`. The `AG` tab and code are gone; the wall is still there behind `W` (and `/W`), so it can come back. A tab too narrow for its label now keeps its count (`PR  10`) instead of dropping to the code alone.

## D43 (2026-10-17): A prompt sends a window back, wherever it was prompted (amends D38, D42)

**Decision (user):** "If I drag it over or bring it over manually with H, it should stay here for sure, but once I have prompted it either within its own session or through kaching, it should be moved back."

**Built:** `queue.sh back` (the UserPromptSubmit hook) now sends the window home too when it was brought over by hand (a drag, `show` / `h`), and it does so while kaching is open. Before, only a window the queue had parked itself went back, and with kaching open nothing moved. Other sessions' prompts and events still leave it alone, and it stays while another tab of the same window waits. kaching's `queue.sh return` after an answer (D42) stays, for menu answers, which fire no prompt hook. Shared code: `send_back` in queue.sh.

## D42 (2026-10-17): Answering an agent from kaching sends its window back to monitor 2 (amends D38)

**Decision (user):** "once I kick off the session here within kaching, even though it's on monitor 1, it doesn't get moved back to monitor 2 after I hit confirm. Please fix that." D38 kept a window that was dragged (or brought with `h`) on monitor 1 until it was dragged back, and with kaching open nothing moves at all (D37).

**Built:** after kaching delivers an answer (a reply, a numbered answer, Enter in a menu, a typed menu answer), it runs `queue.sh return SESSION_ID`. A window the queue moved to the main display (its own event, `show`/`h`, or a drag) goes back to exactly its cell, also while kaching is open, because it is the owner's own action. It stays when another tab of the same window still waits. Moving inside a menu (←/→/Tab) is no answer. Typing in the window itself still leaves it on monitor 1 (D38), since bringing it there to type in it is what `h` is for.

## D41 (2026-10-17): kaching splits waiting agents into INPUT and WAITING, and shows what each one asks

**Decision (user):** waiting, working and idle are sorted right, but inside waiting the owner can't tell who needs an answer from who just finished. The queue now has four sections: INPUT (asked you something, or blocked), WAITING (done), WORKING, IDLE. Each INPUT agent shows what it asks on a line under its name.

**Why:** a turn counted as "needs input" only when its last line ended in "?". Agents that asked in an earlier line, or asked without a question mark ("tell me and I'll check", "I left the live check to you", "let me know if you want X"), showed as done and sat among the finished reports.

**Built:** `bin/ask-check.sh` reads the last 6 lines of the turn, leaving out code blocks and headings. A real question there (not a "?" inside code or a link), or a request for the owner to do or decide something, makes the turn input. The matching sentence is the ask. `stop-check.sh` uses it for the state, the notification text and the new meta `ask=`. A heuristic, so some misses remain; a Haiku pass was left out because it would use the learner's daily token cap on every stop. INPUT also holds agents whose screen shows a menu right now (agent.terminal's `Asking` flag: a permission prompt, an AskUserQuestion, a plan approval), even while Claude Code calls them busy. The two complement each other: the screen catches menus, ask-check catches questions written as text. Group() is unchanged; INPUT is a display and sort split of the waiting group.

## D40 (2026-10-17): Dispatcher v2: always listening, a voice shortcut, one routing list

**Decision (user):** after the first spoken run of 4.3 failed on setup (the dispatcher could not match folder names to message names, guessed STATE.md paths, used `--inbox` for a one-session question, and ended its turn after each answer), the owner asked for: (1) an always-listening dispatcher that is woken by a shortcut in KachingBar, Right Control + Left Option, and hands what was said to the session named or to the open one; (2) the joined session list in Kaching; (3) clear rules; (4) a Haiku vs Sonnet comparison. Built as: `dash.sh --route` (one TSV line per live session: name, message_to, status, state, state_dir, notes, focus, branch; the gate allows it alone). VoiceShortcut.swift: a tap of both keys with no other key in between, so D39's Ctrl+Option+N/T/K never trigger it (Hotkeys.swift cancels the chord). It records the front Terminal tab in `~/.agent/dispatcher/focus`, then starts the dispatcher, types `[shortcut] listen` into it, or only cues when it is busy. It needs Accessibility, which must be re-granted after each rebuild (ad-hoc signature). dispatcher/AGENTS.md: numbered rules; every turn ends with a listen; silent re-listens; stops after 5 empty listens (about 10 min) or "stop"; an unnamed instruction goes to the focused tab. launch.sh turns off MCP auto-backgrounding (the first run lost a 120 s listen to it). dispatcher/eval.sh runs offline cases against fixtures on either model (both 6/6 on 2026-10-17: Haiku 4.6 to 9.1 s per turn, Sonnet 5.0 to 7.4 s). The spoken run on both models is still open (MANUAL-STEPS 4.3).

## D39 (2026-10-17): Global hotkeys from the menu bar dot instead of Raycast

**Decision (user):** "make it work". The Raycast 2.8 script folder could not be added by the owner, and it cannot be added from outside either: Raycast keeps its settings in an encrypted database, and driving its settings window by synthetic clicks would type into whatever the owner is writing. So KachingBar registers the hotkeys itself, with Carbon's RegisterEventHotKey, which needs no Accessibility or Input Monitoring permission. Defaults: Ctrl+Option+N next waiting agent, Ctrl+Option+T tile, Ctrl+Option+K kaching. Each runs the same ui/raycast script, and the bindings live in one file, `~/.agent/hotkeys`. The scripts still work from Raycast. This amends agent.terminal's "Raycast stays the global hotkey layer"; kaching's in-terminal keys.toml is unchanged. build.sh now compiles every ui/menubar/*.swift and links Carbon. Info.plist carries NSAppleEventsUsageDescription for the one-time "control Terminal" prompt.

## D38 (2026-10-17): Windows move on their own only when kaching is closed, and you can drag them (closes D37's open part)

**Decisions (user):**
- **kaching open:** no automatic moves at all. The waiting and tabs records are still kept for kaching.
- **kaching closed:** a waiting window still comes to the main display, but only on its own session's event (done, input, blocked, ready). The idle reminder never moves a window, and windows that started waiting while kaching was open never come over as a batch. That batch is what emptied monitor 2 under D34.
- **Drags:** dragging a window from monitor 2 to monitor 1 gives it the park frame and keeps its grid cell reserved. Dragging it back puts it exactly in that cell. Any window dragged onto monitor 2 joins the grid. A window you dragged over stays until you drag it back; answering it doesn't send it back.

**Built:** the menu bar app (KachingBar) polls the window server for Terminal frames twice a second, which needs no Accessibility or Screen Recording permission. Once a window has landed on another display, with the mouse up and the frame still, it calls `queue.sh dragged ID X Y W H`. `queue.sh` decides what to do. Moves the queue made itself are reported too, and ignored. `next` now raises the oldest waiting tab wherever its window is, and `show SESSION_ID` acts like a drag onto monitor 1.

## D37 (2026-10-17): kaching never moves windows; the queue stops moving them while kaching runs (amends D34)

**Decision (user):** while kaching is open, Terminal windows don't move: kaching's waiting list is the inbox, so the "one window comes over to say it needs input" idea (D29, D34) is redundant there. Windows should only resize when the owner moves one between displays by hand (snap into the grid on monitor 2, the park frame on monitor 1); that part belongs to the monitor queue (chingSorter) and isn't built yet. Opening, quitting or reloading kaching must never touch a Terminal window or a session. kaching never starts or closes sessions.

**Why now:** quitting kaching called `queue.sh show`, which put the queue back in normal mode; every idle session counts as waiting, so five agent windows jumped onto monitor 1 into the same park frame at once and monitor 2 emptied, which looked like the sessions had closed (they hadn't; no session ended). Separately, in single mode the agent selected in kaching stayed on monitor 1 after the owner answered it, because the rule kept "selected" windows regardless of waiting.

**Done:** kaching no longer calls `queue.sh show` on selection or quit. While kaching is open, `queue.sh` reconcile wants no window on the main display: nothing comes over, the selection moves nothing, and a window parked before kaching opened goes back to its cell (tests/t_queue.sh). Still open: resizing a window the owner drags between displays (chingSorter), and whether the queue should move windows at all while kaching is closed.

## D36 (2026-10-17): A larger park frame (amends D32)

**Decision (user):** the frame for a waiting window on the main display is about 50% wider and 20% taller: 690 x 948, top-left still at 320,70 (`queue_park_frame` default 320,70,690,948). It ends at y 1018, inside the main display's usable area above the Dock.

## D35 (2026-10-17): Ching is renamed Kaching

**Decision (user):** the kit is called Kaching, like an old cash register closing. The agent terminal (D33) already carried the name; now the whole kit does.

**What changed:** the link is `~/.claude/kaching` and install.sh writes the hooks under it; the jobs are `org.kaching.watch`, `org.kaching.learn` and `org.kaching.menubar`; the dot is `KachingBar.app`; the CLI is `kaching-proposals` and the watcher `kaching-watch.sh`; the Raycast scripts are `kaching-next.sh`, `kaching-tile.sh` and `kaching-open.sh`; environment variables are `KACHING_*`; the repo folder becomes `~/bbq/kaching`. Text that describes the past (this log, the checkpoints, dated specs and plans) keeps the old name.

**Kept working through the switch:** `~/.claude/ching` stays a second link to the kit (install.sh creates it, or points it here again), so hook entries, launchd jobs and running sessions that still use the old path keep running the same code. `bin/ching-proposals` and `bin/ching-watch.sh` are wrappers around the new names, and the guard treats `ching-proposals approve` exactly like `kaching-proposals approve`. A `CHING_*` variable still counts when its `KACHING_*` name is unset (lib.sh, the early learner checks, KachingBar). install.sh replaces the hook entries under the old link with the same entries under the new one (no hook runs twice), and replaces the `org.ching.*` jobs after their successors have loaded; `--install-menubar` replaces ChingBar.

**Not renamed, on purpose (stored data):** the `<!-- ching:checkpoint -->` and `<!-- ching:snapshot -->` blocks in STATE.md files, the `ching-learn-task:` marker the learner writes into its prompts and filters transcripts by, the `ching-learn` name on learner events, `~/.agent/defaults/ching.env`, `ching-prepush-marker` in installed pre-push hooks, and everything under `~/.agent/`. The GitHub repository keeps its name. Session names such as chingSorter or Ching01 are the owner's.

## D34 (2026-10-17): The monitor queue serves kaching: one agent at a time while it is open

**Decision (owner, through the agent terminal design, D33):** while kaching runs, the main display shows kaching plus at most one agent window: the one kaching has selected, else the head of the queue. The others keep their waiting records but stay in their cells; answering one brings the next, in the background, never taking focus. With kaching closed, the D29-D32 behaviour applies. Built as one reconcile step that every queue change runs: it works out which windows belong on the main display and moves only the difference. Also for kaching: a tabs map per session, the session id and kind in each waiting record, `queue.sh show` and `queue.sh dismiss`. Not built here: sending text into a tab (kaching's terminal/send.js) and any key layer (Raycast stays the global hotkey layer).

## D33 (2026-10-17): The agent terminal (kaching)

**Decision (user):** one keyboard-only screen for every agent, in the spirit of the Bloomberg Terminal and in the look of `ssh terminal.shop`: near-black, grey text, white for what's selected, one orange accent. Desk (queue + selected agent) and a command line of codes (IN AG FL RP PR PC) are the home screen; the wall shows every agent as tiles sized to the window; the PC view reads Paperclip, which is a source and not the backend. Replies are typed in the terminal and delivered into the agent's own Terminal.app tab; only Terminal.app sessions take replies. Numbers answer an agent's options; pre-written replies (fix it, review the code, check in on the other agents, `/merge`, commit, new worktree) sit near the home row and live in `~/.agent/terminal/keys.toml`, which the owner edits. Each session merges itself with the global `merge` skill (`~/.agents/skills/merge`); a dedicated merge agent only if parallel merges become a problem. While the terminal is open, monitor 1 holds it plus one agent window at a time (chingSorter's queue, D34+). The terminal has no AI of its own: it reads files and types what the owner chose. Design: `docs/superpowers/specs/2026-10-17-agent-terminal-design.md`.

**Found while building it:** Terminal's `do script` types into a background tab without focus, but Claude Code treats a long burst as a paste and swallows its newline, so Enter is pressed separately (a key event posted to Terminal's process, ~0.1 s window flicker, the fallback the owner accepted) and `send.js` checks that the text left the input box, retrying Enter. A menu (AskUserQuestion) is answered with the number key alone. Session names come from Claude Code's own `~/.claude/sessions/<pid>.json`, joined with Ching's `meta`.

## D32 (2026-10-17): A fixed frame for waiting windows on the main display (amends D31)

**Decision (user):** a window that comes to the main display takes one fixed frame: top-left 320,70 and bottom-right 780,860 on the owner's screen, so 460 x 790 (`queue_park_frame`, default 320,70,460,790). All waiting windows share it as a stack. Going back still restores the exact cell. Found while building it: Terminal sets a window's y from the top of the display the window is on, but reports it from the top of the main display, so `queue-term.js move` corrects for that. A second display also has its own menu bar that macOS does not take off its visible frame, so the helper takes it off.

## D31 (2026-10-17): The grid is a map of where each project lives (amends D30)

**Decision (user):** moving never resizes a window, on either display, and the main display is never laid out. The grid on the second display is sized by all its agent windows, waiting ones included: a waiting window's cell stays empty while it is away, and it comes back to exactly that cell, so the layout is a visual guide to where each project is. When the count changes (a window opened or closed), each window takes the free cell nearest to where it was.

## D30 (2026-10-17): Tiling and no focus stealing for the monitor queue

**Decision (user):** a window that arrives must never take the focus from the session the owner is working in. Each display tiles its Terminal windows by count (2 side by side, 3 in columns, 4 as 2x2), so arrivals sit beside the owner's work instead of on top of it. One window per project, with its subtasks as tabs. Desktops (Spaces) stay out: windows on a hidden desktop are not moved by tiling. A window cannot be sent back to a particular desktop (no public API), so it goes to the desktop shown on its old display.

## D29 (2026-10-17): Monitor queue for waiting agents

**Decision (user):** waiting agents come to the main display, built into Ching. The owner works on the main display and parks agent Terminals on the second one. A session that finishes or needs input moves its window to the main display; prompting it sends the window back. Native macOS Spaces were considered and rejected: macOS has no supported way to move a Space to another display (yabai needs SIP partly off; AeroSpace replaces the window manager). The main display itself is the queue instead, with a "next waiting agent" hotkey (Raycast script command, `ui/raycast`). A lead agent and its workers are grouped as tabs of one window and move together.

## D28 (2026-10-17): Spot-check policy, auto-title removed, menu bar dot, overnight autonomy

**Decisions (user):**
- **Spot-check:** the owner reviewed items 1-10 of the label spot-check. Items 11-21 and policy questions A-C were left blank and are read as "keep the agent's label".
  - Merge or push instructions that carry "keep everything / don't delete progress" count as corrections, even when stated up front.
  - Re-confirming an instruction the assistant should already have acted on ("then let's merge it") is a correction.
  - Product feedback stays "not".
  - `templates/learn-prompts/corrections.md` and `~/.agent/proposals/.eval/labels.jsonl` are updated (10 items `owner_reviewed`).
  - New patterns the owner named: merge right away when asked and report after; notice when the build drifts from what was asked; build in soii-dev and sync to soiisauce on release (cos is only an install); run migrations yourself.
- **Session auto-title skill:** removed (moved to the Trash on 2026-10-17). Its SessionEnd hook caused the 2026-10-05 registry flood: each titling run was a session that triggered another.
- **Menu bar dot:** a small dot in the macOS menu bar shows whether Ching is running. Later it will show transcripts and push notifications for sessions that need input. It is a separate macOS app (`ui/menubar`), not a Claude Code mod, so D23 still holds.
- **Overnight (2026-10-17 ~01:45):** "Keep driving the sessions until everything is done. Take decisions for yourself and the other agents." The orchestrator session (ChingRollOut) made the remaining build and install calls under this.

## D27 (2026-10-16): The learner stays out of claude-mem; claude-mem is to be replaced in the long run

**Decision (user):**
- Yes to Phase 6 question 8. The learner's runs are kept out of claude-mem in two ways: `CLAUDE_MEM_INTERNAL=1` in the `org.ching.learn` job, and `~/.agent/proposals/.work` in `CLAUDE_MEM_EXCLUDED_PROJECTS` (`~/.claude-mem/settings.json`, which `install.sh` backs up first).
- Long-run direction: **replace claude-mem.** Ching's own data (events, checkpoints, transcripts, the learner's proposals and, later, lessons) should take over what claude-mem does today.

**Consequences:** nothing in Ching may come to depend on claude-mem. Its data can be read as an input while it is still installed, but never required. Replacing it is a later item, not part of stage 6a.

## D26 (2026-10-16): Build Phase 6 stage 6a now (amends D16)

**Decision (user):** yes to Phase 6 question 9. Stage 6a is built now, before the pilot metrics: the contracts, the extractor and report, the correction detector, the skills miner and the plumbing. The reason to wait (design on real data) no longer holds, because 6a reads transcripts and 221 real sessions already exist. Stage 6b (lessons) stays unbuilt (question 5).

**Defaults for questions 1-6:** the spec's recommendations are used as starting values, and the weekly report can correct them:
- nightly run at 05:30, weekly run on Monday at 05:30;
- `LEARN_MODEL_CLASSIFY=haiku`, `LEARN_MODEL_DRAFT=sonnet`, `LEARN_TOKEN_CAP=200000`;
- the learner assigns `task_type`, and a session's own line wins when present;
- rule target: a single repo's `AGENTS.md`, or global when the pattern spans 2+ places;
- `LEARN_SKILL_MAX=3`.

**Question 7:** the labelled set is rebuilt during step 0, and the owner spot-checks about 20 labels. **Question 10:** done the same evening. The 4,615 empty `/private/tmp` registry entries from 2026-10-05 were moved to `~/.agent/archive/registry-private-tmp-2026-10-05/`, with a tarball next to it: 18 MB on disk, 0.9 MB of content. The test that wrote them still has to be found and fixed.

## D25 (2026-10-16): Voice pass line 8 s; no `/voice` fallback

**Decision (user):**
- The 0.6 speed pass line is **8 seconds** from the end of the sentence to the first spoken word, picked before any dispatcher measurement.
- Claude Code's `/voice` is **not** used as a fallback. The user dictates with Wispr Flow, their own tool outside Ching.

**Consequences:** `docs/voice.md` keeps the `/voice` notes for reference only, marked unused. D3's "native `/voice` stays as a fallback" no longer holds. Ching does not install, configure or depend on Wispr Flow. Like `/voice`, Wispr Flow transcribes off the machine, so D5 (local audio) covers only Ching's own voice path: VoiceMode, `/dash` and the dispatcher.

## D24 (2026-10-16): Guard on, push rule off

**Decision (user):** The guard is reinstalled with every protection except the push-to-main release token. On 2026-10-10 the user had removed `guard.sh` from `~/.claude/settings.json` entirely, because rule 3 (a push to main needs a release token, plus `--approve` in `confirm` mode) blocked the automatic commits, pushes and merges they want. That removal also switched off every other protection for six days.

**How it works:** `push_gate` in `~/.agent/config` (`push_gate=on|off`), **default off**. Only exactly `on` (case-insensitive) re-enables the token check for plain pushes to main or the default branch, `gh pr merge` and the API merge calls. No `GOAL.md` `release_mode` overrides it. The following stay denied either way:
- force pushes;
- deleting protected branches;
- `v*` tag pushes and `--no-verify`;
- `rm -rf` outside the repo and `/tmp`;
- `.env` reads and Supabase writes;
- publishing;
- outbound send tools;
- edits to hooks, settings, tokens, `GOAL.md` gate fields and the config file itself.

`release-gate.sh`, `post-release.sh` and `migrate-gate.sh` stay available for manual use. `templates/pre-push` reads the same switch.

**Consequences:** Phase 5.1/5.2 (the `confirm`-then-`auto` rollout to miso-app and miso-workspace) is dropped. `~/.miso/.agent/GOAL.md` still says `release_mode: confirm`; it no longer blocks anything. Reinstalled 2026-10-16 01:28; backup `~/.claude/settings.json.bak.ching.20261016-012816`. A live probe from a real session showed a plain push to main allowed and a force push denied.

## D23 (2026-10-06): Ching is not ported to a Claude Code mod

**Decision (user, accepting the orchestrator's recommendation):** Ching stays bash, settings command hooks and launchd. It is not rewritten as a Claude Code mod (a function-hooks plugin, TypeScript, in-session). A mod may come later only as a read-only UI layer on top, after the Phase 2 pilot.

**Why:**
- Most of Ching runs outside any session: the launchd watcher, `events.jsonl`, `dash.sh`, the session registry, git `pre-push`, the release and migrate gates, the voice dispatcher. A mod lives only while a session runs, so a port would leave two codebases.
- `guard.sh` as a `PreToolUse` command hook is verified under `bypassPermissions` (Phase 0) and covered by the test suite and the Checkpoint 1.5 differential probe. A mod's `tool.call` deny under bypass is untested, and a mod hook that throws is skipped (the call goes ahead), which is the wrong failure mode for a deny list.
- A port would undo D17 (stay in bash) and the guard hardening, and changing the substrate mid-pilot would spoil the pilot metrics.
- Mods are new (Claude Code 2.1.29x) and the API is large and likely to change; the bash scripts and settings hooks are stable.

**How to apply:**
- Enforcement (guard, gates, Stop check, watcher) never moves into a mod.
- If the pilot shows visibility or notification as the weak spot, build a `ching-ui` mod that only reads `~/.agent/` and `events.jsonl`: a pane for `dash.sh --inbox`/`--next`, a status-line entry (goal, Stop retries, release token), toasts for other sessions' blocked/done events (could replace `notify.sh` popups), possibly a `prompt.compose` hook re-injecting `STATE.md`/`NEXT.md` each turn, and `$.audio.speak` as an option for Phase 3 spoken status. If the mod breaks, only the view is lost.

## D20-D22 (2026-10-06): before the pilot

**Decisions (user, choosing the orchestrator's recommended option for each question):**

- **D20:** Sessions may create a `v*` release tag but never push it. Guard rule 8 now denies pushing `v*` tags, `--tags`, `--follow-tags` and config that pushes tags, in every repo. The GitHub `release` environment reviewer stays as the second gate for miso.
- **D21:** Before the pilot, fix the gaps from CHECKPOINT-1.5 section 6 that would hurt real sessions. These are the stop-check items F3, F4, F5, F8 (partial), F9 and F12, the ladder skip, the cheaper checkpoint rule, the false stall on resume, the zero-usage context reset, the `dash.sh` ranking, inbox and READY issues, the installer prompt on a non-tty run, and the rule 5 and rule 8 false positives on grep patterns. Everything else stays logged until the pilot shows it matters.
- **D22:** miso is the first repo to opt in. The opt-in is the worktree `~/bbq/.worktrees/miso-ching-pilot` on branch `ching-pilot` (autonomy block and gitignore lines committed there, `.agent/GOAL.md` with `release_mode: confirm`), not the user's main miso checkout.

## D19 (2026-10-05): Check-in nudges for waiting sessions

**Decision (user):** Ching reminds the user when a session is waiting on them: a banner first, then one spoken note after about 5 minutes. The notch widget that opens on hover is deferred. It is built by extending the existing one-shot watcher, `ching-watch.sh`, and stays within D17 (no daemon, no AI calls).

**Why:** The stall watcher watches sessions, not the user. Nothing noticed a finished session sitting in front of a user who had looked away.

**How to apply:**
- Waiting means `input`, `blocked`, or `done` with open work (a checkpoint blocker or next action that is not a "none" value, or a non-empty `NEXT.md`). A working session never nudges.
- Keyboard and mouse idle time only gates the voice, never the banner.
- The banner uses the shared alert budget (quiet hours, 4 a day, 45-minute cooldown). The spoken note is outside that budget. It is bounded by once per waiting spell, a 10-minute gap between notes, quiet hours, and the user being at the Mac, and it stays silent while VoiceMode is in use.
- Spec and plan: `docs/superpowers/specs/2026-10-05-ching-nudge-design.md`, `docs/superpowers/plans/2026-10-05-ching-nudge.md`.

## D14-D18 (2026-10-05): Hermes harvest (Phase 1.5)

**Decisions (user, in the brainstorming session that evaluated four Hermes Agent repos):**

- **D14:** Ching is the main AI operations layer for all local files. Review before release is required by default in every repo; only a human-written `review: off` in `GOAL.md` disables it (guard rule 11 stops sessions from changing gate settings).
- **D15:** super-hermes, hermes-workspace, hermes-plugins and hermes-skill-factory are a source of ideas only. Nothing from them is installed or run. Claude Code stays the only engine.
- **D16:** Phase 1.5 (coordination + review hardening) is built before the Phase 2 pilot. The learning-loop ideas are recorded for Phase 6 and specified after the pilot.
- **D17:** Stay in bash: an append-only `~/.agent/events.jsonl` plus a one-shot launchd watcher. No daemon, no cloud scheduler, no AI calls in Phase 1.5.
- **D18:** Sessions write drafts only. They never send email or chat messages (guard rule 10).
- Notification policy confirmed: only `input`, `blocked` and `ready` always reach the user; at most 4 other alerts a day, 09:00-21:00, 45-minute cooldown; `done` goes to `dash.sh --inbox`.

Why, and what was rejected: `docs/superpowers/specs/2026-10-05-hermes-harvest-design.md` section 3. Plain summary: `ching-functions.md`.

## D13 (2026-10-05): Checkpoint 1 approved; hooks installed on the real settings

**Decision (user, "go ahead", following the orchestrator's recommendation):** install the kit's hooks into `~/.claude/settings.json`.

- Installed without `--replace-popup`: the old "Session finished" popup stays, so each stop notifies twice until the user opts in.
- `gh pr merge` is allowed only with a valid release token for the local HEAD and `--match-head-commit <that sha>`. Anything else is denied (guard.sh, tests in t_release.sh).
- The git pre-push hook stays off; it is installed per repo with `install.sh --install-prepush <repo>`.
- Result: 7 new hook entries, 602 checks green, existing `vscode-session-manager-hook.sh` and `auto_title_sessions.py` entries untouched. Backups: `~/.claude/settings.json.bak.ching.20261005-140153` and `/tmp/agent-sandbox-backup/settings.pre-install.*.json`. Undo with `install.sh --uninstall`.
- Not yet verified: that hooks fire from the real settings file in Desktop and VS Code, and how already-open sessions pick them up (MANUAL-STEPS.md 0.4).

## D12 (2026-10-05): mem0 is not included

**Decision (user):** Do not include mem0, now or later. It is the wrong tool: its defaults send data to OpenAI (LLM and embeddings), it needs a vector database and a separate service, and running it locally means standing up Ollama and Qdrant. The user expected a lightweight harness around Claude, which it is not. If it cannot run locally without that extra stack, it stays out.

**What I checked (README summary only, not the code):** Apache-2.0, very active (pushed 2026-10-05, 66k stars). Three modes: library, self-hosted Docker server, hosted cloud. Defaults: OpenAI `gpt-5-mini` plus `text-embedding-3-small`, Qdrant. Ollama is supported through config. A `.claude-plugin` directory exists; I did not inspect it. Telemetry defaults were not stated in what I read.

**Still open:** the user is looking for other tools for the "mirror me and learn my decisions" job. Requirements to judge any candidate against: runs fully local with no cloud calls by default, no extra always-on service if avoidable, readable and editable storage, works alongside claude-mem, and proposes decisions for approval rather than acting on them. Ching's profile storage (D11) stays backend-agnostic so a tool can be added or dropped later.

## D11 (2026-10-05): Ching is a learning system, not just a voice interface

**Decision (user):** Ching must not be only a voice model or a session manager. It is a place of learning and adapting that improves itself. It understands how the user works, what they are good at, and what they lack. It keeps track of that and keeps improving the way they work, so their output is as high as possible.

**What this adds to the design (proposed, not yet built; needs the user's review):**

- A **profile** in `~/.agent/profile/`: working patterns (when and how sessions run, which kinds of task finish fast or stall), strengths, gaps, and recurring friction. Plain markdown and JSONL, so the user can read, edit and delete it.
- **Signals** come from data the kit already has: session transcripts and registry, `STATE.md` logs (assumptions, decisions, releases), Stop-hook retries, questions asked, overturned assumptions, minutes per handoff. These are the three pilot metrics in PLAN.md section 7, kept continuously instead of for one pilot.
- A **review loop** (daily or weekly, run on a cheaper model) that reads the signals, updates the profile, and proposes concrete changes: a rule for `AGENTS.md`, a hook tweak, a `GOAL.md` template fix, a task split. Proposals are written to `~/.agent/proposals/` and shown to the user.
- **Self-improvement is gated.** Ching proposes changes to its own scripts, policy and the user's `AGENTS.md`; the user approves them. It does not rewrite its own guardrails or `guard.sh` on its own.
- **Local only.** The profile never leaves the machine and is never sent to a service. The user can inspect it, correct it ("that's wrong") and wipe it.
- This replaces the old "director loop deferred" idea (D7) with something broader. It stays out of Phase 1 and gets its own phase after the machine-wide kit is working (Phase 6 in PLAN.md).

**Open questions for the user:** how blunt should "what I'm lacking" be, how often should the review run, and should the profile feed back into the dispatcher's spoken answers.

## D10 (2026-10-05): Split work across multiple agents from the start

**Decision (user, after the orchestrator's admission):** Large phases are not given to one big agent. They are split into several agents working in parallel on independent parts, with a separate verification step.

**Why:** Phase 0 took about 12 minutes and Phase 1 as one agent writing nine scripts plus tests was slow. The orchestrator should have split it at the start.

**How to apply:**
- Split by independent unit: for example hooks, gates, `dash.sh`, installer, tests, docs each get their own agent when they do not share files.
- Define the shared interface first (file formats, JSON schemas, paths such as `~/.agent/`), then fan out.
- A separate verification agent runs the tests and reviews the result; the implementer does not grade its own work.
- The currently running Phase 1 agent is not restarted. Phases after it follow this rule.
