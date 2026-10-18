# Agent terminal: design

Date: 2026-10-17. Status: draft for the owner's review. Brainstormed in the AgentTerminal session; mockups in `.superpowers/brainstorm/3136-1792238119/content/layout-v2.html` (the approved look).

## Intent

The owner runs many Claude Code agents at once and manages them with the mouse: a notification comes in, they open Mission Control, hunt for the right Terminal window, read where the agent is, then decide or type back. When an agent names a file, they click through Finder folders to reach it.

The agent terminal replaces that with one keyboard-only screen, the way the Bloomberg Terminal is the one screen a trader runs a desk from. It is not an AI chat and not a mouse substitute bolted onto existing windows. It is a fast, predictable cockpit: every agent, what it needs, and the action, one or two keys away. AI can sit behind it, but the terminal itself is deterministic.

It becomes part of Ching, which is being renamed **Kaching** (see "Rename" below). Kaching is the engine (hooks, state, queue, guard, learner); the agent terminal is the screen; Paperclip is one more source the screen reads.

## Goals

- See every live agent on the machine and which ones need the owner, in priority order, on one screen.
- Act on the selected agent without leaving the keyboard: answer its options, send a pre-written reply, type a free reply, open a file it mentioned, jump to its real Terminal window.
- Keys and pre-written replies live in one config file the owner edits as they learn what they use; the terminal picks up changes without a rebuild.
- Background agents in Paperclip appear in their own view and are answered with the same keys.
- Feels like a terminal.shop/Bloomberg tool: instant, dense but calm, straight lines.

## Non-goals (for now)

- Replacing Terminal.app windows. Agents keep running in their own Terminal windows; the terminal reads them and sends to them. (The wall view shows them; it does not host them.)
- Starting a new hardware/keyboard setup or system-wide key remapping. Keys work inside the terminal; the only global hotkey is the existing "Next Waiting Agent" Raycast command, plus one to bring the terminal itself forward.
- Making Paperclip the backend. Paperclip agents are added step by step and the owner will see what they can do; the terminal reads Paperclip, it does not depend on it.
- An AI layer that decides for the owner.

## Anti-goals (would make it a failure even if it works)

