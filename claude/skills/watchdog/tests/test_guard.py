#!/usr/bin/env python3
"""Tests of `watchdog.py guard`, the PreToolUse hook that stops a watchdog from doing file work inline (gap G1), and
of `watchdog.py guard --install --settings F`. Use cases 1-15, 19-20 and 24 of the change "watchdog inline guard"
(the owner checked the list first, 2026-11-27).

The hook reads the PreToolUse JSON on stdin. Pass: exit 0, no output. Refuse: exit 2, the reason on stderr.
Allow-list of a watchdog session (paths from the git root of the project):
  the project's memory folder; <prompts folder>/<project>-watchdog*.md; a file name with "handoff" (any type,
  any case); *-prompt-*.md; the queue file (every watchdog)."""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SKILL = HERE.parent
SCRIPT = SKILL / "scripts" / "watchdog.py"
sys.path.insert(0, str(SKILL.parent / "handoff-session-context" / "scripts"))
import context  # noqa: E402

SID = "0a1b2c3d-1111-2222-3333-444455556666"
WATCHDOG = "myproj (watchdog) #0a1b2c3d"
MATCHER = "Edit|Write|NotebookEdit"


class Base(unittest.TestCase):
    def setUp(self):
        self._td = tempfile.TemporaryDirectory()
        self.root = Path(self._td.name).resolve()
        self.proj = self.git_repo("myproj")
        self.projects = self.root / "claude-projects"
        self.sessions = self.root / "sessions"
        self.sessions.mkdir()
        self.projects.mkdir()

    def tearDown(self):
        self._td.cleanup()

    def git_repo(self, name):
        d = self.root / name
        d.mkdir()
        subprocess.run(["git", "init", "-q", str(d)], check=True)
        return d

    def memory(self, repo=None):
        return self.projects / context.project_slug(repo or self.proj) / "memory"

    def live(self, name, session=SID):
        (self.sessions / f"{os.getpid()}.json").write_text(
            json.dumps({"pid": os.getpid(), "sessionId": session, "name": name}))

    def transcript(self, title, session=SID):
        p = self.projects / context.project_slug(self.proj) / f"{session}.jsonl"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps({"type": "custom-title", "customTitle": title, "sessionId": session}) + "\n")
        return p

    def payload(self, path, tool="Edit", **extra):
        key = "notebook_path" if tool == "NotebookEdit" else "file_path"
        return {"session_id": SID, "hook_event_name": "PreToolUse", "tool_name": tool, "cwd": str(self.proj),
                "transcript_path": str(self.projects / context.project_slug(self.proj) / f"{SID}.jsonl"),
                "tool_input": {key: str(path)}, **extra}

    def env(self, project_dir=True, **more):
        env = {k: v for k, v in os.environ.items() if k not in ("CLAUDECODE", "CLAUDE_PROJECT_DIR")}
        env.update(HANDOFF_PROJECTS_DIR=str(self.projects), HANDOFF_SESSIONS_DIR=str(self.sessions),
                   PATH="/usr/bin:/bin", **more)
        if project_dir:
            env["CLAUDE_PROJECT_DIR"] = str(self.proj if project_dir is True else project_dir)
        return env

    def guard(self, data, **env):
        text = data if isinstance(data, str) else json.dumps(data)
        return subprocess.run([sys.executable, str(SCRIPT), "guard"], input=text, text=True, capture_output=True,
                              env=self.env(**env), cwd=self.root)

    def assertPass(self, r, msg=None):
        self.assertEqual((r.returncode, r.stdout), (0, ""), f"{msg}: {r.stderr}")

    def assertRefused(self, r, msg=None):
        self.assertEqual(r.returncode, 2, f"{msg}: rc {r.returncode} {r.stderr}")
        self.assertIn("route it:", r.stderr, msg)

    def check(self, paths, want, tool="Edit"):
        for rel in paths:
            path = rel if os.path.isabs(str(rel)) else self.proj / rel
            with self.subTest(path=str(rel)):
                want(self.guard(self.payload(path, tool)), str(rel))


class Watchdog(Base):
    def setUp(self):
        super().setUp()
        self.live(WATCHDOG)


