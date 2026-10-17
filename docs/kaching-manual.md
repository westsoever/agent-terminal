# Kaching agent terminal: user manual

Written in ASD-STE100 Simplified Technical English. Labels on the screen (for example `WAITING`, `IN`, `PC`) are technical names. This manual shows them in `code` letters.

## 1. Quick reference

### 1.1 Go to a view

Push `/`, write the code, then push `Enter`.

| Code | View | It shows |
|---|---|---|
| `IN` | Inbox (the desk) | All agents and the selected agent. This is the start view. |
| `AG` | Agents (the wall) | All agents as tiles. You can also push `W`. |
| `FL` | Files | All files that the agents wrote about. |
| `RP` | Repos | The git sync check: repos with work that you can lose. |
| `PR` | Proposals | The changes that the learner proposes. |
| `PC` | Paperclip | Paperclip issues that need you, and issues in progress. |
| `A3` | Agent 3 | The desk, with agent 3 selected. Use a number from 1 to 9. |
| `ching` | An agent by name | The desk, with the first agent whose name starts with these letters. |
| `HELP` | Help | The key list. You can also push `?`. |
| `QUIT` | – | Kaching stops. You can also push `Ctrl+C`. |

Push `Esc` to go back to the desk from any view.

### 1.2 Keys on the desk

| Key | Result |
|---|---|
| `j` or `↓` | Select the next agent. |
| `k` or `↑` | Select the previous agent. |
| `Space` | Select the next agent that waits for you. |
| `1` to `9` | Send the answer with that number to the selected agent. |
| `r` | Write a message to the selected agent. `Enter` sends it. `Esc` cancels it. |
| `o`, then `a` to `i` | Open the file with that letter. |
| `g` | Show the Terminal window of the selected agent. |
| `x` | Remove the selected agent from the waiting list. You do not send an answer. |
| `W` | Go to the wall. |
| `R` | Read all data again now. |
| `?` | Show the help. |

### 1.3 Fixed messages

These keys send a fixed message to the selected agent. They operate on the desk and on the wall only.

| Key | Message |
|---|---|
| `f` | fix it |
| `d` | review the code |
| `s` | check in on the other agents |
| `Space`, then `m` | /merge |
| `Space`, then `c` | commit your work |
| `Space`, then `w` | make a new worktree for this and continue there |

You can change these keys and messages. Refer to section 7.

### 1.4 Keys on the wall

| Key | Result |
|---|---|
| `1` to `9` | Select the tile with that number. |
| `z` | Show the selected tile on the full screen. Push `z` again to go back. |
| `j`, `k`, `Space` | Select the next, previous or next waiting agent. |
| `Esc` | Go back to the desk. |

When a tile shows on the full screen, the number keys send answers, as on the desk.

### 1.5 Keys in the lists (FL, PR, PC, RP)

| View | Key | Result |
|---|---|---|
| All lists | `j`, `k` | Select the next or previous line. |
| `FL` | `Enter` | Open the selected file. |
| `PR` | `Enter` | Show the full proposal. Push `q` to close it. |
| `PR` | `a` | Approve the proposal. The screen asks you to write a code. |
| `PR` | `x` | Reject the proposal. |
| `PR` | `z` | Hide the proposal for 7 days. |
| `PC` | `Enter` | Open the issue in Paperclip in your browser. |
| `PC` | `r` | Write a comment on the issue. `Enter` sends it. |

## 2. Introduction

### 2.1 What Kaching is

Kaching is one screen for all the Claude Code agents on this Mac. You operate it with the keyboard only. It shows which agents wait for you. It shows the last message of each agent. It sends your answers to the agents.

### 2.2 What Kaching does not do

Kaching does not have its own AI. It does not decide for you. It reads the session records of the agents. It writes the text that you select into the Terminal window of the agent. The agent then does the work.

Kaching can only send text to agents in Terminal.app. It shows agents in Claude Desktop, VS Code or Cursor, but you cannot send text to them.

## 3. Install and start

### 3.1 Install Kaching

1. Make sure that Go is installed. If it is not installed, write `brew install go` in a terminal.
2. Write `~/.claude/kaching/terminal/build.sh` in a terminal.
3. Make sure that the terminal shows `built /Users/<you>/.local/bin/kaching`.

### 3.2 Add the start key in Raycast

1. Open Raycast.
2. Go to Extensions, then Script Commands, then Add Directories.
3. Add the folder `~/.claude/kaching/ui/raycast`.
4. Find the command `Open Agent Terminal`.
5. Give it a hotkey.

### 3.3 Start Kaching

1. Push the hotkey of `Open Agent Terminal`.
2. If Kaching does not operate, Raycast opens a new Terminal window. Kaching starts in it and fills the main display.
3. If Kaching operates, Raycast shows its window.

You can also write `kaching` in any Terminal window.

The window must be a minimum of 60 columns wide and 16 lines high.

