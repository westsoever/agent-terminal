# No Terminal windows: design

Date: 2026-10-20. Status: draft; the owner answered three questions (below), the rest waits for approval. Nothing here is built; D72 records the plan. Checked against `main` at D71 and Claude Code 2.1.304.

## Intent

The owner: "if we end up managing all sessions in agent-terminal and have no open terminals, that's completely fine". Today they still leave agterm for Terminal.app. This design lists every reason they still need a Terminal window for a session, checks each one against the code, and proposes how agterm covers it, so that no session keeps a window of its own.

"No Terminal windows" means no window that stays open per session. agterm itself still runs in one Terminal window (the Raycast "Open Agent Terminal" script opens it there), and Claude Code's full screen, when the owner needs it, opens in a short-lived window that closes again (decision 2).

## The owner's decisions (2026-10-20, relayed by the coordinator)

1. **Move running Terminal sessions to the background:** "yes (the `B` / `BG ALL` path, idle sessions only, accepting the losses you listed)". See E.
2. **Claude Code's full screen:** "a short-lived Terminal window that closes when you leave it, NOT inside agterm's own window". See A. agterm never hands its own screen over to `claude attach`.
3. **Sessions started by hand:** "a new `cl` shell command that starts a background session and selects it in agterm". See B.

## The idea in one paragraph

Every session becomes a background session (`claude --bg`), which Claude Code runs in a daemon with a pty of its own. agterm already lists them, reads their conversation from the transcript, reads their screen from `claude logs` (so it sees menus and permission prompts), and types into them by attaching for a moment (`bg.go` `bgSteps`). What is missing is (1) a short-lived window with the full Claude Code screen when the owner needs it, that closes by itself, (2) starting every session as a background one, including resumes and the owner's own starts, and (3) moving the sessions that already run in Terminal tabs over.

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
| 11 | `g`: show the session's window | `ui.go` `K.Goto`: `raiseTab` for a tab; for a background session `bgAttachWindow` opens a new Terminal window running `claude attach <job>`, which stays open after the attach ends | Opens a window that stays |
| 12 | `h`: bring the window to monitor 1 to type in it | `bringHere` (`queue.sh show` + `raiseTab`) | Not for background sessions ("no Terminal window for this agent") |
| 13 | Window tiling on monitor 2, the monitor queue, the `next` hotkey | `bin/queue.sh`, `queue-term.js`, `queue-layout.pl`, `AgentTerminalBar.swift` `TileTrigger` (D29-D38, D42, D43, D68, D69) | Not needed: these only handle Terminal windows; with none they do nothing |
| 14 | Sessions the owner starts by hand in Terminal | Listed and typed into through their tab (`send.js`, `InTerminal`) | They stay Terminal sessions |
| 15 | opencode sessions | `opencode.go`: Terminal tabs only (D64) | No (out of scope here) |
| 16 | The voice dispatcher | `VoiceShortcut.swift` starts `dispatcher/launch.sh` in a new Terminal window (`claude --name dispatcher`), with Terminal's microphone grant | No |

Background sessions already work for: reading the conversation and recap, the agent's menus and permission prompts (4), sending messages, `@Name` helpers (D70), PR and RP agents (D45, D60), PC `b` (D52), `STOP`, dismiss (D50).

## How agterm covers each

### A. The full screen in a short-lived window (covers 6, 7, 8, 9, 11, 12)

Decision 2. `g` on a background session opens a Terminal window on the main display running `claude attach <job>`, as `bgAttachWindow` does today, with one change: the window closes when the attach ends. The owner uses every key and `/` command there; the session keeps running after the window closes.

- How it closes: the window's shell line becomes `claude attach <job>; exit`, so the shell ends with the attach. Whether Terminal then closes the window depends on the profile's "When the shell exits" setting, so agterm also closes it itself: `termWindow` notes the new tab's tty (AppleScript `do script` returns the tab), and agterm closes that window by its tty once nothing runs in it (`send.js` already finds tabs by tty). Phase 0 checks which of the two is needed.
- How the owner leaves: whatever ends `claude attach` (its help: `←` returns to the agent view, `ctrl+z` drops back to the shell; Phase 0 checks which ends the process). The footer of agterm and the window's title say it.
- `h` on a background session does the same (there is no window to bring; it opens on monitor 1 and has focus).
- The window opens on the main display, which the monitor queue never lays out (D68), so the tiling on monitor 2 leaves it alone.
- Only one such window per session: `g` again raises the open one instead of opening a second.

### B. Every new session is a background one (covers 1, 2, 3, 14)

