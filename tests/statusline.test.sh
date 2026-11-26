#!/usr/bin/env bash
# claude/statusline.sh: the Claude Code statusline of every machine (installed by
# install_statusline into ~/.claude/settings.json). The directory, then the
# watchdog part from context.py statusline; it records the window size.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/claude/statusline.sh"
fails=0
check() {  # check <name> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (${out:-})"; fails=$((fails + 1)); fi
}
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
lacks() { ! grep -q -- "$1" "$2"; }
plain() { sed $'s/\033\\[[0-9;]*m//g'; }
line() {  # line <cwd> <pct>; sets $out (colours removed)
  out="$(printf '{"session_id":"abcdef1234567890","workspace":{"current_dir":"%s"},"model":{"display_name":"Opus 5.5"},"context_window":{"context_window_size":1000000,"used_percentage":%s}}' "$1" "$2" \
    | HOME="$tmp/home" HANDOFF_CACHE_DIR="$tmp/cache" PATH="/usr/bin:/bin" sh "$script" 2>&1 | plain)"
}

check "script exists"                     [ -f "$script" ]
line "$tmp/home/Developer/x" 12
# shellcheck disable=SC2088  # the expected display text, not a path
check "home shown as ~, then the watchdog part" [ "$out" = "~/Developer/x Opus 5.5 #abcdef12 ctx 12%" ]
check "records the window size"           [ -f "$tmp/cache/abcdef1234567890.json" ]
line "$tmp/homework" 12
check "a sibling of home is not shortened" [ "$out" = "$tmp/homework Opus 5.5 #abcdef12 ctx 12%" ]
line "/opt" 42
check "marks the hand-off"                [ "$out" = "/opt Opus 5.5 #abcdef12 ctx 42% HAND OFF" ]
out="$(printf 'garbage' | HOME="$tmp/home" HANDOFF_CACHE_DIR="$tmp/cache" PATH="/usr/bin:/bin" sh "$script" 2>&1 | plain)"
check "bad input prints no error"         [ "$(printf '%s' "$out" | tr -d ' ')" = "" ]
check "no home path in the script"        lacks /Users/ "$script"

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
