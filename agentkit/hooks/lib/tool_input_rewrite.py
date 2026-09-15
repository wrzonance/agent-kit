import fcntl
import hashlib
import json
import os
import re
import secrets
import shlex
import tempfile
from contextlib import contextmanager
from pathlib import Path

from rewrite_profile import Unavailable, canonical, decode, private

ORIGINAL = "agent-run.sh --cmd test"


def candidate(event, helper, nonce):
    if not isinstance(event, dict) or (
        event.get("hook_event_name"), event.get("tool_name")
    ) != ("PreToolUse", "Bash"):
        return None
    value = event.get("tool_input")
    if not isinstance(value, dict) or value.get("command") != ORIGINAL:
        return None
    if set(value) - {"command", "description", "timeout"}:
        return None
    if "timeout" in value and (type(value["timeout"]) is not int or value["timeout"] <= 0):
        return None
    if "description" in value and not isinstance(value["description"], str):
        return None
    if not isinstance(event.get("cwd"), str) or not event["cwd"].startswith("/"):
        return None
    if not re.fullmatch(r"[a-f0-9]{32}", nonce):
        raise Unavailable("invalid claim nonce")
    helper = canonical(helper)
    if helper.name != "agent-run.sh" or not helper.is_file() or not os.access(helper, os.X_OK):
        raise Unavailable("invalid trusted helper")
    return value | {"command": f"{shlex.quote(str(helper))} --cmd test # agentkit-rewrite={nonce}"}


def input_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


class Records:
    def __init__(self, root, session):
        self.root = Path(root)
        self.root.mkdir(mode=0o700, exist_ok=True)
        private(self.root, directory=True)
        self.session = session

    @contextmanager
    def transaction(self):
        descriptor = os.open(self.root / "lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "r+") as lock:
            private(self.root / "lock")
            fcntl.flock(lock, fcntl.LOCK_EX)
            path = self.root / "records.json"
            try:
                data = decode(private(path).read_text())
            except FileNotFoundError:
                data = {"schemaVersion": 1, "sessionId": self.session, "seen": [], "results": [], "pending": None}
            if (not isinstance(data, dict) or data.get("schemaVersion") != 1
                    or data.get("sessionId") != self.session
                    or not isinstance(data.get("seen"), list) or not isinstance(data.get("results"), list)
                    or not isinstance(data.get("pending"), (dict, type(None)))):
                raise Unavailable("invalid rewrite state")
            yield data
            descriptor, temporary = tempfile.mkstemp(dir=self.root)
            try:
                with os.fdopen(descriptor, "w") as output:
                    json.dump(data, output, separators=(",", ":"))
                os.replace(temporary, path)
            finally:
                if os.path.lexists(temporary):
                    os.unlink(temporary)

    def issue(self, tool_id, value, helper):
        if not isinstance(tool_id, str) or not 1 <= len(tool_id) <= 256:
            return None
        with self.transaction() as data:
            if data["pending"] is not None or tool_id in data["seen"] or len(data["seen"]) >= 256:
                return None
            event = {"hook_event_name": "PreToolUse", "tool_name": "Bash", "cwd": "/", "tool_input": value}
            replacement = candidate(event, helper, secrets.token_hex(16))
            if replacement is None:
                return None
            data["seen"].append(tool_id)
            data["pending"] = {"toolId": tool_id, "original": ORIGINAL,
                               "transformed": replacement["command"], "inputSha256": input_digest(replacement),
                               "consumed": False}
            return replacement

    def consume(self, command):
        with self.transaction() as data:
            record = data["pending"]
            if record is None or record.get("consumed") or command != record.get("transformed"):
                return None
            record["consumed"] = True
            return record.copy()

    def finish(self, event):
        if (event.get("session_id") != self.session or event.get("tool_name") != "Bash"
                or event.get("hook_event_name") not in {"PostToolUse", "PostToolUseFailure"}):
            return None
        with self.transaction() as data:
            record = data["pending"]
            if (record is None or record.get("toolId") != event.get("tool_use_id")
                    or record.get("inputSha256") != input_digest(event.get("tool_input"))):
                return None
            response = event.get("tool_response")
            response = response if isinstance(response, dict) else {}
            code = response.get("exitCode")
            interrupted = response.get("interrupted", event.get("is_interrupt"))
            result = {key: record[key] for key in ("toolId", "original", "transformed")}
            result.update(sessionId=self.session, executionClaimed=record["consumed"],
                          hookEventName=event["hook_event_name"],
                          interrupted=interrupted if type(interrupted) is bool else None,
                          exitCode=code if type(code) is int else None)
            data["results"].append(result)
            data["pending"] = None
            return result
