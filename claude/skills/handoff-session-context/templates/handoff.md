# Hand-off: <title>, <machine> — <YYYY-MM-DD>

Written by session `<old session id>` (<model>) at <tokens> context tokens (<pct> % of <window>), <HH:MM> UTC.
Read first: <the session's prompt file, or "none">, then this file. Keep this file short: 60–150 lines.

## State

- Git: <repo>, <branch>, at `<commit>`, <clean / what is not committed>.
- Running processes: <PID> `<command>` → log `<path>` (one line each; "none" if none).
- Files being written: <path> (by whom).
- Crons / wake-ups: <none, or what and when (UTC)>. The old session deleted its own.

## Open items

1. <What> — owner <who>, waits on <whom/what>, default <if any>.

## Facts

- <Only what this session learned and no file holds yet: paths, ids, numbers, decisions said in chat.>

## Next steps

1. <First step of the successor.>
- Next wake-up: <HH:MM UTC, or none>.

## Hand-off steps

- Done by the old session: this file; successor started (<Rex window or command>); hook marked done; <watchdog/owner> told.
- For the owner: rename the old session to `deprecated <title>` (`/rename`) and `/exit` it, so that only one session has the title.
