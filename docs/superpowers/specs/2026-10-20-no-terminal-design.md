# No Terminal windows: design

Date: 2026-10-20. Status: draft for the owner's review. Nothing here is built; D72 records the plan. Checked against `main` at D71 and Claude Code 2.1.304.

## Intent

The owner: "if we end up managing all sessions in agent-terminal and have no open terminals, that's completely fine". Today they still leave agterm for Terminal.app. This design lists every reason they still need a Terminal window for a session, checks each one against the code, and proposes how agterm covers it, so that a session never needs a window of its own.

"No Terminal windows" means no window per session. agterm itself still runs in one Terminal window (the Raycast "Open Agent Terminal" script opens it there); that window stays.

## The idea in one paragraph

Every session becomes a background session (`claude --bg`), which Claude Code runs in a daemon with a pty of its own. agterm already lists them, reads their conversation from the transcript, reads their screen from `claude logs` (so it sees menus and permission prompts), and types into them by attaching for a moment (`bg.go` `bgSteps`). What is missing is (1) a way to see and use the full Claude Code screen when the owner needs it, without a new window, (2) starting every session as a background one, including resumes, and (3) moving the sessions that already run in Terminal tabs over.

## What still needs a Terminal window today

| # | Need | Where in the code today | Covered for background sessions today? |
|---|---|---|---|
| 1 | Start a session to work in interactively | `NW` (`ui.go`, `bgStart`) already starts a background one; the owner still types `claude` in a shell for "just a session" | Partly: `NW` needs a first message |
| 2 | Resume an ended session | FIND `r` (`findui.go` `findResume`): `resumeWindow` opens a new Terminal window with `claude --resume <id>` | No |
| 3 | Hand a Paperclip issue to a session with a window | PC `t` (`pchand.go` `termStart`): new Terminal window | No (PC `b` is the background version) |
| 4 | Answer a permission prompt, a plan approval, an AskUserQuestion | `prompt.go` `parsePrompt` on the tab's screen (`send.js screen`); for background sessions on `bgScreen` (`claude logs`, `bgscreen.go`), answered with `bgSend` keys (`ask.go`, `askui.go`) | Yes |
| 5 | The trust prompt of a new folder | `bgStart` fails with Claude Code's own words ("not trusted yet"); the owner has to run `claude` in that folder in a Terminal window once | No |
| 6 | Log in again (expired or logged-out account), MCP server OAuth | Nothing in agterm; done with `claude auth login` or `/login`, `/mcp` in a window | No |
| 7 | `/` commands that open a screen of their own: `/config`, `/model` without an argument, `/mcp`, `/permissions`, `/agents`, `/hooks`, `/plugin`, `/memory` (opens an editor), `/resume`, `/rewind`, `/status`, `/context`, `/doctor` | The editor suggests them (`editor.go` `slashCommands`) and sends them as text. In a Terminal tab the screen opens in that window, so the owner goes there (`g`, `h`). In a background session it opens on a screen nobody sees: `bgScreen` shows it only if it is a numbered menu | No |
| 8 | Claude Code's own keys: `shift+tab` (mode), `esc esc` (rewind), `ctrl+o` (full tool output), `ctrl+r` (history), `!` (shell), `#` (memory), dragging an image in | Only in the window. agterm sends text and a few named keys (`bgKeys`: enter, arrows, tab, esc) | Partly: the keys exist, there is no way to press them |
| 9 | See the full tool output (diffs, long bash output) as it happens | The agent panel shows the transcript (`chatLines`); full output is in the window | No |
| 10 | Interrupt a working session | Another session is building interrupt now; for a background session it is `bgSend(job, "", ["esc"])` | Being built |
| 11 | `g`: show the session's window | `ui.go` `K.Goto`: `raiseTab` for a tab; for a background session `bgAttachWindow` opens a new Terminal window running `claude attach <job>` | Opens a window |
| 12 | `h`: bring the window to monitor 1 to type in it | `bringHere` (`queue.sh show` + `raiseTab`) | Not for background sessions ("no Terminal window for this agent") |
| 13 | Window tiling on monitor 2, the monitor queue, the `next` hotkey | `bin/queue.sh`, `queue-term.js`, `queue-layout.pl`, `AgentTerminalBar.swift` `TileTrigger` (D29-D38, D42, D43, D68, D69) | Not needed: these only handle Terminal windows; with none they do nothing |
| 14 | Sessions the owner starts by hand in Terminal | Listed and typed into through their tab (`send.js`, `InTerminal`) | They stay Terminal sessions |
| 15 | opencode sessions | `opencode.go`: Terminal tabs only (D64) | No (out of scope here) |
| 16 | The voice dispatcher | `VoiceShortcut.swift` starts `dispatcher/launch.sh` in a new Terminal window (`claude --name dispatcher`), with Terminal's microphone grant | No |

