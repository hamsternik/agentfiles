"""The Rex front-end (replaces rex-watchdog.sh). Each Rex call is printed on stderr ("+ rex ...") before it runs.

Rex session: the session labelled with the project folder name, made by `rex session new` when it is missing (one call
that also starts the watchdog in its first window). `session=` overrides it. REX_SESSION never chooses it.
"""
import json
import os
import shlex
import subprocess
import sys

from . import CAPS, Pane, Started


class RexError(RuntimeError):
    def __init__(self, msg, code=1):
        super().__init__(msg)
        self.code = code


def _rex(args):
    print("+ rex " + shlex.join(args), file=sys.stderr)
    r = subprocess.run(["rex", *args], text=True, capture_output=True)
    if r.returncode:
        raise RexError(f"rex {' '.join(args[:2])} failed ({r.returncode}): {r.stderr.strip()}", r.returncode)
    return r.stdout


class Rex:
    name = "rex"
    caps = CAPS

    def __init__(self, session=None, run=None):
        self.session = session
        self.run = run or _rex

    def _session_labels(self):
        return [s.get("label") for s in json.loads(self.run(["session", "ls", "--json"]) or "{}").get("sessions", [])]

    def start(self, plan):
        label, cwd = plan["window_label"], plan["project_dir"]
        tail = ["-c", cwd, "--keep-open", "--", *plan["argv"]]  # the prompt stays the last item, after `--`
        session = self.session
        if not session:
            session = os.path.basename(cwd.rstrip("/"))
            if session not in self._session_labels():
                self.run(["session", "new", session, "--window", label, *tail])
                return Started(where=session, window_label=label)
        self.run(["window", "new", "-s", session, label, *tail])
        return Started(where=session, window_label=label)

    def find_pane(self, pid):
        for session in ([self.session] if self.session else self._session_labels()):
            windows = json.loads(self.run(["window", "ls", "-s", session, "--json"]) or "{}").get("windows", [])
            for w in windows:
                for layer in w.get("layers", []):
                    for b in layer.get("blocks", []):
                        try:
                            child = json.loads(self.run(["block", "call", "-b", b["block_id"], "process"]))["child"]
                        except (KeyError, TypeError, ValueError, RexError):
                            continue
                        if child.get("pid") == pid:
                            return Pane(session=session, window=w["window_id"], label=w.get("label", ""),
                                        block=b["block_id"])
        return None

    def send_line(self, pane, text):
        if text:
            self.run(["send", "-b", pane.block, text])
        self.run(["send-key", "-b", pane.block, "enter"])

    def rename_window(self, pane, label):
        self.run(["window", "rename", "-s", pane.session, pane.window, label])
