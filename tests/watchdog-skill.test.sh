#!/usr/bin/env bash
# The watchdog skill: its Python tests pass, SKILL.md front matter matches the
# folder and names every CLI command, rules.md holds every watchdog lesson, and
# the skill folder stays generic (no session ids, no home paths, no old names).
# Use case 25 of PLAN-watchdog-skill.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo/claude/skills/watchdog"
fails=0

check() {  # check <name> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
holds() { grep -qF -- "$2" "$1" 2>/dev/null; }
lacks() { ! grep -rqE --exclude-dir=__pycache__ --exclude-dir=tests -- "$2" "$1" 2>/dev/null; }

check "Python tests pass"                       env -u CLAUDECODE python3 -m unittest discover -s "$skill/tests" -q
check "SKILL.md exists"                         [ -f "$skill/SKILL.md" ]
check "rules.md exists"                         [ -f "$skill/rules.md" ]
check "front matter starts the file"            [ "$(head -1 "$skill/SKILL.md" 2>/dev/null)" = "---" ]
check "front matter name = folder name"         holds "$skill/SKILL.md" "name: watchdog"
check "front matter has a description"          grep -qE '^description: .{80,}' "$skill/SKILL.md"
check "SKILL.md points to rules.md"             holds "$skill/SKILL.md" "rules.md"
check "watchdog.py is executable"               [ -x "$skill/scripts/watchdog.py" ]
# shellcheck disable=SC2016  # literal text in SKILL.md, not expanded
check "SKILL.md sets W"                         holds "$skill/SKILL.md" 'W=~/.claude/skills/watchdog/scripts/watchdog.py'
# shellcheck disable=SC2016
for cmd in '$W init' '$W public' '$W start' '$W status' '$W handoff' '$W ready' '$W retire' '$W restore' '$W whatsup' \
  '$W queue add' '$W queue list' '$W queue decide' '$W queue default' '$W queue close' '$W queue ref' '$W guard' '$W help'; do
  check "SKILL.md names $cmd"                   holds "$skill/SKILL.md" "$cmd"
done
for fe in "--frontend rex" "--frontend desktop" "--dry-run" "detach_session" "start_session"; do
  check "SKILL.md names $fe"                    holds "$skill/SKILL.md" "$fe"
done

# One anchor per lesson of the watchdog, plus the org rules.
for anchor in \
  "AskUserQuestion" \
  "2 h" \
  "never a default" \
  "deletion" \
  "queue add" \
  "queue decide" \
  "queue default" \
  "ScheduleWakeup" \
  "CronCreate" \
  "one line per milestone" \
  "each id with" \
  "The watchdog chat is an inbox" \
  "answer in your own window" \
  "Check before passing on" \
  "No polling" \
  "40 %" \
  "watchdog-<machine>" \
  "names the model" \
  "No Fable by default" \
  "master or slave" \
  "credential cache" \
  "push only on the owner's word" \
  "triage-inbox" \
  "Bulk AI jobs" \
  "Deleting files" \
  "HTML reports" \
  "Obsolete documents" \
  "ASD-STE100"; do
  check "rules.md: $anchor"                     holds "$skill/rules.md" "$anchor"
done

# Row titles (queue-titles prompt, use cases 20-21): rule 2 asks for them; every documented add has a title.
check "rules.md: D-id with its title"           holds "$skill/rules.md" "write each D-id with its title"
check "rules.md: queue ref"                     holds "$skill/rules.md" "queue ref"
check "rules.md: queue add has --title"         holds "$skill/rules.md" "queue add --title"
check "SKILL.md: queue add has --title"         holds "$skill/SKILL.md" "queue add --title"
check "queue template names queue ref"          holds "$skill/templates/queue.md" "queue ref"

# Rule 1 against inline work (gaps G3, G4, G5). The phrases may wrap: compare them in one line, inside section 1.
rule1() {
  sed -n '/^## 1\./,/^## 2\./p' "$skill/rules.md" | tr '\n' ' ' | tr -s ' ' | grep -qF -- "$1"
}
for anchor in \
  "facts already in context" \
  "at most ~3 read-only commands" \
  "no file writes" \
  "scope and outcome fixed" \
  "recon, spike, research, pilot, plan, TDD" \
  "goal can change" \
  "When a follow-up turns an inline answer into work, stop and route the work with the context so far" \
  "In a watchdog, rule 1 overrides the working-session rules of the global and project rules files" \
  "inline work, test code, investigation, artifacts" \
  "the routed session follows them"; do
  check "rules.md rule 1: $anchor"              rule1 "$anchor"
done

check "no session id in the skill"              lacks "$skill" '(local_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-'
check "no home path in the skill"               lacks "$skill" '/Users/'
check "no old 500 k limit"                      lacks "$skill" '500 k'
check "no start-project-watchdog"               lacks "$skill" 'start-project-watchdog'
check "no watchdog.sh (SPW)"                    lacks "$skill" '(^|[^-])watchdog\.sh'
check "no owner's name"                         lacks "$skill" 'Nikita'
# Agent-specific project files live in .claude/docs/, not in the root docs/ (owner, 2026-11-12).
check "project part lives in .claude/docs"      holds "$skill/SKILL.md" ".claude/docs/prompts/<project>-watchdog.md"

# 30. No tracked file names the old skill or the old CLI path, except the removal code, its tests and the plans (history).
old_names='start-project-watchdog|handoff-session-context/scripts/watchdog\.py'
stale="$(git -C "$repo" grep -lE "$old_names" -- . ':!lib/common.sh' ':!tests/watchdog-step.test.sh' \
  ':!tests/watchdog-skill.test.sh' ':!docs/plans/' 2>/dev/null || true)"
check "no tracked file names the old names (${stale:-none})" [ -z "$stale" ]

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
