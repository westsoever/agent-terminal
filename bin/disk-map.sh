#!/usr/bin/env bash
# disk-map.sh: maps where the home folder's disk space goes and which caches, models and build output could go,
# for CLEAN. Writes report.json (for the agent) and report.html (a treemap with a cleanup script builder) to
# ~/.agent/disk-map/. It only reads: removing things is the cleanup agent's job, with the owner's yes.
#   disk-map.sh [--open]    --open shows report.html in the browser when the scan is done
# DISK_MAP_ROOT (default $HOME) and DISK_MAP_DIR (default ~/.agent/disk-map) are for tests.
set -euo pipefail
root="${DISK_MAP_ROOT:-$HOME}"
out="${DISK_MAP_DIR:-$HOME/.agent/disk-map}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The tree: every folder down to 3 levels that holds 50 MB or more. -x stays on this disk (no iCloud, no volumes).
du -x -k -d 3 "$root" 2>/dev/null | awk -F'\t' '$1 >= 51200' >"$tmp/du" || true  # du exits 1 on folders it may not read

# The candidates: safety, label, the paths (globs under $root), the command that removes them ("" means rm -rf).
# safe: a cache or build output that is made again when it is needed. review: costs a download or holds work.
cat >"$tmp/rules" <<'EOF'
safe	npm cache	.npm/_cacache	npm cache clean --force
safe	Yarn cache	Library/Caches/Yarn	yarn cache clean
safe	pnpm store	Library/pnpm/store	pnpm store prune
safe	Bun cache	.bun/install/cache	bun pm cache rm
safe	Homebrew downloads	Library/Caches/Homebrew	brew cleanup --prune=all
safe	pip cache	Library/Caches/pip .cache/pip	pip cache purge
safe	uv cache	.cache/uv	uv cache clean
safe	Puppeteer & Playwright browsers	.cache/puppeteer Library/Caches/ms-playwright
safe	Gradle caches	.gradle/caches
safe	Xcode DerivedData	Library/Developer/Xcode/DerivedData
safe	Next.js & Turbo build output	*/*/.next */*/.turbo */*/*/.next */*/*/.turbo
safe	Trash	.Trash
review	Go module cache	go/pkg/mod	go clean -modcache
review	Cargo registry	.cargo/registry
review	Hugging Face models	.cache/huggingface
review	Ollama models	.ollama/models	ollama rm <model>  # ollama list shows them
review	LM Studio models	.lmstudio/models .cache/lm-studio/models
review	Android SDK & emulators	Library/Android .android/avd
review	iOS simulators	Library/Developer/CoreSimulator/Devices	xcrun simctl delete unavailable
review	iOS device support	Library/Developer/Xcode/iOS?DeviceSupport
review	Docker data	Library/Containers/com.docker.docker	docker system prune -a
review	Claude Code worktrees	*/.claude/worktrees */*/.claude/worktrees */*/*/.claude/worktrees	git worktree remove <path>  # live sessions may use them
review	Downloads	Downloads
EOF

cd "$root" || exit 1
shopt -s nullglob
n=0
while IFS=$'\t' read -r safety label globs cmd; do
  paths=()
  for g in $globs; do paths+=( $g ); done  # unquoted on purpose: the globs expand here
  ((${#paths[@]})) || continue
  kb=0; list=()
  for p in "${paths[@]}"; do
    [ -d "$p" ] || continue
    s=$(du -x -s -k "$p" 2>/dev/null | cut -f1 || true); s=${s:-0}
    ((s >= 10240)) || continue  # under 10 MB is not worth a line
    kb=$((kb + s)); list+=("$root/$p")
  done
  ((kb)) || continue
  n=$((n + 1))
  printf '%s\0' "${list[@]}" | jq -Rs --arg id "r$n" --arg s "$safety" --arg l "$label" --arg c "$cmd" --argjson kb "$kb" \
    '{id: $id, safety: $s, label: $l, kb: $kb, cmd: $c, paths: (split("\u0000") | map(select(. != "")))}' >>"$tmp/items"
done <"$tmp/rules"

# node_modules in projects nothing in has changed for 30 days: npm install brings them back.
find -x "$root" -maxdepth 6 \( -path "$root/Library" -o -name .Trash -o -name .git \) -prune -o \
  -type d -name node_modules -prune -print 2>/dev/null | while IFS= read -r nm; do
  p="${nm%/node_modules}"
  [ -z "$(find "$p" -maxdepth 1 ! -name node_modules -mtime -30 -print -quit 2>/dev/null)" ] || continue
  printf '%s\t%s\n' "$(du -x -s -k "$nm" 2>/dev/null | cut -f1)" "$nm"
done | awk -F'\t' '$1 >= 10240' >"$tmp/nm" || true
if [ -s "$tmp/nm" ]; then
  jq -Rs '{id: "nm", safety: "review", label: "node_modules in idle projects", cmd: "",
    kb: (split("\n") | map(select(. != "") | split("\t")[0] | tonumber) | add),
    paths: (split("\n") | map(select(. != "") | split("\t")[1]))}' "$tmp/nm" >>"$tmp/items"
fi
touch "$tmp/items"

# df -k /: the disk as a whole, so the page can show what the scan did not reach (system, apps, other users).
read -r total used free < <(df -k "$root" | awk 'NR == 2 {print $2, $3, $4}')

jq -n --arg root "$root" --arg at "$(date '+%Y-%m-%d %H:%M')" \
  --argjson total "$total" --argjson used "$used" --argjson free "$free" \
  --rawfile du "$tmp/du" --slurpfile items "$tmp/items" '
  {generated: $at, root: $root, disk: {total_kb: $total, used_kb: $used, free_kb: $free},
   tree: ($du | split("\n") | map(select(. != "") | split("\t") | {kb: (.[0] | tonumber), path: .[1]})),
   items: ($items | sort_by(.safety != "safe", -.kb))}' >"$out/report.json" || exit 1

{ printf 'window.REPORT = '; cat "$out/report.json"; printf ';\n'; } >"$out/report.js"
cp "$here/templates/disk-map.html" "$out/report.html"

jq -r '"\(.items | length) candidates · safe \(([.items[] | select(.safety == "safe") | .kb] | add // 0) / 1048576 * 10 | floor / 10) GB · review \(([.items[] | select(.safety == "review") | .kb] | add // 0) / 1048576 * 10 | floor / 10) GB"' "$out/report.json"
echo "$out/report.html"
[ "${1:-}" = "--open" ] && open "$out/report.html"
exit 0
