#!/usr/bin/env bash
# shellcheck disable=SC2012,SC2181,SC2319  # checks read $? of the line before, on purpose
# Tests for `af sessions`: copy Claude desktop session metadata between the org
# folders of one account (a seat switch). Temp folders; fixed clock via
# AF_SESSIONS_NOW (ms).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail   # no -e: checks read $? of failing commands
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
day=86400000
now=1800000000000

check() {  # check <name> <cond-exit-code>
  if [[ "$2" == 0 ]]; then echo "ok   $1"; else echo "FAIL $1"; fails=$((fails + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1"; }

setup() {
  tmp="$(mktemp -d)"
  root="$tmp/sessions"; acct="$root/acct-1111"
  src="$acct/aaaa1111-src"; dst="$acct/bbbb2222-dst"
  projects="$tmp/projects"; runs="$tmp/runs"
  mkdir -p "$src" "$dst" "$projects/p1" "$projects/p2" "$tmp/local"
  : > "$tmp/local/machine.env"
}

sess() {  # sess <dir> <id> <cli> <cwd> <lastActivityAt> [extra-json]
  local extra="${6:-}"
  [[ -n "$extra" ]] || extra='{}'
  /usr/bin/jq -n --arg id "local_$2" --arg cli "$3" --arg cwd "$4" --argjson la "$5" \
    --argjson extra "$extra" '{sessionId:$id, cliSessionId:$cli, cwd:$cwd, originCwd:$cwd,
      createdAt:($la - 1000), lastActivityAt:$la, isArchived:false, title:("t " + $id),
      remoteMcpServersConfig:[{uuid:"src-conn",name:"Sheets"}], enabledMcpTools:{"x:y":true}} + $extra' \
    > "$1/local_$2.json"
}
transcript() { : > "$projects/$1/$2.jsonl"; }

af_s() {  # af_s <args...>; sets $out, $rc
  rc=0
  out="$(AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_SESSIONS_DIR="$root" AF_CLAUDE_PROJECTS="$projects" \
    AF_SESSIONS_RUNS="$runs" AF_SESSIONS_NOW="$now" /bin/bash "$repo/bin/af-sessions" "$@" 2>&1)" || rc=$?
}

fixture() {
  setup
  # target org: newest activity, holds the connector template
  sess "$dst" t0 cli-t0 /w/other $((now - 1000)) '{"remoteMcpServersConfig":[{"uuid":"dst-conn","name":"Sheets"}]}'
  # source org
  sess "$src" add1 cli-add1 /w/proj $((now - 2 * day)) '{"scheduledTaskId":"st","scheduledRunContinued":true}'
  transcript p1 cli-add1
  sess "$src" sub1 cli-sub1 /w/proj/sub $((now - 3 * day)); transcript p1 cli-sub1
  sess "$src" old1 cli-old1 /w/proj $((now - 20 * day)); transcript p1 cli-old1
  sess "$src" oth1 cli-oth1 /w/projX $((now - 1 * day)); transcript p1 cli-oth1
  sess "$src" arc1 cli-arc1 /w/proj $((now - 1 * day)) '{"isArchived":true}'; transcript p1 cli-arc1
  sess "$src" not1 cli-not1 /w/proj $((now - 1 * day))
  sess "$src" rep1 cli-rep1 /w/proj $((now - 1 * day)); transcript p2 cli-rep1
  sess "$dst" rep1 cli-rep1 /w/proj $((now - 5 * day)) '{"title":"old copy"}'
  sess "$src" new1 cli-new1 /w/proj $((now - 4 * day)); transcript p2 cli-new1
  sess "$dst" new1 cli-new1 /w/proj $((now - 1 * day)) '{"title":"target newer"}'
}

# --- orgs: lists both orgs, marks the newest as active -------------------------
fixture
af_s orgs
check "orgs exit 0" "$rc"
has "$out" "bbbb2222-dst" && has "$out" "aaaa1111-src"; check "orgs lists both" $?
grep -E 'bbbb2222-dst.*active' <<<"$out" >/dev/null; check "orgs marks newest org active" $?

# --- sync dry run --------------------------------------------------------------
before="$(cd "$dst" && ls | sort)"
af_s sync --to bbbb --days 10 --project /w/proj
check "dry run exit 0" "$rc"
has "$out" "add      add1"; check "dry run: recent session -> add" $?
has "$out" "add      sub1"; check "dry run: session in a sub folder -> add" $?
has "$out" "replace  rep1"; check "dry run: older target copy -> replace" $?
has "$out" "skip     new1  target-newer"; check "dry run: newer target copy -> skip" $?
has "$out" "skip     not1  no-transcript"; check "dry run: no transcript -> skip" $?
has "$out" "old1"; [[ $? != 0 ]]; check "dry run: old session not listed" $?
has "$out" "oth1"; [[ $? != 0 ]]; check "dry run: other project not listed" $?
has "$out" "arc1"; [[ $? != 0 ]]; check "dry run: archived session not listed" $?
has "$out" "dry run"; check "dry run says so" $?
[[ "$(cd "$dst" && ls | sort)" == "$before" ]]; check "dry run writes nothing" $?
[[ ! -e "$runs" ]]; check "dry run makes no run folder" $?

# --- --to defaults to the active org; --include-archived ----------------------
af_s sync --days 10 --project /w/proj --include-archived
has "$out" "add      arc1"; check "--include-archived lists archived" $?
has "$out" "bbbb2222-dst"; check "--to defaults to the active org" $?

# --- apply ---------------------------------------------------------------------
af_s sync --to bbbb --days 10 --project /w/proj --apply
check "apply exit 0" "$rc"
[[ -f "$dst/local_add1.json" && -f "$dst/local_sub1.json" ]]; check "apply adds files" $?
[[ "$(/usr/bin/jq -r '.remoteMcpServersConfig[0].uuid' "$dst/local_add1.json")" == dst-conn ]]
check "apply uses target connectors" $?
[[ "$(/usr/bin/jq -r 'has("scheduledTaskId") or has("scheduledRunContinued")' "$dst/local_add1.json")" == false ]]
check "apply drops scheduled-task fields" $?
[[ "$(/usr/bin/jq -r '.enabledMcpTools["x:y"]' "$dst/local_add1.json")" == true ]]
check "apply keeps other fields" $?
[[ "$(/usr/bin/jq -r .title "$dst/local_rep1.json")" == "t local_rep1" ]]; check "apply replaces older copy" $?
[[ "$(/usr/bin/jq -r .title "$dst/local_new1.json")" == "target newer" ]]; check "apply keeps newer target" $?
[[ ! -e "$dst/local_not1.json" ]]; check "apply skips no-transcript" $?
[[ -f "$src/local_add1.json" ]]; check "apply leaves the source file" $?
run="$(ls -d "$runs"/*/ | head -1)"
[[ -f "$run/manifest.tsv" && "$(wc -l < "$run/manifest.tsv" | tr -d ' ')" == 3 ]]; check "manifest has 3 lines" $?
[[ "$(/usr/bin/jq -r .title "$run/backup/local_rep1.json")" == "old copy" ]]; check "backup of replaced file" $?
has "$out" "restart"; check "apply tells to restart the app" $?

# --- apply again: nothing to do ------------------------------------------------
af_s sync --to bbbb --days 10 --project /w/proj --apply
has "$out" "skip     add1  same"; check "second apply skips copied sessions" $?

# --- undo ----------------------------------------------------------------------
af_s undo "$run"
check "undo exit 0" "$rc"
[[ ! -e "$dst/local_add1.json" && ! -e "$dst/local_sub1.json" ]]; check "undo removes added files" $?
[[ -f "$run/removed/local_add1.json" ]]; check "undo keeps removed files in the run folder" $?
[[ "$(/usr/bin/jq -r .title "$dst/local_rep1.json")" == "old copy" ]]; check "undo restores replaced file" $?

# --- one org ID under two accounts: ACCOUNT/ORG prefix ------------------------
fixture
mkdir -p "$root/acct-2222/bbbb2222-dst"
af_s sync --to bbbb
[[ "$rc" != 0 ]] && has "$out" "matches 2 folders"; check "ambiguous org -> error" $?
af_s sync --to acct-1/bbbb --days 10 --project /w/proj
[[ "$rc" == 0 ]] && has "$out" "acct-1111/bbbb2222-dst"; check "ACCOUNT/ORG prefix resolves" $?

# --- errors --------------------------------------------------------------------
setup
sess "$src" a cli-a /w/proj $((now - day)); transcript p1 cli-a
mkdir -p "$dst"
af_s sync --to bbbb --from aaaa
[[ "$rc" != 0 ]] && has "$out" "no session to copy the connector list from"; check "empty target org -> error" $?
af_s sync --to zzzz
[[ "$rc" != 0 ]] && has "$out" "no org"; check "unknown org -> error" $?

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
