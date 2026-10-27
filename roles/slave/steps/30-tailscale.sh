#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Tailscale as a system daemon (formula), so it is up before anyone logs in.
if ! sudo brew services list 2>/dev/null | grep -Eq '^tailscale[[:space:]]+started'; then
  run sudo brew services start tailscale
fi

if tailscale status >/dev/null 2>&1; then
  ok "Tailscale up: $(tailscale status --self --json 2>/dev/null | jq -r '.Self.DNSName // "?"')"
elif [[ -t 0 ]]; then
  log "Logging this machine into your tailnet (opens a URL)"
  run sudo tailscale up --hostname="$AF_HOSTNAME"
else
  manual "Run: sudo tailscale up --hostname=$AF_HOSTNAME   (then approve the device in the Tailscale admin)"
fi
manual "In the Tailscale admin console: disable key expiry for this machine, and restrict access with ACLs to your own devices."
