#!/usr/bin/env bash
# Tests for `af inbox`: the local side of the Claude Inbox (docs/inbox.md).
# Sessions that cannot reach the Inbox db append changes to an outbox; a session
# with the db tool takes the outbox, writes the db, then acks it into the local
# log. Temp HOME/AF_HOME/AF_LOCAL; fixed clock via AF_INBOX_NOW.
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fails=0
now="2026-11-05T16:02:11Z"

setup() {
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/home" "$tmp/af/state" "$tmp/local"
  : > "$tmp/local/machine.env"
  box="$tmp/home/.claude/inbox"
}

ibx_env() {  # ibx_env <VAR=value|-> <args...>; sets $out (stdout), $err, $rc
  local extra="$1" r=0; shift
  [[ "$extra" == - ]] && extra="AF_INBOX_UNUSED=1"
  out="$(env HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_INBOX_NOW="$now" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$extra" "$repo/bin/af" inbox "$@" 2>"$tmp/err")" || r=$?
  rc=$r; err="$(cat "$tmp/err")"
}
ibx() { ibx_env - "$@"; }

check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what (rc=$rc out=$out err=$err)"; fails=$((fails + 1)); fi
}
lines()    { if [[ -f "$1" ]]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
jq_last()  { tail -n 1 "$box/outbox-master.jsonl" | /usr/bin/jq -e "$1" >/dev/null; }
failed()   { [ "$rc" != 0 ]; }
err_has()  { grep -q -- "$1" <<<"$err"; }
out_has()  { grep -q -- "$1" <<<"$out"; }
all_json() { while IFS= read -r l; do /usr/bin/jq -e . <<<"$l" >/dev/null || return 1; done < "$1"; }

# --- role --------------------------------------------------------------------
setup
ibx role
check "role: master when this Mac has no af role yet"   [ "$out" = master ]
echo slave > "$tmp/af/state/role"
ibx role
check "role: read from the af state"                    [ "$out" = slave ]
ibx_env AF_INBOX_ROLE=master role
check "role: AF_INBOX_ROLE overrides the state"         [ "$out" = master ]
rm -rf "$tmp"

# --- url ---------------------------------------------------------------------
setup
ibx url
check "url: unset fails"                                failed
check "url: unset says how to set it"                   err_has "af inbox url <"
ibx url https://example.com/x
check "url: refuses a non-claude.ai address"            failed
ibx url https://claude.ai/artifact/AbC123
check "url: set exits 0"                                [ "$rc" = 0 ]
ibx url
check "url: prints the stored address"                  [ "$out" = https://claude.ai/artifact/AbC123 ]
rm -rf "$tmp"

# --- new-id ------------------------------------------------------------------
setup
ibx new-id
check "new-id: I-<date>-<4 hex>"                        grep -Eq '^I-20261105-[0-9a-f]{4}$' <<<"$out"
rm -rf "$tmp"

# --- add ---------------------------------------------------------------------
setup
ibx add --type decision --title "Resume run X" --project demo --ref D09 \
  --session local_abc --session slave:local_def --file notes/RUN.md \
  --default "stays paused" --next "Answer yes or no" --by session:master:local_abc
id="$out"
check "add: prints the new id"                          grep -Eq '^I-20261105-[0-9a-f]{4}$' <<<"$id"
check "add: one outbox line"                            [ "$(lines "$box/outbox-master.jsonl")" = 1 ]
check "add: op, ts and by"                              jq_last '.op == "add" and .ts == "'"$now"'" and .by == "session:master:local_abc"'
check "add: item id, type, state"                       jq_last '.item.id == "'"$id"'" and .item.type == "decision" and .item.state == "inbox"'
check "add: no previous state yet"                      jq_last '.item.prev_state == null'
check "add: inbox items are owned by owner"            jq_last '.item.owner == "owner"'
check "add: sessions get the role prefix once"          jq_last '.item.links.sessions == ["master:local_abc", "slave:local_def"]'
check "add: files get the role prefix"                  jq_last '.item.links.files == ["master:notes/RUN.md"]'
check "add: ref, default, next, project"                jq_last '.item.links.ref == "D09" and .item.default == "stays paused" and .item.next == "Answer yes or no" and .item.project == "demo"'
check "add: timestamps and updated_by"                  jq_last '.item.created_at == "'"$now"'" and .item.updated_at == "'"$now"'" and .item.updated_by == "session:master:local_abc"'
check "add: empty notes, no answer"                     jq_last '.item.notes == [] and .item.answer == null'

ibx add --type task --title "Long build" --state in_progress
check "add: in_progress items are owned by the agent"   jq_last '.item.owner == "agent" and .item.state == "in_progress"'
check "add: default by is the agent of this role"       jq_last '.by == "agent:master"'
ibx add --type task --title "Wait for the budget reset" --state waiting --wake 2026-11-06
check "add: waiting with a wake date"                   jq_last '.item.state == "waiting" and .item.wake == "2026-11-06"'

before="$(lines "$box/outbox-master.jsonl")"
ibx add --title "No type";                              check "add: needs --type"                 failed
ibx add --type x --title t;                             check "add: refuses an unknown type"      failed
ibx add --type task;                                    check "add: needs --title"                failed
ibx add --type task --title t --state nope;             check "add: refuses an unknown state"     failed
ibx add --type task --title t --state waiting;          check "add: waiting needs --wake"         failed
ibx add --type task --title t --state waiting --wake tomorrow; check "add: refuses a bad wake date" failed
ibx add --type task --title t --state snoozed --wake 2026-11-09; check "add: cannot snooze"       failed
ibx add --type task --title t --state archived;         check "add: cannot archive"               failed
long="$(printf 'x%.0s' $(seq 1 4200))"
ibx add --type task --title "$long";                    check "add: refuses a line over 4 KB"     failed
check "add: refused calls write nothing"                [ "$(lines "$box/outbox-master.jsonl")" = "$before" ]
rm -rf "$tmp"

# --- move / note / answer ----------------------------------------------------
setup
ibx move I-20261105-a3f9 waiting --wake 2026-11-07
check "move: exits 0"                                   [ "$rc" = 0 ]
check "move: op, id, state, wake"                       jq_last '.op == "move" and .id == "I-20261105-a3f9" and .state == "waiting" and .wake == "2026-11-07"'
ibx move I-20261105-a3f9 "done"
check "move: done is allowed for agents"                jq_last '.state == "done"'
ibx move I-20261105-a3f9 snoozed --wake 2026-11-09;     check "move: agents cannot snooze"        failed
ibx move I-20261105-a3f9 archived;                      check "move: agents cannot archive"       failed
ibx move I-20261105-a3f9 snoozed --wake 2026-11-09 --by owner
check "move: owner can snooze"                         jq_last '.state == "snoozed" and .by == "owner"'
ibx move I-20261105-a3f9 snoozed --by owner;           check "move: snoozed needs --wake"        failed
ibx move bad-id "done";                                   check "move: refuses a bad id"            failed
ibx move I-20261105-a3f9 nope;                          check "move: refuses an unknown state"    failed
ibx note I-20261105-a3f9 "Budget resets at 00:10 UTC"
check "note: op and text"                               jq_last '.op == "note" and .id == "I-20261105-a3f9" and .text == "Budget resets at 00:10 UTC"'
ibx answer I-20261105-a3f9 "yes, resume" --by owner
check "answer: op, text, by"                            jq_last '.op == "answer" and .text == "yes, resume" and .by == "owner"'
ibx note I-20261105-a3f9;                               check "note: needs a text"                failed
rm -rf "$tmp"

# --- take / ack --------------------------------------------------------------
setup
ibx take
check "take: an empty outbox prints nothing"            [ "$rc" = 0 -a -z "$out" ]
ibx add --type task --title one
ibx add --type task --title two
ibx take
check "take: prints the outbox lines"                   [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ]
check "take: the outbox is gone"                        [ ! -e "$box/outbox-master.jsonl" ]
check "take: the lines wait in the sending file"        [ "$(lines "$box/outbox-master.sending.jsonl")" = 2 ]
ibx add --type task --title three
check "take: new adds go to a new outbox"               [ "$(lines "$box/outbox-master.jsonl")" = 1 ]
ibx take
check "take: an un-acked take returns the same lines"   [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 2 ]
check "take: ... and leaves the new outbox alone"       [ "$(lines "$box/outbox-master.jsonl")" = 1 ]
ibx ack
check "ack: removes the sending file"                   [ ! -e "$box/outbox-master.sending.jsonl" ]
check "ack: the sent lines go to the local log"         [ "$(lines "$box/log-master.jsonl")" = 2 ]
ibx ack
check "ack: nothing to ack is fine"                     [ "$rc" = 0 ]
rm -rf "$tmp"

# --- concurrent writers ------------------------------------------------------
setup
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  env HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_INBOX_NOW="$now" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$repo/bin/af" inbox add --type task --title "parallel $i" >/dev/null 2>&1 &
done
wait
rc=0; out=""; err=""
check "parallel: 20 adds give 20 lines"                 [ "$(lines "$box/outbox-master.jsonl")" = 20 ]
check "parallel: every line is whole JSON"              all_json "$box/outbox-master.jsonl"
rm -rf "$tmp"

# --- log / export / status ---------------------------------------------------
setup
ibx log '{"op":"set","id":"I-20261105-a3f9","state":"done"}'
check "log: appends one line"                           [ "$(lines "$box/log-master.jsonl")" = 1 ]
check "log: stamps ts and role"                         /usr/bin/jq -e '.ts == "'"$now"'" and .role == "master" and .op == "set"' "$box/log-master.jsonl"
ibx log 'not json';                                     check "log: refuses invalid JSON"         failed
out="$(printf '%s\n' '{"id":"I-20261001-0001"}' '{"id":"I-20261001-0002"}' \
  | env HOME="$tmp/home" AF_HOME="$tmp/af" AF_LOCAL="$tmp/local" AF_INBOX_NOW="$now" \
    PATH="/usr/bin:/bin:/usr/sbin:/sbin" "$repo/bin/af" inbox export 2>&1)" && rc=0 || rc=$?
check "export: appends to the month file"               [ "$(lines "$box/export-202611.jsonl")" = 2 ]
ibx add --type task --title one
ibx status
check "status: names the role"                          out_has "role=master"
check "status: counts the outbox"                       out_has "outbox=1"
check "status: says the url is not set"                 out_has "url=unset"
check "status: age of the oldest outbox line"           out_has "outbox_oldest=$now"
rm -rf "$tmp"

# --- af help -----------------------------------------------------------------
setup
out="$("$repo/bin/af" help 2>&1)" && rc=0 || rc=$?; err=""
check "af help lists inbox"                             out_has "inbox"
rm -rf "$tmp"

(( fails == 0 )) || { echo "$fails failure(s)"; exit 1; }