- Slow. If opening it, moving between agents or sending a reply has a visible lag, the owner goes back to the mouse.
- Wrong delivery. A reply landing in the wrong agent, or a keypress answering a prompt the owner didn't see, is worse than no tool.
- Crooked or cramped. Misaligned box lines, saturated colours, or tiles squeezed regardless of window size (the owner's feedback on the first mockups).
- Bypassing safety. Anything the guard blocks for a session stays blocked when triggered from the terminal; the terminal never answers a permission prompt by itself.
- Breaking the sessions already running while it is built or while Ching is renamed.

## What it looks like

Visual style (owner's call, from `ssh terminal.shop`): near-black background, mostly grey text (xterm 102 `#878787`), dark grey borders (59 `#5f5f5f`), white bold for the selected/important item (231), one orange accent (202 `#ff5f00`) used only for keys, "needs you" and the selected row (orange background, black text). No other colours. Box-drawing lines must join cleanly at every size.

### Desk (home screen)

Top: a tab bar of views, each labelled with its code (`IN inbox 2`, `AG agents 6`, `FL files`, `RP repos 3`, `PR proposals 1`, `PC paperclip`). Under it the command line (`> IN <GO>`) plus clock, live count, "N need you".

Left panel: the queue, grouped WAITING (decide / input / done, oldest first), WORKING, IDLE. Agents are shown by their session name (`chingSorter`), never by id; fall back to folder + short id only when there's no name.

Right panel, for the selected agent: name, folder, branch; its last message; its options numbered as the agent gave them (`1 merge and push  2 merge only  3 not yet`); FILES IT MENTIONED, lettered `a b c`; the reply line.

Bottom: two key rows. Row 1 = move and answer. Row 2 = pre-written replies.

### Command line

`/` focuses it. Codes switch views or act, Bloomberg style, then Enter (GO): `IN`, `AG`, `FL`, `RP`, `PR`, `PC`, `A<n>` (open agent n), `NEW` (start an agent), `HELP`. Esc returns to the desk. Codes are defined in the config file too.

### Wall (zoomed out)

`W` from the desk. Every agent as a tile: number, name, state, the last lines of its output, a reply line. Tiles size to the window (one column per ~40 columns of width, 3 across on a full 1080p screen, more lines per tile as the window gets taller), with even gaps. The selected tile has an orange border. `1-9` focus, `z` zoom one tile to full screen, Esc back to the desk.

### PC view (Paperclip)

Paperclip issues that are blocked or waiting for the owner's approval, then active agent runs with their cost. Same keys: `j/k` move, numbers answer, `r` reply (posted as an issue comment), `g` opens the issue in the Paperclip web UI. Read from the local Paperclip API (`localhost:3100`, local_trusted mode). If Paperclip is down, the view says so in one line and the rest of the terminal is unaffected.

### FL (files) and RP / PR

FL lists every file path agents mentioned recently, newest first, opened with Enter (default: the file in the owner's editor, a folder in Finder; configurable). RP is Ching's existing sync report (repos with work you could lose). PR is the learner's proposals (`ching-proposals`), approve/reject from the keyboard, which must keep the existing human-only approve check.

## Keys and the config file

Two modes, so letters can be shortcuts: **key mode** (default) where every key is an action, and **typing mode** (`r` to start a free reply, Enter sends, Esc cancels). Owner's direction: answers by number, everything else on keys near the home row (f, j and around) so muscle memory builds; the starting set below is the builder's proposal and the owner will reshape it.

| Key | Action |
|---|---|
| `1`-`9` | answer the agent's numbered option |
| `j` / `k` | next / previous agent in the queue |
| `space` (alone) | next waiting agent (same as `queue.sh next`) |
| `o` + letter | open that mentioned file |
| `g` | go to the agent's real Terminal window (raise + select tab) |
| `r` | type a free reply |
| `/` | command line |
| `f` | send "fix it" |
| `d` | send "review the code" |
| `s` | send "check in on the other agents" |
| `space m` / `space c` / `space w` | send `/merge` / commit / "make a new worktree for this" |
| `W` | wall |

One file, `~/.agent/terminal/keys.toml` (path and format: builder's call, but one human-editable file), holds every key, every pre-written reply text, and every command-line code. It is reloaded on change. Agreed with the chingSorter session: this is the single home for all Kaching shortcuts, and `queue.sh next` is the first action it binds.

## Pre-written replies and merging

A pre-written reply is just text sent to the agent as if the owner typed it. Merging is one of them: `space m` sends `/merge`, and each session merges its own branch using the global merge skill (being built and tested now, in `~/.agents/skills/`), which encodes the owner's rules: fetch first, stage explicit paths, never force-push, never reset others' commits, keep both sides' intent on a conflict and stop with a recommendation when unclear, confirm `git log HEAD..origin/main` is empty, report what went in. A dedicated merge agent (possibly a Paperclip agent with a per-repo merge queue) is a later step, only if several sessions merging into one repo at once becomes a real problem.

## Data: where everything comes from

- Live sessions, states, names, ages, context: Ching's records (`~/.agent/sessions/*`, the registry `dash.sh` reads, `dash.sh --counts`/`--inbox` logic). The terminal reads files directly; it must not shell out to `dash.sh` per frame.
- Waiting queue and Terminal window/tab for each session: the monitor queue (`~/.agent/queue/waiting/<tty>`, `parked/<winid>`) and `queue-term.js` (`raise ID TTY`) from D29-D31. Requested from chingSorter (2026-10-17), which owns these files: a session→tab map for every Terminal session (`~/.agent/queue/tabs/<session_id>`), the session id and waiting kind inside `waiting/<tty>`, a switch that keeps queue bookkeeping but stops window moves, and `queue.sh dismiss <session_id>`. Raycast stays the global hotkey layer.
- An agent's last message, its numbered options, and the paths it mentioned: its transcript JSONL under `~/.claude/projects/` (tail only) plus the Notification hook's message for permission prompts.
- Paperclip: its local HTTP API.
- Sync and proposals: the same sources as `dash.sh --inbox` and `ching-proposals`.

## Sending a reply to a session (the one real unknown)

The terminal must put text into a running interactive Claude Code session in another Terminal tab, exactly as if the owner typed it there, including answering a permission prompt with its number. This has to be proven before anything else is built. Candidates, for the builder to spike in this order:

1. Terminal.app scripting: target the session's tab (window id + tty, already known from the queue) and type into it without stealing focus, if Terminal allows it.
2. Raise the tab (`queue-term.js raise`), send keystrokes, return focus to the agent terminal. Visible flicker, but simple.
3. Start new agent sessions inside tmux (from `NEW` / `space w`) so the terminal can use `tmux send-keys`; existing Terminal sessions fall back to 2.

**Owner's answers (2026-10-17):** only Terminal.app sessions accept replies; sessions in Claude Desktop, VS Code or Cursor are not sent to (they may be listed, without a reply line). If typing into a background tab without focus is impossible, the fallback is option 2 (a brief flicker); tmux is not pursued for now.

Not acceptable: Claude Code's peer-session messaging (it arrives as a message from another session, not from the owner, so it can't answer prompts or carry the owner's authority). Whatever wins must verify delivery (the session's state changes from waiting to working) and show an error otherwise.

## Monitor 1 while the terminal is open: one agent at a time

Owner's decision: to stay focused, monitor 1 shows the terminal (the only focus point) plus **at most one agent window**: the one the owner is dealing with now. Other waiting agents stay in the terminal's queue and their windows stay on monitor 2. Only after the owner has responded to that agent does its window go back and the next waiting agent's window come to monitor 1. The agent window arrives in the background and never takes focus from the terminal; it's there to read the agent's full context, while the reply is typed in the terminal. When the terminal is closed, today's queue behaviour (every waiting window parks on monitor 1) applies unchanged. This is a mode of chingSorter's `queue.sh` (owner of that code), switched on while the terminal runs.

## Rename: Ching → Kaching

Owner's decision: the system is renamed Kaching (an old cash register closing). It touches about 1,300 mentions in 92 files of this repo, 7 hook entries in `~/.claude/settings.json`, 3 launchd jobs (`org.ching.watch/learn/menubar`), `ChingBar.app`, the `~/.claude/ching` link, `CHING_*` env vars, the `ching-proposals` command, the Raycast scripts and the repo folder. Constraints:

- Done as its own step, on a clean main, with no other session mid-branch in the repo; announced to the active Ching sessions first.
- Running sessions must keep working: `~/.claude/ching` and `~/bbq/ching` stay as links to the new paths until every old session has ended; old env var names are read as fallbacks for one release.
- The settings.json and launchd changes go through `install.sh` (sessions can't edit their own hooks; the guard blocks it), so the owner runs or approves that step.
- History (DECISIONS.md, past specs) keeps the old name where it describes the past.

## Build order

1. Spike: send-to-session (above). Throwaway; decides the delivery method.
2. Rename to Kaching.
3. Terminal core: desk, queue, selected-agent panel, keys config, send/answer, open file, go to window.
4. Command line + FL / RP / PR views.
5. Wall.
6. PC view (Paperclip).

Per D10, step 3 onward is split across parallel agents after the shared interfaces (config format, the session-snapshot struct, the send function) are fixed, with a separate verifier.

## Decided by the owner

- A dedicated app-like screen in one Terminal window, keyboard only, Bloomberg/terminal.shop feel; desk + command line merged as home, wall as a zoomed-out view with spacing that follows window size.
- Replies are typed in the terminal and delivered to the agent's own Terminal session.
- Numbers answer; shortcuts near the home row; pre-written replies (fix it, review the code, check in on other agents, merge, commit, new worktree) in an editable config.
- Each session merges itself via a merge skill; a dedicated merge agent maybe later.
- Paperclip is a source (PC view), not the backend; Paperclip agents grow step by step.
- Rename Ching to Kaching.
- Replies go to Terminal.app sessions only; fallback delivery is a brief flicker, not tmux.
- While the terminal is open, monitor 1 holds the terminal plus one agent window at a time, the next one only after the owner responded.
- Split with chingSorter: it owns the monitor queue (merged, D29); the terminal builds on its primitives and the shared keys config.

## Left to the builder (marked as AgentTerminal's calls)

- Language and TUI library. Recommendation: Go with Charm's Bubble Tea + Lip Gloss (what terminal.shop is built on; single fast binary, good box drawing). Ching's bash stays for hooks.
- Command name (`kaching` opens the desk), config file format and path, refresh mechanism (file watching vs. a short poll), exact key defaults beyond the table, how many output lines per tile.
- How "paths it mentioned" are detected in agent output.
- The rename is not a gate for the terminal: the terminal is built under the Kaching name from day one (binary, config path, docs), in parallel; the repo-wide rename lands whenever main is clean and the owner can run `install.sh`.
- Paperclip agents appear on the desk and wall too, under their own PAPERCLIP heading and marked as such; a reply to one is posted as an issue comment through the API, never as keystrokes. The send function takes the target kind (terminal tab / Paperclip issue) explicitly so the two paths can't be confused.
- `space` selects the next waiting agent inside the terminal (focus stays in the terminal); `g` is what raises the real window. The global "Next Waiting Agent" Raycast command keeps raising windows as today.
- `keys.toml` covers keys inside the terminal only in v1. Global hotkeys stay in Raycast; generating Raycast scripts from the config is a later step.
- PC view: v1 posts comments and can move an issue's status; approving a Paperclip approval (which can hire agents or spend budget) needs a typed confirmation, like the human-only approve in `ching-proposals`.
