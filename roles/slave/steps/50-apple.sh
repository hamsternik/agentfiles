#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Xcode (pinned), license, first launch, simulator runtimes.
require_macos
ver="$(grep -v '^[[:space:]]*#' "$AF_ROOT/apple/xcode-version" | head -1 | tr -d '[:space:]')"

if ls -d /Applications/Xcode*.app >/dev/null 2>&1; then
  ok "Xcode present: $(xcodebuild -version 2>/dev/null | head -1)"
elif [[ -t 0 ]]; then
  log "Installing Xcode ($ver) with xcodes (asks for Apple ID)"
  if [[ "$ver" == "latest" ]]; then run xcodes install --latest --select
  else run xcodes install "$ver" --select; fi
else
  manual "Install Xcode: xcodes install ${ver/latest/--latest} --select  (needs an Apple ID sign-in)"
  exit 0
fi

run sudo xcodebuild -license accept
run sudo xcodebuild -runFirstLaunch
run sudo DevToolsSecurity -enable >/dev/null   # no debugger auth prompts over SSH

installed="$(xcrun simctl list runtimes 2>/dev/null || true)"
while read -r platform; do
  [[ -z "$platform" || "$platform" == \#* ]] && continue
  if grep -q "^$platform " <<<"$installed"; then
    ok "$platform runtime present"
  else
    log "Downloading $platform simulator runtime"
    run xcodebuild -downloadPlatform "$platform"
  fi
done < "$AF_ROOT/apple/runtimes.txt"

run xcrun simctl delete unavailable
