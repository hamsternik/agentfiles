#!/usr/bin/env python3
"""Tests of `watchdog.py queue add|list|decide|default|close` (dqueue.py). Use cases 15-21 and 23 of
docs/local/PLAN-watchdog-skill.md. The clock is WATCHDOG_NOW; the Inbox CLI is a stub (WATCHDOG_AF)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "watchdog.py"
sys.path.insert(0, str(HERE.parent / "scripts"))
import dqueue  # noqa: E402

TEMPLATE = (HERE.parent / "templates" / "queue.md").read_text()
SHELF = """# Decision queue

Rules text.

| id | opened | item | rows / scope | default if no answer | owner | status |
|---|---|---|---|---|---|---|
| D62 | 2026-11-18 | old open item | a | none: the owner decides | owner | open |
| D65 | 2026-11-10 | decided long ago | b | A | owner | decided 2026-11-12: A |
| D66 | 2026-11-24 | decided lately | c | A | owner | decided 2026-11-25: A |

## Closed

| id | ref | opened | item | status |
|---|---|---|---|---|
| C03 | D40 | 2026-10-01 | x | dropped |
"""


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.root = Path(self._td.name).resolve()
        self.proj = self.root / "proj"
        self.proj.mkdir()
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)
        self.q = self.proj / ".claude/docs/decisions/queue.md"
        self.q.parent.mkdir(parents=True)
        self.q.write_text(TEMPLATE)
        self.af_log = self.root / "af.log"
        self.af = self.root / "af"
        self.af.write_text(f"#!/bin/sh\necho \"$@\" >> {self.af_log}\n"
                           "[ \"$2\" = add ] && echo I-20261126-ab12\nexit 0\n")
        self.af.chmod(0o755)
        self.now = "2026-11-26T12:00:00Z"

    def tearDown(self):
        self._td.cleanup()

    def cli(self, *args, af=True, now=None):
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_PROJECT_DIR")}
        env["WATCHDOG_NOW"] = now or self.now
        env["TZ"] = "UTC"  # the CronCreate line is in local time
        env["WATCHDOG_AF"] = str(self.af) if af else str(self.root / "missing-af")
        return subprocess.run([sys.executable, str(SCRIPT), "queue", *args], text=True, capture_output=True,
                              env=env, cwd=self.proj)

    def rows(self):
        return dqueue.Queue(self.q.read_text()).rows()

    def af_calls(self):
        return self.af_log.read_text().splitlines() if self.af_log.exists() else []


# 15. add: one row under the header, next id, open, today; the file is read again before the write
class TestAdd(Base):
    def test_add_one_row(self):
        r = self.cli("add", "--item", "Pick A or B", "--default", "A", "--scope", "rows 1-3")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["id"], "D01")
        self.assertEqual(row["opened"], "2026-11-26 12:00 UTC")
        self.assertTrue(row["item"].startswith("Pick A or B"))
        self.assertEqual((row["scope"], row["default"], row["owner"], row["status"]), ("rows 1-3", "A", "owner", "open"))
        self.assertIn("D01", r.stdout)

    def test_another_writer_between_two_adds(self):
        self.cli("add", "--item", "first", "--default", "A")
        text = self.q.read_text().replace("| D01 |", "| D01 |", 1)
        lines = text.splitlines()
        i = max(n for n, x in enumerate(lines) if x.startswith("| D01 "))
        lines.insert(i + 1, "| D02 | 2026-11-26 | by hand | x | B | owner | open |")
        self.q.write_text("\n".join(lines) + "\n")
        self.cli("add", "--item", "third", "--default", "C")
        self.assertEqual([r["id"] for r in self.rows()], ["D01", "D02", "D03"])

    def test_cells_with_a_pipe_are_escaped(self):
        self.cli("add", "--item", "a | b", "--default", "x|y")
        row = self.rows()[0]
        self.assertTrue(row["item"].startswith("a | b"), row)
        self.assertEqual(row["default"], "x|y")
        self.assertEqual(len(self.rows()), 1)

    # 16. add queues one Inbox item; with no Inbox the row is still written
    def test_add_queues_one_inbox_item(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        calls = self.af_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("inbox add --type decision --title Pick"), calls[0])
        self.assertIn("--ref D01", calls[0])
        self.assertIn("--project proj", calls[0])
        self.assertIn("--default A", calls[0])
        self.assertTrue(self.rows()[0]["item"].endswith("· Inbox I-20261126-ab12"), self.rows()[0]["item"])

    def test_no_inbox_warns_and_writes_the_row(self):
        r = self.cli("add", "--item", "Pick", "--default", "A", af=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Inbox", r.stderr)
        self.assertEqual(self.rows()[0]["item"], "Pick")

    # 17. the wake-up lines
    def test_wake_up_lines(self):
        out = self.cli("add", "--item", "Pick", "--default", "A").stdout
        self.assertIn('ScheduleWakeup delaySeconds=7200 prompt="watchdog queue default D01"', out)
        self.assertIn('CronCreate cron="0 14 26 11 *" recurring=false prompt="watchdog queue default D01"', out)


# 18. list: open rows with age; --all: every row of the main table
class TestList(Base):
    def setUp(self):
        super().setUp()
        self.q.write_text(SHELF)

    def test_open_rows_with_age(self):
        r = self.cli("list")
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("D62  open  204 h"), lines[0])

    def test_all(self):
        lines = self.cli("list", "--all").stdout.splitlines()
        self.assertEqual([x.split()[0] for x in lines], ["D62", "D65", "D66"])

    def test_json(self):
        d = json.loads(self.cli("list", "--json").stdout)
        self.assertEqual([r["id"] for r in d], ["D62"])


# 19. decide
class TestDecide(Base):
    def test_decide_writes_the_status_and_the_inbox_answer(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        r = self.cli("decide", "D01", "B, as the owner said")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["status"], "decided 2026-11-26: B, as the owner said")
        self.assertIn("inbox answer I-20261126-ab12 B, as the owner said", self.af_calls()[-1])

    def test_unknown_id_exit_1_file_unchanged(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        before = self.q.read_bytes()
        r = self.cli("decide", "D09", "B")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.q.read_bytes(), before)

    def test_a_decided_row_is_not_decided_again(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        self.cli("decide", "D01", "B")
        r = self.cli("decide", "D01", "C")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.rows()[0]["status"], "decided 2026-11-26: B")


# 20. default: only an open row 2 h old or more whose default does not start with "none"
class TestDefault(Base):
    def test_too_young(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        r = self.cli("default", "D01", now="2026-11-26T13:59:00Z")
        self.assertEqual(r.returncode, 2)
        self.assertIn("2 h", r.stderr)
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_none_default_never_taken(self):
        self.cli("add", "--item", "Delete the pictures?", "--default", "none: a deletion waits for the owner")
        r = self.cli("default", "D01", now="2026-11-27T12:00:00Z")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_taken_after_2_h(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        r = self.cli("default", "D01", now="2026-11-26T14:00:00Z")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["status"], "default taken 2026-11-26 14:00 UTC: A")
        self.assertIn("inbox answer I-20261126-ab12 default taken", self.af_calls()[-1])

    def test_decided_row_is_left_alone(self):
        self.cli("add", "--item", "Pick", "--default", "A")
        self.cli("decide", "D01", "B")
        self.assertEqual(self.cli("default", "D01", now="2026-11-27T12:00:00Z").returncode, 2)


# 21. close: rows closed more than 7 days ago move to "Closed"
class TestClose(Base):
    def setUp(self):
        super().setUp()
        self.q.write_text(SHELF)

    def test_close_moves_old_closed_rows_only(self):
        r = self.cli("close")
        self.assertEqual(r.returncode, 0, r.stderr)
        q = dqueue.Queue(self.q.read_text())
        self.assertEqual([x["id"] for x in q.rows()], ["D62", "D66"])
        closed = q.closed()
        self.assertEqual([(x["id"], x["ref"]) for x in closed], [("C03", "D40"), ("C04", "D65")])
        self.assertEqual(closed[-1]["status"], "decided 2026-11-12: A")
        self.assertEqual(closed[-1]["item"], "decided long ago")
        self.assertIn("Rules text.", self.q.read_text())


# 23. the shelf header ("rows / scope") and the template header ("scope") read the same
class TestHeaders(Base):
    def test_both_headers(self):
        self.assertEqual(dqueue.Queue(SHELF).rows()[0]["scope"], "a")
        self.q.write_text(TEMPLATE)
        self.cli("add", "--item", "x", "--default", "y", "--scope", "s")
        self.assertEqual(self.rows()[0]["scope"], "s")

    def test_other_lines_stay_byte_for_byte(self):
        self.q.write_text(SHELF)
        self.cli("add", "--item", "new", "--default", "A")
        old, new = SHELF.splitlines(), self.q.read_text().splitlines()
        self.assertEqual([x for x in new if not x.startswith("| D67 ")], old)


if __name__ == "__main__":
    unittest.main()
