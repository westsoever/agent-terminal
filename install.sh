#!/usr/bin/env bash
# install.sh - wire the ching kit into Claude Code, machine-wide. Idempotent; only ADDS hook entries.
#
#   install.sh [--dry-run] [--yes] [--replace-popup]
#   install.sh --uninstall [--dry-run] [--yes]
#   install.sh --install-prepush <repo> [--dry-run]
#   install.sh --install-dispatcher [--dry-run] [--yes]
#
# What it changes:
#   $SETTINGS_FILE (default ~/.claude/settings.json): merges hook entries with jq (backup first, unified
#       diff shown before applying; nothing is written when the result is identical), and appends the two
#       VoiceMode converse tool names to permissions.allow when they are missing (--uninstall leaves them).
#   $CLAUDE_DIR/ching  -> symlink to this directory;  $CLAUDE_DIR/commands/<name>.md -> symlink for every
#       file in commands/ (handoff, next, dash).
#   ~/.agent-repos: created empty with a comment if absent (optional extra list for dash.sh).
#   $LAUNCH_AGENTS_DIR/org.ching.watch.plist (default ~/Library/LaunchAgents): runs bin/ching-watch.sh every 300 s.
#   $LAUNCH_AGENTS_DIR/org.ching.learn.plist: runs bin/learn.sh every day at 05:30 local (the learner, Phase 6; the
#       weekly part runs on the first run of each ISO week, normally Monday), with CHING_LEARNER=1 and
#       CLAUDE_MEM_INTERNAL=1; launchd's own output goes to $AGENT_HOME/learn.log.
#   $CLAUDE_MEM_SETTINGS (default ~/.claude-mem/settings.json), only when it exists (D27; ching never needs
#       claude-mem): adds $AGENT_HOME/proposals/.work to CLAUDE_MEM_EXCLUDED_PROJECTS (comma-separated globs), so
#       claude-mem never observes the learner's own runs. Backup first, diff shown; --uninstall takes it out again.
# --install-dispatcher only prepares the voice dispatcher's own folder, $AGENT_HOME/dispatcher (default ~/.agent/dispatcher):
#   .claude/settings.json (its permissions and the tool-gate hook), mcp.json (VoiceMode, converse only) and AGENTS.md /
#   CLAUDE.md links to dispatcher/AGENTS.md. It never touches the settings file above. Start it with
#   $CLAUDE_DIR/ching/dispatcher/launch.sh. To remove it: rm -r the folder (it holds two generated files and two links).
# The preview shows the settings diff and the plist diff. Nothing is applied (settings, symlinks, plist,
# launchctl) without --yes or a "y" at a terminal; with no terminal and no --yes it prints what it would
# change and exits 1. --dry-run prints the same preview and exits 0.
# It never edits or removes vscode-session-manager-hook.sh or its entries. The blanket osascript
# "Session finished" popup is removed ONLY with --replace-popup.
#
# Overrides (for tests): SETTINGS_FILE, CLAUDE_DIR (default: dirname of SETTINGS_FILE when that is set,
# else ~/.claude), AGENT_REPOS_FILE, AGENT_HOME, CLAUDE_MEM_SETTINGS, LAUNCHCTL, LAUNCH_AGENTS_DIR.
set -euo pipefail

CHING_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ -n "${SETTINGS_FILE:-}" ] && [ -z "${CLAUDE_DIR:-}" ]; then CLAUDE_DIR=$(dirname "$SETTINGS_FILE"); fi
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
SETTINGS_FILE=${SETTINGS_FILE:-$CLAUDE_DIR/settings.json}
if [ -z "${AGENT_REPOS_FILE:-}" ]; then
  if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then AGENT_REPOS_FILE=$HOME/.agent-repos; else AGENT_REPOS_FILE=$(dirname "$CLAUDE_DIR")/.agent-repos; fi
fi
LINK="$CLAUDE_DIR/ching"

DRY=0; YES=0; POPUP=0; UNINSTALL=0; PREPUSH=""; DISPATCHER=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --replace-popup) POPUP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --install-prepush) PREPUSH=${2:?--install-prepush needs a repo path}; shift 2 ;;
    --install-dispatcher) DISPATCHER=1; shift ;;
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

