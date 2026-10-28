#!/usr/bin/env python3
"""Track time spent in Pro Tools sessions (macOS).

  python3 pttrack.py run      # start tracking (leave running in a terminal)
  python3 pttrack.py report   # totals per session/project
  python3 pttrack.py link <session folder> [project name]
  python3 pttrack.py unlink <project name>
  python3 pttrack.py links    # show linked folders

Time counts only while Pro Tools is the frontmost app and you've touched the
keyboard/mouse within IDLE_LIMIT seconds. The session name comes from the
front Pro Tools window title.

First run: macOS will ask to let your terminal control "System Events"
(System Settings > Privacy & Security > Accessibility / Automation).
"""
import json
import re
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

POLL = 10            # seconds between checks
IDLE_LIMIT = 10 * 60  # stop counting after this many seconds of no input
LOG = Path.home() / ".protools-tracker" / "log.json"
LINKS = Path.home() / ".protools-tracker" / "links.json"

SCRIPT = '''
tell application "System Events"
    set front_app to name of first application process whose frontmost is true
    if front_app is "Pro Tools" then
        try
            return front_app & "|" & (name of front window of process "Pro Tools")
        end try
        return front_app & "|"
    end if
    return front_app & "|"
end tell
'''


def osa():
    out = subprocess.run(["osascript", "-e", SCRIPT], capture_output=True, text=True)
    return out.stdout.strip()


def idle_seconds():
    out = subprocess.run(["ioreg", "-c", "IOHIDSystem"], capture_output=True, text=True).stdout
    m = re.search(r'"HIDIdleTime" = (\d+)', out)
    return int(m.group(1)) / 1e9 if m else 0


def session_name(title):
    """'Edit: My Song', 'Mix: My Song', 'My Song.ptx - Edit' -> 'My Song'."""
    t = re.sub(r"^(Edit|Mix|Transport|MIDI Editor)\s*:\s*", "", title.strip())
    t = re.sub(r"\s*[-–]\s*(Edit|Mix)$", "", t)
    t = re.sub(r"\.(ptx|ptf)$", "", t)
    return t or None


def load():
    try:
        return json.loads(LOG.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def save(data):
    LOG.parent.mkdir(parents=True, exist_ok=True)
    LOG.write_text(json.dumps(data, indent=2))


def load_links():
    try:
        return json.loads(LINKS.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def link(folder, name=None):
    path = Path(folder).expanduser().resolve()
    if not path.is_dir():
        sys.exit(f"Not a folder: {path}")
    if not list(path.glob("*.pt[xf]")):
        sys.exit(f"No .ptx/.ptf session file found directly in {path}")
    links = load_links()
    links[name or path.name] = str(path)
    LINKS.parent.mkdir(parents=True, exist_ok=True)
    LINKS.write_text(json.dumps(links, indent=2))
    print(f"Linked '{name or path.name}' -> {path}")


def unlink(name):
    links = load_links()
    if links.pop(name, None) is None:
        sys.exit(f"No link named '{name}'")
    LINKS.write_text(json.dumps(links, indent=2))
    print(f"Unlinked '{name}'")


def resolve(session, links):
    """Map a session name to a linked project, else keep the session name."""
    for project, folder in links.items():
        if any(p.stem == session for p in Path(folder).glob("*.pt[xf]")):
            return project
    return session


def run():
    data, current, print_at = load(), None, 0
    print(f"Tracking Pro Tools. Log: {LOG}. Ctrl+C to stop.")
    while True:
        app, _, title = osa().partition("|")
        name = session_name(title) if app == "Pro Tools" else None
        if name:
            current = name  # remember last session so dialogs/plugin windows still count
        if app == "Pro Tools" and current and idle_seconds() < IDLE_LIMIT:
            days = data.setdefault(resolve(current, load_links()), {})
            today = date.today().isoformat()
            days[today] = days.get(today, 0) + POLL
            save(data)
            if time.time() - print_at > 300:
                print(f"{resolve(current, load_links())}: {fmt(sum(days.values()))} total")
                print_at = time.time()
        time.sleep(POLL)


def fmt(sec):
    return f"{int(sec // 3600)}h {int(sec % 3600 // 60):02d}m"


def report():
    data = load()
    if not data:
        print("Nothing logged yet.")
        return
    for name, days in sorted(data.items(), key=lambda kv: -sum(kv[1].values())):
        print(f"{fmt(sum(days.values())):>9}  {name}  ({len(days)} days)")


if __name__ == "__main__":
    cmd, args = (sys.argv[1] if len(sys.argv) > 1 else "report"), sys.argv[2:]
    try:
        if cmd == "run":
            run()
        elif cmd == "link" and args:
            link(*args[:2])
        elif cmd == "unlink" and args:
            unlink(args[0])
        elif cmd == "links":
            print(json.dumps(load_links(), indent=2))
        else:
            report()
    except KeyboardInterrupt:
        print("\nStopped.")
