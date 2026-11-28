#!/usr/bin/env python3
"""Tests of `watchdog.py queue add|list|ref|decide|default|close` (dqueue.py). Use cases 15-21 and 23 of
docs/local/PLAN-watchdog-skill.md; the row titles ("title N") are the use cases of
docs/local/queue-titles-prompt-20261127.md. The clock is WATCHDOG_NOW; the Inbox CLI is a stub (WATCHDOG_AF)."""
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

    def add(self, *args, title="pick one", **kw):
        return self.cli("add", "--title", title, *args, **kw)

    def rows(self):
        return dqueue.Queue(self.q.read_text()).rows()

    def af_calls(self):
        return self.af_log.read_text().splitlines() if self.af_log.exists() else []


# 15. add: one row under the header, next id, open, today; the file is read again before the write
class TestAdd(Base):
    def test_add_one_row(self):
        r = self.add("--item", "Pick A or B", "--default", "A", "--scope", "rows 1-3")
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual(row["id"], "D01")
        self.assertEqual(row["opened"], "2026-11-26 12:00 UTC")
        self.assertTrue(row["item"].startswith("**pick one** — Pick A or B"), row["item"])
        self.assertEqual((row["scope"], row["default"], row["owner"], row["status"]), ("rows 1-3", "A", "owner", "open"))
        self.assertIn("D01", r.stdout)

    def test_another_writer_between_two_adds(self):
        self.add("--item", "first", "--default", "A")
        text = self.q.read_text().replace("| D01 |", "| D01 |", 1)
        lines = text.splitlines()
        i = max(n for n, x in enumerate(lines) if x.startswith("| D01 "))
        lines.insert(i + 1, "| D02 | 2026-11-26 | by hand | x | B | owner | open |")
        self.q.write_text("\n".join(lines) + "\n")
        self.add("--item", "third", "--default", "C")
        self.assertEqual([r["id"] for r in self.rows()], ["D01", "D02", "D03"])

    def test_cells_with_a_pipe_are_escaped(self):
        self.add("--item", "a | b", "--default", "x|y")
        row = self.rows()[0]
        self.assertTrue(row["item"].startswith("**pick one** — a | b"), row)
        self.assertEqual(row["default"], "x|y")
        self.assertEqual(len(self.rows()), 1)

    # 16. add queues one Inbox item; with no Inbox the row is still written
    def test_add_queues_one_inbox_item(self):
        self.add("--item", "Pick", "--default", "A")
        calls = self.af_calls()
        self.assertEqual(len(calls), 1, calls)
        self.assertTrue(calls[0].startswith("inbox add --type decision --title pick one — Pick --ref "), calls[0])
        self.assertIn("--ref D01", calls[0])
        self.assertIn("--project proj", calls[0])
        self.assertIn("--default A", calls[0])
        self.assertTrue(self.rows()[0]["item"].endswith("· Inbox I-20261126-ab12"), self.rows()[0]["item"])

    def test_no_inbox_warns_and_writes_the_row(self):
        r = self.add("--item", "Pick", "--default", "A", af=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("Inbox", r.stderr)
        self.assertEqual(self.rows()[0]["item"], "**pick one** — Pick")

    # 17. the wake-up lines
    def test_wake_up_lines(self):
        out = self.add("--item", "Pick", "--default", "A").stdout
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
        self.assertEqual(lines[0], "D62 (old open item)  open  since 2026-11-18")  # a date only: no hours

    def test_all(self):
        lines = self.cli("list", "--all").stdout.splitlines()
        self.assertEqual([x.split()[0] for x in lines], ["D62", "D65", "D66"])

    def test_json(self):
        d = json.loads(self.cli("list", "--json").stdout)
        self.assertEqual([r["id"] for r in d], ["D62"])


# 19. decide
class TestDecide(Base):
    def test_decide_writes_the_status_and_the_inbox_answer(self):
        self.add("--item", "Pick", "--default", "A")
        r = self.cli("decide", "D01", "B, as the owner said")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["status"], "decided 2026-11-26: B, as the owner said")
        self.assertIn("inbox answer I-20261126-ab12 B, as the owner said", self.af_calls()[-1])

    def test_unknown_id_exit_1_file_unchanged(self):
        self.add("--item", "Pick", "--default", "A")
        before = self.q.read_bytes()
        r = self.cli("decide", "D09", "B")
        self.assertEqual(r.returncode, 1)
        self.assertEqual(self.q.read_bytes(), before)

    def test_a_decided_row_is_not_decided_again(self):
        self.add("--item", "Pick", "--default", "A")
        self.cli("decide", "D01", "B")
        r = self.cli("decide", "D01", "C")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.rows()[0]["status"], "decided 2026-11-26: B")


