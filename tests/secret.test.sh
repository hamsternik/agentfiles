#!/usr/bin/env bash
# Tests for `af secret get|has` with a stubbed `security`: a Keychain read that
# hangs (reported over SSH on recent macOS) must time out with a hint instead of
# blocking `af gateway up` or the health agent.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {  # setup fast|hang
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
  : > "$tmp/local/machine.env"
  echo "AF_KEYCHAIN_TIMEOUT_SECONDS=2" > "$tmp/local/limits.env"
  if [[ "$1" == hang ]]; then
    printf '#!/bin/bash\nexec sleep 30\n' > "$tmp/bin/security"   # one hung process, like the real one
  else
    printf '#!/bin/bash\necho s3cret\n' > "$tmp/bin/security"
  fi
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

secret() {  # secret <args...>; sets $out, $rc, $secs
  local start r=0
  start=$(date +%s)
  out="$(HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" secret "$@" 2>&1)" || r=$?
  rc=$r; secs=$(( $(date +%s) - start ))
}
out_has()     { grep -q -- "$1" <<<"$out"; }
failed_fast() { [ "$rc" != 0 ] && [ "$secs" -lt 10 ]; }
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc ${secs}s: $out)"; fails=$((fails + 1)); fi
}

setup fast; secret get probe/x
check "fast read: prints the value"            [ "$out" = s3cret ]
check "fast read: exit 0"                      [ "$rc" = 0 ]
rm -rf "$tmp"

setup hang; secret get probe/x
check "hung read: fails"                       [ "$rc" != 0 ]
check "hung read: stops after the timeout"     [ "$secs" -lt 10 ]
check "hung read: says how to unlock"          out_has unlock-keychain
secret has probe/x
check "hung has: fails within the timeout"     failed_fast
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
