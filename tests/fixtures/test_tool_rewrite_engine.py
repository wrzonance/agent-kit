import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

MODULE = Path(__file__).resolve().parents[2] / "agentkit/hooks/lib/tool_input_rewrite.py"
sys.path.insert(0, str(MODULE.parent))
SPEC = importlib.util.spec_from_file_location("tool_input_rewrite", MODULE)
ENGINE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ENGINE)


class Rewrites(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.helper = self.root / "a path/it's/agent-run.sh"
        self.helper.parent.mkdir(parents=True)
        self.helper.write_text("#!/bin/bash\nexit 0\n")
        self.helper.chmod(0o700)
        self.event = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": str(self.root),
                      "session_id": "fixture-session", "tool_use_id": "fixture-call",
                      "permission_mode": "default", "tool_input": {"command": "agent-run.sh --cmd test",
                          "description": "private-description", "timeout": 731}}

    def test_candidate_preserves_non_command_fields_and_grants_no_permissions(self):
        original = json.dumps(self.event)
        candidate = ENGINE.candidate(self.event, self.helper, "a" * 32)
        self.assertEqual(self.event["tool_input"] | {"command": candidate["command"]}, candidate)
        self.assertEqual(original, json.dumps(self.event))
        self.assertNotIn("permissionDecision", candidate)
        self.assertTrue(candidate["command"].endswith(" # agentkit-rewrite=" + "a" * 32))

    def test_nested_and_marker_looking_text_is_never_a_candidate(self):
        path = Path(__file__).with_name("tool-rewrite-ineligible.json")
        cases = json.loads(path.read_text()) + ["printf '%s' '# agentkit-rewrite=" + "a" * 32 + "'"]
        for command in cases:
            with self.subTest(command=command):
                event = self.event | {"tool_input": self.event["tool_input"] | {"command": command}}
                self.assertIsNone(ENGINE.candidate(event, self.helper, "a" * 32))

    def test_unknown_tool_execution_controls_are_ineligible(self):
        for extra in ({"run_in_background": True}, {"timeout": True}, {"timeout": 0},
                      {"dangerouslyDisableSandbox": True}, {"workdir": "/elsewhere"}):
            event = self.event | {"tool_input": self.event["tool_input"] | extra}
            self.assertIsNone(ENGINE.candidate(event, self.helper, "a" * 32))

    def test_bash_preserves_argv_cwd_environment_output_and_exit_through_quoted_helper_path(self):
        self.helper.write_text("#!/bin/bash\nprintf '%s\\n' \"$PWD\" \"$SYNTHETIC\" \"$#\" \"$1\" \"$2\"\nprintf fixture-stderr >&2\nexit 37\n")
        subprocess.run(["shellcheck", str(self.helper)], check=True, capture_output=True)
        replacement = ENGINE.candidate(self.event, self.helper, "a" * 32)
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-c", replacement["command"]],
                                cwd=self.root, env={"PATH": "/usr/bin:/bin", "SYNTHETIC": "fixture-value"},
                                capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual(37, result.returncode)
        self.assertEqual([str(self.root), "fixture-value", "2", "--cmd", "test"], result.stdout.splitlines())
        self.assertEqual("fixture-stderr", result.stderr)

    def test_concurrent_calls_get_at_most_one_claim(self):
        def issue(number):
            return ENGINE.Records(self.root / "records", "fixture-session").issue(
                f"call-{number}", self.event["tool_input"], self.helper)

        with ThreadPoolExecutor(max_workers=8) as pool:
            claims = list(pool.map(issue, range(8)))
        self.assertEqual(1, sum(claim is not None for claim in claims))

    def test_claim_is_unique_and_manual_or_nested_commands_cannot_consume_it(self):
        records = ENGINE.Records(self.root / "records", "fixture-session")
        first = records.issue("call-1", self.event["tool_input"], self.helper)
        self.assertIsNotNone(first)
        self.assertIsNone(records.issue("call-1", self.event["tool_input"], self.helper))
        self.assertIsNone(records.issue("call-2", self.event["tool_input"], self.helper))
        for other in (f"'{self.helper}' --cmd test", "printf '%s' " + json.dumps(first["command"]),
                      "sh -c " + json.dumps(first["command"])):
            self.assertIsNone(records.consume(other))
        self.assertEqual("call-1", records.consume(first["command"])["toolId"])
        self.assertIsNone(records.consume(first["command"]))

    def test_missing_completion_preserves_delayed_claim_until_correlated_completion(self):
        records = ENGINE.Records(self.root / "records", "fixture-session")
        original = self.event["tool_input"].copy()
        first = records.issue("call-1", original, self.helper)
        self.assertIsNone(records.issue("call-2", original, self.helper))
        self.assertEqual(self.event["tool_input"], original)
        self.assertEqual("call-1", records.consume(first["command"])["toolId"])
        self.assertIsNone(records.issue("call-2", original, self.helper))
        post = self.event | {"hook_event_name": "PostToolUse", "tool_use_id": "call-1", "tool_input": first}
        completed = records.finish(post)
        self.assertEqual("call-1", completed["toolId"])
        self.assertTrue(completed["executionClaimed"])
        self.assertIsNone(completed["exitCode"])
        self.assertIsNone(records.consume(first["command"]))
        self.assertIsNotNone(records.issue("call-2", original, self.helper))

    def test_failure_completion_records_no_invented_exit_code(self):
        for consumed in (False, True):
            records = ENGINE.Records(self.root / f"records-{consumed}", "fixture-session")
            first = records.issue("call-1", self.event["tool_input"], self.helper)
            if consumed:
                records.consume(first["command"])
            failure = self.event | {"hook_event_name": "PostToolUseFailure", "tool_use_id": "call-1",
                                   "tool_input": first, "error": "private error includes exit 42",
                                   "is_interrupt": consumed}
            result = records.finish(failure)
            self.assertEqual("PostToolUseFailure", result["hookEventName"])
            self.assertIsNone(result["exitCode"])
            self.assertEqual(consumed, result["executionClaimed"])
            self.assertEqual(consumed, result["interrupted"])
            self.assertNotIn("private", json.dumps(result))

    def test_results_are_once_only_correlated_and_do_not_store_output_secrets(self):
        records = ENGINE.Records(self.root / "records", "fixture-session")
        first = records.issue("call-1", self.event["tool_input"], self.helper)
        records.consume(first["command"])
        post = self.event | {"hook_event_name": "PostToolUse", "tool_use_id": "wrong",
                            "tool_input": first, "tool_response": {"stdout": "private-output", "stderr": "private-error"}}
        self.assertIsNone(records.finish(post))
        post["tool_use_id"] = "call-1"
        result = records.finish(post)
        self.assertEqual("PostToolUse", result["hookEventName"])
        self.assertIsNone(result["interrupted"])
        self.assertIsNone(result["exitCode"])
        self.assertNotIn("private-", json.dumps(result))
        self.assertIsNone(records.finish(post))
        self.assertIsNone(records.issue("call-1", self.event["tool_input"], self.helper))

    def test_native_background_return_never_claims_process_success_or_cancellation(self):
        records = ENGINE.Records(self.root / "records", "fixture-session")
        issued = records.issue("call-1", self.event["tool_input"], self.helper)
        records.consume(issued["command"])
        post = self.event | {"hook_event_name": "PostToolUse", "tool_use_id": "call-1", "tool_input": issued,
                            "tool_response": {"stdout": "Command moved to background; exit 0 is not evidence", "stderr": "",
                                              "backgroundTaskId": "fixture", "timedOutAfterMs": 1000,
                                              "interrupted": False, "isImage": False, "noOutputExpected": False}}
        result = records.finish(post)
        self.assertEqual("PostToolUse", result["hookEventName"])
        self.assertNotIn("outcome", result)
        self.assertTrue(result["executionClaimed"])
        self.assertIs(result["interrupted"], False)
        self.assertIsNone(result["exitCode"])


if __name__ == "__main__":
    unittest.main()
