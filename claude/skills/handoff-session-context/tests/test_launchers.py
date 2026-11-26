#!/usr/bin/env python3
"""Tests of the launcher layer (docs/plans/PLAN-watchdog-launchers.md v6, use cases 3-24; step 3: written before
scripts/launchers/ exists). The numbered use cases were given in chat before this file."""
import json
import os
import shlex
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_watchdog import Base, T, PROJECT, OLD_ID, NEW_ID, SCRIPTS, wd  # noqa: E402

LABEL = "watchdog-master #aaaaaaaa"


def launchers():
    import launchers as mod  # scripts/launchers/ (sys.path has SCRIPTS through test_watchdog)
    return mod


def steps():
    from launchers import steps as mod
    return mod


def plan(argv=("claude", "--resume", OLD_ID, "-n", T, "the prompt"), window_label=LABEL, project_dir=PROJECT):
    return {"session": OLD_ID, "name": T, "argv": list(argv), "project_dir": project_dir, "window_label": window_label}


# ---- CLI: watchdog.py with a rex stub on PATH -------------------------------------------------------------------

STUB = r'''#!{py}
import json, sys
args = sys.argv[1:]
with open({log!r}, "a") as fh:
    fh.write(json.dumps(args) + "\n")
if args[:2] == ["session", "ls"]:
    print(json.dumps({{"sessions": [{{"session_id": "session:1", "label": "proj"}}]}}))
else:
    print("{{}}")
'''


class CliBase(Base):
    def setUp(self):
        super().setUp()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.rex_log = self.root / "rex.log"
        stub = self.bin / "rex"
        stub.write_text(STUB.format(py=sys.executable, log=str(self.rex_log)))
        stub.chmod(0o755)
        self.env["PATH"] = f"{self.bin}:/usr/bin:/bin"
        self.env["WATCHDOG_WAIT"] = "0"

    def rex_calls(self):
        if not self.rex_log.exists():
            return []
        return [json.loads(x) for x in self.rex_log.read_text().splitlines()]


class TestCliFrontend(CliBase):
    def test_frontend_rex_uses_rex_and_unknown_is_usage(self):  # 3
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT, "--frontend", "rex")
        self.assertIn(["window", "new"], [c[:2] for c in self.rex_calls()], r.stderr)
        self.rex_log.unlink()
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT, "--frontend", "x")
        self.assertEqual(r.returncode, 64, r.stderr)
        self.assertEqual(self.rex_calls(), [])

    def test_label_option_is_usage(self):  # 4
        for cmd in (["new", "--model", "claude-opus-5-5"], ["restore"]):
            r = self.cli(cmd[0], "--title", T, *cmd[1:], "--project-dir", PROJECT, "--frontend", "rex",
                         "--label", "x")
            self.assertEqual(r.returncode, 64, f"{cmd[0]}: {r.stderr}")
        self.assertEqual(self.rex_calls(), [])

    def test_frontend_rex_without_rex_on_path(self):  # 5
        self.env["PATH"] = str(self.root / "empty")
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT, "--frontend", "rex")
        self.assertEqual(r.returncode, 64, r.stderr)
        self.assertIn("rex", r.stderr)
        self.assertEqual(r.stdout, "")

    def test_restore_guard_before_any_rex_call(self):  # 12
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        self.live(OLD_ID, T)
        r = self.cli("restore", "--title", T, "--project-dir", PROJECT, "--frontend", "rex")
        self.assertEqual(r.returncode, 2, r.stderr)
        self.assertIn("still running", r.stderr)  # the guard, not an argparse usage error (also exit 2)
        self.assertEqual(self.rex_calls(), [])

    def test_new_without_the_name_in_time_exit_5(self):  # 13
        r = self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT, "--frontend", "rex")
        self.assertEqual(r.returncode, 5, r.stderr)
        news = [c for c in self.rex_calls() if c[:2] == ["window", "new"]]
        self.assertEqual(len(news), 1)
        self.assertNotIn("started", r.stdout)

    def test_handoff_same_model_and_fable_refused(self):  # 14
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", title=f"{T} #aaaaaaaa", model="claude-sonnet-5-5")
        self.live(OLD_ID, f"{T} #aaaaaaaa")
        self.cli("handoff", "--title", T, "--handoff-file", "h.md", "--project-dir", PROJECT, "--frontend", "rex")
        news = [c for c in self.rex_calls() if c[:2] == ["window", "new"]]
        self.assertEqual(len(news), 1)
        argv = news[0][news[0].index("--") + 1:]
        self.assertEqual(argv[3:5], ["--model", "claude-sonnet-5-5"])
        self.rex_log.unlink()
        for p in self.procs:
            p.kill()
            p.wait()
        self.procs.clear()
        for f in self.sessions.glob("*.json"):
            f.unlink()
        self.session(NEW_ID, "u2", "2026-11-24T10:00:00Z", title=f"{T} #bbbbbbbb", model="claude-fable-5-2")
        self.live(NEW_ID, f"{T} #bbbbbbbb")
        r = self.cli("handoff", "--title", T, "--handoff-file", "h.md", "--project-dir", PROJECT, "--frontend", "rex")
        self.assertEqual(r.returncode, 4, r.stderr)
        self.assertEqual(self.rex_calls(), [])


