"""The order of the steps of a start and a retire, for any launcher (no front-end knowledge, no CLI).

Exit codes (those of rex-watchdog.sh): 0 ok, 5 no session got the name in time, 7 rename not seen, 8 the old process
did not exit, 9 no pane has the pid.
"""
import sys
import time

NEEDED_TO_RETIRE = frozenset({"find_pane", "send", "rename"})


def start(launcher, plan, name, wait_name, timeout=60, out=None, err=None):
    """Start plan through the launcher; when it really starts a session, wait until a live session has `name`."""
    out, err = out or sys.stdout, err or sys.stderr
    started = launcher.start(plan)
    if "start" not in launcher.caps:
        return 0
    if not wait_name(name, timeout):
        print(f"watchdog.py: the window {started.window_label!r} started in {started.where}, but no live session is "
              f"named {name!r} after {timeout:g} s", file=err)
        return 5
    print(f"started {name} in {launcher.name} window {started.window_label!r} (session {started.where})", file=out)
    return 0


def retire(launcher, plan, yes, verified, alive, sleep=time.sleep, verify_tries=10, exit_wait=30, out=None, err=None):
    """Rename the old session to plan["new_name"], wait for the new name, /exit it, wait for its process to end, then
    rename its window archived-<label>. plan: the JSON of `watchdog.py retire`."""
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
    waited = 0
    while alive(pid):
        waited += 1
        if waited > exit_wait:
            print(f"watchdog.py: pid {pid} did not exit: window not renamed", file=err)
            return 8
        sleep(1)
    launcher.rename_window(pane, f"archived-{pane.label}")
    print(f"retired {plan['new_name']} (pid {pid}); window {pane.window} is now {'archived-' + pane.label!r}", file=out)
    return 0
