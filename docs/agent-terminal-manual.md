# Agent Terminal: user manual

Written in ASD-STE100 Simplified Technical English. Labels on the screen (for example `WAITING`, `IN`, `PC`) are technical names. This manual shows them in `code` letters.

## 1. Quick reference

### 1.1 Go to a view

Push `/`, write the code, then push `Enter`.

| Code | View | It shows |
|---|---|---|
| `IN` | Inbox (the desk) | All agents and the selected agent. This is the start view. |
| `FL` | Files | The last 30 files that the agents wrote about, newest first. Files of agents that stopped stay in the list. |
| `RP` | Repos | The git clones on this Mac and your GitHub repos (`westsoever`, `technobbq`) that have no clone. Repos with work that you can lose (the git sync check) are at the top. |
| `RC` | Recaps | The last recap of each agent. The names are on the left, newest recap first; the recap of the selected agent shows in full in a box on the right. Claude Code writes a recap when you come back to a session after some time. The desk also shows the recap of the selected agent above its last message. |
| `PR` | Pull requests | The open GitHub pull requests that involve you (yours, assigned to you, that ask your review, or where you commented or were mentioned), the last updated first. The number in the tab is how many. |
| `PO` | Proposals | The changes that the learner proposes. The tab is orange when proposals are open. |
| `PC` | Paperclip | Paperclip issues and company approvals that need you, and issues in progress. The selected row shows on the right, with what it asks you. The tab is orange when a row needs you. |
| `FIND` | Find a session | Look for a session by its name, or by what you and the agents said in it. Write the words after `FIND`, for example `FIND agent-terminal resume`. No tab shows this view. Refer to section 6.19. |
| `THEME` | Accent color | Choose the color of the selected rows and of the things that need you: one of 8, orange is the default. Refer to section 7.7. |
| `NW` | New agent | Start a background agent. You can add a folder, a model, an effort and a mode, for example `NW soii sonnet high`. Refer to section 6.15. |
| `ALL` | Write to a group | Write one message to a group of agents: `ALL waiting`, `ALL input`, `ALL idle` or `ALL working`. Refer to section 6.17. |
| `STOP` | – | Stop the selected background agent. Its conversation stays. |
| `A3` | Agent 3 | The desk, with agent 3 selected. Use a number from 1 to 9. |
| `ching` | An agent by name | The desk, with the first agent whose name starts with these letters. |
| `CL` | Changelog | What changed, newest first: one line per decision in `DECISIONS.md`, read each time you open it. `CHANGELOG` does the same. Scroll like the help page. |
| `HELP` | Help | The key list, with what is new at the top. You can also push `?`. The page is longer than the screen: scroll it with `↑`, `↓`, `PgUp`, `PgDn`, `Home` and `End`. |
| `QUIT` | – | Agent Terminal stops. You can also push `Ctrl+C`. |

Push `Esc` to go back to the desk from any view.

### 1.2 Keys on the desk

The right hand does the most frequent work: `j` goes up, `l` goes down, `k` opens the message box.


| Key | Result |
|---|---|
| `l` or `↓` | Select the next agent (down the list). |
| `j` or `↑` | Select the previous agent (up the list). |
| `Space`, `Space` | Select the agent in `INPUT` that has waited the longest. The first `Space` waits for a second key with no time limit; `Esc` cancels it. |
| `1` to `9` | Send the answer with that number to the selected agent. |
| `a` | When the agent asks questions: take the recommended answer of each question and send all. Refer to section 6.3. |
| `k` | Write a message to the selected agent. `Enter` sends it. `Esc` keeps it as a draft. Refer to section 1.4. |
| `o`, then `a` to `i` | Open the file with that letter. |
| `o`, then `1` to `9` | Open the link with that number in the default browser. After `o`, each link on the screen shows its number on its first character. Refer to section 6.8. |
| `g` | Show the Terminal window of the selected agent, where it is. For a background agent, show its own screen in a short-lived Terminal window. Push `Ctrl+Z` there to close it; the agent keeps running. |
| `h` | Bring the window of the selected agent to monitor 1 and into focus, so that you can write in it. Drag it back to monitor 2 to put it back in its position. For a background agent, the same as `g`. |
| `x` | Remove the selected agent from the waiting list. You do not send an answer. |
| `z` | Show the selected agent on the full screen: its recap, its conversation and the message box. `↑` and `↓` scroll a third of a page. Push `z` or `Esc` to go back. |
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
| `@NewName` | A name that is not a session yet: `Enter` starts it as a background helper first, then sends the message to the selected agent. Refer to section 6.18. |
| `/` at the start, then letters | Show the commands and skills that agree with the letters, with their descriptions: Claude Code commands, your commands and skills, the commands and skills of the agent folder and its parent folders, and the enabled plugins. |
| `Tab` or `Enter` | Put the selected suggestion into the message. |
| `↑`, `↓` | Select a suggestion. When there are no suggestions, move between lines. |
| `Ctrl+V` | Paste an image from the clipboard. Agent Terminal saves it as a file and writes its path. The agent opens the file. If the clipboard has no image, Agent Terminal pastes the text. |
| `Cmd+V` | Paste text. Line breaks stay. |
| `←`, `→`, `Option+←`, `Option+→` | Move by one letter or by one word. |
| `Ctrl+A`, `Ctrl+E` | Go to the start or the end of the line. |
| `Option+Backspace`, `Ctrl+W` | Remove the word before the cursor. |
| `Ctrl+K`, `Ctrl+U` | Remove the text after or before the cursor. |
| `Esc` or `Ctrl+C` | Close the box. Agent Terminal keeps the text as a draft for this agent. Push `k` to open it again. |

The top line does not show your message. It shows only the name of the agent that gets the message.

### 1.5 Keys on the wall

| Key | Result |
|---|---|
| `1` to `9` | Select the tile with that number. |
| `z` | Show the selected tile on the full screen. Push `z` again to go back. |
| `l`, `j`, `Space` `Space` | Select the next or previous agent, or the agent in `INPUT` that has waited the longest. |
| `Esc` | Go back to the desk. |

