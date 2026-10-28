#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Mullvad app (bridge until the gluetun gateway works): with local network
# sharing blocked, it cuts SSH, Screen Sharing and the FileVault SSH unlock on
# the LAN. Allow it before anything else here.
if have mullvad; then
  if mullvad lan get 2>/dev/null | grep -q ': allow$'; then
    ok "Mullvad: local network sharing allowed"
  else
    run mullvad lan set allow \
      || manual "Mullvad app > Settings > VPN settings: turn on Local network sharing (else the LAN cannot reach this Mac)."
  fi
fi

# Tailscale as a system daemon (formula), so it is up before anyone logs in.
# Checked without sudo: the daemon runs as root, so look for the process.
if ! pgrep -qx tailscaled; then
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
