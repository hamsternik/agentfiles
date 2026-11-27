#!/usr/bin/env python3
"""watchdog.py — the session logic of a project watchdog (skill watchdog; was in handoff-session-context, CLI v2).

Reads the transcripts (~/.claude/projects/<slug>/), the live sessions (~/.claude/sessions/<pid>.json) and the context
size (context.py). It decides; it knows no front-end. `--frontend rex` hands the decision to a launcher
(launchers/), which starts, types and renames; the default front-end, terminal, only prints.
Run `watchdog.py help` for the subcommands. Standard library only; writes only the READY marker files.

Names: fixed title T; a session's name is `T #<first 8 hex of its id>` (old sessions: plain T).
Env: HANDOFF_PROJECTS_DIR, HANDOFF_SESSIONS_DIR, HANDOFF_CACHE_DIR (tests), plus the context.py variables.
"""
import argparse
import datetime
import json
import os
import re
import shlex
import shutil
import sys
import time
import uuid
from pathlib import Path

_HERE = Path(__file__).resolve().parent  # the real folder in the clone (the skill link resolves to it)
sys.path.insert(0, str(_HERE))
sys.path.insert(1, str(_HERE.parent.parent / "handoff-session-context" / "scripts"))  # context.py stays there
import context  # noqa: E402
import project  # noqa: E402
import dqueue  # noqa: E402

LIVE_SECONDS = 120
SKILL_SCRIPTS = Path(os.path.abspath(__file__)).parent  # keeps the project link path when called through it

HELP = """watchdog.py — session logic of a project watchdog; the one entry point of the watchdog CLI

  status   [--title T] [--wait-name NAME --timeout S] [--check-files F ...]
           the sessions of T (or of every watchdog title): id, pid, name, status, last activity, context
  restore  --title T [--effort E] [FRONT-END]
           the latest session of T and its `claude --resume` line; refused while it still runs
  start    --model M [--machine NAME] [--title T] [--first-prompt TEXT | --prompt-file F] [--effort E]
           [--owner-said-fable] [FRONT-END]
           a new watchdog: T = "<project> (watchdog)", or "(watchdog-<machine>)" when the project part lists 2+
           machines; the session name is "T #<short id>"; first prompt: run the project part; refused while T runs
  handoff  --title T --handoff-file F [--session ID] [--prompt-file F] [--effort E] [--owner-said-fable] [FRONT-END]
           the successor of the live session of T (same model) and the old session's pid
  ready    --session ID
           mark a successor ready (only then may the old session be retired)
  retire   --session ID [--caller ID] [--verify] [FRONT-END] [--yes]
           check that the old session may be retired; print what to type; --verify: is it retired?
           with --frontend rex: a dry run; --yes types /rename and /exit, then renames the window archived-<label>
  init     [--local]
           the project part and the decision queue from the templates (never overwrites); --local: git-exclude both
  public   public, private or unknown (gh repo view)
  queue next-id | add --item TEXT --default TEXT [--scope S] [--owner O] | list [--all] [--json]
        | decide D<nn> ANSWER | default D<nn> | close
           the decision queue (path: "Queue file:" in the project part, else .claude/docs/decisions/queue.md).
           add: a new open row + one Inbox item (af inbox), and the 2 h wake-up line; default: only an open row
           2 h old or more whose default does not start with "none"; close: rows done > 7 days go to "Closed"
  whatsup  one screen: the watchdog sessions of the project, the open D-rows with age, the git state (commits not
           pushed, changed files), the Inbox outbox; the skill adds the Inbox items (ArtifactData)
  help     this text

FRONT-END: --frontend terminal|rex|desktop [--rex S] [--dry-run].
  --dry-run (or --json) only prints, on every front-end. terminal (the default) runs the claude line in this
  terminal (restore, start, handoff). It refuses inside a Claude Code session ($CLAUDECODE): use rex or desktop there. retire only prints.
  desktop prints the start_session arguments (title, cwd, model, prompt) as JSON; it cannot restore or type.
  rex starts the window (restore, new, handoff) or types into the pane (retire) through Rex, from a Rex pane or a
  plain terminal. The Rex session is the one labelled with the project folder name (made when missing); --rex S
  overrides it. The window label is always `<role> #<short id>`, the role from the title: no --label option.
Common options: --project-dir DIR (default: $CLAUDE_PROJECT_DIR, else the project above the cwd), --json.
Exit codes: 0 ok, 1 no session, 2 refused, 3 duplicates, 4 Fable without the owner's word, 5 timeout, 6 not yet,
  7 rename not seen, 8 the old process did not exit, 9 no pane has the pid, 64 usage; a failed rex call: its code.
Env: WATCHDOG_WAIT (s, 60: name wait), WATCHDOG_VERIFY (tries, 10: rename check), WATCHDOG_EXIT_WAIT (s, 30).
"""

