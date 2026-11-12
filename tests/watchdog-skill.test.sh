#!/usr/bin/env bash
# The start-project-watchdog skill text: SKILL.md front matter matches the
# folder, rules.md holds every watchdog lesson, and the skill folder stays
# generic (no session ids, no home paths).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo/claude/skills/start-project-watchdog"
fails=0

check() {  # check <name> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
holds() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -rqE -- "$2" "$1" 2>/dev/null; }

check "SKILL.md exists"                         [ -f "$skill/SKILL.md" ]
check "rules.md exists"                         [ -f "$skill/rules.md" ]
check "front matter starts the file"            [ "$(head -1 "$skill/SKILL.md" 2>/dev/null)" = "---" ]
check "front matter name = folder name"         holds "$skill/SKILL.md" "name: start-project-watchdog"
check "front matter has a description"          grep -qE '^description: .{80,}' "$skill/SKILL.md"
check "SKILL.md points to rules.md"             holds "$skill/SKILL.md" "rules.md"
check "SKILL.md uses the script"                holds "$skill/SKILL.md" "scripts/watchdog.sh"
check "SKILL.md has the hand-off procedure"     holds "$skill/SKILL.md" "500 k"

# One anchor per lesson (a)-(j) of the watchdog, plus the extra org rules.
for anchor in \
  "AskUserQuestion" \
  "2 h" \
  "never a default" \
  "deletion" \
  "start_session" \
  'get_session("self")' \
  "one line per milestone" \
  "Check before passing on" \
  "No polling" \
  "500 k" \
  "names the model" \
  "No Fable by default" \
  "master or slave" \
  "credential cache" \
  "push only on the owner's word" \
  "triage-inbox" \
  "next-id" \
  "Bulk AI jobs" \
  "Deleting files" \
  "HTML reports" \
  "Obsolete documents" \
  "ASD-STE100"; do
  check "rules.md: $anchor"                     holds "$skill/rules.md" "$anchor"
done

check "no session id in the skill"              lacks "$skill" 'local_[0-9a-f]{8}'
check "no home path in the skill"               lacks "$skill" '/Users/'

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
