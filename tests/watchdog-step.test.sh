#!/usr/bin/env bash
# The watchdog step (master 70, slave 87) links the watchdog skill into
# ~/.claude/skills, removes the old start-project-watchdog link when it points
# into this clone, is idempotent, leaves a skill that is not ours alone, and
# changes nothing with --dry-run. Use case 26 of PLAN-watchdog-skill.
# It also adds the watchdog guard hook (PreToolUse) to each work project.
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

local_settings=".claude/settings.local.json"

work_projects() {  # three work projects ($p1, $p2 with settings, $foreign) and a folder with no git
  p1="$tmp/work/p1"; p2="$tmp/work/p2"; foreign="$tmp/work/foreign"
  mkdir -p "$p1" "$p2/.claude" "$foreign/.claude/skills/handoff-session-context" "$tmp/work/notgit"
  git -C "$p1" init -q; git -C "$p2" init -q; git -C "$foreign" init -q
  printf '{\n  "permissions": {"allow": ["Bash(ls)"]}\n}\n' > "$p2/$local_settings"
  cp "$p2/$local_settings" "$tmp/p2.original"
}
guards() {  # guards <settings file>: the number of guard hooks in it
  /usr/bin/jq '[.hooks.PreToolUse[]? | select(.matcher == "Edit|Write|NotebookEdit") | .hooks[]
    | select(.command | test("watchdog\\.py.* guard"))] | length' "$1" 2>/dev/null || echo 0
}
has_guard() { [[ "$(guards "$1/$local_settings")" == "$2" ]]; }
lacks_guard() { ! grep -q ' guard' "$1" 2>/dev/null; }
backed_up() {  # one backup holds the file as it was before the step
  local f
  for f in "$1/$local_settings".bak-*; do cmp -s "$f" "$tmp/p2.original" && return 0; done
  return 1
}
git_hides_settings() { ! git -C "$1" status --porcelain --untracked-files=all | grep -q 'settings\.local\.json'; }

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

  # the guard hook (a watchdog does no file work inline): in each work project, not at user level
  setup
  work_projects
  step "$file"
  check "$file: guard: exits 0"                  [ "$rc" = 0 ]
  check "$file: guard: a new settings file"      has_guard "$p1" 1
  check "$file: guard: an existing file"         has_guard "$p2" 1
  check "$file: guard: keeps the other settings" [ "$(/usr/bin/jq -c .permissions "$p2/$local_settings")" = '{"allow":["Bash(ls)"]}' ]
  check "$file: guard: the original is backed up" backed_up "$p2"
  check "$file: guard: with a foreign handoff skill" has_guard "$foreign" 1
  check "$file: guard: git does not show p1"     git_hides_settings "$p1"
  check "$file: guard: git does not show p2"     git_hides_settings "$p2"
  check "$file: guard: git does not show foreign" git_hides_settings "$foreign"
  check "$file: guard: no non-git folder"        [ ! -e "$tmp/work/notgit/.claude" ]
  check "$file: guard: not in the user settings" lacks_guard "$tmp/home/.claude/settings.json"
  step "$file"
  check "$file: guard: a second run exits 0"     [ "$rc" = 0 ]
  check "$file: guard: still one entry (p1)"     has_guard "$p1" 1
  check "$file: guard: still one entry (p2)"     has_guard "$p2" 1
  rm -rf "$tmp"

  setup
  work_projects
  printf '{ not json' > "$p2/$local_settings"
  step "$file"
  check "$file: guard: bad JSON: exits 0"        [ "$rc" = 0 ]
  check "$file: guard: bad JSON: file kept"      [ "$(cat "$p2/$local_settings")" = '{ not json' ]
  check "$file: guard: bad JSON: a warning"      grep -q "watchdog guard: .*$p2/.*left alone" <<<"$out"
  check "$file: guard: bad JSON: the others run" has_guard "$p1" 1
  rm -rf "$tmp"

  setup
  work_projects
  before="$(cat "$p2/$local_settings")"
  step "$file" AF_DRY_RUN=1
  check "$file: guard: dry-run: exits 0"         [ "$rc" = 0 ]
  check "$file: guard: dry-run: no new file"     [ ! -e "$p1/$local_settings" ]
  check "$file: guard: dry-run: file unchanged"  [ "$(cat "$p2/$local_settings")" = "$before" ]
  check "$file: guard: dry-run: says what"       grep -q "dry-run.*guard --install.*p1" <<<"$out"
  rm -rf "$tmp"
done

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
