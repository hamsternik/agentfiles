#!/usr/bin/env bash
# af slot / af worktree / af health under macOS /bin/bash 3.2 (PATH without
# Homebrew, so `#!/usr/bin/env bash` resolves to /bin/bash).
# Run: make test
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
tmp="$(cd "$(mktemp -d)" && pwd -P)"   # real path: git reports /private/var, not /var
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/home" "$tmp/local" "$tmp/af"
cat > "$tmp/local/machine.env" <<EOF
AF_PERSONAL_DIR="$tmp/personal"
AF_WORK_DIR="$tmp/work"
AF_US_GATEWAY_ENABLED=0
AF_NOTIFY_CMD="$tmp/notify.sh"
EOF
printf 'AF_MAX_XCODEBUILD=1\nAF_MAX_WORKTREES=2\nAF_MEM_FREE_WARN_PCT=0\nAF_SWAP_WARN_MB=99999999\n' > "$tmp/local/limits.env"
cat > "$tmp/notify.sh" <<EOF
#!/bin/bash
echo "\$1" >> "$tmp/notified"
EOF
chmod +x "$tmp/notify.sh"

af() {
  HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
    "$repo/bin/af" "$@"
}
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; fails=$((fails + 1)); fi
}
rc() { local r=0; "$@" >/dev/null 2>&1 || r=$?; echo "$r"; }
slots() { find "$tmp/af/state/slots/$1" -name '*.lock' 2>/dev/null | wc -l | tr -d ' '; }

bash32()      { [[ "$(PATH=/usr/bin:/bin env bash --version)" == *"version 3.2"* ]]; }
status_full() { [[ "$(af slot status 2>/dev/null)" == *"xcodebuild  1/1"* ]]; }

check "env bash is 3.2 here"            bash32

# --- af slot -----------------------------------------------------------------
check "slot: runs the command"           [ "$(af slot browser -- echo hi 2>/dev/null)" = hi ]
check "slot: released afterwards"        [ "$(slots browser)" = 0 ]
check "slot: exit code passes through"   [ "$(rc af slot browser -- sh -c 'exit 7')" = 7 ]
af slot xcodebuild -- sleep 4 >/dev/null 2>&1 &
bg=$!; sleep 1
check "slot: full -> times out"          [ "$(rc af slot xcodebuild --wait 1 -- true)" = 1 ]
check "slot: status shows 1/1"           status_full
check "slot: queued run gets the slot"   [ "$(rc af slot xcodebuild --wait 15 -- true)" = 0 ]
wait "$bg" || true
mkdir -p "$tmp/af/state/slots/xcodebuild/0.lock"; echo 999999 > "$tmp/af/state/slots/xcodebuild/0.lock/pid"
check "slot: stale slot reclaimed"       [ "$(rc af slot xcodebuild --wait 3 -- true)" = 0 ]
touch "$tmp/af/state/disk-blocked"
check "slot: disk block refuses builds"  [ "$(rc af slot xcodebuild -- true)" = 1 ]
check "slot: disk block allows browser"  [ "$(rc af slot browser -- true)" = 0 ]
rm -f "$tmp/af/state/disk-blocked"

# --- af worktree -------------------------------------------------------------
# Worktrees go next to their repo, in <group folder>/.worktrees/<repo>/<branch>.
mkrepo() { mkdir -p "$1" && git -C "$1" init -q && git -C "$1" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init; }
mkrepo "$tmp/personal/repo"; mkrepo "$tmp/work/wrepo"
check "worktree: personal one in _hamsternik-style group dir" \
                                         [ "$(af worktree new "$tmp/personal/repo" feat/a 2>/dev/null)" = "$tmp/personal/.worktrees/repo/feat-a" ]
check "worktree: work one in the work group dir" \
                                         [ "$(af worktree new "$tmp/work/wrepo" feat/b 2>/dev/null)" = "$tmp/work/.worktrees/wrepo/feat-b" ]
check "worktree: cap counts both groups (max 2)" [ "$(rc af worktree new "$tmp/personal/repo" feat/c)" = 1 ]
check "worktree: list shows both"        [ "$(af worktree list 2>/dev/null | wc -l | tr -d ' ')" = 2 ]
check "worktree: .derived/ excluded"     grep -qx '.derived/' "$tmp/personal/repo/.git/info/exclude"
af worktree rm "$tmp/personal/.worktrees/repo/feat-a" >/dev/null 2>&1 || true
check "worktree: rm frees a place"       [ "$(rc af worktree new "$tmp/personal/repo" feat/c)" = 0 ]
check "worktree: nothing in the home folder" [ -z "$(ls -A "$tmp/home")" ]

# --- af health ---------------------------------------------------------------
printf 'AF_DISK_WARN_PCT=0\nAF_DISK_BLOCK_PCT=0\n' >> "$tmp/local/limits.env"
check "health: problem -> exit 1"        [ "$(rc af health)" = 1 ]
check "health: disk block flag set"      [ -f "$tmp/af/state/disk-blocked" ]
check "health: notified once"            [ "$(wc -l < "$tmp/notified" | tr -d ' ')" = 1 ]
af health >/dev/null 2>&1 || true
check "health: no repeat notification"   [ "$(wc -l < "$tmp/notified" | tr -d ' ')" = 1 ]
printf 'AF_DISK_WARN_PCT=101\nAF_DISK_BLOCK_PCT=101\n' >> "$tmp/local/limits.env"
check "health: recovered -> exit 0"      [ "$(rc af health)" = 0 ]
check "health: block flag cleared"       [ ! -f "$tmp/af/state/disk-blocked" ]
check "health: recovery notified"        grep -q '^\[.*\] recovered:' "$tmp/notified"
check "health: one log line per run"     [ "$(wc -l < "$tmp/af/logs/health.log" | tr -d ' ')" = 3 ]

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