- FIND `r` runs `claude --bg --resume <id>` in the session's folder instead of a window. Claude Code's help: "With --resume <session-id>, continues that session in the background under the same ID". The session then shows in the list like any other.
- `NW` with no message: start the session and open the short-lived window (A), for "just a session". Needs a check that `claude --bg` runs without a prompt; if it does not, `NW` keeps asking for the first message.
- `cl` (decision 3): a shell command, installed by `install.sh` into `~/.local/bin/cl` next to `agterm`. `cl [name] [prompt]` runs `claude --bg -n <name>` (the folder's name when left out) in the current folder with `NW`'s model, effort and mode, and writes the new session's id to `~/.agent/terminal/select`. agterm reads that file on its tick, selects the session when it shows up, and deletes the file. `cl` prints the id and returns to the shell; plain `claude` keeps working as today (a Terminal session that `B` can move later).
- PC `t`: see open question 3.

### C. The trust prompt and login (covers 5, 6)

- Trust: when `bgStart` fails with "not trusted", agterm asks "Trust <folder>? enter yes". Yes opens a short-lived window (A) running `cd <folder> && claude`; the owner answers Claude Code's own trust question and leaves with `/exit`, the window closes, and agterm starts the background session again once the window is gone. (Open question 1 has the faster option.)
- Login: agterm checks `claude auth status` when it opens and every few minutes; logged out shows an orange line on the desk. `LOGIN` opens a short-lived window running `claude auth login`; the browser part is the same as today. MCP OAuth is done with `/mcp` in the session's window (A).

### D. `/` commands with a screen (covers 7)

The reply box knows a short list of commands that open a screen (the list above, kept in one table). Sending one of them to a background session types it and then opens the session's short-lived window (A), so the owner lands in the screen. A command with an argument that does not open a screen (`/model sonnet`, `/compact`, `/clear`) goes as today. For a Terminal session nothing changes.

### E. Moving running Terminal sessions over (covers 14, and the cut-over)

Decision 1. `B` (or `BG` on the command line) on a Terminal session that is idle, with no menu on its screen:

1. Type `/exit` into its tab (the existing `send.js text`).
2. Wait for its process to end (its `~/.claude/sessions/<pid>.json` goes).
3. Run `claude --bg --resume <session id> -n <name>` in its folder, with its model (read from the transcript, as `modelTag` does) and permission mode.
4. Close the Terminal tab when only the shell is left (AppleScript; a setting, on by default).

`BG ALL` does this for every idle Terminal session; busy ones and ones with a menu open are skipped and listed. A session that fails at step 3 is reported with Claude Code's words and can be resumed by hand (`claude --resume <id>`); nothing is lost but the running process.

What a moved session loses (the owner accepted this): background shells and monitors it started, a running `/loop`, subagents in flight, permissions granted "for this session", its scrollback. The conversation, memory files and its folder stay. Its next turn starts with a cold prompt cache (more tokens once).

### F. Tiling and the monitor queue (covers 13)

Nothing to build. With no session windows on monitor 2, `queue.sh` and the tile checker find nothing to move, and the short-lived windows open on the main display, which is never laid out. The queue stays for the Terminal sessions that are left (opencode, the dispatcher, a `claude` typed by hand). Once the owner has had no session window for some weeks, a later change turns the queue off by default (`queue=off`) and removes the `next` path; not before.

### G. What stays in Terminal

- agterm's own window, and the short-lived windows of A and C.
- opencode sessions (15): their TUI has no background mode in agterm; they stay as today.
- The voice dispatcher (16), see open question 4.

## What is lost overall

- Speed of a reply: typing into a background session attaches a pty each time (`bgSteps`: about 2 s before the text is in, up to 8 s when the session is slow to draw). The instant echo being built now hides most of it.
- The ambient wall of live windows on monitor 2; see open question 2.
- Seeing tool output live without a key press: it takes `g` and a window (A).
- Sessions survive closing Terminal, but it is not checked yet what happens to background sessions on a reboot or a Claude Code update (`claude respawn` exists for updates).

## Phased order

Each phase is one PR with its own decision entry, and is useful alone.

0. **Check the unknowns (no product code).** In a throwaway folder: which key ends `claude attach` as a process; whether `claude attach <job>; exit` closes the window with the owner's Terminal profile, or agterm must close it; whether `claude --bg` starts without a prompt; whether `claude --bg --resume <id>` after `/exit` keeps the id, the name, the model and the permission mode; what a reboot does to background sessions; whether the statusline (agterm's usage bar) is written by background sessions; whether a pasted `!cmd` or `#note` acts like typed. Write the answers into this file.
1. **The short-lived window (A).** `g` and `h` on a background session open `claude attach` in a window on the main display that closes when the attach ends; one window per session.
2. **Every start is a background one (B, C).** FIND `r` resumes in the background; `cl`; `NW` with no message opens the window; the trust question; `LOGIN`.
3. **Move running sessions over (E).** `B` and `BG ALL`.
4. **`/` commands with a screen (D).** After phase 1, since it uses its window.
5. **Later, after some weeks without session windows (F).** The queue off by default; the window paths of Terminal sessions removed from help and footer.

## Open questions for the owner

Each has the default this design will follow unless the owner says otherwise.

1. **The trust prompt.** Answer it in Claude Code's own screen in a short-lived window (C), or let agterm write the trust flag into `~/.claude.json` (faster, but edits Claude Code's own state)? **Recommended default: the short-lived window.**
2. **Monitor 2.** With no session windows, what goes there: nothing, or a second agterm on the wall view (`W`) as the ambient overview? **Recommended default: nothing new; open a second agterm by hand if you miss the overview.**
3. **PC `t`.** Remove it, or keep it as "background session, then its short-lived window at once"? **Recommended default: keep it in that new form, so `t` still means "I want to watch it".**
4. **The voice dispatcher.** Keep it in its Terminal window for now? **Recommended default: yes, until a test shows a background session gets the microphone.**
