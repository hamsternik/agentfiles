#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Homebrew + the host Brewfile.
if ! have brew; then
  log "Installing Homebrew"
  run /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  eval "$(/opt/homebrew/bin/brew shellenv)"
fi
run brew update
run brew bundle --file "$AF_ROOT/Brewfile"
run brew bundle --file "$AF_ROOT/roles/slave/Brewfile"
ok "Brewfile applied"
