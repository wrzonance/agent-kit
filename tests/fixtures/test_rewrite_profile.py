import importlib.util
import json
import os
import shlex
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[2] / "agentkit/hooks/lib/rewrite_profile.py"
SPEC = importlib.util.spec_from_file_location("rewrite_profile", MODULE)
PROFILE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROFILE)


class Profiles(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir=Path.home() / ".cache")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        PROFILE.OPERATOR_HOME = self.root
        PROFILE.TRUST_ROOT = self.root / "operator-profiles"
        PROFILE.TRUST_ROOT.mkdir(mode=0o700)

    def test_duplicate_json_is_rejected_before_interpretation(self):
        for text in ('{"command":"false","command":"agent-run.sh --cmd test"}',
                     '{"tool_input":{},"tool_input":{"command":"agent-run.sh --cmd test"}}'):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.decode(text)

    def test_operator_parent_chain_cannot_be_redirected_or_shared_writable(self):
        parent = self.root / "cache"
        parent.mkdir(mode=0o700)
        child = parent / "profiles"
        child.mkdir(mode=0o700)
        PROFILE.private_parents(child, self.root)
        parent.chmod(0o777)
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.private_parents(child, self.root)
        parent.chmod(0o700)
        link = self.root / "linked"
        link.symlink_to(parent)
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.private_parents(link / "profiles", self.root)

    def test_repository_claim_cannot_be_an_operator_profile(self):
        path = self.root / "repo/.agent/rewrite-profile.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps({"approval": "operator-reviewed"}))
        path.chmod(0o600)
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.read_operator_profile(path)

    def test_profile_symlink_and_shared_permissions_are_rejected(self):
        real = PROFILE.TRUST_ROOT / "real.json"
        real.write_text('{}')
        link = PROFILE.TRUST_ROOT / "link.json"
        link.symlink_to(real)
        for path in (real, link):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.read_operator_profile(path)

    def test_snapshot_fingerprint_preserves_every_non_path_byte(self):
        snapshot = b"# fixture\nunalias -a\nexport PATH=/usr/bin:/bin\n"
        template, path = PROFILE.snapshot_identity(snapshot)
        changed_path = PROFILE.snapshot_identity(snapshot.replace(b"/usr/bin:/bin", b"/bin"))
        self.assertEqual(template, changed_path[0])
        self.assertNotEqual(path, changed_path[1])
        for addition in (b"alias agent-run.sh='false'\n", b"function command_not_found_handle { :; }\n",
                         b"function builtin { :; }\n", b"trap ':' DEBUG\n"):
            self.assertNotEqual(template, PROFILE.snapshot_identity(snapshot + addition)[0])

    def test_snapshot_never_evaluates_path_code_or_duplicate_declarations(self):
        for value in (b"export PATH=$(printf /bin)\n", b"export PATH=/bin\nexport PATH=/usr/bin\n",
                      b"export PATH=/bin:.\n", b"export PATH=/bin::/usr/bin\n"):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.snapshot_identity(value)

    def test_exported_functions_and_startup_scripts_invalidate_environment(self):
        for name in ("BASH_FUNC_agent-run.sh%%", "BASH_FUNC_builtin%%", "BASH_ENV", "ENV",
                     "CLAUDE_ENV_FILE", "SHELLOPTS", "BASHOPTS"):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.check_environment({name: "private-value"})
        PROFILE.check_environment({"PATH": "/bin", "TOKEN": "private-value"})

    def test_file_identity_rejects_replacement_and_symlink(self):
        source = self.root / "helper"
        source.write_text("before")
        original = PROFILE.fingerprint(source)
        source.write_text("after")
        self.assertNotEqual(original, PROFILE.fingerprint(source))
        link = self.root / "link"
        link.symlink_to(source)
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.fingerprint(link)

    def test_operator_profile_requires_current_content_bindings(self):
        helper = self.root / "helper"
        helper.write_text("trusted fixture")
        data = {"schemaVersion": 1, "adapter": "claude", "version": "2.1.272", "tool": "Bash",
                "approval": "operator-reviewed", "snapshotTemplateSha256": "a" * 64,
                "pathSha256": "b" * 64, "nativeSetupSha256": "c" * 64,
                "bindings": {"fixture": {"path": str(helper), "sha256": PROFILE.fingerprint(helper)}}}
        path = PROFILE.TRUST_ROOT / "fixture.json"
        path.write_text(json.dumps(data))
        path.chmod(0o600)
        self.assertEqual(data, PROFILE.read_operator_profile(path))
        helper.write_text("changed fixture")
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.read_operator_profile(path)

    def test_path_absence_rejects_every_existing_entry_and_unknown_access(self):
        directory = self.root / "bin"
        directory.mkdir(mode=0o700)
        repository = self.root / "repo"
        repository.mkdir()
        PROFILE.check_path_absence(str(directory), repository)
        helper = directory / "agent-run.sh"
        helper.write_text("not executable")
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.check_path_absence(str(directory), repository)
        helper.unlink()
        helper.mkdir()
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.check_path_absence(str(directory), repository)
        helper.rmdir()
        helper.symlink_to(directory / "missing")
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.check_path_absence(str(directory), repository)
        helper.unlink()
        directory.chmod(0)
        with self.assertRaises(PROFILE.Unavailable):
            PROFILE.check_path_absence(str(directory), repository)
        directory.chmod(0o700)
        with (patch.object(os, "lstat", side_effect=PermissionError("fixture access denial")),
              self.assertRaises(PROFILE.Unavailable)):
            PROFILE.check_path_absence(str(directory), repository)

    def test_path_absence_rejects_repository_relative_empty_and_linked_entries(self):
        repository = self.root / "repo"
        repository.mkdir()
        linked = self.root / "linked"
        linked.symlink_to(repository)
        for value in (str(repository), str(repository / "missing"), str(linked), ".", "",
                      "/usr/bin:", "/usr/bin::/bin"):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.check_path_absence(value, repository)
        PROFILE.check_path_absence(str(self.root / "genuinely-absent"), repository)

    def test_native_template_keeps_shell_quoting_and_operator_bytes(self):
        native = "source /private/snapshot.sh 2>/dev/null || true && eval 'printf hello' < /dev/null && pwd -P >| /private/cwd"
        source, command, digest = PROFILE.native_input(native)
        self.assertEqual("/private/snapshot.sh", source)
        self.assertEqual("printf hello", command)
        changed = native.replace("'printf hello'", shlex.quote("printf '%s' '# marker'"))
        self.assertEqual(digest, PROFILE.native_input(changed)[2])
        for altered in (native.replace(" || ", " '||' "), native.replace(" && ", "  && ", 1)):
            self.assertNotEqual(digest, PROFILE.native_input(altered)[2])
        for altered in (native + "; true", native.replace("'printf hello'", "$(printf hello)")):
            with self.assertRaises(PROFILE.Unavailable):
                PROFILE.native_input(altered)


if __name__ == "__main__":
    unittest.main()