Background sessions already work for: reading the conversation and recap, the agent's menus and permission prompts (4), sending messages, `@Name` helpers (D70), PR and RP agents (D45, D60), PC `b` (D52), `STOP`, dismiss (D50).

## How agterm covers each

### A. The full screen inside agterm (covers 6, 7, 8, 9, 11, 12)

`g` on a background session runs `claude attach <job>` inside agterm's own window: agterm hands over the screen with `tea.ExecProcess`, the same way `PO a` already hands it to `agent-terminal-proposals approve`. The owner sees Claude Code's own screen, uses every key and `/` command, and when they leave the attach, agterm comes back where it was. The session keeps running either way.

- This is the one feature that makes a window unnecessary: anything Claude Code can do only on its own screen, the owner does here.
- `h` on a background session does the same (there is no window to bring).
- The current behaviour, a new Terminal window with `claude attach`, moves to `G`, for when the owner wants a session beside agterm.
- To check first: which key ends `claude attach` as a process (its help says `←` returns to the agent view and `ctrl+z` drops back to the shell). agterm needs the attach process to exit, not to stop itself, or agterm waits.

### B. Every new session is a background one (covers 1, 2, 3)

- FIND `r` runs `claude --bg --resume <id>` in the session's folder instead of a window. Claude Code's help: "With --resume <session-id>, continues that session in the background under the same ID". The session then shows in the list like any other.
- PC `t` goes (PC `b` stays), or becomes "background, then attach at once" (A).
- `NW` with no message: start the session and attach at once (A), for "just a session". Needs a check that `claude --bg` runs without a prompt; if it does not, `NW` keeps asking for the first message.
- A shell command for the owner's own habit (14): `cl [name]` in `~/.zshrc` runs `claude --bg -n <name>` in the current folder and leaves a note (a new small file under `~/.agent/terminal/`) so agterm selects it when it shows up. Plain `claude` keeps working as today.

### C. The trust prompt and login (covers 5, 6)

- Trust: when `bgStart` fails with "not trusted", agterm asks "Trust <folder>? enter yes". Yes runs `claude` in that folder inside agterm's screen (A's hand-over), the owner answers Claude Code's own trust question and leaves with `/exit`, and agterm starts the background session again. Writing the trust flag into `~/.claude.json` directly would be faster but edits Claude Code's own state; not proposed.
- Login: agterm checks `claude auth status` when it opens and every few minutes; logged out shows an orange line on the desk. `LOGIN` runs `claude auth login` in agterm's screen (A's hand-over); the browser part is the same as today. MCP OAuth is done in an attach (`/mcp`).

### D. `/` commands with a screen (covers 7)

The reply box knows a short list of commands that open a screen (the list above, kept in one table). Sending one of them to a background session types it and then attaches (A), so the owner lands in the screen. A command with an argument that does not open a screen (`/model sonnet`, `/compact`, `/clear`) goes as today. For a Terminal session nothing changes.

### E. Moving running Terminal sessions over (covers 14, and the cut-over)

`B` (or `BG` on the command line) on a Terminal session that is idle, with no menu on its screen:

