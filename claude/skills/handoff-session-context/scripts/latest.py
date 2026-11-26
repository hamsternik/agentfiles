#!/usr/bin/env python3
"""Find the latest live session of a fixed title and print the line that resumes it (skill handoff-session-context).

    latest.py --title "<fixed title>" [--project-dir <dir>] [--effort <level>] [--json]
    latest.py --title "<fixed title>" --rex <rex session> --label <window label> [--dry-run]

A transcript matches when its LAST own `custom-title` record equals the title (a rename to "deprecated …" ends the
match; a title quoted in a message never counts). The newest match by the time of its last record wins (not the file
mtime). Matches with the same first message uuid are forks of one line; the older ones are listed as older_forks.
Exit 1: no match. Exit 2: --rex refused: the session still runs (a live pid in ~/.claude/sessions/) or was
active in the last 2 minutes.
Standard library only; read-only except --rex (opens a Rex window).
"""
import argparse
import datetime
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import context  # noqa: E402

LIVE_SECONDS = 120


def summarize(path):
    """The facts of one transcript: last title, last time, first uuid, last model and permission mode."""
    s = {"session": path.stem, "transcript": str(path), "title": None, "last": "", "first_uuid": None,
         "model": None, "permission_mode": None}
    with open(path, errors="ignore") as fh:
        for raw in fh:
            try:
                d = json.loads(raw)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            t = d.get("type")
            if t == "custom-title" and d.get("sessionId") == path.stem:
                s["title"] = d.get("customTitle")
            elif t == "permission-mode" and d.get("permissionMode"):
                s["permission_mode"] = d["permissionMode"]
            ts = d.get("timestamp")
            if isinstance(ts, str) and ts > s["last"]:
                s["last"] = ts
            if s["first_uuid"] is None and d.get("uuid"):
                s["first_uuid"] = d["uuid"]
            m = d.get("message")
            if isinstance(m, dict) and m.get("model") and m["model"] != "<synthetic>":
                s["model"] = m["model"]
    return s


def find_latest(title, project_dir, projects=None):
    """(best summary with size fields, [older forks]) or (None, [])."""
    folder = Path(projects or context.projects_dir()) / context.project_slug(project_dir)
    needle = json.dumps(title)[1:-1]  # the title as it is written inside JSON
    matches = []
    for p in sorted(folder.glob("*.jsonl")):
        with open(p, errors="ignore") as fh:
            if needle not in fh.read():  # cheap filter before the JSON pass
                continue
        s = summarize(p)
        if s["title"] == title:
            matches.append(s)
    if not matches:
        return None, []
    matches.sort(key=lambda s: s["last"], reverse=True)
    best = matches[0]
    forks = [s for s in matches[1:] if best["first_uuid"] and s["first_uuid"] == best["first_uuid"]]
    tokens, model = context.read_context(best["transcript"])
    window, _ = context.window_for(best["session"], model or best["model"], os.environ, context.cache_dir())
    lvl, pct = context.level(tokens, window, os.environ)
    best.update(tokens=tokens, window=window, pct=round(pct, 1), level=lvl)
    return best, forks


def resume_line(s, title, effort=None):
    parts = ["claude", "--resume", s["session"], "-n", shlex.quote(title)]
    if s.get("model"):
        parts += ["--model", s["model"]]
    if effort:
        parts += ["--effort", effort]
    if s.get("permission_mode"):
        parts += ["--permission-mode", s["permission_mode"]]
    parts += ["--remote-control", shlex.quote(title)]
    return " ".join(parts)


def rex_command(rex_session, label, project_dir, line):
    return ["rex", "window", "new", "-s", rex_session, label, "-c", project_dir, "--keep-open", "--", "sh", "-c", line]


def default_project_dir(env=os.environ, cwd=None, projects=None):
    """$CLAUDE_PROJECT_DIR; else the nearest folder above the logical $PWD (keeps the skill link path), then above
    the real cwd, that has a transcripts folder; else the cwd."""
    if env.get("CLAUDE_PROJECT_DIR"):
        return env["CLAUDE_PROJECT_DIR"]
    cwd = cwd or os.getcwd()
    projects = Path(projects or context.projects_dir(env))
    for start in (env.get("PWD"), cwd):
        if not start:
            continue
        p = Path(start)
        for d in (d for d in (p, *p.parents) if d != d.parent):  # never the root folder
            if (projects / context.project_slug(d)).is_dir():
                return str(d)
    return cwd


def sessions_dir():
    return Path(os.environ.get("HANDOFF_SESSIONS_DIR") or Path.home() / ".claude" / "sessions")


def live_pid(session, folder=None):
    """The pid of a running Claude Code process of this session (from ~/.claude/sessions/<pid>.json), or None."""
    for f in sorted(Path(folder or sessions_dir()).glob("*.json")):
        try:
            d = json.loads(f.read_text())
            pid = int(d.get("pid"))
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        if d.get("sessionId") != session:
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except PermissionError:
            pass
        return pid
    return None


def _parse(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def recently_active(last, now=None):
    now = _parse(now) if now else datetime.datetime.now(datetime.timezone.utc)
    return bool(last) and (now - _parse(last)).total_seconds() < LIVE_SECONDS


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("--title", required=True)
    ap.add_argument("--project-dir", help="default: $CLAUDE_PROJECT_DIR, else the project above the cwd")
    ap.add_argument("--effort", help="added to the line (the transcript does not hold it)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--rex", metavar="REX_SESSION", help="open the resume line in a new window of this Rex session")
    ap.add_argument("--label", help="the Rex window label (with --rex)")
    ap.add_argument("--dry-run", action="store_true", help="with --rex: print the Rex command, run nothing")
    a = ap.parse_args(argv)
    a.project_dir = a.project_dir or default_project_dir()
    if a.rex and not a.label:
        ap.error("--rex needs --label")

    best, forks = find_latest(a.title, a.project_dir)
    if best is None:
        print(f"latest.py: no session with the title {a.title!r} in {a.project_dir}: run it from the project "
              f"folder or give --project-dir <project folder>", file=sys.stderr)
        return 1
    line = resume_line(best, a.title, a.effort)
    warn = (f"WARNING: context {best['pct']} % ({best['level']}): do not resume; hand off with the skill "
            f"handoff-session-context from a new session") if best["level"] != "ok" else ""
    if a.json:
        print(json.dumps({**best, "older_forks": [f["session"] for f in forks], "resume": line, "warning": warn}))
    else:
        print(f"session {best['session']}  last {best['last']}  context {best['tokens']:,} "
              f"({best['pct']} %, {best['level']})  model {best['model']}  mode {best['permission_mode']}")
        if forks:
            print("older forks: " + ", ".join(f["session"] for f in forks))
        if warn:
            print(warn)
        print(line)
    if a.rex:
        pid = live_pid(best["session"])
        if pid:
            print(f"latest.py: session {best['session']} is still running (pid {pid}): "
                  f"exit it first; nothing opened", file=sys.stderr)
            return 2
        if recently_active(best["last"]):
            print(f"latest.py: session {best['session']} was active less than {LIVE_SECONDS} s ago: "
                  f"stop it first; nothing opened", file=sys.stderr)
            return 2
        cmd = rex_command(a.rex, a.label, a.project_dir, line)
        if a.dry_run:
            print(" ".join(shlex.quote(c) for c in cmd))
        else:
            subprocess.run(cmd, check=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
