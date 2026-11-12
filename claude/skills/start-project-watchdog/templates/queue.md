# Decision queue

Every open decision for the owner is one row here, with a default, an owner and a date. The watchdog adds a row when it asks
the owner a question (skill `start-project-watchdog`, rules.md rule 3) and adds one Inbox item with `links.ref` = the id.
The owner decides in chat; the session that gets the answer writes `decided <YYYY-MM-DD>: <answer>` into the status and acts.
After 2 h with no answer the watchdog takes the default and writes `default taken <YYYY-MM-DD HH:MM UTC>: <decision>`.
Never a default for a deletion, a plan or spec, a rule text, a commit or push, or a write to a shared or external system.
A decided or dropped row stays 7 days in the table, then moves to "Closed".

`status` = `open`, `decided <YYYY-MM-DD>: <answer>`, `default taken <YYYY-MM-DD HH:MM UTC>: <decision>`, or `dropped`.

Ids are stable references: never rename or reuse an id. To add a row, read this file again just before the write and take the next id
(`watchdog.sh next-id <this file>`: the highest `D` number in both tables + 1). A closed row gets the next free `C` id; its old `D` id
stays in the column "ref".

| id | opened | item | scope | default if no answer | owner | status |
|---|---|---|---|---|---|---|

## Closed

| id | ref | opened | item | status |
|---|---|---|---|---|