# 1, 2. only a session with "(watchdog" in its name is guarded
class TestWhichSession(Base):
    def test_a_work_session_passes(self):
        self.live("data load #1a2b3c4d")
        self.assertPass(self.guard(self.payload(self.proj / "src/main.py")))

    def test_watchdog_with_no_bracket_passes(self):
        for name in ("watchdog inline guard", "myproj-watchdog", "fix the watchdog (queue)"):
            with self.subTest(name=name):
                self.live(name)
                self.assertPass(self.guard(self.payload(self.proj / "src/main.py")), name)

    def test_each_watchdog_form_is_guarded(self):
        for name in ("myproj (watchdog)", "myproj (watchdog-master) #1a2b3c4d", "myproj (watchdog-slave)"):
            with self.subTest(name=name):
                self.live(name)
                self.assertRefused(self.guard(self.payload(self.proj / "src/main.py")), name)


# 3. a code file: refused, with the way out
class TestRefuse(Watchdog):
    def test_each_write_tool(self):
        for tool, rel in (("Edit", "src/main.py"), ("Write", "tests/test_x.py"), ("NotebookEdit", "a.ipynb")):
            with self.subTest(tool=tool):
                self.assertRefused(self.guard(self.payload(self.proj / rel, tool)), tool)

    def test_the_message_names_the_file_and_the_routes(self):
        r = self.guard(self.payload(self.proj / "docs/local/report-20261127.md", "Write"))
        self.assertRefused(r)
        for part in ("report-20261127.md", "sub-agent", "watchdog.py start --title"):
            self.assertIn(part, r.stderr)

    def test_a_relative_path_counts_from_the_cwd(self):
        data = self.payload("x")
        data["tool_input"]["file_path"] = "src/main.py"
        self.assertRefused(self.guard(data))

    def test_without_project_dir_the_cwd_gives_the_project(self):
        sub = self.proj / "src"
        sub.mkdir()
        refused = self.payload(sub / "main.py", cwd=str(sub))
        allowed = self.payload(self.proj / "docs/local/a-prompt-1.md", cwd=str(sub))
        self.assertRefused(self.guard(refused, project_dir=False))
        self.assertPass(self.guard(allowed, project_dir=False))

    def test_project_dir_wins_over_a_changed_cwd(self):
        other = self.git_repo("other")
        self.assertRefused(self.guard(self.payload(other / "docs/local/a-prompt-1.md", cwd=str(other))))


# 4. the memory folder of the project
class TestMemory(Watchdog):
    def test_memory_files_pass(self):
        self.check([self.memory() / "watchdog-session.md", self.memory() / "MEMORY.md"], self.assertPass, "Write")

    def test_a_worktree_uses_the_memory_of_the_main_repo(self):
        git = ["git", "-C", str(self.proj), "-c", "user.name=t", "-c", "user.email=t@t"]
        subprocess.run([*git, "commit", "-q", "--allow-empty", "-m", "init"], check=True)
        wt = self.root / "wt"
        subprocess.run([*git, "worktree", "add", "-q", str(wt), "-b", "wt"], check=True, capture_output=True)
        data = self.payload(self.memory() / "MEMORY.md", cwd=str(wt))
        self.assertPass(self.guard(data, project_dir=wt))

    def test_other_memory_and_other_files_beside_it_are_refused(self):
        other = self.git_repo("other")
        self.check([self.memory(other) / "MEMORY.md", self.memory().parent / "notes.md"], self.assertRefused)


# 5. the project part
class TestProjectPart(Watchdog):
    def test_every_place_and_machine(self):
        self.check([".claude/docs/prompts/myproj-watchdog.md", "docs/prompts/myproj-watchdog.md",
                    "docs/prompts/myproj-watchdog-master.md"], self.assertPass)

    def test_other_prompt_files_are_refused(self):
        self.check([".claude/docs/prompts/some-task.md", ".claude/docs/prompts/other-watchdog.md",
                    "src/myproj-watchdog.md"], self.assertRefused)


