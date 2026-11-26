#!/bin/sh
# Claude Code status line of every machine (agentfiles). Bold green directory,
# then in magenta what a watchdog needs: model, short session id, context %,
# HAND OFF / OVER at the hand-off limits. It also records the window size for
# the handoff-session-context skill. install_statusline (lib/common.sh) sets it
# in ~/.claude/settings.json. Claude Code sends the session JSON on stdin.

input=$(cat)
here=$(cd "$(dirname "$0")" && pwd)

cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // ""' 2>/dev/null)
info=$(printf '%s' "$input" | python3 "$here/skills/handoff-session-context/scripts/context.py" statusline 2>/dev/null)

# $HOME as ~ (display text, not a path to expand)
# shellcheck disable=SC2088
case "$cwd" in
  "$HOME") cwd='~' ;;
  "$HOME"/*) cwd='~/'"${cwd#"$HOME"/}" ;;
esac

printf '\033[1;32m%s\033[0m \033[0;35m%s\033[0m' "$cwd" "$info"
