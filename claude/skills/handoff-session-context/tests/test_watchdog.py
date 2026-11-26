#!/usr/bin/env python3
"""Tests of scripts/watchdog.py (watchdog CLI v2) and the latest.py alias. Use cases: see the spec, section 8,
and the numbered list given in chat before this file (1-22)."""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPTS = HERE.parent / "scripts"
SCRIPT = SCRIPTS / "watchdog.py"
sys.path.insert(0, str(SCRIPTS))
import watchdog as wd  # noqa: E402
import context  # noqa: E402

T = "proj (watchdog-master)"
PROJECT = "/home/u/Developer/_work/proj"
OLD_ID = "aaaaaaaa-1111-2222-3333-444444444444"
NEW_ID = "bbbbbbbb-1111-2222-3333-444444444444"


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
        self.root = Path(self._td.name).resolve()
        self.projects = self.root / "projects"
        self.sessions = self.root / "sessions"
        self.cache = self.root / "cache"
        self.dir = self.projects / context.project_slug(PROJECT)
        self.dir.mkdir(parents=True)
        self.sessions.mkdir()
        self.procs = []
        self.env = {"HANDOFF_PROJECTS_DIR": str(self.projects), "HANDOFF_SESSIONS_DIR": str(self.sessions),
                    "HANDOFF_CACHE_DIR": str(self.cache)}
        self._old_env = {k: os.environ.get(k) for k in list(self.env) + ["HANDOFF_WINDOW_TOKENS",
                                                                          "CLAUDE_CODE_MAX_CONTEXT_TOKENS"]}
        os.environ.update(self.env)
        os.environ.pop("HANDOFF_WINDOW_TOKENS", None)
        os.environ.pop("CLAUDE_CODE_MAX_CONTEXT_TOKENS", None)

    def tearDown(self):
        for p in self.procs:
            p.kill()
            p.wait()
        for k, v in self._old_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v
        self._td.cleanup()

    def write(self, sid, recs):
        p = self.dir / f"{sid}.jsonl"
        p.write_text("\n".join(json.dumps(r) for r in recs) + "\n")
        return p

    def session(self, sid, first_uuid, last_ts, title=T, model="claude-opus-5-5", mode="auto", tokens=100):
        recs = [title_rec(sid, title), msg(sid, first_uuid, "2026-11-20T10:00:00Z"),
                {"type": "permission-mode", "permissionMode": mode, "sessionId": sid},
                msg(sid, first_uuid + "-a", last_ts, model=model, tokens=tokens)]
        return self.write(sid, recs)

    def live(self, sid, name, pid=None):
        """A sessions/<pid>.json entry; pid None = a new live sleep process."""
        if pid is None:
            p = subprocess.Popen(["sleep", "60"])
            self.procs.append(p)
            pid = p.pid
        (self.sessions / f"{pid}.json").write_text(json.dumps(
            {"pid": pid, "sessionId": sid, "cwd": PROJECT, "name": name, "status": "idle", "updatedAt": 1795663714628}))
        return pid

    def dead_pid(self):
        p = subprocess.Popen([sys.executable, "-c", "pass"])
        p.wait()
        return p.pid

    def cli(self, *args, script=SCRIPT):
        env = {**os.environ, **self.env}
        return subprocess.run([sys.executable, str(script), *args], text=True, capture_output=True, env=env)


# 1-3 names and match
class TestNames(unittest.TestCase):
    def test_matches_bare_and_suffixed_title(self):
        self.assertTrue(wd.matches(T, T))
        self.assertTrue(wd.matches(f"{T} #dd18597a", T))

    def test_no_match_for_deprecated_moved_or_other(self):
        for name in (f"deprecated {T} #dd18597a", f"moved to rex: {T}", f"{T} #DE18597A", f"{T} #de1859", f"{T}x", None):
            self.assertFalse(wd.matches(name, T), name)

    def test_name_and_label(self):
        self.assertEqual(wd.name_for(T, "dd18597a-0000-4000-8000-000000000001"), f"{T} #dd18597a")
        self.assertEqual(wd.label_for("watchdog-master", "dd18597a-0000-4000-8000-000000000001"),
                         "watchdog-master-dd18597a")

    def test_base_title(self):
        self.assertEqual(wd.base_title(f"{T} #dd18597a"), T)
        self.assertEqual(wd.base_title(T), T)


