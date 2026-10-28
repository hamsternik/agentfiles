#!/usr/bin/env bash
# Tests for bin/af-versions with stubbed brew, xcodebuild, xcodes, xcrun, docker,
# sw_vers and pkgutil. The snapshot goes to a temp dir (AF_VERSIONS_DIR).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
pin() { sed -n "s/^$1=//p" "$repo/config/versions.env" | head -1 || true; }
xbuild="$(pin AF_XCODE_BUILD)"; xver="$(pin AF_XCODE_VERSION)"
rt="$(awk '$1 == "iOS" {print $2; exit}' "$repo/apple/runtimes.txt" || true)"
digest="$(sed -n 's/^ *image: .*@\(sha256:[0-9a-f]*\).*/\1/p' "$repo/services/us-gateway/compose.yaml")"

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af" "$tmp/snap" "$tmp/fver" "$tmp/cver" "$tmp/dot"
  printf 'brew "fish"\nbrew "tmux"\n' > "$tmp/dot/Brewfile.terminal"
  printf 'DOTFILES_REPO="x"\nDOTFILES_DIR="%s"\n' "$tmp/dot" > "$tmp/local/machine.env"
  printf 'google-chrome\nclaude\norbstack\naldente\nmullvad-vpn\ntailscale-app\n' > "$tmp/auto"
  echo "$xver $xbuild" > "$tmp/xcode"; echo "$rt" > "$tmp/runtimes"; echo "2.1.0" > "$tmp/xcodes"
  echo "$digest" > "$tmp/gluetun"
  # brew info --json=v2 --formula|--cask NAMES...: version 1.0 unless overridden.
  cat > "$tmp/bin/brew" <<EOF
#!/bin/bash
[[ "\$1 \$2" == "info --json=v2" ]] || exit 1
kind="\$3"; shift 3; out=""
for n in "\$@"; do
  if [[ "\$kind" == --formula ]]; then
    v="\$(cat "$tmp/fver/\$n" 2>/dev/null || echo 1.0)"
    inst="[{\\"version\\":\\"\$v\\"}]"; [[ "\$v" == missing ]] && inst="[]"
    out="\$out\${out:+,}{\\"name\\":\\"\$n\\",\\"installed\\":\$inst}"
  else
    v="\$(cat "$tmp/cver/\$n" 2>/dev/null || echo 1.0)"; a=false; grep -qx "\$n" "$tmp/auto" && a=true
    out="\$out\${out:+,}{\\"token\\":\\"\$n\\",\\"installed\\":\\"\$v\\",\\"auto_updates\\":\$a}"
  fi
done
if [[ "\$kind" == --formula ]]; then echo "{\\"formulae\\":[\$out],\\"casks\\":[]}"; else echo "{\\"formulae\\":[],\\"casks\\":[\$out]}"; fi
EOF
  cat > "$tmp/bin/xcodebuild" <<EOF
#!/bin/bash
read -r v b < "$tmp/xcode"; printf 'Xcode %s\nBuild version %s\n' "\$v" "\$b"
EOF
  cat > "$tmp/bin/xcodes" <<EOF
#!/bin/bash
[[ "\$1" == version ]] && cat "$tmp/xcodes"
EOF
  cat > "$tmp/bin/xcrun" <<EOF
#!/bin/bash
[[ "\$*" == "simctl runtime list -j" ]] || exit 1
b="\$(cat "$tmp/runtimes")"
if [[ -n "\$b" ]]; then echo "{\\"U1\\":{\\"build\\":\\"\$b\\",\\"state\\":\\"Ready\\"}}"; else echo '{}'; fi
EOF
  # docker: running gateway unless $tmp/nodocker exists.
  cat > "$tmp/bin/docker" <<EOF
#!/bin/bash
[[ -f "$tmp/nodocker" ]] && exit 1
case "\$1" in
  info) exit 0 ;;
  inspect) echo "sha256:imageid" ;;
  image) echo "qmcgaw/gluetun@\$(cat "$tmp/gluetun")" ;;
esac
EOF
  printf '#!/bin/bash\necho 27.2\n' > "$tmp/bin/sw_vers"
  printf '#!/bin/bash\necho "version: 27.2.0.0.1"\n' > "$tmp/bin/pkgutil"
  chmod +x "$tmp/bin/"*
}

versions() {  # versions <args...>; sets $out and $rc
  local r=0
  out="$(HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_VERSIONS_DIR="$tmp/snap" \
    PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$repo/bin/af" versions "$@" 2>&1)" || r=$?
  rc=$r
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc)"; printf '     %s\n' "${out//$'\n'/$'\n'     }"; fails=$((fails + 1)); fi
}
has()     { grep -q -- "$1" <<<"$out"; }
snap_has() { grep -qx -- "$1" "$tmp/snap/brew-versions.$2.txt"; }
snap_lacks() { [[ -f "$tmp/snap/brew-versions.$2.txt" ]] && ! grep -q -- "$1" "$tmp/snap/brew-versions.$2.txt"; }
rc_is()   { [[ "$rc" == "$1" ]]; }

setup; versions --role slave
check "no snapshot: fails"                         rc_is 1
check "no snapshot: says how to record"            has "af versions --record"
versions --role slave --record
check "record: exit 0"                             rc_is 0
check "record: formula from the role Brewfile"     snap_has "formula node@24 1.0" slave
check "record: formula from Brewfile.terminal"     snap_has "formula fish 1.0" slave
check "record: cask without auto-update"           snap_has "cask claude-code 1.0" slave
check "record: auto-updating casks left out"       snap_lacks "cask claude " slave
versions --role slave
check "all match: exit 0"                          rc_is 0
check "shows macOS as information"                 has "27.2"
echo 9.9 > "$tmp/fver/jq"; versions --role slave
check "formula drift: exit 1"                      rc_is 1
check "formula drift: names it"                    has "jq"
rm "$tmp/fver/jq"; echo 3.0 > "$tmp/cver/claude-code"; versions --role slave
check "cask drift: exit 1"                         rc_is 1
rm "$tmp/cver/claude-code"; echo 9.0 > "$tmp/cver/claude"; versions --role slave
check "auto-updating cask change: still 0"         rc_is 0
echo "27.0 27A266a" > "$tmp/xcode"; versions --role slave
check "Xcode build drift: exit 1"                  rc_is 1
echo "$xver $xbuild" > "$tmp/xcode"; : > "$tmp/runtimes"; versions --role slave
check "runtime build missing: exit 1"              rc_is 1
echo "$rt" > "$tmp/runtimes"; echo 1.6.0 > "$tmp/xcodes"; versions --role slave
check "xcodes below minimum: exit 1"               rc_is 1
echo 2.1.0 > "$tmp/xcodes"; echo "sha256:0000" > "$tmp/gluetun"; versions --role slave
check "gluetun digest drift: exit 1"               rc_is 1
touch "$tmp/nodocker"; versions --role slave
check "gateway not running: no failure"            rc_is 0
rm -rf "$tmp"

setup; versions --role master --record; versions --role master
check "master: exit 0 after record"                rc_is 0
check "master: no Xcode row"                       bash -c "! grep -q 'Xcode' <<<'$out'"
check "master: no Brewfile.terminal on master"     snap_lacks "formula fish" master
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
