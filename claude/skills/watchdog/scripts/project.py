"""The project side of a watchdog: the git root, the project part, the queue path, the machines, init and public.

The project part is `.claude/docs/prompts/<project>-watchdog.md` (older projects: `docs/prompts/<project>-watchdog.md`).
It may name the queue file in a line ``Queue file: `<path>` `` (else `.claude/docs/decisions/queue.md`) and lists the
machines in its "## Machines" table. Standard library only; no CLI (watchdog.py is the one entry point).
"""
import datetime
import re
import shutil
import subprocess
from pathlib import Path

TEMPLATES = Path(__file__).resolve().parent.parent / "templates"
DEFAULT_QUEUE = ".claude/docs/decisions/queue.md"
QUEUE_LINE = re.compile(r"^Queue file: `([^`]+)`", re.M)
D_ID = re.compile(r"(?:^|[^A-Za-z0-9])D(\d+)")


class ProjectError(RuntimeError):
    pass


def _git(project_dir, *args):
    return subprocess.run(["git", "-C", str(project_dir), *args], text=True, capture_output=True)


def git_root(path):
    """The top folder of the git repo or worktree that holds path."""
    r = _git(path, "rev-parse", "--show-toplevel")
    if r.returncode:
        raise ProjectError(f"not a git repo: {path}")
    return Path(r.stdout.strip())


def name_of(project_dir):
    return Path(project_dir).name


def part_path(project_dir):
    d, name = Path(project_dir), name_of(project_dir)
    new = d / ".claude/docs/prompts" / f"{name}-watchdog.md"
    old = d / "docs/prompts" / f"{name}-watchdog.md"
    return old if not new.exists() and old.exists() else new


def _part_text(project_dir):
    p = part_path(project_dir)
    return p.read_text(errors="ignore") if p.exists() else ""


def queue_path(project_dir):
    m = QUEUE_LINE.search(_part_text(project_dir))
    return Path(project_dir) / (m.group(1) if m else DEFAULT_QUEUE)


def machines(project_dir):
    """The machine names in the "## Machines" table of the project part (placeholders like <master> left out)."""
    text = _part_text(project_dir)
    m = re.search(r"^## Machines\s*$(.*?)(?=^## |\Z)", text, re.M | re.S)
    out = []
    for line in (m.group(1) if m else "").splitlines():
        cells = [c.strip() for c in line.strip().strip("|").split("|")] if line.strip().startswith("|") else []
        if not cells or not cells[0] or cells[0].startswith("<") or set(cells[0]) <= set("-: "):
            continue
        if cells[0].lower() == "machine":
            continue
        out.append(cells[0])
    return out


def next_id(text):
    """The next D-id: the highest D number in any table row (id, ref or mention) + 1."""
    nums = [int(n) for line in text.splitlines() if line.startswith("|") for n in D_ID.findall(line)]
    return f"D{max(nums, default=0) + 1:02d}"


def _render(src, dst, name):
    if dst.exists():
        return f"kept     {dst}"
    text = src.read_text().replace("{{PROJECT}}", name).replace(
        "{{DATE}}", datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(text)
    return f"created  {dst}"


def exclude_file(project_dir):
    r = _git(project_dir, "rev-parse", "--path-format=absolute", "--git-path", "info/exclude")
    if r.returncode:
        raise ProjectError(f"not a git repo: {project_dir}")
    return Path(r.stdout.strip())


def exclude(project_dir, paths):
    """Add each /path to the repo's local exclude file once. Returns the added lines."""
    f = exclude_file(project_dir)
    text = f.read_text() if f.exists() else ""
    new = [p for p in paths if p not in text.splitlines()]
    if new:
        f.parent.mkdir(parents=True, exist_ok=True)
        with open(f, "a") as fh:
            fh.write(("\n" if text and not text.endswith("\n") else "") + "".join(p + "\n" for p in new))
    return new


def init(project_dir, local=False):
    """Write the project part and the queue from the templates (never overwrite). local: hide both from git."""
    d = Path(project_dir)
    name = name_of(d)
    part = d / ".claude/docs/prompts" / f"{name}-watchdog.md"
    queue = d / DEFAULT_QUEUE
    lines = [_render(TEMPLATES / "project-watchdog.md", part, name), _render(TEMPLATES / "queue.md", queue, name)]
    if local:
        added = exclude(d, ["/" + str(p.relative_to(d)) for p in (part, queue)])
        lines += [f"excluded {p}" for p in added]
    return lines


def public(project_dir):
    """public, private or unknown, from `gh repo view` (no gh, an error or another answer: unknown)."""
    if not shutil.which("gh"):
        return "unknown"
    r = subprocess.run(["gh", "repo", "view", "--json", "visibility", "-q", ".visibility"], cwd=str(project_dir),
                       text=True, capture_output=True)
    if r.returncode:
        return "unknown"
    vis = r.stdout.strip().lower()
    return {"public": "public", "private": "private", "internal": "private"}.get(vis, "unknown")
