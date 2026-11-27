#!/usr/bin/env python3
"""Tests of the project commands of watchdog.py: init, public, queue next-id, and the project part (queue path,
machines). Use cases 11-14 and 22 of docs/local/PLAN-watchdog-skill.md (the owner checked the list first)."""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "watchdog.py"
sys.path.insert(0, str(HERE.parent / "scripts"))
import project  # noqa: E402

QUEUE = """| id | opened | item | rows / scope | default if no answer | owner | status |
|---|---|---|---|---|---|---|
| D01 | 2026-11-01 | a | x | y | owner | open |
| D07 | 2026-11-02 | b, see D05 | x | y | owner | open |

## Closed

| id | ref | opened | item | status |
|---|---|---|---|---|
| C02 | D43 | 2026-11-03 | c | decided 2026-11-04: yes |
"""


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.root = Path(self._td.name).resolve()
        self.proj = self.root / "myproj"
        self.proj.mkdir()
        subprocess.run(["git", "init", "-q", str(self.proj)], check=True)
        self.bin = self.root / "bin"
        self.bin.mkdir()

    def tearDown(self):
        self._td.cleanup()

    def cli(self, *args, cwd=None):
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_PROJECT_DIR")}
        env["PATH"] = f"{self.bin}:/usr/bin:/bin"
        return subprocess.run([sys.executable, str(SCRIPT), *args], text=True, capture_output=True, env=env,
                              cwd=cwd or self.proj)

    def part(self):
        return self.proj / ".claude/docs/prompts/myproj-watchdog.md"

    def queue(self):
        return self.proj / ".claude/docs/decisions/queue.md"

    def exclude(self):
        return self.proj / ".git/info/exclude"


# 11. init never overwrites
class TestInit(Base):
    def test_init_creates_both_files(self):
        r = self.cli("init")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.part().is_file())
        self.assertTrue(self.queue().is_file())
        self.assertIn("created", r.stdout)
        text = self.part().read_text()
        self.assertNotIn("{{PROJECT}}", text)
        self.assertIn("myproj (watchdog)", text)

    def test_init_again_keeps_the_files(self):
        self.cli("init")
        self.part().write_text(self.part().read_text() + "owner text\n")
        before = (self.part().read_bytes(), self.queue().read_bytes())
        r = self.cli("init")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("kept", r.stdout)
        self.assertEqual((self.part().read_bytes(), self.queue().read_bytes()), before)

    def test_init_refuses_a_folder_with_no_git(self):
        nogit = self.root / "nogit"
        nogit.mkdir()
        r = self.cli("init", "--project-dir", str(nogit))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse((nogit / ".claude").exists())

    def test_init_from_a_sub_folder_uses_the_git_root(self):
        (self.proj / "sub").mkdir()
        r = self.cli("init", cwd=self.proj / "sub")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertTrue(self.part().is_file())


# 12. init --local hides the files from git, once
class TestInitLocal(Base):
    def lines(self, path):
        return [x for x in path.read_text().splitlines() if x and not x.startswith("#")]

    def test_local_adds_both_paths_once(self):
        self.cli("init", "--local")
        self.cli("init", "--local")
        lines = self.lines(self.exclude())
        for p in ("/.claude/docs/prompts/myproj-watchdog.md", "/.claude/docs/decisions/queue.md"):
            self.assertEqual(lines.count(p), 1, lines)
        st = subprocess.run(["git", "-C", str(self.proj), "status", "--porcelain"], text=True, capture_output=True)
        self.assertEqual(st.stdout.strip(), "")

    def test_without_local_no_exclude_line(self):
        self.cli("init")
        text = self.exclude().read_text() if self.exclude().exists() else ""
        self.assertNotIn("watchdog.md", text)

    def test_worktree_uses_the_exclude_file_git_names(self):
        subprocess.run(["git", "-C", str(self.proj), "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q",
                        "--allow-empty", "-m", "init"], check=True)
        wt = self.root / "wt"
        subprocess.run(["git", "-C", str(self.proj), "worktree", "add", "-q", str(wt), "-b", "wt"], check=True,
                       capture_output=True)
        r = self.cli("init", "--local", cwd=wt)
        self.assertEqual(r.returncode, 0, r.stderr)
        named = subprocess.run(["git", "-C", str(wt), "rev-parse", "--path-format=absolute", "--git-path",
                                "info/exclude"], text=True, capture_output=True).stdout.strip()
        self.assertIn("/.claude/docs/prompts/wt-watchdog.md", Path(named).read_text())
        st = subprocess.run(["git", "-C", str(wt), "status", "--porcelain"], text=True, capture_output=True)
        self.assertEqual(st.stdout.strip(), "")


# 13. public through gh
class TestPublic(Base):
    def gh(self, body):
        p = self.bin / "gh"
        p.write_text("#!/bin/bash\n" + body + "\n")
        p.chmod(0o755)

    def test_public_private_unknown(self):
        for body, want in (("echo PUBLIC", "public"), ("echo PRIVATE", "private"), ("echo INTERNAL", "private"),
                           ("exit 1", "unknown")):
            self.gh(body)
            r = self.cli("public")
            self.assertEqual((r.returncode, r.stdout.strip()), (0, want), body)

    def test_no_gh_is_unknown(self):
        r = self.cli("public")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "unknown"))


# 14. queue next-id never reuses an id
class TestNextId(Base):
    def test_empty_template_gives_d01(self):
        self.cli("init")
        r = self.cli("queue", "next-id")
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "D01"), r.stderr)

    def test_highest_d_in_any_table_row_plus_one(self):
        self.assertEqual(project.next_id(QUEUE), "D44")

    def test_missing_queue_file_fails(self):
        r = self.cli("queue", "next-id")
        self.assertEqual(r.returncode, 1)
        self.assertIn("queue.md", r.stderr)


# 22. the project part may name another queue file; machines come from the project part
class TestProjectPart(Base):
    def test_default_queue_path(self):
        self.assertEqual(project.queue_path(str(self.proj)), self.queue())

    def test_part_names_another_queue(self):
        self.cli("init")
        self.part().write_text(self.part().read_text().replace(
            "Queue file: `.claude/docs/decisions/queue.md`", "Queue file: `docs/decisions/queue.md`"))
        q = self.proj / "docs/decisions/queue.md"
        q.parent.mkdir(parents=True)
        q.write_text(QUEUE)
        self.assertEqual(project.queue_path(str(self.proj)), q)
        r = self.cli("queue", "next-id")
        self.assertEqual(r.stdout.strip(), "D44", r.stderr)

    def test_part_in_docs_prompts_is_found_too(self):
        old = self.proj / "docs/prompts/myproj-watchdog.md"
        old.parent.mkdir(parents=True)
        old.write_text("Queue file: `docs/decisions/queue.md`\n")
        self.assertEqual(project.part_path(str(self.proj)), old)

    def test_machines_of_the_template_is_one_placeholder(self):
        self.cli("init")
        self.assertEqual(project.machines(str(self.proj)), [])

    def test_machines_listed(self):
        self.cli("init")
        text = self.part().read_text()
        start = text.index("## Machines")
        end = text.index("\n## ", start + 1)
        self.part().write_text(text[:start] + "## Machines\n\n| Machine | Checkout | Reach | Notes |\n|---|---|---|---|\n"
                               "| master | ~/x | ssh | |\n| slave | ~/x | ssh | |\n" + text[end:])
        self.assertEqual(project.machines(str(self.proj)), ["master", "slave"])


if __name__ == "__main__":
    unittest.main()