# 6, 7. hand-off files and route prompt files
class TestHandoffAndPrompt(Watchdog):
    def test_handoff_files_of_any_type_and_case(self):
        self.check(["docs/local/myproj-watchdog-handoff-20261127.md", "runs/run1/HANDOFF.md",
                    "notes/handoff.txt", "src/handoff.py"], self.assertPass, "Write")

    def test_a_folder_named_handoff_gives_no_pass(self):
        self.check(["handoff/main.py", "claude/handoff-skill/notes.md"], self.assertRefused)

    def test_route_prompt_files(self):
        self.check(["docs/local/queue-titles-prompt-20261127.md", "docs/prompts/a-prompt-1.md"], self.assertPass,
                   "Write")

    def test_near_misses_are_refused(self):
        self.check(["docs/local/a-prompt-1.txt", "docs/local/prompt.md", "docs/local/a-prompts.md",
                    "a-prompt-1/main.py"], self.assertRefused)


# 8, 9. no way out of an allowed place
class TestOutside(Watchdog):
    def test_dot_dot(self):
        self.check([f"{self.proj}/docs/local/../../../outside/x-handoff.md",
                    f"{self.memory()}/../x.jsonl",
                    f"{self.proj}/docs/a-prompt-1.md/../../src/main.py"], self.assertRefused)

    def test_a_symlink_counts_as_its_target(self):
        (self.proj / "docs/local").mkdir(parents=True)
        (self.proj / "src").mkdir()
        (self.proj / "src/main.py").write_text("x\n")
        (self.proj / "docs/local/x-handoff.md").symlink_to(self.proj / "src/main.py")
        self.check(["docs/local/x-handoff.md"], self.assertRefused)

    def test_files_outside_the_project(self):
        other = self.git_repo("other")
        self.check([other / "docs/local/a-prompt-1.md", other / "docs/local/x-handoff.md",
                    self.root / "scratchpad/query.py", self.root / ".claude/settings.json"], self.assertRefused)


# 10, 11. the queue: every watchdog (the rules text names the one writer)
class TestQueue(Watchdog):
    def part(self, text):
        p = self.proj / "docs/prompts/myproj-watchdog.md"
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)

    def test_default_queue(self):
        self.check([".claude/docs/decisions/queue.md"], self.assertPass)

    def test_queue_named_in_the_project_part(self):
        self.part("# myproj\n\nQueue file: `docs/decisions/queue.md` (only the slave writes it).\n")
        self.check(["docs/decisions/queue.md"], self.assertPass)
        self.check(["docs/decisions/other.md"], self.assertRefused)

    def test_either_machine(self):
        for name in ("myproj (watchdog-master)", "myproj (watchdog-slave)"):
            with self.subTest(name=name):
                self.live(name)
                self.check([".claude/docs/decisions/queue.md"], self.assertPass)


# 12. a sub-agent does the routed work
class TestSubAgent(Watchdog):
    def test_a_sub_agent_passes(self):
        data = self.payload(self.proj / "src/main.py", agent_id="a1b2c3", agent_type="general-purpose")
        self.assertPass(self.guard(data))

    def test_agent_type_alone_is_the_main_session(self):  # a session started with --agent
        self.assertRefused(self.guard(self.payload(self.proj / "src/main.py", agent_type="claude")))


# 13. the live name, else the transcript title
class TestName(Base):
    def test_live_name_wins_over_the_transcript(self):
        self.transcript("myproj (watchdog)")
        self.live("renamed work session")
        self.assertPass(self.guard(self.payload(self.proj / "src/main.py")))
        self.transcript("work")
        self.live(WATCHDOG)
        self.assertRefused(self.guard(self.payload(self.proj / "src/main.py")))

    def test_no_live_record_uses_the_transcript_title(self):
        self.transcript(WATCHDOG)
        self.assertRefused(self.guard(self.payload(self.proj / "src/main.py")))

    def test_the_record_of_another_session_does_not_count(self):
        self.live(WATCHDOG, session="ffffffff-1111-2222-3333-444455556666")
        self.assertPass(self.guard(self.payload(self.proj / "src/main.py")))


# 14, 15. fail open: a broken input never blocks a session
class TestFailOpen(Watchdog):
    def test_bad_input_passes(self):
        for text in ("", "not json", "[1, 2]", "{}", json.dumps({"session_id": SID, "tool_name": "Edit"}),
                     json.dumps({"session_id": SID, "tool_name": "Edit", "tool_input": "x"})):
            with self.subTest(text=text):
                self.assertPass(self.guard(text), text)

    def test_no_name_passes(self):
        (self.sessions / f"{os.getpid()}.json").unlink()
        self.assertPass(self.guard(self.payload(self.proj / "src/main.py")))

    def test_other_tools_pass(self):
        for tool in ("Read", "Bash", "Agent"):
            with self.subTest(tool=tool):
                self.assertPass(self.guard(self.payload(self.proj / "src/main.py", tool)), tool)


