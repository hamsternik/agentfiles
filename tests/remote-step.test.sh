#!/usr/bin/env bash
# Tests for tests/e2e/remote-step.sh with a stub ssh that runs the "remote"
# command locally under a temp HOME. Uses DRY=1, so the step only prints.
# Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/home"
  # ssh stub: drop options and the target, run the remote command locally.
  cat > "$tmp/bin/ssh" <<EOF
#!/bin/bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -O) exit 0 ;;
    -o) shift 2 ;;
    -t) shift ;;
    *) shift; break ;;
  esac
done
HOME="$tmp/home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" exec /bin/bash -c "\$*"
EOF
  chmod +x "$tmp/bin/ssh"
}

remote_step() {  # remote_step <args...>
  PATH="$tmp/bin:$PATH" DRY=1 /bin/bash "$repo/tests/e2e/remote-step.sh" "$@" >"$tmp/out" 2>&1 \
    || echo "remote-step exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); fi
}
home_root_clean() { [[ "$(ls -A "$tmp/home")" == Developer ]]; }
env_has() { grep -qx "$1" "$tmp/home/Developer/_hamsternik/agentfiles-dev/local/machine.env"; }

setup; remote_step agent@box 15 AF_LID_CLOSED=1
check "copies the working tree"                [ -f "$tmp/home/Developer/_hamsternik/agentfiles-dev/roles/slave/steps/15-power.sh" ]
check "leaves .git behind"                     [ ! -e "$tmp/home/Developer/_hamsternik/agentfiles-dev/.git" ]
check "override applied (example env)"         env_has "AF_LID_CLOSED=1"
check "runs only the chosen step, dry-run"     grep -q 'step 15-power.sh' "$tmp/out"
check "dry-run flag passed"                    grep -q '\[dry-run\]' "$tmp/out"
check "finishes"                               bash -c "! grep -q 'remote-step exited' '$tmp/out'"
check "nothing new directly in the home folder"  home_root_clean
rm -rf "$tmp"

setup
mkdir -p "$tmp/home/Developer/_hamsternik/agentfiles/local"
printf 'AF_HOSTNAME="from-host"\nAF_LID_CLOSED=0\n' > "$tmp/home/Developer/_hamsternik/agentfiles/local/machine.env"
remote_step agent@box 15 AF_LID_CLOSED=1 AF_NEW=x
check "uses the host's own local/machine.env"  env_has 'AF_HOSTNAME="from-host"'
check "override replaces an existing value"    env_has "AF_LID_CLOSED=1"
check "override appends a new value"           env_has "AF_NEW=x"
check "host's own clone is untouched"          grep -qx "AF_LID_CLOSED=0" "$tmp/home/Developer/_hamsternik/agentfiles/local/machine.env"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
