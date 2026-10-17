# Kaching agent terminal: user manual

Written in ASD-STE100 Simplified Technical English. Labels on the screen (for example `WAITING`, `IN`, `PC`) are technical names. This manual shows them in `code` letters.

## 1. Quick reference

### 1.1 Go to a view

Push `/`, write the code, then push `Enter`.

| Code | View | It shows |
|---|---|---|
| `IN` | Inbox (the desk) | All agents and the selected agent. This is the start view. |
| `FL` | Files | The last 30 files that the agents wrote about, newest first. Files of agents that stopped stay in the list. |
| `RP` | Repos | The git sync check: repos with work that you can lose. |
| `RC` | Recaps | The last recap of each agent. Claude Code writes a recap when you come back to a session after some time. The desk also shows the recap of the selected agent above its last message. |
| `PR` | Pull requests | The open GitHub pull requests that involve you (yours, assigned to you, that ask your review, or where you commented or were mentioned), the last updated first. The number in the tab is how many. |
| `PO` | Proposals | The changes that the learner proposes. The tab is orange when proposals are open. |
| `PC` | Paperclip | Paperclip issues and company approvals that need you, and issues in progress. The selected row shows on the right, with what it asks you. The tab is orange when a row needs you. |
| `NW` | New agent | Start a background agent. You can add a folder, a model, an effort and a mode, for example `NW soii sonnet high`. Refer to section 6.15. |
| `ALL` | Write to a group | Write one message to a group of agents: `ALL waiting`, `ALL input`, `ALL idle` or `ALL working`. Refer to section 6.17. |
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
| `a` | When the agent asks questions: take the recommended answer of each question and send all. Refer to section 6.3. |
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
| `@`, then letters | Show the other sessions and the files of the agent folder that agree with the letters. A session shows with the word `session`. |
| `@Name` at the start | Send the message to the session with that name, not to the selected agent. Refer to section 6.18. |
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
| `PR` | `Enter` | Open the pull request on GitHub in your browser. |
| `PR` | `k` | Open the pull request on the right: its branch, size, checks, description, files and thread. Push `k` again to write a comment for a new agent. |
| `PR` | `1`, `2` | With the pull request open: start a new agent that reviews it (`1`) or merges it when it is ready (`2`). |
| `PR` | `↑`, `↓` | Scroll the pull request on the right. |
| `PR` | `Esc` | Close the pull request on the right. Push `Esc` again to go to the desk. |
| `PO` | `Enter` | Show the full proposal. Push `q` to close it. |
| `PO` | `a` | Approve the proposal. The screen asks you to write a code. |
| `PO` | `x` | Reject the proposal. |
| `PO` | `z` | Hide the proposal for 7 days. |
| `PC` | `1` to `9` | Give that answer to what the row asks: for example approve, reject, or decline with a reason. In a list, tick or untick the item with that number. In a question, pick that option. With verdicts, give the current item that verdict. |
| `PC` | `s` | Send what you ticked, picked or judged. |
| `PC` | `x` | Decline a list of choices or of suggested tasks. |
| `PC` | `r` | Decline it with a reason. The box opens. |
| `PC` | `←`, `→` | Go to the previous or next question, or item. |
| `PC` | `o` | Write your own answer to a question. |
| `PC` | `a` | Give the recommended answer to every question and send. Kaching refuses if one question has none. |
| `PC` | `n`, `p` | Show the next or previous page of a long list. |
| `PC` | `↑`, `↓` | Scroll the row on the right: its description, its thread and the full request. |
| `PC` | `Enter` | Open the row in Paperclip in your browser. |
| `PC` | `k` | Write a comment on the row. `Enter` sends it. |

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

1. The tab bar. It shows the views and their codes. The current view is white. The `PO` tab is orange when proposals are open. The `PC` tab is orange when a Paperclip issue needs you. The number in the tab is how many.
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

**Quick approve.** An agent can mark the answer that it recommends: the label ends with `(Recommended)`. Kaching shows each question with its recommended answer under `RECOMMENDED`, with a `★`. Push `a` (quick approve) to take the recommended answer of each question and send all answers. Kaching does it with the keys that you would push. A question with more choices gets all of its recommended answers.

If one question has no recommended answer, quick approve does nothing. The command line names the question. Answer that question yourself. Then push `a` again for the rest.

Kaching reads the questions of all agents in the same way, also for background agents. A permission prompt or a plan approval has no recommended answer: answer it with the number keys.

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

1. Push `/`, write `PO`, push `Enter`.
2. Push `l` (down) or `j` (up) to select a proposal.
3. Push `Enter` to read the full proposal. Push `q` to close it.
4. Do one of these steps:
   - To approve it, push `a`. Write the code that shows on the screen. Push `Enter`.
   - To reject it, push `x`.
   - To hide it for 7 days, push `z`.

Only a person can approve a proposal. An agent cannot approve it.

### 6.14 Do work on Paperclip issues