SUFFIX = re.compile(r" #[0-9a-f]{8}$")
STARTS = ("restore", "start", "handoff")  # the commands that start a session


# ---- names ---------------------------------------------------------------------------------------------------------

def matches(name, title):
    """True when a session name belongs to the fixed title: `T` or `T #<8 hex>`."""
    return isinstance(name, str) and (name == title or (name.startswith(title + " #") and bool(SUFFIX.search(name))
                                                        and len(name) == len(title) + 10))


def base_title(name):
    return SUFFIX.sub("", name or "")


def name_for(title, session):
    return f"{title} #{session[:8]}"


def label_for(label, session):
    return f"{label}-{session[:8]}"


ROLE = re.compile(r"\(([^()]*)\)")


def window_label_for(title, session):
    """The window label of a watchdog: `<role> #<short id>`; the role is the text in the last ( ... ) of the title
    (the project name is left out: the front-end's session already has it), else the whole base title."""
    base = base_title(title).strip()
    roles = [r.strip() for r in ROLE.findall(base) if r.strip()]
    return f"{roles[-1] if roles else base} #{session[:8]}"


def old_window_label(label, title, session):
    """True when a window label belongs to this session: the label of window_label_for, or the old style
    `<label>-<short id>` (before 2026-11-26). An `archived-...` label never matches."""
    label = label or ""
    if label.startswith("archived-"):
        return False
    return label == window_label_for(title, session) or label.endswith(f"-{session[:8]}")


# ---- places --------------------------------------------------------------------------------------------------------

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


def _alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def live_entries(folder=None):
    """The entries of ~/.claude/sessions/<pid>.json whose pid is alive."""
    out = []
    for f in sorted(Path(folder or sessions_dir()).glob("*.json")):
        try:
            d = json.loads(f.read_text())
            pid = int(d.get("pid"))
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        if _alive(pid):
            d["pid"] = pid
            out.append(d)
    return out


def live_pid(session, folder=None):
    for d in live_entries(folder):
        if d.get("sessionId") == session:
            return d["pid"]
    return None


def live_by_session(folder=None):
    return {d.get("sessionId"): d for d in live_entries(folder)}


# ---- transcripts ---------------------------------------------------------------------------------------------------

def summarize(path):
    """Last own title, last time, first uuid, last model and permission mode of one transcript."""
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


def _summaries(project_dir, needle, keep, projects=None):
    folder = Path(projects or context.projects_dir()) / context.project_slug(project_dir)
    out = []
    for p in sorted(folder.glob("*.jsonl")):
        with open(p, errors="ignore") as fh:
            if needle not in fh.read():  # cheap filter before the JSON pass
                continue
        s = summarize(p)
        if keep(s["title"]):
            out.append(s)
    return sorted(out, key=lambda s: s["last"], reverse=True)


def _add_size(s):
    tokens, model = context.read_context(s["transcript"])
    window, _ = context.window_for(s["session"], model or s["model"], os.environ, context.cache_dir())
    lvl, pct = context.level(tokens, window, os.environ)
    s.update(tokens=tokens, window=window, pct=round(pct, 1), level=lvl)
    return s


def find_latest(title, project_dir, projects=None):
    """(best summary with size fields, [older forks]) or (None, [])."""
    matches_ = _summaries(project_dir, json.dumps(title)[1:-1], lambda t: matches(t, title), projects)
    if not matches_:
        return None, []
    best = matches_[0]
    forks = [s for s in matches_[1:] if best["first_uuid"] and s["first_uuid"] == best["first_uuid"]]
    return _add_size(best), forks


def status_rows(title, project_dir, projects=None):
    """One row per session of the title (or of every title with "watchdog" that is not deprecated), newest first."""
    if title:
        rows = _summaries(project_dir, json.dumps(title)[1:-1], lambda t: matches(t, title), projects)
    else:
        rows = _summaries(project_dir, "watchdog", lambda t: bool(t) and "watchdog" in t
                          and not t.startswith(("deprecated", "moved to")), projects)
    live = live_by_session()
    for r in rows:
        e = live.get(r["session"], {})
        r.update(short=r["session"][:8], pid=e.get("pid"), status=e.get("status"), name=e.get("name") or r["title"],
                 base=base_title(r["title"]))
        _add_size(r)
    return rows


