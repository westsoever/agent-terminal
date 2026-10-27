#!/usr/bin/env bash
# disk-map.sh (CLEAN): finds the candidates in a fake home, sizes them, and writes the report the page reads.
# shellcheck source=lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
R="$WORK/root"; O="$WORK/out"
big() { mkdir -p "$1" && dd if=/dev/zero of="$1/f" bs=1048576 count="$2" 2>/dev/null; }
big "$R/.npm/_cacache" 12
big "$R/code/web/.next" 11
big "$R/.ollama/models" 60
big "$R/old/node_modules" 15
big "$R/new/node_modules" 15
big "$R/.cache/uv" 2                       # under 10 MB: not listed
touch -t 202001010000 "$R/old" "$R/old/node_modules" "$R/old/node_modules/f"
touch "$R/new/package.json"                 # changed today: its node_modules stays out
out=$(DISK_MAP_ROOT="$R" DISK_MAP_DIR="$O" "$BIN/disk-map.sh" 2>&1)
J="$O/report.json"
assert_eq "diskmap: report written" "1" "$(jq -e .items "$J" >/dev/null 2>&1 && echo 1 || echo 0)"
assert_eq "diskmap: npm cache is safe" "safe" "$(jq -r '.items[] | select(.label == "npm cache") | .safety' "$J")"
assert_eq "diskmap: npm cache uses npm's own clean" "npm cache clean --force" "$(jq -r '.items[] | select(.label == "npm cache") | .cmd' "$J")"
assert_eq "diskmap: .next found two levels down" "$R/code/web/.next" "$(jq -r '.items[] | select(.label | startswith("Next")) | .paths[0]' "$J")"
assert_eq "diskmap: ollama needs review" "review" "$(jq -r '.items[] | select(.label == "Ollama models") | .safety' "$J")"
assert_eq "diskmap: idle node_modules only" "$R/old/node_modules" "$(jq -r '.items[] | select(.id == "nm") | .paths | join(",")' "$J")"
assert_eq "diskmap: small caches left out" "" "$(jq -r '.items[] | select(.label == "uv cache") | .label' "$J")"
assert_eq "diskmap: safe items first" "safe" "$(jq -r '.items[0].safety' "$J")"
assert_eq "diskmap: tree holds the 50 MB folder" "1" "$(jq --arg p "$R/.ollama/models" '[.tree[] | select(.path == $p)] | length' "$J")"
assert_contains "diskmap: page and data side by side" "$(ls "$O")" "report.js"
assert_contains "diskmap: page copied" "$(ls "$O")" "report.html"
assert_contains "diskmap: prints the page" "$out" "$O/report.html"
exit 0
