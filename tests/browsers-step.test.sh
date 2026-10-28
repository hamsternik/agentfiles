#!/usr/bin/env bash
# Tests for roles/slave/steps/60-browsers.sh: no host-level Playwright or
# Chrome for Testing (no Homebrew package; projects install their own browsers),
# only the dedicated Chrome profile folders and the Claude in Chrome step.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/60-browsers.sh"
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
: > "$tmp/calls"; : > "$tmp/local/machine.env"
for c in npx node; do printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$c" "$tmp" > "$tmp/bin/$c"; done
chmod +x "$tmp/bin/"*

HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" AF_ROOT="$repo" \
  AF_HOME="$tmp/home/.agentfiles" AF_LOCAL="$tmp/local" AF_DRY_RUN=0 \
  /bin/bash "$step" >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/out" "$tmp/calls"; fails=$((fails + 1)); fi
}
check "finishes"                         bash -c "! grep -q 'step exited' '$tmp/out'"
check "no npx (Playwright / CfT) calls"  bash -c "! grep -q '^npx' '$tmp/calls'"
check "us profile folder"                [ -d "$tmp/home/.agentfiles/chrome-profiles/us" ]
check "agent profile folder"             [ -d "$tmp/home/.agentfiles/chrome-profiles/agent" ]
check "Claude in Chrome manual step"     grep -q 'Claude in Chrome' "$tmp/home/.agentfiles/state/manual-steps.md"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
