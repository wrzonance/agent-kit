"""Boundary fixtures only; these do not establish live harness acceptance."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class Activation(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        subprocess.run(["git", "init", "-q", str(self.repo)], check=True)
        self.plugin = self.root / "plugin"
        shutil.copytree(ROOT / "agentkit", self.plugin)
        self.helper = self.plugin / "skills/.shared/scripts/workflow-activation.sh"
        self.hook = self.plugin / "hooks/user-prompt-submit.sh"
        self.payload = {"cwd": str(self.repo), "session_id": "test-session",
                        "hook_event_name": "UserPromptSubmit",
                        "prompt": "$agentkit:parallel-issues 722"}

    def invoke(self, *args, payload=None):
        return subprocess.run([str(self.helper), *args], text=True,
                              input=json.dumps(payload) if payload else None,
                              capture_output=True, cwd=self.repo)

    def prompt(self):
        result = subprocess.run([str(self.hook)], input=json.dumps(self.payload),
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def record(self):
        return json.loads(next((self.repo / ".agent/activation").glob("*.json")).read_text())

    def check(self, *args):
        return self.invoke("check", "--repo-root", str(self.repo), "--session", "test-session",
                           "--skill", "parallel-issues", *args)

    def acknowledge(self):
        return self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                           "--skill", "parallel-issues", "--nonce", self.record()["nonce"])

    def test_unknown_is_not_active(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation-unavailable", result.stderr)

    def test_delivery_intent_requires_session_receipt(self):
        output = self.prompt()
        self.assertIn("parallel-issues", output["hookSpecificOutput"]["additionalContext"])
        self.assertEqual(self.record()["status"], "pending")
        self.assertNotEqual(self.check().returncode, 0)
        self.assertEqual(self.acknowledge().returncode, 0)
        result = self.check()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("session-acknowledgement", result.stdout)
        self.assertNotEqual(self.check("--require", "pre-tool-use").returncode, 0)

    def test_ack_identity_is_first_line(self):
        self.prompt()
        result = self.acknowledge()
        self.assertRegex(result.stdout.splitlines()[0],
                         r"^agentkit: skill=parallel-issues version=0\.8\.1 hash=[0-9a-f]{12}$")

    def test_wrong_nonce_and_other_session_fail(self):
        self.prompt()
        result = self.invoke("ack", "--repo-root", str(self.repo), "--session", "other",
                             "--skill", "parallel-issues", "--nonce", self.record()["nonce"])
        self.assertNotEqual(result.returncode, 0)
        result = self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                             "--skill", "parallel-issues", "--nonce", "bad")
        self.assertNotEqual(result.returncode, 0)

    def test_installed_loaded_mismatch_names_both_versions(self):
        self.prompt()
        self.acknowledge()
        manifest = self.plugin / ".claude-plugin/plugin.json"
        data = json.loads(manifest.read_text())
        data["version"] = "9.9.9"
        manifest.write_text(json.dumps(data))
        (self.plugin / "skills/parallel-issues/SKILL.md").write_text("changed")
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("installed 9.9.9", result.stderr)
        self.assertIn("session received 0.8.1", result.stderr)

    def test_missing_and_standalone_registration(self):
        self.payload["prompt"] = "$parallel-issues 722"
        self.assertIn("standalone-registration", self.prompt()["reason"])
        self.payload["prompt"] = "$agentkit:missing 722"
        self.assertIn("workflow-unavailable", self.prompt()["reason"])
        self.payload["prompt"] = "$agentkit:parallel-issues 722"
        (self.plugin / "skills/parallel-issues/SKILL.md").unlink()
        self.assertIn("workflow-unavailable", self.prompt()["reason"])

    def test_competing_route_and_pending_dispatch_are_denied(self):
        self.prompt()
        payload = dict(self.payload, hook_event_name="PreToolUse", tool_name="Agent",
                       tool_input={"prompt": "implement"})
        result = self.invoke("hook", payload=payload)
        self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")
        self.acknowledge()
        self.assertEqual(self.check("--require", "pre-tool-use").returncode, 0)
        payload.update(tool_name="Skill", tool_input={"skill": "other:parallel-issues"})
        result = self.invoke("hook", payload=payload)
        self.assertIn("competing-workflow", result.stdout)

    def test_resume_revalidates_without_retroactive_receipt(self):
        self.prompt()
        nonce = self.record()["nonce"]
        self.invoke("hook", payload=dict(self.payload, hook_event_name="SessionStart", source="compact"))
        self.assertEqual(self.record()["status"], "pending")
        self.acknowledge()
        self.invoke("hook", payload=dict(self.payload, hook_event_name="SessionStart", source="resume"))
        self.assertEqual(self.check().returncode, 0)
        self.assertEqual(self.record()["nonce"], nonce)

    def test_resume_rearms_capability_without_losing_receipt(self):
        self.prompt()
        self.invoke("hook", payload=dict(self.payload, hook_event_name="PreToolUse",
                                         tool_name="Read", tool_input={"file_path": str(self.helper)}))
        self.acknowledge()
        self.assertEqual(self.check("--require", "pre-tool-use").returncode, 0)
        self.invoke("hook", payload=dict(self.payload, hook_event_name="SessionStart", source="resume"))
        self.assertEqual(self.check().returncode, 0)
        self.assertNotEqual(self.check("--require", "pre-tool-use").returncode, 0)

    def test_unchanged_invocation_reuses_receipt(self):
        self.prompt()
        self.acknowledge()
        before = self.record()
        self.prompt()
        self.assertEqual(self.record(), before)

    def test_preflight_rejects_mismatch_before_probing(self):
        self.prompt()
        self.acknowledge()
        (self.plugin / "skills/parallel-issues/SKILL.md").write_text("stale replacement")
        result = subprocess.run([str(self.helper.parent / "agent-preflight.sh"),
                                 "--worktree", str(self.repo), "--ensure",
                                 "--activation-session", "test-session", "--workflow", "parallel-issues"],
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 1)
        self.assertIn("activation-mismatch", result.stderr)
        self.assertNotIn("skills= path=", result.stdout)

    def test_symlink_evidence_fails_closed(self):
        (self.repo / ".agent").symlink_to(self.root, target_is_directory=True)
        self.assertIn("unsafe evidence path", self.prompt()["reason"])

    def test_pending_receipt_allows_inspection_but_not_mutation_or_dispatch(self):
        self.prompt()
        payload = dict(self.payload, hook_event_name="PreToolUse", tool_name="Bash",
                       tool_input={"command": "cat " + str(self.helper)})
        self.assertEqual(json.loads(self.invoke("hook", payload=payload).stdout), {})
        self.assertEqual(self.record()["status"], "pending")
        native_read = dict(payload, tool_name="Read", tool_input={"file_path": str(self.helper)})
        self.assertEqual(json.loads(self.invoke("hook", payload=native_read).stdout), {})
        for command in ("cat " + str(self.helper) + "; touch /tmp/forbidden",
                        "cat " + str(self.helper) + " > /tmp/forbidden"):
            payload["tool_input"]["command"] = command
            output = json.loads(self.invoke("hook", payload=payload).stdout)
            self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_subdirectory_cannot_evade_pending_gate(self):
        self.prompt()
        subdir = self.repo / "subdir"
        subdir.mkdir()
        payload = dict(self.payload, cwd=str(subdir), hook_event_name="PreToolUse",
                       tool_name="Agent", tool_input={"prompt": "implement"})
        result = subprocess.run([str(self.plugin / "hooks/pre-tool-use.sh")],
                                input=json.dumps(payload), text=True, capture_output=True)
        self.assertEqual(json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_delivered_digest_identifies_actual_workflow_bytes(self):
        self.prompt()
        body = (self.plugin / "skills/parallel-issues/SKILL.md").read_bytes()
        self.assertEqual(self.record()["deliveredDigest"], hashlib.sha256(body).hexdigest())
        self.assertNotEqual(self.record()["deliveredDigest"], self.record()["installedDigest"])

    def test_inspection_never_allows_shell_expansion(self):
        self.prompt()
        malicious = self.plugin / "skills/$(id)"
        malicious.write_text("inert fixture filename")
        payload = dict(self.payload, hook_event_name="PreToolUse", tool_name="Bash",
                       tool_input={"command": "cat " + str(malicious)})
        output = json.loads(self.invoke("hook", payload=payload).stdout)
        self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")


if __name__ == "__main__":
    unittest.main()
