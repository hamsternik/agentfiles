# Claude Inbox

One list of tasks and decisions for every Claude session on the master and the slave. There is no GUI: the owner manages the Inbox by asking watchdog sessions, on a Mac or from the phone through Remote Control. Every watchdog reads and writes the same Inbox. Goal: Zero Inbox at the end of each work day.

## Parts

| Part | Where | What |
|---|---|---|
| Inbox db | the db of one private artifact page (claude.ai) | the truth: collection `items`, one document per item |
| Holder page | `claude/inbox/page.html`, published as an artifact | no interface; it exists because the db belongs to a page, and its rules keep the db owner-only. Deleting it deletes the Inbox |
| Skill | `claude/skills/triage-inbox/` | how sessions list, add, move, flush, review and prune |
| `af inbox` | `bin/af-inbox` | the local side: outbox, local log, role, page URL |
| Install step | `roles/master/steps/50-inbox.sh`, `roles/slave/steps/85-inbox.sh` | links the skill to `~/.claude/skills/triage-inbox` and `af` to `~/.claude/inbox/af` |

Session transcripts stay on the machine that runs them; nothing copies them to the other Mac. The db is the shared layer.

## Item and states

Fields: see the skill, section 1. States:

| State | Meaning | Who moves it out |
|---|---|---|
| `inbox` | the owner must act: decision, approval, review, human step | the owner |
| `in_progress` | an agent works on it (long tasks only) | the agent |
| `waiting` | an external event; `wake` is required | the event or the wake date |
| `snoozed` | the owner chose "later"; `wake` is required | the wake date |
| `done` | an agent says it is done | the owner confirms → `archived`, or sends it back |
| `archived` | closed | — |

The Inbox view = `inbox` + `done` + `waiting`/`snoozed` items whose `wake` is today or earlier. Only the owner snoozes, archives or closes a decision. No session waits on a question: it adds an `inbox` item with a `default`, takes the default, and continues.

## History

The db keeps no history (an artifact db holds at most 25,000 documents, 256 KiB each). Each item keeps `prev_state`, `updated_at` and `updated_by`; `undo` goes back one step. Each machine appends the changes of its sessions to `~/.claude/inbox/log-<role>.jsonl`. Archived items older than `AF_INBOX_PRUNE_DAYS` move to `~/.claude/inbox/export-<YYYYMM>.jsonl`.

## Concurrency

- The db: every session write pins the version it read (`if_version`); a write that collides fails (`version_mismatch`, tested 2026-11-05) and the session re-reads and redoes it.
- The outbox: one line per change, at most `AF_INBOX_MAX_LINE_BYTES`, appended under a lock (`/usr/bin/perl` flock; macOS has no flock(1)). `take` renames the outbox under the same lock; a `take` without an `ack` returns the same lines again.

## Files on each machine (`~/.claude/inbox/`)

| File | Content |
|---|---|
| `url` | the address of the holder page (`af inbox url <url>`) |
| `outbox-<role>.jsonl` | changes queued while the db was out of reach |
| `outbox-<role>.sending.jsonl` | lines taken by a flush, not yet acked |
| `log-<role>.jsonl` | changes this machine wrote |
| `export-<YYYYMM>.jsonl` | pruned items and the monthly backup |
| `af` | link to `bin/af` |

The role comes from `AF_INBOX_ROLE`, else the af role (`$AF_HOME/state/role`), else `master`.

## Set up a machine

1. `make master` or `make slave` (or run the inbox step alone: `./bootstrap.sh <role> --only 50` on the master, `--only 85` on the slave).
2. `~/.claude/inbox/af inbox url <https://claude.ai/artifact/...>` with the address of the one holder page (the same on every machine).
3. Sign in to the same claude.ai account in the Claude desktop app, and turn on Remote Control for new sessions, so the owner reaches the watchdogs from the phone.
4. On the slave: one pinned watchdog session (Remote Control on) that reads the slave's run files, writes items and flushes the slave outbox.

## Headless runs

A headless run (`claude -p`, a scheduled task) can use the db: the tool is deferred, so allow both tools, for example `claude -p "<prompt>" --allowedTools "ToolSearch,ArtifactData"`. Tested 2026-11-05: a read of `items` worked. A run without that allowance uses the outbox.