class TestDefaultProject(Base):
    def test_claude_project_dir_wins(self):
        self.assertEqual(wd.default_project_dir({"CLAUDE_PROJECT_DIR": "/x/y", "PWD": PROJECT + "/a"}, "/z",
                                                self.projects), "/x/y")

    def test_walks_up_from_pwd_to_the_project_with_transcripts(self):
        env = {"PWD": PROJECT + "/.claude/skills/handoff-session-context/scripts"}
        self.assertEqual(wd.default_project_dir(env, "/real/agentfiles/skill", self.projects), PROJECT)

    def test_then_from_the_real_cwd(self):
        self.assertEqual(wd.default_project_dir({}, PROJECT + "/sub", self.projects), PROJECT)

    def test_the_root_folder_is_never_the_project(self):
        (self.projects / context.project_slug("/")).mkdir()
        self.assertEqual(wd.default_project_dir({"PWD": "/nowhere/a"}, "/nowhere/b", self.projects), "/nowhere/b")

    def test_no_project_found_keeps_the_cwd(self):
        self.assertEqual(wd.default_project_dir({"PWD": "/nowhere/a"}, "/nowhere/b", self.projects), "/nowhere/b")


class TestLivePid(unittest.TestCase):
    def test_live_and_dead_pid_files(self):
        with tempfile.TemporaryDirectory() as td:
            d = Path(td)
            dead = subprocess.Popen([sys.executable, "-c", "pass"])
            dead.wait()
            (d / f"{os.getpid()}.json").write_text(json.dumps({"pid": os.getpid(), "sessionId": "live"}))
            (d / f"{dead.pid}.json").write_text(json.dumps({"pid": dead.pid, "sessionId": "gone"}))
            (d / "bad.json").write_text("not json")
            self.assertEqual(wd.live_pid("live", d), os.getpid())
            self.assertIsNone(wd.live_pid("gone", d))
            self.assertIsNone(wd.live_pid("other", d))
            self.assertIsNone(wd.live_pid("live", d / "missing"))


# 4-8 status
class TestStatus(Base):
    def test_rows_newest_first_with_live_data(self):
        self.session(OLD_ID, "u1", "2026-11-20T12:00:00Z")
        self.session(NEW_ID, "u2", "2026-11-25T12:00:00Z", title=f"{T} #bbbbbbbb")
        pid = self.live(NEW_ID, f"{T} #bbbbbbbb")
        rows = wd.status_rows(T, PROJECT)
        self.assertEqual([r["session"] for r in rows], [NEW_ID, OLD_ID])
        self.assertEqual((rows[0]["pid"], rows[0]["status"], rows[0]["short"]), (pid, "idle", "bbbbbbbb"))
        self.assertIsNone(rows[1]["pid"])

    def test_duplicates_exit_3(self):
        self.session(OLD_ID, "u1", "2026-11-20T12:00:00Z")
        self.session(NEW_ID, "u2", "2026-11-25T12:00:00Z", title=f"{T} #bbbbbbbb")
        self.live(OLD_ID, T)
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        r = self.cli("status", "--title", T, "--project-dir", PROJECT)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn("2 live", r.stdout + r.stderr)

    def test_without_title_all_watchdogs_but_deprecated(self):
        self.session(OLD_ID, "u1", "2026-11-20T12:00:00Z", title=f"deprecated {T}")
        self.session(NEW_ID, "u2", "2026-11-25T12:00:00Z", title="other (watchdog-slave) #bbbbbbbb")
        self.session("cccccccc-1111-2222-3333-444444444444", "u3", "2026-11-25T12:00:00Z", title="crawl Kroger")
        rows = wd.status_rows(None, PROJECT)
        self.assertEqual([r["session"] for r in rows], [NEW_ID])

    def test_no_session_exit_1(self):
        self.assertEqual(self.cli("status", "--title", T, "--project-dir", PROJECT).returncode, 1)

    def test_wait_name_found(self):
        def later():
            time.sleep(0.5)
            self.live(NEW_ID, f"{T} #bbbbbbbb")
        import threading
        threading.Thread(target=later).start()
        self.assertTrue(wd.wait_name(f"{T} #bbbbbbbb", timeout=5, poll=0.1))

    def test_wait_name_found_exit_0_without_any_transcript(self):
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        r = self.cli("status", "--title", T, "--project-dir", PROJECT, "--wait-name", f"{T} #bbbbbbbb", "--timeout", "2")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(NEW_ID, r.stdout)

    def test_wait_name_timeout_exit_5(self):
        self.session(OLD_ID, "u1", "2026-11-20T12:00:00Z")
        r = self.cli("status", "--title", T, "--project-dir", PROJECT, "--wait-name", f"{T} #bbbbbbbb", "--timeout", "1")
        self.assertEqual(r.returncode, 5, r.stderr)

    def test_check_files_reports_dead_ids_and_edits_nothing(self):
        self.session(OLD_ID, "u1", "2026-11-20T12:00:00Z")
        self.session(NEW_ID, "u2", "2026-11-25T12:00:00Z", title=f"{T} #bbbbbbbb")
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        f = self.root / "prompt.md"
        text = f"watchdog: {T} #bbbbbbbb, old id {OLD_ID}, also local_0d0d0d0d-0000-4000-8000-000000000002\n"
        f.write_text(text)
        stale = wd.stale_ids([f], wd.status_rows(T, PROJECT))
        self.assertEqual(sorted(stale[str(f)]), sorted([OLD_ID, "local_0d0d0d0d-0000-4000-8000-000000000002"]))
        self.assertEqual(f.read_text(), text)


