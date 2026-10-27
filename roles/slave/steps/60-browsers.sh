#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Browsers: Playwright's Chromium, pinned Chrome for Testing, Chrome profiles.
have npx || die_or_warn "node missing; run step 20 first"

log "Playwright Chromium (shared cache)"
run npx -y playwright@latest install chromium

log "Chrome for Testing -> $AF_HOME/browsers"
run mkdir -p "$AF_HOME/browsers"
run npx -y @puppeteer/browsers install chrome@stable --path "$AF_HOME/browsers"

# Dedicated profiles; never your personal Google profile.
#   us    -> all traffic via the US gateway
#   agent -> Claude in Chrome profile for agent-driven browsing
run mkdir -p "$AF_HOME/chrome-profiles/us" "$AF_HOME/chrome-profiles/agent"
manual "Open 'af browser agent' once (Screen Sharing), install Claude in Chrome there and sign in."
