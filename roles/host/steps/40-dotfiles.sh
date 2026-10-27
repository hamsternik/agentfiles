#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Delegate shell/editor/git config to your personal dotfiles repo, if configured.
if [[ -z "${DOTFILES_REPO:-}" ]]; then
  warn "DOTFILES_REPO empty in local/machine.env; skipping."
  exit 0
fi
if [[ ! -d "$DOTFILES_DIR/.git" ]]; then
  run git clone --recurse-submodules "$DOTFILES_REPO" "$DOTFILES_DIR"
else
  run git -C "$DOTFILES_DIR" pull --ff-only || warn "dotfiles pull failed; using what is checked out"
fi
if [[ -n "${DOTFILES_TARGETS:-}" ]]; then
  # shellcheck disable=SC2086  # targets are a space-separated list
  run make -C "$DOTFILES_DIR" $DOTFILES_TARGETS
fi
ok "dotfiles applied"
