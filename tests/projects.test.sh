#!/usr/bin/env bash
# Projects go to their group folder: `group: work` -> AF_WORK_DIR (~/Developer/_work),
# `group: personal` or no group -> AF_PERSONAL_DIR (~/Developer/_hamsternik).
# af projects sync (stubbed git) and af job (a real manifest) must use that folder.
# Needs yq (Homebrew); skipped without it. Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
yq_bin="$(command -v yq || true)"
[[ -n "$yq_bin" ]] || { echo "skip projects test: yq not installed"; exit 0; }
fails=0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/local" "$tmp/home" "$tmp/af"
: > "$tmp/calls"
cat > "$tmp/local/machine.env" <<EOF
AF_PERSONAL_DIR="$tmp/personal"
AF_WORK_DIR="$tmp/work"
AF_US_GATEWAY_ENABLED=0
EOF
cat > "$tmp/local/projects.yaml" <<'EOF'
projects:
  - name: mine
    repo: git@github.com:me/mine.git
    group: personal
    enabled: true
  - name: crawler
    repo: git@github-work:org/crawler.git
    group: work
    enabled: true
  - name: nogroup
    repo: git@github.com:me/nogroup.git
    enabled: true
  - name: off
    repo: git@github.com:me/off.git
    group: work
    enabled: false
EOF
cat > "$tmp/bin/git" <<EOF
#!/bin/bash
echo "git \$*" >> "$tmp/calls"
EOF
cat > "$tmp/bin/uname" <<'EOF'
#!/bin/bash
if [[ "$1" == -m ]]; then echo arm64; else echo Darwin; fi
EOF
chmod +x "$tmp/bin/"*

af() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" \
    PATH="$tmp/bin:$(dirname "$yq_bin"):/usr/bin:/bin:/usr/sbin:/sbin" "$repo/bin/af" "$@" >"$tmp/out" 2>&1 \
    || echo "af exited $?" >> "$tmp/out"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; sed 's/^/     /' "$tmp/out" "$tmp/calls"; fails=$((fails + 1)); fi
}
called()     { grep -qF -- "$1" "$tmp/calls"; }
not_called() { ! grep -qF -- "$1" "$tmp/calls"; }

af projects sync
check "work project cloned into AF_WORK_DIR"         called "git clone git@github-work:org/crawler.git $tmp/work/crawler"
check "personal project cloned into AF_PERSONAL_DIR" called "git clone git@github.com:me/mine.git $tmp/personal/mine"
check "no group -> personal"                         called "git clone git@github.com:me/nogroup.git $tmp/personal/nogroup"
check "disabled project not cloned"                  not_called "off.git"

mkdir -p "$tmp/work/crawler/.agent"
cat > "$tmp/work/crawler/.agent/project.yaml" <<'EOF'
needs: {us_gateway: false, browser: false}
jobs:
  - name: hello
    command: "pwd > ran.txt"
EOF
af job crawler hello
check "af job runs in the work group folder"         [ "$(cat "$tmp/work/crawler/ran.txt" 2>/dev/null)" = "$tmp/work/crawler" ]

printf 'projects:\n  - name: bad\n    repo: x\n    group: hobby\n    enabled: true\n' > "$tmp/local/projects.yaml"
af projects sync
check "unknown group -> clear error"                 grep -q "Unknown group 'hobby'" "$tmp/out"
check "nothing in the home folder"                   [ -z "$(ls -A "$tmp/home")" ]

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
