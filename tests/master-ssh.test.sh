#!/usr/bin/env bash
# Tests for roles/master/steps/30-ssh.sh with a temp HOME: the SSH alias file
# is included through ~/.ssh/config.local when ~/.ssh/config (owned by the
# dotfiles) already includes that file, so the dotfiles copy is never edited.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/master/steps/30-ssh.sh"
fails=0

setup() {  # setup <first line of ~/.ssh/config; @TMP@ = the new temp dir>
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home/.ssh"
  printf '%s\n\nHost github.com\n  User git\n' "${1//@TMP@/$tmp}" > "$tmp/home/.ssh/config"
  printf 'AF_HOST_TAILNET="box"\nAF_HOST_USER="agent"\n' > "$tmp/local/machine.env"
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/uname"
  before="$(shasum "$tmp/home/.ssh/config")"
}

run_step() {
  HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" AF_ROOT="$repo" \
    AF_HOME="$tmp/home/.agentfiles" AF_LOCAL="$tmp/local" AF_DRY_RUN=0 \
    /bin/bash "$step" >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); fi
}
includes()      { [[ "$(grep -cxF "Include $tmp/home/.agentfiles/ssh_config" "$tmp/home/.ssh/config.local" 2>/dev/null)" == "$1" ]]; }
config_same()   { [[ "$(shasum "$tmp/home/.ssh/config")" == "$before" ]]; }
manual_has()    { grep -qF -- "$1" "$tmp/home/.agentfiles/state/manual-steps.md" 2>/dev/null; }
manual_lacks()  { ! manual_has "$1"; }
local_private() { [[ "$(stat -f %Lp "$tmp/home/.ssh/config.local")" == 600 ]]; }

setup 'Include ~/.ssh/config.local'; run_step
check "dotfiles include: alias file written"     grep -q '^Host agent box' "$tmp/home/.agentfiles/ssh_config"
check "dotfiles include: added to config.local"  includes 1
check "dotfiles include: config.local is 600"    local_private
check "dotfiles include: ~/.ssh/config untouched" config_same
check "dotfiles include: no manual Include step" manual_lacks "Include"
run_step
check "re-run: not added twice"                  includes 1
rm -rf "$tmp"

setup 'Host *'; run_step
check "no config.local include: manual step"     manual_has "Include $tmp/home/.agentfiles/ssh_config"
check "no config.local include: no new file"     [ ! -e "$tmp/home/.ssh/config.local" ]
check "no config.local include: config untouched" config_same
rm -rf "$tmp"

setup 'Include @TMP@/home/.agentfiles/ssh_config'; run_step
check "already in ~/.ssh/config: nothing to do"  manual_lacks "Include"
check "already in ~/.ssh/config: no config.local" [ ! -e "$tmp/home/.ssh/config.local" ]
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
