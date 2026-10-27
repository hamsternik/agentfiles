#!/usr/bin/env bash
# Tests for roles/slave/steps/10-macos.sh with stubbed sudo, scutil, launchctl,
# nc, defaults, fdesetup and uname.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/10-macos.sh"
fails=0

setup() {  # setup <current name> <enabled labels> <open ports>
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/names"
  for k in ComputerName HostName LocalHostName; do echo "$1" > "$tmp/names/$k"; done
  : > "$tmp/disabled"
  for l in $2; do printf '\t"%s" => enabled\n' "$l" >> "$tmp/disabled"; done
  echo "$3" > "$tmp/ports"
  : > "$tmp/calls"
  cat > "$tmp/bin/sudo" <<EOF
#!/bin/bash
echo "sudo \$*" >> "$tmp/calls"; exec "\$@"
EOF
  cat > "$tmp/bin/scutil" <<EOF
#!/bin/bash
echo "scutil \$*" >> "$tmp/calls"
case "\$1" in
  --get) cat "$tmp/names/\$2" ;;
  --set) echo "\$3" > "$tmp/names/\$2" ;;
esac
EOF
  cat > "$tmp/bin/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$tmp/calls"
if [[ "\$1" == print-disabled ]]; then echo 'disabled services = {'; cat "$tmp/disabled"; echo '}'; fi
EOF
  cat > "$tmp/bin/nc" <<EOF
#!/bin/bash
for p in \$(cat "$tmp/ports"); do [[ "\${@: -1}" == "\$p" ]] && exit 0; done
exit 1
EOF
  for c in defaults fdesetup; do
    printf '#!/bin/bash\necho "%s $*" >> "%s/calls"\n' "$c" "$tmp" > "$tmp/bin/$c"
  done
  cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
  chmod +x "$tmp/bin/"*
}

run_step() {  # run_step <AF_HOSTNAME>
  echo "AF_HOSTNAME=\"$1\"" > "$tmp/local/machine.env"
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
manual_has() { grep -qF -- "$1" "$tmp/home/.agentfiles/state/manual-steps.md" 2>/dev/null; }
manual_lacks() { ! manual_has "$1"; }
finished()   { ! grep -q 'step exited' "$tmp/out"; }

setup "MacBook-Pro" "" ""; run_step "agents-mac"
check "fresh: finishes"                         finished
check "fresh: sets ComputerName"                called "sudo scutil --set ComputerName agents-mac"
check "fresh: sets LocalHostName"               called "sudo scutil --set LocalHostName agents-mac"
check "fresh: enables sshd via launchctl"       called "sudo launchctl enable system/com.openssh.sshd"
check "fresh: bootstraps sshd"                  called "sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist"
check "fresh: no systemsetup (exits 0 on error)" not_called "systemsetup"
check "fresh: Remote Login still off -> manual" manual_has "Remote Login"
check "fresh: Screen Sharing off -> manual"     manual_has "Screen Sharing"
check "fresh: never auto-install macOS"         called "AutomaticallyInstallMacOSUpdates -bool false"
check "fresh: never auto-install apps"          called "AutomaticallyInstallAppUpdates -bool false"
check "fresh: security responses stay on"       called "CriticalUpdateInstall -bool true"
check "fresh: system data files stay on"        called "ConfigDataInstall -bool true"
check "fresh: no 'decide FileVault' step"       manual_lacks "Decide FileVault"
check "fresh: no contradicting lid text"        manual_lacks "dummy HDMI plug if you want it closed"
rm -rf "$tmp"

setup "agents-mac" "com.openssh.sshd com.apple.screensharing" "22 5900"; run_step "agents-mac"
check "configured: finishes"                    finished
check "configured: names left alone"            not_called "scutil --set"
check "configured: sshd left alone"             not_called "launchctl enable"
check "configured: no Remote Login manual"      manual_lacks "Remote Login"
check "configured: no Screen Sharing manual"    manual_lacks "Screen Sharing"
rm -rf "$tmp"

setup "MacBook-Pro" "" "22"; run_step "agents-mac"
check "port 22 answers: sshd left alone"        not_called "launchctl enable"
rm -rf "$tmp"

setup "MacBook-Pro" "" ""; run_step "my host.local"
check "invalid name: step stops"                bash -c "grep -q 'step exited' '$tmp/out'"
check "invalid name: nothing renamed"           not_called "scutil --set"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
