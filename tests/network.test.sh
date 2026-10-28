#!/usr/bin/env bash
# Tests for roles/slave/steps/30-tailscale.sh, Mullvad part: when the Mullvad
# app is installed (bridge until the gluetun gateway works), local network
# sharing must be allowed, or the slave blocks SSH, Screen Sharing and the
# FileVault SSH unlock on the LAN. Stubbed mullvad, pgrep, tailscale, sudo.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/30-tailscale.sh"
fails=0

setup() {  # setup <mullvad lan policy: allow|block|none> [set fails: yes]
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  : > "$tmp/calls"
  printf 'AF_HOSTNAME="box"\n' > "$tmp/local/machine.env"
  if [[ "$1" != none ]]; then
    echo "$1" > "$tmp/lan"
    cat > "$tmp/bin/mullvad" <<EOF
#!/bin/bash
echo "mullvad \$*" >> "$tmp/calls"
case "\$*" in
  "lan get") echo "Local network sharing setting: \$(cat "$tmp/lan")" ;;
  "lan set "*) [[ "${2:-}" == yes ]] && exit 1; echo "\$3" > "$tmp/lan" ;;
esac
EOF
  fi
  printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/pgrep"
  printf '#!/bin/bash\necho "tailscale $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/tailscale"
  cat > "$tmp/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
EOF
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

run_step() {
  HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" AF_ROOT="$repo" \
    AF_HOME="$tmp/home/.agentfiles" AF_LOCAL="$tmp/local" AF_DRY_RUN=0 \
    /bin/bash "$step" </dev/null >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "${tmp:-/nonexistent}/out" "${tmp:-/nonexistent}/calls" 2>/dev/null || true; fails=$((fails + 1)); fi
}
called()     { grep -qF -- "$1" "$tmp/calls"; }
not_called() { [[ -f "$tmp/calls" ]] && ! grep -qF -- "$1" "$tmp/calls"; }
finished()   { ! grep -q 'step exited' "$tmp/out"; }
manual_has() { grep -qF -- "$1" "$tmp/home/.agentfiles/state/manual-steps.md" 2>/dev/null; }

check "slave Brewfile has the mullvad-vpn cask"  grep -qE '^cask "mullvad-vpn"' "$repo/roles/slave/Brewfile"

setup block; run_step
check "block: finishes"                          finished
check "block: local network sharing allowed"     called "mullvad lan set allow"
check "block: before tailscale"                  bash -c "[ \$(grep -n 'mullvad lan set' '$tmp/calls' | cut -d: -f1) -lt \$(grep -n '^tailscale' '$tmp/calls' | head -1 | cut -d: -f1) ]"
rm -rf "$tmp"

setup allow; run_step
check "allow: left alone"                        not_called "mullvad lan set"
rm -rf "$tmp"

setup none; run_step
check "no Mullvad app: finishes"                 finished
check "no Mullvad app: nothing to do"            not_called "mullvad"
rm -rf "$tmp"

setup block yes; run_step
check "set fails: step goes on"                  finished
check "set fails: manual step"                   manual_has "Local network sharing"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
