#!/usr/bin/env python3
"""Tests of scripts/latest.py: find the latest live session of a fixed title and print its resume line."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE.parent / "scripts" / "latest.py"
sys.path.insert(0, str(SCRIPT.parent))
import latest  # noqa: E402
import context  # noqa: E402

TITLE = "proj (watchdog-master)"
PROJECT = "/home/u/Developer/_work/proj"


def title_rec(sid, title):
    return {"type": "custom-title", "customTitle": title, "sessionId": sid}


def msg(sid, uuid, ts, text="hi", model=None, tokens=None):
    if model:
        return {"type": "assistant", "uuid": uuid, "timestamp": ts, "sessionId": sid,
                "message": {"id": "m" + uuid, "model": model, "content": [{"type": "text", "text": text}],
                            "usage": {"input_tokens": tokens or 1, "cache_creation_input_tokens": 0,
                                      "cache_read_input_tokens": 0, "output_tokens": 1}}}
    return {"type": "user", "uuid": uuid, "timestamp": ts, "sessionId": sid, "message": {"content": text}}


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.projects = Path(self._td.name).resolve() / "projects"
        self.dir = self.projects / context.project_slug(PROJECT)
        self.dir.mkdir(parents=True)

    def tearDown(self):
        self._td.cleanup()

    def write(self, sid, recs, mtime=None):
        p = self.dir / f"{sid}.jsonl"
        p.write_text("\n".join(json.dumps(r) for r in recs) + "\n")
        if mtime:
            os.utime(p, (mtime, mtime))
        return p

    def session(self, sid, first_uuid, last_ts, title=TITLE, model="claude-opus-5-5", mode="auto", tokens=100):
        recs = [title_rec(sid, title), msg(sid, first_uuid, "2026-11-20T10:00:00Z"),
                {"type": "permission-mode", "permissionMode": mode, "sessionId": sid},
                msg(sid, first_uuid + "-a", last_ts, model=model, tokens=tokens)]
        return self.write(sid, recs)

    def find(self, title=TITLE):
        return latest.find_latest(title, PROJECT, self.projects)


class TestFind(Base):
    def test_own_title_record_counts_a_quoted_title_does_not(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z")
        self.write("bbb", [title_rec("bbb", "other work"),
                           msg("bbb", "u2", "2026-11-26T10:00:00Z", text=f'"customTitle":"{TITLE}" and {TITLE}')])
        best, forks = self.find()
        self.assertEqual(best["session"], "aaa")
        self.assertEqual(forks, [])

    def test_last_title_record_wins_rename_to_deprecated(self):
        p = self.session("aaa", "u1", "2026-11-26T10:00:00Z")
        with open(p, "a") as fh:
            fh.write(json.dumps(title_rec("aaa", "deprecated " + TITLE)) + "\n")
        self.session("ccc", "u3", "2026-11-25T10:00:00Z")
        self.assertEqual(self.find()[0]["session"], "ccc")

    def test_newest_by_last_record_not_by_mtime(self):
        old = self.session("old", "u1", "2026-11-20T10:00:00Z")
        new = self.session("new", "u2", "2026-11-25T10:00:00Z")
        os.utime(old, (2_000_000_000, 2_000_000_000))
        os.utime(new, (1_000_000_000, 1_000_000_000))
        self.assertEqual(self.find()[0]["session"], "new")

    def test_fork_pair_shares_first_uuid_newest_wins_parent_listed(self):
        self.session("parent", "u1", "2026-11-22T10:00:00Z")
        self.session("child", "u1", "2026-11-25T10:00:00Z")
        best, forks = self.find()
        self.assertEqual(best["session"], "child")
        self.assertEqual([f["session"] for f in forks], ["parent"])

    def test_no_match(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z", title="something else")
        self.assertEqual(self.find(), (None, []))

    def test_summary_fields(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z", model="claude-sonnet-5-5", mode="acceptEdits", tokens=450_000)
        best, _ = self.find()
        self.assertEqual((best["model"], best["permission_mode"], best["last"]),
                         ("claude-sonnet-5-5", "acceptEdits", "2026-11-24T10:00:00Z"))
        self.assertEqual((best["tokens"], best["level"]), (450_000, "handoff"))


class TestLines(unittest.TestCase):
    S = {"session": "abc", "model": "claude-opus-5-5", "permission_mode": "auto"}

    def test_resume_line(self):
        self.assertEqual(latest.resume_line(self.S, TITLE),
                         "claude --resume abc -n 'proj (watchdog-master)' --model claude-opus-5-5 "
                         "--permission-mode auto --remote-control 'proj (watchdog-master)'")

    def test_resume_line_effort_and_no_mode(self):
        s = {"session": "abc", "model": None, "permission_mode": None}
        self.assertEqual(latest.resume_line(s, "t", effort="high"),
                         "claude --resume abc -n t --effort high --remote-control t")

    def test_rex_command(self):
        self.assertEqual(latest.rex_command("shelf-crawl", "watchdog-master", "/p q", "claude --resume abc"),
                         ["rex", "window", "new", "-s", "shelf-crawl", "watchdog-master", "-c", "/p q",
                          "--keep-open", "--", "sh", "-c", "claude --resume abc"])

    def test_recent_activity_guard(self):
        self.assertTrue(latest.recently_active("2026-11-26T10:00:00Z", now="2026-11-26T10:01:30Z"))
        self.assertFalse(latest.recently_active("2026-11-26T10:00:00Z", now="2026-11-26T10:02:01Z"))


class TestLivePid(unittest.TestCase):
    def test_live_and_dead_pid_files(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            dead = subprocess.Popen([sys.executable, "-c", "pass"])
            dead.wait()
            (d / f"{os.getpid()}.json").write_text(json.dumps({"pid": os.getpid(), "sessionId": "live"}))
            (d / f"{dead.pid}.json").write_text(json.dumps({"pid": dead.pid, "sessionId": "gone"}))
            (d / "bad.json").write_text("not json")
            self.assertEqual(latest.live_pid("live", d), os.getpid())
            self.assertIsNone(latest.live_pid("gone", d))
            self.assertIsNone(latest.live_pid("other", d))
            self.assertIsNone(latest.live_pid("live", d / "missing"))


class TestDefaultProject(Base):
    def test_claude_project_dir_wins(self):
        self.assertEqual(latest.default_project_dir({"CLAUDE_PROJECT_DIR": "/x/y", "PWD": PROJECT + "/a"}, "/z",
                                                    self.projects), "/x/y")

    def test_walks_up_from_pwd_to_the_project_with_transcripts(self):
        env = {"PWD": PROJECT + "/.claude/skills/handoff-session-context/scripts"}
        self.assertEqual(latest.default_project_dir(env, "/real/agentfiles/skill", self.projects), PROJECT)

    def test_then_from_the_real_cwd(self):
        self.assertEqual(latest.default_project_dir({}, PROJECT + "/sub", self.projects), PROJECT)

    def test_the_root_folder_is_never_the_project(self):
        (self.projects / context.project_slug("/")).mkdir()
        self.assertEqual(latest.default_project_dir({"PWD": "/nowhere/a"}, "/nowhere/b", self.projects), "/nowhere/b")

    def test_no_project_found_keeps_the_cwd(self):
        self.assertEqual(latest.default_project_dir({"PWD": "/nowhere/a"}, "/nowhere/b", self.projects), "/nowhere/b")


class TestCli(Base):
    def run_cli(self, *args):
        env = {**os.environ, "HANDOFF_PROJECTS_DIR": str(self.projects),
               "HANDOFF_CACHE_DIR": str(self.projects.parent / "cache"),
               "HANDOFF_SESSIONS_DIR": str(self.projects.parent / "sessions")}
        env.pop("HANDOFF_WINDOW_TOKENS", None)
        env.pop("CLAUDE_CODE_MAX_CONTEXT_TOKENS", None)
        return subprocess.run([sys.executable, str(SCRIPT), "--title", TITLE, "--project-dir", PROJECT, *args],
                              text=True, capture_output=True, env=env)

    def test_text_output_has_the_line(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z")
        r = self.run_cli()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("session aaa", r.stdout)
        self.assertIn("claude --resume aaa", r.stdout)
        self.assertNotIn("WARNING", r.stdout)

    def test_warning_above_the_limit(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z", tokens=600_000)
        r = self.run_cli()
        self.assertIn("WARNING", r.stdout)

    def test_json(self):
        self.session("p", "u1", "2026-11-22T10:00:00Z")
        self.session("c", "u1", "2026-11-24T10:00:00Z")
        d = json.loads(self.run_cli("--json").stdout)
        self.assertEqual((d["session"], d["older_forks"]), ("c", ["p"]))
        self.assertTrue(d["resume"].startswith("claude --resume c "))

    def test_no_match_exits_1(self):
        r = self.run_cli()
        self.assertEqual(r.returncode, 1)
        self.assertIn("no session", r.stderr)
        self.assertIn("--project-dir", r.stderr)

    def test_rex_dry_run_prints_the_command(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z")
        r = self.run_cli("--rex", "shelf-crawl", "--label", "wd", "--dry-run")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("rex window new -s shelf-crawl wd", r.stdout)

    def test_rex_refuses_a_live_session(self):
        from datetime import datetime, timezone
        now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
        self.session("aaa", "u1", now)
        r = self.run_cli("--rex", "shelf-crawl", "--label", "wd", "--dry-run")
        self.assertEqual(r.returncode, 2)
        self.assertIn("active", r.stderr)

    def test_rex_refuses_a_session_with_a_live_pid(self):
        self.session("aaa", "u1", "2026-11-24T10:00:00Z")
        sessions = self.projects.parent / "sessions"
        sessions.mkdir()
        (sessions / "1.json").write_text(json.dumps({"pid": os.getpid(), "sessionId": "aaa"}))
        r = self.run_cli("--rex", "shelf-crawl", "--label", "wd", "--dry-run")
        self.assertEqual(r.returncode, 2)
        self.assertIn(f"pid {os.getpid()}", r.stderr)


if __name__ == "__main__":
    unittest.main()
