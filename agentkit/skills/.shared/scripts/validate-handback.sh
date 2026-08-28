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
import json
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
HAND_BACK_PARSE_ERROR = (
    "handback argv is empty or not parseable as a command; "
    "materialize the exact command into the handback file"
)


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
    dispatch_plan = None
    issue = None
    index = 0
    while index < len(args):
        option = args[index]
        if option == "--":
            index += 1
            if index < len(args):
                invalid(f"unexpected argument after --: {args[index]}")
            break
        if option in ("--worktree", "--handback-file", "--dispatch-plan", "--issue"):
            if index + 1 >= len(args) or not args[index + 1]:
                invalid(f"{option} requires a value")
            target = {
                "--worktree": "worktree",
                "--handback-file": "handback_file",
                "--dispatch-plan": "dispatch_plan",
                "--issue": "issue",
            }[option]
            if locals()[target] is not None:
                invalid(f"{option} given more than once")
            value = args[index + 1]
            if target == "worktree":
                worktree = value
            elif target == "handback_file":
                handback_file = value
            elif target == "dispatch_plan":
                dispatch_plan = value
            else:
                if not re.fullmatch(r"[1-9][0-9]*", value):
                    invalid("--issue requires a positive integer")
                issue = int(value)
            index += 2
            continue
        invalid(f"unknown option: {option}")
    if worktree is None or handback_file is None or dispatch_plan is None or issue is None:
        invalid(
            "usage: validate-handback.sh --worktree PATH --handback-file FILE "
            "--issue N --dispatch-plan FILE"
        )
    return worktree, handback_file, issue, dispatch_plan


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
    except ValueError:
        invalid(HAND_BACK_PARSE_ERROR)


DISPOSITION_KINDS = {"chain-conversion", "merge-down", "prediction-expansion"}


def validate_plan_pattern(value, label):
    if not isinstance(value, str) or not value or "\x00" in value:
        unavailable(f"dispatch plan {label} must be a non-empty string")
    if value.startswith("/") or "\\" in value or "\r" in value or "\n" in value:
        unavailable(f"dispatch plan {label} must be a repository-relative path or glob")
    if any(part in ("", ".", "..") for part in value.split("/")):
        unavailable(f"dispatch plan {label} contains an unsafe path: {value}")
    return value


def path_glob_matches(path, pattern):
    """Match repository paths with * for one segment and ** for any depth."""
    pieces = ["^"]
    index = 0
    while index < len(pattern):
        character = pattern[index]
        if character == "*":
            if index + 1 < len(pattern) and pattern[index + 1] == "*":
                index += 2
                if index < len(pattern) and pattern[index] == "/":
                    pieces.append("(?:.*/)?")
                    index += 1
                else:
                    pieces.append(".*")
                continue
            pieces.append("[^/]*")
        elif character == "?":
            pieces.append("[^/]")
        else:
            pieces.append(re.escape(character))
        index += 1
    pieces.append(r"\Z")
    return re.match("".join(pieces), path) is not None


