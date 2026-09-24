"""Session receipt protocol, not a native registry attestation.

UserPromptSubmit delivers a random challenge together with workflow bytes.
Only the response promotes pending delivery to acknowledged session receipt.
Capabilities describe observed hook events, never inferred registration.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import stat
import subprocess
import sys
import tempfile

WORKFLOWS = {"parallel-issues", "pr-to-green", "review-remote-pr", "onboard-repo"}


class Unavailable(Exception):
    pass


class ContentMismatch(Unavailable):
    pass


def select_workflow(prompt):
    """Recognize direct requests, not workflow names embedded in reports."""
    match = re.match(r"^\s*[$/]((?:agentkit:)?[a-z][a-z0-9-]*)(?=\s|$)", prompt)
    if match:
        token = match[1].removeprefix("agentkit:")
        token = "review-remote-pr" if token == "review-pr" else token
        return token if token in WORKFLOWS or match[1].startswith("agentkit:") else None
    text = prompt.strip().lower()
    if text == "why are the guards inert?":
        text = text[:-1]
    # Deliberately conservative: ambiguous prose can use the documented selector.
    if re.search(r'["`\n\r?]|\b(?:not|never|don[\x27’]t|do not)\b', text):
        return None
    text = re.sub(r"^please\s+", "", text)
    phrases = {
        "parallel-issues": ("run these issues in parallel", "parallel workstreams",
                            "work on multiple issues at once", "ultracode these issues",
                            "skip brainstorming and just dispatch", "groom the board and go"),
        "pr-to-green": ("take these prs to green", "finish the draft pr queue"),
        "review-remote-pr": ("review remote pr", "babysit pr"),
        "onboard-repo": ("onboard this repo", "set up agentkit here", "yes, onboard it",
                         "why are the guards inert", "declare the verify commands"),
    }
    for workflow, triggers in phrases.items():
        if any(re.match(re.escape(phrase) + r"(?=\s|[.!]|$)", text) for phrase in triggers):
            return workflow
    match = re.match(r"^(?:resume|continue|run|use)\s+(?:[\w-]+[’']s\s+)?"
                     r"(?:(?:the|my|our|saved|existing|agentkit)\s+){0,3}"
                     r"(?:agentkit:)?(parallel-issues|pr-to-green|review-remote-pr|onboard-repo)"
                     r"(?=\s|$)", text)
    return match[1] if match else None


def mismatch(args, record, reason):
    workflow = record.get("workflow")
    selector = "$agentkit:" + (workflow if workflow in WORKFLOWS else "parallel-issues")
    version = identity(args)
    handback = {"schemaVersion": 1, "kind": "activation-blocked",
                "session": record.get("session"), "worktree": record.get("repoRoot"),
                "workflow": workflow,
                "installed": {"version": version, "digest": args.digest},
                "received": {"version": record.get("version"),
                             "digest": record.get("installedDigest")}}
    raise ContentMismatch("agentkit: activation-mismatch: " + reason
                          + "\nagentkit activation-blocked: " + json.dumps(handback, sort_keys=True)
                          + "\nLeaf: return that handback once to the owning root and stop probing; do not invoke "
                          + "an orchestration workflow. Root: validate it against the dispatch, then redeliver "
                          + "current bytes to the same worker context. Otherwise submit " + selector
                          + " in this conversation, then acknowledge the fresh challenge. "
                          + "Restarting the client and resuming this conversation retains its receipt; "
                          + "a new session needs its own invocation and acknowledgement. Saved work is preserved. "
                          + "Diagnosis: cat /absolute/file; rg --no-config -n -- pattern /absolute/file "
                          + "(up to four regular files); rg --no-config --files /absolute/directory. "
                          + "Paths must stay in this repository or installed skills tree; no shell expressions.")


def fail(reason):
    raise Unavailable("agentkit: " + reason)


def checked(path, directory=False):
    info = path.lstat()
    if (stat.S_ISLNK(info.st_mode) or info.st_uid != os.getuid()
            or info.st_mode & 0o022
            or not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode))):
        fail("activation-unavailable: unsafe evidence path " + str(path))


class Evidence:
    def __init__(self, root, session, create=False):
        if not session or len(session) > 256:
            fail("activation-unavailable: missing session identity")
        self.root = Path(root).resolve(strict=True)
        self.session = session
        # Explicit repository scope, no search through home or sibling trees.
        result = subprocess.run(["git", "-C", str(self.root), "rev-parse", "--show-toplevel"],
                                capture_output=True, text=True, check=False)
        if result.returncode or not result.stdout.strip():
            fail("activation-unavailable: cwd must be in a repository")
        self.root = Path(result.stdout.strip()).resolve(strict=True)
        directory = self.root / ".agent"
        for part in (directory, directory / "activation"):
            if create and not part.exists() and not part.is_symlink():
                part.mkdir(mode=0o700)
            checked(part, directory=True)
        self.path = directory / "activation" / (hashlib.sha256(session.encode()).hexdigest() + ".json")
        tracked = subprocess.run(["git", "-C", str(self.root), "ls-files", "--", str(self.path)],
                                 capture_output=True, text=True, check=False)
        if tracked.returncode or tracked.stdout:
            fail("activation-unavailable: evidence must be untracked")

    def read(self):
        checked(self.path)
        record = json.loads(self.path.read_text())
        if (record.get("schemaVersion") != 1 or record.get("session") != self.session
                or record.get("repoRoot") != str(self.root)):
            fail("activation-unavailable: evidence identity mismatch")
        return record

    def write(self, record):
        if self.path.exists() or self.path.is_symlink():
            checked(self.path)
        fd, name = tempfile.mkstemp(prefix=".activation-", dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(record, handle, sort_keys=True)
                handle.write("\n")
            os.replace(name, self.path)
        finally:
            if os.path.exists(name):
                os.unlink(name)


def validate_target(origin, target):
    """Bind a receipt origin to the checkout being prepared."""
    try:
        target = Path(target).resolve(strict=True)
    except OSError:
        fail("activation-target-unavailable: target checkout is missing; create or resume the linked worktree, then retry")
    result = subprocess.run(["git", "-C", str(target), "rev-parse", "--show-toplevel"],
                            capture_output=True, text=True, check=False)
    if result.returncode or not result.stdout.strip():
        fail("activation-target-unavailable: target is not a repository checkout; create or resume the linked worktree, then retry")
    target = Path(result.stdout.strip()).resolve(strict=True)

    def common_directory(root):
        common = subprocess.run(["git", "-C", str(root), "rev-parse", "--git-common-dir"],
                                capture_output=True, text=True, check=False)
        if common.returncode or not common.stdout.strip():
            fail("activation-unavailable: could not identify receipt origin repository")
        path = Path(common.stdout.strip())
        return (path if path.is_absolute() else root / path).resolve(strict=True)

    if common_directory(origin) != common_directory(target):
        fail("activation-target-mismatch: target belongs to a different repository; create or resume a linked worktree from the activation origin")


def identity(args):
    manifest = Path(args.skills).parent / ".claude-plugin/plugin.json"
    version = json.loads(manifest.read_text())["version"]
    if not re.fullmatch(r"[A-Za-z0-9.+_-]+", version) or not re.fullmatch(r"[0-9a-f]{64}", args.digest):
        fail("activation-unavailable: invalid installed identity")
    return version


def validate_content(args, record):
    version = identity(args)
    if record.get("installedDigest") != args.digest or record.get("version") != version:
        mismatch(args, record, f"installed {version} ({args.digest[:12]}) but this session received "
                 f"{record.get('version', 'unknown')} ({str(record.get('installedDigest', 'unknown'))[:12]})")
    if record.get("skillsRoot") != args.skills:
        mismatch(args, record, "installed skill path changed")
    workflow = record.get("workflow")
    if workflow not in WORKFLOWS:
        fail("activation-unavailable: unknown workflow identity")
    body = (Path(args.skills) / workflow / "SKILL.md").read_bytes()
    if record.get("deliveredDigest") != hashlib.sha256(body).hexdigest():
        mismatch(args, record, "delivered workflow bytes differ from installed workflow")


def delegated_skills(args, record):
    """Only authority rows in the installed workflow's call-site map delegate.

    Incidental links, examples and a companion's own delegates grant nothing.
    validate_content binds this source to the acknowledged workflow bytes.
    """
    body = (Path(args.skills) / record["workflow"] / "SKILL.md").read_text()
    section = re.search(r"^## Resident call-site map\s*\n(.*?)(?=^## |\Z)",
                        body, re.MULTILINE | re.DOTALL)
    if not section:
        return set()
    names = set()
    for line in section[1].splitlines():
        cells = line.split("|")
        if len(cells) != 4 or cells[0].strip() or cells[-1].strip():
            continue
        for name in re.findall(r"`\.\./([a-z][a-z0-9-]*)/SKILL\.md`", cells[2]):
            target_dir = Path(args.skills) / name
            target = target_dir / "SKILL.md"
            if (name in WORKFLOWS and target_dir.is_dir() and not target_dir.is_symlink()
                    and target.is_file() and not target.is_symlink()):
                names.add(name)
    return names


def validate(args, record, skill=None, require=()):
    validate_content(args, record)
    if skill and record.get("workflow") != skill and skill not in delegated_skills(args, record):
        fail("competing-workflow: requested " + skill + "; session workflow=" + str(record.get("workflow")))
    if record.get("status") != "active" or record.get("receiptSource") != "session-acknowledgement":
        fail("activation-unavailable: workflow delivery is pending session acknowledgement")
    for capability in require:
        if record.get("capabilities", {}).get(capability) != "observed":
            fail("capability-unavailable: " + capability + " is unknown; do not dispatch guard-dependent work")


def ack_command(args, record):
    return shlex.join([str(Path(args.skills) / ".shared/scripts/agent-preflight.sh"),
                       "--activation-session", record["session"],
                       "--activation-origin", record["repoRoot"],
                       "--workflow", record["workflow"],
                       "--activation-nonce", record["nonce"]])


def deliver(args, evidence, workflow, source, capabilities, recovery=False):
    skill = Path(args.skills) / workflow / "SKILL.md"
    if not skill.is_file() or skill.is_symlink():
        fail("workflow-unavailable: " + workflow)
    body = skill.read_bytes()
    record = {"schemaVersion": 1, "session": evidence.session, "repoRoot": str(evidence.root),
              "workflow": workflow, "skillsRoot": args.skills, "version": identity(args),
              "installedDigest": args.digest, "deliveredDigest": hashlib.sha256(body).hexdigest(),
              "deliverySource": source, "receiptSource": "unknown", "status": "pending",
              "nonce": secrets.token_hex(24), "capabilities": capabilities}
    evidence.write(record)
    if recovery:
        lead = ("agentkit root-mediated activation recovery: the workflow content changed. "
                "Read " + str(skill) + " in full now (reads are permitted while the receipt "
                "is pending), then run this exact receipt command and resume the assigned "
                "work in the same worktree:\n")
    else:
        lead = ("agentkit invocation boundary: explicit workflow delivery, not native registry evidence. "
                "Run this exact preflight command first; it records the session receipt:\n")
    context = (lead + ack_command(args, record) + "\n"
               + "agentkit: skill=" + workflow + " version=" + record["version"]
               + " hash=" + args.digest[:12] + "\n"
               + "Installed skills root: " + args.skills + "\n"
               + "Missing capability remains unknown. Do not substitute another workflow.")
    return record, context


def inspection(args, root, tool, tool_input):
    """Permit a bounded file inspection, never a general shell expression.

    Serves the stale-active path only: a content-mismatched active record still
    permits bounded diagnostic reads and searches before validate() raises
    ContentMismatch.
    """
    directory = False
    if tool == "Read":
        paths = [tool_input.get("file_path", "")]
    elif tool in ("Bash", "exec_command"):
        command = tool_input.get("command", tool_input.get("cmd", ""))
        # shlex splits words but does not model shell substitutions or operators.
        if re.search(r"[;&|<>`$\n\r*?\[\]{}()~]", command):
            return False
        try:
            words = shlex.split(command)
        except ValueError:
            return False
        if not words:
            return False
        if words[0] == "cat":
            paths = words[2:] if words[1:2] == ["--"] else words[1:]
        elif (len(words) == 4 and words[0] in ("head", "tail") and words[1] == "-n"
              and re.fullmatch(r"[1-9][0-9]{0,2}", words[2])):
            paths = words[3:]
        elif (len(words) == 4 and words[:2] == ["sed", "-n"]
              and re.fullmatch(r"[1-9][0-9]{0,3}(,[1-9][0-9]{0,3})?p", words[2])):
            paths = words[3:]
        elif words[:4] == ["rg", "--no-config", "-n", "--"]:
            # Only explicit regular files; no recursive roots, preprocessors, or arbitrary options.
            paths = words[5:]
        elif len(words) == 4 and words[:3] == ["rg", "--no-config", "--files"]:
            paths, directory = words[3:], True
        else:
            return False
    else:
        return False
    if not 1 <= len(paths) <= 4:
        return False
    for value in paths:
        path = Path(value)
        if (not path.is_absolute() or not (path.is_dir() if directory else path.is_file())
                or not any(path.resolve().is_relative_to(base) for base in (Path(args.skills), root))):
            return False
    return True


DISPATCH_TOOLS = ("Agent", "Task", "spawn_agent", "Skill")
DISPATCH_COMMANDS = (
    r"(?:^\s*|[;&|(\n]\s*)(?:\S*/)?create-issue-worktree\.sh(?:\s|$)",
    r"(?:^\s*|[;&|(\n]\s*)(?:\S*/)?worktree-commit\.sh(?:\s|$)",
    r"(?:^\s*|[;&|(\n]\s*)(?:\S*/)?chain-advance\.sh(?:\s|$)",
    r"(?<![\w/.-])git\s+(?:-[cC]\s+\S+\s+)*(push|worktree\s+add)\b",
    r"(?<![\w/.-])gh\s+(?:-R\s+\S+\s+|--repo\s+\S+\s+)?pr\s+(create|ready|merge)\b",
)


def executed_text(command):
    """Strip heredoc bodies and quoted strings so patterns only match executed text,
    never inert data (a commit message, a README snippet, an example CLI invocation).
    A single-token quoted string (no internal whitespace) is unwrapped first, not
    stripped, because it is the kit's own documented form for an absolute helper
    path or invocation and must still match as executed text."""
    stripped = re.sub(r"<<-?\s*['\"]?(\w+)['\"]?[^\n]*\n.*?^\t*\1\s*$", " ", command,
                      flags=re.DOTALL | re.MULTILINE)
    # Unwrap `bash -c '...'` (and sh/zsh/dash, single or double quoted) into executed text
    # BEFORE quoted strings are stripped as data: the kit's own recipes wrap commands this
    # way (the harness shell is zsh), so the -c body is executed, not inert. One pass only;
    # a `bash -c` nested inside another `bash -c` body stays unwrapped as a known gap.
    shell_c = re.sub(
        r"(?:^|(?<=[\s;&|(]))(?:bash|sh|zsh|dash)\s+(?:-[a-zA-Z]+\s+)*-c\s+"
        r"(?:'([^']*)'|\"([^\"]*)\")",
        lambda m: " " + (m.group(1) if m.group(1) is not None else m.group(2)) + " ",
        stripped)
    unwrapped = re.sub(r"'([^'\s]*)'|\"([^\"\s]*)\"", r"\1\2", shell_c)
    return re.sub(r"'[^']*'|\"[^\"]*\"", " ", unwrapped)


def dispatch_class(tool, tool_input):
    """A dispatch-class call spends slots, opens PRs, or pushes; those wait for the receipt."""
    if tool in DISPATCH_TOOLS:
        return True
    if tool in ("Bash", "exec_command"):
        command = tool_input.get("command", tool_input.get("cmd", ""))
        text = executed_text(command)
        return any(re.search(pattern, text) for pattern in DISPATCH_COMMANDS)
    return False


def hook(args):
    payload = json.load(sys.stdin)
    event = payload.get("hook_event_name", "UserPromptSubmit")
    root, session = payload.get("cwd", ""), payload.get("session_id", "")
    if event == "UserPromptSubmit":
        prompt = payload.get("prompt", "")
        workflow = select_workflow(prompt)
        if not workflow:
            return {}
        named = {name for name in WORKFLOWS if re.search(r"\b" + re.escape(name) + r"\b", prompt)}
        if not re.match(r"^\s*[$/]", prompt) and len(named) > 1:
            fail("competing-workflow: name one workflow per invocation; existing receipt preserved")
        skill = Path(args.skills) / workflow / "SKILL.md"
        if workflow not in WORKFLOWS or not skill.is_file() or skill.is_symlink():
            fail("workflow-unavailable: " + workflow + "; install/register the current plugin and invoke it again")
        evidence = Evidence(root, session, create=True)
        try:
            previous = evidence.read()
        except FileNotFoundError:
            previous = None
        if previous and previous.get("status") == "active":
            try:
                validate(args, previous)
            except ContentMismatch:
                pass  # Redelivery below stays pending until a fresh acknowledgement.
            else:
                if previous.get("workflow") == workflow:
                    return {"hookSpecificOutput": {"hookEventName": event, "additionalContext":
                            "agentkit activation unchanged: acknowledged workflow=" + workflow
                            + "; reuse durable session receipt; do not repeat discovery."}}
        _, context = deliver(args, evidence, workflow, "UserPromptSubmit.additionalContext",
                             {"user-prompt-submit": "observed", "pre-tool-use": "unknown"})
        return {"hookSpecificOutput": {"hookEventName": event, "additionalContext": context}}
    try:
        evidence = Evidence(root, session)
        record = evidence.read()
    except FileNotFoundError:
        return {}
    if event == "PreToolUse":
        record["capabilities"]["pre-tool-use"] = "observed"
        evidence.write(record)
        tool = payload.get("tool_name", "")
        tool_input = payload.get("tool_input", {})
        if record.get("status") != "active":
            # Pending delivery gates dispatch only; reads, edits, and inspection proceed.
            if dispatch_class(tool, tool_input):
                validate(args, record)
            return {}
        if inspection(args, evidence.root, tool, tool_input):
            # A stale (content-mismatched) active record still permits bounded
            # diagnostic reads; validate() below is what raises ContentMismatch.
            return {}
        validate(args, record)
        if tool == "Skill":
            requested = tool_input.get("skill", "")
            if (not isinstance(requested, str) or not requested.startswith("agentkit:")
                    or requested.removeprefix("agentkit:") not in WORKFLOWS):
                fail("competing-workflow: active workflow=" + record["workflow"])
            validate(args, record, requested.removeprefix("agentkit:"))
        return {}
    if event == "SessionStart":
        # Revalidation preserves historical receipt; never creates one for a compacted context.
        try:
            validate_content(args, record)
        except ContentMismatch as error:
            reason = "SessionStart source=" + str(payload.get("source", "unknown")) + ": " + str(error)
            return {"systemMessage": reason, "hookSpecificOutput": {
                "hookEventName": event, "additionalContext": reason + "; do not dispatch."}}
        record["capabilities"]["pre-tool-use"] = "unknown"
        evidence.write(record)
        return {"hookSpecificOutput": {"hookEventName": event, "additionalContext":
                "agentkit durable activation: workflow=" + record["workflow"]
                + " status=" + record.get("status", "unknown")
                + " version=" + record.get("version", "unknown")
                + "; historical session receipt only, not proof of this context's native registry. "
                + ("" if record.get("status") == "active" else "Run: " + ack_command(args, record))}}
    return {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skills", required=True)
    parser.add_argument("--digest", required=True)
    parser.add_argument("action", choices=("hook", "ack", "check", "identity", "classify", "redeliver"))
    parser.add_argument("--repo-root")
    parser.add_argument("--target-root")
    parser.add_argument("--session")
    parser.add_argument("--skill", choices=sorted(WORKFLOWS))
    parser.add_argument("--nonce")
    parser.add_argument("--require", action="append", default=[])
    args = parser.parse_args()
    event = "UserPromptSubmit"
    try:
        if args.action == "classify":
            print(select_workflow(json.load(sys.stdin)["prompt"]) or "")
            return 0
        if args.action == "hook":
            # Preserve event for the correct denial schema, without treating malformed input as allow.
            raw = sys.stdin.read()
            import io
            sys.stdin = io.StringIO(raw)
            event = json.loads(raw).get("hook_event_name", event)
            print(json.dumps(hook(args)))
            return 0
        if args.action == "identity":
            print(f"agentkit: skill={args.skill} version={identity(args)} hash={args.digest[:12]}")
            return 0
        if not args.repo_root or not args.session or not args.skill:
            fail("activation-unavailable: --repo-root, --session and --skill are required")
        try:
            evidence = Evidence(args.repo_root, args.session)
            record = evidence.read()
        except FileNotFoundError:
            reason = ("activation-unavailable: no receipt at activation origin for session; invoke "
                      + args.skill + " in that checkout and acknowledge the fresh challenge")
            if args.action == "check":
                reason += ("\nagentkit: if no challenge was delivered in this conversation, no workflow "
                           "run exists; reference use needs no activation")
            fail(reason)
        if args.action == "redeliver":
            if record.get("workflow") != args.skill:
                fail("activation-unavailable: recovery workflow does not match the affected receipt")
            if record.get("status") != "active":
                fail("activation-unavailable: recovery receipt is pending session acknowledgement")
            try:
                validate_content(args, record)
            except ContentMismatch:
                pass
            else:
                fail("activation-unavailable: recovery is not needed for an unchanged active receipt")
            capabilities = dict(record.get("capabilities", {}))
            capabilities["pre-tool-use"] = "unknown"
            _, context = deliver(args, evidence, args.skill, "root-redelivery", capabilities, recovery=True)
            print(context)
            return 0
        if args.action == "ack":
            if not args.nonce or not secrets.compare_digest(args.nonce, record.get("nonce", "")):
                fail("activation-unavailable: session receipt challenge mismatch")
            if args.skill != record.get("workflow"):
                # A companion consumes an already active receipt; it cannot
                # acknowledge pending delivery on the parent's behalf.
                validate(args, record, args.skill)
            else:
                record["status"], record["receiptSource"] = "active", "session-acknowledgement"
                validate(args, record, args.skill)
                evidence.write(record)
            print(f"agentkit: skill={args.skill} version={identity(args)} hash={args.digest[:12]}")
        else:
            validate(args, record, args.skill, args.require)
            if args.target_root:
                validate_target(evidence.root, args.target_root)
            print(json.dumps(record, sort_keys=True))
        return 0
    except (Unavailable, OSError, ValueError, KeyError, TypeError) as error:
        reason = str(error) if isinstance(error, Unavailable) else "agentkit: activation-unavailable: " + str(error)
        if args.action == "hook":
            if event == "PreToolUse":
                print(json.dumps({"hookSpecificOutput": {"hookEventName": event,
                      "permissionDecision": "deny", "permissionDecisionReason": reason}}))
            elif event == "SessionStart":
                print(json.dumps({"systemMessage": reason, "hookSpecificOutput": {
                    "hookEventName": event, "additionalContext": reason + "; do not dispatch."}}))
            else:
                print(json.dumps({"decision": "block", "reason": reason}))
            return 0
        print(reason, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
