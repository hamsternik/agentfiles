#!/usr/bin/env bash
# Tests for bin/af-browser with a stubbed `open`: the "us" profile goes through
# the proxy and blocks local DNS resolution (prefetch leaks), except for the
# proxy host itself; other profiles use the normal network.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {  # setup [machine.env lines...]
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
  : > "$tmp/calls"; : > "$tmp/local/machine.env"
  local l; for l in "$@"; do echo "$l" >> "$tmp/local/machine.env"; done
  cat > "$tmp/bin/open" <<EOF
#!/bin/bash
for a in "\$@"; do echo "\$a"; done >> "$tmp/calls"
EOF
  chmod +x "$tmp/bin/open"
}

browser() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" browser "$@" >"$tmp/out" 2>&1 || echo "af exited $?" >> "$tmp/out"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- open args:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
arg()    { grep -qxF -- "$1" "$tmp/calls"; }
no_arg() { ! grep -qF -- "$1" "$tmp/calls"; }

setup 'AF_US_PROXY_URL="http://box:8888"'; browser us https://example.com
check "us: own profile dir"                    arg "--user-data-dir=$tmp/af/chrome-profiles/us"
check "us: via the proxy"                      arg "--proxy-server=http://box:8888"
check "us: no local DNS except the proxy host" arg "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE box"
check "us: opens the URL"                      arg "https://example.com"
rm -rf "$tmp"

setup; browser us
check "us default: local proxy"                arg "--proxy-server=http://127.0.0.1:8888"
check "us default: excludes 127.0.0.1"         arg "--host-resolver-rules=MAP * ~NOTFOUND , EXCLUDE 127.0.0.1"
rm -rf "$tmp"

setup; browser agent
check "agent: no proxy"                        no_arg "--proxy-server"
check "agent: no resolver rules"               no_arg "--host-resolver-rules"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
