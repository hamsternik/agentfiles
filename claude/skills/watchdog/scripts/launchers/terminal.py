"""The terminal front-end: this terminal becomes the session (os.execvp of the plan argv in the project folder).

watchdog.py refuses it inside a Claude Code session ($CLAUDECODE set) before it gets here: a `claude` exec in the
Bash tool of a session would nest a second session. It cannot find, type into or rename another pane.
"""
import os
import sys

from . import Started


class Terminal:
    name = "terminal"
    caps = frozenset({"start"})

    def __init__(self, session=None, execvp=None):
        self.execvp = execvp or os.execvp

    def start(self, plan):
        sys.stdout.flush()  # the printed claude line must not be lost in the buffer
        sys.stderr.flush()
        os.chdir(plan["project_dir"])
        self.execvp(plan["argv"][0], plan["argv"])  # does not return
        return Started(where="this terminal", window_label=plan.get("window_label", ""))
