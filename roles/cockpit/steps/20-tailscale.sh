#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Tailscale app on the cockpit. A system-wide VPN (e.g. the Mullvad app) can
# conflict with it; see docs/PLAN.md "US traffic" for the gateway alternative.
if tailscale status >/dev/null 2>&1 || /Applications/Tailscale.app/Contents/MacOS/Tailscale status >/dev/null 2>&1; then
  ok "Tailscale running"
else
  run open -a Tailscale || true
  manual "Sign in to Tailscale on this Mac (same tailnet as the host)."
fi
