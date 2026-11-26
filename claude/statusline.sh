#!/bin/sh
# Claude Code status line - derived from ~/.zshrc PROMPT style

input=$(cat)

# handoff-session-context: record the real context window (Nikita 2026-11-26)
printf '%s' "$input" | python3 "$HOME/Developer/_hamsternik/agentfiles/claude/skills/handoff-session-context/scripts/context.py" record >/dev/null 2>&1 || true

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // ""')
model=$(echo "$input" | jq -r '.model.display_name // ""')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Replace $HOME with ~ in the path
home="$HOME"
short_cwd="${cwd#$home}"
if [ "$short_cwd" != "$cwd" ]; then
  short_cwd="~$short_cwd"
fi

# Build context string if available
ctx_str=""
if [ -n "$used" ]; then
  ctx_str=" [ctx: ${used}%]"
fi

# Replicate zsh prompt style:
# Bold green directory, then model info in magenta
printf '\033[1;32m%s\033[0m \033[0;35m%s%s\033[0m' \
  "$short_cwd" \
  "$model" \
  "$ctx_str"
