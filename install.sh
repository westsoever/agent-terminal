#!/usr/bin/env bash
# install.sh - wire the agent-terminal kit into Claude Code, machine-wide. Idempotent; only ADDS hook entries.
#
#   install.sh [--dry-run] [--yes] [--replace-popup]
#   install.sh --uninstall [--dry-run] [--yes]
#   install.sh --install-prepush <repo> [--dry-run]
#   install.sh --install-dispatcher [--dry-run] [--yes]
#   install.sh --install-menubar [--dry-run] [--yes]
#
# What it changes:
#   $SETTINGS_FILE (default ~/.claude/settings.json): merges hook entries with jq (backup first, unified
#       diff shown before applying; nothing is written when the result is identical), and appends the two
#       VoiceMode converse tool names to permissions.allow when they are missing (--uninstall leaves them).
#   $CLAUDE_DIR/agent-terminal  -> symlink to this directory;  $CLAUDE_DIR/commands/<name>.md -> symlink for every
#       file in commands/ (handoff, next, dash);  $CL_LINK (~/.local/bin/cl) -> bin/cl (D73; --uninstall removes it).
#   From Kaching (D65) or Ching (D35): hooks under kaching/ or ching/ and the org.kaching.* / org.ching.* jobs are replaced; both links stay.
#   ~/.agent-repos: created empty with a comment if absent (optional extra list for dash.sh).
#   $LAUNCH_AGENTS_DIR/org.agent-terminal.watch.plist (default ~/Library/LaunchAgents): runs bin/agent-terminal-watch.sh every 300 s.
#   $LAUNCH_AGENTS_DIR/org.agent-terminal.learn.plist: runs bin/learn.sh every day at 05:30 local (the learner, Phase 6; the
#       weekly part runs on the first run of each ISO week, normally Monday), with AGENT_TERMINAL_LEARNER=1 and
#       CLAUDE_MEM_INTERNAL=1; launchd's own output goes to $AGENT_HOME/learn.log.
#   $CLAUDE_MEM_SETTINGS (default ~/.claude-mem/settings.json), only when it exists (D27; agent-terminal never needs
#       claude-mem): adds $AGENT_HOME/proposals/.work to CLAUDE_MEM_EXCLUDED_PROJECTS (comma-separated globs), so
#       claude-mem never observes the learner's own runs. Backup first, diff shown; --uninstall takes it out again.
# --install-dispatcher only prepares the voice dispatcher's own folder, $AGENT_HOME/dispatcher (default ~/.agent/dispatcher):
#   .claude/settings.json (its permissions and the tool-gate hook), mcp.json (VoiceMode, converse only) and AGENTS.md /
#   CLAUDE.md links to dispatcher/AGENTS.md. It never touches the settings file above. Start it with
#   $CLAUDE_DIR/agent-terminal/dispatcher/launch.sh. To remove it: rm -r the folder (it holds two generated files and two links).
# --install-menubar builds $AGENT_TERMINAL_APPS_DIR/AgentTerminalBar.app (default ~/Applications; ui/menubar/build.sh, swiftc from $SWIFTC
#   or /usr/bin) only when its source hash differs, and installs $LAUNCH_AGENTS_DIR/org.agent-terminal.menubar.plist (RunAtLoad;
#   KeepAlive unless it quit cleanly). --uninstall also removes both (the app only when its bundle id is ours).
# The preview shows the settings diff and the plist diff. Nothing is applied (settings, symlinks, plist,
# launchctl) without --yes or a "y" at a terminal; with no terminal and no --yes it prints what it would
# change and exits 1. --dry-run prints the same preview and exits 0.
# It never edits or removes vscode-session-manager-hook.sh or its entries. The blanket osascript
# "Session finished" popup is removed ONLY with --replace-popup.
#
# Overrides (for tests): SETTINGS_FILE, CLAUDE_DIR (default: dirname of SETTINGS_FILE when that is set,
# else ~/.claude), AGENT_REPOS_FILE, AGENT_HOME, CLAUDE_MEM_SETTINGS, AGENT_TERMINAL_APPS_DIR, SWIFTC, LAUNCHCTL, LAUNCH_AGENTS_DIR.
set -euo pipefail