# ---- names (decision layer) ---------------------------------------------------------------------------------------

class TestNames(Base):
    SID = "de18597a-0000-4000-8000-000000000001"

    def test_window_label_for(self):  # 6
        cases = {"proj (watchdog-master)": "watchdog-master #de18597a",
                 "proj/ (watchdog)": "watchdog #de18597a",
                 "a (b) (watchdog-slave)": "watchdog-slave #de18597a",
                 "plain title": "plain title #de18597a",
                 "proj (watchdog-master) #aaaaaaaa": "watchdog-master #de18597a"}
        for title, label in cases.items():
            self.assertEqual(wd.window_label_for(title, self.SID), label, title)

    def test_names_do_not_depend_on_the_caller(self):  # 7
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z", title=f"{T} #aaaaaaaa")
        callers = [({}, None),
                   ({"REX_SESSION": "session:other", "REX_BLOCK": "block:crawl-problems-review"}, None),
                   ({}, str(self.root))]
        seen = []
        for extra, cwd in callers:
            env = {**os.environ, **self.env, **extra}
            import subprocess
            r = subprocess.run([sys.executable, str(SCRIPTS / "watchdog.py"), "restore", "--title", T,
                                "--project-dir", PROJECT, "--json"], text=True, capture_output=True, env=env, cwd=cwd)
            self.assertEqual(r.returncode, 0, r.stderr)
            d = json.loads(r.stdout)
            seen.append((d["window_label"], d["title"]))
        self.assertEqual(seen, [("watchdog-master #aaaaaaaa", f"{T} #aaaaaaaa")] * 3)
        n = json.loads(self.cli("new", "--title", T, "--model", "claude-opus-5-5", "--project-dir", PROJECT,
                                "--json").stdout)
        self.assertEqual(n["window_label"], f"watchdog-master #{n['session'][:8]}")


class TestOldWindowLabel(unittest.TestCase):
    SID = "b7e63c93-6629-4a87-a274-8760e70bb5f0"

    def test_old_window_label(self):  # D1
        title = "proj (watchdog-master) #b7e63c93"
        for label in ("watchdog-master #b7e63c93", "watchdog-master-b7e63c93"):
            self.assertTrue(wd.old_window_label(label, title, self.SID), label)
        for label in ("watchdog-master #aaaaaaaa", "watchdog-slave #b7e63c93", "watchdog-master", "b7e63c93",
                      "archived-watchdog-master #b7e63c93x",
                      "archived-watchdog-master-b7e63c93"):
            self.assertFalse(wd.old_window_label(label, title, self.SID), label)


# ---- rex launcher with a recording run ----------------------------------------------------------------------------

