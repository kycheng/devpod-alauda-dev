#!/usr/bin/env python3
"""Keep working state across compaction.

`save` (PreCompact) writes MR links, ticket keys and recent user messages to a file.
`point` (SessionStart, source compact) tells the resumed session where it is.
"""
import json
import os
import re
import subprocess
import sys
import time

DIR = "/workspaces/.claude/handoff/auto"
TAIL_BYTES = 16 * 1024 * 1024
KEEP_DAYS = 14
LINK = re.compile(r"https://[\w.-]+/[^\s\"'<>)\\]*(?:merge_requests|pull)/\d+")
TICKET = re.compile(r"\b[A-Z][A-Z0-9]+-\d{3,}\b")
TAG = re.compile(r"<[^>]+>")
SECRET = re.compile(r"(?i)\b(password|passwd|token|secret|密码)\s*[:=：]?\s*\S+")
SKIP = ("<task-notification", "<command-", "<local-command", "<system-reminder", "[Request interrupted")


def snapshot_path(session):
    return os.path.join(DIR, f"{session}.md")


def user_text(record):
    """Text of a user message, including ones queued while a turn was running."""
    if record.get("type") == "attachment":
        attachment = record.get("attachment") or {}
        content = attachment.get("prompt") if attachment.get("type") == "queued_command" else ""
    elif record.get("type") == "user" and not record.get("isCompactSummary"):
        content = (record.get("message") or {}).get("content")
    else:
        return ""
    if isinstance(content, list):
        if any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content):
            return ""
        return " ".join(b.get("text", "") for b in content if isinstance(b, dict))
    return content if isinstance(content, str) else ""


def read_state(path):
    with open(path, "rb") as f:
        size = os.path.getsize(path)
        f.seek(max(0, size - TAIL_BYTES))
        text = f.read().decode("utf-8", "ignore")
    links, messages = {}, []
    for line in text.splitlines():
        links.update((m, None) for m in LINK.findall(line))
        try:
            record = json.loads(line)
        except ValueError:
            continue
        message = user_text(record)
        if message.strip() and not message.lstrip().startswith(SKIP):
            messages.append(SECRET.sub(r"\1=[redacted]", TAG.sub("", message).strip()))
    return list(links)[-20:], messages[-8:]


def branch(cwd):
    out = subprocess.run(["git", "-C", cwd, "branch", "--show-current"],
                         capture_output=True, text=True, timeout=10)
    return out.stdout.strip() or "(none)"


def sweep():
    for name in os.listdir(DIR):
        old = os.path.join(DIR, name)
        try:
            if time.time() - os.path.getmtime(old) > KEEP_DAYS * 86400:
                os.remove(old)
        except OSError:
            pass


def save(payload):
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    path = snapshot_path(payload["session_id"])
    # A failure below must not leave the previous compaction's file looking current.
    if os.path.exists(path):
        os.remove(path)
    sweep()
    links, messages = read_state(payload["transcript_path"])
    cwd = payload.get("cwd") or os.getcwd()
    tickets = sorted(set(TICKET.findall(" ".join(messages))))
    lines = [f"# Pre-compaction snapshot {time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime())} UTC", "",
             f"- cwd: {cwd}", f"- branch: {branch(cwd)}",
             f"- tickets: {', '.join(tickets) or '(none)'}", "", "## MR/PR links"]
    lines += [f"- {u}" for u in links] or ["- (none)"]
    lines += ["", "## Recent user messages (oldest first)"]
    lines += [f"- {m[:400]}" for m in messages]
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write("\n".join(lines) + "\n")


def point(payload):
    path = snapshot_path(payload.get("session_id", ""))
    if os.path.exists(path):
        print(f"Compaction happened. State saved just before it: {path}. "
              "Read it if the summary lacks MR links or recent instructions.")


if __name__ == "__main__":
    try:
        data = json.load(sys.stdin)
        {"save": save, "point": point}[sys.argv[1]](data)
    except Exception as err:
        print(f"compact-snapshot: {err}", file=sys.stderr)
