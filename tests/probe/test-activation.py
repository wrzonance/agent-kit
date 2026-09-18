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
        manifest = self.plugin / ".claude-plugin/plugin.json"
        data = json.loads(manifest.read_text())
        data["version"] = "0.8.1"
        manifest.write_text(json.dumps(data))
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

    def linked_worktree(self):
        subprocess.run(["git", "-C", str(self.repo), "config", "user.name", "test"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "config", "user.email", "test@example.invalid"], check=True)
        (self.repo / "seed").write_text("seed\n")
        subprocess.run(["git", "-C", str(self.repo), "add", "seed"], check=True)
        subprocess.run(["git", "-C", str(self.repo), "commit", "-qm", "seed"], check=True)
        target = self.root / "linked-worktree"
        subprocess.run(["git", "-C", str(self.repo), "worktree", "add", "-q", "-b", "linked", str(target)], check=True)
        return target

    def test_unknown_is_not_active(self):
        result = self.check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("no receipt at activation origin", result.stderr)
        self.assertIn("invoke parallel-issues in that checkout", result.stderr)

    def test_failed_activation_helper_does_not_block_ordinary_prompt(self):
        self.helper.rename(self.helper.with_name("workflow-activation.disabled"))
        self.payload["prompt"] = "hello"
        result = subprocess.run([str(self.hook)], input=json.dumps(self.payload),
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})

    def test_failed_helper_keeps_ordinary_run_request_available(self):
        self.helper.rename(self.helper.with_name("workflow-activation.disabled"))
        self.payload["prompt"] = "run the unit tests"
        self.assertEqual(self.prompt(), {})

    def test_missing_or_corrupt_classifier_preserves_chat_and_blocks_selectors(self):
        library = self.helper.parent / "lib/workflow-activation.py"
        original = library.read_bytes()
        for failure in ("missing", "corrupt"):
            if failure == "missing":
                library.unlink()
            else:
                library.write_text("invalid python syntax !")
            for prompt in ("hello", "run the unit tests", "$other:skill", "/help",
                           "$agentkit:parallel-issues", "/pr-to-green", "/review-pr", "$agentkit:unknown"):
                with self.subTest(failure=failure, prompt=prompt):
                    self.payload["prompt"] = prompt
                    output = self.prompt()
                    if prompt.startswith(("$agentkit:", "/pr-to-green", "/review-pr")):
                        self.assertEqual(output.get("decision"), "block")
                    else:
                        self.assertEqual(output, {})
            library.write_bytes(original)

    def test_missing_python_preserves_chat_and_blocks_selector(self):
        commands = self.root / "without-python"
        commands.mkdir()
        for name in ("bash", "cat", "dirname", "jq"):
            (commands / name).symlink_to(shutil.which(name))
        for prompt in ("hello", "$agentkit:parallel-issues"):
            with self.subTest(prompt=prompt):
                result = subprocess.run([str(self.hook)],
                                        input=json.dumps(dict(self.payload, prompt=prompt)),
                                        text=True, capture_output=True, cwd=self.repo,
                                        env={"PATH": str(commands)})
                self.assertEqual(result.returncode, 0, result.stderr)
                output = json.loads(result.stdout)
                if prompt == "hello":
                    self.assertEqual(output, {})
                else:
                    self.assertEqual(output.get("decision"), "block")

    def test_failed_activation_helper_blocks_workflow_invocation(self):
        self.helper.rename(self.helper.with_name("workflow-activation.disabled"))
        self.payload["prompt"] = "  $agentkit:parallel-issues 722"
        result = subprocess.run([str(self.hook)], input=json.dumps(self.payload),
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["decision"], "block")
        self.assertIn("activation-unavailable", output["reason"])

    def test_failed_activation_helper_blocks_native_and_unregistered_agentkit_forms(self):
        self.helper.rename(self.helper.with_name("workflow-activation.disabled"))
        for prompt in ("/pr-to-green --auto-merge", "$agentkit:unknown"):
            with self.subTest(prompt=prompt):
                result = subprocess.run([str(self.hook)], input=json.dumps(dict(self.payload, prompt=prompt)),
                                        text=True, capture_output=True, cwd=self.repo)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout)["decision"], "block")

    def test_malformed_hook_input_fails_closed_as_unknown(self):
        result = subprocess.run([str(self.hook)], input="{", text=True,
                                capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        output = json.loads(result.stdout)
        self.assertEqual(output["decision"], "block")
        self.assertIn("could not be classified safely", output["reason"])

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
        self.assertIn("no receipt at activation origin", result.stderr)
        self.assertIn("invoke parallel-issues in that checkout", result.stderr)
        result = self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                             "--skill", "parallel-issues", "--nonce", "bad")
        self.assertNotEqual(result.returncode, 0)

    def test_origin_receipt_authorizes_only_linked_target(self):
        self.prompt()
        self.assertEqual(self.acknowledge().returncode, 0)
        target = self.linked_worktree()
        for checked_target in (self.repo, target, target):
            with self.subTest(target=checked_target):
                result = self.check("--target-root", str(checked_target))
                self.assertEqual(result.returncode, 0, result.stderr)

        unrelated = self.root / "unrelated"
        subprocess.run(["git", "init", "-q", str(unrelated)], check=True)
        result = self.check("--target-root", str(unrelated))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("activation-target-mismatch", result.stderr)
        self.assertIn("create or resume a linked worktree", result.stderr)

    def test_preflight_reads_origin_receipt_and_measures_linked_target(self):
        self.prompt()
        self.assertEqual(self.acknowledge().returncode, 0)
        target = self.linked_worktree()
        result = subprocess.run([str(self.helper.parent / "agent-preflight.sh"),
                                 "--worktree", str(target), "--ensure",
                                 "--activation-origin", str(self.repo),
                                 "--activation-session", "test-session",
                                 "--workflow", "parallel-issues"],
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("worktree=" + str(target), result.stdout)
        self.assertNotIn("worktree=" + str(self.repo) + "\n", result.stdout)

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
        self.assertIn("invocation boundary", self.prompt()["hookSpecificOutput"]["additionalContext"])
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

    def public_event(self, event, **fields):
        script = {"SessionStart": "session-start.sh", "PreToolUse": "pre-tool-use.sh"}[event]
        result = subprocess.run([str(self.plugin / "hooks" / script)],
                                input=json.dumps(dict(self.payload, hook_event_name=event, **fields)),
                                text=True, capture_output=True, cwd=self.repo)
        self.assertEqual(result.returncode, 0, result.stderr)
        return json.loads(result.stdout)

    def test_upgrade_resume_redelivers_and_preserves_saved_state(self):
        self.prompt()
        self.acknowledge()
        old = self.record()
        saved = self.repo / ".agent/saved-run.json"
        saved.write_text('{"prs":[271,272],"reviews":"preserve"}')
        body = self.plugin / "skills/parallel-issues/SKILL.md"
        body.write_text(body.read_text() + "\nUpdated workflow content.\n")
        output = self.public_event("SessionStart", source="resume")
        self.assertIn("resume", json.dumps(output))
        self.assertIn("$agentkit:parallel-issues", json.dumps(output))
        self.assertNotEqual(self.check().returncode, 0)
        self.payload["prompt"] = "$agentkit:parallel-issues --yolo --fast-mode"
        self.assertIn("Updated workflow content", json.dumps(self.prompt()))
        self.assertEqual(self.record()["status"], "pending")
        self.assertNotEqual(old["nonce"], self.record()["nonce"])
        denied = self.public_event("PreToolUse", tool_name="Agent", tool_input={"prompt": "run"})
        self.assertEqual(denied["hookSpecificOutput"]["permissionDecision"], "deny")
        stale = self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                            "--skill", "parallel-issues", "--nonce", old["nonce"])
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(self.acknowledge().returncode, 0)
        self.assertEqual(saved.read_text(), '{"prs":[271,272],"reviews":"preserve"}')

    def test_stale_leaf_receipt_hands_back_once_and_root_redelivers_to_same_worker(self):
        self.prompt()
        self.assertEqual(self.acknowledge().returncode, 0)
        old = self.record()
        saved = self.repo / ".agent/worker-edit.txt"
        saved.write_text("unpublished worker change\n")
        body = self.plugin / "skills/parallel-issues/SKILL.md"
        body.write_text(body.read_text() + "\nSame-version recovery content.\n")

        denied = self.public_event("PreToolUse", tool_name="Agent", tool_input={"prompt": "continue"})
        reason = denied["hookSpecificOutput"]["permissionDecisionReason"]
        marker = "agentkit activation-blocked: "
        self.assertEqual(reason.count(marker), 1)
        handback = json.loads(reason.split(marker, 1)[1].splitlines()[0])
        self.assertEqual(handback["schemaVersion"], 1)
        self.assertEqual(handback["session"], "test-session")
        self.assertEqual(handback["worktree"], str(self.repo))
        self.assertEqual(handback["workflow"], "parallel-issues")
        self.assertEqual(handback["installed"]["version"], handback["received"]["version"])
        self.assertNotEqual(handback["installed"]["digest"], handback["received"]["digest"])
        self.assertNotIn("nonce", json.dumps(handback).lower())

        before_wrong_workflow = self.record()
        wrong_workflow = self.invoke("redeliver", "--repo-root", handback["worktree"],
                                     "--session", handback["session"],
                                     "--skill", "pr-to-green")
        self.assertNotEqual(wrong_workflow.returncode, 0)
        self.assertEqual(self.record(), before_wrong_workflow)

        delivery = self.invoke("redeliver", "--repo-root", handback["worktree"],
                               "--session", handback["session"],
                               "--skill", handback["workflow"])
        self.assertEqual(delivery.returncode, 0, delivery.stderr)
        self.assertIn("Same-version recovery content", delivery.stdout)
        refreshed = self.record()
        self.assertEqual(refreshed["deliverySource"], "root-redelivery")
        self.assertEqual(refreshed["status"], "pending")
        self.assertNotEqual(refreshed["nonce"], old["nonce"])
        stale = self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                            "--skill", "parallel-issues", "--nonce", old["nonce"])
        self.assertNotEqual(stale.returncode, 0)
        self.assertEqual(self.acknowledge().returncode, 0)
        resumed = self.public_event("PreToolUse", tool_name="Agent", tool_input={"prompt": "continue"})
        self.assertNotEqual(resumed.get("hookSpecificOutput", {}).get("permissionDecision"), "deny")
        self.assertEqual(saved.read_text(), "unpublished worker change\n")

    def test_advertised_invocations_deliver_fresh_challenges(self):
        cases = {
            "Resume HonkHonk’s saved parallel-issues run using Agent Kit 0.9.1 with --yolo": "parallel-issues",
            "run these issues in parallel": "parallel-issues",
            "parallel workstreams": "parallel-issues",
            "work on multiple issues at once": "parallel-issues",
            "ultracode these issues": "parallel-issues",
            "skip brainstorming and just dispatch": "parallel-issues",
            "groom the board and go": "parallel-issues",
            "take these PRs to green": "pr-to-green",
            "finish the draft PR queue": "pr-to-green",
            "review remote PR 42": "review-remote-pr",
            "babysit PR 42": "review-remote-pr",
            "/review-pr 42": "review-remote-pr",
            "onboard this repo": "onboard-repo",
            "set up agentkit here": "onboard-repo",
            "yes, onboard it": "onboard-repo",
            "why are the guards inert": "onboard-repo",
            "why are the guards inert?": "onboard-repo",
            "declare the verify commands": "onboard-repo",
        }
        for prompt, workflow in cases.items():
            with self.subTest(prompt=prompt):
                self.payload.update(prompt=prompt, session_id="natural-" + workflow)
                output = self.prompt()
                self.assertIn("invocation boundary", json.dumps(output))
                self.assertIn("--skill " + workflow, json.dumps(output))

    def test_reports_quotes_and_negation_do_not_activate(self):
        for prompt in ('"run these issues in parallel"', 'Do not resume parallel-issues',
                       'Explain how to resume parallel-issues',
                       'Reported: Resume parallel-issues', '```\n/parallel-issues\n```',
                       'Resume the report about "parallel-issues"',
                       'Resume the report about parallel-issues',
                       'Resume parallel-issues? No, do not run it.'):
            with self.subTest(prompt=prompt):
                self.payload["prompt"] = prompt
                self.assertEqual(self.prompt(), {})

    def test_ambiguous_workflow_request_preserves_existing_receipt(self):
        self.prompt()
        before = self.record()
        self.payload["prompt"] = "resume parallel-issues and pr-to-green"
        self.assertIn("competing-workflow", json.dumps(self.prompt()))
        self.assertEqual(self.record(), before)

    def test_unicode_negation_preserves_active_workflow(self):
        self.prompt()
        self.assertEqual(self.acknowledge().returncode, 0)
        before = self.record()
        self.payload["prompt"] = "resume pr-to-green but don’t merge anything"
        self.assertEqual(self.prompt(), {})
        self.assertEqual(self.record(), before)

    def test_explicit_selector_precedes_attached_workflow_mentions(self):
        for selector in ("$agentkit:parallel-issues", "/parallel-issues"):
            with self.subTest(selector=selector):
                self.payload["prompt"] = selector + " 57 54 — issue text mentions pr-to-green"
                self.assertIn("--skill parallel-issues", json.dumps(self.prompt()))
                self.assertEqual(self.record()["workflow"], "parallel-issues")

    def test_pending_upgrade_resume_does_not_offer_stale_ack(self):
        self.prompt()
        old = self.record()
        (self.plugin / "skills/parallel-issues/SKILL.md").write_text("changed pending content")
        output = self.public_event("SessionStart", source="resume")
        self.assertIn("$agentkit:parallel-issues", json.dumps(output))
        self.assertNotIn(old["nonce"], json.dumps(output))
        self.assertEqual(self.record(), old)

    def test_stale_diagnostic_reads_and_searches_are_bounded(self):
        self.prompt()
        self.acknowledge()
        (self.plugin / "skills/parallel-issues/SKILL.md").write_text("changed")
        source = self.repo / "activation-source.py"
        source.write_text("activation diagnosis")
        saved = self.repo / ".agent/saved.json"
        saved.write_text("saved review evidence")
        escaped = self.repo / "escape"
        escaped.symlink_to(self.root)
        for command in ("cat " + str(source), "cat " + str(saved),
                        "rg --no-config --files " + str(self.repo),
                        "rg --no-config -n -- activation " + str(source)):
            with self.subTest(command=command):
                output = self.public_event("PreToolUse", tool_name="Bash", tool_input={"command": command})
                self.assertNotEqual(output.get("hookSpecificOutput", {}).get("permissionDecision"), "deny")
        for command in ("rg --pre touch activation " + str(source),
                        "rg --no-config --files " + str(self.root),
                        "rg --no-config --files " + str(escaped),
                        "rg --no-config --files --follow " + str(self.repo),
                        "rg -n -- activation " + str(source),
                        "cat " + str(source) + " > " + str(saved),
                        "cat " + str(escaped / "plugin/.claude-plugin/plugin.json"),
                        "rg --no-config -n -- activation " + str(self.repo),
                        "cat " + str(source) + " #\ntouch " + str(saved)):
            with self.subTest(command=command):
                output = self.public_event("PreToolUse", tool_name="Bash", tool_input={"command": command})
                self.assertEqual(output["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_natural_invocation_fails_closed_when_helper_missing(self):
        self.helper.rename(self.helper.with_name("workflow-activation.disabled"))
        self.payload["prompt"] = "resume saved parallel-issues run"
        self.assertEqual(self.prompt()["decision"], "block")

    def test_relocation_and_version_upgrade_require_new_receipt(self):
        self.prompt()
        self.acknowledge()
        old = self.record()
        relocated = self.root / "plugin-upgraded"
        shutil.copytree(self.plugin, relocated)
        self.plugin = relocated
        self.helper = relocated / "skills/.shared/scripts/workflow-activation.sh"
        self.hook = relocated / "hooks/user-prompt-submit.sh"
        self.assertNotEqual(self.check().returncode, 0)
        self.assertIn("invocation boundary", json.dumps(self.prompt()))
        self.assertNotEqual(old["nonce"], self.record()["nonce"])
        self.assertEqual(self.acknowledge().returncode, 0)
        manifest = relocated / ".claude-plugin/plugin.json"
        manifest.write_text(json.dumps({"version": "0.9.2"}))
        self.assertIn("invocation boundary", json.dumps(self.prompt()))
        self.assertEqual(self.record()["status"], "pending")
        self.assertEqual(self.acknowledge().returncode, 0)

    def test_competing_invocation_rotates_pending_and_session_isolation(self):
        self.prompt()
        self.acknowledge()
        original = self.record()
        self.payload["session_id"] = "new-session"
        self.assertIn("invocation boundary", json.dumps(self.prompt()))
        self.assertEqual(self.check().returncode, 0)
        self.payload.update(session_id="test-session", prompt="/pr-to-green")
        self.assertIn("invocation boundary", json.dumps(self.prompt()))
        self.assertNotEqual(self.check().returncode, 0)
        result = self.invoke("ack", "--repo-root", str(self.repo), "--session", "test-session",
                             "--skill", "parallel-issues", "--nonce", original["nonce"])
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
