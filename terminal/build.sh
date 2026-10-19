#!/bin/bash
# build.sh: build the agent terminal and install it as ~/.local/bin/agterm (or $1).
# D64: the command was called kaching. A kaching left in the same folder (the owner's old install, which Raycast scripts
# and the menu bar dot may still start) becomes a link to the new binary, so those keep working.
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-$HOME/.local/bin/agterm}
mkdir -p "$(dirname "$OUT")"
go build -o "$OUT" .
echo "built $OUT"
OLD="$(dirname "$OUT")/kaching"
if [ "$(basename "$OUT")" = agterm ] && { [ -e "$OLD" ] || [ -L "$OLD" ]; }; then
  ln -sfn agterm "$OLD"
  echo "linked $OLD -> agterm (the old name)"
fi
