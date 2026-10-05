# Checkpoint 1: Phase 1 core kit built and tested

Status: all of Phase 1 (1.1 to 1.9) is built in `~/bbq/ching`, versioned with a local `git init` (no remote). Nothing outside `~/bbq/ching` and `/tmp` was written. Your real `~/.claude/settings.json` was only read (checksum verified unchanged after the dry run below). Stopping here for your approval before `install.sh` touches real settings.

Scope: v3 (machine-wide), see the note at the top of PLAN.md. Hooks work in any cwd (repo, plain folder, `~`); state is in `~/.agent/` (override `AGENT_HOME`); a repo `.agent/GOAL.md` is an optional override that also opts that repo into the Stop check and the release/migrate gates.

## 1. What was built

`bin/` session-start (also `touch` and `end` modes for UserPromptSubmit/SessionEnd), pre-compact, stop-check, notify, guard, release-gate, post-release, migrate-gate, dash, plus `lib.sh` (shared helpers; the one addition to the section 5 layout, needed once state became machine-wide). `commands/handoff.md`, `commands/next.md`, `templates/` (GOAL, STATE, NEXT, VERIFY evidence format, autonomy block, gitignore lines, agent-repos example, `pre-push` hook), `dispatcher/AGENTS.md`, `install.sh`, `tests/` (`run.sh`, 9 test files, optional `live-smoke.sh`).

Install steps for you later (not done): `brew install terminal-notifier` (notify.sh degrades to osascript without it), then `./install.sh --dry-run`, then `./install.sh` (add `--replace-popup` to drop the blanket "Session finished" popup), and per repo `./install.sh --install-prepush <repo>` for the git backstop.

## 2. Test output (`tests/run.sh`)

```
file             pass   fail
t_dash             30      0
t_guard           216      0
t_install          49      0
t_lint             47      0
t_migrate          85      0
t_notify           15      0
t_post_release     17      0
t_release          75      0
t_session          31      0
t_stop             32      0

TOTAL: 597 passed, 0 failed, 0 skipped
```

Runs in about 11 s (files run in parallel, each in its own sandbox under /tmp with HOME, AGENT_HOME and CLAUDE_DIR redirected, notifications in dry-run or faked). shellcheck 0.11 (installed in a throwaway /tmp venv, not brew) is clean on every script; `t_lint` runs it when present and skips otherwise. Scripts target the macOS system bash 3.2.

Live check (not part of run.sh, `tests/live-smoke.sh`, about US$0.10 on haiku): through the real `claude -p` in bypassPermissions with the hooks that `install.sh` generated (passed via `--settings`): SessionStart `additionalContext` reached the model (it answered `PINEAPPLE-42` from STATE.md); the Stop hook blocked, the model acted on the reason (created the file, logged to STATE.md), the second Stop passed and a single "Done" notification was logged; `git push --force origin HEAD:scratch` was denied by `guard.sh` (the remote stayed empty).

## 3. Exact diff install.sh WOULD make (`--dry-run` on a /tmp copy of the real settings.json)

Command: `CLAUDE_DIR=/Users/clyde/.claude SETTINGS_FILE=/tmp/cp1/settings.json AGENT_REPOS_FILE=/tmp/cp1/agent-repos ./install.sh --dry-run`. Size: 74 lines added, 0 removed (7 new hook entries). Your existing entries (vscode-session-manager on SessionEnd, Stop, PreToolUse, UserPromptSubmit, Notification, the python title hook, and the osascript popup) are untouched. The real file is already in jq canonical formatting, so there is no reformatting noise.

```diff
--- /tmp/cp1/settings.json (current)
+++ /tmp/cp1/settings.json (after install)
@@ -32,6 +32,16 @@
             "command": "/Users/clyde/.claude/vscode-session-manager-hook.sh end"
           }
         ]
+      },
+      {
+        "matcher": "",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/session-start.sh end",
+            "timeout": 10
+          }
+        ]
       }
     ],
     "Stop": [
@@ -48,6 +58,16 @@
             "timeout": 5
           }
         ]
+      },
+      {
+        "matcher": "",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/stop-check.sh",
+            "timeout": 900
+          }
+        ]
       }
     ],
     "PreToolUse": [
@@ -59,6 +79,16 @@
             "command": "/Users/clyde/.claude/vscode-session-manager-hook.sh resume"
           }
         ]
+      },
+      {
+        "matcher": "Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/guard.sh",
+            "timeout": 15
+          }
+        ]
       }
     ],
     "UserPromptSubmit": [
@@ -70,6 +100,16 @@
             "command": "/Users/clyde/.claude/vscode-session-manager-hook.sh start"
           }
         ]
+      },
+      {
+        "matcher": "",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/session-start.sh touch",
+            "timeout": 5
+          }
+        ]
       }
     ],
     "Notification": [
@@ -81,7 +121,41 @@
             "command": "/Users/clyde/.claude/vscode-session-manager-hook.sh stop"
           }
         ]
+      },
+      {
+        "matcher": "idle_prompt",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/notify.sh idle",
+            "timeout": 10
+          }
+        ]
       }
+    ],
+    "SessionStart": [
+      {
+        "matcher": "",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/session-start.sh",
+            "timeout": 10
+          }
+        ]
+      }
+    ],
+    "PreCompact": [
+      {
+        "matcher": "",
+        "hooks": [
+          {
+            "type": "command",
+            "command": "/Users/clyde/.claude/ching/bin/pre-compact.sh",
+            "timeout": 10
+          }
+        ]
+      }
     ]
   },
   "enableArtifact": false,
```

