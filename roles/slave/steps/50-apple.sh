#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Xcode (pinned), license, first launch, simulator runtimes.
require_macos
ver="$(grep -v '^[[:space:]]*#' "$AF_ROOT/apple/xcode-version" | head -1 | tr -d '[:space:]')"

# A full Xcode is selected (xcodebuild fails with only the Command Line Tools)
# and matches the pin. Not a glob on /Applications: Xcode*.app also matches Xcodes.app.
xcode_version() { xcodebuild -version 2>/dev/null | awk 'NR == 1 {print $2}' || true; }
have_xcode="$(xcode_version)"
if [[ -n "$have_xcode" && ( "$ver" == latest || "$have_xcode" == "$ver" ) ]]; then
  ok "Xcode present: Xcode $have_xcode"
elif [[ -t 0 ]]; then
  log "Installing Xcode ($ver) with xcodes (asks for an Apple Developer sign-in)"
  if [[ "$ver" == latest ]]; then run xcodes install --latest --select --experimental-unxip
  else run xcodes install "$ver" --select --experimental-unxip; fi
else
  manual "Install Xcode: xcodes install ${ver/latest/--latest} --select --experimental-unxip  (Apple Developer sign-in + 2FA). Without an Apple ID here: copy the .xip from another Mac and add --path <file.xip> (needs a version, not --latest)."
  exit 0
fi

run sudo xcodebuild -license accept
run sudo xcodebuild -runFirstLaunch
# No debugger auth prompts over SSH.
if DevToolsSecurity -status 2>/dev/null | grep -q 'currently enabled'; then
  ok "Developer mode on"
else
  run sudo DevToolsSecurity -enable >/dev/null
fi

# Each platform needs a runtime that matches the SDK of the selected Xcode;
# any older runtime does not count. arm64 only (smaller; default on Apple silicon).
sdk_for() {
  case "$1" in
    iOS) echo iphonesimulator ;; watchOS) echo watchsimulator ;;
    tvOS) echo appletvsimulator ;; visionOS) echo xrsimulator ;;
  esac
}
runtimes="$(xcrun simctl list runtimes -j 2>/dev/null || echo '{"runtimes":[]}')"
while read -r platform; do
  [[ -z "$platform" || "$platform" == \#* ]] && continue
  sdk="$(xcrun --sdk "$(sdk_for "$platform")" --show-sdk-version 2>/dev/null || true)"
  if [[ -n "$sdk" ]] && jq -e --arg p "$platform" --arg v "$sdk" \
       '.runtimes[] | select(.platform == $p and .isAvailable and (.version | startswith($v)))' \
       >/dev/null <<<"$runtimes"; then
    ok "$platform $sdk runtime present"
  else
    log "Downloading the $platform ${sdk:-latest} simulator runtime"
    run xcodebuild -downloadPlatform "$platform" -architectureVariant arm64
  fi
done < "$AF_ROOT/apple/runtimes.txt"

run xcrun simctl delete unavailable
