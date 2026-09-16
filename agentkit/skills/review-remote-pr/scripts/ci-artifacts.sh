#!/usr/bin/env bash
# Fetch evidence for one assigned CI failure. Run from the assigned worktree.
# REST docs: https://docs.github.com/en/rest/actions/artifacts
# https://docs.github.com/en/rest/actions/workflow-jobs
# Requires gh, git, Python 3. Exit 0 includes reported ABSENT/EXPIRED evidence;
# exit 2 means invalid input, unsafe archive, or incomplete API collection.
# --dest must be a dedicated directory strictly below this worktree's .agent/.
# Downloads are cached by immutable artifact/job IDs and bound to repo/run.
# Per invocation: 256 MiB artifact transfers, 1 GiB expanded, separate 64 MiB logs,
# 16 MiB inventories; 120s/request, 10,000 ZIP entries, 1000:1 ZIP ratio.
# Retained artifacts (including archives) are capped at download + expanded limits;
# cached bytes count, and retained logs share the log cap. Inventories are replaced.
# --max-download-bytes/--max-expanded-bytes/--max-log-bytes may lower these caps.
# Size skips and expired logs are reported without suppressing other evidence.
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import threading
import zipfile

MAX_DOWNLOAD_BYTES = 256 * 1024**2
MAX_EXPANDED_BYTES = 1024**3
MAX_LOG_BYTES = 64 * 1024**2
MAX_METADATA_BYTES = 16 * 1024**2
MARKER = 'validated\n'


class EvidenceError(Exception):
    pass


class SizeLimit(EvidenceError):
    pass


class Budget:
    def __init__(self, remaining):
        self.remaining = remaining

    def charge(self, count):
        self.remaining -= count
        if self.remaining < 0:
            self.remaining = 0
            raise SizeLimit('exceeds aggregate download budget')


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def identifier(value):
    require(re.fullmatch(r'[1-9][0-9]*', str(value)), 'invalid numeric ID')
    return str(value)


def api(endpoint, output, budget, space, paginate=False):
    # gh api follows the REST download redirect; never use server-supplied URLs.
    command = ['gh', 'api', endpoint, '--method', 'GET']
    if paginate:
        command += ['--paginate', '--slurp']
    if budget.remaining <= 0 or space <= 0:
        raise SizeLimit('exceeds aggregate size budget')
    with output.open('xb') as stream, output.with_suffix('.stderr').open('xb') as errors:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors) as process:
            deadline = threading.Timer(120, process.kill)
            deadline.start()
            try:
                size = 0
                while chunk := process.stdout.read(65536):
                    size += len(chunk)
                    budget.charge(len(chunk))
                    if size > space:
                        raise SizeLimit('exceeds retained evidence budget')
                    stream.write(chunk)
                code = process.wait()
                require(code >= 0, 'REST request terminated (120s deadline)')
            finally:
                deadline.cancel()
                if process.poll() is None:
                    process.kill()
    if code:
        detail = output.with_suffix('.stderr').read_text(errors='replace')
        if '(HTTP 410)' in detail:
            return False
        raise EvidenceError(f'REST request failed: {endpoint}: {detail[:2000]}')
    output.with_suffix('.stderr').unlink()
    return True


def records(endpoint, key, output, budget):
    require(api(endpoint, output, budget, MAX_METADATA_BYTES, True), f'listing unavailable: {endpoint}')
    pages = json.loads(output.read_text())
    require(isinstance(pages, list), 'invalid paginated response')
    result = []
    for page in pages:
        require(isinstance(page, dict) and isinstance(page.get(key), list), 'invalid listing')
        result.extend(page[key])
    return result


