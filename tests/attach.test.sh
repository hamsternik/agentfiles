#!/usr/bin/env bash
# Tests for bin/af-attach with stubbed mosh, ssh and open. A non-interactive
# SSH command on the slave has no Homebrew on PATH, so tmux and mosh-server
# must be called by absolute path.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {  # setup mosh|nomosh [machine.env lines...]
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
  : > "$tmp/calls"
  local with="$1"; shift
  printf 'AF_HOST_TAILNET="box"\n' > "$tmp/local/machine.env"
  local l; for l in "$@"; do echo "$l" >> "$tmp/local/machine.env"; done
  local c; for c in ssh open $([[ "$with" == mosh ]] && echo mosh); do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$c" "$tmp" > "$tmp/bin/$c"
  done
  chmod +x "$tmp/bin/"*
}

attach() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" attach "$@" >"$tmp/out" 2>&1 || echo "af exited $?" >> "$tmp/out"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
called() { grep -qF -- "$1" "$tmp/calls"; }

setup mosh; attach
check "mosh: absolute mosh-server"             called "mosh --server=/opt/homebrew/bin/mosh-server agent -- "
check "mosh: absolute tmux, session main"      called "/opt/homebrew/bin/tmux new -A -s main"
rm -rf "$tmp"

setup nomosh; attach work
check "ssh: absolute tmux, own session"        called "ssh -t agent /opt/homebrew/bin/tmux new -A -s work"
rm -rf "$tmp"

setup mosh 'AF_HOST_BREW_PREFIX="/usr/local"'; attach
check "custom prefix (Intel or own layout)"    called "mosh --server=/usr/local/bin/mosh-server agent -- /usr/local/bin/tmux"
rm -rf "$tmp"

setup nomosh; attach --screen
check "--screen opens Screen Sharing"          called "open vnc://box"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