def wait_name(name, timeout=60, poll=1.0):
    """True when a live session has this name before the timeout."""
    end = time.monotonic() + timeout
    while True:
        if any(d.get("name") == name for d in live_entries()):
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(poll)


ID_RE = re.compile(r"(?:local_)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|#[0-9a-f]{8}\b")


def stale_ids(files, rows):
    """{file: [ids]}: session ids or `#short` suffixes in the files that are not a live session of the rows."""
    live_ids = {r["session"] for r in rows if r.get("pid")}
    live_short = {"#" + i[:8] for i in live_ids}
    out = {}
    for f in files:
        try:
            text = Path(f).read_text(errors="ignore")
        except OSError:
            continue
        found = []
        for m in ID_RE.findall(text):
            if m in live_ids or m in live_short or m in found:
                continue
            found.append(m)
        if found:
            out[str(f)] = found
    return out


# ---- command lines -------------------------------------------------------------------------------------------------

def resume_argv(s, effort=None):
    name = s.get("title")
    argv = ["claude", "--resume", s["session"], "-n", name]
    if s.get("model"):
        argv += ["--model", s["model"]]
    if effort:
        argv += ["--effort", effort]
    if s.get("permission_mode"):
        argv += ["--permission-mode", s["permission_mode"]]
    return argv + ["--remote-control", name, RESTORE_PROMPT]


def _parse(ts):
    return datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))


def recently_active(last, now=None):
    now = _parse(now) if now else datetime.datetime.now(datetime.timezone.utc)
    return bool(last) and (now - _parse(last)).total_seconds() < LIVE_SECONDS


RESTORE_PROMPT = ("You were restored with `watchdog.py restore` after an exit or a crash. Your scheduled tasks are "
                  "gone: set your wake-ups, crons and background processes again, then continue your work.")


def _tail(session):
    return (f" Run `python3 {SKILL_SCRIPTS / 'watchdog.py'} ready --session {session}` first; "
            f"then set your wake-ups and crons again.")


def new_plan(title, model, first_prompt="", effort=None, session=None):
    session = session or str(uuid.uuid4())
    name = name_for(title, session)
    argv = ["claude", "--session-id", session, "--model", model, "-n", name, "--remote-control", name]
    if effort:
        argv += ["--effort", effort]
    prompt = (first_prompt.strip() + _tail(session)).strip()
    return {"session": session, "short": session[:8], "name": name, "argv": argv + [prompt],
            "window_label": window_label_for(title, session)}


def _fable_refused(model, said):
    return "fable" in (model or "").lower() and not said


def live_of_title(title):
    return [d for d in live_entries() if matches(d.get("name"), title)]


# ---- subcommands ---------------------------------------------------------------------------------------------------

def _out(a, data, text):
    a.decision = data
    if getattr(a, "frontend", "terminal") != "terminal" and not (a.json or getattr(a, "dry_run", False)):
        return  # the launcher steps print their own lines
    print(json.dumps(data) if a.json else text)


def _err(msg, code):
    print(f"watchdog.py: {msg}", file=sys.stderr)
    return code


def cmd_status(a):
    if a.wait_name:  # a new session may have no transcript yet: the live entry is the answer
        if not wait_name(a.wait_name, a.timeout):
            return _err(f"no live session named {a.wait_name!r} after {a.timeout:g} s", 5)
        e = next(d for d in live_entries() if d.get("name") == a.wait_name)
        _out(a, e, f"{e.get('name')}  {e.get('sessionId')}  pid {e['pid']}")
        return 0
    rows = status_rows(a.title, a.project_dir)
    if not rows:
        return _err(f"no session of {a.title or 'any watchdog title'!r} in {a.project_dir}: run it from the project "
                    f"folder or give --project-dir <project folder>", 1)
    stale = stale_ids(a.check_files, rows) if a.check_files else {}
    groups = {}
    for r in rows:
        if r["pid"]:
            groups.setdefault(r["base"], []).append(r["session"])
    dups = {t: ids for t, ids in groups.items() if len(ids) > 1}
    lines = []
    for r in rows:
        live = f"pid {r['pid']} {r['status'] or ''}".strip() if r["pid"] else "not running"
        lines.append(f"{r['name']}  {r['session']}  {live}  last {r['last']}  context {r['tokens']:,} "
                     f"({r['pct']} %, {r['level']})  {r['model']}")
    for t, ids in dups.items():
        lines.append(f"WARNING: {len(ids)} live sessions of {t!r}: {', '.join(ids)}")
    for f, ids in stale.items():
        lines.append(f"stale in {f}: {', '.join(ids)}")
    _out(a, {"rows": rows, "duplicates": dups, "stale": stale}, "\n".join(lines))
    return 3 if dups else 0


