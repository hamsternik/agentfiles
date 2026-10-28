#!/usr/bin/env bash
# Tests for roles/slave/steps/50-apple.sh with stubbed xcodebuild, xcrun,
# xcodes, DevToolsSecurity, sudo and uname. Pins come from config/versions.env.
# stdin is not a terminal, so a missing Xcode becomes a manual step.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/50-apple.sh"
fails=0
pin() { sed -n "s/^$1=//p" "$repo/config/versions.env" 2>/dev/null | head -1 || true; }
want="$(pin AF_XCODE_VERSION)"; build="$(pin AF_XCODE_BUILD)"; min="$(pin AF_XCODES_MIN_VERSION)"
rt="$(awk '$1 == "iOS" {print $2; exit}' "$repo/apple/runtimes.txt" || true)"   # pinned iOS runtime build

# setup <selected "version build" or ""> <xcodes installed lines> <unused> <Ready runtime builds> <devtools> [xcodes version]
setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home"
  : > "$tmp/calls"; : > "$tmp/local/machine.env"
  echo "$1" > "$tmp/selected"
  printf '%s' "$2" > "$tmp/installed"
  local rts="" b n=0
  for b in $4; do
    n=$((n + 1))
    rts="$rts${rts:+,}\"UUID-$n\":{\"build\":\"$b\",\"version\":\"27.x\",\"platformIdentifier\":\"com.apple.platform.iphonesimulator\",\"state\":\"Ready\"}"
  done
  echo "{$rts}" > "$tmp/runtimes.json"
  cat > "$tmp/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
EOF
  cat > "$tmp/bin/xcodebuild" <<EOF
#!/bin/bash
echo "xcodebuild \$*" >> "$tmp/calls"
if [[ "\$1" == -version ]]; then
  read -r v b < "$tmp/selected"
  [[ -n "\$v" ]] || { echo "xcode-select: error: tool 'xcodebuild' requires Xcode" >&2; exit 1; }
  printf 'Xcode %s\nBuild version %s\n' "\$v" "\$b"
fi
EOF
  # xcodes select <version>: selects the installed line for that version.
  cat > "$tmp/bin/xcodes" <<EOF
#!/bin/bash
echo "xcodes \$*" >> "$tmp/calls"
case "\$1" in
  version) echo "${6:-2.1.0}" ;;
  installed) cat "$tmp/installed" ;;
  select) grep "^\$2 (" "$tmp/installed" | sed -E 's/^([^ ]+) \\(([^)]+)\\).*/\\1 \\2/' > "$tmp/selected" ;;
  runtimes) [[ -f "$tmp/rt_fail" ]] && exit 1; true ;;
esac
EOF
  cat > "$tmp/bin/xcrun" <<EOF
#!/bin/bash
echo "xcrun \$*" >> "$tmp/calls"
case "\$*" in
  "--sdk iphonesimulator --show-sdk-version") [[ -n "$3" ]] && echo "$3" || exit 1 ;;
  "simctl runtime list -j") cat "$tmp/runtimes.json" ;;
esac
EOF
  cat > "$tmp/bin/DevToolsSecurity" <<EOF
#!/bin/bash
echo "DevToolsSecurity \$*" >> "$tmp/calls"
[[ "\$1" == -status ]] && echo "Developer mode is currently $5."
true
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
manual_has() { grep -qF -- "$1" "$tmp/home/.agentfiles/state/manual-steps.md" 2>/dev/null; }
finished()   { ! grep -q 'step exited' "$tmp/out"; }

check "versions.env pins the Xcode version"         [ -n "$want" ]
check "versions.env pins the Xcode build"           [ -n "$build" ]
check "versions.env has an xcodes minimum"          [ -n "$min" ]
check "apple/xcode-version is gone"                 [ ! -e "$repo/apple/xcode-version" ]

setup "" "" "" "" enabled; run_step
check "no Xcode: finishes"                          finished
check "no Xcode: manual install of the pin"         manual_has "xcodes install $want --select --experimental-unxip"
check "no Xcode: nothing else attempted"            not_called "xcodebuild -license"
rm -rf "$tmp"

setup "$want $build" "$want ($build) (Selected)  /Applications/Xcode-$want.0.app" "" "$rt" enabled; run_step
check "pinned build selected: finishes"             finished
check "pinned build selected: reported"             grep -q "Xcode $want ($build)" "$tmp/out"
check "pinned build selected: no select/install"    not_called "xcodes select"
check "pinned build selected: license accepted"     called "sudo xcodebuild -license accept"
check "pinned runtime build present: no install"   not_called "xcodes runtimes install"
check "pinned runtime build present: no download"  not_called "-downloadPlatform"
check "developer mode on: left alone"               not_called "DevToolsSecurity -enable"
rm -rf "$tmp"

setup "27.0 27A266a" "$(printf '27.0 (27A266a) (Selected)  /Applications/Xcode-27.0.0.app\n%s (%s)  /Applications/Xcode-%s.0.app\n' "$want" "$build" "$want")" "$want" "$want" disabled; run_step
check "pin installed, not selected: xcodes select"  called "xcodes select $want"
check "pin installed, not selected: finishes"       finished
check "dev mode off: enabled"                       called "sudo DevToolsSecurity -enable"
rm -rf "$tmp"

setup "27.0 27A266a" "27.0 (27A266a) (Selected)  /Applications/Xcode-27.0.0.app" "27.0" "27.0" enabled; run_step
check "other Xcode only: manual install of the pin" manual_has "xcodes install $want"
rm -rf "$tmp"

setup "$want $build" "$want ($build) (Selected)  /Applications/Xcode-$want.0.app" "$want" "$want" enabled 1.6.0; run_step
check "old xcodes: manual upgrade step"             manual_has "xcodes"
check "old xcodes: names the minimum"               manual_has "$min"
rm -rf "$tmp"

check "runtimes.txt pins an iOS build"             [ -n "$rt" ]

setup "$want $build" "$want ($build) (Selected)  /Applications/Xcode-$want.0.app" "" "OTHERBUILD" enabled; run_step
check "runtime build missing: xcodes by build"      called "xcodes runtimes install $rt"
check "runtime build missing: no fallback needed"   not_called "-downloadPlatform"
rm -rf "$tmp"

setup "$want $build" "$want ($build) (Selected)  /Applications/Xcode-$want.0.app" "" "" enabled; touch "$tmp/rt_fail"; run_step
check "xcodes runtimes fails: arm64 fallback"       called "xcodebuild -downloadPlatform iOS -architectureVariant arm64"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
