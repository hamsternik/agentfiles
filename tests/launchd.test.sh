#!/usr/bin/env bash
# Tests for LaunchAgent loading in roles/slave/steps/90-services.sh with a
# stubbed launchctl that copies two real problems: no gui/<uid> domain without
# a GUI login, and the bootout race (the job stays visible for a moment, and a
# bootstrap meanwhile fails with "5: Input/output error").
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
step="$repo/roles/slave/steps/90-services.sh"
fails=0

setup() {  # setup gui|nogui [loaded labels...]
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/loaded"
  : > "$tmp/calls"; : > "$tmp/local/machine.env"
  [[ "$1" == gui ]] && touch "$tmp/gui"
  shift
  local l; for l in "$@"; do touch "$tmp/loaded/$l"; done
  cat > "$tmp/bin/launchctl" <<EOF
#!/bin/bash
echo "launchctl \$*" >> "$tmp/calls"
case "\$1" in
  print)
    if [[ "\$2" == gui/*/* ]]; then
      f="$tmp/loaded/\${2##*/}"
      [[ -f "\$f" ]] || exit 113
      if [[ -f "\$f.dying" ]]; then
        n=\$(cat "\$f.dying")
        if (( n <= 0 )); then rm -f "\$f" "\$f.dying"; exit 113; fi
        echo \$((n - 1)) > "\$f.dying"
      fi
      exit 0
    fi
    [[ -f "$tmp/gui" ]] || { echo "Could not find domain for" >&2; exit 112; } ;;
  bootout) [[ -f "$tmp/loaded/\${2##*/}" ]] && echo 2 > "$tmp/loaded/\${2##*/}.dying"; exit 0 ;;
  enable) exit 0 ;;
  bootstrap)
    [[ -f "$tmp/gui" ]] || { echo "Bootstrap failed: 125: Domain does not support specified action" >&2; exit 125; }
    l="\$(basename "\$3" .plist)"
    [[ -f "$tmp/loaded/\$l" ]] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
    touch "$tmp/loaded/\$l" ;;
esac
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
loaded()     { [[ -f "$tmp/loaded/$1" && ! -f "$tmp/loaded/$1.dying" ]]; }

setup nogui; run_step
check "no GUI: finishes"                       finished
check "no GUI: plist still rendered"           [ -f "$tmp/home/Library/LaunchAgents/local.agentfiles.health.plist" ]
check "no GUI: no bootstrap attempted"         not_called "launchctl bootstrap"
check "no GUI: says it loads at next login"    grep -q 'next login' "$tmp/out"
rm -rf "$tmp"

setup gui; run_step
check "GUI, new: finishes"                     finished
check "GUI, new: enabled"                      called "launchctl enable gui/"
check "GUI, new: health loaded"                loaded local.agentfiles.health
check "GUI, new: cleanup loaded"               loaded local.agentfiles.cleanup
rm -rf "$tmp"

setup gui local.agentfiles.health local.agentfiles.cleanup; run_step
check "GUI, reload: survives the bootout race" finished
check "GUI, reload: booted out first"          called "launchctl bootout gui/"
check "GUI, reload: health loaded again"       loaded local.agentfiles.health
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