def cmd_restore(a):
    best, forks = find_latest(a.title, a.project_dir)
    if best is None:
        return _err(f"no session with the title {a.title!r} in {a.project_dir}: run it from the project folder or "
                    f"give --project-dir <project folder>", 1)
    pid = live_pid(best["session"])
    if pid:
        return _err(f"session {best['session']} is still running (pid {pid}): exit it first", 2)
    if recently_active(best["last"]):
        return _err(f"session {best['session']} was active less than {LIVE_SECONDS} s ago: check that it stopped", 2)
    argv = resume_argv(best, a.effort)
    warn = (f"WARNING: context {best['pct']} % ({best['level']}): do not resume; hand off with the skill "
            f"handoff-session-context from a new session") if best["level"] != "ok" else ""
    text = [f"session {best['session']}  last {best['last']}  context {best['tokens']:,} ({best['pct']} %, "
            f"{best['level']})  model {best['model']}  mode {best['permission_mode']}"]
    if forks:
        text.append("older forks: " + ", ".join(f["session"] for f in forks))
    if warn:
        text.append(warn)
        if getattr(a, "frontend", "terminal") != "terminal":
            print(warn, file=sys.stderr)
    text.append(" ".join(shlex.quote(x) for x in argv))
    _out(a, {**best, "older_forks": [f["session"] for f in forks], "argv": argv, "warning": warn,
             "project_dir": a.project_dir, "window_label": window_label_for(best["title"], best["session"])},
         "\n".join(text))
    return 0


def _first_prompt(a):
    if getattr(a, "prompt_file", None):
        return f"Read {a.prompt_file} first."
    return getattr(a, "first_prompt", "") or ""


def start_title(a):
    """(title, error): --title, else "<project> (watchdog)", or "<project> (watchdog-<machine>)" when the project part
    lists 2 or more machines (then --machine must name one of them)."""
    if a.title:
        return a.title, None
    name = Path(a.project_dir).name
    ms = project.machines(a.project_dir)
    if len(ms) < 2:
        return f"{name} (watchdog)", None
    if a.machine not in ms:
        return None, (f"the project part lists {len(ms)} machines ({', '.join(ms)}): give --machine <one of them>"
                      if not a.machine else f"--machine {a.machine}: not in the project part ({', '.join(ms)})")
    return f"{name} (watchdog-{a.machine})", None


def cmd_start(a):
    a.title, err = start_title(a)
    if err:
        return _err(err, 64)
    if not (a.prompt_file or a.first_prompt):
        part = project.part_path(a.project_dir)
        if part.exists():
            a.first_prompt = f"Run {part.relative_to(a.project_dir)}."
    live = live_of_title(a.title)
    if live:
        return _err(f"a session of {a.title!r} still runs: {live[0].get('name')} (pid {live[0]['pid']})", 2)
    if _fable_refused(a.model, a.owner_said_fable):
        return _err("Fable only on the owner's word: add --owner-said-fable when he said so", 4)
    plan = new_plan(a.title, a.model, _first_prompt(a), a.effort)
    plan["project_dir"] = a.project_dir
    _out(a, plan, " ".join(shlex.quote(x) for x in plan["argv"]))
    return 0