# 20. default: only an open row 2 h old or more whose default does not start with "none"
class TestDefault(Base):
    def test_too_young(self):
        self.add("--item", "Pick", "--default", "A")
        r = self.cli("default", "D01", now="2026-11-26T13:59:00Z")
        self.assertEqual(r.returncode, 2)
        self.assertIn("2 h", r.stderr)
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_none_default_never_taken(self):
        self.add("--item", "Delete the pictures?", "--default", "none: a deletion waits for the owner")
        r = self.cli("default", "D01", now="2026-11-27T12:00:00Z")
        self.assertEqual(r.returncode, 2)
        self.assertEqual(self.rows()[0]["status"], "open")

    def test_taken_after_2_h(self):
        self.add("--item", "Pick", "--default", "A")
        r = self.cli("default", "D01", now="2026-11-26T14:00:00Z")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["status"], "default taken 2026-11-26 14:00 UTC: A")
        self.assertIn("inbox answer I-20261126-ab12 default taken", self.af_calls()[-1])

    def test_date_only_row_counts_from_the_end_of_its_day(self):
        """A row with a date only (written by hand) may have been made at 23:59: no default on that day."""
        self.q.write_text(SHELF.replace("| D62 | 2026-11-18 | old open item | a | none: the owner decides |",
                                        "| D62 | 2026-11-26 | old open item | a | A |"))
        self.assertEqual(self.cli("default", "D62", now="2026-11-26T23:00:00Z").returncode, 2)
        self.assertEqual(self.cli("default", "D62", now="2026-11-27T02:00:00Z").returncode, 0)

    def test_decided_row_is_left_alone(self):
        self.add("--item", "Pick", "--default", "A")
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
        self.add("--item", "x", "--default", "y", "--scope", "s")
        self.assertEqual(self.rows()[0]["scope"], "s")

    def test_other_lines_stay_byte_for_byte(self):
        self.q.write_text(SHELF)
        self.add("--item", "new", "--default", "A")
        old, new = SHELF.splitlines(), self.q.read_text().splitlines()
        self.assertEqual([x for x in new if not x.startswith("| D67 ")], old)


# title 1-8. add --title: required, at most 8 words, no "|", no line break, no "**"; the item starts with the prefix
class TestAddTitle(Base):
    def assert_refused(self, r, before):
        self.assertEqual(r.returncode, 64, r.stderr)
        self.assertNotIn("unrecognized arguments", r.stderr)
        self.assertIn("title", r.stderr)
        self.assertEqual(self.q.read_bytes(), before)
        self.assertEqual(self.af_calls(), [])

    def test_item_starts_with_the_title(self):
        r = self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(self.rows()[0]["item"],
                         "**push of SM main** — Push it now? · Inbox I-20261126-ab12")

    def test_title_is_required(self):
        before = self.q.read_bytes()
        self.assert_refused(self.cli("add", "--item", "Pick", "--default", "A"), before)

    def test_bad_titles_are_refused(self):
        before = self.q.read_bytes()
        for title in ("", "   ", "a | b", "a|b", "line\nbreak", "carriage\rreturn", "bold ** inside"):
            with self.subTest(title=title):
                self.assert_refused(self.add("--item", "Pick", "--default", "A", title=title), before)

    def test_9_words_are_refused(self):
        before = self.q.read_bytes()
        self.assert_refused(self.add("--item", "Pick", "--default", "A", title="1 2 3 4 5 6 7 8 9"), before)

    def test_8_words_pass(self):
        r = self.add("--item", "Pick", "--default", "A", title="1 2 3 4 5 6 7 8")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.rows()[0]["item"].startswith("**1 2 3 4 5 6 7 8** — Pick"))


# title 9-11. list: the id with the title, the status and the age; --json: a title field beside the full item
class TestListTitle(Base):
    def test_line_of_a_new_row(self):
        self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        self.assertEqual(self.cli("list").stdout, "D01 (push of SM main)  open  0 h\n")

    def test_all_has_the_same_form(self):
        self.q.write_text(SHELF)
        self.assertEqual(self.cli("list", "--all").stdout.splitlines(), [
            "D62 (old open item)  open  since 2026-11-18",
            "D65 (decided long ago)  decided 2026-11-12: A  since 2026-11-10",
            "D66 (decided lately)  decided 2026-11-25: A  since 2026-11-24",
        ])

    def test_json_has_the_title_and_the_full_item(self):
        self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        row = json.loads(self.cli("list", "--json").stdout)[0]
        self.assertEqual(row.get("title"), "push of SM main")
        self.assertEqual(row["item"], "**push of SM main** — Push it now? · Inbox I-20261126-ab12")


