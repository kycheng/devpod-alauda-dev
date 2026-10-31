"""Run with: python3 -m unittest discover -s .devcontainer/files/claude/tests"""
import importlib.machinery
import importlib.util
import json
import os
import tempfile
import unittest
from unittest import mock

ROOT = os.path.join(os.path.dirname(__file__), "..")


def load(path):
    name = os.path.basename(path).replace("-", "_").replace(".py", "")
    loader = importlib.machinery.SourceFileLoader(name, os.path.join(ROOT, path))
    spec = importlib.util.spec_from_loader(name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ProdGuard(unittest.TestCase):
    guard = load("hooks/prod-write-guard.py")

    def test_blocks_writes(self):
        for command in (
            "kubectl --kubeconfig ~/.kube/edge-prod.yaml delete pod x",
            "kubectl --kubeconfig ~/.kube/edge-prod.yaml -n a \\\n  delete pod x",
            "export KUBECONFIG=~/edge-prod.yaml; K=/opt/bin/kubectl; $K --request-timeout=20s -n a patch ingress b",
            'K="kubectl --kubeconfig edge-prod.yaml"; $K delete pod x',
            "KUBECONFIG=edge-prod.yaml kubectl -n a exec p -- ls",
            "kubectl --context production rollout restart deploy/x",
            "kubectl --context prod01 delete pod x",
            "kubectl --context edge-prd delete pod x",
            "kubectl --kubeconfig edge-prod2.yaml apply -f a.yaml",
            'kubectl --kubeconfig "/a b/prod.yaml" delete pod x',
            "oc --context prod delete pod x",
            "kubectl --context prod debug node/a",
            "kubectl --context prod certificate approve a",
            "helm --kube-context edge-prod upgrade a b",
            "timeout 60 kubectl --context prod delete pod x",
            "ssh mac 'KUBECONFIG=edge-prod.yaml kubectl delete pod x'",
            "ssh -o ConnectTimeout=8 mac bash -s <<'EOF'\nexport KUBECONFIG=~/edge-prod.yaml\nK=/opt/bin/kubectl\n$K delete pod x\nEOF",
            'zsh -lc "kubectl --context prod delete pod x"',
        ):
            self.assertTrue(self.guard.blocked(command), command)

    def test_allows_reads_and_other_clusters(self):
        for command in (
            "KUBECONFIG=edge-prod.yaml kubectl -n a get pods | grep delete",
            "KUBECONFIG=edge-prod.yaml kubectl logs p | grep apply",
            "KUBECONFIG=edge-prod.yaml kubectl rollout status deploy/x",
            "kubectl --context prod -n run get pods",
            "kubectl --context prod auth can-i delete pods",
            "kubectl --kubeconfig env2.yaml delete pod x",
            "kubectl --kubeconfig env2.yaml -n prod delete pod x",
            "kubectl --kubeconfig env2.yaml apply -f overlays/prod/x.yaml",
            "kubectl --kubeconfig env2.yaml delete pod my-prod-pod",
            "kubectl --kubeconfig env2.yaml delete pod x; cat docs/prod.md",
            "kubectl delete pod products-1",
            "cat docs/prod.md",
            'git commit -m "docs: how to kubectl apply on prod"',
            'grep -rn "helm upgrade" deploy/prod/',
            'echo "$name run on prod"',
            "cp $SRC cp/prod.yaml",
            "cat > notes.md <<'EOF'\nkubectl --context prod delete pod x\nEOF",
        ):
            self.assertFalse(self.guard.blocked(command), command)

    def test_env_kubeconfig_counts(self):
        self.assertTrue(self.guard.blocked("kubectl delete pod x", "/k/edge-prod.yaml"))


class DiscordGuard(unittest.TestCase):
    guard = load("hooks/discord-reply-guard.py")
    channel = '<channel source="plugin:discord:discord">hi</channel>'
    inbound = {"type": "user", "message": {"content": channel}}
    queued = {"type": "attachment", "attachment": {"type": "queued_command", "prompt": channel}}
    summary = {"type": "user", "isCompactSummary": True, "message": {"content": "earlier: " + channel}}
    quoted = {"type": "user", "message": {"content": "why did " + channel + " fail?"}}
    result = {"type": "user", "message": {"content": [{"type": "tool_result", "content": channel}]}}

    @staticmethod
    def tool(name):
        return {"type": "assistant", "message": {"content": [
            {"type": "tool_use", "name": "mcp__plugin_discord_discord__" + name, "input": {}}]}}

    def pending(self, records):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl") as f:
            f.write("\n".join(json.dumps(r) for r in records))
            f.flush()
            return self.guard.unanswered(f.name)

    def test_unanswered(self):
        self.assertTrue(self.pending([self.inbound]))
        self.assertTrue(self.pending([self.queued]))
        self.assertTrue(self.pending([self.inbound, self.tool("reply"), self.queued]))
        self.assertTrue(self.pending([self.inbound, self.tool("react")]))

    def test_answered_or_not_inbound(self):
        self.assertFalse(self.pending([self.inbound, self.tool("reply")]))
        self.assertFalse(self.pending([self.inbound, self.tool("edit_message")]))
        self.assertFalse(self.pending([self.result]))
        self.assertFalse(self.pending([self.summary]))
        self.assertFalse(self.pending([self.quoted]))


def status(ident, name, state, finished="t1"):
    return {"id": ident, "name": name, "status": state, "finished_at": finished, "target_url": "u"}


def snap(watcher, state="opened", statuses=(), notes=()):
    latest = watcher.latest_statuses(statuses)
    return {
        "state": state, "sha": "abc", "conflicts": False, "note_ids": list(notes), "latest": latest,
        "failed": sorted(n for n, s in latest.items() if s["status"] in watcher.FAILED),
        "running": sorted(n for n, s in latest.items() if s["status"] in watcher.RUNNING),
        "passed": sorted(n for n, s in latest.items() if s["status"] == "success"),
        "links": {},
    }


class PrWatch(unittest.TestCase):
    watcher = load("bin/pr-watch")

    def run_watch(self, snaps, timeout=1):
        """Feed snapshots in order; the clock passes the deadline once they run out."""
        now = [0]
        queue = list(snaps)

        def clock():
            return now[0]

        def fake_snapshot(*_):
            if not queue:
                now[0] = timeout + 1
                raise OSError("no more")
            item = queue.pop(0)
            if isinstance(item, Exception):
                raise item
            return item

        with mock.patch.object(self.watcher, "snapshot", fake_snapshot), \
                mock.patch("sys.stdout"):
            return self.watcher.watch("h", "g", "1", 0, timeout, sleep=lambda _: None, clock=clock)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        patcher = mock.patch.object(self.watcher, "STATE_DIR", self.tmp.name)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)

    def test_newest_status_wins_in_any_order(self):
        for order in (1, -1):
            latest = self.watcher.latest_statuses(
                [status(1, "t", "failed"), status(2, "t", "success")][::order])
            self.assertEqual(latest["t"]["status"], "success")

    def test_failure_reported_once(self):
        failed = snap(self.watcher, statuses=[status(1, "t", "failed")])
        self.assertEqual(self.run_watch([failed]), 0)
        self.assertEqual(self.run_watch([failed]), 2)

    def test_rerun_failing_again_wakes(self):
        self.assertEqual(self.run_watch([snap(self.watcher, statuses=[status(1, "t", "failed")])]), 0)
        self.assertEqual(self.run_watch([snap(self.watcher, statuses=[status(2, "t", "failed", "t2")])]), 0)

    def test_terminal_state_does_not_poll_again(self):
        merged = snap(self.watcher, state="merged")
        self.assertEqual(self.run_watch([merged]), 0)
        self.assertEqual(self.run_watch([merged]), 4)

    def test_reopened_then_closed_fires_again(self):
        closed, opened = snap(self.watcher, state="closed"), snap(self.watcher)
        self.assertEqual(self.run_watch([closed]), 0)
        self.assertEqual(self.run_watch([opened, closed]), 0)

    def test_comment_during_gap_is_kept(self):
        self.assertEqual(self.run_watch([snap(self.watcher, notes=[5])]), 2)
        self.assertEqual(self.run_watch([snap(self.watcher, notes=[5, 6])]), 0)

    def test_comment_replacing_a_deleted_one_fires(self):
        self.assertEqual(self.run_watch([snap(self.watcher, notes=[4, 5])]), 2)
        self.assertEqual(self.run_watch([snap(self.watcher, notes=[4, 6])]), 0)

    def test_own_and_system_notes_ignored(self):
        self.assertTrue(self.watcher.own_note({"system": True, "body": "x"}))
        self.assertTrue(self.watcher.own_note({"system": False, "body": "review " + self.watcher.NOTE_MARKER}))
        self.assertFalse(self.watcher.own_note({"system": False, "body": "please fix"}))

    def test_manual_job_does_not_block_passed(self):
        statuses = [status(1, "a", "success"), status(2, "deploy", "manual")]
        self.assertEqual(self.run_watch([snap(self.watcher, statuses=statuses)]), 0)

    def test_zero_timeout_exits_cleanly(self):
        self.assertEqual(self.run_watch([], timeout=0), 2)

    def test_not_found_fails_fast(self):
        self.assertEqual(self.run_watch([self.watcher.NotFound("x")]), 3)

    def test_event_survives_state_write_failure(self):
        with mock.patch.object(self.watcher.os, "replace", side_effect=OSError("disk full")), \
                mock.patch("sys.stderr"):
            self.assertEqual(self.run_watch([snap(self.watcher, state="merged")]), 0)