When a tile shows on the full screen, the number keys send answers, as on the desk.

### 1.6 Keys in the lists (FL, RC, PR, PO, PC, RP)

| View | Key | Result |
|---|---|---|
| All lists | `l`, `j` | Select the next or previous line. |
| `FL` | `Enter` | Open the selected file. |
| `RC` | `l`, `j` | Select the next or previous agent. Its recap shows on the right. |
| `RC` | `Up`, `Down`, `PgUp`, `PgDn`, `Home`, `End` | Scroll a long recap. |
| `RC` | `Enter` | Go to the desk, with that agent selected. |
| `PR` | `Enter` | Open the pull request on GitHub in your browser. |
| `PR` | `k` | Open the pull request on the right: its branch, size, checks, description, files and thread. Push `k` again to write a comment for a new agent. |
| `PR` | `1` | With the pull request open: start a new agent that reviews it. |
| `PR` | `2` | With the pull request open: merge it now. Agent Terminal runs `gh pr merge` itself; no agent starts. It does not merge when the pull request has conflicts or checks that failed or still run. |
| `PR` | `3` | With the pull request open: close it now, without a merge. Agent Terminal runs `gh pr close` itself; no agent starts and there is no confirm step. It also closes drafts and pull requests with conflicts or failing checks. |
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
| `PC` | `o` | Write your own answer to a question. When the question has no own answer, `o` shows a number on each link. Refer to section 6.8. |
| `PC` | `a` | Give the recommended answer to every question and send. Agent Terminal refuses if one question has none. |
| `PC` | `n`, `p` | Show the next or previous page of a long list. |
| `PC` | `↑`, `↓` | Scroll the row on the right: its description, its thread and the full request. |
| `PC` | `b` | Hand the issue to a new background agent. Refer to section 6.14. |
| `PC` | `t` | Hand the issue to a new session in a Terminal window. |
| `PC` | `Enter` | Open the row in Paperclip in your browser. |
| `PC` | `k` | Write a comment on the row. `Enter` sends it. |
| `RP` | `Enter` | Open the folder of the repo. A repo without a local folder asks `No local folder. Open it on GitHub?`: push `Enter` or `y` to open it, any other key to stop. |
| `RP` | `g`, `Option+Enter` | Open the repo on GitHub in your browser. `Shift+Enter` also does this, but only in a terminal that sends it differently from `Enter` (Terminal.app does not). |
| `RP` | `k` | Show the folders of the repo in a panel on the right. |
| `RP` | `b` | Show the branches of the repo in a panel on the right. Refer to section 6.12. |
| `RP` | `w` | Show the worktrees of the repo in a panel on the right. |
| `RP` | `i` | Copy the path of the repo's folder. A repo without a local folder gives its GitHub address. |
| `RP` panel | `l`, `j` | Select the next or previous file or folder. |
| `RP` panel | `k` | Go into the folder, or open the file. `..` goes up. |
| `RP` panel | `h`, `Backspace` | Go up one folder. |
| `RP` panel | `Enter` | Show the folder in Finder, or open the file. |
| `RP` panel | `g` | Open the folder that the panel shows on GitHub. |
| `RP` panel | `i` | Copy the full path of the selected file or folder (`..` gives the folder that the panel shows). On a repo without a clone it copies the GitHub address. |
| `RP` panel | `Esc` | Close the panel. Push `Esc` again to go to the desk. |
| `RP` branches, worktrees | `l`, `j` | Select the next or previous branch or worktree. |
| `RP` branches, worktrees | `1`, `2`, `3` | Start a new background agent that reviews, merges or fixes the selected branch (in the worktree panel: the worktree's branch). |
| `RP` branches, worktrees | `k` | Write your own task for a new background agent on the branch. `Enter` starts it. |
| `RP` branches, worktrees | `f` | Fetch origin (`git fetch --prune`) and read the branches again. |
| `RP` branches, worktrees | `g` | Open the branch on GitHub. |
| `RP` branches, worktrees | `Enter` | Show the folder of the branch's worktree in Finder (the repo's folder when it has none). |
| `RP` branches, worktrees | `i` | Copy the name of the branch, or in the worktree panel the path of the worktree. |
| `RP` branches, worktrees | `b`, `w` | Go to the branches or to the worktrees of the same repo. |

### 1.7 Keys in the FIND view

| Key | Result |
|---|---|
| `l`, `j` | Select the next or previous result. |
| `Enter` | For a live session: go to the desk with that agent selected. For a session that ended: show the messages that match, on a page that you can only read. |
| `s` | Ask Claude which sessions fit the words. |
| `r` | Resume the selected session that ended. A new Terminal window opens and starts `claude --resume`. |
| `l`, `j` on the page | Scroll the page one line down or up. `PgDn` and `PgUp` scroll one page. `Home` and `End` go to the start and the end. |
| `Esc` | Close the page. Push `Esc` again to go back to the desk. |

## 2. Introduction

### 2.1 What Agent Terminal is

Agent Terminal is one screen for all the Claude Code agents on this Mac. You operate it with the keyboard only. It shows which agents wait for you. It shows the last message of each agent. It sends your answers to the agents.

### 2.2 What Agent Terminal does not do

Agent Terminal does not have its own AI. It does not decide for you. The only exception is the `AI` step of `FIND` (section 6.19). It runs when you push `s`, or when the other steps find nothing. It reads the session records of the agents. It writes the text that you select into the Terminal window of the agent. The agent then does the work.

Agent Terminal can only send text to agents in Terminal.app and to background agents. It shows agents in Claude Desktop, VS Code or Cursor, but you cannot send text to them.

## 3. Install and start

### 3.1 Install Agent Terminal

1. Make sure that Go is installed. If it is not installed, write `brew install go` in a terminal.
2. Write `~/.claude/agent-terminal/terminal/build.sh` in a terminal.
3. Make sure that the terminal shows `built /Users/<you>/.local/bin/agterm`.

