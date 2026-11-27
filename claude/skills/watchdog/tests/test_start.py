#!/usr/bin/env python3
"""Tests of `watchdog.py start` (the title from the project folder and the machines of the project part) and of the
removed `new`. Use cases 1-4 and 10 of docs/local/PLAN-watchdog-skill.md."""
import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_frontends import FrontBase  # noqa: E402

MACHINES = ("## Machines\n\n| Machine | Checkout | Reach | Notes |\n|---|---|---|---|\n"
            "| master | ~/x | ssh | |\n| slave | ~/x | ssh | |\n\n## Report\n")


class StartBase(FrontBase):
    def setUp(self):
        super().setUp()
        self.part = self.proj / ".claude/docs/prompts/proj-watchdog.md"
        self.part.parent.mkdir(parents=True)
        self.part.write_text("# proj (watchdog)\n\n## Machines\n\n| Machine | Checkout | Reach | Notes |\n"
                             "|---|---|---|---|\n| <master or slave> | | | |\n\n## Report\n")

    def start(self, *extra):
        return self.cli("start", "--model", "claude-opus-5-5", "--project-dir", str(self.proj), "--json", *extra)


# 1. one machine: "<project> (watchdog) #<id>"
class TestOneMachine(StartBase):
    def test_title_and_name(self):
        r = self.start()
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertRegex(d["name"], r"^proj \(watchdog\) #[0-9a-f]{8}$")
        self.assertEqual(d["name"], f"proj (watchdog) #{d['session'][:8]}")
        self.assertEqual(d["window_label"], f"watchdog #{d['session'][:8]}")

    def test_first_prompt_runs_the_project_part(self):
        d = json.loads(self.start().stdout)
        self.assertTrue(d["argv"][-1].startswith("Run .claude/docs/prompts/proj-watchdog.md."), d["argv"][-1])

    def test_prompt_file_wins(self):
        d = json.loads(self.start("--prompt-file", "docs/x.md").stdout)
        self.assertTrue(d["argv"][-1].startswith("Read docs/x.md first."), d["argv"][-1])


# 2. two machines: "<project> (watchdog-<machine>) #<id>"; --machine is required
class TestTwoMachines(StartBase):
    def setUp(self):
        super().setUp()
        text = self.part.read_text()
        self.part.write_text(text[:text.index("## Machines")] + MACHINES)

    def test_machine_title(self):
        d = json.loads(self.start("--machine", "master").stdout)
        self.assertRegex(d["name"], r"^proj \(watchdog-master\) #[0-9a-f]{8}$")

    def test_no_machine_is_usage(self):
        r = self.start()
        self.assertEqual(r.returncode, 64)
        self.assertIn("--machine", r.stderr)

    def test_unknown_machine_is_usage(self):
        r = self.start("--machine", "laptop")
        self.assertEqual(r.returncode, 64)
        self.assertIn("master, slave", r.stderr)


# 3. a live session of the title: refused
class TestRefused(StartBase):
    def test_live_title_exit_2(self):
        self.live("cccccccc-1111-2222-3333-444444444444", "proj (watchdog) #cccccccc")
        r = self.start()
        self.assertEqual((r.returncode, r.stdout), (2, ""))
        self.assertEqual(self.execs(), [])

    # 4. Fable only on the owner's word
    def test_fable_exit_4(self):
        r = self.cli("start", "--model", "claude-fable-5-2", "--project-dir", str(self.proj), "--json")
        self.assertEqual(r.returncode, 4)
        r = self.cli("start", "--model", "claude-fable-5-2", "--project-dir", str(self.proj), "--json",
                     "--owner-said-fable")
        self.assertEqual(r.returncode, 0, r.stderr)


# 10. `new` is gone: usage with a hint
class TestNewRemoved(StartBase):
    def test_new_is_usage_with_a_hint(self):
        r = self.cli("new", "--title", "x (watchdog)", "--model", "claude-opus-5-5")
        self.assertEqual(r.returncode, 64)
        self.assertIn("start", r.stderr)


if __name__ == "__main__":
    unittest.main()
