#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Power for an always-on machine: never sleep on AC, wake for network, restart
# after a freeze. With AF_LID_CLOSED=1 it also stays awake with the lid shut.
# Run on its own with: ./bootstrap.sh slave --only 15
require_macos

log "Power: never sleep on AC, wake for network, restart after freeze"
# -c = on charger only, so a pulled cable still lets the battery protect itself.
run sudo pmset -c sleep 0 disksleep 0 displaysleep 10 powernap 0 womp 1 tcpkeepalive 1
run sudo pmset -a autorestart 1
run sudo systemsetup -setrestartfreeze on >/dev/null \
  || warn "systemsetup -setrestartfreeze failed; autorestart still covers power loss."

# A closed MacBook sleeps unless something keeps it awake. disablesleep is not
# in `man pmset` but works on Apple silicon. It applies on battery too.
sleep_disabled() { pmset -g | awk '/SleepDisabled/ {print $2}'; }
want="${AF_LID_CLOSED:-0}"
if [[ "$(sleep_disabled)" == "$want" ]]; then
  ok "SleepDisabled already $want"
else
  log "Lid closed = $want -> SleepDisabled $want"
  run sudo pmset -a disablesleep "$want"
  if [[ "$AF_DRY_RUN" != 1 ]]; then
    [[ "$(sleep_disabled)" == "$want" ]] || die "pmset did not apply disablesleep $want"
    ok "SleepDisabled $want"
  fi
fi
