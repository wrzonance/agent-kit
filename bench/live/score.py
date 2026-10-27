#!/usr/bin/env python3
"""Score one Codex run from its rollout files: root cost, worker cost, and the north-star counters.

Usage:
  score.py ROOT [--sessions DIR] [--harness codex|claude] [--label k=v ...] [--outcome FILE]

ROOT is a Codex root rollout-*.jsonl or a Claude Code <session-id>.jsonl; the harness is detected
from the first line unless --harness names it. Claude workers are <session-id>/subagents/agent-*.jsonl.

For Codex, ROOT is the root thread's rollout-*.jsonl. Every rollout under --sessions (default: the
directory tree three levels above ROOT_ROLLOUT, i.e. ~/.codex/sessions) whose session_meta names the
same session_id is a child of this run: a spawned worker, or the harness's own guardian reviewer.
Prints one JSON object, ready to append to bench/results/live.jsonl.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime
from pathlib import Path

KIT_PATH = re.compile(r"plugins/cache/agent-kit/|/agentkit/(skills|hooks)/|/v2/(skills|templates|lib|bin)/")
READ_CMD = re.compile(r"^\s*(cat|sed|rg|nl|head|tail|less|awk|grep)\b")
SPAWN_TOOLS = {"spawn_agent"}
# Harness-injected user-role messages (instructions, skill bodies, context) are not operator prompts.
INJECTED = re.compile(r"^\s*(#\s*AGENTS\.md|<skill>|<environment_context>|<user_instructions>|<recommended_plugins>|<turn_aborted>|<subagent|<permissions)")
WAIT_TOOLS = {"wait_agent", "wait"}
TRIGGERS = ("agent_done", "bash_done", "teammate", "human", "hook", "other")
CLAUDE_SPAWN_TOOLS = {"Agent", "Task"}
CLAUDE_WAIT_TOOLS = {"TaskOutput"}
# The harness's hook-feedback injections open with a system-reminder or hook envelope.
CLAUDE_HOOK = re.compile(
    r"(<system-reminder>\s*)?(<user-prompt-submit-hook>|(Stop|SubagentStop|UserPromptSubmit|PostToolUse|PreToolUse) hook (feedback|blocking error|additional context))")


def ts(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def records(path: Path):
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                continue


def session_meta(path: Path) -> dict:
    for record in records(path):
        if record.get("type") == "session_meta":
            return record.get("payload", {})
        break
    return {}


def tokens(usage: dict | None) -> dict:
    usage = usage or {}
    return {k: int(usage.get(k, 0)) for k in ("total_tokens", "input_tokens", "cached_input_tokens", "output_tokens")}


def command_text(item: dict) -> str:
    command = item.get("command")
    if isinstance(command, list):
        return str(command[-1]) if command else ""
    return str(command or "")


def empty_wakes() -> dict:
    return {"total": 0, "by_trigger": {name: 0 for name in TRIGGERS}}


def score_thread(path: Path) -> dict:
    """Counters for one rollout file."""
    wake_log = empty_wakes()
    wait_calls: set = set()
    event_users = 0
    out = {
        "calls": 0, "exec_calls": 0, "failed_exec": 0, "help_calls": 0, "kit_read_bytes": 0,
        "spawns": 0, "waits": 0, "turn_ends": 0, "user_messages": 0, "compactions": 0,
        "first_spawn": None, "start": None, "end": None, "tokens": tokens(None), "active_s": 0.0,
        "wakes": wake_log, "cache_read_tokens": 0,
    }
    turn_start = None
    last_usage = None
    for record in records(path):
        stamp = record.get("timestamp")
        payload = record.get("payload") or {}
        kind = payload.get("type")
        if stamp:
            out["start"] = out["start"] or stamp
            out["end"] = stamp
        if record.get("type") == "compacted":
            out["compactions"] += 1
        if kind in ("custom_tool_call", "function_call"):
            out["calls"] += 1
            name = payload.get("name", "")
            if name in SPAWN_TOOLS:
                out["spawns"] += 1
                if out["first_spawn"] is None:
                    out["first_spawn"] = {"at": stamp, "calls_before": out["calls"] - 1,
                                          "tokens_before": tokens(last_usage)["total_tokens"]}
            elif name in WAIT_TOOLS:
                out["waits"] += 1
            if name == "wait_agent" and kind == "function_call":
                wait_calls.add(payload.get("call_id"))
        elif kind == "function_call_output" and payload.get("call_id") in wait_calls:
            add_wake(wake_log, "agent_done")
        elif kind == "user_message" and record.get("type") == "event_msg":
            event_users += 1
        elif kind == "item_completed" and (payload.get("item") or {}).get("type") == "CommandExecution":
            item = payload["item"]
            text = command_text(item)
            output = (item.get("stdout") or "") + (item.get("stderr") or "")
            out["exec_calls"] += 1
            if item.get("exit_code") not in (0, None):
                out["failed_exec"] += 1
            if "--help" in text:
                out["help_calls"] += 1
            if READ_CMD.search(text) and KIT_PATH.search(text):
                out["kit_read_bytes"] += len(output.encode("utf-8", errors="replace"))
        elif kind == "token_count" and payload.get("info"):
            last_usage = payload["info"].get("total_token_usage")
        elif kind == "task_started":
            turn_start = stamp
        elif kind == "task_complete":
            out["turn_ends"] += 1
            if turn_start and stamp:
                out["active_s"] += ts(stamp) - ts(turn_start)
                turn_start = None
        elif record.get("type") == "response_item" and kind == "message" and payload.get("role") == "user":
            text = "".join(c.get("text", "") for c in payload.get("content") or [] if isinstance(c, dict))
            if text.strip() and not INJECTED.search(text):
                out["user_messages"] += 1
                add_wake(wake_log, "human")
    if out["user_messages"] == 0 and event_users:
        wake_log["by_trigger"]["human"] += event_users
        wake_log["total"] += event_users
    if turn_start and out["end"]:
        out["active_s"] += ts(out["end"]) - ts(turn_start)
    out["active_s"] = round(out["active_s"], 1)
    out["tokens"] = tokens(last_usage)
    out["cache_read_tokens"] = out["tokens"]["cached_input_tokens"]
    return out


def add_wake(wakes: dict, trigger: str) -> None:
    wakes["total"] += 1
    wakes["by_trigger"][trigger] += 1


def first_text(message: dict) -> str:
    """The text a user line opens with: the string content, or the first text block."""
    content = message.get("content")
    if isinstance(content, str):
        return content
    for block in content or []:
        if isinstance(block, dict) and block.get("type") == "text":
            return block.get("text", "")
    return ""


def is_tool_result(message: dict) -> bool:
    content = message.get("content")
    return isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def result_bytes(block: dict) -> int:
    content = block.get("content")
    if isinstance(content, list):
        content = "".join(c.get("text", "") for c in content if isinstance(c, dict))
    return len(str(content or "").encode("utf-8", errors="replace"))


def classify_claude_wake(text: str) -> str:
    """Trigger of a non-tool-result user line. Only the harness-injected openings count; the
    same words inside an operator prompt stay human."""
    head = text.lstrip()
    if head.startswith("<task-notification>"):
        summary = re.match(r"<task-notification>\s*(?:<[^>]+>[^<]*</[^>]+>\s*)*?<summary>\s*(Agent \"|Background command)", head)
        if summary is None:
            return "other"
        return "agent_done" if summary.group(1).startswith("Agent") else "bash_done"
    if head.startswith(("<teammate-message", "Another Claude session sent a message")):
        return "teammate"
    if CLAUDE_HOOK.match(head):
        return "hook"
    return "human" if head else "other"


def claude_usage(usages: dict) -> dict:
    """Deduplicated (by message.id) usage, in the Codex tokens() shape."""
    cached = sum(int(u.get("cache_read_input_tokens") or 0) for u in usages.values())
    fresh = sum(int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0) for u in usages.values())
    out = sum(int(u.get("output_tokens") or 0) for u in usages.values())
    return {"total_tokens": fresh + cached + out, "input_tokens": fresh + cached,
            "cached_input_tokens": cached, "output_tokens": out}


def is_kit_read(name: str, tool_input: dict) -> bool:
    if name == "Read":
        return bool(KIT_PATH.search(str(tool_input.get("file_path", ""))))
    if name == "Bash":
        command = str(tool_input.get("command", ""))
        return bool(READ_CMD.search(command) and KIT_PATH.search(command))
    return False


class ClaudeTally:
    """Mutable state for one pass over a Claude transcript."""

    def __init__(self) -> None:
        self.usages: dict = {}
        self.seen_tools: set = set()
        self.bash_ids: set = set()
        self.kit_ids: set = set()
        self.tool_turns: dict = {}
        self.turn_start = None
        self.last_stamp = None
        self.active_s = 0.0
        self.boundaries = 0
        self.summaries = 0

    def close_turn(self) -> None:
        if self.turn_start and self.last_stamp:
            self.active_s += ts(self.last_stamp) - ts(self.turn_start)
        self.turn_start = None


def tally_tool_use(out: dict, tally: ClaudeTally, block: dict, stamp) -> None:
    """Count one tool_use block (deduplicated by its id across streamed lines)."""
    if block.get("id") in tally.seen_tools:
        return
    tally.seen_tools.add(block.get("id"))
    out["calls"] += 1
    name, tool_input = block.get("name", ""), block.get("input") or {}
    if is_kit_read(name, tool_input):
        tally.kit_ids.add(block.get("id"))
    if name == "Bash":
        out["exec_calls"] += 1
        tally.bash_ids.add(block.get("id"))
        out["help_calls"] += "--help" in str(tool_input.get("command", ""))
    elif name in CLAUDE_SPAWN_TOOLS:
        out["spawns"] += 1
        if out["first_spawn"] is None:
            out["first_spawn"] = {"at": stamp, "calls_before": out["calls"] - 1,
                                  "tokens_before": claude_usage(tally.usages)["total_tokens"]}
    elif name in CLAUDE_WAIT_TOOLS:
        out["waits"] += 1


def tally_tool_results(out: dict, tally: ClaudeTally, message: dict) -> None:
    for block in message["content"]:
        if not isinstance(block, dict) or block.get("type") != "tool_result":
            continue
        if block.get("is_error") and block.get("tool_use_id") in tally.bash_ids:
            out["failed_exec"] += 1
        if block.get("tool_use_id") in tally.kit_ids:
            out["kit_read_bytes"] += result_bytes(block)


def score_claude(path: Path) -> dict:
    """Counters for one Claude Code transcript, in the same shape as score_thread."""
    out = {
        "calls": 0, "exec_calls": 0, "failed_exec": 0, "help_calls": 0, "kit_read_bytes": 0,
        "spawns": 0, "waits": 0, "turn_ends": 0, "user_messages": 0, "compactions": 0,
        "first_spawn": None, "start": None, "end": None, "tokens": tokens(None), "active_s": 0.0,
        "wakes": empty_wakes(), "cache_read_tokens": 0,
    }
    tally = ClaudeTally()
    for record in records(path):
        stamp = record.get("timestamp")
        if stamp:
            out["start"] = out["start"] or stamp
            out["end"] = stamp
        message = record.get("message") or {}
        kind = record.get("type")
        if kind == "system" and record.get("subtype") == "compact_boundary":
            tally.boundaries += 1
        if kind not in ("user", "assistant"):
            continue
        if kind == "user" and is_tool_result(message):
            tally_tool_results(out, tally, message)
        elif kind == "user" and record.get("isCompactSummary"):
            tally.summaries += 1
        elif kind == "user":
            trigger = classify_claude_wake(first_text(message))
            add_wake(out["wakes"], trigger)
            out["user_messages"] += trigger == "human"
            tally.close_turn()
            tally.turn_start = stamp
        else:
            if message.get("id"):
                tally.usages[message["id"]] = message.get("usage") or {}
                tally.tool_turns.setdefault(message["id"], False)
            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use":
                    tally.tool_turns[message.get("id")] = True
                    tally_tool_use(out, tally, block, stamp)
        tally.last_stamp = stamp or tally.last_stamp
    tally.close_turn()
    out["active_s"] = round(tally.active_s, 1)
    out["turn_ends"] = sum(1 for used_tool in tally.tool_turns.values() if not used_tool)
    out["compactions"] = tally.boundaries or tally.summaries
    out["tokens"] = claude_usage(tally.usages)
    out["cache_read_tokens"] = out["tokens"]["cached_input_tokens"]
    return out


def detect_harness(path: Path) -> str:
    """codex rollouts open with session_meta; Claude Code transcripts do not."""
    for record in records(path):
        return "codex" if record.get("type") == "session_meta" else "claude"
    return "codex"


def claude_children(root: Path) -> list[Path]:
    return sorted((root.parent / root.stem / "subagents").glob("agent-*.jsonl"))


def find_children(root: Path, sessions: Path, session_id: str) -> list[Path]:
    children = []
    for path in sorted(sessions.rglob("rollout-*.jsonl")):
        if path.resolve() == root.resolve():
            continue
        meta = session_meta(path)
        if meta.get("session_id") == session_id and meta.get("id") != session_id:
            children.append(path)
    return children


def child_kind(meta: dict) -> str:
    source = meta.get("source") or {}
    sub = source.get("subagent") if isinstance(source, dict) else None
    if isinstance(sub, dict) and sub.get("other") == "guardian":
        return "guardian"
    return "worker"


def elapsed(start: str | None, end: str | None) -> float | None:
    if not start or not end:
        return None
    return round(ts(end) - ts(start), 1)


def build(root: Path, sessions: Path | None, labels: dict, outcome: dict, harness: str | None = None) -> dict:
    harness = harness or detect_harness(root)
    if harness == "claude":
        meta, score, children = {}, score_claude, claude_children(root)
        session_id = root.stem
    else:
        meta, score = session_meta(root), score_thread
        session_id = meta.get("session_id") or meta.get("id")
        children = find_children(root, sessions or root.parents[3], session_id)
    main = score(root)
    first = main.pop("first_spawn")
    workers, guardian = [], []
    for path in children:
        child_meta = session_meta(path) if harness == "codex" else {"id": path.stem}
        counters = score(path)
        counters.pop("first_spawn")
        row = {"id": child_meta.get("id"), "tokens": counters["tokens"]["total_tokens"],
               "calls": counters["calls"], "failed_exec": counters["failed_exec"],
               "help_calls": counters["help_calls"], "wall_s": elapsed(counters["start"], counters["end"])}
        (guardian if child_kind(child_meta) == "guardian" else workers).append(row)
    root_tokens = main["tokens"]["total_tokens"]
    worker_tokens = sum(w["tokens"] for w in workers)
    guardian_tokens = sum(g["tokens"] for g in guardian)
    return {
        **labels,
        "session_id": session_id,
        "cli_version": meta.get("cli_version"),
        "root": {
            "wall_s": elapsed(main["start"], main["end"]), "active_s": main["active_s"],
            "prompts": main["user_messages"],
            "calls": main["calls"], "exec_calls": main["exec_calls"], "failed_exec": main["failed_exec"],
            "help_calls": main["help_calls"], "kit_read_bytes": main["kit_read_bytes"],
            "spawns": main["spawns"], "waits": main["waits"], "turn_ends": main["turn_ends"],
            "steers": max(main["user_messages"] - 1, 0), "compactions": main["compactions"],
            "tokens": main["tokens"], "cache_read_tokens": main["cache_read_tokens"],
            "wakes": main["wakes"],
            "first_spawn": None if first is None else {
                "wall_s": elapsed(main["start"], first["at"]),
                "calls": first["calls_before"], "tokens": first["tokens_before"]},
        },
        "workers": {"count": len(workers), "tokens": worker_tokens,
                    "calls": sum(w["calls"] for w in workers), "each": workers},
        "guardian": {"count": len(guardian), "tokens": guardian_tokens},
        "system_tokens": root_tokens + worker_tokens + guardian_tokens,
        "outcome": outcome,
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("root", type=Path)
    parser.add_argument("--sessions", type=Path)
    parser.add_argument("--harness", choices=("codex", "claude"), help="default: detected from the first line")
    parser.add_argument("--label", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--outcome", type=Path, help="JSON object merged in as the outcome field")
    args = parser.parse_args(argv)
    if not args.root.is_file():
        print(f"score: no rollout at {args.root}", file=sys.stderr)
        return 2
    labels = {}
    for item in args.label:
        key, sep, value = item.partition("=")
        if not sep or not key:
            print(f"score: --label needs KEY=VALUE, got {item!r}", file=sys.stderr)
            return 2
        labels[key] = value
    outcome = json.loads(args.outcome.read_text()) if args.outcome else {}
    print(json.dumps(build(args.root, args.sessions, labels, outcome, args.harness), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