AGENT_TERMINAL_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
if [ -n "${SETTINGS_FILE:-}" ] && [ -z "${CLAUDE_DIR:-}" ]; then CLAUDE_DIR=$(dirname "$SETTINGS_FILE"); fi
CLAUDE_DIR=${CLAUDE_DIR:-$HOME/.claude}
SETTINGS_FILE=${SETTINGS_FILE:-$CLAUDE_DIR/settings.json}
if [ -z "${AGENT_REPOS_FILE:-}" ]; then
  if [ "$CLAUDE_DIR" = "$HOME/.claude" ]; then AGENT_REPOS_FILE=$HOME/.agent-repos; else AGENT_REPOS_FILE=$(dirname "$CLAUDE_DIR")/.agent-repos; fi
fi
LINK="$CLAUDE_DIR/agent-terminal"
CL_LINK=${CL_LINK:-$HOME/.local/bin/cl}   # D73: the cl command
OLD_LINKS=("$CLAUDE_DIR/kaching" "$CLAUDE_DIR/ching")   # D65, D35: the link's names before the renames, kept as more links to this directory
AGENT_TERMINAL_APPS_DIR=${AGENT_TERMINAL_APPS_DIR:-${KACHING_APPS_DIR:-${CHING_APPS_DIR:-}}}

DRY=0; YES=0; POPUP=0; UNINSTALL=0; PREPUSH=""; DISPATCHER=0; MENUBAR=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --replace-popup) POPUP=1; shift ;;
    --uninstall) UNINSTALL=1; shift ;;
    --install-prepush) PREPUSH=${2:?--install-prepush needs a repo path}; shift 2 ;;
    --install-dispatcher) DISPATCHER=1; shift ;;
    --install-menubar) MENUBAR=1; shift ;;
    -h|--help) awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "install: unknown argument $1" >&2; exit 64 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "install: jq is required" >&2; exit 1; }

