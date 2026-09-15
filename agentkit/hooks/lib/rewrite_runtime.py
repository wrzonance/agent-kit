import hashlib
import json
import os
import re
import shlex
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True
sys.pycache_prefix = "/dev/null"
from rewrite_profile import (
    TRUST_ROOT,
    Unavailable,
    canonical,
    check_environment,
    check_path_absence,
    decode,
    native_input,
    private,
    read_operator_profile,
    snapshot_identity,
    snapshot_path,
)
from tool_input_rewrite import Records, candidate


def evaluate_snapshot(profile, path, environment):
    check_environment(environment)
    try:
        path = canonical(path)
        info = path.stat()
        if (path.parent != Path(profile["snapshotRoot"]) or not stat.S_ISREG(info.st_mode)
                or info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_size > 1048576):
            raise Unavailable("untrusted current snapshot")
        snapshot = path.read_bytes()
        if snapshot_identity(snapshot) != (profile["snapshotTemplateSha256"], profile["pathSha256"]):
            raise Unavailable("changed current snapshot")
        check_path_absence(snapshot_path(snapshot)[1], profile["cwd"])
    except OSError as error:
        raise Unavailable("unavailable current snapshot") from error


def evaluate_shell(profile, native, environment):
    snapshot, command, setup = native_input(native)
    if setup != profile["nativeSetupSha256"]:
        raise Unavailable("changed native setup")
    evaluate_snapshot(profile, snapshot, environment)
    return {"snapshot": snapshot, "command": command}


def process_identity(pid):
    root = Path("/proc") / str(pid)
    fields = (root / "stat").read_text().rsplit(") ", 1)[1].split()
    return {"pid": pid, "parent": int(fields[1]), "startTime": fields[19],
            "executable": str((root / "exe").resolve(strict=True))}


def process_arguments(pid):
    return (Path("/proc") / str(pid) / "cmdline").read_bytes().decode().rstrip("\0").split("\0")


def validate_launch(profile, environment, event=None):
    check_environment(environment)
    session = environment.get("CLAUDE_CODE_SESSION_ID", "")
    if (not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", session)
            or environment.get("CLAUDE_CODE_SHELL") != profile["shellInvocation"]
            or environment.get("CLAUDE_CODE_SHELL_PREFIX") != profile["bindings"]["prefix"]["path"]):
        raise Unavailable("unapproved launch environment")
    if event is not None and (event.get("session_id"), event.get("cwd"), event.get("tool_name")) != (
        session, profile["cwd"], "Bash"
    ):
        raise Unavailable("mismatched tool session")
    pid = os.getppid()
    for _ in range(16):
        process = process_identity(pid)
        if process["executable"] == profile["bindings"]["cli"]["path"]:
            arguments = process_arguments(process["pid"])
            options = [argument.split("=", 1)[0] for argument in arguments]
            required = {"--tools": "Bash", "--settings": profile["bindings"]["settings"]["path"],
                        "--permission-mode": "manual", "--permission-prompts": "none"}
            if options.count("--restricted") != 1 or "--restricted" not in arguments or any(argument.split("=", 1)[0] in {
                "--dangerously-skip-permissions", "--allow-dangerously-skip-permissions", "--plugin-dir",
                "--plugin-url", "--allowedTools", "--allowed-tools", "--disallowedTools", "--disallowed-tools",
                "--permission-prompt-tool", "--setting-sources", "--add-dir", "--bare", "--safe-mode"
            } for argument in arguments):
                raise Unavailable("unsupported CLI permission policy")
            for name, value in required.items():
                if options.count(name) != 1 or name not in arguments or arguments[arguments.index(name) + 1:arguments.index(name) + 2] != [value]:
                    raise Unavailable("unapproved CLI settings")
            return process
        if process["parent"] <= 1:
            break
        pid = process["parent"]
    raise Unavailable("no approved adapter ancestor")


def authorize_execution(profile, records: Records, native, environment):
    _, command, _ = native_input(native)
    prefix = shlex.quote(profile["bindings"]["helper"]["path"]) + " --cmd test # agentkit-rewrite="
    reserved = command.startswith(prefix) and re.fullmatch(r"[a-f0-9]{32}", command[len(prefix):])
    with records.transaction() as data:
        known = any(record.get("transformed") == command for record in data["results"])
        known = known or (data["pending"] is not None and data["pending"].get("transformed") == command)
    if not known and not reserved:
        return None
    evaluate_shell(profile, native, environment)
    claim = records.consume(command)
    if claim is None:
        raise Unavailable("missing or consumed execution claim")
    return claim


