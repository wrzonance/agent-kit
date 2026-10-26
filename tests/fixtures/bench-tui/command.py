#!/usr/bin/env python3
"""External-process doubles for the real interactive trial runner, with no network."""
import json
import os
import shlex
import subprocess
import sys
from pathlib import Path

base = Path(os.environ["TUI_FIXTURE"])
name, args = Path(sys.argv[0]).name, sys.argv[1:]
mode = os.environ.get("TUI_MODE", "normal")
alive = base / "alive"
with (base / "calls").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name in ("tmux", "codex", "claude") and args[:1] != ["plugin"]:
    with (base / "inherited").open("a") as log:
        for key in os.environ:
            if key.startswith("CLAUDE") or key in ("CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_CI"):
                log.write(key + "\n")


def launch_cli():
    command, cwd = json.loads((base / "command.json").read_text())
    subprocess.run(shlex.split(command), cwd=cwd, check=True)
    (base / "launched").touch()


def transcript(harness):
    prompt = args[-1]
    if not prompt.startswith(("$ak:issues", "/ak:issues")):
        return
    with (base / "invocations").open("a") as log:
        log.write(prompt + "\n")
    cwd = str(Path.cwd())
    if harness == "codex":
        directory = Path(os.environ["CODEX_HOME"]) / "sessions"
        directory.mkdir(parents=True, exist_ok=True)
        records = [{"type": "session_meta", "payload": {"id": "root", "cwd": cwd}}]
        if mode not in ("no-start", "child-only"):
            records.append({"type": "event_msg", "payload": {"type": "task_started"}})
        (directory / "rollout-root.jsonl").write_text("\n".join(map(json.dumps, records)) + "\n")
        child = [{"type": "session_meta", "payload": {
            "id": "child", "parent_thread_id": "root", "cwd": cwd}},
            {"type": "event_msg", "payload": {"type": "task_started"}}]
        (directory / "rollout-child.jsonl").write_text("\n".join(map(json.dumps, child)) + "\n")
    else:
        slug = "".join(c if c.isascii() and c.isalnum() else "-" for c in cwd)
        directory = Path.home() / ".claude/projects" / slug
        directory.mkdir(parents=True, exist_ok=True)
        with (base / "claude-projects").open("a") as log:
            log.write(str(directory) + "\n")
        records = [{"type": "user", "cwd": cwd, "sessionId": "root",
                    "message": {"role": "user", "content": prompt}}]
        if mode != "no-start":
            records.append({"type": "assistant", "cwd": cwd, "message": {
                "id": "reply", "role": "assistant", "content": [],
                "usage": {"input_tokens": 2, "output_tokens": 1}}})
        (directory / "root.jsonl").write_text("\n".join(map(json.dumps, records)) + "\n")


if name in ("codex", "claude"):
    if not args or args[0] != "plugin":
        transcript(name)
elif name == "git":
    if args[0] == "clone":
        args = ["init", "-q", "-b", "fixture", args[-1]]
    sys.exit(subprocess.run([os.environ["TUI_REAL_GIT"], *args], check=False).returncode)
elif name == "gh":
    if args[:2] == ["api", "graphql"]:
        print("5000 9999999999")
    elif args[:2] == ["project", "item-list"]:
        print(json.dumps({"items": [{"status": "Ready", "content": {"number": 11}}]}))
    elif "/pulls?" in args[1]:
        if mode != "premature":
            print("99")
    elif "/comments" in args[1]:
        if mode == "already-gone":
            alive.unlink(missing_ok=True)
        print("ak receipt")
elif name == "tmux":
    command = args[0]
    if command == "new-session":
        alive.touch()
        cwd = args[args.index("-c") + 1]
        (base / "launched").unlink(missing_ok=True)
        (base / "command.json").write_text(json.dumps([args[-1], cwd]))
        if not (base / "panes").exists():
            launch_cli()
        if mode == "premature":
            alive.unlink()
    elif command == "has-session":
        if not alive.exists():
            print("can't find session: fixture", file=sys.stderr)
            sys.exit(1)
    elif command == "capture-pane":
        panes = (base / "panes").read_text().splitlines() if (base / "panes").exists() else []
        if panes:
            print(panes.pop(0))
            (base / "panes").write_text("\n".join(panes))
        else:
            if not (base / "launched").exists():
                launch_cli()
            print("› /ak:issues --serialize --yolo --limit 4")
    elif command == "send-keys" and args[-1] == "C-c":
        if not alive.exists():
            print("can't find pane: fixture", file=sys.stderr)
            sys.exit(1)
        if mode == "cleanup-error":
            print("unexpected terminal write error", file=sys.stderr)
            sys.exit(2)
        alive.unlink()
    elif command == "kill-session":
        alive.unlink(missing_ok=True)
elif name == "sleep":
    pass
