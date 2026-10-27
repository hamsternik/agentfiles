#!/usr/bin/env bash
# End-to-end check of roles/slave/steps/15-power.sh on a real host, run from
# another machine:  make e2e-power TARGET=agent@<host>   (or pass the target as $1)
#
# Needs AF_LID_CLOSED=1 applied on the host. Asks for the SSH password once
# (one shared connection), never uses sudo, changes nothing on the host.
# Checks: SleepDisabled 1 and sleep 0; lid really closed; SSH answers for
# AF_E2E_MINUTES (default 5); the host's power log shows no sleep meanwhile.
set -euo pipefail
target="${1:?usage: power.e2e.sh <user@host>}"
host="${target#*@}"
minutes="${AF_E2E_MINUTES:-5}"
interval=30
fails=0

ssh_opts=(-o ControlMaster=auto -o ControlPath=/tmp/af-e2e-%C -o ControlPersist=30m -o ConnectTimeout=10)
# shellcheck disable=SC2029  # every command is a fixed string meant to run on the host
r() { ssh "${ssh_opts[@]}" "$target" "$@"; }
trap 'ssh "${ssh_opts[@]}" -O exit "$target" 2>/dev/null || true' EXIT

pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
lid_closed() { r "ioreg -r -k AppleClamshellState -d 1" | grep -q '"AppleClamshellState" = Yes'; }

echo "== connecting to $target (type the password within 2 minutes if asked)"
r true || { echo "FAIL cannot reach $target"; exit 1; }

settings="$(r "pmset -g")"
if grep -Eq 'SleepDisabled[[:space:]]+1' <<<"$settings"; then pass "SleepDisabled 1"; else fail "SleepDisabled is not 1"; fi
if grep -Eq '^ sleep[[:space:]]+0' <<<"$settings"; then pass "sleep 0"; else fail "sleep is not 0"; fi

if ! lid_closed; then
  echo "== close the lid now (waiting up to 2 minutes)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do lid_closed && break; sleep 10; done
fi
if lid_closed; then pass "lid is closed"; else fail "lid is still open"; exit 1; fi

start="$(r "date '+%F %T'")"
echo "== watching for ${minutes} min from $start (host clock)"
rounds=$(( minutes * 60 / interval ))
missed=0
for ((i = 1; i <= rounds; i++)); do
  sleep "$interval"
  if nc -z -G 5 "$host" 22 2>/dev/null; then echo "     +$(( i * interval ))s reachable"
  else echo "     +$(( i * interval ))s NO ANSWER"; missed=$((missed + 1)); fi
done
if (( missed == 0 )); then pass "reachable for ${minutes} min"; else fail "unreachable in $missed of $rounds probes"; fi

# pmset log lines: "YYYY-MM-DD HH:MM:SS +ZZZZ <Type> ..."; Type "Sleep" = system slept.
log="$(r "pmset -g log")"
echo "     info: $(awk -v s="$start" '($1 " " $2) < s && $4 == "Sleep"' <<<"$log" | wc -l | tr -d ' ') sleep events in the log before the test (parser sanity)"
sleeps="$(awk -v s="$start" '($1 " " $2) >= s && $4 == "Sleep"' <<<"$log")"
if [[ -z "$sleeps" ]]; then pass "no sleep in the power log"; else fail "host slept:"; while IFS= read -r l; do echo "     $l"; done <<<"$sleeps"; fi

if lid_closed; then pass "lid still closed at the end"; else fail "lid was opened during the test"; fi

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
echo "all checks passed"
