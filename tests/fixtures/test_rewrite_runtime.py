import importlib.util
import json
import os
import py_compile
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / "agentkit/hooks/lib/rewrite_runtime.py"
sys.path.insert(0, str(MODULE.parent))
SPEC = importlib.util.spec_from_file_location("rewrite_runtime", MODULE)
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class NativeRuntime(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=Path.home() / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repo"
        self.repository.mkdir()
        self.binary_directory = self.root / "bin"
        self.binary_directory.mkdir(mode=0o700)
        self.snapshot = self.root / "snapshot.sh"
        self.snapshot.write_text(f"unalias -a\nexport PATH={self.binary_directory}\n")
        self.snapshot.chmod(0o600)
        self.native = f"source {self.snapshot} 2>/dev/null || true && eval 'printf fixture' < /dev/null && pwd -P >| {self.root}/cwd"
        template, path = RUNTIME.snapshot_identity(self.snapshot.read_bytes())
        self.profile = {"cwd": str(self.repository), "snapshotRoot": str(self.root),
                        "snapshotTemplateSha256": template, "pathSha256": path,
                        "nativeSetupSha256": RUNTIME.native_input(self.native)[2]}

    def test_current_snapshot_native_envelope_and_environment_are_all_required(self):
        self.assertEqual("printf fixture", RUNTIME.evaluate_shell(self.profile, self.native, {})["command"])
        for environment in ({"BASH_FUNC_agent-run.sh%%": "private"}, {"BASH_ENV": "private"}):
            with self.assertRaises(RUNTIME.Unavailable):
                RUNTIME.evaluate_shell(self.profile, self.native, environment)
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.evaluate_shell(self.profile, self.native.replace("|| true", "|| false"), {})
        self.snapshot.write_text(self.snapshot.read_text() + "alias agent-run.sh='false'\n")
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.evaluate_shell(self.profile, self.native, {})

    def test_disappeared_snapshot_and_new_path_binding_never_fall_back_to_login_shell(self):
        helper = self.binary_directory / "agent-run.sh"
        helper.write_text("existing binding")
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.evaluate_shell(self.profile, self.native, {})
        helper.unlink()
        self.snapshot.unlink()
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.evaluate_shell(self.profile, self.native, {})

    def test_process_identity_reads_only_structural_ancestry_metadata(self):
        process = RUNTIME.process_identity(os.getpid())
        self.assertEqual(os.getppid(), process["parent"])
        self.assertEqual(Path(sys.executable).resolve(), Path(process["executable"]))
        self.assertTrue(process["startTime"].isdigit())
        self.assertNotIn("environment", process)

    def test_launch_requires_real_ancestor_and_exact_session_settings_and_prefix(self):
        prefix, settings, cli = (self.root / name for name in ("prefix", "settings.json", "cli"))
        profile = self.profile | {"shellInvocation": "/bin/bash", "bindings": {
            "prefix": {"path": str(prefix)}, "settings": {"path": str(settings)},
            "cli": {"path": str(cli)}}}
        environment = {"CLAUDE_CODE_SESSION_ID": "fixture-session", "CLAUDE_CODE_SHELL": "/bin/bash",
                       "CLAUDE_CODE_SHELL_PREFIX": str(prefix)}
        event = {"session_id": "fixture-session", "cwd": str(self.repository), "tool_name": "Bash"}
        ancestor = {"pid": 123, "parent": 1, "startTime": "456", "executable": str(cli)}
        arguments = [str(cli), "--restricted", "--tools", "Bash", "--settings", str(settings),
                     "--permission-mode", "manual", "--permission-prompts", "none"]
        with (patch.object(RUNTIME, "process_identity", return_value=ancestor),
              patch.object(RUNTIME, "process_arguments", return_value=arguments)):
            self.assertEqual(ancestor, RUNTIME.validate_launch(profile, environment, event))
            for changed in (environment | {"CLAUDE_CODE_SESSION_ID": "other-session"},
                            environment | {"CLAUDE_CODE_SHELL_PREFIX": "/other/prefix"},
                            environment | {"CLAUDE_CODE_SHELL": "/bin/zsh"}):
                with self.assertRaises(RUNTIME.Unavailable):
                    RUNTIME.validate_launch(profile, changed, event)
            for extra in ("--dangerously-skip-permissions", "--permission-mode=bypassPermissions",
                          "--settings=/repo/other.json", "--tools=Read,Bash", "--permission-prompts=stdio",
                          "--restricted=false", "--allowedTools=Bash", "--allowed-tools=Bash",
                          "--disallowedTools=Read", "--disallowed-tools=Read", "--plugin-url=fixture",
                          "--permission-prompt-tool=fixture", "--setting-sources=user", "--add-dir=/fixture",
                          "--bare", "--safe-mode"):
                arguments.append(extra)
                with self.assertRaises(RUNTIME.Unavailable):
                    RUNTIME.validate_launch(profile, environment, event)
                arguments.pop()
        with (patch.object(RUNTIME, "process_identity", return_value=ancestor | {"executable": "/other/cli"}),
              self.assertRaises(RUNTIME.Unavailable)):
            RUNTIME.validate_launch(profile, environment, event)

    def test_prefix_refuses_consumed_finished_and_unknown_nonce_replacements(self):
        helper = self.root / "agent-run.sh"
        helper.write_text("#!/bin/bash\nexit 0\n")
        helper.chmod(0o700)
        profile = self.profile | {"bindings": {"helper": {"path": str(helper)}}}
        records = RUNTIME.Records(self.root / "records", "fixture-session")
        first = records.issue("call-1", {"command": "agent-run.sh --cmd test"}, helper)

        def native(command):
            return self.native.replace("'printf fixture'", shlex.quote(command))

        for command in (str(helper) + " --cmd test", "printf '%s' " + shlex.quote(first["command"]),
                        "sh -c " + shlex.quote(first["command"])):
            self.assertIsNone(RUNTIME.authorize_execution(profile, records, native(command), {}))
        self.assertEqual("call-1", RUNTIME.authorize_execution(profile, records, native(first["command"]), {})["toolId"])
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.authorize_execution(profile, records, native(first["command"]), {})
        records.finish({"session_id": "fixture-session", "tool_name": "Bash", "tool_use_id": "call-1",
                        "hook_event_name": "PostToolUse", "tool_input": first})
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.authorize_execution(profile, records, native(first["command"]), {})
        expired = first["command"].rsplit("=", 1)[0] + "=" + "a" * 32
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.authorize_execution(profile, records, native(expired), {})

    def test_first_call_is_unchanged_and_current_observation_is_rechecked_before_claim(self):
        helper = self.root / "agent-run.sh"
        helper.write_text("#!/bin/bash\nexit 0\n")
        helper.chmod(0o700)
        profile = self.profile | {"bindings": {"helper": {"path": str(helper)}}}
        records = RUNTIME.Records(self.root / "records", "fixture-session")
        event = {"session_id": "fixture-session", "tool_use_id": "call-1", "tool_name": "Bash",
                 "hook_event_name": "PreToolUse", "cwd": str(self.repository),
                 "tool_input": {"command": "agent-run.sh --cmd test", "timeout": 10000}}
        self.assertIsNone(RUNTIME.prepare_rewrite(profile, records, event, {}))
        RUNTIME.observe_shell(profile, records, self.native, {})
        rewritten = RUNTIME.prepare_rewrite(profile, records, event, {})
        self.assertEqual(10000, rewritten["timeout"])
        with records.transaction() as data:
            self.assertNotIn("printf fixture", str(data))
        self.snapshot.write_text(self.snapshot.read_text() + "function agent-run.sh { false; }\n")
        with self.assertRaises(RUNTIME.Unavailable):
            RUNTIME.prepare_rewrite(profile, records, event | {"tool_use_id": "call-2"}, {})

    def test_isolated_hook_entrypoint_rejects_repository_profile_and_import_poisoning(self):
        (self.repository / "json.py").write_text("raise SystemExit('untrusted import')\n")
        fake = self.repository / "profile.json"
        fake.write_text('{"approval":"operator-reviewed"}')
        for payload in ("{", '{"tool_name":"Edit","tool_name":"Bash"}',
                        '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"agent-run.sh --cmd test"}}'):
            process = subprocess.run([sys.executable, "-I", str(MODULE), "pre"], input=payload,
                                     cwd=self.repository, env=os.environ | {"PYTHONPATH": str(self.repository),
                                         "AGENTKIT_REWRITE_PROFILE": str(fake)}, capture_output=True,
                                     text=True, check=False, timeout=5)
            self.assertEqual(0, process.returncode)
            self.assertEqual("{}", process.stdout.strip())
            self.assertNotIn("untrusted import", process.stderr)

    def test_public_prefix_refuses_direct_reserved_command_without_native_envelope(self):
        command = "/usr/bin/agent-run.sh --cmd test # agentkit-rewrite=" + "a" * 32
        process = subprocess.run([sys.executable, "-I", str(MODULE), "prefix",
                                  str(self.root / "missing-profile.json"), command],
                                 capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual(126, process.returncode)
        self.assertNotIn("command not found", process.stderr)

    def test_public_prefix_rejects_wrong_argument_count_without_hook_fallback(self):
        profile = str(self.root / "missing-profile.json")
        for arguments in ([], [profile], [profile, "printf first", "printf second"]):
            with self.subTest(arguments=arguments):
                process = subprocess.run([sys.executable, "-I", str(MODULE), "prefix", *arguments],
                                         input="{}", capture_output=True, text=True, check=False, timeout=5)
                self.assertEqual(126, process.returncode)
                self.assertEqual("", process.stdout)
                self.assertEqual("agentkit: rewrite execution unavailable\n", process.stderr)

    def test_isolated_entrypoint_ignores_matching_repository_bytecode_cache(self):
        code = self.root / "code"
        code.mkdir()
        for name in ("rewrite_runtime.py", "rewrite_profile.py", "tool_input_rewrite.py"):
            shutil.copyfile(MODULE.parent / name, code / name)
        source = code / "rewrite_profile.py"
        original, info = source.read_bytes(), source.stat()
        poison = b"raise SystemExit('untrusted bytecode')\n#"
        source.write_bytes(poison + b" " * (len(original) - len(poison)))
        os.utime(source, ns=(info.st_atime_ns, info.st_mtime_ns))
        cache = code / "__pycache__" / ("rewrite_profile." + sys.implementation.cache_tag + ".pyc")
        py_compile.compile(str(source), cfile=str(cache), doraise=True)
        source.write_bytes(original)
        os.utime(source, ns=(info.st_atime_ns, info.st_mtime_ns))
        process = subprocess.run([sys.executable, "-I", str(code / "rewrite_runtime.py"), "pre"],
                                 input="{}", capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual((0, "{}"), (process.returncode, process.stdout.strip()))
        self.assertNotIn("untrusted bytecode", process.stderr)

    def prefix_fixture(self, body):
        helper = self.root / "agent-run.sh"
        helper.write_text("#!/bin/bash\n" + body)
        helper.chmod(0o700)
        subprocess.run(["shellcheck", str(helper)], check=True, capture_output=True, timeout=5)
        profile = self.profile | {"bindings": {"helper": {"path": str(helper)}}}
        records = RUNTIME.Records(self.root / "records", "fixture-session")
        issued = records.issue("call-1", {"command": "agent-run.sh --cmd test", "timeout": 10000}, helper)
        spec = self.root / "prefix-fixture.json"
        spec.write_text(json.dumps({"profile": profile, "records": str(records.root)}))
        native = self.native.replace("'printf fixture'", shlex.quote(issued["command"]))
        return [sys.executable, "-I", str(Path(__file__).resolve()), "--prefix-fixture", str(spec), native]

    def test_public_prefix_executes_once_with_native_result_and_refuses_replay(self):
        command = self.prefix_fixture('printf "%s|%s|%s\\n" "$PWD" "$1" "$2"\nprintf stderr >&2\nexit 37\n')
        process = subprocess.run(command, cwd=self.repository, capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual(37, process.returncode)
        self.assertEqual(f"{self.repository}|--cmd|test\n", process.stdout)
        self.assertEqual("stderr", process.stderr)
        replay = subprocess.run(command, cwd=self.repository, capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual(126, replay.returncode)
        self.assertEqual("", replay.stdout)

    def test_prefix_refuses_replacement_when_native_cwd_changed_after_the_hook(self):
        command = self.prefix_fixture("printf wrong-scope\n")
        process = subprocess.run(command, cwd=self.root, capture_output=True, text=True, check=False, timeout=5)
        self.assertEqual(126, process.returncode)
        self.assertEqual("", process.stdout)

    def test_prefix_preserves_process_group_cancellation_without_running_orphan(self):
        pidfile = self.root / "helper-pid"
        command = self.prefix_fixture(f"printf '%s' \"$$\" > {shlex.quote(str(pidfile))}\nexec /bin/sleep 30\n")
        process = subprocess.Popen(command, cwd=self.repository, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 3
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(pidfile.exists(), "helper never entered")
            helper_pid = int(pidfile.read_text())
            os.killpg(process.pid, signal.SIGTERM)
            process.communicate(timeout=3)
            self.assertEqual(-signal.SIGTERM, process.returncode)
            path = Path("/proc") / str(helper_pid) / "stat"
            deadline = time.monotonic() + 1
            state = "unknown"
            while state not in {"Z", "absent"} and time.monotonic() < deadline:
                try:
                    state = path.read_text().rsplit(") ", 1)[1].split()[0]
                except (FileNotFoundError, ProcessLookupError):
                    state = "absent"
                if state not in {"Z", "absent"}:
                    time.sleep(0.01)
            self.assertIn(state, {"Z", "absent"})
        finally:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.communicate(timeout=3)


if __name__ == "__main__":
    if sys.argv[1:2] == ["--prefix-fixture"]:
        fixture = json.loads(Path(sys.argv[2]).read_text())
        fixture_records = RUNTIME.Records(fixture["records"], "fixture-session")
        with patch.object(RUNTIME, "context", return_value=(fixture["profile"], fixture_records)):
            try:
                RUNTIME.prefix("fixture-authority-at-process-edge", sys.argv[3])
            except RUNTIME.Unavailable:
                raise SystemExit(126) from None
    else:
        unittest.main()
