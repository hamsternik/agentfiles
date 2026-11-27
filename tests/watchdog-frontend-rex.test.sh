#!/usr/bin/env bash
# watchdog.py --frontend rex (the Rex launcher, scripts/launchers/rex.py; was rex-watchdog.sh). A fake `rex` on PATH
# logs every call and simulates the parts the launcher needs (window new / session new start a fake claude = a sleep
# with a sessions/<pid>.json entry; send + send-key enter apply /rename and /exit to that entry). watchdog.py runs
# for real on fixture folders. Use cases 23-32 (docs/plans/PLAN-watchdog-launchers.md; list given in chat).
# Run: make test   (uses /bin/bash, like a fresh Mac)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
skill="$repo/claude/skills/watchdog"
wd="$skill/scripts/watchdog.py"
fails=0
T="proj (watchdog-master)"
TRE="proj \(watchdog-master\)"   # T as an extended regex
PROJECT="/home/u/Developer/_work/proj"
OLD_ID="aaaaaaaa-1111-2222-3333-444444444444"
NEW_ID="bbbbbbbb-1111-2222-3333-444444444444"

check() {  # check <name> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   $what"; else echo "FAIL $what"; echo "---- out:"; echo "$out"; echo "---- rex log:"; cat "$st/log" 2>/dev/null; fails=$((fails + 1)); fi
}
logged() { grep -qF -- "$1" "$st/log" 2>/dev/null; }
not_logged() { ! grep -qE -- "$1" "$st/log" 2>/dev/null; }
order() {  # order <pattern>...: the patterns appear in the log in this order
  local n=0 line p
  for p in "$@"; do
    line="$(tail -n +"$((n + 1))" "$st/log" | grep -nF -- "$p" | head -1 | cut -d: -f1)"
    [[ -n "$line" ]] || return 1
    n=$((n + line))
  done
}

setup() {
  st="$(mktemp -d)"
  mkdir -p "$st/bin" "$st/projects" "$st/sessions" "$st/cache"
  slug="$(python3 -c 'import re,sys; print(re.sub(r"[^A-Za-z0-9-]", "-", sys.argv[1]))' "$PROJECT")"
  mkdir -p "$st/projects/$slug"
  : > "$st/log"; : > "$st/spawned"; : > "$st/pids"
  export FAKE_REX_DIR="$st" HANDOFF_PROJECTS_DIR="$st/projects" HANDOFF_SESSIONS_DIR="$st/sessions" \
    HANDOFF_CACHE_DIR="$st/cache" WATCHDOG_WAIT=5 WATCHDOG_VERIFY=3 WATCHDOG_EXIT_WAIT=3 FAKE_RENAME_ENTERS=1
  unset HANDOFF_WINDOW_TOKENS CLAUDE_CODE_MAX_CONTEXT_TOKENS
  cat > "$st/sim.py" <<'PY'
import json, os, signal, subprocess, sys
st = os.environ["FAKE_REX_DIR"]; sessions = os.environ["HANDOFF_SESSIONS_DIR"]
def entry_of_pid(pid):
    return os.path.join(sessions, f"{pid}.json")
def spawn(sid, name, cwd):
    p = subprocess.Popen(["sleep", "60"], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    with open(entry_of_pid(p.pid), "w") as fh:
        json.dump({"pid": p.pid, "sessionId": sid, "name": name, "cwd": cwd, "status": "idle"}, fh)
    with open(os.path.join(st, "spawned"), "a") as fh:
        fh.write(f"{p.pid}\n")
    return p.pid
cmd = sys.argv[1]
if cmd == "start":                                  # start <cwd> <claude argv...>
    cwd, argv = sys.argv[2], sys.argv[3:]
    sid = argv[argv.index("--session-id") + 1] if "--session-id" in argv else argv[argv.index("--resume") + 1]
    spawn(sid, argv[argv.index("-n") + 1], cwd)
elif cmd == "spawn":                                # spawn <sid> <name> <cwd>: print the pid
    print(spawn(*sys.argv[2:5]))
elif cmd == "enter":                                # enter <block>
    b = sys.argv[2]
    pending = os.path.join(st, f"pending-{b}")
    if not os.path.exists(pending):
        sys.exit(0)
    text = open(pending).read()
    count_f = os.path.join(st, f"enters-{b}")
    n = int(open(count_f).read()) + 1 if os.path.exists(count_f) else 1
    need = int(os.environ.get("FAKE_RENAME_ENTERS", "1")) if text.startswith("/rename ") else 1
    if n < need:
        open(count_f, "w").write(str(n)); sys.exit(0)
    os.path.exists(count_f) and os.unlink(count_f)
    os.unlink(pending)
    pid = int([l.split()[1] for l in open(os.path.join(st, "pids")) if l.split()[0] == b][0])
    if text.startswith("/rename "):
        d = json.load(open(entry_of_pid(pid))); d["name"] = text[len("/rename "):]
        json.dump(d, open(entry_of_pid(pid), "w"))
    elif text == "/exit":
        os.kill(pid, signal.SIGTERM)
PY
  cat > "$st/bin/rex" <<'SH'
#!/bin/bash
st="$FAKE_REX_DIR"
printf '%s\n' "$*" >> "$st/log"
start_cmd() {  # the part of `window new` / `session new` after -c DIR ... -- : start the fake claude
  while [ "$1" != "-c" ]; do shift; done; cwd="$2"
  while [ "$1" != "--" ]; do shift; done; shift
  python3 "$st/sim.py" start "$cwd" "$@"
}
case "$1" in
  session)
    case "$2" in
      ls) cat "$st/rex-sessions.json" ;;
      new) start_cmd "$@" ;;
    esac ;;
  window)
    case "$2" in
      ls) if [ "$4" = proj ]; then cat "$st/rex-windows.json"; else echo '{"windows":[]}'; fi ;;  # $4 = -s value
      new) start_cmd "$@" ;;
      rename) : ;;
    esac ;;
  block) pid="$(grep "^$4 " "$st/pids" | cut -d' ' -f2)"
         if [ -n "$pid" ]; then printf '{"child":{"pid":%s,"argv0":"claude"}}\n' "$pid"
         else printf '{"last_exit":{"exit_code":0}}\n'; fi ;;  # an ended pane: no child
  send) printf '%s' "$4" > "$st/pending-$3" ;;
  send-key) python3 "$st/sim.py" enter "$3" ;;