link_plan=""
plan_link() { # target link
  local target=$1 link=$2
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then return 0; fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    say "warning: $link exists and is not our symlink; leaving it alone"; return 0
  fi
  link_plan="$link_plan$target|$link"$'\n'
}

# ---------------- the voice dispatcher's own folder ----------------
if [ "$DISPATCHER" -eq 1 ]; then
  AH=${AGENT_HOME:-$HOME/.agent}
  DDIR=${DISPATCHER_DIR:-$AH/dispatcher}
  VM=$(command -v voicemode 2>/dev/null || echo voicemode)
  render() { # template -> the template with its @placeholders@ filled in (jq: any character in a path is safe)
    jq --indent 2 --arg link "$LINK" --arg vm "$VM" \
      'walk(if type == "string" then gsub("@CHING@"; $link) | gsub("@VOICEMODE@"; $vm) else . end)' "$1"
  }
  tmpd
  gen_files="$DDIR/.claude/settings.json|$CHING_ROOT/dispatcher/settings.json
$DDIR/mcp.json|$CHING_ROOT/dispatcher/mcp.json"
  write_plan=""
  while IFS='|' read -r dest tmpl; do
    [ -n "$dest" ] || continue
    render "$tmpl" >"$TMPD/render.new"
    if [ -f "$dest" ] && [ "$(cat "$dest")" = "$(cat "$TMPD/render.new")" ]; then continue; fi
    say "== dispatcher: $dest"
    if [ -f "$dest" ]; then
      diff -u --label "$dest (current)" --label "$dest (after install)" "$dest" "$TMPD/render.new" || true
    else
      diff -u --label "$dest (absent)" --label "$dest (after install)" /dev/null "$TMPD/render.new" || true
    fi
    cp "$TMPD/render.new" "$TMPD/w.$(printf '%s' "$dest" | shasum | cut -c1-12)"
    write_plan="$write_plan$dest|$TMPD/w.$(printf '%s' "$dest" | shasum | cut -c1-12)"$'\n'
  done <<<"$gen_files"
  if [ "$(readlink "$LINK" 2>/dev/null)" != "$CHING_ROOT" ]; then
    say "warning: $LINK is not the kit's symlink yet. The dispatcher's paths go through it: run install.sh first."
  fi
  plan_link "$LINK/dispatcher/AGENTS.md" "$DDIR/AGENTS.md"
  plan_link "AGENTS.md" "$DDIR/CLAUDE.md"
  if [ -z "$write_plan" ] && [ -z "$link_plan" ]; then say "nothing to do"; exit 0; fi
  d_plan() {
    while IFS='|' read -r dest _; do [ -z "$dest" ] || would "write $dest"; done <<<"$write_plan"
    while IFS='|' read -r t l; do [ -z "$l" ] || would "symlink $l -> $t"; done <<<"$link_plan"
  }
  if [ "$DRY" -eq 1 ]; then d_plan; exit 0; fi
  if [ "$YES" -eq 0 ]; then
    d_plan
    if [ -t 0 ]; then
      printf 'Apply these changes? [y/N] '; read -r ans
      case "$ans" in y|Y|yes) ;; *) say "aborted"; exit 1 ;; esac
    else
      echo "install: not a terminal; re-run with --yes to apply the changes shown above" >&2; exit 1
    fi
  fi
  while IFS='|' read -r dest src; do
    [ -n "$dest" ] || continue
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest.tmp" && mv "$dest.tmp" "$dest"; act "wrote $dest"
  done <<<"$write_plan"
  while IFS='|' read -r t l; do
    [ -n "$l" ] || continue
    mkdir -p "$(dirname "$l")"; ln -s "$t" "$l"; act "symlink $l -> $t"
  done <<<"$link_plan"
  say "dispatcher ready. Start it with: $LINK/dispatcher/launch.sh"
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
need_plist() { # file body -> 0 when this run must write (install) or remove (uninstall) it
  if [ "$UNINSTALL" -eq 0 ]; then [ ! -f "$1" ] || [ "$(cat "$1")" != "$2" ]; else [ -f "$1" ]; fi
}
NEED_PLIST=0; if need_plist "$PLIST" "$PLIST_BODY"; then NEED_PLIST=1; fi

