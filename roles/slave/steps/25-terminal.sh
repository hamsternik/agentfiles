#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Terminal environment first: your dotfiles, terminal tools and login shell,
# right after Homebrew and before the long steps, so every later session
# (yours over SSH / Screen Sharing, or an agent's in tmux) already has them.
require_macos

if [[ -z "${DOTFILES_REPO:-}" ]]; then
  warn "DOTFILES_REPO empty in local/machine.env; skipping the terminal environment."
  exit 0
fi

log "dotfiles -> $DOTFILES_DIR"
if [[ -d "$DOTFILES_DIR/.git" ]]; then
  run git -C "$DOTFILES_DIR" pull --ff-only || warn "dotfiles pull failed; using what is checked out"
else
  run git clone --recurse-submodules "$DOTFILES_REPO" "$DOTFILES_DIR"
fi

# Terminal tools come from the dotfiles repo, so every machine gets the same list.
brewfile="$DOTFILES_DIR/Brewfile.terminal"
if [[ -f "$brewfile" ]]; then
  run brew bundle --no-upgrade --file "$brewfile"
elif [[ "$AF_DRY_RUN" == 1 && ! -d "$DOTFILES_DIR" ]]; then
  log "[dry-run] would install $brewfile after the clone"
else
  die_or_warn "No Brewfile.terminal in $DOTFILES_DIR. Add one (terminal tools only, no casks) to the dotfiles repo."
fi

# Folders the dotfiles make targets expect to exist.
run mkdir -p "$HOME/.config/fish/functions" "$HOME/.config/fish/conf.d" "$HOME/.vim"
[[ -d "$HOME/.ssh" ]] || run mkdir -m 700 "$HOME/.ssh"

if [[ -n "${DOTFILES_TARGETS:-}" ]]; then
  # shellcheck disable=SC2086  # targets are a space-separated list
  run make -C "$DOTFILES_DIR" $DOTFILES_TARGETS
fi
[[ "$AF_DRY_RUN" == 1 ]] || ok "dotfiles applied"

# Login shell, e.g. fish like on the master. It must be listed in /etc/shells.
if [[ -n "${AF_LOGIN_SHELL:-}" ]]; then
  shells_file="${AF_SHELLS_FILE:-/etc/shells}"
  shell_path="$(command -v "$AF_LOGIN_SHELL" || true)"
  if [[ -z "$shell_path" && "$AF_DRY_RUN" == 1 ]]; then
    prefix="$(brew --prefix 2>/dev/null || true)"
    shell_path="${prefix:-/opt/homebrew}/bin/$AF_LOGIN_SHELL"
  fi
  [[ -n "$shell_path" ]] || die_or_warn "$AF_LOGIN_SHELL is not installed; add it to Brewfile.terminal"
  if [[ -n "$shell_path" ]]; then
    grep -qx "$shell_path" "$shells_file" \
      || run sudo sh -c "printf '%s\n' '$shell_path' >> '$shells_file'"
    current="$(dscl . -read "/Users/$USER" UserShell 2>/dev/null | awk '{print $2}')"
    if [[ "$current" == "$shell_path" ]]; then
      ok "login shell already $shell_path"
    else
      run sudo chsh -s "$shell_path" "$USER"
    fi
  fi
fi
