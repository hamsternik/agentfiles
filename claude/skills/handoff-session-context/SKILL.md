---
name: handoff-session-context
description: Measure this session's own context size and hand off the essentials of the session to a new session before the context gets too big (hand off at 40 % of the model's window, the successor runs by 50 %). Writes the hand-off file, starts the successor with the same model and title, marks the hand-off done, tells the watchdog or the owner. Use when the Stop hook says "Run the skill handoff-session-context", when the owner or a watchdog asks for a hand-off, at each wake-up of a loop session (check the size), when the owner asks "how big is the context?", to start, restore or retire a project watchdog session ("restore the watchdog", "start a new watchdog"), or for its status.
---

# Hand off the session context

A session stays below about half of its context window: a big context costs more per turn and the model makes more
mistakes. At **40 %** of the window the session hands off; by **50 %** the successor runs. (1 M window: 400 k / 500 k;
200 k window: 80 k / 100 k.) Decision D50 of the owner, 2026-11-23; skill since 2026-11-24.

Set-up: `C=${CLAUDE_SKILL_DIR}/scripts/context.py`, `W=~/.claude/skills/watchdog/scripts/watchdog.py` (the user-level skill `watchdog`).
This session's id is `${CLAUDE_SESSION_ID}`.
Install: per work project (a link in `<project>/.claude/skills/`, the hook in `<project>/.claude/settings.local.json`),
by the agentfiles watchdog step; not at user level.

## Check the size

`python3 $C size --session ${CLAUDE_SESSION_ID}` prints
`tokens=… window=… pct=… level=ok|handoff|over model=… source=cache|table|env|maxctx`.

- Tokens: input + cache write + cache read of the newest reply in this session's transcript.
- Window: the statusline cache (`~/.claude/context-window/<id>.json`), else the model table (Opus, Fable, Sonnet,
  Haiku 1 M; unknown 200 k). `HANDOFF_WINDOW_TOKENS`, `HANDOFF_AT_PCT`, `HANDOFF_MAX_PCT` override.
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
3. **Start the successor** on this machine with the same model. The successor's name is `<fixed title> #<its short
   id>`; the fixed title is the session title without a ` #xxxxxxxx` suffix.
   - `python3 $W handoff --title "<fixed title>" --handoff-file <file> --session ${CLAUDE_SESSION_ID} [--prompt-file <prompt>] --frontend rex`
     starts it in a Rex window (when this session runs in Rex: `REX_SESSION` is set). Without `--frontend rex`
     (terminal, the default) it prints the `claude` line: give it to the owner.
     It refuses Fable without the owner's word (add `--owner-said-fable` only when he said so for this job).
4. **Mark it:** `python3 $C mark-done --session ${CLAUDE_SESSION_ID} --file <hand-off file>`.
5. **Tell, in one line:** a working session tells its watchdog; a watchdog tells the owner in chat. The line: the
   hand-off file and the successor's name and window.
6. **Stop.** Do no more work in this session. The successor retires it (next section); a session cannot rename itself.

## First steps of a successor (its first prompt says so)

1. `python3 $W ready --session ${CLAUDE_SESSION_ID}`, then read the hand-off file and set the wake-ups and crons again.
2. Retire the old session with the command of your first prompt:
   `python3 $W retire --session <old id> --caller ${CLAUDE_SESSION_ID} --frontend <F>` (dry run: check the plan),
   then the same with `--yes`. With `--frontend rex` it types `/rename deprecated <old name>` and `/exit` into the old pane, checks the new name,
   waits for the old process to end, and renames its window `archived-<label>`. It refuses without your `ready`.

## Watchdog CLI (`$W` = `~/.claude/skills/watchdog/scripts/watchdog.py`, skill `watchdog`)

`watchdog.py` is the one entry point. It decides and knows no front-end. `--frontend terminal` (the default) only
prints, so it works everywhere; `--frontend rex` hands the decision to the Rex launcher (`scripts/launchers/`), from a
Rex pane or a plain terminal. Names never depend on the caller: the Rex session is the one labelled with the project
folder name (made when missing; `--rex S` overrides it), the window label is `<role> #<short id>` with the role from
the title (`proj (watchdog-master)` → `watchdog-master #de18597a`). `python3 $W help` lists every command.

- `python3 $W status [--title T]`: the sessions of a watchdog title (id, pid, name, context %, last activity);
  exit 3 on 2 live sessions of one title. `--check-files <files>` lists stale ids in prompt or memory files (no edit).
- **New watchdog:** `python3 $W new --title T --model <m> [--prompt-file <prompt>] --frontend rex`. It refuses
  while T runs.
- **Restore** (after Ctrl-C, an upgrade, a crash; the owner asks "restore the watchdog"):
  `python3 $W restore --title T --frontend rex`. It refuses while the old session runs or was active in
  the last 2 minutes. At level `handoff` or `over` the output has a WARNING: do not resume; hand off from a new
  session instead. The resumed session sets its crons, wake-ups and background processes again.

## Not in this skill

Auto-compact settings, the content of the project prompts, and the decision queue.