### 3.2 Add the start key in Raycast

1. Open Raycast.
2. Go to Extensions, then Script Commands, then Add Directories.
3. Add the folder `~/.claude/agent-terminal/ui/raycast`.
4. Find the command `Open Agent Terminal`.
5. Give it a hotkey.

### 3.3 Start Agent Terminal

1. Push the hotkey of `Open Agent Terminal`.
2. If Agent Terminal does not operate, Raycast opens a new Terminal window. Agent Terminal starts in it and fills the main display.
3. If Agent Terminal operates, Raycast shows its window.

You can also write `agterm` in any Terminal window.

The window must be a minimum of 60 columns wide and 16 lines high.

### 3.4 Stop Agent Terminal

1. Push `/`.
2. Write `QUIT`.
3. Push `Enter`.

You can also push `Ctrl+C`.

## 4. The screen

### 4.1 Parts of the screen

The screen has five parts, from the top to the bottom:

1. The tab bar. It shows the views and their codes. The current view is white. The `PO` tab is orange when proposals are open. The `PC` tab is orange when a Paperclip issue needs you. The number in the tab is how many.
2. The command line. It shows the current code, the time, the number of agents and the number of agents that wait for you. It also shows short messages from Agent Terminal.
3. The agent list (left). It shows all agents in three groups.
4. The agent panel (right). It shows the selected agent.
5. The key bar (bottom). The first line shows the keys for the current view. The second line shows the fixed messages. On the right, the two lines show your Claude usage: the 5-hour window above the 7-day limit. Each line shows the exact percentage, a bar, and the time until it starts again (`↻ 1h33m`, `↻ 1d08h`). When the screen is narrow, keys at the end of the lines give way.

The usage comes from the statusline: `~/.claude/statusline-command.sh` writes the `rate_limits` of each session to `~/.agent/usage/<session id>.json` when they change, and Agent Terminal shows the newest file. Before any session has updated its statusline, the bar says `no statusline reading yet`. If it stays that way, check that your statusline script has the lines that write `~/.agent/usage/<session id>.json`: without them no file exists and Agent Terminal has nothing to read.

Links in the text (`http://` and `https://`) are real links. To open one with the keyboard, push `o`, then the number that the link shows (refer to section 6.8). This works in every terminal. In a terminal that knows OSC 8 links (for example iTerm2 or Ghostty), you can also push `Cmd` and click on a link. Terminal.app ignores OSC 8 links, so there a click does nothing. A link that is too long for the line shows cut with `…`, but `o` and the click open the whole address.

### 4.2 The agent list

The agent list has five groups, and the `REMOTE` part below them. All headers are always on the screen, also when a group has no agent. An empty `INPUT` shows that no agent needs you.

| Group | Agents in the group |
|---|---|
| `INPUT` | The agent stopped and needs you: its screen shows a question or an approval (`asks`), it has a question (`input`), or it cannot continue (`blocked`). The agent that waited the longest time is at the top. |
| `WAITING` | The agent finished its turn (`done`), or it is ready for release (`ready`), but something is still open: its checkpoint has a next action or a blocker, or its `NEXT.md` has text. The agent that waited the longest time is at the top. |
| `WORKING` | The agent does work now. |
| `IDLE` | The agent does not do work and does not wait for an answer. |
| `DONE` | The agent finished its task and nothing is left: its checkpoint has no next action and no blocker, and its `NEXT.md` is empty or missing. The agent that finished last is at the top. |

Each line shows the name of the agent, its state and the time since the last change. The selected agent has an orange line.

Below `DONE` is a sixth part, `REMOTE`. It lists your Claude Code sessions that run on other machines (Remote Control) and are connected to your account now. A session that is archived or not connected is not shown. Each line has a `◇`, the name, the state and the time since the last change. Agent Terminal reads the list from your Claude account every 30 seconds.

| State | Meaning |
|---|---|
| `working` | The session does work now. |
| `reply` | The session answered and you did not look at it yet (orange). |
| `asks` | The session waits for an answer from you (orange). |
| `idle` | The session does not do work. |

Push `l` or `j` to go from the agents into `REMOTE`. The right side shows the model, the context used, and what the session last said it did.

- Push `k` to write a message. Agent Terminal sends it with `claude -p "…" --cloud <session id>`. The status line shows `sending…`, then `✓ sent` or the reason it did not go.
- Push `Enter` to open the session on `claude.ai/code` in your browser. Read the reply there.
- Agent Terminal cannot show the messages of a remote session. Your account refuses that read on this Mac (`elevated session requires a trusted device`). It shows the state and sends messages only.

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

Agent Terminal has four modes. The command line shows the current mode.

| Mode | How you start it | What the keys do | How you stop it |
|---|---|---|---|
| Key mode | This is the normal mode. | Each key does an action. | – |
| Command mode | Push `/`. | You write a code. | `Enter` does the code. `Esc` cancels. |
| Write mode | Push `k`. | You write a message. Refer to section 1.4. | `Enter` sends it. `Esc` keeps it as a draft. |
| Open mode | Push `o`. | You select a file or a link. Each link on the screen shows its number. | Push the letter of the file or the number of the link. Any other key cancels. |

In command mode and write mode:

- `Backspace` removes the last letter.
- `Ctrl+U` removes all the text.

## 6. Procedures

### 6.1 Find the agents that wait for you

1. Look at the command line. It shows the number of agents that wait for you.
2. Push `Space` two times. Agent Terminal selects the agent in `INPUT` that has waited the longest. Agents that are only done (`WAITING`) are skipped. An agent that shows a question or an approval on its screen waits from the moment that it showed it, not from the start of its turn. Agent Terminal reads the screens of all busy agents, so such an agent is in `INPUT` also when you never selected it.
3. Read the agent panel and answer it.
4. Push `Space` two times again. Agent Terminal selects the agent in `INPUT` that now has waited the longest. Pushing `Space` two times again before you answer keeps the same agent.

