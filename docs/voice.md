# Voice, level A: hear the status, dictate into a worker

Level A is two small things that need no dispatcher session. Level B (talk to one session that relays to the others) is in `dispatcher/AGENTS.md` and `docs/dispatcher-acceptance.md`.

| You want to | Use | Audio goes through |
|---|---|---|
| Hear what every session is doing | `/dash` (says `dash.sh --speak` aloud) | VoiceMode: local Whisper and Kokoro. Nothing leaves the machine. |
| Dictate a message into the session you are looking at | Wispr Flow, your own dictation app (not part of Agent Terminal) | Wispr Flow's service. Not local, and outside Agent Terminal. |

Claude Code's `/voice` is **not used** (D25): you dictate with Wispr Flow. The notes on `/voice` further down are kept for reference only. D5 (audio stays on the machine) covers Agent Terminal's own voice path. For a spoken conversation with the sessions, use the dispatcher (level B), which stays local.

## What `install.sh` sets up

- `permissions.allow` gets both names of VoiceMode's converse tool, so a session in a non-bypass mode is not asked each time: `mcp__voicemode__converse` (a hand-added MCP server) and `mcp__plugin_voicemode_voicemode__converse` (the plugin). Nothing else under `permissions` changes, and running the installer twice adds nothing. `--uninstall` leaves these two entries, because it cannot tell them from ones you added yourself.
- `~/.claude/commands/dash.md` links to `commands/dash.md`, which gives you `/dash`.

## Hear the status: `/dash`

In any session, type:

| Command | What happens |
|---|---|
| `/dash` | Runs `dash.sh --speak` and says the summary aloud (speak only, no listening). It also prints it. |
| `/dash --text` | Same summary, printed, not spoken. |
| `/dash --inbox` | What needs you, what is ready, what finished. Marks FINISHED as seen. |
| `/dash --next` | The top sessions to look at next. |
| `/dash --all` | Every session seen in the last 30 days. |

The summary leads with how many sessions need you, names the blocked ones, and warns when more than five sessions are active.

If another session is already talking, VoiceMode refuses to start a second voice (the `conch` lock, `~/.voicemode/conch`). `/dash` does not wait or retry then: you get the text. Check with `voicemode conch status`.

Only the dispatcher is meant to speak on its own. Worker sessions stay silent; `/dash` speaks only because you typed it.

If you hear nothing:

1. `voicemode kokoro status` and `voicemode whisper service status` should both say running locally.
2. `voicemode conch status`: is another session holding the voice channel?
3. Use `/dash --text` to confirm the command itself works.

## Dictate into the focused session: `/voice` (reference only, not used; D25)

You dictate with Wispr Flow instead. Nothing in Agent Terminal calls `/voice`.

Use this when you want to speak a message to the session you are looking at, with no dispatcher. It is speech-to-text only: no spoken replies, and it cannot be triggered from a hook or a command. (Facts below are from Claude Code's voice dictation docs, `code.claude.com/docs/en/voice-dictation`, read 2026-10-16.)

1. Type `/voice`. It toggles dictation; `/voice hold` or `/voice tap` pick the mode, `/voice off` turns it off.
2. Hold **Space** and talk (hold mode, the default); release to stop. In tap mode you tap to start and tap again to send.
3. Read the text that appeared in the prompt, then press Enter.

**Read it before you send it.** A mishearing sent to a worker in bypass mode is a wrong instruction. Hold mode leaves the text in the prompt for you to check; tap mode auto-submits transcripts of three or more words. For anything that deploys, pushes, deletes or migrates, use hold mode, or use the dispatcher, which reads those back before relaying.

Settings and keys (all optional):

- Persist it: `"voice": {"enabled": true, "mode": "hold"}` in `~/.claude/settings.json`. There is also an `autoSubmit` sub-key.
- Rebind the key in `~/.claude/keybindings.json`: context `Chat`, action `voice:pushToTalk`, for example `"meta+k"`. In hold mode avoid a bare letter, which types during warm-up. Caps Lock cannot be bound.
- Language: the `language` setting (English by default). It also sets the language Claude answers in.

Requirements and limits:

- A claude.ai login. It does not work when `ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN`, `apiKeyHelper`, Bedrock, Vertex or Foundry take precedence.
- macOS asks for microphone access for the terminal app the first time. If it never asks and nothing records, System Settings > Privacy & Security > Microphone.
- It needs a local microphone: not in cloud sessions, SSH sessions or VS Code Remote sessions. Documented for the CLI and the VS Code extension. The docs do not mention the Desktop Code tab, so treat it as untested there.
- Recording stops after 15 seconds of silence or two minutes. Esc or Ctrl+C cancels.
- Space only starts dictation where Space would type into the prompt (not while paging the transcript, or in vim normal mode).

## Speed

The 2026-10-05 measurement was 15 to 40 seconds from the end of speech to the first spoken word, of which the voice pipeline was about 5 seconds and the rest the model turn in a large session (`PHASE0-RESULTS.md`, 0.6). `/dash` runs a script and says one short paragraph, so it avoids most of that. Whether it feels fast enough is the pass line you pick in `MANUAL-STEPS.md`, step 0.6.

## Not verified

- `/dash` has not been run live with sound: it was built overnight with no audio triggered. Its command file, the flags it passes and the installer link are tested; hearing it is step V1 in `MANUAL-STEPS.md`.
- `/voice` was not run here. It is the documented behaviour, nothing more.
- `voiceEnabled`, an older single-key form of the setting, is listed in the settings reference. This page documents the `voice` object only.