def read_dispatch_plan(path, issue):
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        unavailable(f"dispatch plan is unreadable or invalid JSON: {error}")
    schema_version = document.get("schemaVersion") if isinstance(document, dict) else None
    if not isinstance(document, dict) or isinstance(schema_version, bool) \
            or schema_version not in (1, 2):
        unavailable("dispatch plan must be an object with schemaVersion 1 or 2")

    entries = document.get("entries")
    if not isinstance(entries, list) or not entries:
        unavailable("dispatch plan must contain a non-empty entries array")
    selected = None
    seen_issues = set()
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("issue"), int) \
                or isinstance(entry.get("issue"), bool) or entry["issue"] < 1:
            unavailable("each dispatch-plan entry must name a positive issue number")
        entry_issue = entry["issue"]
        if entry_issue in seen_issues:
            unavailable(f"dispatch plan contains duplicate issue entry: {entry_issue}")
        seen_issues.add(entry_issue)
        predicted = entry.get("predictedWriteSet")
        if not isinstance(predicted, list) or not predicted:
            unavailable(
                f"dispatch-plan entry for issue #{entry_issue} has no predictedWriteSet"
            )
        for number, pattern in enumerate(predicted):
            validate_plan_pattern(pattern, f"predictedWriteSet[{number}]")

        disposition = entry.get("writeSetDisposition")
        if disposition is not None:
            if not isinstance(disposition, dict):
                unavailable(
                    f"dispatch-plan entry for issue #{entry_issue} has an invalid writeSetDisposition"
                )
            kind = disposition.get("kind")
            if kind not in DISPOSITION_KINDS:
                unavailable(
                    f"dispatch-plan entry for issue #{entry_issue} has an unsupported disposition"
                )
            reason = disposition.get("reason")
            if not isinstance(reason, str) or not reason.strip():
                unavailable(
                    f"dispatch-plan entry for issue #{entry_issue} disposition needs a reason"
                )
            scope = disposition.get("paths")
            if not isinstance(scope, list) or not scope:
                unavailable(
                    f"dispatch-plan entry for issue #{entry_issue} disposition needs paths"
                )
            for number, pattern in enumerate(scope):
                validate_plan_pattern(pattern, f"writeSetDisposition.paths[{number}]")
        if entry_issue == issue:
            selected = (predicted, disposition)
    if selected is None:
        unavailable(f"dispatch plan has no entry for issue #{issue}")

    conflict_map = document.get("conflictMap")
    if not isinstance(conflict_map, dict):
        unavailable("dispatch plan must contain a conflictMap object")
    pairs = conflict_map.get("pairs")
    if not isinstance(pairs, list):
        unavailable("dispatch plan conflictMap.pairs must be an array")
    for pair in pairs:
        if not isinstance(pair, dict):
            unavailable("dispatch-plan conflictMap pairs must be objects")
        pair_issues = pair.get("issues")
        overlap = pair.get("overlap")
        if not isinstance(pair_issues, list) or len(pair_issues) != 2 or \
                any(not isinstance(value, int) or isinstance(value, bool) or value < 1
                    for value in pair_issues) or pair_issues[0] == pair_issues[1]:
            unavailable("each conflictMap pair must name two distinct issue numbers")
        if not isinstance(overlap, list) or not overlap:
            unavailable("each conflictMap pair must record an overlap")
        for number, pattern in enumerate(overlap):
            validate_plan_pattern(pattern, f"conflictMap.pairs.overlap[{number}]")
    revisions = conflict_map.get("revisions")
    if not isinstance(revisions, list):
        unavailable("dispatch plan conflictMap.revisions must be an array")
    for revision in revisions:
        if not isinstance(revision, dict) or not isinstance(revision.get("reason"), str) \
                or not revision["reason"].strip():
            unavailable("every conflict-map revision must record a reason")
        revision_issues = revision.get("issues")
        if revision_issues is not None:
            if not isinstance(revision_issues, list) or not revision_issues or \
                    any(not isinstance(value, int) or isinstance(value, bool) or value < 1
                        for value in revision_issues):
                unavailable("a conflict-map revision's issues must be positive issue numbers")
        revision_paths = revision.get("paths")
        if revision_paths is not None:
            if not isinstance(revision_paths, list) or not revision_paths:
                unavailable("a conflict-map revision's paths must be a non-empty array")
            for number, pattern in enumerate(revision_paths):
                validate_plan_pattern(pattern, f"conflictMap.revisions.paths[{number}]")
    if selected[1] is not None:
        if not revisions:
            unavailable(
                "an out-of-prediction disposition requires a conflict-map revision"
            )
        # A non-empty list proves only that SOME revision exists. Without binding
        # it to this issue and these paths, a revision recorded for another issue
        # -- or for an earlier, unrelated change -- authorizes this disposition,
        # and the operand ships with no conflict-map change of its own.
        disposition_paths = set(selected[1]["paths"])
        if not any(
            issue in (revision.get("issues") or [])
            and disposition_paths <= set(revision.get("paths") or [])
            for revision in revisions
        ):
            unavailable(
                f"an out-of-prediction disposition requires a conflict-map revision naming "
                f"issue #{issue} and covering its disposition paths"
            )
    return selected


