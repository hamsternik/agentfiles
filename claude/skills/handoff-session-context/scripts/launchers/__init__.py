"""Front-end launchers of the watchdog CLI (docs/plans/PLAN-watchdog-launchers.md, v6).

watchdog.py decides; a launcher only starts, finds, types into and renames sessions of one front-end. A launcher has
`name`, `caps` (the operations that really act) and the 4 operations of `Launcher`. When a capability is missing,
the caller prints the step for the owner (launchers/steps.py). Standard library only. No CLI: watchdog.py is the one
entry point.
"""
from dataclasses import dataclass
from typing import Optional, Protocol

CAPS = frozenset({"start", "find_pane", "send", "rename"})
NAMES = ("terminal", "rex")


@dataclass(frozen=True)
class Pane:
    session: str  # the front-end's session (Rex: the session label)
    window: str  # the window id
    label: str  # the window label
    block: str  # the pane (Rex: block id)


@dataclass(frozen=True)
class Started:
    where: str  # the front-end's session that got the window ("printed" when nothing started)
    window_label: str


class Launcher(Protocol):
    name: str
    caps: frozenset

    def start(self, plan: dict) -> Started:
        """Start (or print) plan["argv"] in plan["project_dir"], in a window plan["window_label"]."""

    def find_pane(self, pid: int) -> Optional[Pane]:
        """The pane whose process has this pid, or None."""

    def send_line(self, pane: Pane, text: str) -> None:
        """Type the text (may be empty) and press Return."""

    def rename_window(self, pane: Pane, label: str) -> None:
        """Give the pane's window a new label."""


def get(name, **opts):
    """The launcher of a front-end. Options: terminal(out=stream), rex(session=label or id, run=callable)."""
    if name == "terminal":
        from .terminal import Terminal
        return Terminal(**opts)
    if name == "rex":
        from .rex import Rex
        return Rex(**opts)
    raise ValueError(f"unknown front-end {name!r}: use one of {', '.join(NAMES)}")
