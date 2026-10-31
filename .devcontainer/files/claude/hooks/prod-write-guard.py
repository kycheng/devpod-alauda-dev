#!/usr/bin/env python3
"""PreToolUse hook: block cluster writes aimed at a production kubeconfig or context.

Runs in every permission mode, so it still holds under bypassPermissions. A user
who really needs the write runs it with the `!` prefix, which skips hooks.

This is a guard rail, not a security boundary. It parses the command text, looks
through `ssh`, `bash -c` and heredocs fed to a shell, and tracks KUBECONFIG and
variables holding the client. It can't see inside scripts, `$(...)`, loop
variables or direct API calls.
"""
import json
import os
import re
import shlex
import sys

PROD = re.compile(r"(?<![a-z0-9])(?:prod(?:uction)?|prd)\d*(?![a-z0-9])", re.I)
KUBE_CLIENTS = {"kubectl", "k", "oc", "kubecolor"}
KUBE_WRITES = {
    "apply", "create", "delete", "patch", "replace", "edit", "scale", "label", "annotate",
    "set", "expose", "run", "exec", "cp", "drain", "cordon", "uncordon", "taint", "autoscale",
    "debug", "attach",
}
KUBE_WRITE_PAIRS = {
    "rollout": {"restart", "undo", "pause", "resume"},
    "certificate": {"approve", "deny"},
    "auth": {"reconcile"},
}
HELM_WRITES = {"install", "upgrade", "uninstall", "delete", "rollback"}
TARGET_FLAGS = {"--kubeconfig", "--context", "--cluster", "--kube-context"}
VALUE_FLAGS = TARGET_FLAGS | {
    "-n", "--namespace", "--user", "--request-timeout", "-s", "--server", "--as", "--token",
    "--kube-apiserver", "--kube-token",
}
WRAPPERS = {"env", "sudo", "command", "nohup", "exec", "time", "then", "do", "else", "!", "{", "("}
SHELLS = {"bash", "sh", "zsh"}
SSH_VALUE_FLAGS = set("bcDEeFIiJLlmOoPpRSWw")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)([\w.-]+)\1")
ASSIGNMENT = re.compile(r"^([A-Za-z_]\w*)=(.*)$", re.S)
VARIABLE = re.compile(r"\$\{?([A-Za-z_]\w*)\}?")


def split_heredocs(command):
    """Return (shell text, bodies fed to a shell). Other heredoc bodies are data."""
    kept, bodies, lines = [], [], command.split("\n")
    index = 0
    while index < len(lines):
        current = lines[index]
        kept.append(current)
        index += 1
        match = HEREDOC.search(current)
        if not match:
            continue
        body = []
        while index < len(lines) and lines[index].strip() != match.group(2):
            body.append(lines[index])
            index += 1
        index += 1
        words = current.split()
        if any(os.path.basename(w) in SHELLS | {"ssh"} for w in words[:8]):
            bodies.append("\n".join(body))
    return "\n".join(kept), bodies


def split_segments(text):
    """Split on ; && || | & and newlines, outside quotes."""
    segments, current, quote, index = [], [], None, 0
    while index < len(text):
        char = text[index]
        if quote:
            current.append(char)
            if char == "\\" and quote == '"' and index + 1 < len(text):
                index += 1
                current.append(text[index])
            elif char == quote:
                quote = None
        elif char in "'\"":
            quote = char
            current.append(char)
        elif char == "\\" and index + 1 < len(text):
            index += 1
            current.append(text[index])
        elif char in ";|&\n":
            segments.append("".join(current))
            current = []
        else:
            current.append(char)
        index += 1
    segments.append("".join(current))
    return [s.strip() for s in segments if s.strip()]


def tokenize(segment):
    try:
        return shlex.split(segment, comments=True)
    except ValueError:
        return segment.split()


def expand(token, variables):
    return VARIABLE.sub(lambda m: variables.get(m.group(1), m.group(0)), token)


def is_prod_kube_write(tokens):
    verb_args, index = [], 0
    while index < len(tokens):
        token = tokens[index]
        if token in VALUE_FLAGS:
            index += 1
        elif not token.startswith("-"):
            verb_args.append(token)
        index += 1
    if not verb_args:
        return False
    verb = verb_args[0]
    if verb in KUBE_WRITES:
        return True
    return len(verb_args) > 1 and verb_args[1] in KUBE_WRITE_PAIRS.get(verb, ())


def targets_prod(tokens, kubeconfig):
    if kubeconfig and PROD.search(kubeconfig):
        return True
    for index, token in enumerate(tokens):
        name = token.split("=", 1)[0]
        if name not in TARGET_FLAGS:
            continue
        value = token.split("=", 1)[1] if "=" in token else " ".join(tokens[index + 1:index + 2])
        if PROD.search(value):
            return True
    return False


def ssh_remote(tokens):
    index = 1
    while index < len(tokens) and tokens[index].startswith("-"):
        flag = tokens[index]
        if len(flag) == 2 and flag[1] in SSH_VALUE_FLAGS:
            index += 1
        index += 1
    return " ".join(tokens[index + 1:])


def check_segment(segment, env):
    tokens = [expand(t, env) for t in tokenize(segment)]
    kubeconfig = env.get("KUBECONFIG", "")
    while tokens:
        first = tokens[0]
        if first == "export":
            tokens = tokens[1:]
            for token in tokens:
                match = ASSIGNMENT.match(token)
                if match:
                    env[match.group(1)] = match.group(2)
            return False
        match = ASSIGNMENT.match(first)
        if match:
            if len(tokens) == 1:
                env[match.group(1)] = match.group(2)
            elif match.group(1) == "KUBECONFIG":
                kubeconfig = match.group(2)
            tokens = tokens[1:]
        elif first in WRAPPERS:
            tokens = tokens[1:]
        elif first == "timeout":
            index = 1
            while index < len(tokens) and tokens[index].startswith("-"):
                index += 1
            tokens = tokens[index + 1:]
        else:
            break
    if not tokens:
        return False
    # A variable may hold "kubectl --kubeconfig x", which expands to one token.
    if " " in tokens[0]:
        tokens = tokenize(tokens[0]) + tokens[1:]
    name = os.path.basename(tokens[0])
    if name == "ssh":
        return command_blocked(ssh_remote(tokens), dict(env))
    if name in SHELLS:
        for index, token in enumerate(tokens[1:], 1):
            if token.startswith("-") and "c" in token and not token.startswith("--"):
                return command_blocked(" ".join(tokens[index + 1:index + 2]), dict(env))
        return False
    if name in KUBE_CLIENTS:
        return targets_prod(tokens, kubeconfig) and is_prod_kube_write(tokens[1:])
    if name == "helm":
        verbs = [t for t in tokens[1:] if not t.startswith("-")]
        write = any(v in HELM_WRITES for v in verbs[:3]) and "plugin" not in verbs[:1]
        return write and targets_prod(tokens, kubeconfig)
    return False


def command_blocked(command, env):
    text, bodies = split_heredocs(command.replace("\\\n", " "))
    for segment in split_segments(text):
        if check_segment(segment, env):
            return True
    return any(command_blocked(body, env) for body in bodies)


def blocked(command, env_kubeconfig=""):
    return command_blocked(command, {"KUBECONFIG": env_kubeconfig} if env_kubeconfig else {})


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
