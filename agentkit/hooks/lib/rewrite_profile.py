import hashlib
import json
import os
import pwd
import re
import shlex
import stat
from pathlib import Path

OPERATOR_HOME = Path(pwd.getpwuid(os.getuid()).pw_dir)
TRUST_ROOT = OPERATOR_HOME / ".cache/agentkit/tool-rewrite/profiles"
HASH = re.compile(r"[a-f0-9]{64}")


class Unavailable(ValueError):
    pass


def decode(text):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Unavailable("duplicate JSON key")
            result[key] = value
        return result

    try:
        return json.loads(text, object_pairs_hook=unique,
                          parse_constant=lambda _: (_ for _ in ()).throw(Unavailable("nonfinite JSON")))
    except (ValueError, TypeError) as error:
        raise Unavailable("invalid JSON") from error


def canonical(path):
    path = Path(path)
    if not path.is_absolute() or path.resolve(strict=True) != path:
        raise Unavailable("noncanonical path")
    return path


def private(path, directory=False):
    path = canonical(path)
    info = path.stat()
    kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise Unavailable("nonprivate operator record")
    return path


def private_parents(path, anchor):
    path, anchor = canonical(path), canonical(anchor)
    if not path.is_relative_to(anchor):
        raise Unavailable("outside operator directory")
    while True:
        info = path.stat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise Unavailable("replaceable operator parent")
        if path == anchor:
            return
        path = path.parent


def fingerprint(path):
    path = canonical(path)
    digest = hashlib.sha256()
    entries = sorted(path.rglob("*")) if path.is_dir() else [path]
    for entry in entries:
        if "__pycache__" in entry.parts:
            continue
        entry = canonical(entry)
        if entry.is_dir():
            continue
        info = entry.stat()
        if not stat.S_ISREG(info.st_mode):
            raise Unavailable("unsupported bound file")
        relative = str(entry.relative_to(path)) if path.is_dir() else "file"
        digest.update(f"{relative}\0{stat.S_IMODE(info.st_mode)}\0".encode())
        with entry.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
    return digest.hexdigest()


def read_operator_profile(path):
    path = private(path)
    if path.parent != TRUST_ROOT or path.suffix != ".json":
        raise Unavailable("profile is outside operator trust root")
    private(TRUST_ROOT, directory=True)
    private_parents(TRUST_ROOT, OPERATOR_HOME)
    data = decode(path.read_text())
    if not isinstance(data, dict) or (
        data.get("schemaVersion"), data.get("adapter"), data.get("version"), data.get("tool")
    ) != (1, "claude", "2.1.272", "Bash") or data.get("approval") != "operator-reviewed":
        raise Unavailable("unsupported operator profile")
    for key in ("snapshotTemplateSha256", "pathSha256", "nativeSetupSha256"):
        if not isinstance(data.get(key), str) or not HASH.fullmatch(data[key]):
            raise Unavailable("missing profile identity")
    bindings = data.get("bindings")
    if not isinstance(bindings, dict) or not 1 <= len(bindings) <= 16:
        raise Unavailable("missing content bindings")
    for binding in bindings.values():
        if not isinstance(binding, dict) or set(binding) != {"path", "sha256"}:
            raise Unavailable("invalid content binding")
        if fingerprint(binding["path"]) != binding["sha256"]:
            raise Unavailable("changed trusted content")
    return data


def snapshot_path(snapshot):
    try:
        text = snapshot.decode("utf-8")
    except UnicodeError as error:
        raise Unavailable("invalid snapshot encoding") from error
    matches = list(re.finditer(r"^export PATH=([^\n]+)$", text, re.MULTILINE))
    if len(matches) != 1 or not re.fullmatch(r"[/A-Za-z0-9._:+-]+", matches[0][1]):
        raise Unavailable("unknown snapshot PATH")
    value = matches[0][1]
    if any(not part.startswith("/") for part in value.split(":")):
        raise Unavailable("relative or empty PATH entry")
    normalized = text[:matches[0].start(1)] + "<PATH>" + text[matches[0].end(1):]
    return normalized.encode(), value


def snapshot_identity(snapshot):
    normalized, path = snapshot_path(snapshot)
    return hashlib.sha256(normalized).hexdigest(), hashlib.sha256(path.encode()).hexdigest()


def check_environment(environment):
    startup = {"BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CLAUDE_ENV_FILE"}
    if any(key in startup or key.startswith(("BASH_FUNC_", "__BASH_FUNC<")) for key in environment):
        raise Unavailable("unapproved shell startup environment")


def native_input(command):
    match = re.fullmatch(
        r"source (?P<snapshot>/[-A-Za-z0-9._/]+)(?P<setup> .*? eval )"
        r"(?P<quoted>.+)(?P<tail> < /dev/null && pwd -P >\| )(?P<cwd>/[-A-Za-z0-9._/]+)",
        command, re.DOTALL)
    if match is None:
        raise Unavailable("unknown native envelope")
    try:
        words = shlex.split(match["quoted"])
    except ValueError as error:
        raise Unavailable("unknown native envelope") from error
    if len(words) != 1 or match["quoted"] not in (
        shlex.quote(words[0]), "'" + words[0].replace("'", "'\\''") + "'"
    ):
        raise Unavailable("unknown native command quoting")
    normalized = "source <SNAPSHOT>" + match["setup"] + "<COMMAND>" + match["tail"] + "<CWD>"
    return match["snapshot"], words[0], hashlib.sha256(normalized.encode()).hexdigest()


def check_path_absence(value, repository):
    try:
        repository = canonical(repository)
    except OSError as error:
        raise Unavailable("unproven repository lookup") from error
    for item in value.split(":"):
        if not item.startswith("/"):
            raise Unavailable("relative or empty PATH entry")
        try:
            directory = Path(item).resolve(strict=False)
            if directory.is_relative_to(repository):
                raise Unavailable("repository-controlled PATH directory")
            for parent in reversed((directory, *directory.parents)):
                try:
                    info = os.lstat(parent)
                except FileNotFoundError:
                    break
                if (not stat.S_ISDIR(info.st_mode) or not info.st_mode & 0o444
                        or not info.st_mode & 0o111 or not os.access(parent, os.R_OK | os.X_OK)):
                    raise Unavailable("unsearchable PATH directory")
                if info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX:
                    raise Unavailable("shared writable PATH directory")
                try:
                    os.lstat(parent / ".git")
                except FileNotFoundError:
                    pass
                else:
                    raise Unavailable("repository-controlled PATH directory")
            try:
                os.lstat(directory / "agent-run.sh")
            except FileNotFoundError:
                continue
        except OSError as error:
            raise Unavailable("unproven PATH lookup") from error
        raise Unavailable("existing helper PATH entry")