# 9-11 restore (v1 latest.py cases)
class TestRestore(Base):
    def find(self, title=T):
        return wd.find_latest(title, PROJECT, self.projects)

    def test_own_title_record_counts_a_quoted_title_does_not(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        self.write("bbb", [title_rec("bbb", "other work"),
                           msg("bbb", "u2", "2026-11-26T10:00:00Z", text=f'"customTitle":"{T}" and {T}')])
        best, forks = self.find()
        self.assertEqual((best["session"], forks), (OLD_ID, []))

    def test_suffixed_title_matches(self):
        self.session(NEW_ID, "u1", "2026-11-24T10:00:00Z", title=f"{T} #bbbbbbbb")
        self.assertEqual(self.find()[0]["session"], NEW_ID)

    def test_last_title_record_wins_rename_to_deprecated(self):
        p = self.session(OLD_ID, "u1", "2026-11-26T10:00:00Z")
        with open(p, "a") as fh:
            fh.write(json.dumps(title_rec(OLD_ID, "deprecated " + T)) + "\n")
        self.session(NEW_ID, "u3", "2026-11-25T10:00:00Z")
        self.assertEqual(self.find()[0]["session"], NEW_ID)

    def test_newest_by_last_record_not_by_mtime(self):
        old = self.session(OLD_ID, "u1", "2026-11-20T10:00:00Z")
        new = self.session(NEW_ID, "u2", "2026-11-25T10:00:00Z")
        os.utime(old, (2_000_000_000, 2_000_000_000))
        os.utime(new, (1_000_000_000, 1_000_000_000))
        self.assertEqual(self.find()[0]["session"], NEW_ID)

    def test_fork_pair_shares_first_uuid(self):
        self.session(OLD_ID, "u1", "2026-11-22T10:00:00Z")
        self.session(NEW_ID, "u1", "2026-11-25T10:00:00Z")
        best, forks = self.find()
        self.assertEqual((best["session"], [f["session"] for f in forks]), (NEW_ID, [OLD_ID]))

    def test_summary_fields_and_level(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", model="claude-sonnet-5-5", mode="acceptEdits", tokens=450_000)
        best, _ = self.find()
        self.assertEqual((best["model"], best["permission_mode"], best["tokens"], best["level"]),
                         ("claude-sonnet-5-5", "acceptEdits", 450_000, "handoff"))

    def test_resume_argv(self):
        s = {"session": "abc", "model": "claude-opus-5-5", "permission_mode": "auto", "title": f"{T} #abcabcab"}
        self.assertEqual(wd.resume_argv(s),
                         ["claude", "--resume", "abc", "-n", f"{T} #abcabcab", "--model", "claude-opus-5-5",
                          "--permission-mode", "auto", "--remote-control", f"{T} #abcabcab"])
        s = {"session": "abc", "model": None, "permission_mode": None, "title": "t"}
        self.assertEqual(wd.resume_argv(s, effort="high"),
                         ["claude", "--resume", "abc", "-n", "t", "--effort", "high", "--remote-control", "t"])

    def test_recent_activity_guard(self):
        self.assertTrue(wd.recently_active("2026-11-26T10:00:00Z", now="2026-11-26T10:01:30Z"))
        self.assertFalse(wd.recently_active("2026-11-26T10:00:00Z", now="2026-11-26T10:02:01Z"))

    def test_cli_text_json_and_warning(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", tokens=600_000)
        r = self.cli("restore", "--title", T, "--project-dir", PROJECT)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f"claude --resume {OLD_ID}", r.stdout)
        self.assertIn("WARNING", r.stdout)
        d = json.loads(self.cli("restore", "--title", T, "--project-dir", PROJECT, "--json").stdout)
        self.assertEqual(d["argv"][:3], ["claude", "--resume", OLD_ID])
        self.assertEqual(d["project_dir"], PROJECT)

    def test_live_session_exit_2(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        self.live(OLD_ID, T)
        r = self.cli("restore", "--title", T, "--project-dir", PROJECT)
        self.assertEqual(r.returncode, 2)
        self.assertIn("still running", r.stderr)

    def test_no_session_exit_1_names_project_dir(self):
        r = self.cli("restore", "--title", T, "--project-dir", PROJECT)
        self.assertEqual(r.returncode, 1)
        self.assertIn("--project-dir", r.stderr)


# 12-14 new
class TestNew(Base):
    def test_live_session_of_title_refused(self):
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT, "--json")
        self.assertEqual((r.returncode, r.stdout), (2, ""))

    def test_fable_needs_the_owner_word(self):
        args = ["new", "--title", T, "--model", "claude-fable-5-2", "--project-dir", PROJECT, "--json"]
        self.assertEqual(self.cli(*args).returncode, 4)
        self.assertEqual(self.cli(*args, "--owner-said-fable").returncode, 0)

    def test_argv_names_and_prompt_tail(self):
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT,
                     "--first-prompt", "Read docs/prompts/x.md first.", "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        sid = d["session"]
        self.assertRegex(sid, r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
        name = f"{T} #{sid[:8]}"
        self.assertEqual((d["name"], d["short"]), (name, sid[:8]))
        self.assertEqual(d["project_dir"], PROJECT)
        self.assertEqual(d["argv"][:9], ["claude", "--session-id", sid, "--model", "claude-opus-5-5",
                                         "-n", name, "--remote-control", name])
        prompt = d["argv"][-1]
        self.assertTrue(prompt.startswith("Read docs/prompts/x.md first."))
        self.assertIn(f"watchdog.py ready --session {sid}", prompt)
        self.assertIn("wake-ups", prompt)


# 15-16 handoff
class TestHandoff(Base):
    def test_successor_plan_copies_model(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", title=f"{T} #aaaaaaaa", model="claude-sonnet-5-5")
        pid = self.live(OLD_ID, f"{T} #aaaaaaaa")
        r = self.cli("handoff", "--title", T, "--handoff-file", "docs/local/h.md", "--project-dir", PROJECT, "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["old"]["session"], d["old"]["pid"]), (OLD_ID, pid))
        self.assertEqual(d["project_dir"], PROJECT)
        new = d["new"]
        self.assertNotEqual(new["session"], OLD_ID)
        self.assertEqual(new["argv"][3:5], ["--model", "claude-sonnet-5-5"])
        prompt = new["argv"][-1]
        for part in ("docs/local/h.md", OLD_ID, f"ready --session {new['session']}", "retire --session " + OLD_ID):
            self.assertIn(part, prompt)

    def test_two_live_without_session_exit_3(self):  # 15b
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", title=f"{T} #aaaaaaaa")
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        r = self.cli("handoff", "--title", T, "--handoff-file", "h.md", "--project-dir", PROJECT, "--json")
        self.assertEqual((r.returncode, r.stdout), (3, ""))
        self.assertIn("--session", r.stderr)

    def test_session_names_the_old_one(self):  # 15c
        self.session(NEW_ID, "u2", "2026-11-25T10:00:00Z", title=f"{T} #bbbbbbbb")
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        pid = self.live(NEW_ID, f"{T} #bbbbbbbb")
        r = self.cli("handoff", "--title", T, "--handoff-file", "h.md", "--session", NEW_ID,
                     "--project-dir", PROJECT, "--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["old"]["session"], d["old"]["pid"]), (NEW_ID, pid))
        self.assertIn(f"retire --session {NEW_ID}", d["new"]["argv"][-1])

    def test_no_live_session_exit_1(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        r = self.cli("handoff", "--title", T, "--handoff-file", "h.md", "--project-dir", PROJECT)
        self.assertEqual(r.returncode, 1)


# 17-20 ready and retire
class TestReadyRetire(Base):
    def setup_pair(self, ready=True):
        old_pid = self.live(OLD_ID, f"{T} #aaaaaaaa")
        new_pid = self.live(NEW_ID, f"{T} #bbbbbbbb")
        if ready:
            self.assertEqual(self.cli("ready", "--session", NEW_ID).returncode, 0)
        return old_pid, new_pid

    def test_ready_writes_marker(self):
        self.assertEqual(self.cli("ready", "--session", NEW_ID).returncode, 0)
        self.assertTrue((self.cache / f"{NEW_ID}.ready").exists())

    def retire(self, *extra):
        return self.cli("retire", "--session", OLD_ID, "--json", *extra)

    def test_refusals(self):
        # target dead
        dead = self.dead_pid()
        self.live(OLD_ID, f"{T} #aaaaaaaa", pid=dead)
        r = self.retire()
        self.assertEqual(r.returncode, 2)
        self.assertIn("not running", r.stderr)
        (self.sessions / f"{dead}.json").unlink()
        # caller = target
        self.setup_pair()
        r = self.retire("--caller", OLD_ID)
        self.assertEqual(r.returncode, 2)
        self.assertIn("caller", r.stderr)

    def test_no_successor(self):
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        r = self.retire()
        self.assertEqual(r.returncode, 2)
        self.assertIn("successor", r.stderr)

    def test_successor_not_ready(self):
        self.setup_pair(ready=False)
        r = self.retire()
        self.assertEqual(r.returncode, 2)
        self.assertIn("ready", r.stderr)

    def test_name_not_a_watchdog_title(self):
        self.live(OLD_ID, f"deprecated {T} #aaaaaaaa")
        r = self.retire()
        self.assertEqual(r.returncode, 2)
        self.assertIn("title", r.stderr)

    def test_plan(self):
        old_pid, _ = self.setup_pair()
        r = self.retire("--caller", NEW_ID)
        self.assertEqual(r.returncode, 0, r.stderr)
        d = json.loads(r.stdout)
        self.assertEqual((d["pid"], d["new_name"]), (old_pid, f"deprecated {T} #aaaaaaaa"))
        self.assertEqual(d["type"], [f"/rename deprecated {T} #aaaaaaaa", "/exit"])

    def test_verify(self):
        old_pid, _ = self.setup_pair()
        self.assertEqual(self.retire("--verify").returncode, 6)
        f = self.sessions / f"{old_pid}.json"
        d = json.loads(f.read_text())
        d["name"] = f"deprecated {T} #aaaaaaaa"
        f.write_text(json.dumps(d))
        self.assertEqual(self.retire("--verify").returncode, 0)
        d["name"] = f"{T} #aaaaaaaa"
        f.write_text(json.dumps(d))
        for p in self.procs:
            if p.pid == old_pid:
                p.kill()
                p.wait()
        self.assertEqual(self.retire("--verify").returncode, 0)


# 21-22 help and alias
class TestHelpAlias(Base):
    def test_help_lists_every_subcommand(self):
        for args in (["help"], []):
            r = self.cli(*args)
            self.assertEqual(r.returncode, 0, r.stderr)
            for sub in ("status", "restore", "new", "handoff", "ready", "retire", "help"):
                self.assertRegex(r.stdout, rf"(?m)^\s*{sub}\b.+", sub)

    def test_latest_alias(self):
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        a = self.cli("--title", T, "--project-dir", PROJECT, script=SCRIPTS / "latest.py")
        b = self.cli("restore", "--title", T, "--project-dir", PROJECT)
        self.assertEqual((a.returncode, a.stdout), (b.returncode, b.stdout))
        self.assertIn("watchdog.py restore", a.stderr)


if __name__ == "__main__":
    unittest.main()
