#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# macOS settings for an always-on, unattended machine.
require_macos

log "Machine name -> $AF_HOSTNAME"
run sudo scutil --set ComputerName "$AF_HOSTNAME"
run sudo scutil --set HostName "$AF_HOSTNAME"
run sudo scutil --set LocalHostName "$AF_HOSTNAME"

# Power settings live in 15-power.sh.

log "Updates: download automatically, never install/reboot on their own"
run sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool true
run sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false
run sudo defaults write /Library/Preferences/com.apple.commerce AutoUpdate -bool false

log "Remote Login (sshd)"
if sudo systemsetup -getremotelogin 2>/dev/null | grep -q 'On'; then
  ok "Remote Login already on"
else
  run sudo systemsetup -setremotelogin on \
    || manual "Turn on System Settings > General > Sharing > Remote Login (the terminal may need Full Disk Access to do it from CLI)."
fi

# Things macOS does not let a script do reliably, or that are a judgement call.
manual "Turn on System Settings > General > Sharing > Screen Sharing (for simulators and permission prompts)."
manual "Decide FileVault vs. unattended reboot: with FileVault on, the Mac waits at the unlock screen after a restart. See docs/runbook.md."
manual "AlDente: cap charging at 80% and start it at login (battery health on an always-plugged laptop)."
manual "Spotlight: add your worktrees dir and ~/Library/Developer/Xcode/DerivedData to System Settings > Spotlight > Search Privacy."
manual "Lid: keep it open, or use a dummy HDMI plug if you want it closed (clamshell needs a display)."
