#!/usr/bin/env bash
# Tests for helpers in lib/common.sh that need no stubs.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../lib/common.sh
. "$repo/lib/common.sh"
fails=0

ge() {  # ge <a> <b> <y|n>: expect version_ge a b
  local r=n
  version_ge "$1" "$2" && r=y
  if [[ "$r" == "$3" ]]; then echo "ok   version_ge $1 $2 -> $r"
  else echo "FAIL version_ge $1 $2 -> $r (want $3)"; fails=$((fails + 1)); fi
}
ge 2.1.0 2.1.0 y
ge 2.10.1 2.9 y
ge 1.6.0 2.1.0 n
ge 2.1 2.1.0 y
ge 2.0.9 2.1 n
ge 27.1 27.0.1 y
ge 3 2.99.99 y
ge 08 8 y

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