def cmd_handoff(a):
    live = live_of_title(a.title)
    if a.session:  # the session that hands off (the skill passes its own id)
        live = [d for d in live if d.get("sessionId") == a.session]
    if not live:
        return _err(f"no live session of {a.title!r}" + (f" with the id {a.session}" if a.session else "") +
                    " to hand off", 1)
    if len(live) > 1:
        return _err(f"{len(live)} live sessions of {a.title!r}: give --session <the id that hands off>", 3)
    old = live[0]
    transcript = context.find_transcript(old.get("sessionId"), a.project_dir)
    model = summarize(Path(transcript))["model"] if transcript else None
    if not model:
        return _err(f"no model found in the transcript of {old.get('sessionId')}", 1)
    if _fable_refused(model, a.owner_said_fable):
        return _err("the old session runs on Fable: Fable only on the owner's word (--owner-said-fable)", 4)
    session = str(uuid.uuid4())
    prompt = (f"Read {a.handoff_file} first" + (f", then {a.prompt_file}" if a.prompt_file else "") +
              f". You continue the work of session {old.get('sessionId')} ({old.get('name')}).")
    plan = new_plan(a.title, model, prompt, a.effort, session)
    plan["argv"][-1] += (f" Then retire the old session: python3 {SKILL_SCRIPTS / 'watchdog.py'} retire --session "
                         f"{old.get('sessionId')} --caller {session} --frontend {a.frontend} (dry run first, then "
                         f"add --yes).")
    data = {"old": {"session": old.get("sessionId"), "pid": old["pid"], "name": old.get("name")}, "new": plan,
            "project_dir": a.project_dir}
    _out(a, data, f"old {old.get('name')} (pid {old['pid']})\n" + " ".join(shlex.quote(x) for x in plan["argv"]))
    return 0


