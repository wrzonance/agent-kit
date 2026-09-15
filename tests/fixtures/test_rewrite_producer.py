import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "agentkit/skills/.shared/scripts/rewrite-profile.py"
SPEC = importlib.util.spec_from_file_location("rewrite_producer", MODULE)
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)


class Producer(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=Path.home() / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.snapshot = self.root / "snapshot"
        self.snapshot.write_text("unalias -a\nexport PATH=/usr/bin:/bin\n")
        self.native = self.root / "native"
        self.native.write_text("source /private/snapshot 2>/dev/null || true && eval 'printf fixture' < /dev/null && pwd -P >| /private/cwd")
        self.snapshot.chmod(0o600)
        self.native.chmod(0o600)

    def test_reviewed_hashes_bind_exact_audit_input_before_profile_creation(self):
        def digest(path):
            return hashlib.sha256(path.read_bytes()).hexdigest()

        expected = {"snapshot": digest(self.snapshot), "native": digest(self.native)}
        result = PRODUCER.reviewed_shell(self.snapshot, self.native, expected)
        self.assertEqual({"snapshotTemplateSha256", "pathSha256", "nativeSetupSha256"}, set(result))
        self.snapshot.write_text(self.snapshot.read_text() + "alias agent-run.sh='false'\n")
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.reviewed_shell(self.snapshot, self.native, expected)

    def test_compatibility_requires_matching_native_post_and_permission_preservation(self):
        provider = self.root / "provider.jsonl"
        events = self.root / "events.ndjson"
        provider.write_text(json.dumps({"type": "system", "subtype": "init", "plugins": [],
                                        "claude_code_version": "2.1.272"}) + "\n")
        original = {"command": "agent-run.sh --cmd test", "timeout": 10000}
        replacement = original | {"command": "'/private/agent-run.sh' --cmd test"}
        data = [{"event": "PreToolUse", "id": "call", "session": "session", "input": original,
                 "output": {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": replacement}}},
                {"event": "PostToolUse", "id": "call", "session": "session", "input": replacement,
                 "response": {"stdout": "synthetic observation"}}]
        events.write_text("\n".join(map(json.dumps, data)))
        PRODUCER.compatibility(provider, events)
        data[0]["output"]["hookSpecificOutput"]["permissionDecision"] = "allow"
        events.write_text("\n".join(map(json.dumps, data)))
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.compatibility(provider, events)

    @unittest.skipUnless(os.environ.get("AGENT_REWRITE_OBSERVED_AUDIT"), "private observed audit not supplied")
    def test_optional_observed_inputs_parse_without_creating_authority(self):
        audit = Path(os.environ["AGENT_REWRITE_OBSERVED_AUDIT"])
        snapshots = list(audit.glob("prefix-*.snapshot"))
        self.assertEqual(1, len(snapshots))
        snapshot = snapshots[0]
        native = snapshot.with_suffix(".command")
        expected = {"snapshot": hashlib.sha256(snapshot.read_bytes()).hexdigest(),
                    "native": hashlib.sha256(native.read_bytes()).hexdigest()}
        PRODUCER.reviewed_shell(snapshot, native, expected)
        compatibility = Path(os.environ["AGENT_REWRITE_OBSERVED_COMPATIBILITY"])
        PRODUCER.compatibility(compatibility / "provider.jsonl", compatibility / "events.ndjson")

    def test_unreviewed_spec_bytes_cannot_create_operator_authority(self):
        spec = self.root / "spec.json"
        spec.write_text("{}")
        spec.chmod(0o600)
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.attest(spec, "a" * 64)

    def test_target_entry_evidence_requires_exact_argv_cwd_and_one_native_nonce(self):
        manifest = {"helper": "/private/agent-run.sh", "nonce": "fixture", "cwd": "/private/repo"}
        entry = {"nonce": "fixture", "cwd": "/private/repo", "argv": ["--cmd", "test"],
                 "environment": "synthetic", "exitCode": 0}
        post = {"input": {"command": "'/private/agent-run.sh' --cmd test"},
                "response": {"stdout": "REWRITE-PROBE:fixture\n"}}
        PRODUCER.validate_entry(manifest, entry, post)
        for changed in (entry | {"argv": ["--cmd", "other"]}, entry | {"cwd": "/other"},
                        entry | {"exitCode": 1}, entry | {"nonce": "other"}):
            with self.assertRaises(PRODUCER.Unavailable):
                PRODUCER.validate_entry(manifest, changed, post)
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.validate_entry(manifest, entry, post | {"response": {}})

    def test_public_attestation_rejects_replaceable_launch_parent_before_writing(self):
        directory = self.root / "launch"
        directory.mkdir(mode=0o777)
        directory.chmod(0o777)
        data = {"kit": str(MODULE.parents[3]), "python": str(Path(sys.executable).resolve()),
                "prefix": str(directory / "prefix.sh"), "settings": str(directory / "settings.json")}
        path = self.root / "reviewed-spec.json"
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.attest(path, hashlib.sha256(path.read_bytes()).hexdigest())
        self.assertFalse((directory / "prefix.sh").exists())

    def test_public_attestation_rejects_an_interpreter_the_hooks_will_not_use(self):
        other = self.root / "other-python"
        other.write_text("fixture")
        data = {"kit": str(MODULE.parents[3]), "python": str(other),
                "prefix": str(self.root / "prefix.sh"), "settings": str(self.root / "settings.json")}
        path = self.root / "reviewed-spec.json"
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        with self.assertRaises(PRODUCER.Unavailable):
            PRODUCER.attest(path, hashlib.sha256(path.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
