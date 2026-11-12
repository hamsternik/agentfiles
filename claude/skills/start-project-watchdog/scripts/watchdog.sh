#!/bin/bash
# Mechanical steps of the start-project-watchdog skill. macOS /bin/bash 3.2, no Homebrew tools.
#   watchdog.sh init <project dir>              make .claude/docs/prompts/<project>-watchdog.md and .claude/docs/decisions/queue.md (never overwrite)
#   watchdog.sh next-id <queue file>            print the next free D-id (highest D number in all table rows + 1)
#   watchdog.sh start-line <project dir> <model> [--owner-said-fable]
#                                               print the title and the start line; refuse Fable without the owner's word
#   watchdog.sh public <project dir>            print public, private or unknown (GitHub visibility of the repo)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
templates="$here/../templates"

die() { printf 'watchdog.sh: %s\n' "$*" >&2; exit 1; }
usage() { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 1; }

project_dir() {  # project_dir <dir>: absolute path of a git repo, or die
  [[ -n "${1:-}" ]] || die "missing <project dir>"
  [[ -d "$1" ]] || die "no such folder: $1"
  local abs
  abs="$(cd "$1" && pwd)"
  git -C "$abs" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repo: $abs"
  printf '%s\n' "$abs"
}

render() {  # render <template> <target> <project>: write once, never overwrite
  local src="$1" dst="$2" name="$3" content
  if [[ -e "$dst" ]]; then
    printf 'kept     %s\n' "$dst"
    return 0
  fi
  content="$(cat "$src")"
  content="${content//\{\{PROJECT\}\}/$name}"
  content="${content//\{\{DATE\}\}/$(date -u +%Y-%m-%d)}"
  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" > "$dst"
  printf 'created  %s\n' "$dst"
}

cmd_init() {
  local dir name
  dir="$(project_dir "${1:-}")"
  name="$(basename "$dir")"
  render "$templates/project-watchdog.md" "$dir/.claude/docs/prompts/$name-watchdog.md" "$name"
  render "$templates/queue.md" "$dir/.claude/docs/decisions/queue.md" "$name"
}

cmd_next_id() {
  local file="${1:-}" max
  [[ -n "$file" ]] || die "missing <queue file>"
  [[ -f "$file" ]] || die "no such file: $file"
  # Every D-id in a table row counts (id, ref and mentions): a higher number is safe, a reused one is not.
  max="$(grep '^|' "$file" | grep -oE '(^|[^A-Za-z0-9])D[0-9]+' | grep -oE '[0-9]+' \
    | sed 's/^0*//; s/^$/0/' | sort -n | tail -1 || true)"
  printf 'D%02d\n' "$(( ${max:-0} + 1 ))"
}

cmd_start_line() {
  local dir name model="${2:-}" fable_ok=0 note=""
  dir="$(project_dir "${1:-}")"
  [[ -n "$model" ]] || die "missing <model> (Opus or Sonnet; Fable only on the owner's word)"
  [[ "${3:-}" == --owner-said-fable ]] && fable_ok=1
  if printf '%s' "$model" | grep -qi fable; then
    if [[ "$fable_ok" != 1 ]]; then
      printf 'watchdog.sh: no Fable by default; pass --owner-said-fable only on the owner'"'"'s word\n' >&2
      exit 2
    fi
    note=" (Fable on the owner's word)"
  fi
  name="$(basename "$dir")"
  printf 'Title: %s (watchdog)\n' "$name"
  printf 'Folder: %s\n' "$dir"
  printf 'Start line: Run .claude/docs/prompts/%s-watchdog.md. Model: %s%s.\n' "$name" "$model" "$note"
}

cmd_public() {
  local dir vis
  dir="$(project_dir "${1:-}")"
  if ! command -v gh >/dev/null 2>&1; then echo unknown; return 0; fi
  vis="$(cd "$dir" && gh repo view --json visibility -q .visibility 2>/dev/null)" || { echo unknown; return 0; }
  case "$(printf '%s' "$vis" | tr '[:upper:]' '[:lower:]')" in
    public) echo public ;;
    private|internal) echo private ;;
    *) echo unknown ;;
  esac
}

case "${1:-}" in
  init) shift; cmd_init "$@" ;;
  next-id) shift; cmd_next_id "$@" ;;
  start-line) shift; cmd_start_line "$@" ;;
  public) shift; cmd_public "$@" ;;
  *) usage ;;
esac
