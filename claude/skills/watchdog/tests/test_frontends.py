#!/usr/bin/env python3
"""Tests of the 3 front-ends of watchdog.py: terminal (exec claude in this terminal, the default), rex, desktop
(print the start_session arguments). Use cases 5-9 of docs/local/PLAN-watchdog-skill.md."""
import json
import os
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_watchdog import Base, T, PROJECT, OLD_ID, NEW_ID  # noqa: E402


class FrontBase(Base):
    def setUp(self):
        super().setUp()
        self.proj = self.root / "proj"
        self.proj.mkdir()
        self.env.pop("CLAUDECODE", None)

    def cli(self, *args, claudecode=None, extra=None, cwd=None):
        env = {k: v for k, v in {**os.environ, **self.env}.items() if k != "CLAUDECODE"}
        if claudecode:
            env["CLAUDECODE"] = claudecode
        env.update(extra or {})
        import subprocess
        from test_watchdog import SCRIPT
        return subprocess.run([sys.executable, str(SCRIPT), *args], text=True, capture_output=True, env=env, cwd=cwd)

    def execs(self):
        if not self.claude_log.exists():
            return []
        return [json.loads(x) for x in self.claude_log.read_text().splitlines()]

    def restorable(self):
        """A stopped session of T in the project folder self.proj."""
        from test_watchdog import context, title_rec, msg
        d = self.projects / context.project_slug(str(self.proj))
        d.mkdir(parents=True, exist_ok=True)
        recs = [title_rec(OLD_ID, f"{T} #aaaaaaaa"), msg(OLD_ID, "u1", "2026-11-20T10:00:00Z"),
                msg(OLD_ID, "u1-a", "2026-11-24T10:00:00Z", model="claude-opus-5-5", tokens=100)]
        (d / f"{OLD_ID}.jsonl").write_text("\n".join(json.dumps(r) for r in recs) + "\n")


# 5. the default front-end runs claude in this terminal
class TestTerminalExec(FrontBase):
    def test_new_execs_claude_with_the_plan_argv_in_the_project(self):
        r = self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj))
        self.assertEqual(r.returncode, 0, r.stderr)
        runs = self.execs()
        self.assertEqual(len(runs), 1, r.stdout + r.stderr)
        plan = json.loads(self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir",
                                   str(self.proj), "--json").stdout)
        self.assertEqual(runs[0]["argv"][:2], ["--session-id", runs[0]["argv"][1]])
        self.assertEqual(runs[0]["argv"][2:4], plan["argv"][3:5])  # --model <m>
        self.assertEqual(Path(runs[0]["cwd"]).resolve(), self.proj.resolve())

    def test_restore_execs_the_resume_line(self):
        self.restorable()
        r = self.cli("restore", "--title", T, "--project-dir", str(self.proj))
        self.assertEqual(r.returncode, 0, r.stderr)
        runs = self.execs()
        self.assertEqual(runs[0]["argv"][:2], ["--resume", OLD_ID])

    def test_dry_run_and_json_never_exec(self):
        self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj), "--dry-run")
        self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj), "--json")
        self.assertEqual(self.execs(), [])


# 6. inside a Claude session the terminal front-end refuses
class TestTerminalInsideClaude(FrontBase):
    def test_claudecode_set_exit_64_no_exec(self):
        r = self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj),
                     claudecode="1")
        self.assertEqual(r.returncode, 64)
        self.assertIn("--frontend rex", r.stderr)
        self.assertEqual(self.execs(), [])

    def test_dry_run_inside_claude_still_prints(self):
        r = self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj),
                     "--dry-run", claudecode="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("claude --session-id", r.stdout)


# 7. desktop prints the start_session arguments
class TestDesktop(FrontBase):
    def test_new_prints_one_json_object(self):
        r = self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj),
                     "--first-prompt", "Read x.md first.", "--frontend", "desktop", claudecode="1")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertRegex(d["title"], r"^proj \(watchdog-master\) #[0-9a-f]{8}$")
        self.assertEqual(d["cwd"], str(self.proj))
        self.assertEqual(d["model"], "claude-opus-5-5")
        self.assertTrue(d["prompt"].startswith("Read x.md first."))
        self.assertEqual((d["use_worktree"], d["context"]), (False, "fresh"))
        self.assertEqual(self.execs(), [])

    def test_restore_desktop_is_refused(self):
        self.restorable()
        r = self.cli("restore", "--title", T, "--project-dir", str(self.proj), "--frontend", "desktop")
        self.assertEqual(r.returncode, 64)
        self.assertIn("resume", r.stderr)


# 8. retire on a front-end that cannot type: the 2 lines, exit 0, nothing sent
class TestRetireNoTyping(FrontBase):
    def pair(self):
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        self.assertEqual(self.cli("ready", "--session", NEW_ID).returncode, 0)

    def test_terminal_and_desktop(self):
        self.pair()
        for fe in ("terminal", "desktop"):
            r = self.cli("retire", "--session", OLD_ID, "--caller", NEW_ID, "--frontend", fe, "--yes")
            self.assertEqual(r.returncode, 0, f"{fe}: {r.stderr}")
            self.assertIn(f"/rename deprecated {T} #aaaaaaaa", r.stdout, fe)
            self.assertIn("/exit", r.stdout, fe)
        self.assertEqual(self.execs(), [])


# 9. no detection: REX_SESSION never chooses the front-end
class TestNoDetection(FrontBase):
    def test_rex_session_set_still_terminal(self):
        r = self.cli("start", "--title", T, "--model", "claude-opus-5-5", "--project-dir", str(self.proj),
                     extra={"REX_SESSION": "session:x", "REX_BLOCK": "block:y"})
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(len(self.execs()), 1)


if __name__ == "__main__":
    unittest.main()
