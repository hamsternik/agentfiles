"""Front-end launchers of the watchdog CLI (docs/plans/PLAN-watchdog-launchers.md, v6).

watchdog.py decides; a launcher only starts, finds, types into and renames sessions of one front-end. A launcher has
`name`, `caps` (the operations that really act) and the operations of `Launcher`. When a capability is missing,
the caller prints the step for the owner (launchers/steps.py). terminal (the default) execs claude in this terminal;
desktop prints the start_session arguments; rex acts through Rex. Standard library only. No CLI: watchdog.py is the one entry point.
"""
from dataclasses import dataclass
from typing import Optional, Protocol

CAPS = frozenset({"start", "find_pane", "send", "rename", "find_ended", "capture"})
NAMES = ("terminal", "rex", "desktop")


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

    def find_ended(self, plan: dict, match) -> list:
        """The windows in the session that plan would start in, whose label match(label) accepts and whose
        processes have all ended (one Pane per window)."""

    def send_line(self, pane: Pane, text: str) -> None:
        """Type the text (may be empty) and press Return."""

    def rename_window(self, pane: Pane, label: str) -> None:
        """Give the pane's window a new label."""

    def capture(self, pane: Pane) -> str:
        """The text on the pane's screen (cap "capture")."""


def get(name, **opts):
    """The launcher of a front-end that acts. Options: rex(session=label or id, run=callable)."""
    if name == "rex":
        from .rex import Rex
        return Rex(**opts)
    if name == "terminal":
        from .terminal import Terminal
        return Terminal(**opts)
    if name == "desktop":
        from .desktop import Desktop
        return Desktop(**opts)
    raise ValueError(f"unknown front-end {name!r}: use one of {', '.join(NAMES)}")