say() { printf '%s\n' "$*"; }
act() { if [ "$DRY" -eq 1 ]; then say "would: $*"; else say "did:   $*"; fi; }
would() { say "would: $*"; }
TMPD=""
tmpd() { if [ -z "$TMPD" ]; then TMPD=$(mktemp -d "${TMPDIR:-/tmp}/agent-terminal-install.XXXXXX"); trap 'rm -rf "$TMPD"' EXIT; fi; }
# values go into XML text: & < > in a path would otherwise break the plist (launchd then refuses to load it)
xml_esc() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
LAUNCH_AGENTS_DIR=${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
LAUNCHCTL=${LAUNCHCTL:-launchctl}
AH=${AGENT_HOME:-$HOME/.agent}
# the menu bar dot (ui/menubar): its app bundle and its launchd job
MB_APP="${AGENT_TERMINAL_APPS_DIR:-$HOME/Applications}/AgentTerminalBar.app"
MB_PLIST="$LAUNCH_AGENTS_DIR/org.agent-terminal.menubar.plist"
MB_ID=org.agent-terminal.menubar
# the dot before D65 (KachingBar) and before D35 (ChingBar): app name and bundle id / job label, one per line
OLD_MBS="KachingBar|org.kaching.menubar
ChingBar|org.ching.menubar"
old_mb_app() { printf '%s' "${AGENT_TERMINAL_APPS_DIR:-$HOME/Applications}/$1.app"; }
old_mb_plist() { printf '%s' "$LAUNCH_AGENTS_DIR/$1.plist"; }
old_mb_app_id() { /usr/bin/plutil -extract CFBundleIdentifier raw "$(old_mb_app "$1")/Contents/Info.plist" 2>/dev/null || true; }
OLD_MB_JOBS=""; OLD_MB_APPS_RM=""
old_mb_scan() { # fills OLD_MB_JOBS ("plist|label" lines) and OLD_MB_APPS_RM (paths) with the old dots that are installed
  OLD_MB_JOBS=""; OLD_MB_APPS_RM=""
  local n id
  while IFS='|' read -r n id; do
    [ -n "$n" ] || continue
    [ ! -f "$(old_mb_plist "$id")" ] || OLD_MB_JOBS="$OLD_MB_JOBS$(old_mb_plist "$id")|$id"$'\n'
    if [ -e "$(old_mb_app "$n")" ] && [ "$(old_mb_app_id "$n")" = "$id" ]; then OLD_MB_APPS_RM="$OLD_MB_APPS_RM$(old_mb_app "$n")"$'\n'; fi
  done <<<"$OLD_MBS"
}
old_mb_plan() {
  local plist id app
  while IFS='|' read -r plist id; do [ -z "$plist" ] || would "launchctl bootout $id and remove $plist (the dot before the rename)"; done <<<"$OLD_MB_JOBS"
  while IFS= read -r app; do [ -z "$app" ] || would "remove $app"; done <<<"$OLD_MB_APPS_RM"
}
old_mb_remove() {
  local plist id app
  while IFS='|' read -r plist id; do
    [ -n "$plist" ] || continue
    "$LAUNCHCTL" bootout "gui/$(id -u)/$id" >/dev/null 2>&1 || true
    rm -f "$plist"; act "removed $plist ($id, the dot before the rename)"
  done <<<"$OLD_MB_JOBS"
  while IFS= read -r app; do
    [ -z "$app" ] || { rm -rf "$app"; act "removed $app"; }
  done <<<"$OLD_MB_APPS_RM"
}
mb_app_id() { /usr/bin/plutil -extract CFBundleIdentifier raw "$MB_APP/Contents/Info.plist" 2>/dev/null || true; }

# ---------------- pre-push hook for one repo ----------------
if [ -n "$PREPUSH" ]; then
  git -C "$PREPUSH" rev-parse --git-dir >/dev/null 2>&1 || { echo "install: $PREPUSH is not a git repo" >&2; exit 1; }
  hooks_dir=$(git -C "$PREPUSH" rev-parse --git-path hooks)
  case "$hooks_dir" in /*) ;; *) hooks_dir="$(cd "$PREPUSH" && pwd -P)/$hooks_dir" ;; esac
  target="$hooks_dir/pre-push"
  rendered=$(sed "s#@AGENT_TERMINAL_BIN@#$LINK/bin#" "$AGENT_TERMINAL_ROOT/templates/pre-push")
  if [ -f "$target" ] && ! grep -q 'ching-prepush-marker' "$target"; then
    target="$hooks_dir/pre-push.agent-terminal"
    say "note: $hooks_dir/pre-push already exists and is not ours; writing pre-push.agent-terminal instead."
    say "      Chain it from your hook:  \"$target\" \"\$@\" || exit 1   (stdin must be passed through)"
  fi
  if [ -f "$target" ] && [ "$(cat "$target")" = "$rendered" ]; then say "pre-push hook already installed: $target"; exit 0; fi
  act "write $target"
  if [ "$DRY" -eq 0 ]; then mkdir -p "$hooks_dir"; printf '%s\n' "$rendered" >"$target"; chmod +x "$target"; fi
  exit 0
fi

phys() { # path -> its physical path (symlinked folders resolved); '' when its folder does not exist
  if [ -d "$1" ]; then (cd -P "$1" 2>/dev/null && pwd -P); return 0; fi
  local d; d=$(cd -P "$(dirname "$1")" 2>/dev/null && pwd -P) || return 0
  printf '%s/%s' "$d" "$(basename "$1")"
}
same_target() { # link target -> 0 when the link already leads to target, also when its text names the folder by an
  # older path that is now a symlink to it (~/bbq/ching after the move to ~/bbq/agent-terminal)
  local t; t=$(readlink "$1")
  [ "$t" = "$2" ] && return 0
  case "$t" in /*) ;; *) return 1 ;; esac
  [ -n "$(phys "$t")" ] && [ "$(phys "$t")" = "$(phys "$2")" ]
}
link_plan=""
relink_plan=""
plan_link() { # target link
  local target=$1 link=$2
  if [ -L "$link" ] && same_target "$link" "$target"; then return 0; fi
  if [ -e "$link" ] || [ -L "$link" ]; then
    say "warning: $link exists and is not our symlink; leaving it alone"; return 0
  fi
  link_plan="$link_plan$target|$link"$'\n'
}
plan_compat_link() { # target link: like plan_link, but a symlink of ours that leads elsewhere is pointed here again
  local target=$1 link=$2
  if [ -L "$link" ]; then
    same_target "$link" "$target" || relink_plan="$relink_plan$target|$link"$'\n'
    return 0
  fi
  plan_link "$target" "$link"
}

# ---------------- the voice dispatcher's own folder ----------------
if [ "$DISPATCHER" -eq 1 ]; then
  DDIR=${DISPATCHER_DIR:-$AH/dispatcher}
  VM=$(command -v voicemode 2>/dev/null || echo voicemode)
  render() { # template -> the template with its @placeholders@ filled in (jq: any character in a path is safe)
    jq --indent 2 --arg link "$LINK" --arg vm "$VM" \
      'walk(if type == "string" then gsub("@AGENT_TERMINAL@"; $link) | gsub("@VOICEMODE@"; $vm) else . end)' "$1"
  }
  tmpd
  gen_files="$DDIR/.claude/settings.json|$AGENT_TERMINAL_ROOT/dispatcher/settings.json
$DDIR/mcp.json|$AGENT_TERMINAL_ROOT/dispatcher/mcp.json"
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
  if ! { [ -L "$LINK" ] && same_target "$LINK" "$AGENT_TERMINAL_ROOT"; }; then
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

# ---------------- the menu bar dot (ui/menubar): AgentTerminalBar.app and its launchd job ----------------
if [ "$MENUBAR" -eq 1 ]; then
  [ "$UNINSTALL" -eq 0 ] || { echo "install: --uninstall removes the menu bar dot too; run it without --install-menubar" >&2; exit 64; }
  if [ -e "$MB_APP" ] && [ "$(mb_app_id)" != "$MB_ID" ]; then
    echo "install: $MB_APP exists and is not AgentTerminalBar ($MB_ID); leaving it alone" >&2; exit 1
  fi
  BUILD="$AGENT_TERMINAL_ROOT/ui/menubar/build.sh"
  if ! want_hash=$("$BUILD" --hash 2>&1); then echo "install: $want_hash" >&2; exit 1; fi
  have_hash=$(/usr/bin/plutil -extract AgentTerminalSourceHash raw "$MB_APP/Contents/Info.plist" 2>/dev/null || true)
  NEED_APP=0; [ "$have_hash" = "$want_hash" ] && [ -x "$MB_APP/Contents/MacOS/AgentTerminalBar" ] || NEED_APP=1
  X_EXE=$(xml_esc "$MB_APP/Contents/MacOS/AgentTerminalBar"); X_AH=$(xml_esc "$AH"); X_LINK=$(xml_esc "$LINK")
  MB_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$MB_ID</string>
  <key>ProgramArguments</key><array><string>$X_EXE</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>ProcessType</key><string>Interactive</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
    <key>AGENT_HOME</key><string>$X_AH</string>
    <key>AGENT_TERMINAL_DIR</key><string>$X_LINK</string>
  </dict>
  <key>StandardOutPath</key><string>$X_AH/menubar.log</string>
  <key>StandardErrorPath</key><string>$X_AH/menubar.log</string>
</dict>
</plist>
EOP
)
  NEED_MB_PLIST=0; [ -f "$MB_PLIST" ] && [ "$(cat "$MB_PLIST")" = "$MB_BODY" ] || NEED_MB_PLIST=1
  if ! { [ -L "$LINK" ] && same_target "$LINK" "$AGENT_TERMINAL_ROOT"; }; then
    say "warning: $LINK is not the kit's symlink yet. The dot reads dash.sh through it: run install.sh first."
  fi
  old_mb_scan
  if [ "$NEED_APP" -eq 0 ] && [ "$NEED_MB_PLIST" -eq 0 ] && [ -z "$OLD_MB_JOBS" ] && [ -z "$OLD_MB_APPS_RM" ]; then say "nothing to do"; exit 0; fi
  if [ "$NEED_APP" -eq 1 ]; then
    say "== app: $MB_APP"
    say "source hash ${want_hash}; installed: ${have_hash:-none}"
  fi
  if [ "$NEED_MB_PLIST" -eq 1 ]; then
    say "== launchd: $MB_PLIST"
    tmpd; printf '%s\n' "$MB_BODY" >"$TMPD/mb.new"
    if [ -f "$MB_PLIST" ]; then
      diff -u --label "$MB_PLIST (current)" --label "$MB_PLIST (after install)" "$MB_PLIST" "$TMPD/mb.new" || true
    else
      diff -u --label "$MB_PLIST (absent)" --label "$MB_PLIST (after install)" /dev/null "$TMPD/mb.new" || true
    fi
  fi
  mb_plan() {
    [ "$NEED_APP" -eq 0 ] || would "build $MB_APP (ui/menubar/build.sh)"
    if [ "$NEED_MB_PLIST" -eq 1 ]; then would "write $MB_PLIST and launchctl bootstrap it"
    else would "launchctl kickstart -k gui/$(id -u)/$MB_ID (restart the rebuilt app)"; fi
    old_mb_plan
  }
  if [ "$DRY" -eq 1 ]; then mb_plan; exit 0; fi
  if [ "$YES" -eq 0 ]; then
    mb_plan
    if [ -t 0 ]; then
      printf 'Apply these changes? [y/N] '; read -r ans
      case "$ans" in y|Y|yes) ;; *) say "aborted"; exit 1 ;; esac
    else
      echo "install: not a terminal; re-run with --yes to apply the changes shown above" >&2; exit 1
    fi
  fi
  if [ "$NEED_APP" -eq 1 ]; then
    "$BUILD" "$(dirname "$MB_APP")" --force >/dev/null || { echo "install: building $MB_APP failed" >&2; exit 1; }
    act "built $MB_APP"
  fi
  if [ "$NEED_MB_PLIST" -eq 1 ]; then
    mkdir -p "$LAUNCH_AGENTS_DIR" "$AH"
    printf '%s\n' "$MB_BODY" >"$MB_PLIST.tmp"; mv "$MB_PLIST.tmp" "$MB_PLIST"
    "$LAUNCHCTL" bootout "gui/$(id -u)/$MB_ID" >/dev/null 2>&1 || true
    if ! "$LAUNCHCTL" bootstrap "gui/$(id -u)" "$MB_PLIST"; then
      rm -f "$MB_PLIST"
      echo "install: launchctl bootstrap failed; removed $MB_PLIST so the next run retries" >&2
      exit 1
    fi
    act "loaded $MB_PLIST (the menu bar dot, at login)"
  else
    "$LAUNCHCTL" kickstart -k "gui/$(id -u)/$MB_ID" >/dev/null 2>&1 || true
    act "restarted $MB_ID"
  fi
  old_mb_remove
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
OLD_BINS_JSON=$(for l in "${OLD_LINKS[@]}"; do printf '%s\n' "$l/bin/"; done | jq -R . | jq -s -c .)
HOOKS_JSON=$(printf '%s\n' "$HOOKS" | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")
    | {event: .[0], matcher: .[1], command: .[2], timeout: (.[3] | tonumber)})')

if [ "$UNINSTALL" -eq 1 ]; then
  NEW=$(printf '%s' "$CURRENT" | jq --indent 2 '
    if .hooks then
      .hooks |= (with_entries(.value |= (map(.hooks |= map(select((.command // "") | (contains("/agent-terminal/bin/") or contains("/kaching/bin/") or contains("/ching/bin/")) | not)))
                                          | map(select((.hooks | length) > 0))))
                 | with_entries(select((.value | length) > 0)))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end')
else
  NEW=$(printf '%s' "$CURRENT" | jq --indent 2 --argjson add "$HOOKS_JSON" --argjson popup "$POPUP" --argjson voice "$VOICE_ALLOW" \
        --argjson olds "$OLD_BINS_JSON" '
    def has_cmd($g; $c): ([$g[]? | .hooks[]? | .command] | index($c)) != null;
    .hooks = (.hooks // {})
    # D35, D65: our entries under the old links make way for the same entries under the new one (no hook runs twice)
    | .hooks |= (with_entries(.value |= (map(.hooks |= map(select(((.command // "") as $c | any($olds[]; . as $p | $c | startswith($p))) | not)))
                                        | map(select((.hooks | length) > 0))))
                 | with_entries(select((.value | length) > 0)))
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
  plan_link "$AGENT_TERMINAL_ROOT" "$LINK"
  # an old link is kept leading here, never made on a machine that has not had it (a new install has none)
  for l in "${OLD_LINKS[@]}"; do if [ -L "$l" ] || [ -e "$l" ]; then plan_compat_link "$AGENT_TERMINAL_ROOT" "$l"; fi; done
  for c in "$AGENT_TERMINAL_ROOT"/commands/*.md; do
    [ -f "$c" ] || continue
    plan_link "$c" "$CLAUDE_DIR/commands/$(basename "$c")"
  done
  plan_link "$AGENT_TERMINAL_ROOT/bin/cl" "$CL_LINK"
fi
unlink_plan=""   # --uninstall: the cl link, only when it leads to this kit's bin/cl
if [ "$UNINSTALL" -eq 1 ] && [ -L "$CL_LINK" ] && same_target "$CL_LINK" "$AGENT_TERMINAL_ROOT/bin/cl"; then unlink_plan=$CL_LINK; fi
NEED_REPOS=0
if [ "$UNINSTALL" -eq 0 ] && [ ! -e "$AGENT_REPOS_FILE" ]; then NEED_REPOS=1; fi

# ---------------- launchd watcher (agent-terminal-watch.sh every 5 minutes) ----------------
PLIST="$LAUNCH_AGENTS_DIR/org.agent-terminal.watch.plist"
X_LINK=$(xml_esc "$LINK"); X_AH=$(xml_esc "$AH")
PLIST_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.agent-terminal.watch</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$X_LINK/bin/agent-terminal-watch.sh</string></array>
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
LPLIST="$LAUNCH_AGENTS_DIR/org.agent-terminal.learn.plist"
X_PATH=$(xml_esc "/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin")   # claude lives in ~/.local/bin
LPLIST_BODY=$(cat <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>org.agent-terminal.learn</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$X_LINK/bin/learn.sh</string></array>
  <key>StartCalendarInterval</key><dict><key>Hour</key><integer>5</integer><key>Minute</key><integer>30</integer></dict>
  <key>ProcessType</key><string>Background</string>
  <key>EnvironmentVariables</key><dict>
    <key>PATH</key><string>$X_PATH</string>
    <key>AGENT_HOME</key><string>$X_AH</string>
    <key>AGENT_TERMINAL_LEARNER</key><string>1</string>
    <key>CLAUDE_MEM_INTERNAL</key><string>1</string>
  </dict>
  <key>StandardOutPath</key><string>$X_AH/learn.log</string>
  <key>StandardErrorPath</key><string>$X_AH/learn.log</string>
</dict>
</plist>
EOP
)
NEED_LPLIST=0; if need_plist "$LPLIST" "$LPLIST_BODY"; then NEED_LPLIST=1; fi

# ---------------- the jobs under their names before D65 and D35: replaced by org.agent-terminal.* (install) or removed (uninstall) ----------------
OLD_JOBS=""   # "plist|label" lines for the old jobs whose plist exists
for _j in org.kaching.watch org.kaching.learn org.ching.watch org.ching.learn; do
  [ ! -f "$LAUNCH_AGENTS_DIR/$_j.plist" ] || OLD_JOBS="$OLD_JOBS$LAUNCH_AGENTS_DIR/$_j.plist|$_j"$'\n'
done

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

# ---------------- the menu bar dot: only --uninstall touches it here (--install-menubar is its own step above) ----------------
NEED_MB_RM=0; NEED_MB_APP_RM=0
old_mb_scan
if [ "$UNINSTALL" -eq 1 ]; then
  [ ! -f "$MB_PLIST" ] || NEED_MB_RM=1
  if [ -e "$MB_APP" ]; then
    if [ "$(mb_app_id)" = "$MB_ID" ]; then NEED_MB_APP_RM=1; else say "warning: $MB_APP is not AgentTerminalBar ($MB_ID); leaving it alone"; fi
  fi
else
  if [ -n "$OLD_MB_JOBS" ]; then
    say "note: the menu bar dot still runs under an old name ($(printf '%s' "$OLD_MB_JOBS" | cut -d'|' -f2 | tr '\n' ' ')). Run install.sh --install-menubar to replace it with AgentTerminalBar."
  fi
  OLD_MB_JOBS=""; OLD_MB_APPS_RM=""   # only --install-menubar and --uninstall remove an old dot
fi

if [ "$CHANGED" -eq 0 ] && [ -z "$link_plan" ] && [ -z "$relink_plan" ] && [ -z "$unlink_plan" ] && [ "$NEED_REPOS" -eq 0 ] && [ "$NEED_PLIST" -eq 0 ] \
   && [ "$NEED_LPLIST" -eq 0 ] && [ "$CM_CHANGED" -eq 0 ] && [ "$NEED_MB_RM" -eq 0 ] && [ "$NEED_MB_APP_RM" -eq 0 ] \
   && [ -z "$OLD_JOBS" ] && [ -z "$OLD_MB_JOBS" ] && [ -z "$OLD_MB_APPS_RM" ]; then
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
[ "$NEED_MB_RM" -eq 0 ] || show_plist_diff "$MB_PLIST" ""
show_old_plist() { # the job under its pre-D65 or pre-D35 name, which this run removes
  say "== launchd: $1 (the name before the rename)"
  diff -u --label "$1 (current)" --label "$1 (removed)" "$1" /dev/null || true
}
while IFS='|' read -r _p _; do [ -z "$_p" ] || show_old_plist "$_p"; done <<<"$OLD_JOBS$OLD_MB_JOBS"
if [ "$CM_CHANGED" -eq 1 ]; then
  say "== claude-mem: $CM_FILE"
  tmpd
  printf '%s\n' "$cm_cur" >"$TMPD/cm.before"; printf '%s\n' "$CM_NEW" >"$TMPD/cm.after"
  diff -u --label "$CM_FILE (current)" --label "$CM_FILE (after install)" "$TMPD/cm.before" "$TMPD/cm.after" || true
fi
plan_lines() { # everything this run would do, whether or not settings.json changes
  while IFS='|' read -r t l; do [ -z "$l" ] || would "symlink $l -> $t"; done <<<"$link_plan"
  while IFS='|' read -r t l; do [ -z "$l" ] || would "point $l at $t (it led elsewhere)"; done <<<"$relink_plan"
  [ -z "$unlink_plan" ] || would "remove the symlink $unlink_plan"
  [ "$NEED_REPOS" -eq 0 ] || would "create $AGENT_REPOS_FILE (empty, optional)"
  [ "$CHANGED" -eq 0 ] || would "back up and rewrite $SETTINGS_FILE"
  [ "$NEED_PLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "launchctl bootout and remove $PLIST"; else would "write $PLIST and launchctl bootstrap it"; fi; }
  [ "$NEED_LPLIST" -eq 0 ] || { if [ "$UNINSTALL" -eq 1 ]; then would "launchctl bootout and remove $LPLIST"; else would "write $LPLIST and launchctl bootstrap it"; fi; }
  [ "$NEED_MB_RM" -eq 0 ] || would "launchctl bootout and remove $MB_PLIST"
  [ "$NEED_MB_APP_RM" -eq 0 ] || would "remove $MB_APP"
  while IFS='|' read -r _p _l; do [ -z "$_p" ] || would "launchctl bootout $_l and remove $_p"; done <<<"$OLD_JOBS"
  old_mb_plan
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
    BACKUP="$SETTINGS_FILE.bak.agent-terminal.$(date +%Y%m%d-%H%M%S)"
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
while IFS='|' read -r t l; do
  [ -n "$l" ] || continue
  ln -s "$t" "$l.new.$$" && perl -e 'rename($ARGV[0], $ARGV[1]) or die "$!\n"' "$l.new.$$" "$l" \
    || { rm -f "$l.new.$$"; echo "install: could not point $l at $t" >&2; exit 1; }
  act "pointed $l at $t"
done <<<"$relink_plan"
if [ -n "$unlink_plan" ]; then rm -f "$unlink_plan"; act "removed the symlink $unlink_plan"; fi
if [ "$NEED_REPOS" -eq 1 ]; then
  cp "$AGENT_TERMINAL_ROOT/templates/agent-repos.example" "$AGENT_REPOS_FILE.tmp"
  sed -i.bak 's/^~/# ~/' "$AGENT_REPOS_FILE.tmp"; rm -f "$AGENT_REPOS_FILE.tmp.bak"
  mv "$AGENT_REPOS_FILE.tmp" "$AGENT_REPOS_FILE"; act "create $AGENT_REPOS_FILE"
fi
if [ "$CM_CHANGED" -eq 1 ]; then
  CM_BACKUP="$CM_FILE.bak.agent-terminal.$(date +%Y%m%d-%H%M%S)"
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
[ "$NEED_PLIST" -eq 0 ] || apply_plist "$PLIST" "$PLIST_BODY" org.agent-terminal.watch "agent-terminal-watch every 5 minutes"
[ "$NEED_LPLIST" -eq 0 ] || apply_plist "$LPLIST" "$LPLIST_BODY" org.agent-terminal.learn "learn.sh every day at 05:30"
[ "$NEED_MB_RM" -eq 0 ] || apply_plist "$MB_PLIST" "" "$MB_ID" "the menu bar dot"
if [ "$NEED_MB_APP_RM" -eq 1 ]; then rm -rf "$MB_APP"; act "removed $MB_APP"; fi
# the pre-D65 and pre-D35 jobs go only after their replacements loaded (a failed bootstrap above exits first)
remove_old_job() { # plist label
  "$LAUNCHCTL" bootout "gui/$(id -u)/$2" >/dev/null 2>&1 || true
  rm -f "$1"; act "removed $1 ($2, the name before the rename)"
}
while IFS='|' read -r _p _l; do [ -z "$_p" ] || remove_old_job "$_p" "$_l"; done <<<"$OLD_JOBS"
old_mb_remove
if [ "$UNINSTALL" -eq 1 ]; then say "note: --uninstall removes hook entries, the watcher, the learner job and the menu bar dot and ~/.local/bin/cl; other symlinks, a removed popup and the converse entries in permissions.allow (they may predate the install) are left as they are."; fi
exit 0