1. Type `/exit` into its tab (the existing `send.js text`).
2. Wait for its process to end (its `~/.claude/sessions/<pid>.json` goes).
3. Run `claude --bg --resume <session id> -n <name>` in its folder, with its model (read from the transcript, as `modelTag` does) and permission mode.
4. Close the Terminal tab when only the shell is left (AppleScript; a setting, on by default).

`BG ALL` does this for every idle Terminal session; busy ones are skipped and listed.

What a moved session loses (the same as any `claude --resume`): background shells and monitors it started, a running `/loop`, subagents in flight, permissions granted "for this session", its scrollback. The conversation, memory files and its folder stay. Its next turn starts with a cold prompt cache (more tokens once).

### F. Tiling and the monitor queue (covers 13)

Nothing to build. With no Terminal windows on monitor 2, `queue.sh` and the tile checker find nothing to move. They stay for the Terminal sessions that are left (opencode, the dispatcher, sessions the owner starts by hand). Once the owner has had no session window for some weeks, a later change turns the queue off by default (`queue=off`) and removes the `h` and `next` paths; not before.

Monitor 2 is then free. One option is a second agterm there on the wall (`W`), as the ambient overview the Terminal grid gives today (question 5).

### G. What stays in Terminal

- agterm's own window.
- opencode sessions (15): their TUI has no background mode in agterm; they stay as today.
- The voice dispatcher (16), until background sessions are known to get the microphone.

## What is lost overall

- Speed of a reply: typing into a background session attaches a pty each time (`bgSteps`: about 2 s before the text is in, up to 8 s when the session is slow to draw). The instant echo being built now hides most of it.
- The ambient wall of live windows on monitor 2; the wall view (`W`) or a second agterm is the replacement.
- Seeing tool output live without a key press: it takes `g` (A).
- Sessions survive closing Terminal, but it is not checked yet what happens to background sessions on a reboot or a Claude Code update (`claude respawn` exists for updates).

## Phased order

Each phase is one PR with its own decision entry, and is useful alone.

0. **Check the unknowns (no product code).** In a throwaway folder: how `claude attach` ends as a process under `tea.ExecProcess`; whether `claude --bg` starts without a prompt; whether `claude --bg --resume <id>` after `/exit` keeps the id, the name, the model and the permission mode; what a reboot does to background sessions; whether the statusline (agterm's usage bar) is written by background sessions; whether a pasted `!cmd` or `#note` acts like typed. Write the answers into this file.
1. **The full screen inside agterm (A).** `g`/`h` on a background session attach inside agterm; `G` keeps the window. From here the owner never needs a window for a background session.
2. **Every start is a background one (B, C).** FIND `r` resumes in the background; PC `t` goes; the trust question; `LOGIN`; `NW` with no message attaches.
3. **Move running sessions over (E).** `B` and `BG ALL`.
4. **`/` commands with a screen (D).** After phase 1, since it uses it.
5. **Later, after some weeks without session windows (F).** The queue off by default; the window paths removed from help and footer.

## Open questions for the owner

1. **Move or let die out?** Should agterm move running Terminal sessions to the background (`B`, `BG ALL`), which needs them idle and loses their in-memory state (background shells, `/loop`, session-only permissions), or only start new sessions in the background and let the Terminal ones end on their own?
2. **Where does the full Claude Code screen go?** Inside agterm's window (agterm hidden until you leave the attach; proposed), or a short-lived Terminal window that closes when you leave it?
3. **Sessions you start by hand.** Keep `claude` in a shell as today (a Terminal session agterm can move later), or use a `cl` shell command that starts a background session and selects it in agterm?
4. **The trust prompt.** Answer it in Claude Code's own screen inside agterm (proposed), or let agterm write the trust flag into `~/.claude.json`?
5. **Monitor 2.** With no session windows, what goes there: a second agterm on the wall view, nothing, or something else?
6. **PC `t`.** Remove it, or keep it as "background, then attach at once"?
7. **The voice dispatcher.** Keep it in its Terminal window for now?
