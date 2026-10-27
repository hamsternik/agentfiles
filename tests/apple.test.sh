#!/usr/bin/env bash
# Tests for roles/slave/steps/50-apple.sh with stubbed xcodebuild, xcrun,
# xcodes, DevToolsSecurity, sudo and uname. stdin is not a terminal, so a
# missing Xcode becomes a manual step.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/50-apple.sh"
fails=0

setup() {  # setup <xcode version or ""> <sdk> <runtime versions> <devtools enabled|disabled>
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  : > "$tmp/calls"
  : > "$tmp/local/machine.env"
  local rts="" v
  for v in $3; do
    rts="$rts${rts:+,}{\"platform\":\"iOS\",\"version\":\"$v\",\"isAvailable\":true,\"identifier\":\"com.apple.CoreSimulator.SimRuntime.iOS-${v//./-}\",\"name\":\"iOS $v\"}"
  done
  echo "{\"runtimes\":[$rts]}" > "$tmp/runtimes.json"
  cat > "$tmp/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
EOF
  cat > "$tmp/bin/xcodebuild" <<EOF
#!/bin/bash
echo "xcodebuild \$*" >> "$tmp/calls"
if [[ "\$1" == -version ]]; then
  [[ -n "$1" ]] || { echo "xcode-select: error: tool 'xcodebuild' requires Xcode" >&2; exit 1; }
  printf 'Xcode %s\nBuild version 27A000\n' "$1"
fi
EOF
  cat > "$tmp/bin/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$tmp/calls"
[[ -n "$1" ]] || exit 1
case "\$*" in
  "--sdk iphonesimulator --show-sdk-version") echo "$2" ;;
  "simctl list runtimes -j") cat "$tmp/runtimes.json" ;;
esac
EOF
  cat > "$tmp/bin/DevToolsSecurity" <<EOF
#!/bin/bash
echo "DevToolsSecurity \$*" >> "$tmp/calls"
[[ "\$1" == -status ]] && echo "Developer mode is currently $4."
true
EOF
  printf '#!/bin/bash\necho "xcodes $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/xcodes"
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
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
called()     { grep -qF -- "$1" "$tmp/calls"; }
not_called() { [[ -f "$tmp/calls" ]] && ! grep -qF -- "$1" "$tmp/calls"; }
manual_has() { grep -qF -- "$1" "$tmp/home/.agentfiles/state/manual-steps.md" 2>/dev/null; }
finished()   { ! grep -q 'step exited' "$tmp/out"; }

setup "" "" "" enabled; run_step
check "no Xcode: finishes"                      finished
check "no Xcode: not reported as present"       bash -c "! grep -q 'Xcode present' '$tmp/out'"
check "no Xcode: manual install step"           manual_has "xcodes install"
check "no Xcode: manual uses fast unxip"        manual_has "--experimental-unxip"
check "no Xcode: nothing else attempted"        not_called "xcodebuild -license"
rm -rf "$tmp"

setup "27.0" "27.0" "27.0" enabled; run_step
check "ready: finishes"                         finished
check "ready: Xcode reported"                   grep -q 'Xcode present: Xcode 27.0' "$tmp/out"
check "ready: runtime matches SDK, no download" not_called "-downloadPlatform"
check "ready: developer mode left alone"        not_called "DevToolsSecurity -enable"
check "ready: license accepted"                 called "sudo xcodebuild -license accept"
rm -rf "$tmp"

setup "27.1" "27.1" "27.0" disabled; run_step
check "old runtime only: downloads arm64 iOS"   called "xcodebuild -downloadPlatform iOS -architectureVariant arm64"
check "dev mode off: enabled"                   called "sudo DevToolsSecurity -enable"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