def extract(archive, target, expanded_space, retained_space):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        require(len(entries) <= 10000, 'archive exceeds entry limit')
        expanded = sum(i.file_size for i in entries)
        seen = set()
        for entry in entries:
            name = entry.filename
            path = PurePosixPath(name)
            require(name and not path.is_absolute() and '\\' not in name
                    and ':' not in name and all(p not in ('', '.', '..') for p in name.rstrip('/').split('/')),
                    'unsafe archive path')
            require(not any(ord(c) < 32 for c in name), 'unsafe archive filename')
            require(path not in seen, 'duplicate archive path')
            seen.add(path)
            kind = stat.S_IFMT(entry.external_attr >> 16)
            require(kind in (0, stat.S_IFREG, stat.S_IFDIR), 'unsafe archive file type')
            require(not entry.flag_bits & 1, 'encrypted archive unsupported')
            require(entry.file_size <= max(1, entry.compress_size) * 1000, 'archive compression ratio exceeds limit')
        if expanded > expanded_space or expanded > retained_space:
            raise SizeLimit('exceeds aggregate expanded/retained budget')
        # Every entry is validated before writing anything. Extract manually in a
        # fresh private directory; never restore archive permissions or symlinks.
        target.mkdir()
        for entry in entries:
            output = target / entry.filename
            if entry.is_dir():
                output.mkdir(parents=True, exist_ok=True)
            else:
                output.parent.mkdir(parents=True, exist_ok=True)
                with source.open(entry) as reader, output.open('xb') as writer:
                    shutil.copyfileobj(reader, writer)
        return expanded