### 3.4 Stop Kaching

1. Push `/`.
2. Write `QUIT`.
3. Push `Enter`.

You can also push `Ctrl+C`.

## 4. The screen

### 4.1 Parts of the screen

The screen has five parts, from the top to the bottom:

1. The tab bar. It shows the views and their codes. The current view is white.
2. The command line. It shows the current code, the time, the number of agents and the number of agents that wait for you. It also shows short messages from Kaching.
3. The agent list (left). It shows all agents in three groups.
4. The agent panel (right). It shows the selected agent.
5. The key bar (bottom). The first line shows the keys for the current view. The second line shows the fixed messages.

### 4.2 The agent list

The agent list has three groups:

| Group | Agents in the group |
|---|---|
| `WAITING` | The agent stopped and waits for you: it has a question (`input`), it cannot continue (`blocked`), it finished (`done`), or it is ready for release (`ready`). The agent that waited the longest time is at the top. |
| `WORKING` | The agent does work now. |
| `IDLE` | The agent does not do work and does not wait for an answer. |

Each line shows the name of the agent, its state and the time since the last change. The selected agent has an orange line.

A dark name shows an agent that is not in Terminal.app. You can read its messages, but you cannot send text to it.

### 4.3 The agent panel

The agent panel shows the selected agent:

- The top line shows its name, its folder and its git branch.
- The text is the end of its last message.
- The numbered lines are the answers that it asks you to select from.
- `FILES IT MENTIONED` shows the files that its last message names. Each file has a letter.
- The `reply` line shows the text that you write.

An orange frame shows that the agent waits for you.

### 4.4 Colours

| Colour | Meaning |
|---|---|
| Orange | A key, an agent that waits for you, or the selected item. |
| White | The current view, or a name that is important. |
| Grey | Normal text. |
| Dark grey | Frames, idle agents, and agents that you cannot send text to. |

## 5. Modes

Kaching has four modes. The command line shows the current mode.

| Mode | How you start it | What the keys do | How you stop it |
|---|---|---|---|
| Key mode | This is the normal mode. | Each key does an action. | – |
| Command mode | Push `/`. | You write a code. | `Enter` does the code. `Esc` cancels. |
| Write mode | Push `r`. | You write a message. | `Enter` sends it. `Esc` cancels. |
| File mode | Push `o`. | You select a file. | Push the letter of the file. Any other key cancels. |

In command mode and write mode:

- `Backspace` removes the last letter.
- `Ctrl+U` removes all the text.

## 6. Procedures

### 6.1 Find the agents that wait for you

1. Look at the command line. It shows the number of agents that wait for you.
2. Push `Space`. Kaching selects the next agent that waits for you.
3. Read the agent panel.
4. Push `Space` again to go to the next agent.

### 6.2 Select an answer

Use this procedure when the agent panel shows numbered answers.

1. Select the agent.
2. Read the numbered answers.
3. Push the number of the answer.
4. Make sure that the command line shows `sent` and then `✓ <name> is on it`.

When the agent shows a menu, Kaching pushes only the number key in the agent window. When the agent writes a numbered list in its message, Kaching writes the number and pushes `Enter`.

### 6.3 Send a fixed message

1. Select the agent.
2. Push the key of the message, for example `f` for "fix it".
3. For a message on the space bar, push `Space`, then push the second key in less than half a second.
4. Make sure that the command line shows `✓ <name> is on it`.

### 6.4 Write a message

1. Select the agent.
2. Push `r`.
3. Write your message.
4. Push `Enter`.
5. Make sure that the command line shows `✓ <name> is on it`.

To cancel the message, push `Esc` before step 4.

### 6.5 Open a file that an agent wrote about

1. Select the agent.
2. Find the file in `FILES IT MENTIONED`.
3. Push `o`.
4. Push the letter of the file.

The file opens in its default application. A folder opens in Finder.

To see the files of all agents, go to the files view (`/FL`). Select a file. Push `Enter`.

### 6.6 Go to the Terminal window of an agent

1. Select the agent.
2. Push `g`.
3. The Terminal window of the agent comes to the front.
4. To go back, push the Raycast hotkey of `Open Agent Terminal`.

### 6.7 Remove an agent from the waiting list

Use this procedure when an agent waits but you do not want to answer now.

1. Select the agent.
2. Push `x`.
3. Make sure that the command line shows `Dismissed <name>`.

The agent window goes back to its position on the second display. The agent does not get a message.

### 6.8 Look at all agents together

1. Push `W`. The wall shows each agent as a tile.
2. Push the number of a tile to select it.
3. Push `z` to show the tile on the full screen.
4. Push `z` again to go back to the wall.
5. Push `Esc` to go back to the desk.

The tiles change size with the window. A wide window shows more tiles in each line.

### 6.9 Look at the repos

1. Push `/`.
2. Write `RP`.
3. Push `Enter`.
4. Read the repos that need attention.