def cmd_ready(a):
    session = a.session or os.environ.get("CLAUDE_SESSION_ID")
    if not session or not re.fullmatch(r"[A-Za-z0-9_-]+", session):
        return _err("ready needs --session <your session id>", 2)
    cache = context.cache_dir()
    cache.mkdir(parents=True, exist_ok=True)
    (cache / f"{session}.ready").write_text(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"))
    _out(a, {"session": session, "ready": True}, f"ready {session}")
    return 0


def is_retired(session):
    """True when the session no longer runs, or runs with a `deprecated ...` name."""
    target = {d.get("sessionId"): d for d in live_entries()}.get(session)
    return target is None or str(target.get("name") or "").startswith("deprecated")


def cmd_retire(a):
    entries = {d.get("sessionId"): d for d in live_entries()}
    target = entries.get(a.session)
    if a.verify:
        if is_retired(a.session):
            _out(a, {"session": a.session, "retired": True}, f"retired {a.session}")
            return 0
        return _err(f"session {a.session} still runs as {target.get('name')!r}", 6)
    if target is None:
        return _err(f"session {a.session} is not running", 2)
    name = target.get("name") or ""
    title = base_title(name)
    if not title or name.startswith(("deprecated", "moved to")) or "watchdog" not in title or not matches(name, title):
        return _err(f"session {a.session} has the name {name!r}: not a watchdog title", 2)
    if a.caller and a.caller == a.session:
        return _err("the caller cannot retire itself", 2)
    succ = [d for sid, d in entries.items() if sid != a.session and matches(d.get("name"), title)]
    if not succ:
        return _err(f"no live successor of {title!r}: start it first", 2)
    ready = [d for d in succ if (context.cache_dir() / f"{d.get('sessionId')}.ready").exists()]
    if not ready:
        return _err(f"the successor {succ[0].get('name')!r} is not ready: it must run `watchdog.py ready` first", 2)
    new_name = f"deprecated {name}"
    data = {"session": a.session, "pid": target["pid"], "name": name, "new_name": new_name,
            "successor": ready[0].get("sessionId"), "type": [f"/rename {new_name}", "/exit"]}
    _out(a, data, f"retire {name} (pid {target['pid']}): type `/rename {new_name}`, Enter, then `/exit`, Enter")
    return 0


def _git_project(a):
    """The git root of --project-dir; else of the cwd; else of $CLAUDE_PROJECT_DIR (init, public, queue, whatsup,
    start). The cwd comes before $CLAUDE_PROJECT_DIR: a session may run the CLI for another repo."""
    if a.project_dir:
        return project.git_root(a.project_dir)
    try:
        return project.git_root(os.getcwd())
    except project.ProjectError:
        if os.environ.get("CLAUDE_PROJECT_DIR"):
            return project.git_root(os.environ["CLAUDE_PROJECT_DIR"])
        raise


def cmd_init(a):
    for line in project.init(_git_project(a), local=a.local):
        print(line)
    return 0


def cmd_public(a):
    print(project.public(_git_project(a)))
    return 0


def _now():
    """Now in UTC; WATCHDOG_NOW (ISO) sets it for tests."""
    if os.environ.get("WATCHDOG_NOW"):
        return _parse(os.environ["WATCHDOG_NOW"])
    return datetime.datetime.now(datetime.timezone.utc)


def _af():
    """The af CLI for the Inbox: $WATCHDOG_AF, else ~/.claude/inbox/af (install_inbox), else af on PATH; or None."""
    if "WATCHDOG_AF" in os.environ:  # set (tests): only this one, never a fallback to the real Inbox
        c = os.environ["WATCHDOG_AF"]
        return c if c and os.access(c, os.X_OK) else None
    for c in (str(Path.home() / ".claude/inbox/af"), shutil.which("af")):
        if c and os.access(c, os.X_OK):
            return c
    return None


def _inbox(args):
    """Run `af inbox <args>`; the stdout, or None with a warning when there is no Inbox."""
    import subprocess
    af = _af()
    if not af:
        print("watchdog.py: no Inbox on this machine (no af): the queue row is enough", file=sys.stderr)
        return None
    r = subprocess.run([af, "inbox", *args], text=True, capture_output=True)
    if r.returncode:
        print(f"watchdog.py: af inbox {args[0]} failed ({r.returncode}): {r.stderr.strip()}", file=sys.stderr)
        return None
    return r.stdout.strip()


INBOX_ID = re.compile(r"· Inbox (I-\d{8}-[0-9a-f]{4})$")


def _answer(row, text):
    m = INBOX_ID.search(row.get("item", ""))
    if m:
        _inbox(["answer", m.group(1), text])


def _row_line(r, now):
    return (f"{r['id']}  {r.get('status', '')}  {dqueue.age_text(r, now)}  {r.get('item', '')}  "
            f"(default: {r.get('default', '')})")


def _git_out(proj, *args):
    import subprocess
    r = subprocess.run(["git", "-C", str(proj), *args], text=True, capture_output=True)
    return r.stdout.strip() if r.returncode == 0 else None


def _plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def cmd_whatsup(a):
    """One screen: the watchdog sessions, the open D-rows, the git state, the Inbox outbox."""
    proj = _git_project(a)
    now = _now()
    print(f"== {proj.name}  ({now:%Y-%m-%d %H:%M} UTC)")
    rows = status_rows(None, str(proj))
    print("Sessions:" if rows else "Sessions: no watchdog session in this project")
    for r in rows:
        live = f"pid {r['pid']} {r['status'] or ''}".strip() if r["pid"] else "not running"
        print(f"  {r['name']}  {live}  last {r['last']}  context {r['pct']} % ({r['level']})")
    path = project.queue_path(proj)
    if not path.is_file():
        print(f"Queue: no queue ({path.relative_to(proj)})")
    else:
        try:
            open_rows = [r for r in dqueue.Queue(path.read_text(errors="ignore")).rows() if r.get("status") == "open"]
        except dqueue.QueueError as e:
            open_rows = None
            print(f"Queue: {e}")
        if open_rows is not None:
            print(f"Queue ({path.relative_to(proj)}): {_plural(len(open_rows), 'open row')}")
            for r in open_rows:
                print("  " + _row_line(r, now))
    branch = _git_out(proj, "rev-parse", "--abbrev-ref", "HEAD") or "?"
    ahead = _git_out(proj, "rev-list", "--count", "@{u}..HEAD")
    dirty = [x for x in (_git_out(proj, "status", "--porcelain") or "").splitlines() if x]
    push = "no upstream" if ahead is None else f"{_plural(int(ahead), 'commit')} not pushed"
    print(f"Git: {branch}, {push}, {_plural(len(dirty), 'file')} changed")
    st = _inbox(["status"]) if _af() else None
    if st is None:
        print("Inbox: not set up on this machine")
    else:
        n = dict(x.split("=", 1) for x in st.splitlines() if "=" in x).get("outbox", "0")
        print(f"Inbox: {n} changes wait in the outbox" + (" (flush: skill triage-inbox)" if n != "0" else ""))
    print("Inbox items of the project: the skill reads them (triage-inbox, ArtifactData)")
    return 0


def _write(path, q):
    path.write_text(q.text())


def cmd_queue(a):
    proj = _git_project(a)
    path = project.queue_path(proj)
    if not path.is_file():
        return _err(f"no queue file {path}: run `watchdog.py init`, or name it in the project part (Queue file:)", 1)
    text = path.read_text(errors="ignore")
    if a.qcmd == "next-id":
        print(project.next_id(text))
        return 0
    now = _now()
    try:
        q = dqueue.Queue(text)
        if a.qcmd == "add":
            rid = project.next_id(path.read_text(errors="ignore"))  # read again just before the write
            item = a.item
            iid = _inbox(["add", "--type", "decision", "--title", a.item, "--ref", rid, "--project", proj.name,
                          "--default", a.default])
            if iid:
                item = f"{a.item} · Inbox {iid}"
            q.add({"id": rid, "opened": now.strftime("%Y-%m-%d %H:%M UTC"), "item": item, "scope": a.scope or "",
                   "default": a.default, "owner": a.owner, "status": "open"})
            _write(path, q)
            wake = now + datetime.timedelta(hours=dqueue.DEFAULT_AFTER_HOURS)
            local = wake.astimezone()
            prompt = f"watchdog queue default {rid}"
            print(f"added {rid}" + (f" (Inbox {iid})" if iid else ""))
            print(f'wake-up: ScheduleWakeup delaySeconds={dqueue.DEFAULT_AFTER_HOURS * 3600} prompt="{prompt}"')
            print(f'fallback: CronCreate cron="{local.minute} {local.hour} {local.day} {local.month} *" '
                  f'recurring=false prompt="{prompt}"')
            return 0
        if a.qcmd == "list":
            rows = [r for r in q.rows() if a.all or r.get("status") == "open"]
            if a.json:
                print(json.dumps([{k: v for k, v in r.items() if not k.startswith("_")} for r in rows]))
                return 0
            for r in rows:
                print(_row_line(r, now))
            return 0
        if a.qcmd == "decide":
            row = q.row(a.id)
            if row.get("status") != "open":
                return _err(f"{a.id} is not open ({row.get('status')})", 2)
            q.set(a.id, "status", f"decided {now:%Y-%m-%d}: {a.answer}")
            _write(path, q)
            _answer(row, a.answer)
            print(f"decided {a.id}")
            return 0
        if a.qcmd == "default":
            row = q.row(a.id)
            why = dqueue.default_refusal(row, now)
            if why:
                return _err(why, 2)
            status = f"default taken {now:%Y-%m-%d %H:%M} UTC: {row['default']}"
            q.set(a.id, "status", status)
            _write(path, q)
            _answer(row, status)
            print(f"{a.id}: {status}")
            return 0
        if a.qcmd == "close":
            moved = q.close(now)
            if moved:
                _write(path, q)
            print("closed " + (", ".join(moved) if moved else "nothing"))
            return 0
    except dqueue.QueueError as e:
        return _err(str(e), e.code)
    return _err(f"unknown queue command {a.qcmd!r}", 64)


class _Parser(argparse.ArgumentParser):
    def error(self, message):  # a usage error is exit 64 (2 is "refused")
        self.print_usage(sys.stderr)
        self.exit(64, f"{self.prog}: error: {message}\n")


def _frontend(p, retire=False):
    p.add_argument("--frontend", choices=("terminal", "rex", "desktop"), default="terminal")
    p.add_argument("--dry-run", action="store_true", help="print the decision and the claude line; act on no front-end")
    p.add_argument("--rex", help="the Rex session for the window (default: the one named after the project folder)")
    if retire:
        p.add_argument("--yes", action="store_true", help="with a front-end that types: act, not a dry run")


def _env_num(name, default):
    try:
        return float(os.environ.get(name, default))
    except ValueError:
        return float(default)


def _launch(a):
    """Run the decision of a.cmd (a.decision) through the launcher of a.frontend."""
    import launchers
    from launchers import steps
    from launchers.rex import RexError
    launcher = launchers.get(a.frontend, session=a.rex)
    d = a.decision
    wait = _env_num("WATCHDOG_WAIT", 60)
    try:
        if a.cmd == "start":
            return steps.start(launcher, d, d["name"], wait_name, wait)
        if a.cmd == "restore" and a.frontend == "terminal":
            return steps.start(launcher, d, d["title"], wait_name, wait)
        if a.cmd == "restore":  # first archive the ended window of the same session (Rex keeps it open)
            return steps.start(launcher, d, d["title"], wait_name, wait,
                               match=lambda label: old_window_label(label, d["title"], d["session"]))
        if a.cmd == "handoff":
            plan = {**d["new"], "project_dir": d["project_dir"]}
            return steps.start(launcher, plan, plan["name"], wait_name, wait)
        return steps.retire(launcher, d, a.yes, verified=lambda: is_retired(a.session), alive=_alive,
                            verify_tries=int(_env_num("WATCHDOG_VERIFY", 10)),
                            exit_wait=_env_num("WATCHDOG_EXIT_WAIT", 30))
    except RexError as e:
        return _err(str(e), e.code)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv or argv[0] in ("help", "-h", "--help"):
        print(HELP, end="")
        return 0
    if argv[0] == "new":
        return _err("`new` is now `start`: start --model M [--machine NAME] [--title T] ... (watchdog.py help)", 64)
    ap = _Parser(prog="watchdog.py", add_help=False)
    sub = ap.add_subparsers(dest="cmd", required=True)

    def add(name, **kw):
        p = sub.add_parser(name, **kw)
        p.add_argument("--project-dir")
        p.add_argument("--json", action="store_true")
        return p

    p = add("status")
    p.add_argument("--title")
    p.add_argument("--wait-name")
    p.add_argument("--timeout", type=float, default=60)
    p.add_argument("--check-files", nargs="*", default=[])
    p = add("restore")
    p.add_argument("--title", required=True)
    p.add_argument("--effort")
    _frontend(p)
    p = add("start")
    p.add_argument("--title", help="default: <project> (watchdog), or (watchdog-<machine>) for 2+ machines")
    p.add_argument("--machine", help="this machine, when the project part lists 2 or more machines")
    p.add_argument("--model", required=True)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--first-prompt")
    g.add_argument("--prompt-file")
    p.add_argument("--effort")
    p.add_argument("--owner-said-fable", action="store_true")
    _frontend(p)
    p = add("handoff")
    p.add_argument("--title", required=True)
    p.add_argument("--handoff-file", required=True)
    p.add_argument("--session", help="the session that hands off (needed when 2 sessions of T run)")
    p.add_argument("--prompt-file")
    p.add_argument("--effort")
    p.add_argument("--owner-said-fable", action="store_true")
    _frontend(p)
    p = add("ready")
    p.add_argument("--session")
    p = add("retire")
    p.add_argument("--session", required=True)
    p.add_argument("--caller")
    p.add_argument("--verify", action="store_true")
    _frontend(p, retire=True)
    p = add("init")
    p.add_argument("--local", action="store_true", help="hide the 2 files in the repo's git exclude file")
    add("public")
    add("whatsup")
    p = add("queue")
    qs = p.add_subparsers(dest="qcmd", required=True)
    qs.add_parser("next-id")
    q = qs.add_parser("add")
    q.add_argument("--item", required=True)
    q.add_argument("--default", required=True, help='the decision after 2 h; "none: <why>" = never a default')
    q.add_argument("--scope")
    q.add_argument("--owner", default="owner")
    q = qs.add_parser("list")
    q.add_argument("--all", action="store_true")
    q.add_argument("--json", action="store_true")
    q = qs.add_parser("decide")
    q.add_argument("id")
    q.add_argument("answer")
    q = qs.add_parser("default")
    q.add_argument("id")
    qs.add_parser("close")
    a = ap.parse_args(argv)
    if a.cmd in ("init", "public", "queue", "whatsup"):
        try:
            return {"init": cmd_init, "public": cmd_public, "queue": cmd_queue, "whatsup": cmd_whatsup}[a.cmd](a)
        except project.ProjectError as e:
            return _err(str(e), 1)
    if a.cmd == "start" and not a.project_dir:  # a new session: the git root of the cwd, never a parent folder
        try:
            a.project_dir = str(_git_project(a))
        except project.ProjectError:
            pass
    a.project_dir = a.project_dir or default_project_dir()
    frontend = getattr(a, "frontend", "terminal")
    if frontend == "rex" and not shutil.which("rex"):
        return _err("--frontend rex: no `rex` command on PATH (install Rex, or use --frontend terminal)", 64)
    if frontend == "desktop" and a.cmd == "restore":
        return _err("--frontend desktop cannot resume a session: restore with --frontend terminal or rex", 64)
    execs = frontend == "terminal" and a.cmd in STARTS and not (a.json or a.dry_run)
    code = {"status": cmd_status, "restore": cmd_restore, "start": cmd_start, "handoff": cmd_handoff,
            "ready": cmd_ready, "retire": cmd_retire}[a.cmd](a)
    if code != 0 or getattr(a, "verify", False) or a.cmd in ("status", "ready") or getattr(a, "dry_run", False):
        return code  # a refusal keeps its own exit code; --dry-run never acts, on any front-end
    if execs and os.environ.get("CLAUDECODE"):  # a refusal only: CLAUDECODE never chooses the front-end
        return _err("inside a Claude Code session the terminal front-end cannot run claude: use --frontend rex or "
                    "--frontend desktop (or --dry-run to print the line)", 64)
    if frontend == "terminal" and not execs:
        return code  # printed: --dry-run, --json, or retire (the terminal cannot type into another pane)
    return _launch(a)


if __name__ == "__main__":
    sys.exit(main())
