#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# A "us" Chrome profile on the cockpit that exits via the host's US gateway,
# so this laptop no longer needs a system-wide VPN.
run mkdir -p "$AF_HOME/chrome-profiles/us"
ok "Use 'af browser us' to open US stores through the host gateway."
