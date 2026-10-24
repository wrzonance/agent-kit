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
CLAUDE_HOOK = re.compile(r"stop hook|hook feedback|<user-prompt-submit-hook>", re.IGNORECASE)


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


def message_text(message: dict) -> str:
    content = message.get("content")
    if isinstance(content, str):
        return content
    return "".join(b.get("text", "") for b in content or [] if isinstance(b, dict) and b.get("type") == "text")


def is_tool_result(message: dict) -> bool:
    content = message.get("content")
    return isinstance(content, list) and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)


def classify_claude_wake(text: str) -> str:
    """Trigger of a non-tool-result user line that wakes the model."""
    if "<task-notification>" in text:
        return "bash_done" if "Background command" in text else "agent_done"
    if "<teammate-message" in text or "Another Claude session sent a message" in text:
        return "teammate"
    if CLAUDE_HOOK.search(text):
        return "hook"
    return "human" if text.strip() else "other"


def claude_usage(usages: dict) -> dict:
    """Deduplicated (by message.id) usage, in the Codex tokens() shape."""
    cached = sum(int(u.get("cache_read_input_tokens") or 0) for u in usages.values())
    fresh = sum(int(u.get("input_tokens") or 0) + int(u.get("cache_creation_input_tokens") or 0) for u in usages.values())
    out = sum(int(u.get("output_tokens") or 0) for u in usages.values())
    return {"total_tokens": fresh + cached + out, "input_tokens": fresh + cached,
            "cached_input_tokens": cached, "output_tokens": out}


def score_claude(path: Path) -> dict:
    """Counters for one Claude Code transcript, in the same shape as score_thread."""
    out = {
        "calls": 0, "exec_calls": 0, "failed_exec": 0, "help_calls": 0, "kit_read_bytes": 0,
        "spawns": 0, "waits": 0, "turn_ends": 0, "user_messages": 0, "compactions": 0,
        "first_spawn": None, "start": None, "end": None, "tokens": tokens(None), "active_s": 0.0,
        "wakes": empty_wakes(), "cache_read_tokens": 0,
    }
    usages: dict = {}
    seen_tools: set = set()
    bash_ids: set = set()
    pending_wake = False
    for record in records(path):
        stamp = record.get("timestamp")
        if stamp:
            out["start"] = out["start"] or stamp
            out["end"] = stamp
        message = record.get("message") or {}
        if record.get("type") == "user":
            if is_tool_result(message):
                for block in message["content"]:
                    if block.get("is_error") and block.get("tool_use_id") in bash_ids:
                        out["failed_exec"] += 1
                continue
            text = message_text(message)
            trigger = classify_claude_wake(text)
            if trigger == "human":
                out["user_messages"] += 1
            pending_wake = trigger
        elif record.get("type") == "assistant":
            if pending_wake:
                add_wake(out["wakes"], pending_wake)
                pending_wake = False
            if message.get("id"):
                usages[message["id"]] = message.get("usage") or {}
            for block in message.get("content") or []:
                if not isinstance(block, dict) or block.get("type") != "tool_use" or block.get("id") in seen_tools:
                    continue
                seen_tools.add(block.get("id"))
                out["calls"] += 1
                name = block.get("name", "")
                if name == "Bash":
                    out["exec_calls"] += 1
                    bash_ids.add(block.get("id"))
                    command = str((block.get("input") or {}).get("command", ""))
                    out["help_calls"] += "--help" in command
                elif name in CLAUDE_SPAWN_TOOLS:
                    out["spawns"] += 1
                    if out["first_spawn"] is None:
                        out["first_spawn"] = {"at": stamp, "calls_before": out["calls"] - 1,
                                              "tokens_before": claude_usage(usages)["total_tokens"]}
                elif name in CLAUDE_WAIT_TOOLS:
                    out["waits"] += 1
    out["tokens"] = claude_usage(usages)
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
