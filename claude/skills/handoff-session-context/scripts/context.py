#!/usr/bin/env python3
"""The context size of a Claude Code session, and the hand-off trigger (skill handoff-session-context).

Standard library only. Read-only on transcripts; writes only small files in the cache folder.

    context.py size [--session <id>] [--transcript <path>] [--cwd <dir>] [--json]
    context.py hook                                   Stop hook: hook JSON on stdin
    context.py record                                 statusline: statusline JSON on stdin, writes the window size
    context.py mark-done --session <id> --file <handoff file>
    context.py handoff-path --cwd <dir> --title "<title>"
    context.py install-hook --settings <project>/.claude/settings.local.json   add the Stop hook once (backup first)

Context now = input + cache write + cache read tokens of the newest main-part reply in the transcript.
Levels: ok < HANDOFF_AT_PCT (40) <= handoff < HANDOFF_MAX_PCT (50) <= over, as a share of the model's window.
Env: HANDOFF_WINDOW_TOKENS, HANDOFF_AT_PCT, HANDOFF_MAX_PCT, HANDOFF_CACHE_DIR, HANDOFF_PROJECTS_DIR.
"""
import argparse
import datetime
import json
import os
import re
import sys
from pathlib import Path

HOME_CLAUDE = Path.home() / ".claude"
TAIL_BYTES = 2_000_000
STEP_PCT = 5
SKILL = "handoff-session-context"


def cache_dir(env=os.environ):
    return Path(env.get("HANDOFF_CACHE_DIR") or HOME_CLAUDE / "context-window")


def projects_dir(env=os.environ):
    return Path(env.get("HANDOFF_PROJECTS_DIR") or HOME_CLAUDE / "projects")


def project_slug(cwd):
    """The transcript folder name Claude Code uses for a project folder."""
    return re.sub(r"[^A-Za-z0-9-]", "-", str(cwd))


def _safe_id(session):
    return bool(session) and re.fullmatch(r"[A-Za-z0-9_-]+", str(session)) is not None


def find_transcript(session, cwd=None, projects=None):
    """<projects>/<slug of cwd>/<session>.jsonl; else the first <projects>/*/<session>.jsonl. None if not found."""
    if not _safe_id(session):
        return None
    projects = Path(projects or projects_dir())
    if cwd:
        p = projects / project_slug(cwd) / f"{session}.jsonl"
        if p.is_file():
            return p
    for p in sorted(projects.glob(f"*/{session}.jsonl")):
        if p.is_file():
            return p
    return None


def _scan(lines):
    """(tokens, model) of the last usable usage line in lines, or None."""
    best = None
    for raw in lines:
        if '"usage"' not in raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        m = d.get("message") if isinstance(d, dict) else None
        u = m.get("usage") if isinstance(m, dict) else None
        if not isinstance(u, dict) or m.get("model") == "<synthetic>":
            continue
        best = (int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0)
                + int(u.get("cache_read_input_tokens") or 0), m.get("model"))
    return best


def read_context(transcript, tail_bytes=TAIL_BYTES):
    """(tokens, model) of the newest reply. Reads the tail first; the whole file only if the tail has no usage."""
    path = Path(transcript)
    size = path.stat().st_size
    with open(path, "rb") as fh:
        if size > tail_bytes:
            fh.seek(size - tail_bytes)
            tail = fh.read().decode("utf-8", "ignore").split("\n")[1:]  # the first line is cut
            found = _scan(tail)
            if found:
                return found
            fh.seek(0)
        found = _scan(fh.read().decode("utf-8", "ignore").split("\n"))
    return found or (0, None)