# title 12-15. an old row (no prefix): the start of the item up to ":" or "(", at most 60 characters, cut at a word
class TestOldRowTitle(Base):
    def put(self, item, rid="D62"):
        self.q.write_text(SHELF.replace("| D62 | 2026-11-18 | old open item |", f"| {rid} | 2026-11-18 | {item} |"))

    def title(self, item, rid="D62"):
        self.put(item, rid)
        r = self.cli("list", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        return json.loads(r.stdout)[0].get("title")

    def test_stops_at_a_colon_or_a_parenthesis(self):
        self.assertEqual(self.title("Batch phase 2: restart it?"), "Batch phase 2")
        self.assertEqual(self.title("API key 2 (in the playbook) is full"), "API key 2")

    def test_a_clock_time_does_not_cut(self):
        self.assertEqual(self.title("Chain stopped 01:44 UTC: the grid is ok"), "Chain stopped 01:44 UTC")

    def test_a_hand_written_prefix_with_the_own_id(self):
        self.assertEqual(self.title("D62 (push of SM main to origin): the queue commit sits on 5 commits"),
                         "push of SM main to origin")

    def test_parentheses_inside_the_hand_written_prefix(self):
        self.assertEqual(self.title("D62 (push (SM main) to origin): the queue commit"), "push (SM main) to origin")

    def test_an_empty_start_takes_the_first_60_characters(self):
        self.assertEqual(
            self.title("(first written as D25; that id is also the other stage-2 row, so renumbered) More text"),
            "(first written as D25; that id is also the other stage-2")

    def test_another_id_is_part_of_the_title(self):
        self.assertEqual(self.title("D40 follow-up (a note): pick"), "D40 follow-up")

    def test_a_long_start_is_cut_at_a_word(self):
        self.assertEqual(
            self.title("Review the open questions of the audit and decide which of them need a new plan"),
            "Review the open questions of the audit and decide which of")

    def test_a_word_that_ends_at_60_stays(self):
        sixty = "aaaaaaaaa " * 5 + "bbbbbbbbbb"
        self.assertEqual(self.title(sixty + " ccc"), sixty)

    def test_no_inbox_suffix(self):
        self.assertEqual(self.title("Pick one · Inbox I-20261126-ab12"), "Pick one")

    def test_a_read_does_not_write(self):
        self.put("Batch phase 2: restart?")
        before = self.q.read_bytes()
        self.assertIn("(Batch phase 2)", self.cli("list").stdout)
        self.assertEqual(self.q.read_bytes(), before)


# title 16-17. ref: the paste-ready form, from both tables
class TestRef(Base):
    def setUp(self):
        super().setUp()
        self.q.write_text(SHELF)

    def test_ids_in_the_given_order(self):
        r = self.cli("ref", "D66", "D62")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "D66 (decided lately), D62 (old open item)\n")

    def test_a_row_with_a_prefix(self):
        self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        self.assertEqual(self.cli("ref", "D67").stdout, "D67 (push of SM main)\n")

    def test_a_closed_row_by_its_ref(self):
        r = self.cli("ref", "D40", "D62")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout, "D40 (x), D62 (old open item)\n")

    def test_a_closed_row_with_a_hand_written_prefix(self):
        self.q.write_text(SHELF.replace("| 2026-10-01 | x |", "| 2026-10-01 | D40 (name of it): more |"))
        self.assertEqual(self.cli("ref", "D40").stdout, "D40 (name of it)\n")

    def test_unknown_id_exit_1_no_output(self):
        r = self.cli("ref", "D62", "D99")
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertEqual(r.stdout, "")
        self.assertIn("D99", r.stderr)


# title 18-19. decide, default and close keep the prefix
class TestPrefixKept(Base):
    ITEM = "**push of SM main** — Push it now? · Inbox I-20261126-ab12"

    def test_decide(self):
        self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        self.assertEqual(self.cli("decide", "D01", "B").returncode, 0)
        self.assertEqual(self.rows()[0]["item"], self.ITEM)
        self.assertIn("inbox answer I-20261126-ab12 B", self.af_calls()[-1])

    def test_default(self):
        self.add("--item", "Push it now?", "--default", "A", title="push of SM main")
        self.assertEqual(self.cli("default", "D01", now="2026-11-26T14:00:00Z").returncode, 0)
        self.assertEqual(self.rows()[0]["item"], self.ITEM)

    def test_close(self):
        self.q.write_text(SHELF.replace("| decided long ago |", "| **old one** — decided long ago |"))
        self.assertEqual(self.cli("close").returncode, 0)
        closed = dqueue.Queue(self.q.read_text()).closed()
        self.assertEqual(closed[-1]["item"], "**old one** — decided long ago")
        self.assertEqual(self.cli("ref", "D65").stdout, "D65 (old one)\n")


# title 21. the help text names the new flag and command
class TestHelp(Base):
    def test_help_names_title_and_ref(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "help"], text=True, capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("add --title", r.stdout)
        self.assertIn("ref D<nn>", r.stdout)


if __name__ == "__main__":
    unittest.main()