### 6.10 Do a proposal of the learner

1. Push `/`, write `PR`, push `Enter`.
2. Push `j` or `k` to select a proposal.
3. Push `Enter` to read the full proposal. Push `q` to close it.
4. Do one of these steps:
   - To approve it, push `a`. Write the code that shows on the screen. Push `Enter`.
   - To reject it, push `x`.
   - To hide it for 7 days, push `z`.

Only a person can approve a proposal. An agent cannot approve it.

### 6.11 Do work on Paperclip issues

1. Push `/`, write `PC`, push `Enter`.
2. Push `j` or `k` to select an issue. The lines below the issue show why it waits.
3. To write a comment, push `r`. Write the comment. Push `Enter`.
4. To open the issue in your browser, push `Enter`.

Orange issues need you. If Paperclip does not operate, the view shows `Paperclip isn't running (localhost:3100)`.

## 7. Change the keys and the fixed messages

All keys and fixed messages are in the file `~/.agent/terminal/keys.toml`. Kaching writes this file when it starts the first time.

### 7.1 Change a fixed message

1. Open `~/.agent/terminal/keys.toml` in a text editor.
2. Find the `[[reply]]` block of the message.
3. Change the `text` line. Kaching writes this text into the agent window.
4. Change the `label` line. The key bar shows this label.
5. Save the file.
6. Make sure that the command line of Kaching shows `keys.toml reloaded`.

### 7.2 Add a fixed message

1. Open `~/.agent/terminal/keys.toml`.
2. Add a new block at the end of the file:

   ```toml
   [[reply]]
   key = "e"
   label = "explain"
   text = "explain what you changed in two lines"
   ```

3. For a key on the space bar, write `key = "space e"`.
4. Save the file.

Do not use a key that Kaching uses for an action (for example `j`, `k`, `r`, `o`, `g`, `x`, `W`, `z`, `/`). The action has priority.

### 7.3 Change an action key

1. Open `~/.agent/terminal/keys.toml`.
2. Find the `[keys]` block.
3. Change the key of the action, for example `next = "n"`.
4. Save the file.

If you remove a line, Kaching uses the default key.

### 7.4 Change how files open

1. Open `~/.agent/terminal/keys.toml`.
2. Change the `open_cmd` line, for example `open_cmd = "code"` for VS Code.
3. Save the file.

## 8. Kaching and the Terminal windows

Kaching does not move, resize or close Terminal windows. When you start, stop or reload Kaching, all Terminal windows stay where they are. The agent sessions continue.

Kaching only does these things to an agent window:

- It writes your text into the window.
- It pushes `Enter` or a number key in the window. For this, the window comes to the front for approximately 0.1 seconds.
- When you push `g`, it brings the window to the front.

Kaching does not start new agent sessions.

## 9. How Kaching sends text

Kaching writes the text into the Terminal window of the agent. This does not change the window that you use.

Kaching then pushes `Enter` in the agent window. For this key, the agent window comes to the front for approximately 0.1 seconds. Then Kaching comes back to the front.

Kaching examines the agent window after it pushes `Enter`. If the text did not go, Kaching pushes `Enter` again.

## 10. Problems and solutions

| Problem | Cause | Solution |
|---|---|---|
| The command line shows `isn't in a Terminal tab: look only`. | The agent is not in Terminal.app. | Push `g` to go to the agent. Write your answer there. |
| The command line shows `has no option 2`. | The agent did not give numbered answers, or Kaching did not read them yet. | Wait 2 seconds. Push `R`. Try again. Or push `r` and write the answer. |
| The command line shows `typed but not submitted`. | The agent window did not accept `Enter`. | Push `g`. Push `Enter` in the agent window. |
| An agent is not in the list. | The agent stopped, or it is a background process. | Push `R`. If it does not show, look in Terminal. |
| A fixed message key does nothing. | You are not on the desk or on the wall. | Push `Esc`. Push the key again. |
| `keys.toml` shows an error on the command line. | The file has an error. | Correct the line that the error shows. Kaching uses the default keys until you correct it. |
| The screen shows `kaching needs at least 60x16`. | The window is too small. | Make the window larger. |
| The PC view shows `Paperclip isn't running`. | The Paperclip service does not operate. | Start Paperclip. Then go to `PC` again. |

## 11. Files

| File | Contents |
|---|---|
| `~/.local/bin/kaching` | The program. |
| `~/.agent/terminal/keys.toml` | Your keys and fixed messages. |
| `~/.agent/terminal/open` | Tells the monitor queue that Kaching operates and which agent is selected. Kaching removes it when it stops. |
| `~/.agent/terminal/send.js` | The script that sends text to Terminal windows. Kaching writes it when it starts. |
| `~/.claude/kaching/terminal/` | The source code. |
| `~/.claude/kaching/docs/superpowers/specs/2026-10-17-agent-terminal-design.md` | The design. |
