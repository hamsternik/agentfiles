#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Xcode (pinned in config/versions.env), license, first launch, simulator runtimes.
require_macos
want="$AF_XCODE_VERSION"; build="$AF_XCODE_BUILD"

xcodes_ver="$(xcodes version 2>/dev/null | head -1 || true)"
if [[ -n "$xcodes_ver" ]] && ! version_ge "$xcodes_ver" "$AF_XCODES_MIN_VERSION"; then
  manual "xcodes $xcodes_ver is older than $AF_XCODES_MIN_VERSION and cannot sign in to Apple: brew upgrade xcodes, then af versions --record."
fi

# The selected Xcode's build (xcodebuild fails with only the Command Line Tools).
# Not a glob on /Applications: Xcode*.app also matches Xcodes.app.
selected_build() { xcodebuild -version 2>/dev/null | awk '/^Build version/ {print $3}' || true; }
if [[ "$(selected_build)" == "$build" ]]; then
  ok "Xcode $want ($build) selected"
elif xcodes installed 2>/dev/null | grep -q "^$want ($build)"; then
  run xcodes select "$want"
elif [[ -t 0 ]]; then
  log "Installing Xcode $want ($build) with xcodes (asks for an Apple Developer sign-in)"
  run xcodes install "$want" --select --experimental-unxip
else
  manual "Install Xcode $want ($build): xcodes install $want --select --experimental-unxip  (Apple Developer sign-in + 2FA). Without an Apple ID here: copy the .xip from another Mac and add --path <file.xip>."
  exit 0
fi
if [[ "$AF_DRY_RUN" != 1 && "$(selected_build)" != "$build" ]]; then
  die_or_warn "Selected Xcode build is '$(selected_build)', not $build. Check config/versions.env and 'xcodes installed'."
fi

run sudo xcodebuild -license accept
run sudo xcodebuild -runFirstLaunch
# No debugger auth prompts over SSH.
if DevToolsSecurity -status 2>/dev/null | grep -q 'currently enabled'; then
  ok "Developer mode on"
else
  run sudo DevToolsSecurity -enable >/dev/null
fi

# Simulator runtimes pinned by build in apple/runtimes.txt ("<platform> <build>").
# xcodes installs an exact build; xcodebuild (arm64, the platform's current
# runtime) is the fallback, so the build is checked again afterwards.
have_runtime() {  # have_runtime <build>: Ready in `simctl runtime list -j`
  xcrun simctl runtime list -j 2>/dev/null \
    | jq -e --arg b "$1" 'to_entries[] | select(.value.build == $b and .value.state == "Ready")' >/dev/null
}
while read -r platform rt_build _; do
  [[ -z "$platform" || "$platform" == \#* ]] && continue
  if [[ -z "$rt_build" || "$rt_build" == \#* ]]; then
    die_or_warn "apple/runtimes.txt: '$platform' has no build; write '<platform> <build>'"
    continue
  fi
  if have_runtime "$rt_build"; then
    ok "$platform runtime $rt_build present"
    continue
  fi
  log "Installing the $platform simulator runtime $rt_build"
  run xcodes runtimes install "$rt_build" \
    || run xcodebuild -downloadPlatform "$platform" -architectureVariant arm64
  if [[ "$AF_DRY_RUN" != 1 ]] && ! have_runtime "$rt_build"; then
    warn "$platform runtime $rt_build still missing (the fallback installs the current one); af versions will report it"
  fi
done < "$AF_ROOT/apple/runtimes.txt"

run xcrun simctl delete unavailable
