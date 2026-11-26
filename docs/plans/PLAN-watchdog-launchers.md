# PLAN — watchdog launchers (handoff-session-context)

Status: v6 approved by the owner (2026-11-26); built 2026-11-26, steps 1-8 done (build notes at the end).
Skill: `claude/skills/handoff-session-context/`.

## Why

- A Claude Code session can run in different front-ends: a plain terminal, the Claude desktop app, Rex (a pilot
  now), and later others. Each front-end starts, finds, types into and renames a session in its own way.
- Today the skill has one front-end adapter, `scripts/rex-watchdog.sh`. It is Rex-only, it has no tests, and it
  calls `python3` 11 times only to read JSON. Outside Rex, the owner copies the `claude` line by hand.
- The handoff prompt (`cmd_handoff`) names `rex-watchdog.sh retire`. So the decision layer already knows about
  Rex, which breaks the rule "`watchdog.py` decides and never calls Rex".
- Goal: `watchdog.py` keeps all decisions and knows no front-end. Each front-end is one launcher behind one
  interface (Strategy pattern). A new front-end is a new launcher file and its tests, with no change to the
  decisions.

## What

### Scope
- In: a launcher interface; two launchers, `terminal` (the default) and `rex`; a `--frontend` option on the
  commands that start or type; `rex-watchdog.sh` rewritten in Python as the `rex` launcher, then removed; tests
  with a fake launcher.
- Out (non-goals): a Claude desktop launcher (add it when a real need comes); detection of the front-end from the
  environment; TypeScript; changes to `context.py`, the Stop hook or the hand-off file.
- Prerequisite: the restore prompt change (`RESTORE_PROMPT` in `resume_argv`, 5 test use cases) is committed first.

### Layers

| Layer | File | Knows |
|---|---|---|
| CLI + decisions | `scripts/watchdog.py` | the one entry point. Transcripts, live sessions, names, guards, argv, prompts. No front-end. |
| Orchestration | `scripts/launchers/steps.py` (new, no CLI) | the order of the steps of `new`, `restore`, `handoff`, `retire`; the waits (name seen, rename seen, process ended); exit codes. No front-end. |
| Launchers | `scripts/launchers/{__init__,terminal,rex}.py` (new, no CLI) | the calls of one front-end only. `rex.py` replaces `rex-watchdog.sh`. |

### The CLI (one entry point: `watchdog.py`)
- `status`, `ready`, `help`: as now. They never start or type.
- `new`, `restore`, `handoff`, `retire` take `--frontend terminal|rex`. The default is `terminal`.
  - `terminal` works in every environment, because it only prints. It prints the `claude` line, or for `retire`
    the lines to type. This is the behaviour of the commands now, so a call with no `--frontend` stays the same.
  - `rex` starts the window, or types into the pane, through Rex. `retire --frontend rex` acts only with `--yes`;
    without it, it prints the plan (dry run), as `rex-watchdog.sh retire` does now.
  - `--json` prints the decision as JSON with any front-end, for scripts.
- No detection: `REX_SESSION`, `TERM_PROGRAM` and other environment values never choose the front-end. Only
  `--frontend` does.
- The exit codes of `rex-watchdog.sh` move here: 0–6 as now, 7 rename not seen, 8 the old process did not exit,
  9 no Rex pane has the pid, 64 usage.
- `watchdog.py` imports `launchers` only for `--frontend rex`, so the Stop hook and `status` do not load it.

### The contract
- `watchdog.py` gives a start plan. Its JSON keys stay as they are now (`session`, `name`, `argv`, `project_dir`;
  `restore` also `title`, `warning`; `handoff` also `old`). A test fixes these keys.
- New key `window_label`: the Rex window label, made in `watchdog.py`, so the naming rule lives in the decision
  layer only. (Not `window`: that key already holds the context window size in tokens in the `restore` JSON.)

Launcher interface (`typing.Protocol`):