esac
SH
  chmod +x "$st/bin/rex"
  printf '{"windows":[]}\n' > "$st/rex-windows.json"  # a session with no windows (pair and 25b write their own)
  printf '{"sessions":[{"session_id":"session:s0","label":"other"},{"session_id":"session:s1","label":"proj"}]}\n' > "$st/rex-sessions.json"
  export PATH="$st/bin:$PATH"
}
teardown() {
  while read -r pid; do kill "$pid" 2>/dev/null; done < "$st/spawned"
  rm -rf "$st"
}
run() {  # run <args...>; sets $out, $rc
  local r=0
  out="$(python3 "$wd" "$@" 2>&1)" || r=$?
  rc=$r
}
transcript() {  # transcript <sid> <title> <last ts>
  python3 - "$st/projects/$slug/$1.jsonl" "$1" "$2" "$3" <<'PY'
import json, sys
p, sid, title, ts = sys.argv[1:]
recs = [{"type": "custom-title", "customTitle": title, "sessionId": sid},
        {"type": "user", "uuid": "u-" + sid, "timestamp": "2026-11-20T10:00:00Z", "sessionId": sid, "message": {"content": "hi"}},
        {"type": "permission-mode", "permissionMode": "auto", "sessionId": sid},
        {"type": "assistant", "uuid": "a-" + sid, "timestamp": ts, "sessionId": sid,
         "message": {"id": "m", "model": "claude-opus-5-5", "content": [], "usage": {"input_tokens": 100}}}]
open(p, "w").write("\n".join(json.dumps(r) for r in recs) + "\n")
PY
}
pair() {  # pair [ready]: live old (block B1, window W1) and live successor (block B2, window W2)
  old_pid="$(python3 "$st/sim.py" spawn "$OLD_ID" "$T #aaaaaaaa" "$PROJECT")"
  new_pid="$(python3 "$st/sim.py" spawn "$NEW_ID" "$T #bbbbbbbb" "$PROJECT")"
  printf 'block:B1 %s\nblock:B2 %s\n' "$old_pid" "$new_pid" > "$st/pids"
  cat > "$st/rex-windows.json" <<JSON
{"windows":[{"window_id":"window:W1","label":"watchdog-master-aaaaaaaa","layers":[{"blocks":[{"block_id":"block:B1"}]}]},
            {"window_id":"window:W2","label":"watchdog-master-bbbbbbbb","layers":[{"blocks":[{"block_id":"block:B2"}]}]}]}
JSON
  transcript "$OLD_ID" "$T #aaaaaaaa" "2026-11-24T10:00:00Z"
  if [ "${1:-}" = ready ]; then : > "$st/cache/$NEW_ID.ready"; fi
}
pid_gone() { ! kill -0 "$1" 2>/dev/null; }

