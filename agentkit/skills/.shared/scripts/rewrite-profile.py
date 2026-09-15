import hashlib
import json
import os
import re
import secrets
import shlex
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "hooks/lib"))
sys.dont_write_bytecode = True
sys.pycache_prefix = "/dev/null"
from rewrite_profile import (
    OPERATOR_HOME,
    TRUST_ROOT,
    Unavailable,
    canonical,
    check_environment,
    decode,
    fingerprint,
    native_input,
    private,
    private_parents,
    snapshot_identity,
)
from rewrite_runtime import command_environment


def reviewed_shell(snapshot, native, expected):
    snapshot, native = private(snapshot), private(native)
    if (hashlib.sha256(snapshot.read_bytes()).hexdigest() != expected["snapshot"]
            or hashlib.sha256(native.read_bytes()).hexdigest() != expected["native"]):
        raise Unavailable("changed reviewed audit bytes")
    template, path = snapshot_identity(snapshot.read_bytes())
    return {"snapshotTemplateSha256": template, "pathSha256": path,
            "nativeSetupSha256": native_input(native.read_text())[2]}


def compatibility(provider, events):
    messages = [decode(line) for line in Path(provider).read_text().splitlines()]
    initialization = [message for message in messages if message.get("type") == "system"
                      and message.get("subtype") == "init"]
    if (len(initialization) != 1 or initialization[0].get("plugins") != []
            or initialization[0].get("claude_code_version") != "2.1.272"):
        raise Unavailable("unapproved observed adapter")
    records = [decode(line) for line in Path(events).read_text().splitlines()]
    if len(records) != 2:
        raise Unavailable("missing adapter input/result compatibility evidence")
    before, after = records
    output = before.get("output", {}).get("hookSpecificOutput", {})
    original, replacement = before.get("input", {}), after.get("input", {})
    if (before.get("event") != "PreToolUse" or after.get("event") != "PostToolUse"
            or not before.get("id") or before["id"] != after.get("id")
            or not before.get("session") or before["session"] != after.get("session")
            or original.get("command") != "agent-run.sh --cmd test"
            or original.get("command") == replacement.get("command")
            or {key: value for key, value in original.items() if key != "command"}
            != {key: value for key, value in replacement.items() if key != "command"}
            or output != {"hookEventName": "PreToolUse", "updatedInput": replacement}
            or not isinstance(after.get("response"), dict)):
        raise Unavailable("unproven adapter input/result compatibility")


def validate_entry(manifest, entry, post):
    expected = {"nonce": manifest["nonce"], "cwd": manifest["cwd"], "argv": ["--cmd", "test"],
                "environment": "synthetic", "exitCode": 0}
    words = shlex.split(post["input"]["command"])
    stdout = post.get("response", {}).get("stdout", "")
    if (entry != expected or words != [manifest["helper"], "--cmd", "test"]
            or stdout.count("REWRITE-PROBE:" + manifest["nonce"]) != 1):
        raise Unavailable("missing reviewed target entry evidence")


def source_checksums(path):
    lines = Path(path).read_text().splitlines()
    if not 1 <= len(lines) <= 64:
        raise Unavailable("invalid probe source manifest")
    for line in lines:
        match = re.fullmatch(r"([a-f0-9]{64})  (/.*)", line)
        if match is None or hashlib.sha256(canonical(match[2]).read_bytes()).hexdigest() != match[1]:
            raise Unavailable("changed reviewed probe source")


def write_exclusive(path, text, mode=0o600):
    path = Path(path)
    canonical(path.parent)
    with os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode), "w") as output:
        output.write(text)