class Install(unittest.TestCase):
    installer = load("install.py")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = os.path.join(self.tmp.name, "settings.json")
        patcher = mock.patch.object(self.installer, "SETTINGS", self.path)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_merge_keeps_settings_and_is_idempotent(self):
        with open(self.path, "w") as f:
            json.dump({"keep": 1, "autoCompactWindow": 500000}, f)
        self.installer.merge_settings()
        self.installer.merge_settings()
        with open(self.path) as f:
            settings = json.load(f)
        self.assertEqual(settings["keep"], 1)
        self.assertEqual(settings["autoCompactWindow"], 500000)
        self.assertEqual(len(settings["hooks"]["PreToolUse"]), 2)

    def test_failed_write_leaves_file_intact(self):
        with open(self.path, "w") as f:
            json.dump({"keep": 1}, f)
        with mock.patch.object(self.installer.json, "dump", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                self.installer.merge_settings()
        with open(self.path) as f:
            self.assertEqual(json.load(f), {"keep": 1})

    def test_edited_skill_is_not_overwritten(self):
        source = os.path.join(self.tmp.name, "source")
        dest = os.path.join(self.tmp.name, "dest")
        os.makedirs(source)
        os.makedirs(dest)
        with open(os.path.join(source, "SKILL.md"), "w") as f:
            f.write("new")
        with open(os.path.join(dest, "SKILL.md"), "w") as f:
            f.write("edited")
        with mock.patch("sys.stdout"):
            self.installer.sync_tree(source, dest)
        with open(os.path.join(dest, "SKILL.md")) as f:
            self.assertEqual(f.read(), "edited")


class CompactSnapshot(unittest.TestCase):
    snapshot = load("hooks/compact-snapshot.py")

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.transcript = os.path.join(self.tmp.name, "t.jsonl")
        patcher = mock.patch.object(self.snapshot, "DIR", os.path.join(self.tmp.name, "auto"))
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, records):
        with open(self.transcript, "w") as f:
            f.write("\n".join(json.dumps(r) for r in records))

    def test_queued_included_summary_skipped_secrets_redacted(self):
        self.write([
            {"type": "user", "isCompactSummary": True, "message": {"content": "old summary"}},
            {"type": "attachment", "attachment": {"type": "queued_command", "prompt": "<channel>mid turn</channel>"}},
            {"type": "user", "message": {"content": "password=hunter22abc"}},
        ])
        _, messages = self.snapshot.read_state(self.transcript)
        self.assertEqual(messages[0], "mid turn")
        self.assertEqual(len(messages), 2)
        self.assertNotIn("hunter22abc", messages[1])

    def test_failed_save_removes_stale_snapshot(self):
        self.write([])
        os.makedirs(self.snapshot.DIR)
        stale = self.snapshot.snapshot_path("s")
        with open(stale, "w") as f:
            f.write("old")
        with self.assertRaises(KeyError):
            self.snapshot.save({"session_id": "s"})
        self.assertFalse(os.path.exists(stale))

    def test_old_directory_does_not_abort_save(self):
        self.write([])
        old = os.path.join(self.snapshot.DIR, "old")
        os.makedirs(old)
        os.utime(old, (0, 0))
        self.snapshot.save({"session_id": "s", "transcript_path": self.transcript, "cwd": self.tmp.name})
        self.assertTrue(os.path.exists(self.snapshot.snapshot_path("s")))


if __name__ == "__main__":
    unittest.main()
