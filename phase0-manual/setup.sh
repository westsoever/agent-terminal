#!/bin/bash
# Idempotent. Recreates the throwaway sandbox used by the manual Phase 0 steps. Touches only /tmp/agent-sandbox.
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
S=/tmp/agent-sandbox
mkdir -p $S/hooks $S/logs $S/repo/.claude
cp "$HERE/log-client.sh" $S/hooks/log-client.sh && chmod +x $S/hooks/log-client.sh
cp "$HERE/settings-sessionstart-log.json" $S/repo/.claude/settings.json
cd $S/repo
[ -d .git ] || { git init -q && echo hi > a.txt && git add a.txt && git commit -qm init; }
: > $S/logs/clients.log
rm -f $S/ping.txt
echo "sandbox ready: $S/repo   log: $S/logs/clients.log"
