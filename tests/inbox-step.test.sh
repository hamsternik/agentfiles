#!/usr/bin/env bash
# The inbox step (master 50, slave 85) links the triage-inbox skill and `af`
# into ~/.claude, makes ~/.claude/inbox, is idempotent, and leaves a skill
# that is not ours alone. Temp HOME/AF_HOME/AF_LOCAL.
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

for file in roles/master/steps/50-inbox.sh roles/slave/steps/85-inbox.sh; do
  setup
  step "$file"
  check "$file: exits 0"                         [ "$rc" = 0 ]
  check "$file: links the skill"                 links_to "$tmp/home/.claude/skills/triage-inbox" "$repo/claude/skills/triage-inbox"
  check "$file: makes the inbox folder"          [ -d "$tmp/home/.claude/inbox" ]
  check "$file: links af for the skill"          links_to "$tmp/home/.claude/inbox/af" "$repo/bin/af"
  step "$file"
  check "$file: a second run exits 0"            [ "$rc" = 0 ]
  check "$file: a second run keeps the links"    links_to "$tmp/home/.claude/skills/triage-inbox" "$repo/claude/skills/triage-inbox"
  rm -rf "$tmp"

  setup
  mkdir -p "$tmp/home/.claude/skills/triage-inbox"
  step "$file"
  check "$file: a foreign skill folder is kept"  [ -d "$tmp/home/.claude/skills/triage-inbox" -a ! -L "$tmp/home/.claude/skills/triage-inbox" ]
  check "$file: ... with a warning"              grep -q "not ours" <<<"$out"
  rm -rf "$tmp"
done

# The linked af finds its repo through the symlink.
setup
step roles/master/steps/50-inbox.sh
out="$(HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  "$tmp/home/.claude/inbox/af" inbox role 2>&1)" && rc=0 || rc=$?
check "linked af runs af inbox"                  [ "$out" = master ]
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
