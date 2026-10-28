#!/usr/bin/env bash
# Tests for roles/slave/steps/25-terminal.sh with stubbed git, brew, make, sudo,
# dscl, chsh and a fake fish. /etc/shells is a temp copy (AF_SHELLS_FILE).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/25-terminal.sh"
fails=0

setup() {  # setup <has Brewfile.terminal yes|no> <current login shell> [AF_LOGIN_SHELL value]
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  : > "$tmp/calls"
  printf '/bin/bash\n/bin/zsh\n' > "$tmp/shells"
  echo "$2" > "$tmp/usershell"
  cat > "$tmp/local/machine.env" <<EOF
DOTFILES_REPO="https://example.invalid/dotfiles.git"
DOTFILES_DIR="$tmp/home/.dotfiles"
DOTFILES_TARGETS="install-git-conf install-fish-conf"
AF_LOGIN_SHELL=${3-fish}
EOF
  cat > "$tmp/bin/git" <<EOF
#!/bin/bash
echo "git \$*" >> "$tmp/calls"
if [[ "\$1" == clone ]]; then
  d="\${@: -1}"; mkdir -p "\$d/.git"
  [[ "$1" == yes ]] && touch "\$d/Brewfile.terminal"
fi
true
EOF
  # brew bundle "installs" fish, so the shell appears only after the bundle.
  cat > "$tmp/bin/brew" <<EOF
#!/bin/bash
echo "brew \$*" >> "$tmp/calls"
case "\$1" in
  --prefix) echo /opt/homebrew ;;
  bundle) printf '#!/bin/bash\n' > "$tmp/bin/fish"; chmod +x "$tmp/bin/fish" ;;
esac
EOF
  cat > "$tmp/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
EOF
  cat > "$tmp/bin/dscl" <<EOF
#!/bin/bash
echo "UserShell: \$(cat "$tmp/usershell")"
EOF
  cat > "$tmp/bin/chsh" <<EOF
#!/bin/bash
echo "chsh \$*" >> "$tmp/calls"; echo "\$2" > "$tmp/usershell"
EOF
  printf '#!/bin/bash\necho "make $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/make"
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

run_step() {
  HOME="$tmp/home" USER=agent PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" AF_ROOT="$repo" \
    AF_HOME="$tmp/home/.agentfiles" AF_LOCAL="$tmp/local" AF_DRY_RUN=0 AF_SHELLS_FILE="$tmp/shells" \
    /bin/bash "$step" >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
called()     { grep -qF -- "$1" "$tmp/calls"; }
not_called() { [[ -f "$tmp/calls" ]] && ! grep -qF -- "$1" "$tmp/calls"; }
finished()   { ! grep -q 'step exited' "$tmp/out"; }
fish_dirs()  { [[ -d "$tmp/home/.config/fish/functions" && -d "$tmp/home/.config/fish/conf.d" ]]; }
ssh_mode()   { [[ -d "$tmp/home/.ssh" && "$(stat -f %Lp "$tmp/home/.ssh")" == 700 ]]; }

setup yes /bin/zsh; run_step
check "fresh: finishes"                         finished
check "fresh: clones the dotfiles"              called "git clone --recurse-submodules https://example.invalid/dotfiles.git $tmp/home/.dotfiles"
check "fresh: installs Brewfile.terminal"       called "brew bundle --no-upgrade --file $tmp/home/.dotfiles/Brewfile.terminal"
check "fresh: runs the make targets"            called "make -C $tmp/home/.dotfiles install-git-conf install-fish-conf"
check "fresh: fish folders exist"               fish_dirs
check "fresh: ~/.vim exists"                    [ -d "$tmp/home/.vim" ]
check "fresh: ~/.ssh exists, mode 700"          ssh_mode
check "fresh: fish added to /etc/shells"        grep -qx "$tmp/bin/fish" "$tmp/shells"
check "fresh: login shell set to fish"          called "chsh -s $tmp/bin/fish agent"
rm -rf "$tmp"

setup yes /bin/zsh; run_step; : > "$tmp/calls"; run_step
check "re-run: finishes"                        finished
check "re-run: pulls instead of cloning"        called "git -C $tmp/home/.dotfiles pull --ff-only"
check "re-run: no second clone"                 not_called "git clone"
check "re-run: /etc/shells not appended again"  [ "$(grep -cx "$tmp/bin/fish" "$tmp/shells")" = 1 ]
check "re-run: login shell left alone"          not_called "chsh"
rm -rf "$tmp"

setup no /bin/zsh; run_step
check "no Brewfile.terminal: step stops"        bash -c "grep -q 'step exited' '$tmp/out'"
check "no Brewfile.terminal: says what to add"  grep -q 'Brewfile.terminal' "$tmp/out"
rm -rf "$tmp"

setup yes /bin/zsh ""; run_step
check "no AF_LOGIN_SHELL: shell left alone"     not_called "chsh"
rm -rf "$tmp"

setup yes /bin/zsh; echo 'DOTFILES_REPO=""' >> "$tmp/local/machine.env"; run_step
check "no DOTFILES_REPO: finishes"              finished
check "no DOTFILES_REPO: nothing cloned"        not_called "git"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
