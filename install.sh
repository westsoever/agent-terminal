#!/usr/bin/env bash
# install.sh - wire the ching kit into Claude Code, machine-wide. Idempotent; only ADDS hook entries.
#
#   install.sh [--dry-run] [--yes] [--replace-popup]
#   install.sh --uninstall [--dry-run] [--yes]
#   install.sh --install-prepush <repo> [--dry-run]
#
# What it changes:
#   $SETTINGS_FILE (default ~/.claude/settings.json): merges hook entries with jq (backup first, unified
#       diff shown before applying; nothing is written when the result is identical), and appends the two
#       VoiceMode converse tool names to permissions.allow when they are missing (--uninstall leaves them).
#   $CLAUDE_DIR/ching  -> symlink to this directory;  $CLAUDE_DIR/commands/<name>.md -> symlink for every
#       file in commands/ (handoff, next, dash).
#   ~/.agent-repos: created empty with a comment if absent (optional extra list for dash.sh).
#   $LAUNCH_AGENTS_DIR/org.ching.watch.plist (default ~/Library/LaunchAgents): runs bin/ching-watch.sh every 300 s.
# The preview shows the settings diff and the plist diff. Nothing is applied (settings, symlinks, plist,
# launchctl) without --yes or a "y" at a terminal; with no terminal and no --yes it prints what it would
# change and exits 1. --dry-run prints the same preview and exits 0.
# It never edits or removes vscode-session-manager-hook.sh or its entries. The blanket osascript
# "Session finished" popup is removed ONLY with --replace-popup.
#
# Overrides (for tests): SETTINGS_FILE, CLAUDE_DIR (default: dirname of SETTINGS_FILE when that is set,
# else ~/.claude), AGENT_REPOS_FILE, AGENT_HOME, LAUNCHCTL, LAUNCH_AGENTS_DIR.
set -euo pipefail

CHING_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ -n "${SETTINGS_FILE:-}" ] && [ -z "${CLAUDE_DIR:-}" ]; then CLAUDE_DIR=$(dirname "$SETTINGS_FILE"); fi
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
SETTINGS_FILE=${SETTINGS_FILE:-$CLAUDE_DIR/settings.json}
if [ -z "${AGENT_REPOS_FILE:-}" ]; then
  if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then AGENT_REPOS_FILE=$HOME/.agent-repos; else AGENT_REPOS_FILE=$(dirname "$CLAUDE_DIR")/.agent-repos; fi
fi
LINK="$CLAUDE_DIR/ching"

DRY=0; YES=0; POPUP=0; UNINSTALL=0; PREPUSH=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --replace-popup) POPUP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --install-prepush) PREPUSH=${2:?--install-prepush needs a repo path}; shift 2 ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install: unknown argument $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "install: jq is required" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
act() { if [ "$DRY" -eq 1 ]; then say "would: $*"; else say "did:   $*"; fi; }
would() { say "would: $*"; }
TMPD=""
tmpd() { if [ -z "$TMPD" ]; then TMPD=$(mktemp -d "${TMPDIR:-/tmp}/ching-install.XXXXXX"); trap 'rm -rf "$TMPD"' EXIT; fi; }

