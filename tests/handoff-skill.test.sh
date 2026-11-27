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
check "watchdog.py unit tests pass"             env -u CLAUDECODE python3 -m unittest discover -s "$repo/claude/skills/watchdog/tests" -q

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
check "SKILL.md has no fixed path to itself"     lacks "$skill/SKILL.md" '[~]/.claude/skills/handoff-session-context'
check "SKILL.md marks the hand-off done"        holds "$skill/SKILL.md" "mark-done"
# shellcheck disable=SC2016
check "SKILL.md sets W to the watchdog skill"   holds "$skill/SKILL.md" 'W=~/.claude/skills/watchdog/scripts/watchdog.py'
check "SKILL.md names no rex-watchdog.sh"      lacks "$skill/SKILL.md" 'rex-watchdog'
check "SKILL.md names --frontend rex"           holds "$skill/SKILL.md" "--frontend rex"
check "SKILL.md has no --label"                 lacks "$skill/SKILL.md" '[-][-]label'
check "SKILL.md leaves rename to the owner"      holds "$skill/SKILL.md" "/rename"
check "SKILL.md names the limits"               holds "$skill/SKILL.md" "40 %"
check "template exists"                         [ -f "$skill/templates/handoff.md" ]
for section in "## State" "## Open items" "## Facts" "## Next steps" "## Hand-off steps"; do
  check "template has $section"                 holds "$skill/templates/handoff.md" "$section"
done
check "skill has no home paths"                lacks "$skill" '/Users/[a-z]'
check "skill code has no session ids"          lacks "$skill/scripts" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
check "skill text has no session ids"          lacks "$skill/SKILL.md" '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
check "context.py is executable"                [ -x "$skill/scripts/context.py" ]
check "latest.py alias is gone"                 [ ! -e "$skill/scripts/latest.py" ]
check "watchdog.py is executable (skill watchdog)" [ -x "$repo/claude/skills/watchdog/scripts/watchdog.py" ]
check "watchdog.py is no longer here"            [ ! -e "$skill/scripts/watchdog.py" ]
check "rex-watchdog.sh is gone"                 [ ! -e "$skill/scripts/rex-watchdog.sh" ]
check "the launchers package moved"             [ -f "$repo/claude/skills/watchdog/scripts/launchers/__init__.py" ]
# shellcheck disable=SC2016
for cmd in '$W handoff' '$W retire' '$W restore' '$W start' '$W ready' '$W status' '$W help'; do
  check "SKILL.md names $cmd"                   holds "$skill/SKILL.md" "$cmd"
done
check "SKILL.md no longer uses latest.py"       lacks "$skill/SKILL.md" 'latest\.py'
check "start-project-watchdog uses watchdog.py" holds "$repo/claude/skills/start-project-watchdog/SKILL.md" "scripts/watchdog.py\" new"
check "start-project-watchdog: --frontend rex"  holds "$repo/claude/skills/start-project-watchdog/SKILL.md" "--frontend rex"
check "start-project-watchdog: no wrapper"      lacks "$repo/claude/skills/start-project-watchdog/SKILL.md" 'rex-watchdog'

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
step() {  # step <file> [VAR=value...]; sets $out, $rc
  local r=0 f="$1"; shift
  out="$(env "$@" AF_ROOT="$repo" HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_WORK_ROOT="$tmp/work" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v python3)")" /bin/bash "$repo/$f" 2>&1)" || r=$?
  rc=$r
}
statusline_of() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1]))
for k in sys.argv[2].split("."): d=d.get(k) if isinstance(d, dict) else None
print(d if d is not None else "")' "$tmp/home/.claude/settings.json" "$1"; }
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
  check "$file: user settings keep the model"          [ "$(statusline_of model)" = opus ]
  check "$file: adds the minimal statusline"           [ "$(statusline_of statusLine.command)" = "sh \"$repo/claude/statusline.sh\"" ]
  check "$file: no statusline manual step"             lacks "$tmp/af/state/manual-steps.md" "statusline"
  step "$file"
  check "$file: a second run exits 0"                  [ "$rc" = 0 ]
  check "$file: a second run adds no hook"             [ "$(hooks_in "$tmp/work/p1/.claude/settings.local.json")" = 1 ]
  check "$file: a second run adds no exclude line"     [ "$(grep -c handoff-session-context "$tmp/work/p1/.git/info/exclude")" = 1 ]
  rm -rf "$tmp"

  # a statusline of the owner's own is left alone; the manual step names the record line
  setup
  printf '{\n  "statusLine": {"type": "command", "command": "sh mine.sh"}\n}\n' > "$tmp/home/.claude/settings.json"
  step "$file"
  check "$file: foreign statusline: exits 0"           [ "$rc" = 0 ]
  check "$file: foreign statusline: left alone"        [ "$(statusline_of statusLine.command)" = "sh mine.sh" ]
  check "$file: foreign statusline: manual step"       holds "$tmp/af/state/manual-steps.md" "context.py record"
  rm -rf "$tmp"

  # dry-run: settings.json is not touched
  setup
  step "$file" AF_DRY_RUN=1
  check "$file: dry-run: settings.json unchanged"      [ "$(cat "$tmp/home/.claude/settings.json")" = "$(printf '{\n  "model": "opus"\n}')" ]
  check "$file: dry-run: prints the statusline plan"   grep -q 'dry-run.*install-statusline' <<<"$out"
  rm -rf "$tmp"
done

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
