# Parallel Claude Code Workflow (macOS, Desktop app + VS Code)

Goal: run 4-8 sessions across repos, stop re-reading context, get long-running autonomous work with few questions.

## 1. Setup in the Desktop app
1. Open Claude Code Desktop -> **Code** tab.
2. Per repo: choose Environment (Local / Cloud / SSH), pick the project folder, pick model, set permission mode.
3. Start in **Plan** mode, then move to Accept edits / Auto once the plan is good.
4. Tick the **worktree** option when two sessions touch the same repo (stored in `.claude/worktrees/`). Add a `.worktreeinclude` file if worktrees need `.env`.
5. Run all managed sessions inside the Desktop app: its sidebar (filter by status/project, group by project, Cmd-click for split view) only lists sessions it started.
6. Use `/btw` or Cmd+; for side questions that should not pollute the session.
7. Use Cloud sessions for long refactors/migrations.
8. Keep VS Code open on the same folders for editing and diffs.

## 2. Per-repo `.agent/` folder
- `GOAL.md` - outcome, scope boundaries, test command, definition of done.
- `STATE.md` - Done / In progress / Blocked / Decisions / Assumptions made / Recommended next step.
- `NEXT.md` - a self-contained prompt, ready to paste.

Add to `.gitignore`: `.claude/worktrees/` and `.agent/.retries`.

## 3. CLAUDE.md autonomy policy (template)
```
## Autonomy policy
- Read .agent/GOAL.md and .agent/STATE.md at the start of every session.
- Do not ask clarifying questions. When ambiguous, decide using this order:
  1) existing repo convention, 2) simplest option, 3) most reversible option.
- Log every assumption under "Assumptions made" in .agent/STATE.md and continue.
- If information is missing: fetch it first (read docs, grep the repo, run the command, use MCP tools). Ask only if all fail.
- Ask before: destructive or irreversible actions, spending money, handling credentials, force-push.
- Before stopping, run the test command in GOAL.md. Do not stop while it fails.
- At the end of every turn, update STATE.md and rewrite NEXT.md.
```

## 4. Hooks (shared by Desktop app, CLI and VS Code via ~/.claude/settings.json)
- **SessionStart**: inject `.agent/STATE.md` and `NEXT.md` into context.
- **PreCompact**: save state to STATE.md before compaction.
- **Stop**: check done-criteria; if unmet and retry counter < 3 (`.agent/.retries`), send back with the reason; otherwise allow stop and write summary. Verify exact block/continue JSON and loop-prevention field in the hooks docs.
- **Notification**: push only for `agent_needs_input` and `agent_completed`, include repo name (`basename "$PWD"`).
- **PreToolUse**: deny `rm -rf` and force-push. Use permission rules for hard allow/deny.
- **asyncRewake**: run long test suites in background and wake Claude on failure.

macOS notifications: `brew install terminal-notifier jq`, then
`terminal-notifier -title "$TITLE" -message "$MSG" -activate <bundle id>`.
If nothing appears: set notification style to Alerts and add a Focus-mode exception.

## 5. Director loop
A `director.sh` (or `/next` command) that runs `claude -p` on a cheaper model:
1. Read GOAL.md, STATE.md, `git log -5`, `git diff --stat`, latest test output.
2. Compare with acceptance criteria; if tests fail, that is the next item.
3. Rewrite NEXT.md as a self-contained prompt (goal, files, constraints, done-criteria, "don't ask, decide and log").
4. Optionally feed it back with `claude -p`.

A `dash.sh` prints one line per repo (listed in `~/.agent-repos`): status, blockers, age of last update.

## 6. Model budgeting
Strongest model for planning, architecture, review. Cheaper model for executing a well-specified plan, with tests and a reviewer subagent (`.claude/agents/`) in the loop. Parallel sessions multiply token use: cap active sessions at about 4-5 and park the rest behind their STATE.md.

## 7. Validate the plan (pilot)
1. Pilot ONE repo with a real test suite for 2-3 days.
2. Metrics: (a) times a session stopped to ask you something, (b) logged assumptions you had to overturn, (c) minutes per handoff.
3. Test hooks in a throwaway repo first (SessionStart injects, Stop retries then ends, notification shows repo name) in both Desktop and VS Code sessions.
4. Review first outputs via diff view / Review code.
5. Autonomy ladder: Plan -> Accept edits -> Auto. Never use Bypass permissions on real repos.
6. Add repos one at a time only when metrics improve.
7. Too many questions -> vague GOAL.md or missing test command. Confident wrong choices -> tighten decision policy and done-criteria.

## 8. Prompt to give your agent to build all this
```
Build a .agent/ workflow for this macOS (zsh) machine's Claude Code setup. First read the current Claude Code docs for hooks, desktop app, worktrees and cross-session messaging, and use the exact schemas they give. Install terminal-notifier and jq via Homebrew if missing. Deliver:
1) ~/.claude/commands/handoff.md and next.md slash commands.
2) Hook scripts in ~/.claude/settings.json: SessionStart (inject STATE.md + NEXT.md), PreCompact (save state), Stop (done-criteria check, max-3 retries in .agent/.retries, then write STATE.md), Notification (only agent_needs_input and agent_completed, with repo name, via notify.sh using terminal-notifier -activate).
3) director.sh using claude -p on a cheaper model that rewrites NEXT.md.
4) dash.sh printing one line per repo in ~/.agent-repos.
5) CLAUDE.md autonomy-policy template and .agent/ templates.
6) PreToolUse deny for rm -rf and force-push.
Make everything idempotent. Test each script in a throwaway repo, with one VS Code and one Desktop session, and show results before touching my real repos.
```
