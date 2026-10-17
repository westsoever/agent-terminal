# Kaching agent terminal: user manual

Written in ASD-STE100 Simplified Technical English. Labels on the screen (for example `WAITING`, `IN`, `PC`) are technical names. This manual shows them in `code` letters.

## 1. Quick reference

### 1.1 Go to a view

Push `/`, write the code, then push `Enter`.

| Code | View | It shows |
|---|---|---|
| `IN` | Inbox (the desk) | All agents and the selected agent. This is the start view. |
| `AG` | Agents (the wall) | All agents as tiles. You can also push `W`. |
| `FL` | Files | The last 30 files that the agents wrote about, newest first. Files of agents that stopped stay in the list. |
| `RP` | Repos | The git sync check: repos with work that you can lose. |
| `RC` | Recaps | The last recap of each agent. Claude Code writes a recap when you come back to a session after some time. The desk also shows the recap of the selected agent above its last message. |
| `PR` | Proposals | The changes that the learner proposes. The tab is orange when proposals are open. |
| `PC` | Paperclip | Paperclip issues that need you, and issues in progress. The selected issue shows on the right, with what it asks you. The tab is orange when an issue needs you. |
| `NW` | New agent | Start a background agent. Refer to section 6.15. |
| `STOP` | – | Stop the selected background agent. Its conversation stays. |
| `A3` | Agent 3 | The desk, with agent 3 selected. Use a number from 1 to 9. |
| `ching` | An agent by name | The desk, with the first agent whose name starts with these letters. |
| `HELP` | Help | The key list. You can also push `?`. |
| `QUIT` | – | Kaching stops. You can also push `Ctrl+C`. |

Push `Esc` to go back to the desk from any view.

### 1.2 Keys on the desk

The right hand does the most frequent work: `j` goes up, `l` goes down, `k` opens the message box.


| Key | Result |
|---|---|
| `l` or `↓` | Select the next agent (down the list). |
| `j` or `↑` | Select the previous agent (up the list). |
| `Space` | Select the agent in `INPUT` that has waited the longest. |
| `1` to `9` | Send the answer with that number to the selected agent. |
| `k` | Write a message to the selected agent. `Enter` sends it. `Esc` keeps it as a draft. Refer to section 1.4. |
| `o`, then `a` to `i` | Open the file with that letter. |
| `g` | Show the Terminal window of the selected agent, where it is. For a background agent, open a new Terminal window that is attached to it. |
| `h` | Bring the window of the selected agent to monitor 1 and into focus, so that you can write in it. Drag it back to monitor 2 to put it back in its position. |
| `x` | Remove the selected agent from the waiting list. You do not send an answer. |
| `Enter`, `←`, `→` | When the agent asks a question: confirm, or go to the previous or next question. |
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

### 1.4 Keys when you write a message

