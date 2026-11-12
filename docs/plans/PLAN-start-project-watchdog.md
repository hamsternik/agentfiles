# PLAN: start-project-watchdog skill

Status: **approved 2026-11-12** (the owner: "Approve").

## Goal

One reusable Claude Code skill, `start-project-watchdog`, that makes the ONE pinned watchdog session of any project
("<project> (watchdog)") on the master or the slave. agentfiles installs it on both machines. The first user is the
dotfiles repo: the new watchdog "dotfiles (watchdog)" runs on the master and replaces the old "dotfiles/ (watchdog)"
session on the slave by a hand-off.

The skill carries the full watchdog rule set itself. Reason: the org rules file of the work folder does not apply to
projects outside it (dotfiles, agentfiles). A project keeps only a short project part:
`docs/prompts/<project>-watchdog.md`.

## Decisions

Taken before the interview (task brief, 2026-11-12):
- Form: a skill at `claude/skills/start-project-watchdog/`, installed by agentfiles on the master and the slave, callable in any project.
- The skill carries the full rule set; it writes a short project part `docs/prompts/<project>-watchdog.md`.
- The title is "<project> (watchdog)". The first use replaces the current dotfiles watchdog by a hand-off; the owner archives the old session (archive, never delete).

Interview, 2026-11-12:

| # | Question | Answer |
|---|---|---|
| 1 | Machine of the new dotfiles watchdog | **Master.** The old one runs on the slave. The master reads slave facts over SSH. |
| 2 | Where a watchdog records an open decision | **Both:** a D-row in the project file `docs/decisions/queue.md` and one Claude Inbox item (`type: decision`, `links.ref` = the D-id) through the `triage-inbox` skill. |
| 3 | How the skill makes the session | **Launcher:** run the skill in any session of the project; it interviews, writes the project part, and starts a new session with `start_session`. With no `start_session`, it gives the owner the start line. |
| 4 | Extra org rule sections in the skill | **All four:** Bulk AI jobs, Deleting files, HTML reports, Obsolete documents. |

Facts found (2026-11-12):
- The old "dotfiles/ (watchdog)" is a slave session (model Opus, started 2026-11-10). Its job: keep dotfiles in sync between the two machines. Its memory on the slave holds one rule: the role of a machine comes from its network name.
- The master has no saved SSH connection in the desktop app, so `start_session` on the master cannot start a session on the slave.
- The slave clone of agentfiles is behind `main` (at the Inbox design commit) and has no `~/.claude/skills/`.
- On the master the Claude Inbox is live (`triage-inbox` linked, page address set).
- The dotfiles repo has no `docs/` folder. It is a public GitHub repo.

## Parts

| Part | Path | What |
|---|---|---|
| Skill entry | `claude/skills/start-project-watchdog/SKILL.md` | trigger text; procedure A "make or hand off the watchdog" (launcher); procedure B "hand-off before ~500 k tokens" |
| Rule set | `claude/skills/start-project-watchdog/rules.md` | the full watchdog rules (section "Rule set" below). The watchdog reads it at its start and after each hand-off |
| Templates | `claude/skills/start-project-watchdog/templates/project-watchdog.md`, `templates/queue.md` | the project part and the decision queue header |
| Script | `claude/skills/start-project-watchdog/scripts/watchdog.sh` | the mechanical steps (below); macOS `/bin/bash` 3.2, no Homebrew tools |
| Install | `lib/common.sh` `install_watchdog_skill`; `roles/master/steps/70-watchdog.sh`; `roles/slave/steps/87-watchdog.sh` | links the skill folder to `~/.claude/skills/start-project-watchdog`, the same way as `install_session_sync` |
| Tests | `tests/watchdog-skill.test.sh`, `tests/watchdog-step.test.sh` | stub tests (section "Tests") |
| Lint | `Makefile` `lint` | adds `claude/skills/*/scripts/*.sh` to shellcheck |

### Script `watchdog.sh`

| Command | Does |
|---|---|
| `init <project dir>` | Checks that the folder is a git repo. Makes `docs/prompts/<project>-watchdog.md` from the template and `docs/decisions/queue.md` from its template, only if they do not exist (never overwrites). Prints the two paths and `created` or `kept`. `<project>` = the folder name. |
| `next-id <queue file>` | Prints the next free D-id: the highest number of all `D` ids and `ref` ids in both tables + 1, two digits minimum (`D01`). Never reuses an id. |
| `start-line <project dir> <model>` | Prints the title `<project> (watchdog)` and the start line `Run docs/prompts/<project>-watchdog.md. Model: <model>.` Refuses (exit 2) a Fable model unless `--owner-said-fable` is given. |
| `public <project dir>` | Prints `public` or `private` for the `origin` remote (`gh repo view --json visibility`; `unknown` when `gh` is missing). The skill keeps a public project part free of work names and hostnames. |

