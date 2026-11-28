"""The guard of a watchdog: a PreToolUse hook, so a watchdog session does no file work inline (rules.md, rule 1).

In a session whose name has "(watchdog", Edit, Write and NotebookEdit pass only on the watchdog's own files: the
project memory, the project part, the decision queue, hand-off files and route prompt files. A sub-agent passes: it
does routed work. Bash and MCP file tools are not checked. Standard library only; no CLI (watchdog.py is the one entry
point).
"""
import datetime
import fnmatch
import json
import os
import subprocess
from pathlib import Path

import context
import project

MARK = "(watchdog"
PATH_KEYS = {"Edit": "file_path", "Write": "file_path", "NotebookEdit": "notebook_path"}
MATCHER = "|".join(PATH_KEYS)
# A missing script must not block: python3 exits 2 for a file it cannot open, and 2 refuses the tool call.
HOOK_COMMAND = 'f="$HOME/.claude/skills/watchdog/scripts/watchdog.py"; [ ! -f "$f" ] || python3 "$f" guard'
PROMPT_DIRS = (".claude/docs/prompts", "docs/prompts")  # where a project part lives

REFUSAL = """watchdog guard: {path} is not a file of the watchdog. A watchdog does no file work inline (rules.md, rule 1).
route it: sub-agent or `watchdog.py start --title "<title>" --model <m> --prompt-file <file> --frontend rex`
A watchdog writes only: the project memory, <project>-watchdog*.md, the queue, *handoff* files, *-prompt-*.md."""


def _roots(start):
    """(the git root of start, the root of the main repo): they differ in a worktree. No git: start itself."""
    try:
        root = project.git_root(start).resolve()
    except project.ProjectError:
        root = Path(start).resolve()
        return root, root
    r = subprocess.run(["git", "-C", str(root), "rev-parse", "--path-format=absolute", "--git-common-dir"], text=True,
                       capture_output=True)
    common = Path(r.stdout.strip()) if r.returncode == 0 else None
    return root, common.parent.resolve() if common and common.name == ".git" else root


def allowed(path, root, memory):
    """True when a resolved path is a file the watchdog may write."""
    if memory in path.parents:
        return True
    if root not in path.parents:
        return False
    if path == project.queue_path(root).resolve():  # every watchdog: rules.md names the one writer
        return True
    name = path.name
    if "handoff" in name.lower() or fnmatch.fnmatchcase(name, "*-prompt-*.md"):
        return True
    return (path.parent.relative_to(root).as_posix() in PROMPT_DIRS
            and name.startswith(f"{project.name_of(root)}-watchdog") and name.endswith(".md"))


def refusal(data, session_name, env=os.environ):
    """The reason to refuse the tool call of the hook input `data`, or None to pass it.
    session_name(data) gives the name of the session; it runs only for a tool that writes a file."""
    if not isinstance(data, dict) or data.get("tool_name") not in PATH_KEYS or data.get("agent_id"):
        return None
    tool_input = data.get("tool_input")
    target = tool_input.get(PATH_KEYS[data["tool_name"]]) if isinstance(tool_input, dict) else None
    if not target or MARK not in (session_name(data) or ""):
        return None
    cwd = data.get("cwd") or os.getcwd()
    root, main = _roots(env.get("CLAUDE_PROJECT_DIR") or cwd)
    path = Path(os.path.realpath(os.path.join(cwd, target)))  # follows links and "..": no way out of a folder
    memory = (context.projects_dir(env) / context.project_slug(main) / "memory").resolve()
    return None if allowed(path, root, memory) else REFUSAL.format(path=path)


def _backup(settings, text, today):
    """Write text beside settings as <name>.bak-<date>, -2, -3 …: an older backup stays."""
    today = today or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d")
    p, n = settings.with_name(f"{settings.name}.bak-{today}"), 2
    while p.exists():
        p, n = settings.with_name(f"{settings.name}.bak-{today}-{n}"), n + 1
    p.write_text(text, encoding="utf-8")


def install(settings, today=None):
    """Add the PreToolUse hook to a settings.json once. Returns "added" or "present". Backs up the old file.
    A file that is not a JSON object with the usual shape is left alone (ValueError)."""
    settings = Path(settings)
    text = settings.read_text(encoding="utf-8") if settings.exists() else ""
    data = json.loads(text) if text.strip() else {}
    hooks = data.setdefault("hooks", {}) if isinstance(data, dict) else None
    groups = hooks.setdefault("PreToolUse", []) if isinstance(hooks, dict) else None
    if not isinstance(groups, list):
        raise ValueError("no JSON object with a hooks.PreToolUse list")
    if any(h.get("command") == HOOK_COMMAND for g in groups for h in g.get("hooks", [])):
        return "present"
    if text:
        _backup(settings, text, today)
    groups.append({"matcher": MATCHER, "hooks": [{"type": "command", "command": HOOK_COMMAND, "timeout": 10}]})
    settings.parent.mkdir(parents=True, exist_ok=True)
    tmp = settings.with_name(f".{settings.name}.tmp")
    tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    tmp.replace(settings)
    return "added"
