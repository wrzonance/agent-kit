#!/usr/bin/env bash
# Validate a root-owned publication handback without executing it.
#
# The parser is deliberately implemented in Python: shlex.split gives the root
# an argv representation while treating shell syntax as data. This wrapper
# keeps the shipped helper's interface shell-native and lets the Python logic
# reuse the repository's protected-path policy through the sibling library.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly SCRIPT_DIR
readonly PROTECTED_LIB="$SCRIPT_DIR/lib/protected-paths.sh"
readonly REPO_CONFIG="$SCRIPT_DIR/repo-config.sh"

if ! command -v python3 > /dev/null 2>&1; then
    printf '%s: python3 is unavailable; validation evidence cannot be collected\n' \
        "${0##*/}" >&2
    exit 2
fi
if [[ ! -r $PROTECTED_LIB || ! -x $REPO_CONFIG ]]; then
    printf '%s: protected-path validation support is unavailable\n' "${0##*/}" >&2
    exit 2
fi

exec python3 - "$PROTECTED_LIB" "$REPO_CONFIG" "$@" <<'PY'
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path


PROTECTED_LIB = Path(sys.argv[1])
REPO_CONFIG = Path(sys.argv[2])
ARGS = sys.argv[3:]
PROGRAM = "validate-handback.sh"
SHIPPED_HELPER = PROTECTED_LIB.parent.parent / "worktree-commit.sh"


class InvalidHandback(Exception):
    """The evidence is readable, but the handback fails a publication rule."""


class UnavailableEvidence(Exception):
    """The validator cannot establish the facts required for a safe decision."""


def invalid(message):
    raise InvalidHandback(message)


def unavailable(message):
    raise UnavailableEvidence(message)


def parse_cli(args):
    worktree = None
    handback_file = None
    index = 0
    while index < len(args):
        option = args[index]
        if option in ("--worktree", "--handback-file"):
            if index + 1 >= len(args) or not args[index + 1]:
                invalid(f"{option} requires a value")
            target = "worktree" if option == "--worktree" else "handback_file"
            if locals()[target] is not None:
                invalid(f"{option} given more than once")
            if target == "worktree":
                worktree = args[index + 1]
            else:
                handback_file = args[index + 1]
            index += 2
            continue
        invalid(f"unknown option: {option}")
    if worktree is None or handback_file is None:
        invalid("usage: validate-handback.sh --worktree PATH --handback-file FILE")
    return worktree, handback_file


def resolve_existing(path_value, label):
    try:
        path = Path(path_value).resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        unavailable(f"cannot resolve {label}: {error}")
    return path


def resolve_inside(root, raw_path, label):
    if not raw_path or "\x00" in raw_path:
        invalid(f"{label} is empty or contains NUL")
    try:
        candidate = Path(raw_path)
        resolved = (candidate if candidate.is_absolute() else root / candidate).resolve(strict=False)
    except (OSError, RuntimeError, ValueError) as error:
        invalid(f"cannot canonicalize {label}: {error}")
    if resolved == root or root not in resolved.parents:
        invalid(f"{label} is outside the worktree: {raw_path}")
    return resolved


def run_evidence(command, *, text=False):
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=text,
        )
    except OSError as error:
        unavailable(f"could not run evidence command {command[0]}: {error}")
    if result.returncode != 0:
        unavailable(
            f"evidence command failed ({result.returncode}): {command[0]}"
        )
    return result


def read_handback(path):
    try:
        data = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        unavailable(f"cannot read handback file: {error}")
    if "\x00" in data:
        invalid("handback contains NUL bytes")
    try:
        return shlex.split(data, comments=False, posix=True)
    except ValueError as error:
        invalid(f"handback is not parseable shell-like argv: {error}")


def parse_handback(argv):
    if not argv:
        invalid("expected worktree-commit.sh as the only helper")
    try:
        helper = Path(argv[0]).resolve(strict=False)
        shipped_helper = SHIPPED_HELPER.resolve(strict=True)
    except (OSError, RuntimeError, ValueError) as error:
        unavailable(f"cannot resolve worktree-commit.sh helper: {error}")
    if helper != shipped_helper:
        invalid("expected worktree-commit.sh as the only helper")

    message = None
    body_seen = False
    trailers = []
    files = None
    index = 1
    while index < len(argv):
        option = argv[index]
        if option == "--":
            files = argv[index + 1 :]
            break
        if option in ("--message", "--body", "--trailer"):
            if index + 1 >= len(argv):
                invalid(f"{option} requires a value")
            value = argv[index + 1]
            index += 2
        elif option.startswith("--message="):
            option, value = "--message", option.split("=", 1)[1]
            index += 1
        elif option.startswith("--body="):
            option, value = "--body", option.split("=", 1)[1]
            index += 1
        elif option.startswith("--trailer="):
            option, value = "--trailer", option.split("=", 1)[1]
            index += 1
        else:
            invalid(f"unexpected helper argument before --: {option}")

        if option == "--message":
            if message is not None:
                invalid("--message given more than once")
            message = value
        elif option == "--body":
            if body_seen:
                invalid("--body given more than once")
            body_seen = True
        else:
            trailers.append(value)
    if files is None:
        invalid("handback must terminate options with --")
    if message is None:
        invalid("--message is required")
    if not files:
        invalid("at least one explicit file operand is required")
    return message, trailers, files


