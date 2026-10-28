#!/usr/bin/env bash
# `./bootstrap.sh <role> --dry-run` must change nothing: no sudo, no writes
# outside the repo (nor local/ inside it), no installs, no opened apps.
# Every command that could change the machine is a logging stub; HOME is a
# fresh temp dir; PATH has no Homebrew. Two scenarios: a fresh Mac (no CLT,
# brew, docker, tailscale, node) and one with those tools already present.
# Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0

# Commands a dry-run may call, and only with these first arguments.
read_only='^(brew list --cask |brew info --cask |node --version|uname |jq |xcrun --sdk |DevToolsSecurity -status|launchctl print|scutil --get |fdesetup status|xcode-select -p|pmset -g|pmset -g cap|docker info|tailscale status|brew --prefix|xcodebuild -version|xcrun simctl list|security find-generic-password|ioreg )'

stub() {  # stub <name> <exit code> [stdout]
  cat > "$tmp/bin/$1" <<STUB
#!/bin/bash
echo "$1 \$*" >> "$tmp/calls"
printf '%s' "${3:-}"
exit $2
STUB
  chmod +x "$tmp/bin/$1"
}

setup() {  # setup fresh|tooled
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/home"
  : > "$tmp/calls"
  for c in sudo open orb launchctl defaults scutil systemsetup DevToolsSecurity \
           xcodes npx curl make softwareupdate fdesetup; do
    stub "$c" 0
  done
  stub security 44                       # no Keychain item
  stub pmset 0 $' SleepDisabled\t\t0\n sleep                1\n'
  stub xcodebuild 1
  stub xcrun 1
  stub uname 0 "Darwin"
  if [[ "$1" == fresh ]]; then
    stub xcode-select 2                  # no Command Line Tools
  else
    stub xcode-select 0 "/Library/Developer/CommandLineTools"
    stub brew 0
    stub docker 0
    stub tailscale 0
    stub jq 0 "host.example"
    stub node 0
    stub npx 0
  fi
  before="$(git -C "$repo" status --porcelain --ignored)"
}

run_dry() {  # run_dry <role>
  HOME="$tmp/home" PATH="$tmp/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
    /bin/bash "$repo/bootstrap.sh" "$1" --dry-run </dev/null >"$tmp/out" 2>&1 \
    || echo "bootstrap exited $?" >> "$tmp/out"
}

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"
  else echo "FAIL $what"; sed 's/^/     /' "$tmp/out"; echo "     -- calls:"; sed 's/^/     /' "$tmp/calls"; fails=$((fails + 1)); fi
}
finished()     { ! grep -q 'bootstrap exited' "$tmp/out"; }
only_reads()   { ! grep -Ev "$read_only" "$tmp/calls" | grep -q .; }
home_empty()   { [[ -z "$(find "$tmp/home" -mindepth 1 -print -quit)" ]]; }
repo_same()    { [[ "$(git -C "$repo" status --porcelain --ignored)" == "$before" ]]; }

for scenario in fresh tooled; do
  for role in slave master; do
    setup "$scenario"
    run_dry "$role"
    check "$scenario $role: dry-run finishes"           finished
    check "$scenario $role: only read-only commands run" only_reads
    check "$scenario $role: nothing written to HOME"    home_empty
    check "$scenario $role: repo unchanged (no local/)" repo_same
    rm -rf "$tmp"
  done
done

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
