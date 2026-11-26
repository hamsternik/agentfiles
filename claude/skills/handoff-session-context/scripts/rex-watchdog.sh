#!/bin/bash
# rex-watchdog.sh — the Rex part of the watchdog CLI v2 (skill handoff-session-context). macOS /bin/bash 3.2.
# Every decision comes from `watchdog.py ... --json`; this script only runs the Rex calls, and prints each one
# (on stderr, "+ rex ...") before it runs. Run `rex-watchdog.sh help` for the commands.
# Env (tests): WATCHDOG_WAIT (name wait, s, 60), WATCHDOG_VERIFY (rename check, s, 10), WATCHDOG_EXIT_WAIT (s, 30).
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WD="$here/watchdog.py"

usage() {
  cat <<'EOF'
rex-watchdog.sh — Rex calls for project watchdog sessions (decisions by watchdog.py)

  new      --title T --model M --rex S --label L [--first-prompt TEXT | --prompt-file F] [--effort E] [--owner-said-fable]
           open a new Rex window L-<id> in Rex session S with a new watchdog "T #<id>"; wait for its name
  restore  --title T --rex S --label L [--effort E]
           open the latest session of T again (claude --resume) in a new window L-<id>
  handoff  --title T --handoff-file F --session ID --rex S --label L [--prompt-file F] [--effort E]
           start the successor of the live session of T; the successor retires the old one after `ready`
  retire   --session ID [--caller ID] [--rex S] [--yes]
           type `/rename deprecated ...` and `/exit` into the old session's pane, then rename its window
           archived-<label>; without --yes: print the plan only
  help     this text

All commands take --project-dir DIR. Exit codes: those of watchdog.py, and 7 rename not seen, 8 the old process
did not exit, 9 no Rex pane has the session's pid, 64 usage.
EOF
}

say() { printf 'rex-watchdog.sh: %s\n' "$*" >&2; }
rexc() {  # print, then run one Rex call
  local s="+ rex" x
  for x in "$@"; do s="$s $(printf '%q' "$x")"; done
  printf '%s\n' "$s" >&2
  rex "$@"
}
jget() {  # jget <key path> < json: a value; a list prints NUL-separated items
  python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in sys.argv[1].split("."):
    d = d[k]
sys.stdout.write("".join(str(x) + "\0" for x in d) if isinstance(d, list) else str(d))' "$1"
}

# ---- options ----------------------------------------------------------------------------------------------------
cmd="${1:-help}"; [ $# -gt 0 ] && shift
rex_session="" label="" yes=0 title="" session="" caller="" project_dir=""
pass=()  # options passed to watchdog.py as they are
# shellcheck disable=SC2034  # title is read through need() (${!v})
while [ $# -gt 0 ]; do
  case "$1" in
    --rex) rex_session="$2"; shift 2 ;;
    --label) label="$2"; shift 2 ;;
    --yes) yes=1; shift ;;
    --title) title="$2"; pass+=("$1" "$2"); shift 2 ;;
    --session) session="$2"; shift 2 ;;
    --caller) caller="$2"; shift 2 ;;
    --project-dir) project_dir="$2"; pass+=("$1" "$2"); shift 2 ;;
    --owner-said-fable) pass+=("$1"); shift ;;
    --model|--first-prompt|--prompt-file|--effort|--handoff-file) pass+=("$1" "$2"); shift 2 ;;
    *) say "unknown option: $1"; exit 64 ;;
  esac
done

need() { local v; for v in "$@"; do [ -n "${!v}" ] || { say "$cmd needs --${v//_/-}"; exit 64; }; done; }

# ---- start a window and wait for the name ----------------------------------------------------------------------
start_window() {  # start_window <json> <argv key> <name> <window label>
  local json="$1" key="$2" name="$3" wlabel="$4" proj argv=() x
  proj="$(printf '%s' "$json" | jget project_dir)"
  while IFS= read -r -d '' x; do argv+=("$x"); done < <(printf '%s' "$json" | jget "$key")
  rexc window new -s "$rex_session" "$wlabel" -c "$proj" --keep-open -- "${argv[@]}" >/dev/null || exit $?
  if ! python3 "$WD" status --wait-name "$name" --timeout "${WATCHDOG_WAIT:-60}" >/dev/null; then
    say "the window $wlabel started, but no live session is named '$name' after ${WATCHDOG_WAIT:-60} s"
    exit 5
  fi
  printf 'started %s in Rex window %s (session %s)\n' "$name" "$wlabel" "$rex_session"
}

