#!/usr/bin/env bash
# Tests for `af gateway test` with a stubbed curl: the exit must be in the US
# for any VPN provider; with Mullvad it must also be a Mullvad exit.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {  # setup <provider> <trace loc> <mullvad_exit_ip true|false>
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
  : > "$tmp/calls"
  echo "AF_US_GATEWAY_PROVIDER=\"$1\"" > "$tmp/local/machine.env"
  cat > "$tmp/bin/curl" <<EOF
#!/bin/bash
echo "curl \$*" >> "$tmp/calls"
case "\$*" in
  *cdn-cgi/trace*) printf 'fl=1\nip=203.0.113.7\nloc=$2\nwarp=off\n' ;;
  *am.i.mullvad.net*) printf '{"ip":"203.0.113.7","country":"USA","city":"New York","mullvad_exit_ip":$3}\n' ;;
  *) exit 6 ;;
esac
EOF
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

gw_test() {  # prints the exit code of `af gateway test`
  local r=0
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" gateway test >"$tmp/out" 2>&1 || r=$?
  echo "$r"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}

image="$(sed -n 's/^ *image: *//p' "$repo/services/us-gateway/compose.yaml")"
setup mullvad US true
check "gluetun pinned by tag and digest"       grep -qE '^qmcgaw/gluetun:v[0-9.]+@sha256:[0-9a-f]{64}$' <<<"$image"
check "mullvad, US exit: passes"               [ "$(gw_test)" = 0 ]
check "mullvad: also checks the Mullvad exit"  grep -q 'am.i.mullvad.net' "$tmp/calls"
check "goes through the local proxy"           grep -q -- '-x http://127.0.0.1:' "$tmp/calls"
rm -rf "$tmp"

setup protonvpn US false
check "other provider, US exit: passes"        [ "$(gw_test)" = 0 ]
check "other provider: no Mullvad check"       bash -c "! grep -q 'am.i.mullvad.net' '$tmp/calls'"
rm -rf "$tmp"

setup protonvpn DE false
check "exit outside the US: fails"             [ "$(gw_test)" != 0 ]
rm -rf "$tmp"

setup mullvad US false
check "mullvad, not a Mullvad exit: fails"     [ "$(gw_test)" != 0 ]
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
