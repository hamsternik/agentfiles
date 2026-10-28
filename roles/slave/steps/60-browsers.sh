#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Browsers: dedicated Chrome profiles (Google Chrome comes from the Brewfile).
# No host-level Playwright or Chrome for Testing: neither has a Homebrew
# package, and each project installs the browsers of its own Playwright
# version in its agent.setup (docs/plans/PLAN-session-2.md).

# Dedicated profiles; never your personal Google profile.
#   us    -> all traffic via the US gateway
#   agent -> Claude in Chrome profile for agent-driven browsing
run mkdir -p "$AF_HOME/chrome-profiles/us" "$AF_HOME/chrome-profiles/agent"
manual "Open 'af browser agent' once (Screen Sharing), install Claude in Chrome there and sign in."
