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
# A dry-run only prints them.
manual() {
  if [[ "$AF_DRY_RUN" != 1 ]]; then
    mkdir -p "$AF_STATE"
    printf -- '- %s\n' "$*" >> "$AF_STATE/manual-steps.md"
  fi
  warn "MANUAL: $*"
}

# A precondition that stops a real run. A dry-run warns and goes on, so it
# shows everything that would happen (and every missing precondition).
die_or_warn() {
  if [[ "$AF_DRY_RUN" == 1 ]]; then warn "[dry-run] would stop here: $*"; else die "$*"; fi
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

# version_ge 2.10.1 2.9 -> true. Numeric dotted versions; bash 3.2 safe.
version_ge() {
  local IFS=. i a b
  read -r -a a <<<"$1"; read -r -a b <<<"$2"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    (( 10#${a[i]:-0} > 10#${b[i]:-0} )) && return 0
    (( 10#${a[i]:-0} < 10#${b[i]:-0} )) && return 1
  done
  return 0
}

# A Sharing service is on: its launchd override is "enabled", or its port answers.
# No sudo needed (systemsetup needs Full Disk Access and exits 0 when it refuses).
service_on() {  # service_on <launchd label> <port>
  launchctl print-disabled system 2>/dev/null | grep -q "\"$1\" => enabled" \
    || nc -z -G 2 127.0.0.1 "$2" 2>/dev/null
}
require_macos() { is_macos || die "This step only runs on macOS."; }

# Load config: repo defaults first, then machine-local overrides.
af_load_config() {
  # shellcheck source=/dev/null
  [[ -f "$AF_ROOT/config/limits.env" ]] && . "$AF_ROOT/config/limits.env"
  # shellcheck source=/dev/null
  [[ -f "$AF_ROOT/config/versions.env" ]] && . "$AF_ROOT/config/versions.env"
  # shellcheck source=/dev/null
  [[ -f "$AF_LOCAL/machine.env" ]] && . "$AF_LOCAL/machine.env"
  # shellcheck source=/dev/null
  [[ -f "$AF_LOCAL/limits.env" ]] && . "$AF_LOCAL/limits.env"
  [[ "$AF_DRY_RUN" == 1 ]] || mkdir -p "$AF_STATE" "$AF_LOGS"
}

# (Re)load a LaunchAgent in the GUI session. Without a GUI login (e.g. over SSH
# before the FileVault unlock) gui/<uid> does not exist; launchd loads the plist
# from ~/Library/LaunchAgents at the next login anyway. After a bootout the job
# stays visible for a moment, and a bootstrap meanwhile fails with error 5.
load_launch_agent() {  # load_launch_agent <label> <plist>
  local label="$1" plist="$2" uid _
  uid="$(id -u)"
  if ! launchctl print "gui/$uid" >/dev/null 2>&1; then
    warn "No GUI session: $label loads at the next login."
    return 0
  fi
  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    run launchctl bootout "gui/$uid/$label" || true
    if [[ "$AF_DRY_RUN" != 1 ]]; then
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        launchctl print "gui/$uid/$label" >/dev/null 2>&1 || break
        sleep 0.5
      done
    fi
  fi
  run launchctl enable "gui/$uid/$label"
  run launchctl bootstrap "gui/$uid" "$plist" \
    || { sleep 1; run launchctl bootstrap "gui/$uid" "$plist"; }
  [[ "$AF_DRY_RUN" == 1 ]] || ok "loaded $label"
}

# Casks whose app was installed by hand (present in /Applications, unknown to
# Homebrew) make `brew bundle` stop with "already an App". Adopt them first.
adopt_casks() {  # adopt_casks <Brewfile...>
  local apps="${AF_APPLICATIONS_DIR:-/Applications}" f cask app
  have brew || return 0    # fresh Mac in a dry-run: Homebrew not installed yet
  for f in "$@"; do
    # brew gets </dev/null so it cannot eat the list on stdin.
    while IFS= read -r cask; do
      brew list --cask "$cask" </dev/null >/dev/null 2>&1 && continue
      app="$(brew info --cask --json=v2 "$cask" </dev/null 2>/dev/null \
        | jq -r '[.casks[0].artifacts[]? | .app? // empty | .[0] | strings] | first // empty' || true)"
      if [[ -n "$app" && -d "$apps/$app" ]]; then
        log "adopting hand-installed $app into Homebrew (cask $cask)"
        run brew install --cask --adopt "$cask" </dev/null
      fi
    done < <(grep -oE '^cask "[^"]+"' "$f" | cut -d'"' -f2)
  done
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

# Link <src> to <target> unless something else already lives at <target>.
link_ours() {  # link_ours <src> <target>
  local src="$1" target="$2"
  if [[ ! -e "$target" && ! -L "$target" ]]; then
    run ln -s "$src" "$target"
    [[ "$AF_DRY_RUN" == 1 ]] || ok "Linked $target -> $src"
  elif [[ "$(readlink "$target" 2>/dev/null)" == "$src" ]]; then
    ok "$target already linked"
  else
    warn "$target exists and is not ours; leaving it."
  fi
}

# Claude Inbox on this machine: the triage-inbox skill, ~/.claude/inbox and an
# `af` link there, so the skill finds `af inbox` without PATH (docs/inbox.md).
install_inbox() {
  local skills="$HOME/.claude/skills" box="$HOME/.claude/inbox"
  run mkdir -p "$skills" "$box"
  link_ours "$AF_ROOT/claude/skills/triage-inbox" "$skills/triage-inbox"
  link_ours "$AF_ROOT/bin/af" "$box/af"
  if [[ ! -s "$box/url" ]]; then
    manual "Claude Inbox: set the page address on this machine: ~/.claude/inbox/af inbox url <https://claude.ai/artifact/...> (docs/inbox.md)."
  fi
}
