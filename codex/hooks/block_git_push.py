#!/usr/bin/env python3
"""Block git push attempts from Codex shell tool calls."""

from __future__ import annotations

import json
import re
import sys


GIT_PUSH_RE = re.compile(
    r"""
    (?:^|[\s;&|()])
    (?:
      (?:command|builtin|noglob)\s+
      |sudo\s+(?:-\S+\s+)*
      |env\s+(?:-\S+\s+)*(?:[A-Za-z_][A-Za-z0-9_]*=\S+\s+)*
    )*
    (?:(?:/usr/bin|/usr/local/bin|/bin)/)?
    git
    (?:
      \s+-C\s+(?:"[^"]*"|'[^']*'|[^\s;&|()]+)
    )*
    \s+push(?:\s|$)
    """,
    re.IGNORECASE | re.VERBOSE,
)


def deny(reason: str) -> None:
    payload = {
        "hookSpecificOutput": {
            "hookEventName": "PreToolUse",
            "permissionDecision": "deny",
            "permissionDecisionReason": reason,
        }
    }
    print(json.dumps(payload, separators=(",", ":")))


def main() -> int:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return 0

    tool_input = event.get("tool_input") or {}
    command = tool_input.get("command")
    if not isinstance(command, str):
        return 0

    if GIT_PUSH_RE.search(command):
        deny(
            "git push is blocked in Codex-managed environments. "
            "Ask the human to review and push from outside the agent."
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