class FakeRex:
    """Answers the rex calls that the launcher makes; records each argv."""

    def __init__(self, sessions=("proj",), windows=None, pids=None):
        self.calls = []
        self.sessions = list(sessions)
        self.windows = windows or {}  # session label -> [(window id, label, [block ids])]
        self.pids = pids or {}  # block id -> child pid

    def __call__(self, args):
        self.calls.append(list(args))
        if args[:2] == ["session", "ls"]:
            return json.dumps({"sessions": [{"session_id": f"session:{s}", "label": s} for s in self.sessions]})
        if args[:2] == ["window", "ls"]:
            s = args[args.index("-s") + 1]
            return json.dumps({"windows": [{"window_id": wid, "label": label,
                                            "layers": [{"blocks": [{"block_id": b} for b in blocks]}]}
                                           for wid, label, blocks in self.windows.get(s, [])]})
        if args[:2] == ["block", "call"]:
            b = args[args.index("-b") + 1]
            return json.dumps({"child": {"pid": self.pids[b]}} if b in self.pids else {"last_exit": {"exit_code": 0}})
        return "{}"


class TestRexLauncher(unittest.TestCase):
    def rex(self, fake, session=None):
        return launchers().get("rex", session=session, run=fake)

    def test_project_session_not_the_callers(self):  # 8
        fake = FakeRex(sessions=("other", "proj"))
        os.environ["REX_SESSION"] = "session:other"
        try:
            self.rex(fake).start(plan())
        finally:
            os.environ.pop("REX_SESSION")
        news = [c for c in fake.calls if c[:2] == ["window", "new"]]
        self.assertEqual(len(news), 1)
        self.assertEqual(news[0][2:4], ["-s", "proj"])

    def test_missing_project_session_one_session_new(self):  # 9
        fake = FakeRex(sessions=("other",))
        p = plan()
        self.rex(fake).start(p)
        made = [c for c in fake.calls if c[:2] != ["session", "ls"]]
        self.assertEqual(made, [["session", "new", "proj", "--window", LABEL, "-c", PROJECT, "--keep-open", "--",
                                 *p["argv"]]])

    def test_rex_override_no_lookup(self):  # 10
        fake = FakeRex(sessions=("proj",))
        self.rex(fake, session="S").start(plan())
        self.assertEqual([c[:2] for c in fake.calls], [["window", "new"]])
        self.assertEqual(fake.calls[0][2:4], ["-s", "S"])

    def test_start_exact_argv(self):  # 21
        fake = FakeRex()
        p = plan()
        started = self.rex(fake).start(p)
        self.assertEqual(fake.calls[-1], ["window", "new", "-s", "proj", LABEL, "-c", PROJECT, "--keep-open", "--",
                                          *p["argv"]])
        self.assertEqual(fake.calls[-1][-1], "the prompt")
        self.assertEqual(started.window_label, LABEL)

    def test_find_pane(self):  # 22
        fake = FakeRex(windows={"proj": [("window:1", "a", ["block:1"]), ("window:2", LABEL, ["block:2", "block:3"])]},
                       pids={"block:1": 11, "block:3": 4242})
        pane = self.rex(fake).find_pane(4242)
        self.assertEqual((pane.session, pane.window, pane.block), ("proj", "window:2", "block:3"))
        self.assertIsNone(self.rex(fake).find_pane(999))

    def test_find_ended(self):  # R1, R2
        fake = FakeRex(sessions=("other", "proj"),
                       windows={"proj": [("window:1", LABEL, ["block:1"]),             # ended, same label
                                         ("window:2", "watchdog-master-aaaaaaaa", ["block:2"]),  # ended, old style
                                         ("window:3", LABEL, ["block:3"]),             # same label, live
                                         ("window:4", "other #aaaaaaaa", ["block:4"])],  # ended, no match
                                "other": [("window:5", LABEL, ["block:5"])]},
                       pids={"block:3": 4242})
        match = lambda label: label in (LABEL, "watchdog-master-aaaaaaaa")  # noqa: E731
        panes = self.rex(fake).find_ended(plan(), match)
        self.assertEqual([(p.session, p.window, p.label) for p in panes],
                         [("proj", "window:1", LABEL), ("proj", "window:2", "watchdog-master-aaaaaaaa")])
        self.assertNotIn(["window", "ls", "-s", "other", "--json"], fake.calls)
        fake2 = FakeRex(windows={"S": [("window:7", LABEL, ["block:7"])]})
        self.assertEqual([p.window for p in self.rex(fake2, session="S").find_ended(plan(), match)], ["window:7"])

    def test_label_with_space_and_hash(self):  # 23
        fake = FakeRex(windows={"proj": [("window:2", "watchdog-master #de18597a", ["block:2"])]},
                       pids={"block:2": 77})
        r = self.rex(fake)
        pane = r.find_pane(77)
        self.assertEqual(pane.label, "watchdog-master #de18597a")
        r.rename_window(pane, "archived-" + pane.label)
        self.assertEqual(fake.calls[-1], ["window", "rename", "-s", "proj", "window:2",
                                          "archived-watchdog-master #de18597a"])


