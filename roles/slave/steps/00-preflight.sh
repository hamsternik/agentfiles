#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Preflight: right OS, Xcode Command Line Tools, sudo available.
require_macos
[[ "$(uname -m)" == "arm64" ]] || warn "Not Apple Silicon; limits in config/ assume an M-series Mac."

if ! xcode-select -p >/dev/null 2>&1; then
  run xcode-select --install || true
  die_or_warn "Install the Xcode Command Line Tools (dialog opened), then re-run."
else
  ok "Command Line Tools present"
fi

log "Asking for sudo once (power, sharing and service settings need it)"
run sudo -v