| Operation | Input → output | Capability |
|---|---|---|
| `start(plan)` | starts or prints the argv in `plan["project_dir"]`, window `plan["window_label"]` → `Started(where)` | `start` |
| `find_pane(pid)` | → `Pane(where, window, label)` or `None` | `find_pane` |
| `send_line(pane, text)` | types the text and presses Return | `send` |
| `rename_window(pane, label)` | → nothing | `rename` |

Each launcher has a `caps` set. `steps.py` checks `caps` before each step. When a capability is missing, it prints
the step for the owner and does not fail.

| Capability | terminal | rex |
|---|---|---|
| `start` | prints `cd DIR && claude …` (quoted) | `rex window new -s S "<window>" -c DIR --keep-open -- argv` |
| `find_pane` | no | `rex window ls` + `rex block call … process` |
| `send` | no | `rex send` + `rex send-key enter` |
| `rename` | no | `rex window rename` |

### Names (the same for every caller)
A watchdog has the same names whoever starts it: a skill session, a direct `watchdog.py` command, or a successor.
The caller's own window, Rex session or environment never changes a name.
- Claude session name: the fixed title (`restore`) or `<fixed title> #<short id>` (`new`, `handoff`), as now.
- Rex session: the Rex session whose label is the project folder name (`basename(project_dir)`). When none exists,
  one call `rex session new <proj> --window "<label>" -c DIR --keep-open -- argv` makes it and starts the
  watchdog in its first window. The Rex CLI works outside a Rex pane (`--autostart`), so `--frontend rex` works from
  a plain terminal too. `--rex S` is an explicit override.
- Rex window label: `<role> #<short id>`. The role is the text in the last `( … )` of the fixed title; a title with
  no `( … )` is the role as it is. No project name: the Rex session already has it.
  `proj (watchdog-master)` → `watchdog-master #de18597a`; `proj (watchdog-slave)` → `watchdog-slave #…`;
  `proj/ (watchdog)` → `watchdog #…`.
- `retire` renames the window to `archived-<window label>` (`archived-watchdog-master #de18597a`).
- No `--label` option. `label_for(label, session)` (now `<label>-<id>`) becomes `window_label_for(title, session)`.

### Front-end text out of the decisions
- The handoff prompt names `watchdog.py retire --session OLD --caller NEW --frontend <F>` (dry run first, then
  `--yes`), where `<F>` is the `--frontend` value of the `handoff` call. `watchdog.py` passes the value on; it
  does not know what it means.
- `SKILL.md` names only `watchdog.py`. `rex-watchdog.sh` is removed after its references are updated (step 7).

### Acceptance
- All the tests that exist now pass with no change to their expected values, except the handoff prompt text.
- A command with no `--frontend` gives the same output as now.
- New tests pass (use cases below). `make lint` (shellcheck) stays clean.
- No tracked file, skill or project prompt names `rex-watchdog.sh` (the grep of step 7 finds nothing).
- Live check on the master: `restore --frontend rex`, and `handoff --frontend rex` + `retire --frontend rex --yes`,
  from a Rex pane and from a plain terminal, with no `--rex`; `restore` with no `--frontend` prints a line that
  works when the owner pastes it.

## How

### Test use cases (the owner checks this list before the test code is written)

Front-end option
1. `new`, `restore`, `handoff`, `retire` with no `--frontend` → terminal: the same stdout and exit code as now,
   nothing started, no `rex` call (protects: a default that needs Rex or another tool).
2. No `--frontend`, `REX_SESSION` set, `rex` on PATH → still terminal (protects: a hidden detection).
3. `--frontend rex` → the rex launcher; `--frontend x` → usage, exit 64 (protects: an unknown value that falls
   back to terminal in silence).
4. `--label x` → usage, exit 64 (protects: a hand-made name that `status` and `retire` do not find).
5. `--frontend rex` with no `rex` on PATH → a clear error, exit 64, nothing started.

Names
6. `window_label_for`: `proj (watchdog-master)` → `watchdog-master #<id>`; `proj/ (watchdog)` → `watchdog #<id>`;
   `a (b) (watchdog-slave)` → `watchdog-slave #<id>`; `plain title` → `plain title #<id>`; a title that already
   ends in ` #<8 hex>` → one ` #<id>` only (protects: the project name in the label, and a doubled id).
