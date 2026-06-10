"""Validate a codex exec --json trace for the deskbot browser smoke.

Usage: check_agent_trace.py TRACE_JSONL COMMANDS_OUT_JSON

The trace must show deskbot driving the desktop (including a completed
deskbot --screenshot), no failed commands, and none of the forbidden
ad-hoc screenshot/automation paths.
"""

import json
import sys

commands = []
with open(sys.argv[1], "r", encoding="utf-8", errors="replace") as handle:
    for line in handle:
        try:
            obj = json.loads(line)
        except Exception:
            continue
        item = obj.get("item")
        if isinstance(item, dict) and item.get("type") == "command_execution":
            commands.append({
                "command": item.get("command", ""),
                "exit_code": item.get("exit_code"),
                "status": item.get("status"),
            })

with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(commands, handle, indent=2)

joined = "\n".join(str(command.get("command", "")) for command in commands).lower()
forbidden = ["ffmpeg", "xdotool", "gnome-screenshot", "127.0.0.1:8000", "127.0.0.1:28000"]
if "deskbot" not in joined:
    print("Agent trace did not execute deskbot", file=sys.stderr)
    sys.exit(1)
if "--screenshot" not in joined:
    print("Agent trace did not execute deskbot --screenshot", file=sys.stderr)
    sys.exit(1)
for word in forbidden:
    if word in joined:
        print(f"Agent trace used forbidden path: {word}", file=sys.stderr)
        sys.exit(1)
for command in commands:
    status = command.get("status")
    exit_code = command.get("exit_code")
    if status in ("failed", "error") or (exit_code is not None and exit_code != 0):
        print(f"Agent command failed: {command}", file=sys.stderr)
        sys.exit(1)

completed = [
    str(command.get("command", "")).lower()
    for command in commands
    if command.get("status") == "completed" and command.get("exit_code") == 0
]
if not any("deskbot" in command and "--screenshot" in command for command in completed):
    print("Agent trace did not complete a successful deskbot screenshot command", file=sys.stderr)
    sys.exit(1)