# ---------------- pre-push hook for one repo ----------------
if [ -n "$PREPUSH" ]; then
  git -C "$PREPUSH" rev-parse --git-dir >/dev/null 2>&1 || { echo "install: $PREPUSH is not a git repo" >&2; exit 1; }
  hooks_dir=$(git -C "$PREPUSH" rev-parse --git-path hooks)
  case "$hooks_dir" in /*) ;; *) hooks_dir="$(cd "$PREPUSH" && pwd -P)/$hooks_dir" ;; esac
  target="$hooks_dir/pre-push"
  rendered=$(sed "s#@CHING_BIN@#$LINK/bin#" "$CHING_ROOT/templates/pre-push")
  if [ -f "$target" ] && ! grep -q 'ching-prepush-marker' "$target"; then
    target="$hooks_dir/pre-push.ching"
    say "note: $hooks_dir/pre-push already exists and is not ours; writing pre-push.ching instead."
    say "      Chain it from your hook:  \"$target\" \"\$@\" || exit 1   (stdin must be passed through)"
  fi
  if [ -f "$target" ] && [ "$(cat "$target")" = "$rendered" ]; then say "pre-push hook already installed: $target"; exit 0; fi
  act "write $target"
  if [ "$DRY" -eq 0 ]; then mkdir -p "$hooks_dir"; printf '%s\n' "$rendered" >"$target"; chmod +x "$target"; fi
  exit 0
fi

# ---------------- settings merge ----------------
if [ -f "$SETTINGS_FILE" ]; then CURRENT=$(cat "$SETTINGS_FILE"); else CURRENT='{}'; fi
printf '%s' "$CURRENT" | jq -e . >/dev/null 2>&1 || { echo "install: $SETTINGS_FILE is not valid JSON" >&2; exit 1; }

# Voice (Phase 3.1): the VoiceMode converse tool, under both names it can have (the plugin's MCP server
# "voicemode" is mcp__plugin_voicemode_voicemode__converse, a hand-added server is mcp__voicemode__converse).
# Appended to permissions.allow when missing. Nothing else under permissions is created or changed.
VOICE_ALLOW='["mcp__voicemode__converse","mcp__plugin_voicemode_voicemode__converse"]'
GUARD_MATCHER='Bash|Read|Grep|Edit|Write|MultiEdit|NotebookEdit|Monitor|mcp__.*[Ss]upabase.*|mcp__.*([Gg]mail|[Ss]lack|[Dd]iscord|[Tt]elegram).*'

# event, matcher, command, timeout (seconds); tab separated because matchers contain '|'
hook_line() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
HOOKS=$(
  hook_line SessionStart "" "$LINK/bin/session-start.sh" 10
  hook_line UserPromptSubmit "" "$LINK/bin/session-start.sh touch" 5
  hook_line SessionEnd "" "$LINK/bin/session-start.sh end" 10
  hook_line PreCompact "" "$LINK/bin/pre-compact.sh" 10
  hook_line Stop "" "$LINK/bin/stop-check.sh" 900
  hook_line PreToolUse "$GUARD_MATCHER" "$LINK/bin/guard.sh" 15
  hook_line Notification "idle_prompt" "$LINK/bin/notify.sh idle" 10
)
HOOKS_JSON=$(printf '%s\n' "$HOOKS" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")
    | {event: .[0], matcher: .[1], command: .[2], timeout: (.[3] | tonumber)})')

if [ "$UNINSTALL" -eq 1 ]; then
  NEW=$(printf '%s' "$CURRENT" | jq --indent 2 '
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | contains("/ching/bin/") | not)))
                                          | map(select((.hooks | length) > 0))))
                 | with_entries(select((.value | length) > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end')
else
  NEW=$(printf '%s' "$CURRENT" | jq --indent 2 --argjson add "$HOOKS_JSON" --argjson popup "$POPUP" --argjson voice "$VOICE_ALLOW" '
    def has_cmd($g; $c): ([$g[]? | .hooks[]? | .command] | index($c)) != null;
    .hooks = (.hooks // {})
    | reduce $add[] as $h (.;
        .hooks[$h.event] = ((.hooks[$h.event] // []) as $g
          | if has_cmd($g; $h.command)
            then $g | map(if ([.hooks[]?.command] | index($h.command)) != null then .matcher = $h.matcher else . end)
            else $g + [{matcher: $h.matcher, hooks: [{type: "command", command: $h.command, timeout: $h.timeout}]}] end))
    | if ((.permissions // {}) | type) == "object" and ((.permissions.allow // []) | type) == "array" then
        .permissions.allow = ((.permissions.allow // []) as $a | $a + ($voice - $a))
      else . end
    | if $popup == 1 and .hooks.Stop then
        .hooks.Stop |= (map(.hooks |= map(select(((.command // "") | test("osascript.*Session finished")) | not)))
                        | map(select((.hooks | length) > 0)))
      else . end')
fi

canon() { printf '%s' "$1" | jq -S -c .; }
CHANGED=0
if [ "$(canon "$CURRENT")" != "$(canon "$NEW")" ]; then CHANGED=1; fi

if [ "$CHANGED" -eq 1 ]; then
  say "== settings: $SETTINGS_FILE"
  if [ -f "$SETTINGS_FILE" ] && [ "$(printf '%s' "$CURRENT" | jq --indent 2 .)" != "$CURRENT" ]; then
    say "(note: the file is not in jq's canonical formatting; the diff may include reformatting)"
  fi
  tmpd
  printf '%s\n' "$CURRENT" >"$TMPD/before"; printf '%s\n' "$NEW" >"$TMPD/after"
  diff -u --label "$SETTINGS_FILE (current)" --label "$SETTINGS_FILE (after install)" "$TMPD/before" "$TMPD/after" || true
else
  say "settings: no changes needed ($SETTINGS_FILE)"
fi

# ---------------- symlinks and files ----------------
link_plan=""
plan_link() { # target link
  local target=$1 link=$2
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then return 0; fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    say "warning: $link exists and is not our symlink; leaving it alone"; return 0
  fi
  link_plan="$link_plan$target|$link"$'\n'
}
if [ "$UNINSTALL" -eq 0 ]; then
  plan_link "$CHING_ROOT" "$LINK"
  for c in "$CHING_ROOT"/commands/*.md; do
    [ -f "$c" ] || continue
    plan_link "$c" "$CLAUDE_DIR/commands/$(basename "$c")"
  done
fi
NEED_REPOS=0
if [ "$UNINSTALL" -eq 0 ] && [ ! -e "$AGENT_REPOS_FILE" ]; then NEED_REPOS=1; fi

# ---------------- launchd watcher (ching-watch.sh every 5 minutes) ----------------
LAUNCH_AGENTS_DIR=${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LAUNCHCTL=${LAUNCHCTL:-launchctl}
PLIST="$LAUNCH_AGENTS_DIR/org.ching.watch.plist"
AH=${AGENT_HOME:-$HOME/.agent}
# values go into XML text: & < > in a path would otherwise break the plist (launchd then refuses to load it)
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
X_LINK=$(xml_esc "$LINK"); X_AH=$(xml_esc "$AH")
PLIST_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.ching.watch</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$X_LINK/bin/ching-watch.sh</string></array>
  <key>StartInterval</key><integer>300</integer>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>AGENT_HOME</key><string>$X_AH</string>
  </dict>
  <key>StandardOutPath</key><string>$X_AH/watch.log</string>
  <key>StandardErrorPath</key><string>$X_AH/watch.log</string>
</dict>
</plist>
EOP
)
NEED_PLIST=0
if [ "$UNINSTALL" -eq 0 ]; then
  if [ ! -f "$PLIST" ] || [ "$(cat "$PLIST")" != "$PLIST_BODY" ]; then NEED_PLIST=1; fi
elif [ -f "$PLIST" ]; then
  NEED_PLIST=1
fi

if [ "$CHANGED" -eq 0 ] && [ -z "$link_plan" ] && [ "$NEED_REPOS" -eq 0 ] && [ "$NEED_PLIST" -eq 0 ]; then
  say "nothing to do"; exit 0
fi

# The launchd job belongs in the preview too: show what replaces what, like the settings diff above.
if [ "$NEED_PLIST" -eq 1 ]; then
  say "== launchd: $PLIST"
  tmpd
  if [ "$UNINSTALL" -eq 1 ]; then
    diff -u --label "$PLIST (current)" --label "$PLIST (removed)" "$PLIST" /dev/null || true
  else
    printf '%s\n' "$PLIST_BODY" >"$TMPD/plist.new"
    if [ -f "$PLIST" ]; then
      diff -u --label "$PLIST (current)" --label "$PLIST (after install)" "$PLIST" "$TMPD/plist.new" || true
    else
      diff -u --label "$PLIST (absent)" --label "$PLIST (after install)" /dev/null "$TMPD/plist.new" || true
    fi
  fi
fi
plan_lines() { # everything this run would do, whether or not settings.json changes
  while IFS='|' read -r t l; do [ -z "$l" ] || would "symlink $l -> $t"; done <<<"$link_plan"
  [ "$NEED_REPOS" -eq 0 ] || would "create $AGENT_REPOS_FILE (empty, optional)"
  [ "$CHANGED" -eq 0 ] || would "back up and rewrite $SETTINGS_FILE"
  [ "$NEED_PLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "launchctl bootout and remove $PLIST"; else would "write $PLIST and launchctl bootstrap it"; fi; }
}
if [ "$DRY" -eq 1 ]; then plan_lines; exit 0; fi

# Nothing is applied without --yes or an answer at a terminal: not the settings, not the symlinks, and
# not the launchd job (a changed or missing plist is replaced and loaded only after this point).
if [ "$YES" -eq 0 ]; then
  plan_lines
  if [ -t 0 ]; then
    printf 'Apply these changes? [y/N] '; read -r ans
    case "$ans" in y|Y|yes) ;; *) say "aborted"; exit 1 ;; esac
  else
    echo "install: not a terminal; re-run with --yes to apply the changes shown above" >&2; exit 1
  fi
fi

if [ "$CHANGED" -eq 1 ]; then
  mkdir -p "$(dirname "$SETTINGS_FILE")"
  if [ -f "$SETTINGS_FILE" ]; then
    BACKUP="$SETTINGS_FILE.bak.ching.$(date +%Y%m%d-%H%M%S)"
    cp -p "$SETTINGS_FILE" "$BACKUP"; act "backup -> $BACKUP"
  fi
  tmp=$(mktemp "$(dirname "$SETTINGS_FILE")/.settings.XXXXXX")
  printf '%s\n' "$NEW" >"$tmp"
  if [ -f "$SETTINGS_FILE" ]; then chmod --reference="$SETTINGS_FILE" "$tmp" 2>/dev/null || chmod "$(stat -f %Lp "$SETTINGS_FILE")" "$tmp"; fi
  mv "$tmp" "$SETTINGS_FILE"; act "wrote $SETTINGS_FILE"
fi
while IFS='|' read -r t l; do
  [ -n "$l" ] || continue
  mkdir -p "$(dirname "$l")"; ln -s "$t" "$l"; act "symlink $l -> $t"
done <<<"$link_plan"
if [ "$NEED_REPOS" -eq 1 ]; then
  cp "$CHING_ROOT/templates/agent-repos.example" "$AGENT_REPOS_FILE.tmp"
  sed -i.bak 's/^~/# ~/' "$AGENT_REPOS_FILE.tmp"; rm -f "$AGENT_REPOS_FILE.tmp.bak"
  mv "$AGENT_REPOS_FILE.tmp" "$AGENT_REPOS_FILE"; act "create $AGENT_REPOS_FILE"
fi
if [ "$NEED_PLIST" -eq 1 ]; then
  if [ "$UNINSTALL" -eq 1 ]; then
    "$LAUNCHCTL" bootout "gui/$(id -u)/org.ching.watch" >/dev/null 2>&1 || true
    rm -f "$PLIST"; act "removed $PLIST"
  else
    mkdir -p "$LAUNCH_AGENTS_DIR" "$AH"
    printf '%s\n' "$PLIST_BODY" >"$PLIST.tmp"
    mv "$PLIST.tmp" "$PLIST"
    "$LAUNCHCTL" bootout "gui/$(id -u)/org.ching.watch" >/dev/null 2>&1 || true
    if ! "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$PLIST"; then
      # launchd needs the plist at its final path, so remove it on failure: the next run sees it missing and retries
      rm -f "$PLIST"
      echo "install: launchctl bootstrap failed; removed $PLIST so the next run retries" >&2
      exit 1
    fi
    act "loaded $PLIST (ching-watch every 5 minutes)"
  fi
fi
if [ "$UNINSTALL" -eq 1 ]; then say "note: --uninstall removes hook entries and the watcher; symlinks, a removed popup and the converse entries in permissions.allow (they may predate the install) are left as they are."; fi
exit 0