7. `new`, `restore`, `handoff` of `proj (watchdog-master)` from callers in the windows `crawl-problems-review` and
   `watchdog-master #de18597a`, and from a plain terminal → the same window label and session name (protects:
   names that depend on the caller).
8. Rex session: no `--rex`, a Rex session `proj` exists, the caller is in the Rex session `other` → the window goes
   into `proj` (protects: a watchdog window in the session of a random caller).
9. Rex session: from a plain terminal, no Rex session `proj` → one call `rex session new proj --window
   "<label>" -c DIR --keep-open -- <argv>` (protects: `--frontend rex` that fails when the project has no
   Rex session yet; no empty extra window).
10. `--rex S` → the window goes into `S`, no session lookup (protects: an override that is ignored).

Orchestration with a fake launcher
11. `restore` → one `start` with the argv of the decision, prompt last (protects: the orchestration changes the
    argv).
12. `restore` refused by the guard (still running, active < 120 s) → exit 2, no `start` (protects: a second live
    session of one title).
13. `new` → `start`, then the wait for the name; no name in time → exit 5 (protects: a silent "started").
14. `handoff` → `start` of the successor with the same model; Fable without the owner's word → exit 4, no `start`.
15. `retire --yes`, fake with all caps → `send_line("/rename …")`, rename seen, `send_line("/exit")`, process
    ended, `rename_window("archived-…")`, in this order (protects: `/exit` before the rename is seen).
16. `retire --yes`, rename not seen → exit 7, no `/exit` (protects: an old session that exits with its old name and
    is picked again by `restore`).
17. `retire --yes`, process does not end → exit 8, window not renamed.
18. `retire`, no pane has the pid → exit 9, nothing sent.
19. `retire --frontend rex` without `--yes` → plan printed, no `send_line` (protects: a dry run that acts).
20. `retire --yes` with a fake that has no `send` → steps printed, exit 0, no call (protects: a crash on a
    front-end with fewer caps).

Launchers (PATH stubs that record the calls)
21. rex `start` → exactly `rex window new -s S "<window>" -c DIR --keep-open -- <argv>` (protects: a lost
    `--keep-open` or a split prompt).
22. rex `find_pane` reads the window and block JSON → the pane with the matching child pid; none → `None`.
23. rex `find_pane` and `rename_window` with a label that has a space and `#` → the right window (protects: the old
    shell split of labels at spaces).
24. terminal `start` → one line `cd DIR && claude …` that `shlex.split` gives back as the same argv (protects:
    quoting of the prompt).

Contract
25. The JSON keys of `new`, `restore`, `handoff` stay the same, plus `window_label` (protects: other callers of `--json`).
26. The handoff prompt names `watchdog.py retire … --frontend <F>` with the `<F>` of the call, and not
    `rex-watchdog.sh` (protects: Rex text in the decisions; a successor that retires through another front-end).

### Steps
1. Commit the restore prompt change (prerequisite).
2. Write tests 1, 2, 25, 26 against the current code; 26 is red.
3. Write tests 3–24; they are red (no `--frontend`, no `launchers/`).
4. Add `window_label_for` to `watchdog.py` and the `window_label` key.
5. Add `launchers/__init__.py` (Protocol, `Pane`, `Started`, `get(name)`), `launchers/terminal.py`,
   `launchers/rex.py` (rewritten from `rex-watchdog.sh`: `start_window`, `find_pane`, the send and rename calls,
   the Rex session lookup; one `_rex()` that prints `+ rex …` on stderr, as now; `subprocess` + `json`).
6. Add `launchers/steps.py` (from `rex-watchdog.sh`: the waits of `start_window` and `do_retire`; env
   `WATCHDOG_WAIT`, `WATCHDOG_VERIFY`, `WATCHDOG_EXIT_WAIT` as now) and `--frontend`, `--rex`, `--yes` in
   `watchdog.py`. Change the handoff prompt. Update `SKILL.md` and the help text.
