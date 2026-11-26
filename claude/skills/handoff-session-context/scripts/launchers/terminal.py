"""The terminal front-end: it works in every environment, because it only prints. No capabilities."""
import shlex
import sys

from . import Started


class Terminal:
    name = "terminal"
    caps = frozenset()

    def __init__(self, out=None):
        self.out = out

    def start(self, plan):
        """Print one line that the owner can paste into any shell: cd DIR && claude ..."""
        print(f"cd {shlex.quote(plan['project_dir'])} && {shlex.join(plan['argv'])}", file=self.out or sys.stdout)
        return Started(where="printed", window_label=plan.get("window_label", ""))

    def find_pane(self, pid):
        return None

    def send_line(self, pane, text):
        raise NotImplementedError("the terminal front-end cannot type: print the line for the owner")

    def rename_window(self, pane, label):
        raise NotImplementedError("the terminal front-end has no windows")
