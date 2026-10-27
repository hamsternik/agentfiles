#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# launchd services: health check, cleanup, and project jobs.
require_macos
agents_dir="$HOME/Library/LaunchAgents"
export AF_LOGS AF_ROOT

load_agent() {
  local label="$1" tmpl="$2" dst="$agents_dir/$1.plist"
  AF_LABEL="$label" render_template "$tmpl" "$dst"
  run launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  run launchctl bootstrap "gui/$(id -u)" "$dst"
  ok "loaded $label"
}

AF_LABEL=""
export AF_LABEL
load_agent local.agentfiles.health  "$AF_ROOT/services/launchd/health.plist.tmpl"
load_agent local.agentfiles.cleanup "$AF_ROOT/services/launchd/cleanup.plist.tmpl"

if [[ -f "$AF_LOCAL/projects.yaml" ]]; then
  run "$AF_ROOT/bin/af" projects sync
  run "$AF_ROOT/bin/af" projects install-jobs
fi
