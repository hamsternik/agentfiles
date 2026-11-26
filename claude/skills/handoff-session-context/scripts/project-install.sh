#!/bin/bash
# Per-project step of the handoff-session-context skill (called by install_project_skill in agentfiles lib/common.sh):
#   project-install.sh <project dir>   add the Stop hook to <project>/.claude/settings.local.json once
# context.py backs up the old file as settings.local.json.bak-<date>: git must not show it (local exclude).
set -euo pipefail
[[ -d "${1:-}" ]] || { echo "project-install.sh: missing <project dir>" >&2; exit 1; }
exclude="$(git -C "$1" rev-parse --path-format=absolute --git-path info/exclude 2>/dev/null || true)"
pattern='/.claude/settings.local.json.bak-*'
if [[ -n "$exclude" ]] && ! grep -qxF "$pattern" "$exclude" 2>/dev/null; then
  mkdir -p "$(dirname "$exclude")"
  printf '%s\n' "$pattern" >> "$exclude"
fi
python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/context.py" install-hook --settings "$1/.claude/settings.local.json"
