# What Ching borrows from four other projects

Ching is our assistant that runs several AI coding helpers at the same time and keeps you informed about them. Four open-source projects, all built around a tool called Hermes, solve similar problems. We have not installed or run any of them. We read them, picked the useful ideas, and will rebuild those ideas inside Ching. Ching keeps using Claude Code as its only engine.

Throughout this page, a "session" means one AI helper working on one task.

## 1. hermes-plugins (by 42-evey): the biggest improvement

**The problem:** With 4 to 8 helpers working at once, you could get buried in alerts. Or one helper could get stuck and nobody would notice.

**What we take:**
- **A limit on interruptions.** At most 4 alerts a day, none during quiet hours, and a pause between alerts.
- **A watchdog.** A separate checker notices when a helper has stalled and tells you.
- **A "what should I do next?" list.** The dashboard ranks tasks by how urgent, how important, and how recent they are.
- **Spending warnings.** You get a heads-up when a helper has used 80% of its usage budget, and again at 100%.
- **Learning over time.** Ching keeps notes on what worked and what didn't. Old notes fade, and Ching turns the lasting ones into suggestions. You approve them before anything changes.

## 2. hermes-workspace (by outsourc-e): clearer status updates

**The problem:** Ching has to guess what each helper is doing, and you hear about things that don't need you.

**What we take:**
- **A standard progress note.** Every helper ends its notes with the same short summary: what happened, what's blocking it, what comes next, and which files changed. Ching can then read it without guessing.
- **Only the important messages.** You hear only when a helper needs your input or is blocked. Finished work is handled quietly: it waits in the dashboard's inbox, and reading the inbox marks it as seen. The dashboard groups helpers into "needs your review", "blocked", and "ready".
- **A "running out of room" signal.** AI helpers lose track of things when a conversation gets too long. Ching marks each helper as healthy, watch, or time-to-hand-off, and suggests passing the work to a fresh helper before it loses the thread.
- **A safety check.** Its approval checklist showed us a few gaps in our own safety script, which we can now fix.

## 3. super-hermes (by Cranot): honesty about what was missed

**The problem:** A report that says "all good" can hide what nobody checked.

**What we take:**
- **A "what we did and didn't look at" note** at the end of every handoff and review. For example: "This covered X. It did not examine Y." Gaps are written down, not hidden.
- **A list of repeated blind spots.** Those "did not examine" notes add up, so Ching can show you what your helpers keep skipping.
- **Three ways of reviewing.** Before a release, a reviewer helper checks the work from three angles: how it handles errors, whether things are what they claim to be, and what happens when it runs in a simulated real-world situation.

## 4. hermes-skill-factory (by Romanescu11): spotting repeated work

**The problem:** You may do the same kind of task again and again without noticing, across different helpers and different days.

**What we take:**
- **Pattern spotting.** Ching reads the record of past sessions and finds jobs you keep repeating.
- **Ching builds the shortcut itself.** When it sees a repeated job, it creates the shortcut (called a "skill") right away, without waiting for your approval. This matches how Hermes works.
- **Every new shortcut leaves a trail.** Ching records which sessions and how often the job came up, so you can see why a shortcut exists. If you don't like one, you can delete it.

## Keeping testing cheap

Whenever Ching runs the tests, it first runs them with no AI at all. The AI is only called if something fails, and it starts with the cheapest one:
1. **Tests pass:** done, no AI cost.
2. **Tests fail:** a small, cheap model (Haiku 4.5) tries to fix the problem.
3. **Still failing:** a stronger model (Sonnet 5.5) takes over.
4. **Still failing after that:** Ching stops and notifies you.

## 5. Check-ins when a helper is waiting for you

**The problem:** A helper finishes or gets stuck and waits for you, and you are looking at something else. Nothing tells you again.

**What we add:**
- **A banner** when a finished helper still has something open, such as a next step or a blocker.
- **One spoken sentence**, about 5 to 10 minutes later, if the helper is still waiting. It only speaks when you are at the Mac, nobody is using VoiceMode, and it is not quiet hours.
- **Silence for busy helpers.** A helper that is still working never triggers a reminder, even if you have been away for hours.
- **Limits so it cannot flood you.** The banner uses the same alert budget as every other alert. The spoken sentence is outside that budget, so it has its own limits: once each time a helper starts waiting, at most one every 10 minutes, never in quiet hours, and only when you are at the Mac.

Later: a small panel in the notch that you hover over to see the updates.

## 6. Talking to your helpers (voice, level A)

**What works now:**
- **Spoken status.** Run `~/.claude/ching/bin/dash.sh --speak` in any session. It prints one short summary that leads with how many helpers need you, for example "1 needs you. 5 active sessions out of 19. miso-app needs your input." The dispatcher uses the same command, and you can run it yourself.
- **Voice permission.** The two VoiceMode `converse` tool names are on the permission allowlist, so a session that is allowed to speak does not stop to ask first. Only the dispatcher is meant to speak; workers stay silent.

**Dictating into a helper (the fallback that always works):** type `/voice` in the helper you are looking at, hold the key to talk, and release to send. It is dictation only: you speak, the helper reads your words, and nothing is spoken back. It works in the terminal, the Desktop Code tab and VS Code. Use it whenever the dispatcher cannot reach a helper, or whenever you would rather say the instruction straight to that session.

**Check before you send:** if you dictate something that deletes, pushes, deploys or migrates, read the text on screen before you submit it. Speech-to-text mishears, and the guard only catches what it recognises as dangerous.
