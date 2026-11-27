#!/usr/bin/env bash
# The watchdog step (master 70, slave 87) links the watchdog skill into
# ~/.claude/skills, removes the old start-project-watchdog link when it points
# into this clone, is idempotent, leaves a skill that is not ours alone, and
# changes nothing with --dry-run. Use case 26 of PLAN-watchdog-skill.
# Temp HOME/AF_HOME/AF_LOCAL.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home/.claude/skills" "$tmp/af" "$tmp/local" "$tmp/work"
  : > "$tmp/local/machine.env"
}

step() {  # step <file> [VAR=value...]; sets $out, $rc
  local r=0 f="$1"; shift
  out="$(env "$@" AF_ROOT="$repo" HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_WORK_ROOT="$tmp/work" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" /bin/bash "$repo/$f" 2>&1)" || r=$?
  rc=$r
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc: $out)"; fails=$((fails + 1)); fi
}
links_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

link="home/.claude/skills/watchdog"
src="$repo/claude/skills/watchdog"
old="home/.claude/skills/start-project-watchdog"

for file in roles/master/steps/70-watchdog.sh roles/slave/steps/87-watchdog.sh; do
  setup
  step "$file"
  check "$file: exits 0"                         [ "$rc" = 0 ]
  check "$file: links the skill"                 links_to "$tmp/$link" "$src"
  check "$file: the CLI runs through the link"   [ -x "$tmp/$link/scripts/watchdog.py" ]
  step "$file"
  check "$file: a second run exits 0"            [ "$rc" = 0 ]
  check "$file: a second run keeps the link"     links_to "$tmp/$link" "$src"
  rm -rf "$tmp"

  # the old link into this clone goes; a foreign one stays with a warning
  setup
  ln -s "$repo/claude/skills/start-project-watchdog" "$tmp/$old"
  step "$file"
  check "$file: the old link is removed"         [ ! -e "$tmp/$old" -a ! -L "$tmp/$old" ]
  check "$file: ... and says so"                 grep -q "start-project-watchdog" <<<"$out"
  rm -rf "$tmp"
  setup
  ln -s "/elsewhere/start-project-watchdog" "$tmp/$old"
  step "$file"
  check "$file: a foreign old link is kept"      links_to "$tmp/$old" "/elsewhere/start-project-watchdog"
  check "$file: ... with a warning"              grep -q "not ours" <<<"$out"
  rm -rf "$tmp"

  setup
  mkdir -p "$tmp/$link"
  step "$file"
  check "$file: a foreign skill folder is kept"  [ -d "$tmp/$link" -a ! -L "$tmp/$link" ]
  check "$file: ... with a warning"              grep -q "not ours" <<<"$out"
  rm -rf "$tmp"

  # --dry-run changes nothing
  setup
  ln -s "$repo/claude/skills/start-project-watchdog" "$tmp/$old"
  step "$file" AF_DRY_RUN=1
  check "$file: dry-run: no new link"            [ ! -e "$tmp/$link" -a ! -L "$tmp/$link" ]
  check "$file: dry-run: the old link stays"     [ -L "$tmp/$old" ]
  rm -rf "$tmp"
done

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
