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
# --no-upgrade: install what is missing, never move installed versions.
# Upgrades are deliberate: brew upgrade <name>, then af versions --record.
adopt_casks "$AF_ROOT/Brewfile" "$AF_ROOT/roles/slave/Brewfile"
run brew bundle --no-upgrade --file "$AF_ROOT/Brewfile"
run brew bundle --no-upgrade --file "$AF_ROOT/roles/slave/Brewfile"
ok "Brewfile applied"

# node@NN is keg-only (not on PATH); link it unless `node` already is that major.
node_formula="$(grep -oE 'brew "node@[0-9]+"' "$AF_ROOT/roles/slave/Brewfile" | grep -oE 'node@[0-9]+' || true)"
if [[ -n "$node_formula" ]]; then
  if [[ "$(node --version 2>/dev/null)" == "v${node_formula#node@}."* ]]; then
    ok "node is $node_formula"
  else
    run brew link --overwrite --force "$node_formula"
  fi
fi
