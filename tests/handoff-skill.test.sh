#!/usr/bin/env bash
# The handoff-session-context skill: the Python tests of context.py pass, the
# skill text is complete and generic, and the watchdog step (master 70, slave 87)
# links the skill and adds the Stop hook once, keeping the other settings.
# Temp HOME/AF_HOME/AF_LOCAL.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo/claude/skills/handoff-session-context"
fails=0

check() {  # check <name> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (${out:-})"; fails=$((fails + 1)); fi
}
holds() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -rqE --exclude-dir=__pycache__ -- "$2" "$1" 2>/dev/null; }
links_to() { [[ -L "$1" && "$(readlink "$1")" == "$2" ]]; }

# 1. Python unit tests
out=""
check "context.py unit tests pass"              python3 -m unittest discover -s "$skill/tests" -q

# 2. Skill text
check "SKILL.md exists"                         [ -f "$skill/SKILL.md" ]
check "front matter starts the file"            [ "$(head -1 "$skill/SKILL.md" 2>/dev/null)" = "---" ]
check "front matter name = folder name"         holds "$skill/SKILL.md" "name: handoff-session-context"
check "front matter has a description"          grep -qE '^description: .{80,}' "$skill/SKILL.md"
# shellcheck disable=SC2016  # literal text in SKILL.md, not expanded
check "SKILL.md uses its own session id"        holds "$skill/SKILL.md" '${CLAUDE_SESSION_ID}'
# shellcheck disable=SC2016
check "SKILL.md uses context.py size"           holds "$skill/SKILL.md" 'python3 $C size --session'
# shellcheck disable=SC2016
check "SKILL.md finds its script by its own dir" holds "$skill/SKILL.md" 'C=${CLAUDE_SKILL_DIR}/scripts/context.py'
check "SKILL.md has no fixed install path"      lacks "$skill/SKILL.md" '[~]/.claude/skills'
check "SKILL.md marks the hand-off done"        holds "$skill/SKILL.md" "mark-done"
check "SKILL.md starts the successor in Rex"     holds "$skill/SKILL.md" "rex window new"
check "SKILL.md leaves rename to the owner"      holds "$skill/SKILL.md" "/rename"
check "SKILL.md names the limits"               holds "$skill/SKILL.md" "40 %"
check "template exists"                         [ -f "$skill/templates/handoff.md" ]
for section in "## State" "## Open items" "## Facts" "## Next steps" "## Hand-off steps"; do
  check "template has $section"                 holds "$skill/templates/handoff.md" "$section"
done
check "skill has no home paths or session ids"  lacks "$skill" '/Users/[a-z]|[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
check "context.py is executable"                [ -x "$skill/scripts/context.py" ]
check "latest.py is executable"                 [ -x "$skill/scripts/latest.py" ]
# shellcheck disable=SC2016
check "SKILL.md has the restore procedure"     holds "$skill/SKILL.md" 'python3 ${CLAUDE_SKILL_DIR}/scripts/latest.py --title'

# 3. Install step: work projects only (Nikita 2026-11-24: no work skill in ~/.claude/skills)
setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home/.claude" "$tmp/af" "$tmp/local" "$tmp/work/p1" "$tmp/work/p2/.claude" "$tmp/work/notgit" "$tmp/work/foreign/.claude/skills/handoff-session-context"
  : > "$tmp/local/machine.env"
  git -C "$tmp/work/p1" init -q; git -C "$tmp/work/p2" init -q; git -C "$tmp/work/foreign" init -q
  git -C "$tmp/work/p1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
  git -C "$tmp/work/p1" worktree add -q "$tmp/work/p1-wt" -b wt 2>/dev/null   # a worktree: .git is a file
  printf '{\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n' > "$tmp/work/p2/.claude/settings.local.json"
  printf '{\n  "model": "opus"\n}\n' > "$tmp/home/.claude/settings.json"
}
step() {  # step <file>; sets $out, $rc
  local r=0
  out="$(AF_ROOT="$repo" HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_WORK_ROOT="$tmp/work" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" /bin/bash "$repo/$1" 2>&1)" || r=$?
  rc=$r
}
hooks_in() { grep -c 'handoff-session-context/scripts/context.py\\" hook' "$1" 2>/dev/null || true; }
excluded() { grep -qxF '/.claude/skills/handoff-session-context' "$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude)"; }

for file in roles/master/steps/70-watchdog.sh roles/slave/steps/87-watchdog.sh; do
  setup
  step "$file"
  check "$file: exits 0"                               [ "$rc" = 0 ]
  for p in p1 p2 p1-wt; do
    check "$file: $p: links the skill"                 links_to "$tmp/work/$p/.claude/skills/handoff-session-context" "$skill"
    check "$file: $p: the script runs through the link" [ -x "$tmp/work/$p/.claude/skills/handoff-session-context/scripts/context.py" ]
    check "$file: $p: adds the Stop hook (local)"      [ "$(hooks_in "$tmp/work/$p/.claude/settings.local.json")" = 1 ]
    check "$file: $p: link is git-excluded"            excluded "$tmp/work/$p"
    check "$file: $p: git status stays clean"          [ -z "$(git -C "$tmp/work/$p" status --porcelain -- .claude)" ]
  done
  check "$file: p2: keeps the other local settings"    holds "$tmp/work/p2/.claude/settings.local.json" 'Bash(ls)'
  check "$file: a folder with no git gets nothing"     [ ! -e "$tmp/work/notgit/.claude" ]
  check "$file: a foreign skill folder is left alone"  [ ! -L "$tmp/work/foreign/.claude/skills/handoff-session-context" ]
  check "$file: no user-level skill link"              [ ! -e "$tmp/home/.claude/skills/handoff-session-context" ]
  check "$file: user settings.json unchanged"          [ "$(cat "$tmp/home/.claude/settings.json")" = "$(printf '{\n  "model": "opus"\n}')" ]
  check "$file: prints the statusline line"            holds "$tmp/af/state/manual-steps.md" "context.py record"
  step "$file"
  check "$file: a second run exits 0"                  [ "$rc" = 0 ]
  check "$file: a second run adds no hook"             [ "$(hooks_in "$tmp/work/p1/.claude/settings.local.json")" = 1 ]
  check "$file: a second run adds no exclude line"     [ "$(grep -c handoff-session-context "$tmp/work/p1/.git/info/exclude")" = 1 ]
  rm -rf "$tmp"
done

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