### 6.2 Select an answer

Use this procedure when the agent panel shows numbered answers.

1. Select the agent.
2. Read the numbered answers.
3. Push the number of the answer.
4. Make sure that the command line shows `sent` and then `✓ <name> is on it`.

When the agent shows a menu, Agent Terminal pushes only the number key in the agent window. When the agent writes a numbered list in its message, Agent Terminal writes the number and pushes `Enter`.

### 6.3 Answer a question with more than one part

Use this procedure when the agent panel shows `THE AGENT ASKS`. Agent Terminal shows the question as the agent shows it on its own screen. This includes questions with more parts, plan approvals and permission prompts.

1. Select the agent. Its state is `asks`.
2. Read the question and its numbered answers.
3. Push the number of your answer. The agent goes to the next part, and Agent Terminal shows it.
4. Do step 3 again for each part.
5. On the last screen (`Review your answers`), push `1` to send all answers.

To write your own answer, push `k`, write the answer, and push `Enter`. Agent Terminal selects `Type something.` for you and sends your text.

To go back to a part, push `←`. To confirm a selection, push `Enter`.

**Quick approve.** An agent can mark the answer that it recommends: the label ends with `(Recommended)`. Agent Terminal shows each question with its recommended answer under `RECOMMENDED`, with a `★`. Push `a` (quick approve) to take the recommended answer of each question and send all answers. Agent Terminal does it with the keys that you would push. A question with more choices gets all of its recommended answers.

If one question has no recommended answer, quick approve does nothing. The command line names the question. Answer that question yourself. Then push `a` again for the rest.

Agent Terminal reads the questions of all agents in the same way, also for background agents. A permission prompt or a plan approval has no recommended answer: answer it with the number keys.

### 6.4 Send a fixed message

1. Select the agent.
2. Push the key of the message, for example `f` for "fix it".
3. For a message on the space bar, push `Space`, then push the second key. Agent Terminal waits for it as long as it takes; `Esc` cancels.
4. Make sure that the command line shows `✓ <name> is on it`.

### 6.5 Write a message

1. Select the agent.
2. Push `k`. The message box opens below the text of the agent.
3. Write your message. To start a new line, push `Option+Enter`.
4. Push `Enter`.
5. Make sure that the command line shows `✓ <name> is on it`.

To stop before step 4, push `Esc`. Agent Terminal keeps your text as a draft. When you push `k` again for this agent, the draft comes back.

### 6.6 Refer to a file or a command in a message

1. In the message box, write `@` and some letters of the file name.
2. A list of files in the folder of the agent shows above the box.
3. Push `↑` or `↓` to select the file.
4. Push `Tab`. Agent Terminal writes the file as `@path`.

For a command, write `/` at the start of the message, then some letters. Select the command as in steps 3 and 4.

### 6.7 Send an image

1. Copy the image, for example with `Cmd+Ctrl+Shift+4` for a part of the screen.
2. Push `k` to open the message box.
3. Push `Ctrl+V`. Agent Terminal saves the image in `~/.agent/terminal/images/` and writes its path.
4. Write your question about the image.
5. Push `Enter`. The agent opens the image file.

### 6.8 Open a file or a link that an agent wrote about

1. Select the agent.
2. Find the file in `FILES IT MENTIONED`.
3. Push `o`.
4. Push the letter of the file.

The file opens in its default application. A folder opens in Finder.

To see the files of all agents, go to the files view (`/FL`). Select a file. Push `Enter`.

To open a link (`http://` or `https://`):

1. Make sure that the link is on the screen. If necessary, scroll with `↑` and `↓`.
2. Push `o`. Each link on the screen shows a number on its first character, in the accent color.
3. Push the number of the link.

The link opens in the default browser. This also works in the panel of a pull request (`PR`) and of a Paperclip row (`PC`). When there are more than 9 links on the screen, the lowest 9 get a number. In `PC`, when the question has your own answer, `o` writes your own answer instead.

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

The agent leaves the list. A background agent, which has no window, leaves it too. If the agent has a Terminal window that came over to the main display, the window goes back to its position on the second display. The agent does not get a message. When the agent finishes another turn or asks something new, it comes back to the list.

### 6.11 Look at all agents together

1. Push `W`. The wall shows each agent as a tile.
2. Push the number of a tile to select it.
3. Push `z` to show the tile on the full screen.
4. Push `z` again to go back to the wall.
5. Push `Esc` to go back to the desk.

The tiles change size with the window. A wide window shows more tiles in each line.

### 6.12 Look at the repos

1. Push `/`, write `RP`, push `Enter`.
2. Read the list. Each line shows the name of the repo, its name on GitHub (`owner/name`), its local folder (or `github only`), the number of local branches and worktrees (`3 br · 2 wt`), how long ago it was last worked on and, in orange, what the git sync check found (for example `1 stash`). The list has two parts. `MOST RECENT` holds the 10 repos worked on last, the newest first: a commit, checkout or merge in the clone or in one of its worktrees, or a push to GitHub. `ALL REPOSITORIES` holds all the others from A to Z. The selected repo shows the full findings below its line. The keys are in the bottom line.
3. Push `l` (down) or `j` (up) to select a repo.
4. Do one of these steps:
   - To open its folder, push `Enter`. If the repo has no local folder, the command line asks `No local folder. Open it on GitHub?`. Push `Enter` or `y` to open it on GitHub. Push `Esc` to stop.
   - To open it on GitHub, push `g` or `Option+Enter`.
   - To see its branches, push `b`. To see its worktrees, push `w`. Refer to the steps below.
   - To look at its files, push `k`. The list moves to the left and the panel on the right shows the folders and files of the repo (folders first, `.git` is not shown).
5. In the panel:
   - Push `l` or `j` to select a file or folder.
   - Push `k` to go into a folder, or to open a file (with `open_cmd`). Select `..` and push `k`, or push `h`, to go up.
   - Push `Enter` to show the folder in Finder, or to open the file.
   - Push `g` to open the folder that the panel shows on GitHub.
   - Push `Esc` to close the panel.