# ---- retire helpers ---------------------------------------------------------------------------------------------
find_pane() {  # find_pane <pid>: prints "<rex session> <window id> <window label> <block id>" or nothing
  local pid="$1" sessions s wid wl bid p
  if [ -n "$rex_session" ]; then sessions="$rex_session"
  else sessions="$(rex session ls --json | python3 -c 'import json,sys; print("\n".join(s["label"] for s in json.load(sys.stdin)["sessions"]))')"
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    while IFS=' ' read -r wid wl bid; do
      [ -n "$bid" ] || continue
      p="$(rex block call -b "$bid" process 2>/dev/null | python3 -c 'import json,sys
try: print(json.load(sys.stdin)["child"]["pid"])
except Exception: print(0)')"
      if [ "$p" = "$pid" ]; then printf '%s %s %s %s\n' "$s" "$wid" "$wl" "$bid"; return 0; fi
    done < <(rex window ls -s "$s" --json | python3 -c '
import json, sys
for w in json.load(sys.stdin)["windows"]:
    for layer in w.get("layers", []):
        for b in layer.get("blocks", []):
            print(w["window_id"], w["label"].replace(" ", "_"), b["block_id"])')
  done <<< "$sessions"
}

verified() { python3 "$WD" retire --session "$session" --verify >/dev/null 2>&1; }

do_retire() {
  local plan pid new_name pane s wid wl bid i extra=0
  local args=(retire --session "$session" --json)
  [ -n "$caller" ] && args+=(--caller "$caller")
  [ -n "$project_dir" ] && args+=(--project-dir "$project_dir")
  plan="$(python3 "$WD" "${args[@]}")" || exit $?
  pid="$(printf '%s' "$plan" | jget pid)"
  new_name="$(printf '%s' "$plan" | jget new_name)"
  pane="$(find_pane "$pid")"
  [ -n "$pane" ] || { say "no Rex pane runs pid $pid (session $session): nothing sent"; exit 9; }
  read -r s wid wl bid <<< "$pane"
  if [ "$yes" != 1 ]; then
    printf 'plan (dry run; add --yes to act) for pid %s in window %s (%s), block %s:\n' "$pid" "$wl" "$wid" "$bid"
    printf '  rex send -b %s %q && rex send-key -b %s enter   (then check the new name)\n' "$bid" "/rename $new_name" "$bid"
    printf '  rex send -b %s /exit && rex send-key -b %s enter   (then wait for pid %s to end)\n' "$bid" "$bid" "$pid"
    printf '  rex window rename -s %s %s archived-%s\n' "$s" "$wid" "$wl"
    return 0
  fi
  rexc send -b "$bid" "/rename $new_name" || exit $?
  rexc send-key -b "$bid" enter || exit $?
  i=0
  until verified; do
    i=$((i + 1))
    if [ "$i" -ge "${WATCHDOG_VERIFY:-10}" ]; then
      say "the name of pid $pid did not change to '$new_name': /exit not sent"; exit 7
    fi
    if [ "$extra" = 0 ]; then extra=1; rexc send-key -b "$bid" enter || exit $?; fi  # 11-23: the first Enter failed
    sleep 1
  done
  rexc send -b "$bid" "/exit" || exit $?
  rexc send-key -b "$bid" enter || exit $?
  i=0
  while kill -0 "$pid" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -le "${WATCHDOG_EXIT_WAIT:-30}" ] || { say "pid $pid did not exit: window not renamed"; exit 8; }
    sleep 1
  done
  rexc window rename -s "$s" "$wid" "archived-$wl" >/dev/null || exit $?
  printf 'retired %s (pid %s); window %s is now archived-%s\n' "$new_name" "$pid" "$wid" "$wl"
}

# ---- commands ---------------------------------------------------------------------------------------------------
case "$cmd" in
  help|-h|--help) usage ;;
  new)
    need title rex_session label
    json="$(python3 "$WD" new "${pass[@]}" --json)" || exit $?
    sid="$(printf '%s' "$json" | jget session)"
    start_window "$json" argv "$(printf '%s' "$json" | jget name)" "$label-${sid:0:8}" ;;
  restore)
    need title rex_session label
    json="$(python3 "$WD" restore "${pass[@]}" --json)" || exit $?
    sid="$(printf '%s' "$json" | jget session)"
    start_window "$json" argv "$(printf '%s' "$json" | jget title)" "$label-${sid:0:8}" ;;
  handoff)
    need title rex_session label
    [ -n "$session" ] && pass+=(--session "$session")
    json="$(python3 "$WD" handoff "${pass[@]}" --json)" || exit $?
    new="$(printf '%s' "$json" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["new"]["project_dir"]=d["project_dir"]; print(json.dumps(d["new"]))')"
    sid="$(printf '%s' "$new" | jget session)"
    start_window "$new" argv "$(printf '%s' "$new" | jget name)" "$label-${sid:0:8}" ;;
  retire)
    need session
    do_retire ;;
  *) say "unknown command: $cmd"; usage >&2; exit 64 ;;
esac
