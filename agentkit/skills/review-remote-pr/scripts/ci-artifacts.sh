#!/usr/bin/env bash
# Fetch evidence for one assigned CI failure. Run from the assigned worktree.
# REST docs: https://docs.github.com/en/rest/actions/artifacts
# https://docs.github.com/en/rest/actions/workflow-jobs
# Requires gh, git, Python 3. Exit 0 includes reported ABSENT/EXPIRED evidence;
# exit 2 means invalid input, unsafe archive, or incomplete API collection.
# --dest must be a dedicated directory strictly below this worktree's .agent/.
# Downloads are cached by immutable artifact/job IDs and bound to repo/run.
# Limits: 120s/request, 256 MiB/download, 1 GiB expanded, 10,000 entries, 1000:1 ZIP ratio.
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


class EvidenceError(Exception):
    pass


def require(condition, message):
    if not condition:
        raise EvidenceError(message)


def identifier(value):
    require(re.fullmatch(r'[1-9][0-9]*', str(value)), 'invalid numeric ID')
    return str(value)


def api(endpoint, output, paginate=False):
    # gh api follows the REST download redirect; never use server-supplied URLs.
    command = ['gh', 'api', endpoint, '--method', 'GET']
    if paginate:
        command += ['--paginate', '--slurp']
    with output.open('xb') as stream, output.with_suffix('.stderr').open('xb') as errors:
        with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors) as process:
            deadline = threading.Timer(120, process.kill)
            deadline.start()
            try:
                size = 0
                while chunk := process.stdout.read(65536):
                    size += len(chunk)
                    require(size <= 256 * 1024 * 1024, 'download exceeds 256 MiB limit')
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
    return True


def records(endpoint, key, output):
    require(api(endpoint, output, True), f'listing unavailable: {endpoint}')
    pages = json.loads(output.read_text())
    require(isinstance(pages, list), 'invalid paginated response')
    result = []
    for page in pages:
        require(isinstance(page, dict) and isinstance(page.get(key), list), 'invalid listing')
        result.extend(page[key])
    return result


def extract(archive, target):
    with zipfile.ZipFile(archive) as source:
        entries = source.infolist()
        require(len(entries) <= 10000, 'archive exceeds entry limit')
        require(sum(i.file_size for i in entries) <= 1024**3, 'archive exceeds expanded limit')
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


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo', required=True)
    parser.add_argument('--run-id', required=True)
    parser.add_argument('--job')
    parser.add_argument('--name')
    parser.add_argument('--dest', required=True)
    argv = sys.argv[1:]
    if argv[-1:] == ['--']:
        argv.pop()
    args = parser.parse_args(argv)
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
    binding = dest / 'source.json'
    identity = {'repo': args.repo, 'run_id': run}
    if binding.exists():
        require(json.loads(binding.read_text()) == identity, 'destination belongs to another repo/run')
    else:
        require(not any(dest.iterdir()), 'destination must be empty on first use')
        with binding.open('x') as stream:
            json.dump(identity, stream)
    base = f'repos/{args.repo}/actions'
    with tempfile.TemporaryDirectory(prefix='.fetch-', dir=dest) as scratch:
        stage = Path(scratch)
        artifacts = records(f'{base}/runs/{run}/artifacts?per_page=100', 'artifacts', stage / 'artifacts.json')
        jobs = records(f'{base}/runs/{run}/jobs?filter=all&per_page=100', 'jobs', stage / 'jobs.json')
        if job:
            require(any(identifier(j['id']) == job for j in jobs), '--job does not belong to assigned run')
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
            if not api(f'{base}/artifacts/{aid}/zip', part / 'archive.zip'):
                print(f'EXPIRED artifact {aid} {label}: HTTP 410')
                continue
            extract(part / 'archive.zip', part / 'files')
            (part / 'complete').write_text('validated\n')
            part.rename(final)
            print(f'DOWNLOADED artifact {aid} {label}: {final}')
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
            require(api(f'{base}/jobs/{jid}/logs', output), f'EXPIRED job logs: {jid}')
            output.rename(final)
            print(f'DOWNLOADED job {jid}: {final}')
        for name in ('artifacts.json', 'jobs.json'):
            (stage / name).replace(dest / name)


try:
    main()
except (EvidenceError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, subprocess.SubprocessError) as error:
    print(f'ci-artifacts: {error}', file=sys.stderr)
    sys.exit(2)
PY
