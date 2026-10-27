#!/usr/bin/env bash
# Tests for roles/slave/steps/70-containers.sh with stubbed docker, orb, open,
# sudo and uname. Docker answers once `orb start` (or `open -a`) has run.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/70-containers.sh"
fails=0

setup() {  # setup up|down
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  : > "$tmp/calls"
  echo "AF_US_GATEWAY_ENABLED=0" > "$tmp/local/machine.env"
  [[ "$1" == up ]] && touch "$tmp/running"
  cat > "$tmp/bin/docker" <<EOF
#!/bin/bash
echo "docker \$*" >> "$tmp/calls"
[[ -f "$tmp/running" ]]
EOF
  cat > "$tmp/bin/orb" <<EOF
#!/bin/bash
echo "orb \$*" >> "$tmp/calls"
[[ "\$1" == start ]] && touch "$tmp/running"
true
EOF
  cat > "$tmp/bin/open" <<EOF
#!/bin/bash
echo "open \$*" >> "$tmp/calls"; touch "$tmp/running"
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

setup down; run_step
check "limit lives in config/limits.env"       grep -q '^AF_ORB_MEMORY_MIB=' "$repo/config/limits.env"
check "step has no literal memory value"       bash -c "! grep -q 'AF_ORB_MEMORY_MIB:-' '$step'"
check "down: finishes"                         finished
check "down: started headless with orb start"  called "orb start"
check "down: GUI not opened"                   not_called "open -a OrbStack"
check "down: memory cap from limits.env"       called "orb config set memory_mib $(sed -n 's/^AF_ORB_MEMORY_MIB=\([0-9]*\).*/\1/p' "$repo/config/limits.env")"
rm -rf "$tmp"

setup up; echo "AF_ORB_MEMORY_MIB=2048" > "$tmp/local/limits.env"; run_step
check "up: not started again"                  not_called "orb start"
check "up: local override of the cap"          called "orb config set memory_mib 2048"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