# 23. new → rex window new with the suffixed label and the claude --session-id line, then the name wait
setup
run start --title "$T" --model claude-opus-5-5 --frontend rex --project-dir "$PROJECT"
check "23 new: exits 0"                         [ "$rc" = 0 ]
check "23 new: one window new with -c and --keep-open" grep -qE "^window new -s proj watchdog-master #[0-9a-f]{8} -c $PROJECT --keep-open -- claude --session-id [0-9a-f-]{36} --model claude-opus-5-5 -n $TRE #[0-9a-f]{8} --remote-control $TRE #" "$st/log"
check "23 new: label suffix = name suffix"     python3 -c 'import re,sys; l=open(sys.argv[1]).read(); a=re.search(r"watchdog-master #([0-9a-f]{8})",l).group(1); b=re.search(r" #([0-9a-f]{8}) --remote",l).group(1); c=re.search(r"--session-id ([0-9a-f]{8})",l).group(1); sys.exit(0 if a==b==c else 1)' "$st/log"
check "23 new: reports the started name"       grep -qE "started $TRE #[0-9a-f]{8}" <<< "$out"
teardown

# 23b. --rex S overrides the project session: window new -s S, no session lookup
setup
run start --title "$T" --model claude-opus-5-5 --frontend rex --rex S --project-dir "$PROJECT"
check "23b --rex: window new -s S"              grep -qE "^window new -s S watchdog-master #" "$st/log"
check "23b --rex: no session ls"                not_logged "^session ls"
teardown

# 32. no Rex session named after the project → one session new that also starts the watchdog
setup
printf '{"sessions":[{"session_id":"session:s0","label":"other"}]}\n' > "$st/rex-sessions.json"
run start --title "$T" --model claude-opus-5-5 --frontend rex --project-dir "$PROJECT"
check "32 session new: exits 0"                 [ "$rc" = 0 ]
check "32 session new: one call with the window" grep -qE "^session new proj --window watchdog-master #[0-9a-f]{8} -c $PROJECT --keep-open -- claude --session-id " "$st/log"
check "32 session new: no window new"           not_logged "^window new"
check "32 session new: never in the caller's"   not_logged " -s other "
teardown

# 24. new while T is live → no Rex call, exit 2
setup
python3 "$st/sim.py" spawn "$OLD_ID" "$T #aaaaaaaa" "$PROJECT" > /dev/null
run start --title "$T" --model claude-opus-5-5 --frontend rex --project-dir "$PROJECT"
check "24 new while live: exit 2"               [ "$rc" = 2 ]
check "24 new while live: no Rex call"          [ ! -s "$st/log" ]
teardown

# 25. restore → rex window new with claude --resume; while live → no Rex call
setup
transcript "$OLD_ID" "$T #aaaaaaaa" "2026-11-24T10:00:00Z"
run restore --title "$T" --frontend rex --project-dir "$PROJECT"
check "25 restore: exits 0"                     [ "$rc" = 0 ]
check "25 restore: window new with --resume"    logged "window new -s proj watchdog-master #aaaaaaaa -c $PROJECT --keep-open -- claude --resume $OLD_ID -n $T #aaaaaaaa"
: > "$st/log"
run restore --title "$T" --frontend rex --project-dir "$PROJECT"
check "25 restore while live: exit 2"           [ "$rc" = 2 ]
check "25 restore while live: no Rex call"      [ ! -s "$st/log" ]
teardown

# 25b. restore with an ended window of the same label in proj → that window is archived before the new one starts
setup
transcript "$OLD_ID" "$T #aaaaaaaa" "2026-11-24T10:00:00Z"
cat > "$st/rex-windows.json" <<JSON
{"windows":[{"window_id":"window:W9","label":"watchdog-master #aaaaaaaa","layers":[{"blocks":[{"block_id":"block:B9"}]}]}]}
JSON
run restore --title "$T" --frontend rex --project-dir "$PROJECT"
check "25b restore: exits 0"                    [ "$rc" = 0 ]
check "25b restore: archives the ended window first" order "window rename -s proj window:W9 archived-watchdog-master #aaaaaaaa" "window new -s proj watchdog-master #aaaaaaaa"
teardown