1. Push `/`, write `PC`, push `Enter`.
2. Push `l` (down) or `j` (up) to select a row. Orange rows need you. A row is an issue, or a company approval (`APPROVAL`). The row shows on the right: its title, its description, its thread (your comments have a lighter background) and the full request, for example the pull request that it asks you to review.
3. Push `↑` or `↓` to read more of the row.
4. At the bottom, `IT ASKS YOU` shows the question. Below it, a key line shows what each key does. Find the request in this table:

   | What it asks | Keys |
   |---|---|
   | A confirmation (for example "Review the PR") | `1` approve, `2` decline, `3` decline with a reason |
   | A question with one answer | `1` to `9`: the options |
   | A recovery action (`RECOVERY WAITS FOR YOU`) | `1` retry: hand it back to the agent, `2` done: mark the issue done, `3` blocked: keep it blocked |
   | A company approval (`APPROVAL`) | `1` approve, `2` reject, `3` request revision (a note is a must), `4` approve with a note, `5` reject with a note |
   | A list to tick (choices, or suggested tasks) | `1` to `9` tick or untick, `s` send, `x` decline, `r` decline with a reason |
   | Questions with more parts, several answers, or your own answer | `1` to `9` pick, `←` `→` other question, `o` your own answer, `s` send, `a` recommended answers |
   | Items that wait for a verdict | `1` to `3` give the verdict, `←` `→` other item, `s` send |
   | A connection request, or a request that Kaching does not know | None. Push `Enter` to open it in your browser. |

5. Push the keys of your request. Make sure that the command line shows `✓ <answer> · <row>`.
6. For a decline with a reason, or an answer with a note, the box opens. Write the text. Push `Enter`.
7. To write a comment, push `k`. Write the comment. Push `Enter`. This also works on an approval.
8. To open the row in your browser, push `Enter`.

**Company approval.** The panel shows the payload: for example the name, the role and the monthly budget of an agent to hire. It also shows the issue that the approval belongs to.

- Push `1` to approve or `2` to reject. Kaching sends the answer at once.
- To add a note, push `4` (approve) or `5` (reject). Write the note. Push `Enter`.
- To send the approval back for changes, push `3`. Write what to change. Push `Enter`.
- A `board ask` (a request to the board) has no keys. Paperclip wants you to review its action in the browser first. Push `Enter` to open it.

**List to tick.** A list of choices starts with the choices that the request ticked. A list of suggested tasks starts with all tasks ticked.

- Push the number of an item to tick it. Push it again to untick it. `[x]` shows a ticked item.
- A task needs its parent. When you tick a task, its parent is ticked too. When you untick a parent, its tasks are unticked too.
- When the list is longer than the panel, push `n` for the next page and `p` for the previous page.
- Push `s` to send. For tasks, Kaching accepts the ticked tasks. When all tasks are ticked, it accepts all.
- Push `x` to decline. To decline with a reason, push `r`, write the reason, push `Enter`.
- When Paperclip refuses (for example, you ticked too many items), the command line shows its message. Change the ticks. Push `s` again.

**Questions with more parts.** Kaching shows one question at a time, for example `question 2 of 3`. A `✓` after it marks each question that has an answer.

- Push the number of an option. For a question with one answer, Kaching then goes to the next question.
- For a question with several answers, push the number of each option. Then push `→`.
- To write your own answer, push `o`. Write the answer. Push `Enter`. Some questions take only a written answer.
- To go back to a question, push `←`.
- Push `s` to send all answers at once. When a question needs an answer and has none, Kaching names it and sends nothing.
- A star (`★`) marks the answer that the request recommends. A label that ends in `(Recommended)` has the same mark.
- When every question has a star, push `a`. Kaching takes the starred answers and sends them at once.
- When a question has no star, `a` sends nothing. The command line shows which question it is. Kaching does not guess.

**Items that wait for a verdict.** The list shows each item and its verdict. `>` marks the current item. Its full text shows above `IT ASKS YOU`.

- Push `1`, `2` or `3` to give the current item that verdict. The key line shows the verdicts. Kaching then goes to the next item.
- A verdict can need a reason, usually `reject`. Then the box opens. Write the reason. Push `Enter`.
- To go to another item, push `←` or `→`.
- Push `s` to send the verdicts. You can send some items now and the others later. The command line shows how many are left.
- An item that has a verdict already stays as it is.

When Kaching cannot answer a request (a connection request, or a kind that a later Paperclip adds), the panel tells you to open it in the browser. Kaching never sends an answer that it does not understand. If Paperclip does not operate, the view shows `Paperclip isn't running (localhost:3100)`.

### 6.15 Start a background agent

A background agent is a Claude Code session without a window. It does the work while you do other work.