# ---- terminal launcher --------------------------------------------------------------------------------------------

class TestTerminalLauncher(unittest.TestCase):
    def test_start_prints_a_pasteable_line(self):  # 24
        import io
        out = io.StringIO()
        t = launchers().get("terminal", out=out)
        p = plan(argv=("claude", "--resume", OLD_ID, "-n", T, "it's `quoted` & $HOME; done"),
                 project_dir="/home/u/my proj")
        t.start(p)
        line = out.getvalue().strip()
        self.assertEqual(len(line.splitlines()), 1)
        cd, cmd = line.split(" && ", 1)
        self.assertEqual(shlex.split(cd), ["cd", "/home/u/my proj"])
        self.assertEqual(shlex.split(cmd), p["argv"])
        self.assertEqual(set(t.caps), set())


# ---- orchestration with a fake launcher ---------------------------------------------------------------------------

class FakeLauncher:
    name = "fake"

    def __init__(self, caps=("start", "find_pane", "send", "rename", "find_ended"), pane=True, events=None,
                 windows=()):
        self.caps = frozenset(caps)
        self.events = [] if events is None else events
        self.windows = windows  # (label, ended) pairs in the target session
        self.pane = launchers().Pane(session="proj", window="window:2", label=LABEL, block="block:2") if pane else None

    def start(self, p):
        self.events.append(("start", p))
        return launchers().Started(where="proj", window_label=p["window_label"])

    def find_pane(self, pid):
        self.events.append(("find_pane", pid))
        return self.pane

    def find_ended(self, p, match):
        self.events.append(("find_ended",))
        return [launchers().Pane(session="proj", window=f"window:{i}", label=label, block=f"block:{i}")
                for i, (label, ended) in enumerate(self.windows) if ended and match(label)]

    def send_line(self, pane, text):
        self.events.append(("send", text))

    def rename_window(self, pane, label):
        self.events.append(("rename", label))


RETIRE = {"session": OLD_ID, "pid": 4242, "name": f"{T} #aaaaaaaa", "new_name": f"deprecated {T} #aaaaaaaa",
          "successor": NEW_ID, "type": [f"/rename deprecated {T} #aaaaaaaa", "/exit"]}


