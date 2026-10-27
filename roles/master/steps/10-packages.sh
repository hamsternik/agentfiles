#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

require_macos
[[ -n "${AF_HOST_TAILNET:-}" ]] || die "Set AF_HOST_TAILNET in local/machine.env"
have brew || die "Install Homebrew first (your dotfiles README covers it)"
run brew bundle --file "$AF_ROOT/Brewfile"
run brew bundle --file "$AF_ROOT/roles/master/Brewfile"
