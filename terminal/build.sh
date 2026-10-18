#!/bin/bash
# build.sh: build the agent terminal and install it as ~/.local/bin/kaching (or $1).
set -euo pipefail
cd "$(dirname "$0")"
OUT=${1:-$HOME/.local/bin/kaching}
mkdir -p "$(dirname "$OUT")"
go build -o "$OUT" .
echo "built $OUT"
