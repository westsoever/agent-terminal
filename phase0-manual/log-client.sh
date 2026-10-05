#!/bin/bash
# Logs hook event + which client ran it. Only whitelisted env vars (never dump env: it contains tokens).
in=$(cat)
echo "$(date +%T) event=$1 entrypoint=${CLAUDE_CODE_ENTRYPOINT:-?} term_program=${TERM_PROGRAM:-?} vscode=${VSCODE_PID:+yes} payload=$(echo "$in" | jq -c '{session_id,hook_event_name,source,notification_type,cwd}')" >> /tmp/agent-sandbox/logs/clients.log
