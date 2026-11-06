#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Copy desktop sessions between seats: the sync-sessions-to-seat skill and `af sessions`.
install_session_sync
