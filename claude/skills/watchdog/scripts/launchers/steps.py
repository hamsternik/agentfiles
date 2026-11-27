"""The order of the steps of a start and a retire, for any launcher (no front-end knowledge, no CLI).

Exit codes (those of rex-watchdog.sh): 0 ok, 5 no session got the name in time, 7 rename not seen, 8 the old process
did not exit, 9 no pane has the pid, 10 the old session shows the background-work menu and retire may not answer it.
"""
import sys
import time

NEEDED_TO_RETIRE = frozenset({"find_pane", "send", "rename"})
# /exit with background tasks: "1 Exit and stop tasks / 2 Move to background and exit / 3 Stay" (seen 2026-11-27)
BACKGROUND_MENU = "Background work is running"


def start(launcher, plan, name, wait_name, timeout=60, out=None, err=None, match=None):
    """Start plan through the launcher; when it really starts a session, wait until a live session has `name`.
    match(label): the labels of this session's old windows; an ended one is renamed archived-<label> first, so the
    new window is the only one with its label."""
    out, err = out or sys.stdout, err or sys.stderr
    if match is not None and "find_ended" in launcher.caps:
        for pane in launcher.find_ended(plan, match):
            launcher.rename_window(pane, f"archived-{pane.label}")
            print(f"archived the ended window {pane.label!r} ({pane.window})", file=out)
    started = launcher.start(plan)
    if "start" not in launcher.caps:
        return 0
    if not wait_name(name, timeout):
        print(f"watchdog.py: the window {started.window_label!r} started in {started.where}, but no live session is "
              f"named {name!r} after {timeout:g} s", file=err)
        return 5
    print(f"started {name} in {launcher.name} window {started.window_label!r} (session {started.where})", file=out)
    return 0


def retire(launcher, plan, yes, verified, alive, sleep=time.sleep, verify_tries=10, exit_wait=30, out=None, err=None,
           descends=None):
    """Rename the old session to plan["new_name"], wait for the new name, /exit it, wait for its process to end, then
    rename its window archived-<label>. plan: the JSON of `watchdog.py retire`.
    If /exit shows the background-work menu, answer "1 Exit and stop tasks" only when descends(successor pid, old pid)
    is False (stopping the old tasks cannot stop the successor); else choose nothing and stop (exit 10)."""
    out, err = out or sys.stdout, err or sys.stderr
    pid = plan["pid"]
    if not NEEDED_TO_RETIRE <= launcher.caps:
        print(f"retire {plan['name']} (pid {pid}): the {launcher.name} front-end cannot type; type these lines into "
              f"its pane, each with Enter:", file=out)
        for line in plan["type"]:
            print(f"  {line}", file=out)
        return 0
    pane = launcher.find_pane(pid)
    if pane is None:
        print(f"watchdog.py: no {launcher.name} pane runs pid {pid} (session {plan['session']}): nothing sent", file=err)
        return 9
    if not yes:
        print(f"plan (dry run; add --yes to act) for pid {pid} in window {pane.label!r} ({pane.window}), "
              f"pane {pane.block}:", file=out)
        print(f"  type `/rename {plan['new_name']}`, Enter   (then check the new name)", file=out)
        print(f"  type `/exit`, Enter   (then wait for pid {pid} to end)", file=out)
        print(f"  rename the window to {'archived-' + pane.label!r}", file=out)
        return 0
    launcher.send_line(pane, f"/rename {plan['new_name']}")
    tries, extra = 0, False
    while not verified():
        tries += 1
        if tries >= verify_tries:
            print(f"watchdog.py: the name of pid {pid} did not change to {plan['new_name']!r}: /exit not sent", file=err)
            return 7
        if not extra:  # 11-23: the first Enter did not arrive
            extra = True
            launcher.send_line(pane, "")
        sleep(1)
    launcher.send_line(pane, "/exit")
    waited, answered = 0, False
    while alive(pid):
        if not answered and "capture" in launcher.caps and BACKGROUND_MENU in (launcher.capture(pane) or ""):
            succ = plan.get("successor_pid")
            if not succ or descends is None or descends(succ, pid):
                why = f"the successor (pid {succ}) is a child of it" if succ and descends else "no successor pid"
                print(f"watchdog.py: pid {pid} shows \"{BACKGROUND_MENU}\" and {why}: chose nothing, window not "
                      f"renamed; answer the menu in pane {pane.block}", file=err)
                return 10
            launcher.send_line(pane, "1")
            answered = True
            print(f"pid {pid} showed \"{BACKGROUND_MENU}\": chose 1 Exit and stop tasks (the successor, pid {succ}, "
                  f"is not a child of it)", file=out)
        waited += 1
        if waited > exit_wait:
            print(f"watchdog.py: pid {pid} did not exit: window not renamed", file=err)
            return 8
        sleep(1)
    launcher.rename_window(pane, f"archived-{pane.label}")
    print(f"retired {plan['new_name']} (pid {pid}); window {pane.window} is now {'archived-' + pane.label!r}", file=out)
    return 0