def window_for(session, model, env, cache):
    """(window tokens, source): env HANDOFF_WINDOW_TOKENS > statusline cache > CLAUDE_CODE_MAX_CONTEXT_TOKENS > table."""
    try:
        if env.get("HANDOFF_WINDOW_TOKENS"):
            return int(env["HANDOFF_WINDOW_TOKENS"]), "env"
    except ValueError:
        pass
    if _safe_id(session):
        try:
            w = int(json.loads((Path(cache) / f"{session}.json").read_text())["window"])
            if w > 0:
                return w, "cache"
        except (OSError, ValueError, KeyError, TypeError):
            pass
    try:
        if env.get("CLAUDE_CODE_MAX_CONTEXT_TOKENS"):
            return int(env["CLAUDE_CODE_MAX_CONTEXT_TOKENS"]), "maxctx"
    except ValueError:
        pass
    m = (model or "").lower()
    return (1_000_000 if any(k in m for k in ("opus", "fable", "sonnet")) else 200_000), "table"


def _limits(env):
    try:
        return float(env.get("HANDOFF_AT_PCT") or 40), float(env.get("HANDOFF_MAX_PCT") or 50)
    except ValueError:
        return 40.0, 50.0


def level(tokens, window, env):
    """(level, pct): ok, handoff or over."""
    at, top = _limits(env)
    pct = tokens * 100.0 / window if window else 0.0
    return ("over" if pct >= top else "handoff" if pct >= at else "ok"), pct


def measure(session=None, transcript=None, cwd=None, env=os.environ):
    if transcript is None:
        transcript = find_transcript(session, cwd, projects_dir(env))
    if transcript is None or not Path(transcript).is_file():
        return None
    tokens, model = read_context(transcript)
    session = session or Path(transcript).stem
    window, source = window_for(session, model, env, cache_dir(env))
    lvl, pct = level(tokens, window, env)
    return {"session": session, "transcript": str(transcript), "tokens": tokens, "window": window,
            "pct": round(pct, 1), "level": lvl, "model": model, "source": source}


