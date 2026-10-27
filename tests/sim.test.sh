#!/usr/bin/env bash
# Tests for bin/af-sim device creation with a stubbed xcrun: default device
# type, and the runtime choice (newest available iOS runtime that supports the
# device type, whatever order simctl lists them in).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

dt() { printf '{"name":"%s","identifier":"com.apple.CoreSimulator.SimDeviceType.%s"}' "$1" "${1// /-}"; }
rt() {  # rt <version> <device names...>
  local v="$1" types="" d; shift
  for d in "$@"; do types="$types${types:+,}$(dt "$d")"; done
  printf '{"platform":"iOS","version":"%s","isAvailable":true,"identifier":"com.apple.CoreSimulator.SimRuntime.iOS-%s","supportedDeviceTypes":[%s]}' \
    "$v" "${v//./-}" "$types"
}

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
  : > "$tmp/calls"; : > "$tmp/local/machine.env"
  # Listed out of order on purpose: 27.0, 26.10, 26.4; "iPhone 11" only in 26.x.
  echo "{\"runtimes\":[$(rt 27.0 "iPhone 17" "iPhone 16"),$(rt 26.10 "iPhone 17" "iPhone 16" "iPhone 11"),$(rt 26.4 "iPhone 16" "iPhone 11")]}" > "$tmp/runtimes.json"
  cat > "$tmp/bin/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$tmp/calls"
case "\$*" in
  "simctl list devices -j") echo '{"devices":{}}' ;;
  "simctl list runtimes -j") cat "$tmp/runtimes.json" ;;
  "simctl create "*) echo "UDID-1" ;;
esac
EOF
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

af() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" "$@" >"$tmp/out" 2>&1 || echo "af exited $?" >> "$tmp/out"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
called() { grep -qF -- "$1" "$tmp/calls"; }

setup; af sim run -- true
check "default device is iPhone 17"            called "simctl create af-sim-0 iPhone 17 "
check "newest runtime that supports it (27.0)" called "iPhone 17 com.apple.CoreSimulator.SimRuntime.iOS-27-0"
check "simulator shut down afterwards"         called "simctl shutdown UDID-1"
rm -rf "$tmp"

setup; af sim run --device "iPhone 11" -- true
check "device only in 26.x -> 26.10, not 26.4" called "iPhone 11 com.apple.CoreSimulator.SimRuntime.iOS-26-10"
rm -rf "$tmp"

setup; af sim run --device "iPhone 99" -- true
check "unsupported device -> clear error"      grep -q 'No available iOS runtime supports' "$tmp/out"
check "unsupported device -> nothing created"  bash -c "! grep -q 'simctl create' '$tmp/calls'"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
