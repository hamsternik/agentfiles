---
name: watchdog
description: The ONE pinned watchdog session of a project ("<project> (watchdog) #<id>", or "(watchdog-<machine>)" for a project on 2+ machines) on the master or the slave Mac, and its tools in one CLI, watchdog.py. Start, replace, hand off, restore and retire a watchdog (front-ends terminal, Rex, Claude Desktop), "what's up" (sessions, open decisions, git, Inbox), and the decision queue (add, list, decide, the 2 h default, close). Carries the full watchdog rule set (rules.md). Use when the owner says "start a watchdog for this project", "make the <project> watchdog", "replace / hand off / restore the watchdog", "what's up", "add a decision", "take the default of D<nn>", or when a watchdog wake-up says `watchdog queue default D<nn>`.
---

# Watchdog

A project has ONE pinned watchdog session: the owner's inbox and router. Every other session of the project is a working
session and reports only to it. The rules are in `rules.md` (this folder; read it first). The project facts are in the
project part `.claude/docs/prompts/<project>-watchdog.md` (older projects: `docs/prompts/<project>-watchdog.md`).

Set-up: `W=~/.claude/skills/watchdog/scripts/watchdog.py` (agentfiles links this folder on the master and the slave).
`python3 $W help` lists every command with its flags and exit codes.

## Commands

| Command | Does |
|---|---|
| `python3 $W init [--local]` | the project part and the queue from the templates; never overwrites. `--local`: hide both in the git exclude file (a repo the owner does not own) |
| `python3 $W public` | `public`, `private` or `unknown`: in a public repo the project part holds session titles and ids only |
| `python3 $W start --model M [--machine NAME] [--title T] [--prompt-file F] [FRONT-END]` | a new watchdog (or, with `--title`, a work session). Refused while the title runs; Fable only with `--owner-said-fable` on the owner's word |
| `python3 $W status [--title T]` | the sessions of a title (or of every watchdog title): id, pid, name, context %, last activity |
| `python3 $W handoff --title T --handoff-file F --session ID [FRONT-END]` | the successor of a live session, same model (skill `handoff-session-context`) |
| `python3 $W ready --session ID` | a successor marks itself ready |
| `python3 $W retire --session OLD --caller NEW [FRONT-END] [--yes]` | retire the old session after its successor is ready |
| `python3 $W restore --title T [FRONT-END]` | resume a session after an exit or a crash |
| `python3 $W whatsup` | one screen: the watchdog sessions, the open D-rows with age, git, the Inbox outbox |
| `python3 $W queue next-id \| add \| list \| decide \| default \| close` | the decision queue (section D) |

FRONT-END: `--frontend terminal` (the default) runs `claude` in this terminal: use it from a plain terminal only (it refuses
inside a Claude Code session). In a session use `--frontend rex` (a Rex window; the Rex session is named after the project
folder) or `--frontend desktop` (it prints the `start_session` arguments as JSON). `--dry-run` or `--json` only print.

## A. Make or replace the watchdog

Run in a session whose folder is the project, on the machine where the watchdog must run.

1. **Find the old watchdog.** `python3 $W status`. This lists only this machine: ask the owner about a watchdog on the other
   machine. If an old watchdog exists, read its project part and memory: its sessions table, open items and facts go into the
   new project part.
2. **Interview.** Use `AskUserQuestion` only when this session is not a watchdog; a watchdog asks in chat (rules.md, rule 3). Ask
   only what is still open: owned areas; the sessions table; status sources; the machines (2 or more: one watchdog per machine,
   and which one writes the queue); the queue path (default `.claude/docs/decisions/queue.md`); a report; the model (default
   Opus; Fable only on the owner's word); does the owner own the repo (if not: `init --local`).
3. **Write the project part.** `python3 $W init [--local]`, then fill each section with Edit. A project with its own queue file
   names it in the line ``Queue file: `<path>` ``. `python3 $W public`: if `public`, write session titles and ids only (no
   employer, client or work names, no hostnames, no IPs, no emails). Show the owner the text and wait for his approval.
4. **Commit** the two files only on the owner's word (never with `--local`); push only on the owner's word.
5. **Start.** In Rex: `python3 $W start --model <m> [--machine <this machine>] --frontend rex`. In the Desktop app:
   `python3 $W start --model <m> [--machine …] --frontend desktop`, then call `mcp__ccd_session__start_session` with the printed
   `title`, `cwd`, `model`, `prompt`, `use_worktree: false`, `context: "fresh"` and `initiation: "user_asked"`; at once
   `mcp__ccd_session_mgmt__detach_session` with the new id (the watchdog is a top-level session, not nested under this one);
   check with `get_session` that `detached` is true. With neither: `--dry-run` prints the line; the owner runs it in a terminal
   in the project folder (`claude` starts there), on the right machine.
6. **Tell the owner** one line: the new session, its machine and model, and that its first steps (project part, "Steps") run
   there: its id, memory and docs, "report here only" to the live sessions, and the retire of the old watchdog.

## B. Hand-off

At 40 % of the context window (the Stop hook of `handoff-session-context` asks), or when a new session has tools this one
lacks: write the state into the project part (sessions table with the time in UTC, open items, open D-rows, facts only this
session knows) and raise its version line. Ask the owner in chat for the commit of the project part (no default). Then run the
hand-off of the skill `handoff-session-context` (`$W handoff …`, same machine, same model unless the owner says another). The
successor retires this session (`$W retire`).

## C. Restore and retire

- After an exit, an upgrade or a crash ("restore the watchdog"): `python3 $W restore --title "<title>" --frontend rex` (or the
  terminal default from a plain terminal; the Desktop cannot resume). It refuses while the old session runs or was active in the
  last 2 minutes; at level `handoff` or `over` it warns: hand off from a new session instead.
- `python3 $W retire --session <old> --caller <new> --frontend rex` is a dry run; add `--yes` to act. Terminal and Desktop
  print the 2 lines to type into the old session.

## D. Decision queue

Rules 3 and 4 of `rules.md`. The path comes from the project part (``Queue file: `<path>` ``), else
`.claude/docs/decisions/queue.md`.
- `python3 $W queue add --item "<question>" --default "<recommended decision>" [--scope S]`: the next id, an `open` row, one
  Inbox item, and the wake-up line. Set that wake-up: `ScheduleWakeup` when it is in your tool list (it accepts a call outside
  `/loop`), else the printed `CronCreate` one-shot line. For a deletion, a plan or spec, a rule text, a commit or push, or a write
  to a shared or external system: `--default "none: <why>"`.
- `python3 $W queue list [--all] [--json]`: the open rows with their age in hours.
- `python3 $W queue decide D<nn> "<answer>"`: the owner's answer into the row and the Inbox item.
- `python3 $W queue default D<nn>`: at the wake-up; it refuses when the row may not take its default.
- `python3 $W queue close`: the rows done more than 7 days ago go to "Closed".

## E. What's up

`python3 $W whatsup`, then the Inbox items of the project (skill `triage-inbox`, the Inbox view). Answer first; name what you
did not check (rules.md, rule 5).

## Not in this skill

The Inbox itself (skill `triage-inbox`), the context size and the Stop hook (skill `handoff-session-context`), status reports
of one project (a project skill), and the work of the working sessions.
