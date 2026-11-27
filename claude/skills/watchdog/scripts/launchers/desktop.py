"""The Claude Desktop front-end, as far as a CLI can go: it prints the arguments of the Desktop tool start_session
as one JSON object. The model calls start_session with them, then detach_session (skill watchdog, SKILL.md).
It cannot resume a session, or find, type into or rename one.
"""
import json
import sys

from . import Started


def _arg(argv, flag):
    return argv[argv.index(flag) + 1] if flag in argv else None


class Desktop:
    name = "desktop"
    caps = frozenset()

    def __init__(self, session=None, out=None):
        self.out = out or sys.stdout

    def start(self, plan):
        argv = plan["argv"]
        args = {"title": plan["name"], "cwd": plan["project_dir"], "model": _arg(argv, "--model"),
                "prompt": argv[-1], "use_worktree": False, "context": "fresh"}
        if _arg(argv, "--effort"):
            args["effort"] = _arg(argv, "--effort")
        print(json.dumps(args), file=self.out)
        return Started(where="printed", window_label=plan.get("window_label", ""))
