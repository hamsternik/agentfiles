#!/usr/bin/env bash
# Shared helpers. Source this file; do not execute it.
# shellcheck disable=SC2034

AF_ROOT="${AF_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
AF_LOCAL="${AF_LOCAL:-$AF_ROOT/local}"
AF_HOME="${AF_HOME:-$HOME/.agentfiles}"          # runtime state, outside the repo
AF_STATE="$AF_HOME/state"
AF_LOGS="$AF_HOME/logs"
AF_DRY_RUN="${AF_DRY_RUN:-0}"

if [[ -t 2 ]]; then
  _c_info=$'\033[34m'; _c_ok=$'\033[32m'; _c_warn=$'\033[33m'; _c_err=$'\033[31m'; _c_off=$'\033[0m'
else
  _c_info=""; _c_ok=""; _c_warn=""; _c_err=""; _c_off=""
fi

log()  { printf '%s==>%s %s\n' "$_c_info" "$_c_off" "$*" >&2; }
ok()   { printf '%s ok%s %s\n'  "$_c_ok"   "$_c_off" "$*" >&2; }
warn() { printf '%s !!%s %s\n'  "$_c_warn" "$_c_off" "$*" >&2; }
die()  { printf '%s xx%s %s\n'  "$_c_err"  "$_c_off" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# Manual steps are collected and printed at the end of bootstrap.
manual() {
  mkdir -p "$AF_STATE"
  printf -- '- %s\n' "$*" >> "$AF_STATE/manual-steps.md"
  warn "MANUAL: $*"
}

# Run a command, or just print it in dry-run mode.
run() {
  if [[ "$AF_DRY_RUN" == 1 ]]; then
    printf '   [dry-run] %s\n' "$*" >&2
  else
    "$@"
  fi
}

is_macos() { [[ "$(uname -s)" == "Darwin" ]]; }
require_macos() { is_macos || die "This step only runs on macOS."; }

# Load config: repo defaults first, then machine-local overrides.
af_load_config() {
  # shellcheck source=/dev/null
  [[ -f "$AF_ROOT/config/limits.env" ]] && . "$AF_ROOT/config/limits.env"
  # shellcheck source=/dev/null
  [[ -f "$AF_LOCAL/machine.env" ]] && . "$AF_LOCAL/machine.env"
  # shellcheck source=/dev/null
  [[ -f "$AF_LOCAL/limits.env" ]] && . "$AF_LOCAL/limits.env"
  mkdir -p "$AF_STATE" "$AF_LOGS"
}

# Render a template by replacing {{VAR}} with the value of $VAR.
render_template() {
  local src="$1" dst="$2" content var
  content="$(cat "$src")"
  for var in $(grep -o '{{[A-Z_][A-Z0-9_]*}}' "$src" | sort -u | tr -d '{}'); do
    [[ -n "${!var+x}" ]] || die "Template $src needs \$$var"
    content="${content//\{\{$var\}\}/${!var}}"
  done
  run mkdir -p "$(dirname "$dst")"
  if [[ "$AF_DRY_RUN" == 1 ]]; then
    printf '   [dry-run] render %s -> %s\n' "$src" "$dst" >&2
  else
    printf '%s\n' "$content" > "$dst"
  fi
}
