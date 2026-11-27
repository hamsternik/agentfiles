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
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)  # the watchdog form needs a git root
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


# Regression 2026-11-27: `start --frontend rex --dry-run` started a real Rex session in the wrong folder.
class TestDryRunNeverActs(StartBase):
    def test_rex_dry_run_makes_no_rex_call(self):
        log = self.root / "rex.log"
        stub = self.bin / "rex"
        stub.write_text(f"#!/bin/sh\necho \"$@\" >> {log}\necho '{{}}'\n")
        stub.chmod(0o755)
        for fe in ("rex", "desktop", "terminal"):
            r = self.cli("start", "--model", "claude-opus-5-5", "--project-dir", str(self.proj), "--frontend", fe,
                         "--dry-run", claudecode="1")
            self.assertEqual(r.returncode, 0, f"{fe}: {r.stderr}")
            self.assertIn("claude --session-id", r.stdout, fe)
        self.assertFalse(log.exists(), log.read_text() if log.exists() else "")
        self.assertEqual(self.execs(), [])


class TestProjectFromCwd(StartBase):
    def test_no_project_dir_is_the_git_root_of_the_cwd(self):
        """The parent folder has transcripts (old default: the nearest folder with transcripts) and
        CLAUDE_PROJECT_DIR names another project: start still takes the git root of the cwd."""
        import subprocess
        from test_watchdog import context
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)
        (self.projects / context.project_slug(str(self.root))).mkdir(parents=True, exist_ok=True)
        (self.proj / "sub").mkdir()
        r = self.cli("start", "--model", "claude-opus-5-5", "--json", cwd=self.proj / "sub",
                     extra={"CLAUDE_PROJECT_DIR": str(self.root / "elsewhere"), "PWD": str(self.proj / "sub")})
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual(Path(d["project_dir"]).resolve(), self.proj.resolve())
        self.assertTrue(d["name"].startswith("proj (watchdog) #"), d["name"])


# Guard (owner, 2026-11-27): the watchdog form of start runs only in the git root of a project.
class TestGitRootGuard(StartBase):
    def test_a_parent_folder_with_no_git_is_refused(self):
        """Like ~/Developer/_work: no repo, but it holds the project folders (and transcripts)."""
        from test_watchdog import context
        (self.projects / context.project_slug(str(self.root))).mkdir(parents=True, exist_ok=True)
        r = self.cli("start", "--model", "claude-opus-5-5", cwd=self.root, extra={"PWD": str(self.root)})
        self.assertEqual(r.returncode, 64, r.stdout + r.stderr)
        self.assertIn("git root", r.stderr)
        self.assertEqual(self.execs(), [])

    def test_a_sub_folder_given_as_project_dir_is_refused(self):
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)
        (self.proj / "sub").mkdir()
        r = self.cli("start", "--model", "claude-opus-5-5", "--project-dir", str(self.proj / "sub"), "--json")
        self.assertEqual(r.returncode, 64)
        self.assertIn("git root", r.stderr)

    def test_the_git_root_is_accepted(self):
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)
        r = self.cli("start", "--model", "claude-opus-5-5", "--json", cwd=self.proj, extra={"PWD": str(self.proj)})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(Path(json.loads(r.stdout)["project_dir"]).resolve(), self.proj.resolve())


# 10. `new` is gone: usage with a hint
class TestNewRemoved(StartBase):
    def test_new_is_usage_with_a_hint(self):
        r = self.cli("new", "--title", "x (watchdog)", "--model", "claude-opus-5-5")
        self.assertEqual(r.returncode, 64)
        self.assertIn("start", r.stderr)


if __name__ == "__main__":
    unittest.main()
