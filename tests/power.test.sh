#!/usr/bin/env bash
# Tests for roles/slave/steps/15-power.sh with stubbed sudo/pmset/systemsetup/uname.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/15-power.sh"
fails=0

# One sandbox per case: stub bin/, fake AF_HOME and local/, a call log.
setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  echo "${1:-0}" > "$tmp/sleepdisabled"
  cat > "$tmp/bin/sudo" <<STUB
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
STUB
  cat > "$tmp/bin/pmset" <<STUB
#!/bin/bash
echo "pmset \$*" >> "$tmp/calls"
if [[ "\$*" == "-g cap" ]]; then
  printf 'Capabilities for AC Power:\n displaysleep\n sleep\n womp\n'
  [[ -f "$tmp/cap_autorestart" ]] && printf ' autorestart\n'
  true
elif [[ "\$1" == -g ]]; then
  printf 'System-wide power settings:\n SleepDisabled\t\t%s\nCurrently in use:\n sleep                0\n' "\$(cat "$tmp/sleepdisabled")"
elif [[ "\$*" == *disablesleep* ]]; then
  echo "\${@: -1}" > "$tmp/sleepdisabled"
fi
STUB
  cat > "$tmp/bin/systemsetup" <<STUB
#!/bin/bash
echo "systemsetup \$*" >> "$tmp/calls"
STUB
  cat > "$tmp/bin/uname" <<'STUB'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
STUB
  chmod +x "$tmp/bin/"*
  : > "$tmp/calls"
}

run_step() {  # run_step <AF_LID_CLOSED> [dry-run]
  echo "AF_LID_CLOSED=$1" > "$tmp/local/machine.env"
  PATH="$tmp/bin:$PATH" AF_ROOT="$repo" AF_HOME="$tmp/home" AF_LOCAL="$tmp/local" \
    AF_DRY_RUN="${2:-0}" /bin/bash "$step" >"$tmp/out" 2>&1 || echo "step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/calls" "$tmp/out"; fails=$((fails + 1)); fi
}
called()     { grep -qF -- "$1" "$tmp/calls"; }
not_called() { [[ -f "$tmp/calls" ]] && ! grep -qF -- "$1" "$tmp/calls"; }

setup 0; run_step 1
check "lid closed: disables sleep"            called "sudo pmset -a disablesleep 1"
check "lid closed: never sleeps on AC"        called "sudo pmset -c sleep 0"
check "lid closed: state is applied"          grep -qx 1 "$tmp/sleepdisabled"
check "laptop: no autorestart (not supported)" not_called "pmset -a autorestart"
check "no systemsetup (restartfreeze is a no-op)" not_called "systemsetup"
rm -rf "$tmp"

setup 0; touch "$tmp/cap_autorestart"; run_step 1
check "desktop: autorestart when supported"   called "sudo pmset -a autorestart 1"
rm -rf "$tmp"

setup 1; run_step 1
check "already disabled: no second change"    not_called "pmset -a disablesleep"
rm -rf "$tmp"

setup 1; run_step 0
check "lid open: re-enables sleep"            called "sudo pmset -a disablesleep 0"
rm -rf "$tmp"

setup 0; run_step 1 1
check "dry-run: no sudo at all"               not_called "sudo"
check "dry-run: state untouched"              grep -qx 0 "$tmp/sleepdisabled"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
