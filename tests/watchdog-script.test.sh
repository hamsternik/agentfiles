#!/usr/bin/env bash
# shellcheck disable=SC2181,SC2319  # checks read $? of the line before, on purpose
# Tests for claude/skills/start-project-watchdog/scripts/watchdog.sh:
# init (never overwrites), next-id (never reuses a D-id), start-line (no Fable
# by default), public (repo visibility through gh). Temp folders, stub gh.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail   # no -e: checks read $? of failing commands
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$repo/claude/skills/start-project-watchdog/scripts/watchdog.sh"
fails=0

check() {  # check <name> <cond-exit-code>
  if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1 (rc=$rc: $out)"; fails=$((fails + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; }

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/proj/myproj"
  git -C "$tmp/proj/myproj" init -q
}

wd() {  # wd <args...>; sets $out, $rc
  rc=0
  out="$(PATH="$tmp/bin:/usr/bin:/bin" /bin/bash "$script" "$@" 2>&1)" || rc=$?
}

sum() { /sbin/md5 -q "$1"; }

# --- init -------------------------------------------------------------------
setup
p="$tmp/proj/myproj"
wd init "$p"
check "init: exits 0"                           "$rc"
[[ -f "$p/docs/prompts/myproj-watchdog.md" ]];  check "init: makes the project part" $?
[[ -f "$p/docs/decisions/queue.md" ]];          check "init: makes the decision queue" $?
has "$out" "created";                           check "init: says created" $?
grep -q '{{PROJECT}}' "$p/docs/prompts/myproj-watchdog.md"; [[ $? != 0 ]]
check "init: fills the project name"            $?
grep -qF 'myproj (watchdog)' "$p/docs/prompts/myproj-watchdog.md"; check "init: the part names the title" $?
echo "owner text" >> "$p/docs/prompts/myproj-watchdog.md"
a="$(sum "$p/docs/prompts/myproj-watchdog.md")"; b="$(sum "$p/docs/decisions/queue.md")"
wd init "$p"
check "init again: exits 0"                     "$rc"
has "$out" "kept";                              check "init again: says kept" $?
[[ "$(sum "$p/docs/prompts/myproj-watchdog.md")" == "$a" ]]; check "init again: project part unchanged" $?
[[ "$(sum "$p/docs/decisions/queue.md")" == "$b" ]];         check "init again: queue unchanged" $?
mkdir -p "$tmp/nogit"
wd init "$tmp/nogit"
[[ "$rc" != 0 ]];                               check "init: refuses a folder that is not a git repo" $?
[[ ! -e "$tmp/nogit/docs" ]];                   check "init: ... and writes nothing there" $?
rm -rf "$tmp"

# --- next-id ----------------------------------------------------------------
setup
p="$tmp/proj/myproj"
wd init "$p" >/dev/null
wd next-id "$p/docs/decisions/queue.md"
[[ "$out" == D01 ]];                            check "next-id: empty queue gives D01" $?
q="$tmp/queue.md"
cat > "$q" <<'MD'
| id | opened | item | rows / scope | default if no answer | owner | status |
|---|---|---|---|---|---|---|
| D01 | 2026-11-01 | a | x | y | owner | open |
| D07 | 2026-11-02 | b, see D05 | x | y | owner | open |

## Closed

| id | ref | opened | item | status |
|---|---|---|---|---|
| C02 | D43 | 2026-11-03 | c | decided 2026-11-04: yes |
MD
wd next-id "$q"
[[ "$out" == D44 ]];                            check "next-id: highest D or ref + 1 (D44)" $?
wd next-id "$tmp/missing.md"
[[ "$rc" != 0 ]];                               check "next-id: a missing file fails" $?
rm -rf "$tmp"

# --- start-line -------------------------------------------------------------
setup
p="$tmp/proj/myproj"
wd start-line "$p" opus
check "start-line: exits 0"                     "$rc"
has "$out" "myproj (watchdog)";                 check "start-line: names the title" $?
has "$out" "Run docs/prompts/myproj-watchdog.md"; check "start-line: names the prompt file" $?
has "$out" "Model: opus";                       check "start-line: names the model" $?
wd start-line "$p" Claude-Fable-5
[[ "$rc" == 2 ]];                               check "start-line: refuses Fable (exit 2)" $?
wd start-line "$p" fable --owner-said-fable
check "start-line: Fable on the owner's word"   "$rc"
has "$out" "owner's word";                      check "start-line: ... says so in the line" $?
wd start-line "$p"
[[ "$rc" != 0 ]];                               check "start-line: a missing model fails" $?
rm -rf "$tmp"

# --- public -----------------------------------------------------------------
setup
p="$tmp/proj/myproj"
printf '#!/bin/bash\necho PUBLIC\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
wd public "$p"
[[ "$out" == public ]];                         check "public: gh PUBLIC gives public" $?
printf '#!/bin/bash\necho PRIVATE\n' > "$tmp/bin/gh"
wd public "$p"
[[ "$out" == private ]];                        check "public: gh PRIVATE gives private" $?
rm "$tmp/bin/gh"
wd public "$p"
[[ "$out" == unknown ]];                        check "public: no gh gives unknown" $?
printf '#!/bin/bash\nexit 1\n' > "$tmp/bin/gh"; chmod +x "$tmp/bin/gh"
wd public "$p"
[[ "$out" == unknown ]];                        check "public: a gh error gives unknown" $?
rm -rf "$tmp"

# --- usage ------------------------------------------------------------------
setup
wd nope
[[ "$rc" != 0 ]];                               check "an unknown command fails" $?
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
