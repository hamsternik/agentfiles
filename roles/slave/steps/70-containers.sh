#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# OrbStack + the US egress gateway.
require_macos
if ! docker info >/dev/null 2>&1; then
  # `orb start` works headless (over SSH); the app is the fallback.
  run orb start || run open -a OrbStack
  if [[ "$AF_DRY_RUN" != 1 ]]; then
    for _ in $(seq 1 30); do docker info >/dev/null 2>&1 && break; sleep 2; done
  fi
fi
if docker info >/dev/null 2>&1; then ok "OrbStack running"
else die_or_warn "Docker (OrbStack) not responding"; fi

# Cap the Linux VM so containers cannot starve Xcode and simulators.
run orb config set memory_mib "$AF_ORB_MEMORY_MIB" \
  || manual "Set the OrbStack memory limit to $AF_ORB_MEMORY_MIB MiB in its settings."
manual "OrbStack: open the app once (Screen Sharing) to finish setup and approve the admin prompt, then Settings > enable 'Start at login'."

if [[ "${AF_US_GATEWAY_ENABLED:-0}" == 1 && "$AF_DRY_RUN" == 1 ]]; then
  log "[dry-run] would check the Keychain for us-gateway secrets, then run 'af gateway up'"
elif [[ "${AF_US_GATEWAY_ENABLED:-0}" == 1 ]]; then
  if "$AF_ROOT/bin/af" secret has us-gateway/wireguard-private-key; then
    run "$AF_ROOT/bin/af" gateway up
  else
    manual "Store gateway secrets, then run 'af gateway up':  af secret set us-gateway/wireguard-private-key;  af secret set us-gateway/wireguard-addresses"
  fi
fi
