---
name: sync-sessions-to-seat
description: Copy the owner's Claude desktop (Code tab) sessions from one seat/org to another, so the sidebar of the new seat shows them with full history. Use when the owner changes seats (for example, the weekly limit of one seat is used up), says "migrate my sessions", "copy sessions to the team/personal seat", "sync sessions between seats", or asks why a session is missing after a seat switch. Runs `af sessions` (agentfiles bin/af-sessions).
---

# Sync sessions to another seat

The desktop app keeps one metadata file per session, `local_<id>.json`, in
`~/Library/Application Support/Claude/claude-code-sessions/<account>/<org>/`, and shows only the folder of the active org.
The transcripts in `~/.claude/projects/` belong to no org; every seat reads the same files.
So a seat switch needs only a copy of the metadata files. `af sessions sync` does it:

- The newer `lastActivityAt` wins. An older target copy is replaced (backup first); a newer or equal one is kept.
- The copy gets the target org's connector list (`remoteMcpServersConfig` of the target's newest session) and loses `scheduledTaskId` / `scheduledRunContinued`.
- Sessions without a transcript on this Mac are skipped.
- Each `--apply` writes a run folder `~/.claude/session-sync/<UTC time>-<org>/` with `manifest.tsv`, `target` and `backup/`. `af sessions undo <run folder>` takes it back.

Set-up: `A=~/Developer/_hamsternik/agentfiles/bin/af` (or `af` on PATH).

## Procedure

1. List the orgs: `$A sessions orgs`. The org that holds the current session is the target, usually the one marked `active`. If the target org has no session yet, ask the owner to open one session in the app on that seat first (it gives the connector list).
2. Ask the owner only what is not clear: the projects (`--project <dir>`, repeat; default all), the window (`--days N`, default 10), archived sessions (`--include-archived`).
3. Dry run: `$A sessions sync --to <org prefix> --days N --project <dir> ...`. Show the owner the add / replace / skip lines and the totals. Each line: action, session id (8 chars), skip reason, last activity (UTC), project, title.
4. Wait for the owner's yes. Then run the same command with `--apply`.
   Auto mode blocks this write ("Session Transcript Tampering"), even with an allow rule. Ask the owner to switch this session to Manual (Ask) mode and approve the command.
5. Report the totals and the run folder. Tell the owner to restart the Claude app (it reads the folders only at start).
6. After the restart, check one copied session: it opens with its full history.

## Rules

- Never work on the same session on two seats at the same time: both apps write the same transcript.
- The copy is one-way per run. To go back later, run `sync` again in the other direction; the newer side wins.
- An artifact published from one org cannot be republished to the same link from another org.
- Undo: `$A sessions undo <run folder>` (moves added files into `<run folder>/removed/`, restores replaced files from `backup/`), then restart the app.
- Never delete session files; undo moves them.
