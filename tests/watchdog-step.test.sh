#!/usr/bin/env bash
# The watchdog step (master 70, slave 87) links the start-project-watchdog
# skill into ~/.claude/skills, is idempotent, and leaves a skill that is not
# ours alone. Temp HOME/AF_HOME/AF_LOCAL.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home" "$tmp/af" "$tmp/local"
  : > "$tmp/local/machine.env"
}

step() {  # step <file>; sets $out, $rc
  local r=0
  out="$(AF_ROOT="$repo" HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" /bin/bash "$repo/$1" 2>&1)" || r=$?
  rc=$r
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc: $out)"; fails=$((fails + 1)); fi
}
links_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

link="home/.claude/skills/start-project-watchdog"
src="$repo/claude/skills/start-project-watchdog"

for file in roles/master/steps/70-watchdog.sh roles/slave/steps/87-watchdog.sh; do
  setup
  step "$file"
  check "$file: exits 0"                         [ "$rc" = 0 ]
  check "$file: links the skill"                 links_to "$tmp/$link" "$src"
  check "$file: the script runs through the link" [ -x "$tmp/$link/scripts/watchdog.sh" ]
  step "$file"
  check "$file: a second run exits 0"            [ "$rc" = 0 ]
  check "$file: a second run keeps the link"     links_to "$tmp/$link" "$src"
  rm -rf "$tmp"

  setup
  mkdir -p "$tmp/$link"
  step "$file"
  check "$file: a foreign skill folder is kept"  [ -d "$tmp/$link" -a ! -L "$tmp/$link" ]
  check "$file: ... with a warning"              grep -q "not ours" <<<"$out"
  rm -rf "$tmp"
done

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