## Procedure A: make or hand off the watchdog (SKILL.md)

Run in a session whose folder is the project (on the machine where the watchdog must run). An argument may name another project folder.

1. **Check the tools.** `mcp__ccd_session__start_session`, `mcp__ccd_session__list_start_targets`, `mcp__ccd_session_mgmt__get_session`, `list_sessions` and `CronCreate` must be loadable (ToolSearch). If `start_session` is missing: go on, and at step 6 give the owner the start line.
2. **Find the old watchdog.** `list_sessions` for a title that ends in "(watchdog)" with this project folder. Ask the owner about a watchdog on the other machine (the master cannot list slave sessions; read its metadata over SSH when he agrees).
3. **Interview.** AskUserQuestion only when this session is not a watchdog; a watchdog (procedure B, or the old watchdog that runs the launcher) asks in chat. Only what is open: owned areas (what the watchdog keeps and what goes to other sessions), the session table (live sessions, what each owns), status sources (files, commands, skills, the other machine), the decision queue path (default `docs/decisions/queue.md`), a report or artifact (if any), the model (default Opus; Fable only on the owner's word).
4. **Write the project part.** `watchdog.sh init`, then fill the template with Edit: version line, start, role (short), owned areas, sessions table, status sources, machine facts (master/slave, how to reach the other one), open items, report. Public repo: titles and ids only, no work names, no hostnames. The owner approves the text before step 6.
5. **Commit** the project part and the queue file only on the owner's word; push only on his word.
6. **Start.** `watchdog.sh start-line`; then `start_session` (`initiation: user_asked`, `context: fresh`, `cwd` = the project, the model from step 3, title `<project> (watchdog)`, prompt = the start line). With no `start_session`: give the owner the start line and the title; he opens and pins the session.
7. Tell the owner one line: the new session, its model, and that the hand-off steps run there.

### Steps of the new watchdog (in the project part, from the template)

1. **Check the tools** (as A1). Missing `start_session`: say so in one line and stop the hand-off; the old watchdog stays.
2. **Own id.** `get_session("self")`. Set the title `<project> (watchdog)` and pin the session (`set_session_title`, `set_pinned`). Write the id into the project memory file `watchdog-session.md` (one line "ONE pinned watchdog = …") with its `MEMORY.md` line, and into the version line of the project part.
3. **Read** `rules.md` of this skill, the project part, the open rows of the decision queue, the Inbox items of the project.
4. **Tell the sessions.** One message to each live session of the table: "The <project> watchdog is now <title> (<id>); report here only, one line per milestone." A session on the other machine: send only when `ListAgents` lists it (Remote Control); else the owner tells it.
5. **Docs.** Current files that hold the old watchdog id get the new id (dated records keep the old id). Commit only on the owner's word.
6. **Tell the owner** one line: ready, the new id, and "unpin and archive the old watchdog (archive, not delete)".

## Procedure B: hand-off before ~500 k tokens (SKILL.md)

At about 500,000 context tokens (or when the tool set of a new session is necessary), the watchdog writes its state into the project part (sessions table, open items, facts only it knows), raises the version, and runs procedure A step 6 with its own project. The new session runs the steps above. The old one stops after step 6 of the new one.

## Rule set (`rules.md`)

Generic text, no project names. Each rule says "the owner" for the person who decides.

1. **Role: Inbox and router.** For each input, pick one route and name it in one line: inline (short, no file work); the owning session (send it with the full context); a sub-agent (one-shot, fully scoped, it reports milestones to the watchdog); a new work session (`start_session`: edits, discussion, the owner's code, its own history). Do no work on a task after it has an owner.
2. **One inbox.** Working sessions report only to the watchdog, one line per milestone. They do not message each other; the watchdog passes messages. The owner gets the route line, one result line per milestone and the decisions that need him. Details stay in the owning session.
3. **No AskUserQuestion in the watchdog.** A question = a chat message with the options, the recommended decision and what happens after 2 h; one D-row in the decision queue (re-read the file; `watchdog.sh next-id`; default = the recommendation; owner; status `open`; never rename or reuse an id) and one Inbox item (`triage-inbox`: `type: decision`, `default`, `links.ref` = the D-id); one wake-up 2 h later (`CronCreate` one-shot). Then continue with other work and end the turn.
4. **The 2 h default.** An answer within 2 h: act, write `decided <date>: <answer>` into the row and the item. No answer: take the recommendation, write `default taken <date time UTC>: <decision>`, act, say so in one line. Never a default for: a deletion, a plan or spec, a rule text, a commit or push, a write to a shared or external system.
5. **Check before passing on.** A session's report is a claim: check the files, the commits (`git log`) and the counts before telling the owner.
6. **No polling.** Wake-ups only for the 2 h decision default. Session reports arrive as notifications.
7. **Hand-off** before the context passes about 500 k tokens (procedure B).
8. **Start lines.** Every start of a session or sub-agent names the model (Sonnet or Opus; Haiku for readers). No Fable by default; Fable only on the owner's word, written in the start line. The start prompt names the task, the prompt file, the title and "report to <watchdog title> only, one line per milestone". After the start: one line to the owner (title and reason). With no `start_session`: write the prompt file and the start line; the owner opens the session.
9. **Two machines.** Name the machine of each fact (master or slave). Read the other machine over its SSH alias, read-only. Git over SSH on the slave works only while the credential cache holds a login from the slave's own Terminal; if a fetch or push fails there, tell the owner. Never type a password, never `sudo`.
10. **Commit and push.** Commit only on the owner's word; push only on his word.
11. **Bulk AI jobs.** More than 5 sub-agents, more than 1 child session or more than 500 model reads: pilot first with real usage (transcript `usage` fields, `get_usage` before and after), the owner approves the extrapolated cost; budget stop (the job budget, 60 % weekly, 50 % weekly Fable); small parents; never the Agent tool's token count as the cost.
12. **Deleting files.** No hard delete while the task is open; the clean-up step needs the owner's explicit "clean up" after a list of paths, count, size and the restore way; Trash or archive first; stop and ask when the disk forces a delete.
13. **HTML reports.** Answer first; TL;DR per section; open questions at the end; title = H1 = artifact name, no date in it; "As of HH:MM UTC, YYYY-MM-DD" under the H1; before sharing max 2 A4 pages and 1,400 words; after sharing no cut.
14. **Obsolete documents.** Move to `docs/archive/<type>/archived-<name>` with one first line; only after the owner confirms each file; never on the session's own decision.
15. **Report language.** ASD-STE100 Simplified Technical English. A yes/no question: "Yes" / "No" / "Not clear", 1–3 sentences, then "Do you need a deeper explanation?".

## Tests (written first, red before green)

`tests/watchdog-skill.test.sh` (temp folders, `/bin/bash`, a stub `gh` on PATH):
- `init` makes both files in a temp git repo; a second run prints `kept` and does not change them (checksum); a folder that is not a git repo fails.
- `next-id`: the template queue → `D01`; a queue with `D01`, `D07`, and a closed row `C02` with ref `D43` → `D44`.
- `start-line`: names the model and the title; `fable` (any case) exits 2; with `--owner-said-fable` it passes.
- `public`: stub `gh` prints `PUBLIC` → `public`; no `gh` → `unknown`.
- The skill text: `SKILL.md` front matter `name` = the folder name; `rules.md` holds each lesson (anchors: `AskUserQuestion`, `get_session("self")`, `start_session`, `2 h`, `deletion`, `500 k`, `Fable`, `credential cache`, `push only`); no `local_<hex>` session id and no `/Users/` path in the skill folder.

`tests/watchdog-step.test.sh` (copy of the inbox step test pattern): master 70 and slave 87 link the skill, a second run keeps the link, a foreign folder stays with a warning. `tests/dry-run.test.sh` covers the new steps without changes.

## Build order (one TDD iteration each; commit only on the owner's word)

1. Script + its tests (`init`, `next-id`, `start-line`, `public`), Makefile lint line.
2. `SKILL.md`, `rules.md`, templates + the skill-text test.
3. Install function + steps 70 / 87 + the step test. Then `make lint` and `make test` green.
4. Install on the master: `./bootstrap.sh master --only 70`.
5. Install on the slave, after the owner's push: in the slave clone `git pull --ff-only` (over SSH only while the credential cache holds; else the owner runs it in the slave Terminal), then `./bootstrap.sh slave --only 87`.
6. One line to the watchdog that sent this task.

Not in this plan (after it, on the owner's word): the first use for dotfiles — run `/start-project-watchdog` in a dotfiles session on the master; its project part goes into the public dotfiles repo.

## Open points

None. The owner approves or changes this plan.
