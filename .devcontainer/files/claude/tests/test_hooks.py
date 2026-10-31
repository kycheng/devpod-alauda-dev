"""Run with: python3 -m unittest discover -s .devcontainer/files/claude/tests"""
import importlib.util
import json
import os
import tempfile
import unittest

HOOKS = os.path.join(os.path.dirname(__file__), "..", "hooks")


def load(name):
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), os.path.join(HOOKS, name + ".py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ProdGuard(unittest.TestCase):
    guard = load("prod-write-guard")

    def test_blocks_writes(self):
        for command in (
            "kubectl --kubeconfig ~/.kube/edge-prod.yaml delete pod x",
            "export KUBECONFIG=~/edge-prod.yaml; $K --request-timeout=20s -n a patch ingress b",
            "KUBECONFIG=edge-prod.yaml kubectl -n a exec p -- ls",
            "kubectl --context production rollout restart deploy/x",
            "helm --kube-context edge-prod upgrade a b",
        ):
            self.assertTrue(self.guard.blocked(command), command)

    def test_allows_reads_and_other_clusters(self):
        for command in (
            "KUBECONFIG=edge-prod.yaml kubectl -n a get pods | grep delete",
            "KUBECONFIG=edge-prod.yaml kubectl logs p | grep apply",
            "KUBECONFIG=edge-prod.yaml kubectl rollout status deploy/x",
            "kubectl --kubeconfig env2.yaml delete pod x",
            "kubectl delete pod products-1",
            "cat docs/prod.md",
        ):
            self.assertFalse(self.guard.blocked(command), command)

    def test_env_kubeconfig_counts(self):
        self.assertTrue(self.guard.blocked("kubectl delete pod x", "/k/edge-prod.yaml"))


class DiscordGuard(unittest.TestCase):
    guard = load("discord-reply-guard")
    inbound = {"type": "user", "message": {"content": '<channel source="plugin:discord:discord">hi</channel>'}}
    reply = {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "name": "mcp__plugin_discord_discord__reply", "input": {}}]}}
    result = {"type": "user", "message": {"content": [
        {"type": "tool_result", "content": '<channel source="plugin:discord:discord">'}]}}

    def pending(self, records):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write("\n".join(json.dumps(r) for r in records))
            f.flush()
            return self.guard.unanswered(f.name)

    def test_cases(self):
        self.assertTrue(self.pending([self.inbound]))
        self.assertFalse(self.pending([self.inbound, self.reply]))
        self.assertTrue(self.pending([self.inbound, self.reply, self.inbound]))
        self.assertFalse(self.pending([self.result]))


if __name__ == "__main__":
    unittest.main()
