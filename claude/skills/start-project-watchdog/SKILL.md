---
name: start-project-watchdog
description: Make or hand off the ONE pinned watchdog session of a project ("<project> (watchdog)") on the master or the slave Mac. Interviews the owner, writes the short project part .claude/docs/prompts/<project>-watchdog.md and .claude/docs/decisions/queue.md, and starts the new watchdog with start_session (model named, no Fable). The skill carries the full watchdog rule set (rules.md), so it works in projects whose folder has no watchdog rules. Use when the owner says "start a watchdog for this project", "make the <project> watchdog", "replace the watchdog", "hand off the watchdog", or when a watchdog nears 500 k context tokens.
---

# Start a project watchdog

A project has ONE pinned watchdog session, "<project> (watchdog)": the owner's inbox and router. Every other session of the
project is a working session and reports only to it. The rules of the watchdog are in `rules.md` (this folder); the project
facts are in `.claude/docs/prompts/<project>-watchdog.md` in the project.

Set-up: `W=~/.claude/skills/start-project-watchdog/scripts/watchdog.sh` (agentfiles links this folder on the master and the slave).

## A. Make or replace the watchdog (launcher)

Run in a session whose folder is the project, on the machine where the watchdog must run. An argument may name another project folder.

1. **Check the tools.** Load with ToolSearch: `mcp__ccd_session__start_session`, `mcp__ccd_session__list_start_targets`,
   `mcp__ccd_session_mgmt__get_session`, `mcp__ccd_session_mgmt__list_sessions`, `mcp__ccd_session_mgmt__detach_session`,
   `CronCreate`. If `start_session` or `detach_session` is missing, continue; step 6 then gives the owner the start line.
2. **Find the old watchdog.** `list_sessions`: a title that ends in "(watchdog)" with this project folder. This lists only this
   machine: ask the owner about a watchdog on the other machine, and read its metadata over SSH only when he agrees. If an old
   watchdog exists, read its project part and memory: its sessions table, open items and facts go into the new project part.
3. **Interview.** Use `AskUserQuestion` only when this session is not a watchdog; a watchdog asks in chat (rules.md, rule 3).
   Ask only what is still open:
   - owned areas: what the watchdog keeps, and what goes to which session;
   - the sessions table: live sessions, machine, what each owns;
   - status sources: files, commands, skills, the other machine;
   - the decision queue path (default `.claude/docs/decisions/queue.md`);
   - a report or artifact, if any;
   - the model of the watchdog (default Opus; Fable only on the owner's word).
4. **Write the project part.** `$W init <project dir>` makes `.claude/docs/prompts/<project>-watchdog.md` and `.claude/docs/decisions/queue.md`
   from the templates (it never overwrites; an existing file is `kept`, then edit it). Fill each section with Edit: version line,
   start (machine, model), owned areas, sessions, status sources, machines, report, open items, facts only the old watchdog knew.
   `$W public <project dir>`: if `public`, write session titles and ids only: no employer, client or work names, no hostnames,
   no IPs, no emails. Show the owner the text and wait for his approval.
5. **Commit** the two files only on the owner's word; push only on the owner's word.
6. **Start.** `$W start-line <project dir> <model>` (exit 2 = Fable without the owner's word: ask him). Then `start_session`:
   `initiation: "user_asked"`, `context: "fresh"`, `cwd` = the project folder, `use_worktree: false` (the project folder itself),
   `model` = the model, `title` = the printed title, `prompt` = the printed start line, `background` = one paragraph on the
   hand-off. At once after the start, call `mcp__ccd_session_mgmt__detach_session` with the new session id: the watchdog must be a
   standalone top-level session of the project, not a session nested under this launcher (and not archived with it). Check with
   `get_session` that `detached` is true and `cwd` is the project folder.
   With no `start_session` or no `detach_session`, start nothing: give the owner the title and the one-line start prompt; he
   opens a new session in the project folder on the right machine, runs the line, and pins the session.
7. **Tell the owner** one line: the new session, its machine and model, and that the hand-off steps run there (steps 1–6 of
   the project part: own id from `get_session("self")`, title and pin, memory and docs, "report here only" to the live
   sessions, and "archive the old watchdog, never delete").

## B. Hand-off before 500 k tokens

Run in the watchdog itself, before its context passes about 500 k tokens, or when a new session has tools this one lacks.
1. Write the state into the project part: the sessions table (with the time, UTC), the open items, the open D-rows, the facts
   only this session knows. Raise the version line (`v1.1`, date, "written by" = your id).
2. Ask the owner in chat for the commit of the project part (no default; rules.md, rule 4).
3. Run procedure A, step 6 (same machine, same model unless the owner says another).
4. After the new watchdog reports "ready": send nothing more; tell the live sessions nothing (the new one does it). Stop.

## Not in this skill

The Inbox itself (skill `triage-inbox`), status reports of a project (a project skill), and the work of the working sessions.
