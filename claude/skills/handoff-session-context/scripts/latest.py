#!/usr/bin/env python3
"""latest.py is now `watchdog.py restore` (watchdog CLI v2). This alias stays for one version."""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import watchdog  # noqa: E402

if __name__ == "__main__":
    print("latest.py is now watchdog.py restore", file=sys.stderr)
    sys.exit(watchdog.main(["restore", *sys.argv[1:]]))