def parse_handback(argv):
    if not argv:
        invalid(HAND_BACK_PARSE_ERROR)
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
    # The canonical path travels back to the caller so the emitted argv can name
    # the shipped helper rather than whatever argv[0] spelled. Resolving argv[0]
    # only proves what it pointed at during validation; a symlink retargeted
    # afterwards would otherwise hand root a worker-controlled program to run.
    return message, trailers, files, shipped_helper


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


def staged_paths(root):
    # worktree-commit.sh stages its explicit operands and then commits the whole
    # index, so anything the worker staged beforehand is published too. Its own
    # guard_staged_protected_paths only fires during an active merge, which
    # leaves the ordinary path ungated -- this set is what makes the explicit
    # operands a complete description of the commit rather than a subset of it.
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
    staged = set()
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
        index_status = status[0]
        if index_status not in (" ", "?", "!"):
            staged.add(resolve_inside(root, raw_path, "git status path"))
        if "R" in status or "C" in status:
            if index >= len(records) - 1 or not records[index]:
                unavailable("git status rename/copy record is incomplete")
            if index_status not in (" ", "?", "!"):
                staged.add(
                    resolve_inside(root, os.fsdecode(records[index]), "git status path")
                )
            index += 1
    return staged


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


def validate(root, handback_path, issue, dispatch_plan_path):
    # A supplied worktree must be the repository root, not an arbitrary subdir.
    git_root = run_evidence(
        ["git", "-C", str(root), "rev-parse", "--show-toplevel"], text=True
    ).stdout.strip()
    if Path(git_root).resolve(strict=True) != root:
        unavailable("--worktree is not the git toplevel")

    predicted, disposition = read_dispatch_plan(dispatch_plan_path, issue)
    argv = read_handback(handback_path)
    message, trailers, raw_files, shipped_helper = parse_handback(argv)
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
        if not any(path_glob_matches(relative, pattern) for pattern in predicted):
            if disposition is None:
                invalid(
                    f"explicit path is outside predicted write set: {relative}; "
                    "record chain-conversion, merge-down, or prediction-expansion "
                    "with a reason in the dispatch plan"
                )
            scope = disposition["paths"]
            if not any(path_glob_matches(relative, pattern) for pattern in scope):
                invalid(
                    f"explicit path is outside predicted write set and disposition scope: "
                    f"{relative} ({disposition['kind']})"
                )
        pattern = protected_pattern(root, relative, declared)
        if pattern:
            invalid(f"protected path is not publishable: {relative} ({pattern})")
        if resolved not in changed:
            invalid(f"explicit path is not changed: {raw_path}")
        explicit.append(resolved)
    if not explicit:
        invalid("at least one explicit file operand is required")

    # Everything already in the index is committed alongside the operands, so a
    # path staged but not declared would be published without ever reaching the
    # protected check above.
    explicit_set = set(explicit)
    for resolved in sorted(staged_paths(root)):
        relative = resolved.relative_to(root).as_posix()
        pattern = protected_pattern(root, relative, declared)
        if pattern:
            invalid(f"protected path is not publishable: {relative} ({pattern})")
        if resolved not in explicit_set:
            invalid(f"staged path is not declared: {relative}")

    return [str(shipped_helper)] + argv[1:]


def main():
    try:
        worktree_value, handback_value, issue, dispatch_plan_value = parse_cli(ARGS)
        root = resolve_existing(worktree_value, "worktree")
        if not root.is_dir():
            unavailable("worktree is not a directory")
        handback_path = resolve_existing(handback_value, "handback file")
        if not handback_path.is_file():
            unavailable("handback file is not a regular file")
        raw_dispatch_plan = Path(dispatch_plan_value)
        if raw_dispatch_plan.is_symlink():
            unavailable("dispatch plan must not be a symlink")
        dispatch_plan_path = resolve_existing(dispatch_plan_value, "dispatch plan")
        if not dispatch_plan_path.is_file():
            unavailable("dispatch plan is not a regular file")
        argv = validate(root, handback_path, issue, dispatch_plan_path)
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