def tree_bytes(directory):
    return sum(p.stat().st_size for p in directory.rglob('*') if p.is_file())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--job')
    parser.add_argument('--name')
    parser.add_argument('--dest', required=True)
    for name, maximum in (('download', MAX_DOWNLOAD_BYTES), ('expanded', MAX_EXPANDED_BYTES), ('log', MAX_LOG_BYTES)):
        parser.add_argument(f'--max-{name}-bytes', type=int, default=maximum,
                            help=f'lower aggregate {name} limit (maximum {maximum})')
    argv = sys.argv[1:]
    if argv[-1:] == ['--']:
        argv.pop()
    args = parser.parse_args(argv)
    for value, maximum in ((args.max_download_bytes, MAX_DOWNLOAD_BYTES),
                           (args.max_expanded_bytes, MAX_EXPANDED_BYTES), (args.max_log_bytes, MAX_LOG_BYTES)):
        require(0 < value <= maximum, 'byte limits must be positive and cannot exceed fixed maxima')
    require(re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', args.repo), 'expected OWNER/REPO')
    require(all(part not in ('.', '..') for part in args.repo.split('/')), 'invalid repository component')
    run = identifier(args.run_id)
    job = identifier(args.job) if args.job else None
    root = Path(subprocess.check_output(['git', 'rev-parse', '--show-toplevel'], text=True).strip()).resolve()
    cache = root / '.agent'
    require(not cache.is_symlink(), '.agent must not be a symlink')
    dest = Path(os.path.abspath(args.dest))
    require(dest.is_relative_to(cache) and dest != cache, '--dest must be below worktree .agent/')
    require(dest.resolve().is_relative_to(cache) and dest.resolve() != cache, '--dest escapes .agent/')
    for path in (dest, *dest.parents):
        if path == root:
            break
        require(not path.is_symlink(), 'destination contains symlink')
    if dest.exists():
        require(dest.is_dir(), 'destination must be a directory')
        require(not any(p.is_symlink() for p in dest.rglob('*')), 'cached evidence contains symlink')
    dest.mkdir(parents=True, exist_ok=True)
    require(not any(dest.glob('.fetch-*')), 'unfinished collection directory: resolve it before retrying')
    binding = dest / 'source.json'
    identity = {'repo': args.repo, 'run_id': run}
    if binding.exists():
        require(json.loads(binding.read_text()) == identity, 'destination belongs to another repo/run')
    else:
        require(not any(dest.iterdir()), 'destination must be empty on first use')
        with binding.open('x') as stream:
            json.dump(identity, stream)
    base = f'repos/{args.repo}/actions'
    retained = sum(tree_bytes(p) for p in dest.glob('artifact-*') if p.is_dir())
    expanded = sum(tree_bytes(p) for p in dest.glob('artifact-*/files') if p.is_dir())
    logs = sum(p.stat().st_size for p in dest.glob('job-*.log') if p.is_file())
    retained_limit = args.max_download_bytes + args.max_expanded_bytes
    require(retained <= retained_limit and expanded <= args.max_expanded_bytes and logs <= args.max_log_bytes,
            'existing evidence exceeds requested aggregate limits')
    transfers = Budget(args.max_download_bytes)
    log_transfers = Budget(args.max_log_bytes)
    metadata = Budget(MAX_METADATA_BYTES)
    with tempfile.TemporaryDirectory(prefix='.fetch-', dir=dest) as scratch:
        stage = Path(scratch)
        artifacts = records(f'{base}/runs/{run}/artifacts?per_page=100', 'artifacts', stage / 'artifacts.json', metadata)
        jobs = records(f'{base}/runs/{run}/jobs?filter=all&per_page=100', 'jobs', stage / 'jobs.json', metadata)
        if job:
            require(any(identifier(j['id']) == job for j in jobs), '--job does not belong to assigned run')
        for name in ('artifacts.json', 'jobs.json'):
            (stage / name).replace(dest / name)
        # Logs have their own allowance and are collected before artifact failures.
        selected_jobs = [j for j in jobs if identifier(j['id']) == job] if job else [
            j for j in jobs if j.get('conclusion') in ('failure', 'timed_out', 'cancelled', 'action_required', 'startup_failure')]
        if not selected_jobs:
            print('ABSENT failed-job logs: no matching jobs')
        for item in selected_jobs:
            jid = identifier(item['id'])
            final = dest / f'job-{jid}.log'
            if final.is_file():
                print(f'CACHED job {jid}: {final}')
                continue
            output = stage / f'job-{jid}.log'
            try:
                if not api(f'{base}/jobs/{jid}/logs', output, log_transfers, args.max_log_bytes - logs):
                    print(f'EXPIRED job logs: {jid}')
                    continue
                logs += output.stat().st_size
                output.rename(final)
                print(f'DOWNLOADED job {jid}: {final}')
            except SizeLimit as error:
                output.unlink(missing_ok=True)
                print(f'SKIPPED job logs: {jid}: {error}')
        selected = [a for a in artifacts if args.name is None or a['name'] == args.name]
        if not selected:
            print('ABSENT artifacts: no matching artifacts in assigned run')
        for artifact in selected:
            aid = identifier(artifact['id'])
            label = json.dumps(artifact['name'])
            final = dest / f'artifact-{aid}'
            if (final / 'complete').is_file():
                print(f'CACHED artifact {aid} {label}: {final}')
                continue
            if artifact.get('expired') is True:
                print(f'EXPIRED artifact {aid} {label}')
                continue
            require(not final.exists(), f'incomplete artifact destination: {final}')
            part = stage / f'artifact-{aid}'
            part.mkdir()
            try:
                if not api(f'{base}/artifacts/{aid}/zip', part / 'archive.zip', transfers, retained_limit - retained):
                    print(f'EXPIRED artifact {aid} {label}: HTTP 410')
                    continue
                added = extract(part / 'archive.zip', part / 'files', args.max_expanded_bytes - expanded,
                                retained_limit - retained - (part / 'archive.zip').stat().st_size - len(MARKER))
                (part / 'complete').write_text(MARKER)
                retained += tree_bytes(part)
                expanded += added
                part.rename(final)
                print(f'DOWNLOADED artifact {aid} {label}: {final}')
            except SizeLimit as error:
                shutil.rmtree(part)
                print(f'SKIPPED artifact {aid} {label}: {error}')


try:
    main()
except (EvidenceError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
    print(f'ci-artifacts: {error}', file=sys.stderr)
    sys.exit(2)
PY
