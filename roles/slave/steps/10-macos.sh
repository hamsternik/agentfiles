#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# macOS settings for an always-on, unattended machine.
require_macos

log "Machine name -> $AF_HOSTNAME"
# It is also the LocalHostName (name.local), so it must be a DNS label.
[[ "$AF_HOSTNAME" =~ ^[A-Za-z0-9-]{1,63}$ ]] \
  || die "AF_HOSTNAME '$AF_HOSTNAME' must be 1-63 letters, digits or hyphens"
for key in ComputerName HostName LocalHostName; do
  if [[ "$(scutil --get "$key" 2>/dev/null)" == "$AF_HOSTNAME" ]]; then
    ok "$key already $AF_HOSTNAME"
  else
    run sudo scutil --set "$key" "$AF_HOSTNAME"
  fi
done

# Power settings live in 15-power.sh.

log "Updates: check and download automatically, never install macOS or apps on their own"
su=/Library/Preferences/com.apple.SoftwareUpdate
run sudo defaults write "$su" AutomaticCheckEnabled -bool true
run sudo defaults write "$su" AutomaticDownload -bool true
run sudo defaults write "$su" AutomaticallyInstallMacOSUpdates -bool false
run sudo defaults write "$su" AutomaticallyInstallAppUpdates -bool false
# Security responses and system data files (XProtect etc.) stay automatic.
run sudo defaults write "$su" CriticalUpdateInstall -bool true
run sudo defaults write "$su" ConfigDataInstall -bool true
run sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

log "Remote Login (sshd)"
if service_on com.openssh.sshd 22; then
  ok "Remote Login on"
else
  run sudo launchctl enable system/com.openssh.sshd
  run sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist || true
  if [[ "$AF_DRY_RUN" != 1 ]] && ! service_on com.openssh.sshd 22; then
    manual "Turn on System Settings > General > Sharing > Remote Login."
  fi
  manual "Turn Remote Login on in System Settings > General > Sharing once, even if SSH works: the FileVault SSH unlock after a restart depends on that setting."
fi

# Screen Sharing cannot be enabled from the CLI (kickstart lost that in macOS 12.1).
if service_on com.apple.screensharing 5900; then
  ok "Screen Sharing on"
else
  manual "Turn on System Settings > General > Sharing > Screen Sharing (not Remote Management); allow access only for $USER. Needed for simulators and permission prompts."
fi

if fdesetup status 2>/dev/null | grep -q 'FileVault is On'; then
  log "FileVault on: after a restart, unlock over SSH from the same LAN (Tailscale starts only after the unlock). See docs/runbook.md."
fi
if [[ "${AF_LID_CLOSED:-0}" == 1 ]]; then
  log "Lid closed: step 15 keeps the Mac awake; Screen Sharing needs a display (HDMI cable or dummy plug). See docs/runbook.md."
fi

manual "AlDente: cap charging at 80% and start it at login (battery health on an always-plugged laptop)."
manual "Spotlight: add your worktrees dir and ~/Library/Developer/Xcode/DerivedData to System Settings > Spotlight > Search Privacy."