7. Find every reference to `rex-watchdog.sh`: this repo (`ggrep -rn`), the prompts and memory files of each project
   that installs the skill (a list, no edit), and the prompts of live sessions (a running successor that still has
   the old text). Show the list to the owner; update the files he confirms; then `git rm scripts/rex-watchdog.sh`.
8. Run all tests and `make lint`. Live check on the master (Acceptance). Commit, then the slave gets it on pull.

### Risks
- A running successor may still hold the old text `rex-watchdog.sh retire` in its first prompt. After the delete,
  that step fails with "no such file". Step 7 lists such sessions; delete only when none is open, or tell the
  session the new command.
- The window label has a space and `#`. Rex accepts it (a window `velocity-audit-weekly (s)` exists); test 23
  covers the lookup.
- `watchdog.py` runs under the Homebrew `python3`, the same as the Stop hook. Use the standard library only.

## Decided (owner)
1. One entry point: `watchdog.py` (v1 review). No `run` subcommand (v5 review, KISS): the commands take
   `--frontend`.
2. `rex-watchdog.sh` is rewritten in Python as the `rex` launcher and then removed (v1 review).
3. One naming rule for every caller; no `--label` (v2 review).
4. Rex session = the project folder name, made when missing; `--frontend rex` works outside Rex (v3 review).
5. Window label `watchdog-<master|slave> #<short id>`: the role from the title, no project name (v4 review).
6. Default front-end `terminal`, no detection from the environment (v5 review, KISS).

## Open questions
None.

## Build notes (2026-11-26)

Changes found during the build (each one also changed in the text above):
- The JSON key is `window_label`, not `window`: the `restore` JSON already has `window` (the context window size).
- The function is `window_label_for`: `context.py` already has `window_for` (the context window size).
- A missing Rex session is one call, `rex session new <proj> --window "<label>" … -- argv` (from `rex session new
  --help`): no second call, no empty window.
- The Rex launcher tests use a recording `run` in the process; the CLI tests and the shell test use a fake `rex` on
  PATH.
- `tests/rex-watchdog.test.sh` is now `tests/watchdog-frontend-rex.test.sh`: the same fake `rex` (sleep processes,
  session entries), driven through `watchdog.py --frontend rex`; plus 23b (`--rex S`) and 32 (`session new`).
- `tests/handoff-skill.test.sh` and the start line of the skill `start-project-watchdog` name `watchdog.py … --frontend
  rex`.
- With no `--frontend`, the commands print the decision text as before; `Terminal.start` (`cd DIR && claude …`) is
  not used by the CLI. `--json` with `--frontend rex` prints the JSON and also acts.

Tests: 105 Python tests (test_watchdog 50, test_context 33, test_launchers 22), `make test` (45 checks in
watchdog-frontend-rex), `make lint` clean.

Live check on the master (one Haiku test session `shelf-crawl (watchdog-livecheck)`, no second child session: the
bulk-job rule):
1. `new --frontend rex` from a Rex pane → window `watchdog-livecheck #b7e63c93` in the Rex session `shelf-crawl`; the
   session ran `ready` and replied.
2. `restore --frontend rex` with no `REX_*` variables → the same label in `shelf-crawl`; the session got the restore
   prompt and acted on it.
3. `restore` with no `--frontend` → printed the line, started nothing; the line, pasted into `zsh -lc`, resumed the
   session with the prompt.
4. `retire --frontend rex --yes` with no successor → exit 2, no Rex call.
Not run live: `handoff --frontend rex` + `retire --yes` (a second child session = a bulk job; covered by use cases
14-20, 26 and the shell test 26-30).

Follow-ups (not in this plan):
- `restore` leaves the old window of the exited session open (`--keep-open`) with the same label: 2 windows with one
  label in the Rex session. `retire` finds panes by pid, so it still works.
- The slave did not answer ssh at the build: its live sessions were not checked for the old `rex-watchdog.sh retire`
  text before its next `git pull`.