def observe_shell(profile, records: Records, native, environment):
    try:
        observation = evaluate_shell(profile, native, environment)
        observation.pop("command")
    except Unavailable:
        observation = None
    with records.transaction() as data:
        data["observation"] = observation


def prepare_rewrite(profile, records: Records, event, environment):
    helper = profile["bindings"]["helper"]["path"]
    if candidate(event, helper, "0" * 32) is None:
        return None
    with records.transaction() as data:
        observation = data.get("observation")
    if not observation:
        return None
    evaluate_snapshot(profile, observation["snapshot"], environment)
    return records.issue(event.get("tool_use_id"), event["tool_input"], helper)


def command_environment(environment):
    selected = {key: value for key, value in environment.items()
                if key.startswith(("AGENT_CMD_", "AGENT_RUNDIR_", "AGENT_VERIFY_")) or key == "AGENT_REPO_RUNNER"}
    return hashlib.sha256(json.dumps(selected, sort_keys=True).encode()).hexdigest()


def context(path, event=None):
    profile = read_operator_profile(path)
    bindings = profile["bindings"]
    required = {"code", "helperTree", "helper", "config", "cli", "shell", "python", "settings", "prefix", "producer", "provider", "events", "spec", "execution", "manifest", "sources"}
    if set(bindings) != required or not re.fullmatch(r"[a-f0-9]{32}", Path(path).stem):
        raise Unavailable("incomplete producer bindings")
    code = Path(__file__).resolve().parent.parent
    expected = {"code": code, "producer": code.parent / "skills/.shared/scripts/rewrite-profile.py",
                "python": Path(sys.executable).resolve(), "shell": Path("/bin/bash").resolve(),
                "helper": Path(bindings["helperTree"]["path"]) / ".shared/scripts/agent-run.sh",
                "config": canonical(profile["cwd"]) / ".agent/config.env"}
    if any(bindings[name]["path"] != str(value) for name, value in expected.items()):
        raise Unavailable("changed canonical producer lineage")
    if profile.get("commandEnvironmentSha256") != command_environment(os.environ):
        raise Unavailable("changed command configuration environment")
    process = validate_launch(profile, os.environ, event)
    session = os.environ["CLAUDE_CODE_SESSION_ID"]
    root = TRUST_ROOT.parent / "sessions"
    for part in (None, Path(path).stem, hashlib.sha256(session.encode()).hexdigest()):
        root = root if part is None else root / part
        root.mkdir(mode=0o700, exist_ok=True)
        private(root, directory=True)
    records = Records(root, session)
    with records.transaction() as data:
        if data.get("process", process) != process:
            raise Unavailable("stale adapter process")
        data["process"] = process
    return profile, records


def reserved_command(command):
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    return (len(words) == 5 and words[0].startswith("/") and words[0].endswith("/agent-run.sh")
            and words[1:4] == ["--cmd", "test", "#"]
            and re.fullmatch(r"agentkit-rewrite=[a-f0-9]{32}", words[4])
            and command == f"{shlex.quote(words[0])} --cmd test # {words[4]}")


def prefix(path, native):
    code = Path(__file__).resolve().parent.parent
    hooks = {shlex.quote(str(code / name)) for name in ("pre-tool-use.sh", "post-tool-use.sh")}
    if native not in hooks:
        try:
            profile, records = context(path)
            if Path.cwd() != Path(profile["cwd"]):
                raise Unavailable("changed native working directory")
            claim = authorize_execution(profile, records, native, os.environ)
            if claim is None:
                observe_shell(profile, records, native, os.environ)
        except (Unavailable, OSError, KeyError, TypeError, ValueError):
            try:
                command = native_input(native)[1]
            except Unavailable:
                raise Unavailable("unapproved native invocation") from None
            if reserved_command(command):
                raise Unavailable("rewrite execution validation failed") from None
    os.execv("/bin/bash", ["/bin/bash", "-c", native])


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "prefix":
        try:
            prefix(sys.argv[2], sys.argv[3])
        except (Unavailable, OSError):
            print("agentkit: rewrite execution unavailable", file=sys.stderr)
            return 126
    output = {}
    try:
        event = decode(sys.stdin.read())
        profile, records = context(os.environ.get("AGENTKIT_REWRITE_PROFILE", ""), event)
        if sys.argv[1:] == ["pre"]:
            replacement = prepare_rewrite(profile, records, event, os.environ)
            if replacement is not None:
                output = {"hookSpecificOutput": {"hookEventName": "PreToolUse", "updatedInput": replacement}}
        elif sys.argv[1:] == ["post"]:
            records.finish(event)
    except (Unavailable, OSError, KeyError, TypeError, ValueError, AttributeError):
        output = {}
    print(json.dumps(output, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