# 19, 20, 24. install into one settings file
class TestInstall(Base):
    def setUp(self):
        super().setUp()
        self.settings = self.proj / ".claude/settings.local.json"
        self.settings.parent.mkdir()

    def install(self):
        return subprocess.run([sys.executable, str(SCRIPT), "guard", "--install", "--settings", str(self.settings)],
                              text=True, capture_output=True, env=self.env(), cwd=self.root)

    def entries(self):
        data = json.loads(self.settings.read_text())
        return [h for g in data["hooks"]["PreToolUse"] if g.get("matcher") == MATCHER for h in g["hooks"]]

    def backups(self):
        return sorted(self.settings.parent.glob("settings.local.json.bak-*"))

    def test_adds_the_hook_to_a_new_file(self):
        r = self.install()
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "added"), r.stderr)
        self.assertEqual([h["type"] for h in self.entries()], ["command"])

    def test_keeps_the_other_settings_and_hooks(self):
        other = {"matcher": "Bash", "hooks": [{"type": "command", "command": "other"}]}
        self.settings.write_text(json.dumps({"permissions": {"allow": ["Bash(ls)"]},
                                             "hooks": {"PreToolUse": [other], "Stop": [{"hooks": []}]}}))
        self.assertEqual(self.install().returncode, 0)
        data = json.loads(self.settings.read_text())
        self.assertEqual(data["permissions"], {"allow": ["Bash(ls)"]})
        self.assertEqual(data["hooks"]["Stop"], [{"hooks": []}])
        self.assertEqual(data["hooks"]["PreToolUse"][0], other)
        self.assertEqual(len(self.entries()), 1)

    def test_a_second_run_changes_nothing(self):
        self.install()
        before = self.settings.read_bytes()
        r = self.install()
        self.assertEqual((r.returncode, r.stdout.strip()), (0, "present"), r.stderr)
        self.assertEqual(self.settings.read_bytes(), before)
        self.assertEqual(self.backups(), [])

    def test_invalid_json_is_left_alone(self):
        self.settings.write_text("{ not json")
        r = self.install()
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("settings.local.json", r.stderr)
        self.assertEqual(self.settings.read_text(), "{ not json")

    def test_an_older_backup_is_never_overwritten(self):
        self.settings.write_text('{"model": "first"}\n')
        self.install()
        first = self.backups()
        self.assertEqual([p.read_text() for p in first], ['{"model": "first"}\n'])
        self.settings.write_text('{"model": "second"}\n')  # same day, an other edit
        self.install()
        self.assertEqual(sorted(p.read_text() for p in self.backups()),
                         ['{"model": "first"}\n', '{"model": "second"}\n'])

    def run_hook(self, home):
        self.install()
        command = self.entries()[0]["command"]
        return subprocess.run(["/bin/sh", "-c", command], input=json.dumps(self.payload(self.proj / "src/main.py")),
                              text=True, capture_output=True, env=self.env(HOME=str(home)), cwd=self.root)

    def test_the_installed_command_runs_the_guard(self):
        home = self.root / "home"
        (home / ".claude/skills").mkdir(parents=True)
        (home / ".claude/skills/watchdog").symlink_to(SKILL)
        self.live(WATCHDOG)
        self.assertRefused(self.run_hook(home))

    def test_a_missing_script_never_blocks(self):  # python3 exits 2 for a missing file, and 2 blocks the tool
        self.live(WATCHDOG)
        r = self.run_hook(self.root / "empty-home")
        self.assertEqual((r.returncode, r.stdout), (0, ""), r.stderr)


class TestHelp(unittest.TestCase):
    def test_help_names_guard(self):
        r = subprocess.run([sys.executable, str(SCRIPT), "help"], text=True, capture_output=True)
        self.assertRegex(r.stdout, r"(?m)^  guard ")


if __name__ == "__main__":
    unittest.main()
