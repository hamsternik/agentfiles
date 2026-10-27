#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Homebrew + the host Brewfile.
if ! have brew; then
  log "Installing Homebrew"
  # Single quotes: the installer is downloaded when the command runs, not in a dry-run.
  # shellcheck disable=SC2016
  run /bin/bash -c '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
  [[ "$AF_DRY_RUN" == 1 ]] || eval "$(/opt/homebrew/bin/brew shellenv)"
fi
run brew update
run brew bundle --file "$AF_ROOT/Brewfile"
run brew bundle --file "$AF_ROOT/roles/slave/Brewfile"
ok "Brewfile applied"
