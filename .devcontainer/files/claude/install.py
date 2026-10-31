#!/usr/bin/env python3
"""Install Claude Code hooks, skills and tools, and merge them into settings.json.

Safe to re-run. Managed files are overwritten; other settings are left untouched.
"""
import copy
import filecmp
import glob
import json
import os
import shutil

HERE = os.path.dirname(os.path.abspath(__file__))
HOME = "/workspaces/.claude"
BIN = "/workspaces/.local/bin"
HOOKS = f"{HOME}/hooks"
SETTINGS = f"{HOME}/settings.json"
PY = "python3 " + HOOKS + "/"
WANTED_HOOKS = {
    "Stop": [(None, PY + "discord-reply-guard.py")],
    "PreToolUse": [("Bash", PY + "prod-write-guard.py"), ("Skill", PY + "skill-usage-log.py")],
    "PreCompact": [(None, PY + "compact-snapshot.py save")],
    "SessionStart": [("compact", PY + "compact-snapshot.py point")],
}
WANTED_VALUES = {"autoCompactWindow": 300000, "bashOutputMaxChars": 12000}


def sync_tree(source, dest):
    """Copy new files, but keep ones edited locally: skills accumulate gotchas in place."""
    for folder, _, names in os.walk(source):
        target = os.path.join(dest, os.path.relpath(folder, source))
        os.makedirs(target, exist_ok=True)
        for name in names:
            src, dst = os.path.join(folder, name), os.path.join(target, name)
            if not os.path.exists(dst):
                shutil.copy(src, dst)
            elif not filecmp.cmp(src, dst, shallow=False):
                print(f"Keeping local edits in {dst}; compare with {src}")


def copy_files():
    os.makedirs(HOOKS, exist_ok=True)
    os.makedirs(BIN, exist_ok=True)
    for path in glob.glob(f"{HERE}/hooks/*.py"):
        shutil.copy(path, HOOKS)
    for path in glob.glob(f"{HERE}/bin/*"):
        shutil.copy(path, BIN)
        os.chmod(f"{BIN}/{os.path.basename(path)}", 0o755)
    for name in os.listdir(f"{HERE}/skills"):
        sync_tree(f"{HERE}/skills/{name}", f"{HOME}/skills/{name}")
    for name in ("epics", "handoff", "knowledge", "state"):
        os.makedirs(f"{HOME}/{name}", exist_ok=True)


def merge_settings():
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
    original = copy.deepcopy(settings)
    for key, value in WANTED_VALUES.items():
        settings.setdefault(key, value)
    hooks = settings.setdefault("hooks", {})
    for event, entries in WANTED_HOOKS.items():
        groups = hooks.setdefault(event, [])
        present = {h.get("command") for g in groups for h in g.get("hooks", [])}
        for matcher, command in entries:
            if command in present:
                continue
            group = {"hooks": [{"type": "command", "command": command, "timeout": 20}]}
            if matcher:
                group["matcher"] = matcher
            groups.append(group)
    if settings == original:
        return
    # Replace atomically: a full disk must not leave settings.json truncated.
    tmp = f"{SETTINGS}.{os.getpid()}"
    try:
        with open(tmp, "w") as f:
            json.dump(settings, f, indent=2, ensure_ascii=False)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, SETTINGS)
    finally:
        if os.path.exists(tmp):
            os.remove(tmp)


if __name__ == "__main__":
    copy_files()
    merge_settings()
    print("Claude config installed")