1. Select an agent that works in the folder that you want, or know the folder.
2. Push `/`, write `NW`, push `Enter`. To use another folder, write it after `NW`: a path (`NW ~/bbq/soii`), a folder in `~/bbq` (`NW soii`), or the start of an agent name (`NW miso`).
3. To choose the model, the effort or the permission mode, write them after `NW`, in any place: a model (`opus`, `sonnet`, `haiku`, `fable`, or a full name), an effort (`low`, `medium`, `high`, `xhigh`, `max`), a mode (`plan`, `auto`, `bypass`, `accept`, `manual`, `dontask`). Example: `NW soii sonnet high`. The defaults are `nw_model`, `nw_effort` and `nw_permission` in `keys.toml` (section 7.6).
4. The message box opens with `new background agent in <folder>` and the options. Write the task.
5. Push `Enter`. The command line shows `✓ background agent <id> started`. Kaching selects the new agent when it shows in the list.
6. Answer it as any other agent: push `k`, or a number key. Its questions and menus show in the agent panel like those of other agents. Quick approve (`a`) works too.

To change the model of a running agent, write `/model sonnet` as a message. The agent asks `Switch model?`. The agent panel shows the question. Push `1` to confirm.

To see its own screen, push `g`. A new Terminal window opens and shows the agent. Closing that window does not stop the agent.

To stop it, select it, push `/`, write `STOP`, push `Enter`. To open it again later, write `claude --resume <id>` in a terminal.

The folder must be trusted by Claude Code. If the command line shows `Workspace not trusted`, write `claude` in that folder once and accept.

### 6.16 Look at the open pull requests

1. Push `/`, write `PR`, push `Enter`.
2. Push `l` (down) or `j` (up) to select a pull request. Each line shows the repo and number, how long ago it changed, and its title. A draft shows `draft` after its number.
3. Push `Enter` to open it on GitHub in your browser, or push `k` to read it on the right: the branch, how many lines and files it changes, conflicts and checks, the description, the files and the comments and reviews. Push `↑` and `↓` to scroll. Push `l` or `j` to go to the next pull request; the right side follows.
4. To have an agent work on it, push `k` again. Write what it should do, for example `review this feature and check that it does what it says`. Push `Enter`. Kaching starts a new background agent in your local clone of the repo (in your home folder when there is none) with the pull request and your comment as its task. It works in its own worktree of the pull request's branch and reports back to you; it comments on GitHub only if you ask it to. It shows in the inbox like any other agent.
5. For the usual tasks, push a number instead: `1` reviews it, `2` merges it when its checks pass and it has no conflicts.
6. Push `Esc` to close the pull request on the right.

Kaching reads the list with `gh`: every 30 seconds while the view is open, every 2 minutes for the number in the tab. If a read fails, the last list stays and the error shows at the top. If the error says you are not logged in, write `gh auth login` in a terminal.

### 6.17 Write to a group of agents

Use this procedure to send one message to many agents.

1. Push `/`, write `ALL` and a group, push `Enter`. The groups are:

   | Group | Agents in the group |
   |---|---|
   | `waiting` | The agents in `INPUT` and in `WAITING`. |
   | `input` | The agents in `INPUT`: they ask you something or are blocked. |
   | `idle` | The agents in `IDLE`. |
   | `working` | The agents in `WORKING`. |

2. The message box opens. Its title shows how many agents get the message, and their names.
3. Write the message. Push `Enter`.
4. Kaching writes the message to the agents one after the other. The command line shows `✓ sent to <n> agents` and the names.

Kaching leaves out an agent that shows a menu on its screen, because the message would go into the menu. Kaching also leaves out an agent that is not in Terminal.app and not in the background. The title and the command line name them.

### 6.18 Write to another session

1. Push `k` to open the message box.
2. Write `@` and some letters of the name. The list shows the other sessions first, with the word `session`.
3. Push `Tab` to take a name. A name with spaces gets quotation marks: `@"release notes"`.
4. Write the message after the name. Push `Enter`.
5. Kaching writes the message, without the name, to that session. The selected agent does not get it.

A name in the middle of a message stays in the message. The selected agent then passes the message on itself, with its own tool for messages between sessions.

If the name is not a live session, Kaching sends the message to the selected agent. If two sessions have the name, or the session shows a menu, the box stays open and the command line tells you.

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

### 7.6 Change how `NW` starts agents and the quick approve key

1. Open `~/.agent/terminal/keys.toml`.
2. Above `[keys]`, set `nw_model`, `nw_effort` and `nw_permission`. Words that you write after `NW` have priority. An empty value leaves the choice to Claude Code.
3. In `[keys]`, set `quick_approve` to change the key of quick approve (`a`).
4. Save the file.

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

To read the screen of a background agent, Kaching does not attach. It runs `claude logs <id>` and replays the output in a small terminal program. It then reads the menu from that screen, as it does for an agent in Terminal.app. Kaching reads the selected agent from time to time, and each agent that waits for you every 2 seconds.

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
| The command line shows `Paperclip refused`. | Paperclip does not accept the answer. The text after it says why. | Read the text. Change your answer, or open the row in the browser. |
| The command line shows `no recommended answer for question`. | The question has no `★`. Kaching does not guess. | Pick an answer for each question. Push `s`. |

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