def read_config(root, key, *, optional=False):
    try:
        result = subprocess.run(
            [str(REPO_CONFIG), "--repo-root", str(root), "--get", key],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except OSError as error:
        unavailable(f"could not read repository configuration key {key}: {error}")
    if result.returncode == 1 and optional:
        return ""
    if result.returncode != 0:
        unavailable(f"could not read repository configuration key {key}")
    return result.stdout.rstrip("\n")


def changed_paths(root):
    result = run_evidence(
        [
            "git",
            "-C",
            str(root),
            "status",
            "--porcelain=v1",
            "-z",
            "--untracked-files=all",
        ]
    )
    records = result.stdout.split(b"\0")
    changed = set()
    index = 0
    while index < len(records) - 1:
        record = records[index]
        index += 1
        if not record:
            continue
        if len(record) < 4 or record[2:3] != b" ":
            unavailable("git status produced an unrecognized porcelain record")
        try:
            status = record[:2].decode("ascii")
            raw_path = os.fsdecode(record[3:])
        except UnicodeDecodeError as error:
            unavailable(f"git status contains an undecodable path: {error}")
        changed.add(resolve_inside(root, raw_path, "git status path"))
        if "R" in status or "C" in status:
            if index >= len(records) - 1 or not records[index]:
                unavailable("git status rename/copy record is incomplete")
            changed.add(resolve_inside(root, os.fsdecode(records[index]), "git status path"))
            index += 1
    return changed


def protected_pattern(root, relative_path, declared):
    command = [
        "bash",
        "-c",
        'source "$1" && shared_protected_pattern "$2" "$3" "$4" 0',
        "protected-path-check",
        str(PROTECTED_LIB),
        relative_path,
        str(root),
        declared,
    ]
    try:
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except OSError as error:
        unavailable(f"could not run protected-path policy: {error}")
    if result.returncode not in (0, 1):
        unavailable(f"protected-path policy failed ({result.returncode})")
    if result.returncode == 1:
        return ""
    return result.stdout.decode("utf-8", "replace")


def validate(root, handback_path):
    # A supplied worktree must be the repository root, not an arbitrary subdir.
    git_root = run_evidence(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True
    ).stdout.strip()
    if Path(git_root).resolve(strict=True) != root:
        unavailable("--worktree is not the git toplevel")

    argv = read_handback(handback_path)
    message, trailers, raw_files = parse_handback(argv)
    model = read_config(root, "AGENT_WORKER_MODEL")
    declared = read_config(root, "AGENT_PROTECTED_PATHS", optional=True)
    if not model.strip():
        unavailable("repository worker model is unavailable")

    if "\r" in message or "\n" in message:
        invalid("commit subject must be a single line")
    if not re.fullmatch(
        r"(?:build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test)"
        r"(?:\([^()]+\))?!?: .+",
        message,
    ):
        invalid("commit subject is not Conventional Commit syntax")

    trailer_pattern = re.compile(r"^Co-Authored-By: .+ <.+@.+>$")
    worker_trailers = [trailer for trailer in trailers if trailer.startswith("Co-Authored-By:")]
    if len(worker_trailers) != 1 or not trailer_pattern.fullmatch(worker_trailers[0]):
        invalid("expected one valid Co-Authored-By trailer")
    if "\r" in worker_trailers[0] or "\n" in worker_trailers[0]:
        invalid("Co-Authored-By trailer must be a single line")
    model_boundary = rf"(?<![A-Za-z0-9._:/-]){re.escape(model)}(?![A-Za-z0-9._:/-])"
    if not re.search(model_boundary, worker_trailers[0]):
        invalid("Co-Authored-By trailer does not carry the repository worker model")

    changed = changed_paths(root)
    explicit = []
    for raw_path in raw_files:
        resolved = resolve_inside(root, raw_path, "explicit path")
        relative = resolved.relative_to(root).as_posix()
        pattern = protected_pattern(root, relative, declared)
        if pattern:
            invalid(f"protected path is not publishable: {relative} ({pattern})")
        if resolved not in changed:
            invalid(f"explicit path is not changed: {raw_path}")
        explicit.append(resolved)
    if not explicit:
        invalid("at least one explicit file operand is required")
    return argv


def main():
    try:
        worktree_value, handback_value = parse_cli(ARGS)
        root = resolve_existing(worktree_value, "worktree")
        if not root.is_dir():
            unavailable("worktree is not a directory")
        handback_path = resolve_existing(handback_value, "handback file")
        if not handback_path.is_file():
            unavailable("handback file is not a regular file")
        argv = validate(root, handback_path)
        sys.stdout.buffer.write(b"".join(os.fsencode(value) + b"\0" for value in argv))
        return 0
    except InvalidHandback as error:
        print(f"{PROGRAM}: invalid handback: {error}", file=sys.stderr)
        return 1
    except UnavailableEvidence as error:
        print(f"{PROGRAM}: evidence unavailable: {error}", file=sys.stderr)
        return 2


raise SystemExit(main())
PY