6. In the branch panel (`b`):
   - The top line counts the local branches, the branches on origin only, the branches with work that the default branch does not have, and the worktrees.
   - Each line shows `⌂` when the branch is checked out in a worktree, then the name, then the branch against the default branch (`+2 −5`: 2 commits that the default branch does not have, 5 behind it; `merged`; `default`), then the branch against its copy on GitHub (`not pushed`, `↑1` to push, `↓1` to pull, `gone`, `pushed`), its age and its last commit. The branches on origin only are under `ON ORIGIN ONLY`.
   - Below the list, the selected branch is described in words.
   - Push `1` to review it, `2` to merge it into the default branch, `3` to fix it, or `k` to write your own task. Each starts a new background agent in the worktree of the branch (in the repo's folder when it has none). `2` refuses the default branch and a branch that is already merged.
   - Push `f` to fetch origin. Agent Terminal does not fetch by itself, so the branches on origin are as of your last fetch.
   - Push `w` to see the worktrees.
7. In the worktree panel (`w`): each line shows the folder of the worktree (the first is the repo's own folder), its branch, its changed files and its branch against the default branch. `1`, `2`, `3` and `k` work on the branch of the selected worktree. `Enter` shows the folder in Finder. Push `b` to see the branches.

Agent Terminal finds local repos one level below `~/bbq` and `~`, in `~/.agent-repos` and in the sync check. It reads the GitHub repos with `gh repo list` each time you open the view. If that read fails, the last list stays and the error shows at the top. For a repo without a local folder, the panel reads the folders from GitHub, and `k` on a file opens it on GitHub.

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
   | A connection request, or a request that Agent Terminal does not know | None. Push `Enter` to open it in your browser. |

5. Push the keys of your request. Make sure that the command line shows `✓ <answer> · <row>`.
6. For a decline with a reason, or an answer with a note, the box opens. Write the text. Push `Enter`.
7. To write a comment, push `k`. Write the comment. Push `Enter`. This also works on an approval.
8. To open the row in your browser, push `Enter`.

**Hand an issue to an agent with your permissions.** The agents of Paperclip have restricted permissions. Some work they cannot finish: for example, set a status, or write outside their folder. A session that you start has your permissions. Use it to look over the work and to finish it.

1. Select the issue.
2. Push `b` for a new background agent. Push `t` for a new session in a Terminal window.
3. The message box opens. Write the task, or leave the box empty. An empty box sends this task: look over the issue and finish what the Paperclip agents could not.
4. To give the issue to a session that already runs, write `@` and its name at the start of the box. Example: `@miso check the pull request`. The session gets the issue and the text after the name.
5. Push `Enter`.

Agent Terminal writes a briefing file for the agent in `~/.agent/terminal/handoff/`. It has the description of the issue, its thread, the request that waits for you, and the folder of the work. The folder is the one that the `repo:` line of the issue names, in `~/bbq` or in your home folder. The agent gets a short first message that names the file.

The briefing tells the agent how to report. It writes one comment on the issue and sets the status to `in review`. It never sets `done`. It does not answer the requests of the issue, and it does not answer approvals: those are yours. It uses Paperclip's API on this Mac (`http://localhost:3100`), which needs no login.

A background agent shows in the agent list with `◦`, and a session in Terminal shows as a Terminal agent. Their names start with `paperclip` and the number of the issue. If the box stays open, the command line says why: for example, no session has that name.
**Company approval.** The panel shows the payload: for example the name, the role and the monthly budget of an agent to hire. It also shows the issue that the approval belongs to.

- Push `1` to approve or `2` to reject. Agent Terminal sends the answer at once.
- To add a note, push `4` (approve) or `5` (reject). Write the note. Push `Enter`.
- To send the approval back for changes, push `3`. Write what to change. Push `Enter`.
- A `board ask` (a request to the board) has no keys. Paperclip wants you to review its action in the browser first. Push `Enter` to open it.

**List to tick.** A list of choices starts with the choices that the request ticked. A list of suggested tasks starts with all tasks ticked.

- Push the number of an item to tick it. Push it again to untick it. `[x]` shows a ticked item.
- A task needs its parent. When you tick a task, its parent is ticked too. When you untick a parent, its tasks are unticked too.
- When the list is longer than the panel, push `n` for the next page and `p` for the previous page.
- Push `s` to send. For tasks, Agent Terminal accepts the ticked tasks. When all tasks are ticked, it accepts all.
- Push `x` to decline. To decline with a reason, push `r`, write the reason, push `Enter`.
- When Paperclip refuses (for example, you ticked too many items), the command line shows its message. Change the ticks. Push `s` again.

**Questions with more parts.** Agent Terminal shows one question at a time, for example `question 2 of 3`. A `✓` after it marks each question that has an answer.

- Push the number of an option. For a question with one answer, Agent Terminal then goes to the next question.
- For a question with several answers, push the number of each option. Then push `→`.
- To write your own answer, push `o`. Write the answer. Push `Enter`. Some questions take only a written answer.
- To go back to a question, push `←`.
- Push `s` to send all answers at once. When a question needs an answer and has none, Agent Terminal names it and sends nothing.
- A star (`★`) marks the answer that the request recommends. A label that ends in `(Recommended)` has the same mark.
- When every question has a star, push `a`. Agent Terminal takes the starred answers and sends them at once.
- When a question has no star, `a` sends nothing. The command line shows which question it is. Agent Terminal does not guess.

**Items that wait for a verdict.** The list shows each item and its verdict. `>` marks the current item. Its full text shows above `IT ASKS YOU`.

- Push `1`, `2` or `3` to give the current item that verdict. The key line shows the verdicts. Agent Terminal then goes to the next item.
- A verdict can need a reason, usually `reject`. Then the box opens. Write the reason. Push `Enter`.
- To go to another item, push `←` or `→`.
- Push `s` to send the verdicts. You can send some items now and the others later. The command line shows how many are left.
- An item that has a verdict already stays as it is.

When Agent Terminal cannot answer a request (a connection request, or a kind that a later Paperclip adds), the panel tells you to open it in the browser. Agent Terminal never sends an answer that it does not understand. If Paperclip does not operate, the view shows `Paperclip isn't running (localhost:3100)`.

### 6.15 Start a background agent

A background agent is a Claude Code session without a window. It does the work while you do other work.

1. Select an agent that works in the folder that you want, or know the folder.
2. Push `/`, write `NW`, push `Enter`. Without a folder, the agent starts in the folder of the selected agent. If no agent is selected, Agent Terminal shows an error: it never uses the home folder on its own (write `NW ~` for that). To use another folder, write it after `NW`:
   - a path: `NW ~/bbq/soii`, or `NW ./sub` and `NW ..` from the folder of the selected agent;
   - a folder in `~/bbq`: `NW soii`;
   - the start of a name: `NW mis` fits the folders in `~/bbq` and the agents. If it fits more than one folder, Agent Terminal lists them: write more of the name. An agent in a worktree stands for the main folder of its repo.
   The message box shows the folder, its branch, and how Agent Terminal found it (`folder: the selected agent miso`). An orange `⚠` line warns when the folder is the home folder, is not a git repo, or is a worktree. Press `Esc` and write `NW` again if the folder is wrong.
3. To choose the model, the effort or the permission mode, write them after `NW`, in any place: a model (`opus`, `sonnet`, `haiku`, `fable`, or a full name), an effort (`low`, `medium`, `high`, `xhigh`, `max`), a mode (`plan`, `auto`, `bypass`, `accept`, `manual`, `dontask`). Example: `NW soii sonnet high`. The defaults are `nw_model`, `nw_effort` and `nw_permission` in `keys.toml` (section 7.6).
4. The message box opens with `new background agent in <folder>` and the options. Write the task.
5. Push `Enter`. The command line shows `✓ background agent <id> started`. Agent Terminal selects the new agent when it shows in the list.
6. Answer it as any other agent: push `k`, or a number key. Its questions and menus show in the agent panel like those of other agents. Quick approve (`a`) works too.

To change the model of a running agent, write `/model sonnet` as a message. The agent asks `Switch model?`. The agent panel shows the question. Push `1` to confirm.

To see its own screen, push `g`. A short-lived Terminal window opens and shows the agent: use every key and `/` command of Claude Code there. Push `Ctrl+Z` to leave; Agent Terminal closes the window, and the agent keeps running. Push `g` again while the window is open to bring it to the front: an agent never gets a second window. (`←` in that window goes to Claude Code's list of agents, and the window stays open.)

To stop it, select it, push `/`, write `STOP`, push `Enter`. To open it again later, write `claude --resume <id>` in a terminal.

The folder must be trusted by Claude Code. If the command line shows `Workspace not trusted`, write `claude` in that folder once and accept.

### 6.16 Look at the open pull requests

1. Push `/`, write `PR`, push `Enter`.
2. Push `l` (down) or `j` (up) to select a pull request. Each line shows the repo and number, how long ago it changed, and its title. A draft shows `draft` after its number.
3. Push `Enter` to open it on GitHub in your browser, or push `k` to read it on the right: the branch, how many lines and files it changes, conflicts and checks, the description, the files and the comments and reviews. Push `↑` and `↓` to scroll. Push `l` or `j` to go to the next pull request; the right side follows.
4. To have an agent work on it, push `k` again. Write what it should do, for example `review this feature and check that it does what it says`. Push `Enter`. Agent Terminal starts a new background agent in your local clone of the repo (in your home folder when there is none) with the pull request and your comment as its task. It works in its own worktree of the pull request's branch and reports back to you; it comments on GitHub only if you ask it to. It shows in the inbox like any other agent.
5. To have an agent review it, push `1`.
6. To merge it, push `2`. Agent Terminal merges it at once with `gh pr merge`; no agent starts. The status line shows `merging…`, then `✓ merged` and the merge method, and the pull request goes off the list.
   - Agent Terminal merges the commit that the right side shows. If somebody pushed a new commit after that, GitHub refuses the merge.
   - Agent Terminal makes a merge commit. When the repo does not allow merge commits, it uses squash, then rebase.
   - Agent Terminal does not delete the branch. The repo's own setting can still delete it.
7. To close it without a merge, push `3`. Agent Terminal closes it at once with `gh pr close`; no agent starts and there is no confirm step. The status line shows `closing…`, then `✓ closed`, and the pull request goes off the list.
   - A draft, or a pull request with conflicts or failing checks, closes too. Agent Terminal does not need the right side to be loaded.
   - If you push `3` by mistake, open the pull request on GitHub and push `Reopen pull request`.
   - Agent Terminal does not merge a draft, a pull request with conflicts, or one with checks that failed or still run. It also does not merge when the right side has not loaded. The status line tells you why.
   - When GitHub refuses the merge, for example because of a branch rule, the status line shows the message from `gh`.
7. Push `Esc` to close the pull request on the right.

Agent Terminal reads the list with `gh`: every 30 seconds while the view is open, every 2 minutes for the number in the tab. If a read fails, the last list stays and the error shows at the top. If the error says you are not logged in, write `gh auth login` in a terminal.

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
4. Agent Terminal writes the message to the agents one after the other. The command line shows `✓ sent to <n> agents` and the names.

Agent Terminal leaves out an agent that shows a menu on its screen, because the message would go into the menu. Agent Terminal also leaves out an agent that is not in Terminal.app and not in the background. The title and the command line name them.

### 6.18 Write to another session

1. Push `k` to open the message box.
2. Write `@` and some letters of the name. The list shows the other sessions first, with the word `session`.
3. Push `Tab` to take a name. A name with spaces gets quotation marks: `@"release notes"`.
4. Write the message after the name. Push `Enter`.
5. Agent Terminal writes the message, without the name, to that session. The selected agent does not get it.

A name in the middle of a message stays in the message. The selected agent then passes the message on itself, with its own tool for messages between sessions.

If the name is not a live session, Agent Terminal sends the message to the selected agent. If two sessions have the name, or the session shows a menu, the box stays open and the command line tells you.

To hand work to a new helper session, write a name that no session has, anywhere in the message, for example `merge #15 and #16, use @agtermHelper for it`:

1. The box shows an orange line: `@agtermHelper → new background agent in <folder>`. If it does not, the name belongs to a session, to a file in the folder or to a `REMOTE` session, and no helper starts.
2. Push `Enter`. Agent Terminal starts a background agent with that name in the folder of the selected agent, with the model, effort and mode of `NW` (section 6.15). The helper waits for its task.
3. Then Agent Terminal sends your message, unchanged, to the selected agent. The agent gives the helper its task with its own tool for messages between sessions.

If a helper does not start, for example in a folder that Claude Code does not trust yet, Agent Terminal sends nothing. Your message stays as the draft of the agent: push `k` to open it again.

### 6.19 Find a session

Use this procedure when you know what you or an agent said, but not in which session.

1. Push `/`. Write `FIND` and the words, for example `FIND agent-terminal resume`. Push `Enter`.
2. Read the top line of the view. It shows the progress: `searching…`, and then for example `3 in names, 12 in text`.
3. Look at the results. Agent Terminal searches in three steps:

   | Step | Label | What Agent Terminal searches |
   |---|---|---|
   | 1 | `name` | The name, the folder and the git branch of each live agent. The name of each session that ended: the name that you gave with `/rename`, or the title that Claude Code made. |
   | 2 | `text` | Your prompts and the text replies of the agents, in all sessions on this Mac. A message is a result when it has all the words. Capital letters do not matter. |
   | 3 | `AI` | Claude reads a short list of the last 120 sessions. It selects the sessions that fit the words by meaning. |

4. Read each result. The first line shows the label of the step, the session name, the start folder and the date. A session without a name shows the first 7 characters of its id. A `●` shows a live agent.
5. Read the second line of a result. For a `text` result, it shows the newest message that matches, with the words in white. It also shows who wrote it: `you` or `agent`. `×3` after `text` shows that 3 messages match. For an `AI` result, it shows the reason that Claude gives.
6. Push `l` or `j` to select a result. Push `Enter`:
   - For a live agent, Agent Terminal goes to the desk with that agent selected.
   - For a session that ended, Agent Terminal shows the newest 4 messages that match. Each one has the message before it and the message after it. Push `l` or `j` to scroll. Push `Esc` to close the page.
7. To continue a session that ended, push `r`. Agent Terminal opens a new Terminal window. The window goes to the folder where the session started and runs `claude --resume <session id>`. Agent Terminal does this only when you push `r`.

Step 3 starts by itself when steps 1 and 2 find nothing. The top line then shows `asking Claude…`. This takes approximately 10 seconds. To ask Claude when steps 1 and 2 found results, push `s`. The results of Claude show at the top of the list.

Notes:

- To search for a phrase, write it in double quotes, for example `FIND "pull request" merge`.
- The `text` step stops after 3 seconds. If it stops early, the top line shows `partial`. The list then shows only the newest sessions. Write more words to get fewer results.
- The list shows at most 50 sessions for each step.
- Agent Terminal does not search the claude-mem observer sessions or the sessions of sub-agents that an agent started.
- Step 3 uses your Claude usage. It makes one small call with the model Haiku. The call sends the name, folder, date, first prompt and last reply of the last 120 sessions to Claude. Agent Terminal cuts each prompt and reply to 200 characters.
- The call does not run your hooks. It does not save a session, and it does not add a folder to `~/.agent/sessions`. While it runs, Claude Code lists it as a session in `claude agents`. Agent Terminal does not show it in the agent list.

## 7. Change the keys and the fixed messages

All keys and fixed messages are in the file `~/.agent/terminal/keys.toml`. Agent Terminal writes this file when it starts the first time.

### 7.1 Change a fixed message

1. Open `~/.agent/terminal/keys.toml` in a text editor.
2. Find the `[[reply]]` block of the message.
3. Change the `text` line. Agent Terminal writes this text into the agent window.
4. Change the `label` line. The key bar shows this label.
5. Save the file.
6. Make sure that the command line of Agent Terminal shows `keys.toml reloaded`.

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

Do not use a key that Agent Terminal uses for an action (for example `l`, `j`, `k`, `o`, `g`, `x`, `W`, `z`, `/`). The action has priority.

### 7.3 Change an action key

1. Open `~/.agent/terminal/keys.toml`.
2. Find the `[keys]` block.
3. Change the key of the action, for example `next = "n"`.
4. Save the file.

If you remove a line, Agent Terminal uses the default key.

### 7.4 Change how files open

1. Open `~/.agent/terminal/keys.toml`.
2. Change the `open_cmd` line, for example `open_cmd = "code"` for VS Code.
3. Save the file.

### 7.5 Change how tables show

Agent Terminal draws the markdown tables in an agent's messages as tables.

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
2. Above `[keys]`, set `nw_model`, `nw_effort` and `nw_permission`. A new `keys.toml` has `claude-sonnet-5-5` and `high`. Words that you write after `NW` have priority. An empty value leaves the choice to Claude Code, which then uses the `model` and `effortLevel` of `~/.claude/settings.json`. These options also start the agents that `b` and `t` hand a Paperclip issue to.
3. In `[keys]`, set `quick_approve` to change the key of quick approve (`a`). Set `pc_agent` (`b`) and `pc_terminal` (`t`) to change the keys that hand a Paperclip issue to an agent.
4. Save the file.

### 7.7 Change the accent color

The accent color is the color of the selected row, of the things that need you, and of the cursor. It is orange at first. You can change it to one of 8 colors: orange, amber, green, cyan, blue, violet, magenta or red.

1. Push `/`, write `THEME`, push `Enter`.
2. Push `j` or `l` (or `↑` or `↓`), or a number from `1` to `8`, to move the cursor. The whole screen shows the color under the cursor, so you can see it before you choose.
3. Push `Enter` to keep the color. Agent Terminal writes it as `theme = "green"` in `keys.toml` and uses it again the next time that it starts. Push `Esc` to go back to the color that you had.

To set a color at once, write its name after the command, for example `THEME green`. You can also write the `theme` line in `keys.toml` yourself, above `[keys]`. If the name in the file is not one of the 8, Agent Terminal uses orange.

#### Light and dark terminals

Agent Terminal works on a dark and on a light terminal background. When it starts, it asks the terminal which background it has. On a light background, it uses dark text, darker greys and a darker shade of the accent color, so that all text is easy to read. The `THEME` picker shows which background Agent Terminal uses now.

If Agent Terminal uses the wrong colors for your background, set the background yourself:

1. Open `keys.toml`.
2. Above `[keys]`, write `background = "light"` or `background = "dark"`.
3. Save the file. Agent Terminal uses the new colors at once.

To let Agent Terminal ask the terminal again, write `background = "auto"`.

## 8. Agent Terminal and the Terminal windows

Agent Terminal does not move, resize or close Terminal windows. When you start, stop or reload Agent Terminal, all Terminal windows stay where they are. The agent sessions continue.

Agent Terminal only does these things to an agent window:

- It writes your text into the window.
- It pushes `Enter` or a number key in the window. For this, the window comes to the front for approximately 0.1 seconds.
- When you push `g`, it brings the window to the front.

Agent Terminal starts a new agent session only when you write `NW` (section 6.15). That agent runs in the background, without a window. `g` on a background agent opens one new Terminal window for it.

## 9. How Agent Terminal sends text

Agent Terminal writes the text into the Terminal window of the agent. This does not change the window that you use.

Agent Terminal then pushes `Enter` in the agent window. For this key, the agent window comes to the front for approximately 0.1 seconds. Then Agent Terminal comes back to the front.

Agent Terminal examines the agent window after it pushes `Enter`. If the text did not go, Agent Terminal pushes `Enter` again.

A background agent has no window. Agent Terminal opens `claude attach <id>` out of sight, pastes the text, pushes `Enter` and closes the attach again. The agent continues. This takes approximately 2 seconds.

To read the screen of a background agent, Agent Terminal does not attach. It runs `claude logs <id>` and replays the output in a small terminal program. It then reads the menu from that screen, as it does for an agent in Terminal.app. Agent Terminal reads the selected agent from time to time, and each agent that waits for you every 2 seconds.

## 10. Problems and solutions

| Problem | Cause | Solution |
|---|---|---|
| The command line shows `isn't in a Terminal tab: look only`. | The agent is not in Terminal.app. | Push `g` to go to the agent. Write your answer there. |
| The command line shows `has no option 2`. | The agent did not give numbered answers, or Agent Terminal did not read them yet. | Wait 2 seconds. Push `R`. Try again. Or push `k` and write the answer. |
| The command line shows `typed but not submitted`. | The agent window did not accept `Enter`. | Push `g`. Push `Enter` in the agent window. |
| An agent is not in the list. | The agent stopped, or it is a background process. | Push `R`. If it does not show, look in Terminal. |
| A fixed message key does nothing. | You are not on the desk or on the wall. | Push `Esc`. Push the key again. |
| `keys.toml` shows an error on the command line. | The file has an error. | Correct the line that the error shows. Agent Terminal uses the default keys until you correct it. |
| `Option` + a key writes a wrong character. | Terminal sends `Option` as Meta, and Agent Terminal reads your layout when it starts. | Stop and start Agent Terminal after you change the keyboard layout. |
| The screen shows `agterm needs at least 60x16`. | The window is too small. | Make the window larger. |
| The PC view shows `Paperclip isn't running`. | The Paperclip service does not operate. | Start Paperclip. Then go to `PC` again. |
| The command line shows `Paperclip refused`. | Paperclip does not accept the answer. The text after it says why. | Read the text. Change your answer, or open the row in the browser. |
| The command line shows `no recommended answer for question`. | The question has no `★`. Agent Terminal does not guess. | Pick an answer for each question. Push `s`. |
| The FIND view shows `Claude failed` and a reason. | Claude did not answer in 2 minutes, or your Claude usage is used up. The reason says which. | Wait. Push `s` to ask again. |
| The FIND view shows `partial`. | The `text` step did not finish in 3 seconds. | Write more words. Push `/`, write `FIND` and the new words. |
| `r` in the FIND view shows `its folder is gone`. | The folder where the session started does not exist now. | Make the folder again, or open a terminal and write `claude --resume <session id>` in another folder. |

## 11. Files

| File | Contents |
|---|---|
| `~/.local/bin/agterm` | The program. |
| `~/.agent/terminal/keys.toml` | Your keys and fixed messages. |
| `~/.agent/terminal/open` | Tells the monitor queue that Agent Terminal operates and which agent is selected. Agent Terminal removes it when it stops. |
| `~/.agent/terminal/send.js` | The script that sends text to Terminal windows. Agent Terminal writes it when it starts. |
| `~/.agent/terminal/handoff/` | The briefing files for the agents that you hand a Paperclip issue to. |
| `~/.agent/terminal/files.json` | The last 30 files that the agents wrote about (the `FL` view). |
| `~/.claude/projects/` | The conversations of all sessions. The `FIND` view reads them. It never changes them. |
| `agent-terminal-find` in the temporary folder of your Mac | An empty folder. The `AI` step of `FIND` runs Claude there, so that Claude finds no project settings. |
| `~/.claude/agent-terminal/terminal/` | The source code. |
| `~/.claude/agent-terminal/docs/superpowers/specs/2026-10-17-agent-terminal-design.md` | The design. |