# ---------------- launchd learner (learn.sh every day at 05:30; Phase 6, D26) ----------------
LPLIST="$LAUNCH_AGENTS_DIR/org.ching.learn.plist"
X_PATH=$(xml_esc "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin")   # claude lives in ~/.local/bin
LPLIST_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.ching.learn</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$X_LINK/bin/learn.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>5</integer><key>Minute</key><integer>30</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$X_PATH</string>
    <key>AGENT_HOME</key><string>$X_AH</string>
    <key>CHING_LEARNER</key><string>1</string>
    <key>CLAUDE_MEM_INTERNAL</key><string>1</string>
  </dict>
  <key>StandardOutPath</key><string>$X_AH/learn.log</string>
  <key>StandardErrorPath</key><string>$X_AH/learn.log</string>
</dict>
</plist>
EOP
)
NEED_LPLIST=0; if need_plist "$LPLIST" "$LPLIST_BODY"; then NEED_LPLIST=1; fi

# ---------------- claude-mem exclusion (D27): keep claude-mem from observing the learner ----------------
# claude-mem 13.40.0 (scripts/worker-service.cjs) skips a session whose cwd matches one of the comma-separated globs in
# CLAUDE_MEM_EXCLUDED_PROJECTS (a leading ~/ is expanded); the learner's model calls run in $AH/proposals/.work. Only
# an existing flat settings file is touched: no claude-mem, nothing to do.
CM_FILE=${CLAUDE_MEM_SETTINGS:-$HOME/.claude-mem/settings.json}
CM_PATH="$AH/proposals/.work"
CM_CHANGED=0; CM_NEW=""
if [ -f "$CM_FILE" ]; then
  cm_cur=$(cat "$CM_FILE")
  if ! printf '%s' "$cm_cur" | jq -e 'type == "object" and ((.CLAUDE_MEM_EXCLUDED_PROJECTS // "") | type) == "string"' >/dev/null 2>&1; then
    say "warning: $CM_FILE is not a JSON object with a string CLAUDE_MEM_EXCLUDED_PROJECTS; leaving it alone"
  else
    CM_NEW=$(printf '%s' "$cm_cur" | jq --indent 2 --arg p "$CM_PATH" --argjson un "$UNINSTALL" '
      ((.CLAUDE_MEM_EXCLUDED_PROJECTS // "") | split(",") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $l
      | if $un == 1 then
          (if ($l | index($p)) == null then . elif (($l - [$p]) | length) == 0 then del(.CLAUDE_MEM_EXCLUDED_PROJECTS)
           else .CLAUDE_MEM_EXCLUDED_PROJECTS = (($l - [$p]) | join(",")) end)
        elif ($l | index($p)) != null then .
        else .CLAUDE_MEM_EXCLUDED_PROJECTS = (($l + [$p]) | join(",")) end')
    if [ "$(canon "$cm_cur")" != "$(canon "$CM_NEW")" ]; then CM_CHANGED=1; fi
  fi
fi

if [ "$CHANGED" -eq 0 ] && [ -z "$link_plan" ] && [ "$NEED_REPOS" -eq 0 ] && [ "$NEED_PLIST" -eq 0 ] \
   && [ "$NEED_LPLIST" -eq 0 ] && [ "$CM_CHANGED" -eq 0 ]; then
  say "nothing to do"; exit 0
fi

# The launchd jobs belong in the preview too: show what replaces what, like the settings diff above.
show_plist_diff() { # file body
  say "== launchd: $1"
  tmpd
  if [ "$UNINSTALL" -eq 1 ]; then
    diff -u --label "$1 (current)" --label "$1 (removed)" "$1" /dev/null || true
  else
    printf '%s\n' "$2" >"$TMPD/plist.new"
    if [ -f "$1" ]; then
      diff -u --label "$1 (current)" --label "$1 (after install)" "$1" "$TMPD/plist.new" || true
    else
      diff -u --label "$1 (absent)" --label "$1 (after install)" /dev/null "$TMPD/plist.new" || true
    fi
  fi
}
[ "$NEED_PLIST" -eq 0 ] || show_plist_diff "$PLIST" "$PLIST_BODY"
[ "$NEED_LPLIST" -eq 0 ] || show_plist_diff "$LPLIST" "$LPLIST_BODY"
if [ "$CM_CHANGED" -eq 1 ]; then
  say "== claude-mem: $CM_FILE"
  tmpd
  printf '%s\n' "$cm_cur" >"$TMPD/cm.before"; printf '%s\n' "$CM_NEW" >"$TMPD/cm.after"
  diff -u --label "$CM_FILE (current)" --label "$CM_FILE (after install)" "$TMPD/cm.before" "$TMPD/cm.after" || true
fi
plan_lines() { # everything this run would do, whether or not settings.json changes
  while IFS='|' read -r t l; do [ -z "$l" ] || would "symlink $l -> $t"; done <<<"$link_plan"
  [ "$NEED_REPOS" -eq 0 ] || would "create $AGENT_REPOS_FILE (empty, optional)"
  [ "$CHANGED" -eq 0 ] || would "back up and rewrite $SETTINGS_FILE"
  [ "$NEED_PLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "launchctl bootout and remove $PLIST"; else would "write $PLIST and launchctl bootstrap it"; fi; }
  [ "$NEED_LPLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "launchctl bootout and remove $LPLIST"; else would "write $LPLIST and launchctl bootstrap it"; fi; }
  [ "$CM_CHANGED" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "back up $CM_FILE and take $CM_PATH out of CLAUDE_MEM_EXCLUDED_PROJECTS"; else would "back up $CM_FILE and add $CM_PATH to CLAUDE_MEM_EXCLUDED_PROJECTS"; fi; }
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
if [ "$CM_CHANGED" -eq 1 ]; then
  CM_BACKUP="$CM_FILE.bak.ching.$(date +%Y%m%d-%H%M%S)"
  cp -p "$CM_FILE" "$CM_BACKUP"; act "backup -> $CM_BACKUP"
  tmp=$(mktemp "$(dirname "$CM_FILE")/.settings.XXXXXX")
  printf '%s\n' "$CM_NEW" >"$tmp"
  chmod "$(stat -f %Lp "$CM_FILE" 2>/dev/null || stat -c %a "$CM_FILE")" "$tmp"
  mv "$tmp" "$CM_FILE"; act "wrote $CM_FILE (CLAUDE_MEM_EXCLUDED_PROJECTS)"
fi
apply_plist() { # file body label what
  if [ "$UNINSTALL" -eq 1 ]; then
    "$LAUNCHCTL" bootout "gui/$(id -u)/$3" >/dev/null 2>&1 || true
    rm -f "$1"; act "removed $1"
  else
    mkdir -p "$LAUNCH_AGENTS_DIR" "$AH"
    printf '%s\n' "$2" >"$1.tmp"
    mv "$1.tmp" "$1"
    "$LAUNCHCTL" bootout "gui/$(id -u)/$3" >/dev/null 2>&1 || true
    if ! "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$1"; then
      # launchd needs the plist at its final path, so remove it on failure: the next run sees it missing and retries
      rm -f "$1"
      echo "install: launchctl bootstrap failed; removed $1 so the next run retries" >&2
      exit 1
    fi
    act "loaded $1 ($4)"
  fi
}
[ "$NEED_PLIST" -eq 0 ] || apply_plist "$PLIST" "$PLIST_BODY" org.ching.watch "ching-watch every 5 minutes"
[ "$NEED_LPLIST" -eq 0 ] || apply_plist "$LPLIST" "$LPLIST_BODY" org.ching.learn "learn.sh every day at 05:30"
if [ "$UNINSTALL" -eq 1 ]; then say "note: --uninstall removes hook entries, the watcher and the learner job; symlinks, a removed popup and the converse entries in permissions.allow (they may predate the install) are left as they are."; fi
exit 0