Other actions it would take (all under `~/.claude` plus an optional `~/.agent-repos`):

```
would: symlink /Users/clyde/.claude/ching -> /Users/clyde/bbq/ching
would: symlink /Users/clyde/.claude/commands/handoff.md -> /Users/clyde/bbq/ching/commands/handoff.md
would: symlink /Users/clyde/.claude/commands/next.md -> /Users/clyde/bbq/ching/commands/next.md
would: create /tmp/cp1/agent-repos (empty, optional)
would: back up and rewrite /tmp/cp1/settings.json
```

With `--replace-popup` (opt-in) the only extra change is removing the popup entry from the first Stop group:

```
-          },
-            "command": "osascript -e 'display notification \"Session finished\" with title \"Claude Code\"'",
-            "timeout": 5
```

## 4. Behaviour you should know about

- The guard matcher is `Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|mcp__.*[Ss]upabase.*` and costs about 30 ms per tool call. It fails closed (internal error blocks with exit 2).
- Stop hooks run in parallel, so until you pass `--replace-popup` you get both the old popup and the new notification on every stop.
- `stop-check.sh` runs `test_command` only in repos with a `GOAL.md` (or when `~/.agent/defaults/GOAL.md` has one), skips the run when the tree is unchanged since the last green run, and gives up after 3 blocks per session id (Claude Code's own cap is 8).
- Confirm-mode release: the gate passes, notifies "Ready to push" and waits. You run `release-gate.sh --approve` in your own terminal (guard denies it for agents), then the agent pushes. If you install the `pre-push` hook it blocks YOUR pushes to main too without a token (use `git push --no-verify` as the human bypass; guard denies `--no-verify` for agents).
- Destructive migrations: blocked until `db/rollback/<name>.down.sql` exists and you run `migrate-gate.sh --confirm <file>` yourself; the confirmation is bound to the file contents.

## 5. Decisions I made that you may want to overrule

1. **Beyond the 5.1 list, guard.sh also denies:** `--no-verify` on any git command and `git commit -n`; changing `core.hooksPath`; writes to hooks dirs, user `settings.json` and the kit itself; hand-writing release or migrate tokens or reading the signing secret; `gh pr merge` (it lands code on the default branch without the gate); `gh api` calls that merge, dispatch workflows or write refs/contents; `gh run rerun`; `curl | bash`; `eval` of variables; `printenv`, bare `env`, `export -p`, echoing token variables; `psql` against Supabase hosts and `supabase db push/reset/execute`, `migration up/repair`. Protected branches are `main`, `master` and the remote default branch. Tell me if `gh pr merge` should be allowed.
2. **Evidence rule:** I read "reject non-2xx/404" as: any network status that is not 2xx (304 is accepted) is rejected, including 404 and 3xx redirects, unless a line under `## allowed` covers it with a written reason (a catch-all pattern is rejected). Any console line matching error/uncaught/unhandled/exception is rejected the same way. The model's own verdict line is ignored. A line like `[log] error-free run` is a (conservative) false positive.
3. **Tokens are HMAC-signed** with a secret in `~/.agent/secret` so a hand-written token fails. An agent that writes and runs its own script could still read that file; that residual risk is the same class as "a script that pushes" in PHASE0-RESULTS 0.9.
4. Per-session state lives under `~/.agent/sessions/<id>/` (meta, retries, last-pass, and STATE/NEXT for non-opted-in folders). A brand-new session in the same non-repo folder starts with fresh state (keyed by session id plus cwd, as requested); resumed sessions keep theirs.

## 6. Open questions

1. `gh pr merge` and the other extra denials in section 5: keep, or relax?
2. Should the dispatcher's `dash.sh --speak` count "done" sessions as inactive (it does now) and is 30 minutes the right "active" window?
3. Notification click target is the Claude desktop app (`com.anthropic.claudefordesktop`, read from the installed app). Do you want VS Code (`com.microsoft.VSCode`) for sessions started there? `NOTIFY_ACTIVATE` overrides it.
4. For miso's `db-migrate.ts`: I did not read it (hard rule), so `migrate_pending_cmd` (the dry-run that lists pending files) is unset by default and the guard recognises the runner by its name (`db-migrate*`, `db:migrate*`). Phase 2 should read the runner, set `migrate_pending_cmd` and confirm `--apply`/`--record-only` are the real flag names.
5. Supabase token narrowness and branching (original questions 4) are unchanged: Free plan, no branching.

## 7. Not verified

- Hooks in `~/.claude/settings.json` specifically (live test used `--settings`, same engine); Desktop Code tab and VS Code firing (0.4); `Notification` `idle_prompt` actually firing and the dedupe window (0.3); `SendMessage` waking idle sessions (0.5), so the dispatcher relay is design only; the dispatcher policy has not been exercised with a voice session.
- Real notifications: tests use fakes and dry-run so nothing popped on your screen. terminal-notifier is not installed; click-to-activate is untested. The osascript fallback is tested only with a fake binary (argv handling).
- Live guard coverage: only a Bash deny was exercised through the real engine. The Read, Edit and Supabase MCP matcher paths are unit-tested with synthetic hook JSON but not run live.
- The release gate against a real deploy (`gh run watch` output shapes) is tested with a fake `gh`.
- `dash.sh` state for sessions known only from transcripts is a heuristic (modified in the last 2 minutes means working). Sessions that predate the hooks have no blocker info until they run a hook.
- Shell-level limits stay: a regex over a command string cannot see everything (an agent-written script that pushes or deletes is not caught by guard.sh; the pre-push hook covers pushes only). GitHub branch protection remains the real backstop for main.
