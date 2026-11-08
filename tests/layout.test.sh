#!/usr/bin/env bash
# Layout rule: nothing of agentfiles goes directly into ~ on the master or the slave.
# Personal repos live in ~/Developer/_hamsternik/, work projects in ~/Developer/_work/,
# runtime state in the clone's .state/. Allowed in ~: what a tool needs there
# (.ssh, .claude, .config, .vim, Library, the git config files).
# Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
default() { sed -nE "s/^$1=\"?([^\"#]*)\"?.*/\1/p" "$repo/local.example/machine.env" | sed 's/ *$//'; }

check "dotfiles clone in ~/Developer/_hamsternik"   [ "$(default DOTFILES_DIR)" = "\$HOME/Developer/_hamsternik/dotfiles" ]

# Every home path in code and defaults must be a tool location or under ~/Developer.
paths="$(cd "$repo" && git grep -hoE "(\\\$HOME|\\\$\\{HOME\\}|~)/\\.?[A-Za-z_][A-Za-z0-9_.-]*" -- \
  bin lib roles bootstrap.sh config local.example services Makefile | sort -u)"
bad="$(grep -vE '/(\.ssh|\.claude|\.config|\.vim|Library|Developer|\.gitconfig(-work)?)$' <<<"$paths" || true)"
check "no other home-root path in code or defaults" [ -z "$bad" ]
[[ -z "$bad" ]] || while IFS= read -r l; do echo "     $l"; done <<<"$bad"

# ~/Developer itself only through a group folder: _hamsternik (personal) or _work.
dev="$(cd "$repo" && git grep -hoE "(\\\$HOME|~)/Developer(/[A-Za-z_.-]+)?" -- \
  bin lib roles bootstrap.sh config local.example services Makefile | sort -u)"
bad_dev="$(grep -vE '/Developer/(_hamsternik|_work)$' <<<"$dev" || true)"
check "Developer folder used only via _hamsternik or _work" [ -z "$bad_dev" ]
[[ -z "$bad_dev" ]] || while IFS= read -r l; do echo "     $l"; done <<<"$bad_dev"
check "personal group folder default"            [ "$(default AF_PERSONAL_DIR)" = "\$HOME/Developer/_hamsternik" ]
check "work group folder default"                [ "$(default AF_WORK_DIR)" = "\$HOME/Developer/_work" ]

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
