#!/usr/bin/env python3
"""Stop hook: block ending a turn while the latest Discord message has no reply.

The Discord user cannot see terminal output, so a turn that ends without the
reply tool looks like silence. Fails open: any parse problem allows the stop.
"""
import json
import os
import sys

TAIL_BYTES = 8 * 1024 * 1024
MARKER = '<channel source="plugin:discord'
REPLY_TOOLS = ("discord__reply", "discord__discord_ask", "discord__edit_message")


def tail_lines(path):
    with open(path, "rb") as f:
        size = os.path.getsize(path)
        f.seek(max(0, size - TAIL_BYTES))
        data = f.read()
    lines = data.decode("utf-8", "ignore").splitlines()
    return lines[1:] if size > TAIL_BYTES else lines


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(
            b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text"
        )
    return ""


def is_inbound(record):
    kind = record.get("type")
    if kind == "attachment":
        attachment = record.get("attachment") or {}
        if attachment.get("type") != "queued_command":
            return False
        text = text_of(attachment.get("prompt"))
    elif kind == "user" and not record.get("isCompactSummary"):
        text = text_of((record.get("message") or {}).get("content"))
    else:
        return False
    return text.lstrip().startswith(MARKER)


def replied(record):
    if record.get("type") != "assistant":
        return False
    content = (record.get("message") or {}).get("content")
    if not isinstance(content, list):
        return False
    return any(
        isinstance(b, dict)
        and b.get("type") == "tool_use"
        and any(t in b.get("name", "") for t in REPLY_TOOLS)
        for b in content
    )


def unanswered(path):
    pending = False
    for line in tail_lines(path):
        try:
            record = json.loads(line)
        except ValueError:
            continue
        if is_inbound(record):
            pending = True
        elif replied(record):
            pending = False
    return pending


def main():
    payload = json.load(sys.stdin)
    if payload.get("stop_hook_active"):
        return
    path = payload.get("transcript_path")
    if not path or not unanswered(path):
        return
    print(
        json.dumps(
            {
                "decision": "block",
                "reason": "The latest Discord message has no reply yet and the user "
                "cannot see terminal text. Send the outcome with the Discord reply tool.",
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
