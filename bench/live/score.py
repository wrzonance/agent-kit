#!/usr/bin/env python3
"""Score one Codex run from its rollout files: root cost, worker cost, and the north-star counters.

Usage:
  score.py ROOT_ROLLOUT [--sessions DIR] [--label k=v ...] [--outcome FILE]

ROOT_ROLLOUT is the root thread's rollout-*.jsonl. Every rollout under --sessions (default: the
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


def score_thread(path: Path) -> dict:
    """Counters for one rollout file."""
    out = {
        "calls": 0, "exec_calls": 0, "failed_exec": 0, "help_calls": 0, "kit_read_bytes": 0,
        "spawns": 0, "waits": 0, "turn_ends": 0, "user_messages": 0, "compactions": 0,
        "first_spawn": None, "start": None, "end": None, "tokens": tokens(None), "active_s": 0.0,
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
    if turn_start and out["end"]:
        out["active_s"] += ts(out["end"]) - ts(turn_start)
    out["active_s"] = round(out["active_s"], 1)
    out["tokens"] = tokens(last_usage)
    return out


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


def build(root: Path, sessions: Path, labels: dict, outcome: dict) -> dict:
    meta = session_meta(root)
    session_id = meta.get("session_id") or meta.get("id")
    main = score_thread(root)
    first = main.pop("first_spawn")
    workers, guardian = [], []
    for path in find_children(root, sessions, session_id):
        child_meta = session_meta(path)
        counters = score_thread(path)
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
            "tokens": main["tokens"],
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
    parser.add_argument("--label", action="append", default=[], metavar="KEY=VALUE")
    parser.add_argument("--outcome", type=Path, help="JSON object merged in as the outcome field")
    args = parser.parse_args(argv)
    if not args.root.is_file():
        print(f"score: no rollout at {args.root}", file=sys.stderr)
        return 2
    sessions = args.sessions or args.root.parents[3]
    labels = {}
    for item in args.label:
        key, sep, value = item.partition("=")
        if not sep or not key:
            print(f"score: --label needs KEY=VALUE, got {item!r}", file=sys.stderr)
            return 2
        labels[key] = value
    outcome = json.loads(args.outcome.read_text()) if args.outcome else {}
    print(json.dumps(build(args.root, sessions, labels, outcome), sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
