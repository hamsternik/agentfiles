#!/usr/bin/env python3
"""Tests of `watchdog.py whatsup`: the watchdog sessions, the open D-rows, the git state, the Inbox outbox.
Use case 24 of docs/local/PLAN-watchdog-skill.md."""
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_frontends import FrontBase  # noqa: E402

QUEUE = """| id | opened | item | scope | default if no answer | owner | status |
|---|---|---|---|---|---|---|
| D01 | 2026-11-26 08:00 UTC | first open | a | A | owner | open |
| D02 | 2026-11-26 10:00 UTC | second open | b | B | owner | open |
| D03 | 2026-11-25 10:00 UTC | done | c | C | owner | decided 2026-11-25: C |

## Closed

| id | ref | opened | item | status |
|---|---|---|---|---|
"""


def git(*args):
    subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", *args], check=True, capture_output=True)


class TestWhatsup(FrontBase):
    def setUp(self):
        super().setUp()
        git("init", "-q", str(self.proj))
        git("-C", str(self.proj), "commit", "-q", "--allow-empty", "-m", "one")
        remote = self.root / "remote.git"
        git("init", "-q", "--bare", str(remote))
        git("-C", str(self.proj), "remote", "add", "origin", str(remote))
        git("-C", str(self.proj), "push", "-q", "-u", "origin", "HEAD")
        git("-C", str(self.proj), "commit", "-q", "--allow-empty", "-m", "two, not pushed")
        (self.proj / "dirty.txt").write_text("x")
        self.restorable()  # a stopped watchdog session of proj
        self.af = self.root / "af"
        self.af.write_text("#!/bin/sh\nprintf 'role=master\\nurl=u\\noutbox=2\\noutbox_oldest=-\\nsending=0\\n'\n")
        self.af.chmod(0o755)

    def whatsup(self, queue=True):
        if queue:
            q = self.proj / ".claude/docs/decisions/queue.md"
            q.parent.mkdir(parents=True, exist_ok=True)
            q.write_text(QUEUE)
        return self.cli("whatsup", "--project-dir", str(self.proj),
                        extra={"WATCHDOG_AF": str(self.af), "WATCHDOG_NOW": "2026-11-26T12:00:00Z"})

    def test_all_parts(self):
        r = self.whatsup()
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertIn("proj (watchdog-master) #aaaaaaaa", out)      # the sessions
        self.assertIn("not running", out)
        self.assertIn("D01  open  4 h  first open", out)             # the open rows, with age
        self.assertIn("D02  open  2 h  second open", out)
        self.assertNotIn("D03", out)
        self.assertIn("1 commit not pushed", out)                    # git
        self.assertIn("2 files changed", out)                     # dirty.txt and the untracked .claude/
        self.assertIn("Inbox: 2 changes wait in the outbox", out)    # the Inbox

    def test_no_queue_is_one_line_exit_0(self):
        r = self.whatsup(queue=False)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("no queue", r.stdout)


if __name__ == "__main__":
    unittest.main()
