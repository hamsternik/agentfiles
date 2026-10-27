#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../../../lib/common.sh
. "$AF_ROOT/lib/common.sh"
af_load_config

# Claude: global agent rules for this host, logins.
target="$HOME/.claude/CLAUDE.md"
src="$AF_ROOT/claude/CLAUDE.host.md"
run mkdir -p "$HOME/.claude"
if [[ ! -e "$target" ]]; then
  run ln -s "$src" "$target"
  ok "Linked $target -> $src"
elif [[ "$(readlink "$target" 2>/dev/null)" == "$src" ]]; then
  ok "$target already linked"
else
  warn "$target exists and is not ours; leaving it. Merge claude/CLAUDE.host.md by hand if wanted."
fi

have claude || warn "claude CLI not on PATH yet (open a new shell after step 20)"
manual "Sign in: run 'claude' once and log in; open the Claude desktop app and sign in."
manual "Set up remote access to Claude sessions on this host (check the current options in Claude Code / desktop docs)."
manual "GitHub: 'gh auth login' with an identity whose access is limited to the repos agents may touch."
