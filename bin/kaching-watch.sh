#!/usr/bin/env bash
# kaching-watch.sh: the old name of agent-terminal-watch.sh (D65). The org.kaching.watch launchd job calls it until
# install.sh replaces that job with org.agent-terminal.watch.
set -euo pipefail
exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/agent-terminal-watch.sh" "$@"