def session_settings(spec, profile_path, kit, python):
    prefix = "#!/bin/bash\nexec " + " ".join(map(shlex.quote, (
        str(python), "-I", str(kit / "hooks/lib/rewrite_runtime.py"), "prefix", str(profile_path)))) + ' "$@"\n'
    write_exclusive(spec["prefix"], prefix, 0o700)
    hooks = {}
    for event, filename in (("PreToolUse", "pre-tool-use.sh"), ("PostToolUse", "post-tool-use.sh"),
                            ("PostToolUseFailure", "post-tool-use.sh")):
        hooks[event] = [{"matcher": "Bash", "hooks": [{"type": "command", "timeout": 10,
                         "command": shlex.quote(str(kit / "hooks" / filename))}]}]
    write_exclusive(spec["settings"], json.dumps({"permissions": {"allow": spec["allow"]}, "hooks": hooks}))


def attest(path, expected_hash):
    path = private(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected_hash:
        raise Unavailable("specification was not reviewed at these bytes")
    spec = decode(path.read_text())
    check_environment(os.environ)
    kit = canonical(spec["kit"])
    if kit != Path(__file__).resolve().parents[3]:
        raise Unavailable("producer is outside the approved kit")
    python = canonical(spec["python"])
    if python != Path(sys.executable).resolve() or python != Path("/usr/bin/python3").resolve():
        raise Unavailable("unsupported validator interpreter")
    for name in ("prefix", "settings"):
        parent = private(Path(spec[name]).parent, directory=True)
        private_parents(parent, OPERATOR_HOME)
    shell = reviewed_shell(spec["auditSnapshot"], spec["auditNative"], spec["reviewedHashes"])
    compatibility(spec["provider"], spec["events"])
    events = [decode(line) for line in Path(spec["events"]).read_text().splitlines()]
    validate_entry(decode(Path(spec["manifest"]).read_text()), decode(Path(spec["execution"]).read_text()), events[1])
    source_checksums(spec["sources"])
    cli = canonical(spec["cli"])
    version = subprocess.run([str(cli), "--version"], capture_output=True, text=True, timeout=5, check=True)
    if version.stdout.strip() != "2.1.272 (Claude Code)":
        raise Unavailable("unsupported adapter or validator version")
    cwd = canonical(spec["cwd"])
    declaration = subprocess.run([str(kit / "skills/.shared/scripts/repo-config.sh"), "--repo-root", str(cwd),
                                  "--get-argv", "AGENT_CMD_TEST"], capture_output=True, timeout=5, check=True)
    if not declaration.stdout:
        raise Unavailable("missing declared verification command")
    TRUST_ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    private(TRUST_ROOT, directory=True)
    private_parents(TRUST_ROOT, OPERATOR_HOME)
    profile_path = TRUST_ROOT / (secrets.token_hex(16) + ".json")
    session_settings(spec, profile_path, kit, python)
    paths = {"code": kit / "hooks", "helperTree": kit / "skills", "helper": kit / "skills/.shared/scripts/agent-run.sh",
             "config": cwd / ".agent/config.env", "cli": cli, "python": python, "shell": Path("/bin/bash").resolve(),
             "producer": Path(__file__).resolve(), "spec": path}
    paths.update({name: canonical(spec[name]) for name in ("prefix", "settings", "provider", "events", "execution", "manifest", "sources")})
    profile = {"schemaVersion": 1, "adapter": "claude", "version": "2.1.272", "tool": "Bash", "approval": "operator-reviewed",
               "cwd": str(cwd), "snapshotRoot": str(canonical(spec["snapshotRoot"])), "shellInvocation": "/bin/bash",
               "commandEnvironmentSha256": command_environment(os.environ),
               "declarationSha256": hashlib.sha256(declaration.stdout).hexdigest(),
               "bindings": {name: {"path": str(value), "sha256": fingerprint(value)} for name, value in paths.items()}, **shell}
    write_exclusive(profile_path, json.dumps(profile, separators=(",", ":")))
    return profile_path


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "attest":
        raise SystemExit("usage: rewrite-profile.py attest SPEC REVIEWED_SPEC_SHA256")
    try:
        print(attest(sys.argv[2], sys.argv[3]))
    except (Unavailable, OSError, KeyError, TypeError, ValueError, subprocess.SubprocessError):
        raise SystemExit("agentkit: profile attestation unavailable") from None
