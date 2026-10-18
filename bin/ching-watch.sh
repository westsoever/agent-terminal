#!/usr/bin/env bash
# ching-watch.sh: the old name of kaching-watch.sh (D35). The org.ching.watch launchd job calls it until
# install.sh replaces that job with org.kaching.watch.
set -euo pipefail
exec /bin/bash "$(dirname "${BASH_SOURCE[0]}")/kaching-watch.sh" "$@"