def hook(stdin_text, env, cache):
    """Stop hook. Returns the JSON text to print, or "" (no block). Never raises."""
    try:
        data = json.loads(stdin_text)
        if not isinstance(data, dict) or data.get("stop_hook_active"):
            return ""
        session, transcript = data.get("session_id"), data.get("transcript_path")
        if not _safe_id(session) or not transcript or not Path(transcript).is_file():
            return ""
        cache = Path(cache)
        if (cache / f"{session}.handoff").exists():
            return ""
        tokens, model = read_context(transcript)
        window, _ = window_for(session, model, env, cache)
        lvl, pct = level(tokens, window, env)
        if lvl == "ok":
            return ""
        text = (f"Context {tokens:,} of {window:,} tokens ({pct:.1f} %). Run the skill {SKILL} now: "
                f"finish the current step, write the hand-off file, start the successor.")
        if lvl == "over":
            return json.dumps({"decision": "block", "reason": f"LAST LIMIT {_limits(env)[1]:g} %. " + text})
        at = _limits(env)[0]
        step = int(at + STEP_PCT * ((pct - at) // STEP_PCT))
        warned = cache / f"{session}.warned"
        try:
            if int(warned.read_text().strip()) >= step:
                return ""
        except (OSError, ValueError):
            pass
        cache.mkdir(parents=True, exist_ok=True)
        warned.write_text(f"{step}\n")
        return json.dumps({"decision": "block", "reason": text})
    except Exception:  # a broken hook must never stop a session
        return ""


def record(stdin_text, cache):
    """Statusline: write <cache>/<session_id>.json with the window size. Never raises, never prints."""
    try:
        d = json.loads(stdin_text)
        session = d.get("session_id")
        window = int((d.get("context_window") or {}).get("context_window_size") or 0)
        if not _safe_id(session) or window <= 0:
            return
        model = (d.get("model") or {}).get("id") if isinstance(d.get("model"), dict) else d.get("model")
        cache = Path(cache)
        cache.mkdir(parents=True, exist_ok=True)
        tmp = cache / f".{session}.json.tmp"
        tmp.write_text(json.dumps({"window": window, "model": model,
                                   "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}))
        tmp.replace(cache / f"{session}.json")
    except Exception:
        return


def mark_done(session, file, cache):
    if not _safe_id(session):
        raise ValueError(f"bad session id: {session!r}")
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    (cache / f"{session}.handoff").write_text(json.dumps({
        "file": str(file), "time": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")}) + "\n")


def _git_root(start):
    p = Path(start).resolve()
    for d in (p, *p.parents):
        if (d / ".git").exists():
            return d
    return None


def handoff_path(cwd, title, today=None):
    """<git root>/docs/local/<slug>-handoff-<date>.md, else <cwd>/<slug>-handoff-<date>.md; -2, -3 … if it exists."""
    today = today or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
    slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-") or "session"
    root = _git_root(cwd)
    folder = root / "docs" / "local" if root and (root / "docs" / "local").is_dir() else Path(cwd)
    p, n = folder / f"{slug}-handoff-{today}.md", 2
    while p.exists():
        p, n = folder / f"{slug}-handoff-{today}-{n}.md", n + 1
    return p


# the skill is linked per work project (.claude/skills/), so the hook finds it through the project dir
HOOK_COMMAND = 'python3 "$CLAUDE_PROJECT_DIR/.claude/skills/handoff-session-context/scripts/context.py" hook'


def install_hook(settings, today=None, command=HOOK_COMMAND):
    """Add the Stop hook to a settings.json once. Returns "added" or "present". Backs up the old file.
    A file that is not valid JSON is left alone (ValueError)."""
    settings = Path(settings)
    text = settings.read_text() if settings.exists() else ""
    data = json.loads(text) if text.strip() else {}
    if not isinstance(data, dict):
        raise ValueError(f"{settings}: not a JSON object")
    stop = data.setdefault("hooks", {}).setdefault("Stop", [])
    if any(h.get("command") == command for g in stop for h in g.get("hooks", [])):
        return "present"
    if text:
        today = today or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
        settings.with_name(f"{settings.name}.bak-{today}").write_text(text)
    stop.append({"matcher": "*", "hooks": [{"type": "command", "command": command, "timeout": 10}]})
    settings.parent.mkdir(parents=True, exist_ok=True)
    tmp = settings.with_name(f".{settings.name}.tmp")
    tmp.write_text(json.dumps(data, indent=2) + "\n")
    tmp.replace(settings)
    return "added"


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("size")
    s.add_argument("--session")
    s.add_argument("--transcript")
    s.add_argument("--cwd", default=os.getcwd())
    s.add_argument("--json", action="store_true")
    sub.add_parser("hook")
    sub.add_parser("record")
    m = sub.add_parser("mark-done")
    m.add_argument("--session", required=True)
    m.add_argument("--file", required=True)
    h = sub.add_parser("handoff-path")
    h.add_argument("--cwd", default=os.getcwd())
    h.add_argument("--title", required=True)
    i = sub.add_parser("install-hook")
    i.add_argument("--settings", required=True, help="for example <project>/.claude/settings.local.json")
    i.add_argument("--command", default=HOOK_COMMAND)
    a = ap.parse_args(argv)

    if a.cmd == "install-hook":
        print(f"{install_hook(a.settings, command=a.command)} Stop hook in {a.settings}")
        return 0
    if a.cmd == "hook":
        out = hook(sys.stdin.read(), os.environ, cache_dir())
        if out:
            print(out)
        return 0
    if a.cmd == "record":
        record(sys.stdin.read(), cache_dir())
        return 0
    if a.cmd == "mark-done":
        mark_done(a.session, a.file, cache_dir())
        print(f"marked {a.session}: hook silent from now on")
        return 0
    if a.cmd == "handoff-path":
        print(handoff_path(a.cwd, a.title))
        return 0
    if not (a.session or a.transcript):
        ap.error("size needs --session or --transcript")
    r = measure(a.session, a.transcript, a.cwd)
    if r is None:
        print(f"context.py: no transcript for session {a.session or a.transcript}", file=sys.stderr)
        return 1
    if a.json:
        print(json.dumps(r))
    else:
        print(f"tokens={r['tokens']} window={r['window']} pct={r['pct']} level={r['level']} "
              f"model={r['model']} source={r['source']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
