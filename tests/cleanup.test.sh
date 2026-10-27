#!/usr/bin/env bash
# Tests for bin/af-cleanup log handling: old logs are deleted, and logs that are
# appended forever (health.log, notify.log) are trimmed to AF_LOG_MAX_LINES.
# xcrun is stubbed so nothing touches real simulators; docker is not on PATH.
# Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/home" "$tmp/local" "$tmp/af/logs" "$tmp/af/state"
  printf '#!/bin/bash\necho "xcrun $*" >> "%s/calls"\n' "$tmp" > "$tmp/bin/xcrun"
  chmod +x "$tmp/bin/xcrun"
  echo "AF_LOG_MAX_LINES=100" > "$tmp/local/limits.env"
  seq 1 250 > "$tmp/af/logs/health.log"             # appended forever, fresh mtime
  seq 1 50 > "$tmp/af/logs/notify.log"              # under the limit
  echo old > "$tmp/af/logs/job.x.y.err.log"
  touch -t 202001010000 "$tmp/af/logs/job.x.y.err.log"   # far older than AF_LOG_MAX_AGE_DAYS
}

cleanup_run() {  # cleanup_run [--apply]
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" \
    PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$repo/bin/af-cleanup" "$@" >"$tmp/out" 2>&1 || echo "af-cleanup exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; fails=$((fails + 1)); fi
}
lines() { wc -l < "$1" | tr -d ' '; }

setup; cleanup_run
check "dry run: health.log untouched"        [ "$(lines "$tmp/af/logs/health.log")" = 250 ]
check "dry run: old log kept"                [ -f "$tmp/af/logs/job.x.y.err.log" ]
check "dry run: says it would trim"          grep -q 'health.log' "$tmp/out"
rm -rf "$tmp"

setup; cleanup_run --apply
check "apply: finishes"                      bash -c "! grep -q 'af-cleanup exited' '$tmp/out'"
check "apply: health.log trimmed to 100"     [ "$(lines "$tmp/af/logs/health.log")" = 100 ]
check "apply: newest lines kept"             [ "$(tail -1 "$tmp/af/logs/health.log")" = 250 ]
check "apply: oldest kept line is 151"       [ "$(head -1 "$tmp/af/logs/health.log")" = 151 ]
check "apply: short log untouched"           [ "$(lines "$tmp/af/logs/notify.log")" = 50 ]
check "apply: old log deleted"               [ ! -e "$tmp/af/logs/job.x.y.err.log" ]
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