# 26. handoff → starts the successor; nothing is sent to the old pane
setup
old_pid="$(python3 "$st/sim.py" spawn "$OLD_ID" "$T #aaaaaaaa" "$PROJECT")"
transcript "$OLD_ID" "$T #aaaaaaaa" "2026-11-24T10:00:00Z"
run handoff --title "$T" --handoff-file docs/local/h.md --frontend rex --project-dir "$PROJECT"
check "26 handoff: exits 0"                     [ "$rc" = 0 ]
check "26 handoff: window new with --session-id" grep -qE "^window new .* -- claude --session-id " "$st/log"
check "26 handoff: no send to any pane"         not_logged "^(send|send-key) "
check "26 handoff: the old session still runs"  kill -0 "$old_pid"
teardown

# 26b. handoff --session X passes X on: with 2 live sessions it hands off X
setup
python3 "$st/sim.py" spawn "$OLD_ID" "$T #aaaaaaaa" "$PROJECT" > /dev/null
python3 "$st/sim.py" spawn "$NEW_ID" "$T #bbbbbbbb" "$PROJECT" > /dev/null
transcript "$NEW_ID" "$T #bbbbbbbb" "2026-11-25T10:00:00Z"
run handoff --title "$T" --session "$NEW_ID" --handoff-file h.md --frontend rex --project-dir "$PROJECT"
check "26b handoff --session: exits 0"          [ "$rc" = 0 ]
check "26b handoff --session: prompt names X"   logged "retire --session $NEW_ID"
teardown

# 27. retire without --yes → the plan only
setup; pair ready
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex
check "27 retire dry run: exits 0"              [ "$rc" = 0 ]
check "27 retire dry run: prints the plan"      grep -qF "/rename deprecated $T #aaaaaaaa" <<< "$out"
check "27 retire dry run: names the pane"       grep -qF "block:B1" <<< "$out"
check "27 retire dry run: no send/rename"       not_logged "^(send|send-key|window rename) "
teardown

# 28. retire --yes → rename text, Enter, verify, /exit, Enter, pid gone, window rename archived-<label>
setup; pair ready
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex --yes
check "28 retire: exits 0"                      [ "$rc" = 0 ]
check "28 retire: the order of the Rex calls"   order "send -b block:B1 /rename deprecated $T #aaaaaaaa" "send-key -b block:B1 enter" "send -b block:B1 /exit" "send-key -b block:B1 enter" "window rename -s proj window:W1 archived-watchdog-master-aaaaaaaa"
check "28 retire: the old pid is gone"          pid_gone "$old_pid"
check "28 retire: the successor still runs"     kill -0 "$new_pid"
teardown

# 29. the first Enter does nothing → one more Enter, then on; never applied → stop before /exit
setup; pair ready
export FAKE_RENAME_ENTERS=2
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex --yes
check "29 second Enter: exits 0"                [ "$rc" = 0 ]
check "29 second Enter: 2 Enters before /exit"  [ "$(sed -n '/\/exit/q;p' "$st/log" | grep -c '^send-key -b block:B1 enter')" = 2 ]
teardown
setup; pair ready
export FAKE_RENAME_ENTERS=99
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex --yes
check "29 rename never applied: exit 7"         [ "$rc" = 7 ]
check "29 rename never applied: no /exit sent"  not_logged "^send -b block:B1 /exit"
check "29 rename never applied: old pid runs"   kill -0 "$old_pid"
teardown

# 30. no pane has the target pid → stop, no send
setup; pair ready
printf 'block:B1 1\nblock:B2 %s\n' "$new_pid" > "$st/pids"
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex --yes
check "30 pane not found: exit 9"               [ "$rc" = 9 ]
check "30 pane not found: no send"              not_logged "^(send|send-key) "
teardown

# a failed watchdog.py check (successor not ready) → no Rex call at all
setup; pair
run retire --session "$OLD_ID" --caller "$NEW_ID" --frontend rex --yes
check "retire not ready: exit 2"                [ "$rc" = 2 ]
check "retire not ready: no Rex call"           [ ! -s "$st/log" ]
teardown

# 31. help → every command that a front-end runs
setup
run help
check "31 help: exits 0"                        [ "$rc" = 0 ]
for c in start restore handoff retire help; do
  check "31 help: lists $c"                     grep -qE "^  $c +" <<< "$out"
done
teardown

if [ "$fails" = 0 ]; then echo "all ok"; else echo "$fails failed"; exit 1; fi