class TestSteps(Base):
    def retire(self, fake, yes=True, verified=lambda: True, alive=lambda pid: False):
        import io
        out = io.StringIO()
        ev = fake.events

        def v():
            ev.append(("verified",))
            return verified()

        def a(pid):
            ev.append(("alive",))
            return alive(pid)
        code = steps().retire(fake, RETIRE, yes=yes, verified=v, alive=a, sleep=lambda s: None, verify_tries=3,
                              exit_wait=3, out=out, err=io.StringIO())
        return code, out.getvalue()

    def sends(self, fake):
        return [e[1] for e in fake.events if e[0] == "send"]

    def test_start_passes_the_plan_unchanged(self):  # 11
        self.session(OLD_ID, "u1", "2026-11-24T10:00:00Z")
        p = json.loads(self.cli("restore", "--title", T, "--project-dir", PROJECT, "--json").stdout)
        fake = FakeLauncher()
        waited = []
        import io
        code = steps().start(fake, dict(p), p["title"], wait_name=lambda n, t: waited.append(n) or True,
                             timeout=1, out=io.StringIO())
        self.assertEqual(code, 0)
        self.assertEqual(fake.events, [("start", p)])
        self.assertEqual(fake.events[0][1]["argv"][-1], wd.RESTORE_PROMPT)
        self.assertEqual(waited, [p["title"]])

    def start_restore(self, fake):
        import io
        p = plan(argv=("claude", "--resume", OLD_ID, "-n", f"{T} #aaaaaaaa", "the prompt"))
        p["title"] = f"{T} #aaaaaaaa"
        code = steps().start(fake, p, p["title"], wait_name=lambda n, t: True, timeout=1, out=io.StringIO(),
                             match=lambda label: wd.old_window_label(label, p["title"], OLD_ID))
        return code, [e for e in fake.events if e[0] in ("rename", "start")]

    def test_restore_archives_the_ended_window_first(self):  # A1, A2, A3
        fake = FakeLauncher(windows=[(LABEL, True), ("watchdog-master-aaaaaaaa", True), (LABEL, False),
                                     ("watchdog-master #bbbbbbbb", True)])
        code, ev = self.start_restore(fake)
        self.assertEqual(code, 0)
        self.assertEqual([e[0] for e in ev], ["rename", "rename", "start"])
        self.assertEqual([e[1] for e in ev[:2]], [f"archived-{LABEL}", "archived-watchdog-master-aaaaaaaa"])

    def test_no_find_ended_cap_no_call(self):  # A4
        fake = FakeLauncher(caps=("start",), windows=[(LABEL, True)])
        code, ev = self.start_restore(fake)
        self.assertEqual(code, 0)
        self.assertEqual([e[0] for e in fake.events], ["start"])

    def test_retire_order(self):  # 15
        fake = FakeLauncher()
        code, _ = self.retire(fake)
        self.assertEqual(code, 0)
        order = [e for e in fake.events if e[0] != "find_pane"]
        self.assertEqual(order, [("send", f"/rename deprecated {T} #aaaaaaaa"), ("verified",), ("send", "/exit"),
                                 ("alive",), ("rename", f"archived-{LABEL}")])

    def test_rename_not_seen_exit_7(self):  # 16
        fake = FakeLauncher()
        code, _ = self.retire(fake, verified=lambda: False)
        self.assertEqual(code, 7)
        self.assertNotIn("/exit", self.sends(fake))
        self.assertNotIn("rename", [e[0] for e in fake.events])

    def test_process_does_not_end_exit_8(self):  # 17
        fake = FakeLauncher()
        code, _ = self.retire(fake, alive=lambda pid: True)
        self.assertEqual(code, 8)
        self.assertIn("/exit", self.sends(fake))
        self.assertNotIn("rename", [e[0] for e in fake.events])

    def test_no_pane_exit_9(self):  # 18
        fake = FakeLauncher(pane=False)
        code, _ = self.retire(fake)
        self.assertEqual(code, 9)
        self.assertEqual(self.sends(fake), [])

    def test_dry_run_sends_nothing(self):  # 19
        fake = FakeLauncher()
        code, out = self.retire(fake, yes=False)
        self.assertEqual(code, 0)
        self.assertEqual(self.sends(fake), [])
        self.assertIn(f"/rename deprecated {T} #aaaaaaaa", out)

    def test_no_caps_prints_the_lines(self):  # 20
        fake = FakeLauncher(caps=())
        code, out = self.retire(fake)
        self.assertEqual(code, 0)
        self.assertEqual(fake.events, [])
        for line in RETIRE["type"]:
            self.assertIn(line, out)


if __name__ == "__main__":
    unittest.main()
