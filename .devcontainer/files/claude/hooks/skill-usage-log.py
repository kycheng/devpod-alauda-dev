#!/usr/bin/env python3
"""PreToolUse hook on Skill: append one line per invocation for usage review."""
import json
import os
import sys
import time

LOG = "/workspaces/.claude/state/skill-usage.jsonl"

try:
    payload = json.load(sys.stdin)
    os.makedirs(os.path.dirname(LOG), exist_ok=True)
    with open(LOG, "a") as f:
        f.write(json.dumps({
            "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "skill": (payload.get("tool_input") or {}).get("skill"),
            "session": payload.get("session_id"),
            "cwd": payload.get("cwd"),
        }) + "\n")
except Exception:
    pass