| Key | Result |
|---|---|
| `Enter` | Send the message. |
| `Option+Enter`, `Ctrl+J`, or `\` then `Enter` | Start a new line. |
| `Option` + a key | Write the character that your keyboard layout puts on this key, for example `Option+L` for `@`, `Option+5` for `[`, `Option+8` for `{`, `Option+7` for `|`. |
| `@`, then letters | Show the files of the agent folder that agree with the letters. |
| `/` at the start, then letters | Show the commands and skills that agree with the letters, with their descriptions: Claude Code commands, your commands and skills, the commands and skills of the agent folder and its parent folders, and the enabled plugins. |
| `Tab` or `Enter` | Put the selected suggestion into the message. |
| `↑`, `↓` | Select a suggestion. When there are no suggestions, move between lines. |
| `Ctrl+V` | Paste an image from the clipboard. Kaching saves it as a file and writes its path. The agent opens the file. If the clipboard has no image, Kaching pastes the text. |
| `Cmd+V` | Paste text. Line breaks stay. |
| `←`, `→`, `Option+←`, `Option+→` | Move by one letter or by one word. |
| `Ctrl+A`, `Ctrl+E` | Go to the start or the end of the line. |
| `Option+Backspace`, `Ctrl+W` | Remove the word before the cursor. |
| `Ctrl+K`, `Ctrl+U` | Remove the text after or before the cursor. |
| `Esc` or `Ctrl+C` | Close the box. Kaching keeps the text as a draft for this agent. Push `k` to open it again. |

The top line does not show your message. It shows only the name of the agent that gets the message.

### 1.5 Keys on the wall

| Key | Result |
|---|---|
| `1` to `9` | Select the tile with that number. |
| `z` | Show the selected tile on the full screen. Push `z` again to go back. |
| `l`, `j`, `Space` | Select the next or previous agent, or the agent in `INPUT` that has waited the longest. |
| `Esc` | Go back to the desk. |

When a tile shows on the full screen, the number keys send answers, as on the desk.

### 1.6 Keys in the lists (FL, RC, PR, PC, RP)

| View | Key | Result |
|---|---|---|
| All lists | `l`, `j` | Select the next or previous line. |
| `FL` | `Enter` | Open the selected file. |
| `RC` | `Enter` | Go to the desk, with that agent selected. |
| `PR` | `Enter` | Show the full proposal. Push `q` to close it. |
| `PR` | `a` | Approve the proposal. The screen asks you to write a code. |
| `PR` | `x` | Reject the proposal. |
| `PR` | `z` | Hide the proposal for 7 days. |
| `PC` | `1` to `9` | Give that answer to what the issue asks: for example approve, decline, or decline with a reason. |
| `PC` | `↑`, `↓` | Scroll the issue on the right: its description, its thread and the full request. |
| `PC` | `Enter` | Open the issue in Paperclip in your browser. |
| `PC` | `k` | Write a comment on the issue. `Enter` sends it. |

## 2. Introduction

### 2.1 What Kaching is

Kaching is one screen for all the Claude Code agents on this Mac. You operate it with the keyboard only. It shows which agents wait for you. It shows the last message of each agent. It sends your answers to the agents.

### 2.2 What Kaching does not do

Kaching does not have its own AI. It does not decide for you. It reads the session records of the agents. It writes the text that you select into the Terminal window of the agent. The agent then does the work.

Kaching can only send text to agents in Terminal.app and to background agents. It shows agents in Claude Desktop, VS Code or Cursor, but you cannot send text to them.

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

1. The tab bar. It shows the views and their codes. The current view is white. The `PR` tab is orange when proposals are open. The `PC` tab is orange when a Paperclip issue needs you. The number in the tab is how many.
2. The command line. It shows the current code, the time, the number of agents and the number of agents that wait for you. It also shows short messages from Kaching.
3. The agent list (left). It shows all agents in three groups.
4. The agent panel (right). It shows the selected agent.
5. The key bar (bottom). The first line shows the keys for the current view. The second line shows the fixed messages. On the right, the two lines show your Claude usage: the 5-hour window above the 7-day limit. Each line shows the exact percentage, a bar, and the time until it starts again (`↻ 1h33m`, `↻ 1d08h`). When the screen is narrow, keys at the end of the lines give way.

The usage comes from the statusline: `~/.claude/statusline-command.sh` writes the `rate_limits` of each session to `~/.agent/usage/<session id>.json` when they change, and Kaching shows the newest file. Before any session has updated its statusline, the bar says `no statusline reading yet`.

### 4.2 The agent list

The agent list has three groups:

| Group | Agents in the group |
|---|---|
| `WAITING` | The agent stopped and waits for you: its screen shows a question or an approval (`asks`), it has a question (`input`), it cannot continue (`blocked`), it finished (`done`), or it is ready for release (`ready`). The agent that waited the longest time is at the top. |
| `WORKING` | The agent does work now. |
| `IDLE` | The agent does not do work and does not wait for an answer. |

Each line shows the name of the agent, its state and the time since the last change. The selected agent has an orange line.

Agents in the same Terminal window (its tabs, or macOS window tabs) are one family. The agent in the first tab is the lead. Its sub-sessions show below it with `└`, and the lead shows `+2` for two sub-sessions. A family stays together. It shows in the group of its most urgent agent: when a sub-session waits, the family is in `WAITING`.

A dark name shows an agent that is not in Terminal.app. You can read its messages, but you cannot send text to it.

A `◦` before the name shows a background agent: a session that runs without a window (`claude --bg`). You can send text to it as to the other agents.

### 4.3 The agent panel

The agent panel shows the selected agent:

- The top line shows its name, its folder and its git branch. On the right it shows the model and effort of its last reply, for example `[Opus 5.5] high`. The wall tiles show it too; a narrow tile shows only the model.
- The text is the conversation: your prompts and its messages, the newest at the bottom. Your prompts start with `›` and have a lighter background, so you can find them easily. Tables show as tables (see 7.5).
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
| Green, amber, red | Claude usage: below 50%, from 50%, from 80%. |

## 5. Modes

Kaching has four modes. The command line shows the current mode.

| Mode | How you start it | What the keys do | How you stop it |
|---|---|---|---|
| Key mode | This is the normal mode. | Each key does an action. | – |
| Command mode | Push `/`. | You write a code. | `Enter` does the code. `Esc` cancels. |
| Write mode | Push `k`. | You write a message. Refer to section 1.4. | `Enter` sends it. `Esc` keeps it as a draft. |
| File mode | Push `o`. | You select a file. | Push the letter of the file. Any other key cancels. |

In command mode and write mode:

- `Backspace` removes the last letter.
- `Ctrl+U` removes all the text.

## 6. Procedures

### 6.1 Find the agents that wait for you

1. Look at the command line. It shows the number of agents that wait for you.
2. Push `Space`. Kaching selects the agent in `INPUT` that has waited the longest. Agents that are only done (`WAITING`) are skipped. An agent that shows a question or an approval on its screen waits from the moment that it showed it, not from the start of its turn. Kaching reads the screens of all busy agents, so such an agent is in `INPUT` also when you never selected it.
3. Read the agent panel and answer it.
4. Push `Space` again. Kaching selects the agent in `INPUT` that now has waited the longest. Pushing `Space` again before you answer keeps the same agent.

### 6.2 Select an answer

Use this procedure when the agent panel shows numbered answers.

1. Select the agent.
2. Read the numbered answers.
3. Push the number of the answer.
4. Make sure that the command line shows `sent` and then `✓ <name> is on it`.

When the agent shows a menu, Kaching pushes only the number key in the agent window. When the agent writes a numbered list in its message, Kaching writes the number and pushes `Enter`.

### 6.3 Answer a question with more than one part

Use this procedure when the agent panel shows `THE AGENT ASKS`. Kaching shows the question as the agent shows it on its own screen. This includes questions with more parts, plan approvals and permission prompts.

1. Select the agent. Its state is `asks`.
2. Read the question and its numbered answers.
3. Push the number of your answer. The agent goes to the next part, and Kaching shows it.
4. Do step 3 again for each part.
5. On the last screen (`Review your answers`), push `1` to send all answers.

To write your own answer, push `k`, write the answer, and push `Enter`. Kaching selects `Type something.` for you and sends your text.

To go back to a part, push `←`. To confirm a selection, push `Enter`.

### 6.4 Send a fixed message

1. Select the agent.
2. Push the key of the message, for example `f` for "fix it".
3. For a message on the space bar, push `Space`, then push the second key in less than half a second.
4. Make sure that the command line shows `✓ <name> is on it`.

### 6.5 Write a message

1. Select the agent.
2. Push `k`. The message box opens below the text of the agent.
3. Write your message. To start a new line, push `Option+Enter`.
4. Push `Enter`.
5. Make sure that the command line shows `✓ <name> is on it`.

To stop before step 4, push `Esc`. Kaching keeps your text as a draft. When you push `k` again for this agent, the draft comes back.

### 6.6 Refer to a file or a command in a message

1. In the message box, write `@` and some letters of the file name.
2. A list of files in the folder of the agent shows above the box.
3. Push `↑` or `↓` to select the file.
4. Push `Tab`. Kaching writes the file as `@path`.

For a command, write `/` at the start of the message, then some letters. Select the command as in steps 3 and 4.

### 6.7 Send an image

1. Copy the image, for example with `Cmd+Ctrl+Shift+4` for a part of the screen.
2. Push `k` to open the message box.
3. Push `Ctrl+V`. Kaching saves the image in `~/.agent/terminal/images/` and writes its path.
4. Write your question about the image.
5. Push `Enter`. The agent opens the image file.

### 6.8 Open a file that an agent wrote about

1. Select the agent.
2. Find the file in `FILES IT MENTIONED`.
3. Push `o`.
4. Push the letter of the file.

The file opens in its default application. A folder opens in Finder.

To see the files of all agents, go to the files view (`/FL`). Select a file. Push `Enter`.

### 6.9 Go to the Terminal window of an agent

1. Select the agent.
2. Push `g`.
3. The Terminal window of the agent comes to the front.
4. To go back, push the Raycast hotkey of `Open Agent Terminal`.

### 6.10 Remove an agent from the waiting list

Use this procedure when an agent waits but you do not want to answer now.

1. Select the agent.
2. Push `x`.
3. Make sure that the command line shows `Dismissed <name>`.

The agent window goes back to its position on the second display. The agent does not get a message.

### 6.11 Look at all agents together

1. Push `W`. The wall shows each agent as a tile.
2. Push the number of a tile to select it.
3. Push `z` to show the tile on the full screen.
4. Push `z` again to go back to the wall.
5. Push `Esc` to go back to the desk.

The tiles change size with the window. A wide window shows more tiles in each line.

### 6.12 Look at the repos

1. Push `/`.
2. Write `RP`.
3. Push `Enter`.
4. Read the repos that need attention.

### 6.13 Do a proposal of the learner

1. Push `/`, write `PR`, push `Enter`.
2. Push `l` (down) or `j` (up) to select a proposal.
3. Push `Enter` to read the full proposal. Push `q` to close it.
4. Do one of these steps:
   - To approve it, push `a`. Write the code that shows on the screen. Push `Enter`.
   - To reject it, push `x`.
   - To hide it for 7 days, push `z`.

Only a person can approve a proposal. An agent cannot approve it.

### 6.14 Do work on Paperclip issues

1. Push `/`, write `PC`, push `Enter`.
2. Push `l` (down) or `j` (up) to select an issue. Orange issues need you. The issue shows on the right: its title, its description, its thread (your comments have a lighter background) and the full request, for example the pull request that it asks you to review.
3. Push `↑` or `↓` to read more of the issue.
4. At the bottom, `IT ASKS YOU` shows the question and the numbered answers:

   | What it asks | Answers |
   |---|---|
   | A confirmation (for example "Review the PR") | `1` approve, `2` decline, `3` decline with a reason |
   | A question with one answer | `1` to `9`: the options |
   | A recovery action (`RECOVERY WAITS FOR YOU`) | `1` retry: hand it back to the agent, `2` done: mark the issue done, `3` blocked: keep it blocked |

5. Push the number of your answer. Make sure that the command line shows `✓ <answer> · <issue>`.
6. For `3` (decline with a reason), the box opens. Write the reason. Push `Enter`.
7. To write a comment, push `k`. Write the comment. Push `Enter`.
8. To open the issue in your browser, push `Enter`.

When Kaching cannot answer a request (a question with more parts, a list of choices), the panel tells you to open it in the browser. If Paperclip does not operate, the view shows `Paperclip isn't running (localhost:3100)`.

### 6.15 Start a background agent

A background agent is a Claude Code session without a window. It does the work while you do other work.

1. Select an agent that works in the folder that you want, or know the folder.
2. Push `/`, write `NW`, push `Enter`. To use another folder, write it after `NW`: a path (`NW ~/bbq/soii`), a folder in `~/bbq` (`NW soii`), or the start of an agent name (`NW miso`).
3. The message box opens with `new background agent in <folder>`. Write the task.
4. Push `Enter`. The command line shows `✓ background agent <id> started`. Kaching selects the new agent when it shows in the list.
5. Answer it as any other agent: push `k`, or a number key.

To see its own screen, push `g`. A new Terminal window opens and shows the agent. Closing that window does not stop the agent.

To stop it, select it, push `/`, write `STOP`, push `Enter`. To open it again later, write `claude --resume <id>` in a terminal.

The folder must be trusted by Claude Code. If the command line shows `Workspace not trusted`, write `claude` in that folder once and accept.

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

Do not use a key that Kaching uses for an action (for example `l`, `j`, `k`, `o`, `g`, `x`, `W`, `z`, `/`). The action has priority.

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

### 7.5 Change how tables show

Kaching draws the markdown tables in an agent's messages as tables.

1. Open `~/.agent/terminal/keys.toml`.
2. Change the `tables` line. The line must be above `[keys]`.

   | Value | Tables show as |
   |---|---|
   | `auto` | Columns under a rule. When a column gets narrower than 10 characters (a small tile or window), each row shows as a small block. This is the default. |
   | `rule` | Always columns under a rule. |
   | `grid` | Every cell in a frame. |
   | `records` | Always blocks: the first cell on top, then each other column as its header and value. |

3. Save the file.

## 8. Kaching and the Terminal windows

Kaching does not move, resize or close Terminal windows. When you start, stop or reload Kaching, all Terminal windows stay where they are. The agent sessions continue.

Kaching only does these things to an agent window:

- It writes your text into the window.
- It pushes `Enter` or a number key in the window. For this, the window comes to the front for approximately 0.1 seconds.
- When you push `g`, it brings the window to the front.

Kaching starts a new agent session only when you write `NW` (section 6.15). That agent runs in the background, without a window. `g` on a background agent opens one new Terminal window for it.

## 9. How Kaching sends text

Kaching writes the text into the Terminal window of the agent. This does not change the window that you use.

Kaching then pushes `Enter` in the agent window. For this key, the agent window comes to the front for approximately 0.1 seconds. Then Kaching comes back to the front.

Kaching examines the agent window after it pushes `Enter`. If the text did not go, Kaching pushes `Enter` again.

A background agent has no window. Kaching opens `claude attach <id>` out of sight, pastes the text, pushes `Enter` and closes the attach again. The agent continues. This takes approximately 2 seconds.

## 10. Problems and solutions

| Problem | Cause | Solution |
|---|---|---|
| The command line shows `isn't in a Terminal tab: look only`. | The agent is not in Terminal.app. | Push `g` to go to the agent. Write your answer there. |
| The command line shows `has no option 2`. | The agent did not give numbered answers, or Kaching did not read them yet. | Wait 2 seconds. Push `R`. Try again. Or push `k` and write the answer. |
| The command line shows `typed but not submitted`. | The agent window did not accept `Enter`. | Push `g`. Push `Enter` in the agent window. |
| An agent is not in the list. | The agent stopped, or it is a background process. | Push `R`. If it does not show, look in Terminal. |
| A fixed message key does nothing. | You are not on the desk or on the wall. | Push `Esc`. Push the key again. |
| `keys.toml` shows an error on the command line. | The file has an error. | Correct the line that the error shows. Kaching uses the default keys until you correct it. |
| `Option` + a key writes a wrong character. | Terminal sends `Option` as Meta, and Kaching reads your layout when it starts. | Stop and start Kaching after you change the keyboard layout. |
| The screen shows `kaching needs at least 60x16`. | The window is too small. | Make the window larger. |
| The PC view shows `Paperclip isn't running`. | The Paperclip service does not operate. | Start Paperclip. Then go to `PC` again. |

## 11. Files

| File | Contents |
|---|---|
| `~/.local/bin/kaching` | The program. |
| `~/.agent/terminal/keys.toml` | Your keys and fixed messages. |
| `~/.agent/terminal/open` | Tells the monitor queue that Kaching operates and which agent is selected. Kaching removes it when it stops. |
| `~/.agent/terminal/send.js` | The script that sends text to Terminal windows. Kaching writes it when it starts. |
| `~/.agent/terminal/files.json` | The last 30 files that the agents wrote about (the `FL` view). |
| `~/.claude/kaching/terminal/` | The source code. |
| `~/.claude/kaching/docs/superpowers/specs/2026-10-17-agent-terminal-design.md` | The design. |
