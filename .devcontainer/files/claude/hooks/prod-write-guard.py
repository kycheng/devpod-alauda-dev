#!/usr/bin/env python3
"""PreToolUse hook: block cluster writes aimed at a production kubeconfig or context.

Runs in every permission mode, so it still holds under bypassPermissions. A
user who really needs the write runs it with the `!` prefix, which skips hooks.
Only commands visible in the Bash call are checked, not scripts they invoke.
"""
import json
import os
import re
import sys

PROD = re.compile(r"(?<![A-Za-z0-9])prod(uction)?(?![A-Za-z0-9])", re.I)
FLAGS = r"(?:\s+--?[\w-]+(?:[= ](?!-)[^\s;|&]+)?)*"
# $K covers the common K=/opt/homebrew/bin/kubectl shorthand.
KUBECTL = r"(?:\bkubectl|\$\{?[A-Za-z_]\w*\}?)"
KUBE_WRITE = (
    r"apply|create|delete|patch|replace|edit|scale|label|annotate|set|expose|"
    r"run|exec|cp|drain|cordon|uncordon|taint|autoscale"
)
WRITES = [
    re.compile(KUBECTL + FLAGS + r"\s+(?:" + KUBE_WRITE + r")\b"),
    re.compile(KUBECTL + FLAGS + r"\s+rollout\s+(?:restart|undo|pause|resume)\b"),
    re.compile(r"\bhelm\b" + FLAGS + r"\s+(?:install|upgrade|uninstall|delete|rollback)\b"),
]


def blocked(command, env_kubeconfig=""):
    if not PROD.search(command) and not PROD.search(env_kubeconfig):
        return False
    return any(p.search(command) for p in WRITES)


def main():
    payload = json.load(sys.stdin)
    command = (payload.get("tool_input") or {}).get("command", "")
    if blocked(command, os.environ.get("KUBECONFIG", "")):
        print(
            "Blocked: this looks like a write to a production cluster, which is read-only "
            "for Claude. If the user wants it, they can run it themselves with the ! prefix.",
            file=sys.stderr,
        )
        sys.exit(2)


if __name__ == "__main__":
    main()
