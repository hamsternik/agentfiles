#!/usr/bin/env bash
# agentfiles bootstrap: fresh macOS -> working agent host or master.
#
#   ./bootstrap.sh slave           # always-on agent machine
#   ./bootstrap.sh master          # the laptop you drive it from
#   ./bootstrap.sh slave --only 30 # run steps whose name starts with 30
#   ./bootstrap.sh slave --dry-run # print what would happen
#
# Every step is idempotent: re-running is safe and is how you apply changes.
set -euo pipefail

AF_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AF_ROOT
# shellcheck source=lib/common.sh
. "$AF_ROOT/lib/common.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

role="${1:-}"; [[ -n "$role" ]] || usage 1
shift
only=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --only) only="$2"; shift 2 ;;
    --dry-run) export AF_DRY_RUN=1; shift ;;
    -h|--help) usage 0 ;;
    *) die "Unknown flag: $1" ;;
  esac
done

steps_dir="$AF_ROOT/roles/$role/steps"
if [[ ! -d "$steps_dir" ]]; then
  roles=""; for d in "$AF_ROOT"/roles/*/; do roles="$roles $(basename "$d")"; done
  die "Unknown role '$role'. Available:$roles"
fi

# First run: create local/ from the examples and stop so it can be filled in.
# A dry-run writes nothing and reads the examples instead.
if [[ ! -f "$AF_LOCAL/machine.env" && "$AF_DRY_RUN" == 1 ]]; then
  warn "No local/machine.env; dry-run uses the values from local.example/."
  export AF_LOCAL="$AF_ROOT/local.example"
elif [[ ! -f "$AF_LOCAL/machine.env" ]]; then
  mkdir -p "$AF_LOCAL"
  cp -n "$AF_ROOT"/local.example/* "$AF_LOCAL"/ 2>/dev/null || true
  for f in "$AF_LOCAL"/*.example; do [[ -e "$f" ]] && mv -n "$f" "${f%.example}"; done
  die "Created $AF_LOCAL from local.example/. Fill in local/machine.env, then re-run."
fi

af_load_config
export AF_ROLE="$role"
if [[ "$AF_DRY_RUN" != 1 ]]; then
  echo "$role" > "$AF_STATE/role"
  : > "$AF_STATE/manual-steps.md"
fi

log "Bootstrapping role '$role' from $AF_ROOT"
for step in "$steps_dir"/*.sh; do
  name="$(basename "$step")"
  [[ -z "$only" || "$name" == "$only"* ]] || continue
  log "step $name"
  bash "$step" || die "Step $name failed. Fix and re-run; completed steps are safe to repeat."
done

if [[ "$AF_DRY_RUN" == 1 ]]; then
  ok "Dry-run '$role' finished. Nothing was changed; MANUAL lines above are what a real run would ask for."
  exit 0
fi
ok "Bootstrap '$role' finished."
if [[ -s "$AF_STATE/manual-steps.md" ]]; then
  warn "Manual steps still needed:"
  cat "$AF_STATE/manual-steps.md" >&2
fi
