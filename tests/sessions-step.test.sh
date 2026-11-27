#!/usr/bin/env bash
# The session-sync step (master 60, slave 86) links the sync-sessions-to-seat
# skill into ~/.claude/skills, is idempotent, and changes nothing with
# --dry-run. Use case 28 of PLAN-watchdog-skill. Temp HOME/AF_HOME/AF_LOCAL.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home" "$tmp/af" "$tmp/local"
  : > "$tmp/local/machine.env"
}

step() {  # step <file> [VAR=value...]; sets $out, $rc
  local r=0 f="$1"; shift
  out="$(env "$@" AF_ROOT="$repo" HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$repo/$f" 2>&1)" || r=$?
  rc=$r
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc: $out)"; fails=$((fails + 1)); fi
}
links_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

link="home/.claude/skills/sync-sessions-to-seat"
src="$repo/claude/skills/sync-sessions-to-seat"

for file in roles/master/steps/60-sessions.sh roles/slave/steps/86-sessions.sh; do
  setup
  step "$file"
  check "$file: exits 0"                         [ "$rc" = 0 ]
  check "$file: links the skill"                 links_to "$tmp/$link" "$src"
  step "$file"
  check "$file: a second run keeps the link"     links_to "$tmp/$link" "$src"
  rm -rf "$tmp"

  setup
  step "$file" AF_DRY_RUN=1
  check "$file: dry-run: exits 0"                [ "$rc" = 0 ]
  check "$file: dry-run: no link"                [ ! -e "$tmp/$link" -a ! -L "$tmp/$link" ]
  rm -rf "$tmp"
done

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
