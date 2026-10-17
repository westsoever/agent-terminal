---
description: Machine-wide status of every Claude session, from dash.sh. Says the spoken summary aloud by default; --text, --inbox, --next, --all print instead
argument-hint: [--text | --inbox | --next | --all]
allowed-tools: Bash(~/.claude/kaching/bin/dash.sh:*), mcp__voicemode__converse, mcp__plugin_voicemode_voicemode__converse
---

Show the state of the Claude sessions on this machine. Arguments: `$ARGUMENTS`

1. Pick one dash.sh mode from the arguments. Pass only these flags to the shell, never the argument text itself:
   - none or `--speak`: the spoken summary (`dash.sh --speak`). This is the default and is said aloud.
   - `--text`: the same spoken summary, printed only. Run `dash.sh --speak`; `--text` is this command's own word, dash.sh does not know it.
   - `--inbox`: what needs the user, what is ready, what finished. It marks FINISHED as seen: the next `--inbox` will not list those again, so run it only when the user wants the list.
   - `--next`: the top sessions to look at next.
   - `--all`: the table of every session seen in the last 30 days.
   Anything else: say which flags exist and stop.
2. Run `~/.claude/kaching/bin/dash.sh <flag>` with Bash.
3. Default and `--speak` only: say the output aloud with the `converse` tool (VoiceMode, either tool name above): `message` is the output verbatim, `wait_for_response` is `false` (speak, never listen). If converse says another session currently holds the voice channel, or the tool is missing, do not retry or wait: the printed text is the answer.
4. Print the output as it is. Add nothing: no paths, no ids, no commentary.

Only the dispatcher is meant to speak on its own. This command speaks because the user typed it.
