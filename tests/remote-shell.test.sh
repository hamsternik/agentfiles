#!/usr/bin/env bash
# The slave's login shell is fish (AF_LOGIN_SHELL), and sshd runs every
# `ssh host cmd` as `$SHELL -c "cmd"`. This test records every remote command
# our scripts send (stub ssh/mosh, canned output, nothing runs remotely) and
# checks that each one parses in fish AND in /bin/sh.
# Run: make test   (needs fish for the fish half; skipped without it)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fish_bin="$(command -v fish || true)"
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
: > "$tmp/remote"
printf 'AF_HOST_TAILNET="box"\n' > "$tmp/local/machine.env"

# ssh stub: drop options and the target, record the remote command, answer like a slave.
cat > "$tmp/bin/ssh" <<EOF
#!/bin/bash
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -O) exit 0 ;;
    -o) shift 2 ;;
    -t|-T) shift ;;
    *) shift; break ;;
  esac
done
cmd="\$*"
[[ -n "\$cmd" ]] && echo "\$cmd" >> "$tmp/remote"
case "\$cmd" in
  "pmset -g") printf ' SleepDisabled\t\t1\n sleep                0\n' ;;
  ioreg*) echo '    "AppleClamshellState" = Yes' ;;
  date*) echo "2026-01-01 00:00:00" ;;
  "pmset -g log") true ;;
  *tar\ -xf*) cat >/dev/null ;;
esac
exit 0
EOF
# mosh stub: record the command after "--".
cat > "$tmp/bin/mosh" <<EOF
#!/bin/bash
while [[ \$# -gt 0 && "\$1" != -- ]]; do shift; done
shift; echo "\$*" >> "$tmp/remote"
EOF
printf '#!/bin/bash\nexit 0\n' > "$tmp/bin/nc"
chmod +x "$tmp/bin/"*

env_run() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" "$@" \
    >/dev/null 2>&1 || true
}

env_run env AF_E2E_MINUTES=0 /bin/bash "$repo/tests/e2e/power.e2e.sh" agent@box
env_run /bin/bash "$repo/tests/e2e/remote-step.sh" agent@box 15 AF_LID_CLOSED=1
env_run env DRY=1 /bin/bash "$repo/tests/e2e/remote-step.sh" agent@box 15
env_run "$repo/bin/af" attach work                       # mosh path
rm "$tmp/bin/mosh"; env_run "$repo/bin/af" attach         # ssh path

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
check "recorded remote commands from 3 scripts" [ "$(sort -u "$tmp/remote" | wc -l | tr -d ' ')" -ge 8 ]

while IFS= read -r cmd; do
  check "sh parses:   $cmd" /bin/sh -n -c "$cmd"
  if [[ -n "$fish_bin" ]]; then
    check "fish parses: $cmd" "$fish_bin" --no-config -n -c "$cmd"
  fi
done < <(sort -u "$tmp/remote")
[[ -n "$fish_bin" ]] || echo "skip fish half: fish not installed"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
