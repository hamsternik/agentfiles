---
name: handoff-session-context
description: Measure this session's own context size and hand off the essentials of the session to a new session before the context gets too big (hand off at 40 % of the model's window, the successor runs by 50 %). Writes the hand-off file, starts the successor with the same model and title, marks the hand-off done, tells the watchdog or the owner. Use when the Stop hook says "Run the skill handoff-session-context", when the owner or a watchdog asks for a hand-off, at each wake-up of a loop session (check the size), when the owner asks "how big is the context?", or to restore the latest session of a fixed title ("restore the watchdog") after Ctrl-C or an upgrade.
---

# Hand off the session context

A session stays below about half of its context window: a big context costs more per turn and the model makes more
mistakes. At **40 %** of the window the session hands off; by **50 %** the successor runs. (1 M window: 400 k / 500 k;
200 k window: 80 k / 100 k.) Decision D50 of the owner, 2026-11-23; skill since 2026-11-24.

Set-up: `C=${CLAUDE_SKILL_DIR}/scripts/context.py`. This session's id is `${CLAUDE_SESSION_ID}`.
Install: per work project (a link in `<project>/.claude/skills/`, the hook in `<project>/.claude/settings.local.json`),
by the agentfiles watchdog step; not at user level.

## Check the size

`python3 $C size --session ${CLAUDE_SESSION_ID}` prints
`tokens=… window=… pct=… level=ok|handoff|over model=… source=cache|table|env|maxctx`.

- Tokens: input + cache write + cache read of the newest reply in this session's transcript.
- Window: the statusline cache (`~/.claude/context-window/<id>.json`), else the model table (Opus, Fable, Sonnet 1 M;
  Haiku and unknown 200 k). `HANDOFF_WINDOW_TOKENS`, `HANDOFF_AT_PCT`, `HANDOFF_MAX_PCT` override.
- A loop session (chain watcher, OCR parent, watchdog) runs the check at each wake-up. At `handoff` or `over`: hand off.
- A watchdog may check a loop session of its machine with `--session <that id>` and ask it to run this skill.

The Stop hook (`context.py hook`, project `settings.local.json`) runs the same check after each turn. At 40 % and at 45 % it asks once;
from 50 % it asks after every turn. After step 4 below it stays silent for this session.

## Hand off

1. **Finish the current step.** Start no new work. Stop the loop: delete this session's crons, set no new wake-up.
2. **Write the hand-off file** from `${CLAUDE_SKILL_DIR}/templates/handoff.md`. Place:
   - the session works with a `RUN.md` (a job, batch or chain folder): `HANDOFF.md` in that folder;
   - else: `python3 $C handoff-path --cwd "$PWD" --title "<session title>"` (`docs/local/` of the repo, else the cwd).
   Never overwrite a hand-off file. Write only the essentials: the successor works from this file and the project
   files, not from this chat. State, running processes with PIDs, open items, facts no file holds yet, next steps.
3. **Start the successor** on this machine with the same model and the same title. First prompt:
   `Read <hand-off file> first, then <prompt file, if any>. You continue the work of session ${CLAUDE_SESSION_ID}. Run the hand-off steps of its file.`
   - In Rex (`REX_SESSION` is set): `rex window new -s <rex session> <label>-2 -c <cwd> --keep-open -- claude --model <model> -n "<title>" --remote-control "<title>" "<first prompt>"`
     (`rex whoami --json` gives the Rex session and the window label).
   - Else, if `start_session` exists: the same model, title, cwd and first prompt.
   - Else: start nothing; give the owner the start line.
   - Fable only on the owner's word for this job (org rule). If the old session runs on Fable and has no record of his
     word, start on Opus and say so.
4. **Mark it:** `python3 $C mark-done --session ${CLAUDE_SESSION_ID} --file <hand-off file>`.
5. **Tell, in one line:** a working session tells its watchdog (by the bare fixed title); a watchdog tells the owner in
   chat. The line: the hand-off file, where the successor runs, and "rename the old session to `deprecated <title>` with
   `/rename` and `/exit` it".
6. **Stop.** Do no more work in this session. Do not rename or exit it: the owner does that (a session cannot run
   `/rename` on itself).

## Restore a session of a fixed title (after Ctrl-C, an upgrade, a crash)

Use when the owner asks "restore the watchdog" (or another session with a fixed title) in a new window.

1. `python3 ${CLAUDE_SKILL_DIR}/scripts/latest.py --title "<fixed title>" [--project-dir <dir>]` prints the latest
   session of that title (its own last title record; forks and renames handled), its context level and the exact
   `claude --resume …` line. Exit 1: no such session.
2. Level `handoff` or `over` (the script prints a WARNING): do not resume. Start a new session from a hand-off file instead.
3. Else open it: add `--rex <rex session> --label <window label>` (or give the owner the line). The script refuses
   (exit 2) while the old session still runs (a live pid in `~/.claude/sessions/`) or was active in the last 2 minutes.
   Never resume one id in two windows.
4. The resumed session sets its crons, wake-ups and background processes again: they stop with the old process.

## Not in this skill

Auto-compact settings, the content of the project prompts, and the decision queue.
