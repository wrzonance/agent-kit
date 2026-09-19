#!/usr/bin/env bash
# Structured handbacks are claims: check independent ownership, Git and logs.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
python3 - "$(dirname -- "$here")" <<'PY'
import copy, hashlib, json, os, re, subprocess, sys, tempfile
from pathlib import Path
helper = Path(sys.argv[1]) / 'agentkit/skills/.shared/scripts/worker-result.sh'
with tempfile.TemporaryDirectory() as temp:
    root = Path(temp); repo = root / 'repo'; repo.mkdir()
    def run(*args):
        return subprocess.check_output(args, text=True).strip()
    def git(*args):
        return run('git', '-C', str(repo), *args)
    git('init', '-q', '-b', 'feat/result'); git('config', 'user.name', 'test')
    git('config', 'user.email', 'test@example.invalid')
    (repo / '.gitignore').write_text('.agent/\n')
    (repo / 'a.txt').write_text('base\n'); git('add', '.'); git('commit', '-qm', 'base')
    base = git('rev-parse', 'HEAD')
    (repo / 'a.txt').write_text('change\n'); git('commit', '-qam', 'change')
    head = git('rev-parse', 'HEAD')
    (repo / '.agent/logs').mkdir(parents=True)
    tool=root/'worker-tool'; tool.write_text('#!/bin/sh\nexit 0\n'); tool.chmod(0o700)
    os.environ['PATH']=str(root)+os.pathsep+os.environ['PATH']
    local_declaration='AGENT_CMD_TEST=true\nAGENT_VERIFY_TEST_MODE=local\nAGENT_VERIFY_TEST_TOOLCHAIN=bash,true,worker-tool\n'
    (repo / '.agent/config.env').write_text(local_declaration)
    # Root trust comes from independently delivered runner output, not the
    # worker-writable integrity sidecar.
    runner_output = run(str(helper.with_name('agent-run.sh')), '--dir', str(repo), '--cmd', 'test', '--summary')
    summary = runner_output.splitlines()[-1]
    summary_match = re.search(r' log-sha256=([0-9a-f]{64}) receipt=', summary)
    assert summary_match, summary
    cache = (repo / '.agent/verification-cache').read_text()
    match = re.fullmatch(r'([0-9a-f]{64}) cmd=test log=(.+) at=\S+ focus=\n', cache)
    assert match, cache
    key, log = match.group(1), Path(match.group(2))
    digest_receipt = Path(str(log) + '.sha256')
    receipt_text = digest_receipt.read_text()
    assert re.fullmatch(r'[0-9a-f]{64}\n', receipt_text), receipt_text
    observed_digest = summary_match.group(1)
    assert not digest_receipt.is_symlink() and digest_receipt.stat().st_uid == os.getuid()
    assert oct(digest_receipt.stat().st_mode & 0o777) == '0o600'
    assert observed_digest == hashlib.sha256(log.read_bytes()).hexdigest()
    plan = root / 'plan.json'; owners = root / 'owners.ndjson'; state = root / 'run-state.json'
    def write(path, value):
        path.write_text(json.dumps(value) + '\n'); path.chmod(0o600)
    write(state, {'rootReview':{'status':'pending'},'rootCi':{'status':'pending'}})
    write(plan, {'schemaVersion':1, 'entries':[{'issue':729,'predictedWriteSet':['*.txt']}],
                 'conflictMap':{'pairs':[],'revisions':[]}})
    owner = dict(version=2,runId='run',attempt='attempt',workerId='worker',issue=729,
                 worktree=str(repo),branch='feat/result',state='active',disposition='returned',
                 heartbeatEpoch=1,evidence='')
    write(owners, owner)
    result = dict(schemaVersion=1,runId='run',attempt='attempt',workerId='worker',issue=729,
                  worktree=str(repo),branch='feat/result',baseSha=base,headSha=head,
                  writeSet=['*.txt'],touchedPaths=['a.txt'],push='not-pushed',
                  verification=[dict(command='test',status='pass',log=str(log),fingerprint=key)],
                  obligations=['root-review','root-ci','draft-pr','root-push'],findings=[],blocker=None)
    source = root / 'input.json'; artifact = root / 'result.json'
    def invoke(action, expected, *extra):
        proc = subprocess.run([str(helper), action, *map(str,extra)], capture_output=True,text=True)
        assert proc.returncode == expected, (action,expected,proc.returncode,proc.stdout,proc.stderr)
        assert 'Traceback' not in proc.stderr, proc.stderr
        return json.loads(proc.stdout) if proc.stdout else proc.stderr
    for help_args in (('--help',), ('write','--help')):
        help_result=subprocess.run([str(helper),*help_args],capture_output=True,text=True)
        assert help_result.returncode == 0, (help_args,help_result.stdout,help_result.stderr)
        assert help_result.stdout.startswith('usage: worker-result.sh '), help_result.stdout
        assert 'usage: - ' not in help_result.stdout, help_result.stdout
    write_help=subprocess.check_output([str(helper),'write','--help'],text=True)
    normalized_help=' '.join(write_help.split())
    assert 'schemaVersion, runId, attempt, workerId, issue, worktree, branch, baseSha, headSha' in normalized_help
    assert 'verification[].command' in normalized_help and '[a-z][a-z0-9-]*' in normalized_help
    assert 'agent-run.sh --cmd' in normalized_help
    def save():
        write(source,result); invoke('write',0,'--input',source,'--output',artifact)
    def validate(expected=0, digest=None):
        return invoke('validate',expected,'--result',artifact,'--dispatch-plan',plan,
                      '--owners',owners,'--state',state,'--run-id','run','--attempt','attempt',
                      '--worker-id','worker','--issue','729','--worktree',repo,'--base-sha',base,
                      '--required-check','test', *(['--log-sha256','test='+digest] if digest else []))
    save(); assert oct(artifact.stat().st_mode & 0o777) == '0o600'
    def rejected(label, mutate, *fragments):
        malformed=copy.deepcopy(result); mutate(malformed); write(source,malformed)
        receipt=invoke('write',1,'--input',source,'--output',artifact)
        reason=receipt['reason']
        assert all(fragment in reason for fragment in fragments), (label,reason,fragments)
        return reason
    malformed_cases = [
        ('missing field', lambda r:r.pop('findings'), 'result fields', 'missing', 'findings'),
        ('extra field', lambda r:r.update(extra=True), 'result fields', 'extra'),
        ('schema version', lambda r:r.update(schemaVersion=True), 'schemaVersion', 'integer 1'),
        ('issue', lambda r:r.update(issue=0), 'issue', 'positive integer'),
        ('worker id', lambda r:r.update(workerId=''), 'workerId', 'non-empty string without controls'),
        ('attempt', lambda r:r.update(attempt='bad attempt'), 'attempt', 'stable identifier'),
        ('worktree', lambda r:r.update(worktree='relative'), 'worktree', 'absolute path'),
        ('base sha', lambda r:r.update(baseSha='abc'), 'baseSha', '40 lowercase hexadecimal'),
        ('write set values', lambda r:r.update(writeSet=['src/**','src/**']), 'writeSet', 'unique non-empty strings'),
        ('touched values', lambda r:r.update(touchedPaths=['']), 'touchedPaths', 'unique non-empty strings'),
        ('write set required', lambda r:r.update(writeSet=[]), 'writeSet', 'non-empty'),
        ('touched path', lambda r:r.update(touchedPaths=['../outside']), 'touchedPaths', 'safe repository-relative paths'),
        ('obligations', lambda r:r.update(obligations=['root-review','root-ci','draft-pr','root-review']), 'obligations', 'unique non-empty strings'),
        ('findings', lambda r:r.update(findings=['']), 'findings', 'unique non-empty strings'),
        ('root obligations', lambda r:r.update(obligations=['root-review','root-ci']), 'obligations', 'root-review, root-ci, and draft-pr'),
        ('push value', lambda r:r.update(push='maybe'), 'push', 'pushed, not-pushed, or unknown'),
        ('root push', lambda r:r.update(obligations=['root-review','root-ci','draft-pr']), 'obligations', 'root-push'),
        ('verification list', lambda r:r.update(verification=[]), 'verification', 'non-empty list'),
        ('verification fields', lambda r:r.update(verification=[{'status':'pass'}]), 'verification[0] fields', 'expected command, status'),
        ('verification command line', lambda r:r['verification'][0].update(command='agent-run.sh --cmd test --summary'),
         'verification[0].command', "'agent-run.sh --cmd test --summary'", '[a-z][a-z0-9-]*', 'agent-run.sh --cmd'),
        ('verification status', lambda r:r['verification'][0].update(status='green'), 'verification[0].status', 'pass, fail, skipped, unavailable, or unknown'),
        ('verification value', lambda r:r['verification'][0].update(log=''), 'verification[0].log', 'non-empty string without controls'),
        ('verification reason', lambda r:r['verification'][0].update(status='fail'), 'verification[0].reason', 'required for non-pass'),
        ('duplicate command', lambda r:r.update(verification=[r['verification'][0],copy.deepcopy(r['verification'][0])]),
         'verification[].command', 'unique'),
        ('blocker', lambda r:r.update(blocker={'class':'other'}), 'blocker fields', 'expected class, remainingAction, evidence'),
    ]
    reasons=[rejected(*case) for case in malformed_cases]
    assert len(reasons)==len(set(reasons)), reasons
    save()
    # A successful fresh native run cannot create cache evidence when the
    # repository has not declared local verification capability. Acceptance
    # diagnoses the configuration gap before requesting an impossible rerun.
    (repo/'.agent/config.env').write_text('AGENT_CMD_TEST=true\n')
    native_output=run(str(helper.with_name('agent-run.sh')), '--dir', str(repo), '--cmd', 'test', '--force', '--summary')
    assert 'PASS:' in native_output,native_output
    unavailable=validate(2)
    assert unavailable['status']=='unknown',unavailable
    assert 'verification capability unavailable' in unavailable['reason'],unavailable
    assert 'AGENT_VERIFY_TEST_MODE=local,AGENT_VERIFY_TEST_TOOLCHAIN' in unavailable['reason'],unavailable
    assert 'authorize-native-evidence-handoff' in unavailable['reason'],unavailable
    assert 'evidence unavailable' not in unavailable['reason'],unavailable
    (repo/'.agent/config.env').write_text(local_declaration)
    cache_path=repo/'.agent/verification-cache'
    saved_cache=cache_path.read_bytes(); cache_path.unlink()
    absent=validate(2)
    assert 'evidence unavailable' in absent['reason'] and 'verification-cache' in absent['reason'],absent
    assert 'verification capability unavailable' not in absent['reason'],absent
    cache_path.write_bytes(saved_cache)
    assert validate(2)['claims']['implementation']=='valid', 'legacy cache alone cannot establish original log bytes'
    os.environ['LC_ALL']='agentkit_missing_locale'
    assert validate(digest=observed_digest)['status'] == 'accepted', 'harmless stderr must not corrupt the stdout fingerprint'
    os.environ.pop('LC_ALL')
    assert validate(digest=observed_digest)['status'] == 'accepted'
    assert validate()['reused'] is True
    # Durable execution state cannot be replaced by the legacy green index.
    record=repo/'.agent/verification-records'/key/'result'
    saved_record=record.read_bytes()
    for replacement in (None, f'7\n{log}\n{observed_digest}\n',
                        f'0\n{log}\n{"0"*64}\n', f'0\n{log}.other\n{observed_digest}\n'):
        if replacement is None: record.unlink()
        else: record.write_text(replacement)
        assert validate(2)['claims']['verification']=='unknown'
        record.write_bytes(saved_record)
    running=record.with_name('running'); running.write_text(str(log)+'\n')
    validate(2); running.unlink(); validate()
    running.symlink_to(root/'missing-running'); validate(2); running.unlink()
    for directory in (record.parent,record.parent.parent):
        moved=root/'moved-records'; directory.rename(moved)
        directory.symlink_to(moved,target_is_directory=True); validate(2)
        directory.unlink(); moved.rename(directory)
    tool.write_text('#!/bin/sh\nexit 1\n'); validate(2)
    tool.write_text('#!/bin/sh\nexit 0\n'); validate()
    # Config and declared tool bytes must remain current even on a clean HEAD.
    for suffix in ('AGENT_VERIFY_TEST_MODE=external\n', 'AGENT_VERIFY_TEST_INPUTS=a.txt\n',
                   'AGENT_VERIFY_TEST_TOOLCHAIN=bash,false\n'):
        (repo/'.agent/config.env').write_text('\n'.join(line for line in local_declaration.splitlines() if not line.startswith(suffix.split('=')[0]+'='))+'\n'+suffix); validate(2)
    (repo/'.agent/config.env').write_text(local_declaration); validate()
    result['verification'][0]['sha256']=observed_digest
    write(source,result); invoke('write',1,'--input',source,'--output',artifact)
    del result['verification'][0]['sha256']; save()  # Trust inputs are root CLI only.
    for field,value in [('workerId','other'),('headSha',base),('writeSet',['**']),
                        ('touchedPaths',[]),('findings',['unresolved bug']),('push','pushed')]:
        previous=result[field]; result[field]=value; save(); validate(1); result[field]=previous
    remote=root/'origin.git'; run('git','init','-q','--bare',str(remote))
    git('remote','add','origin',str(remote))
    git('push','-q','origin','HEAD:refs/heads/x/refs/heads/feat/result')
    result['push']='pushed'; save()
    assert 'root-push' in validate(1)['obligations'], 'slash-tail decoy is not publication'
    git('push','-q','origin','HEAD')
    run('git','--git-dir',str(remote),'update-ref','refs/heads/a/refs/heads/feat/result',base)
    validate()  # A wrong-SHA decoy sorts before the valid exact ref.
    run('git','--git-dir',str(remote),'update-ref','refs/heads/feat/result',base)
    # The cached origin ref still points at HEAD; query actual remote while
    # retaining independently valid verification claims for resume.
    assert validate(1)['claims']['verification']=='valid'
    git('remote','remove','origin'); result['push']='not-pushed'
    save()
    original_log=log.read_bytes()
    validate(2,digest='0'*64)  # A supplied conflicting digest cannot replace an existing pin.
    assert validate()['reused'] is False
    log.write_text('=== agent-run exited rc=0 after 1s\n'); unknown=validate(2)
    assert unknown['claims']['implementation'] == 'valid'
    assert unknown['claims']['verification'] == 'unknown'
    assert unknown['status'] == 'unknown'
    assert 'retained log bytes changed' in unknown['reason'],unknown
    assert json.loads(state.read_text())['results']['attempt']['status'] == 'unknown'
    validate(2,digest=hashlib.sha256(log.read_bytes()).hexdigest())  # Worker-derived replacement cannot clear the pin.
    pins=json.loads(state.read_text())['results']['attempt']['trustedLogs']
    assert any(pin['sha256']==observed_digest for pin in pins.values()), 'failed validation preserves original pins'
    log.write_bytes(original_log); validate(2)  # Restoring the same execution cannot clear invalidation.
    def fresh_execution():
        output=run(str(helper.with_name('agent-run.sh')), '--dir', str(repo), '--cmd', 'test', '--force', '--summary')
        terminal=output.splitlines()[-1]
        terminal_digest=re.search(r' log-sha256=([0-9a-f]{64}) receipt=',terminal)
        assert terminal_digest, terminal
        line=(repo/'.agent/verification-cache').read_text().splitlines()[-1]
        observed=re.fullmatch(r'([0-9a-f]{64}) cmd=test log=(.+) at=\S+ focus=',line)
        assert observed, line
        path=Path(observed.group(2))
        return observed.group(1), path, terminal_digest.group(1)
    key,log,observed_digest=fresh_execution()
    result['verification'][0].update(fingerprint=key,log=str(log)); save()
    validate(2); validate(digest=observed_digest)
    log.unlink(); validate(2)
    log.write_text('=== agent-run exited rc=0 after 1s\n'); validate(2)
    key,log,observed_digest=fresh_execution()
    result['verification'][0].update(fingerprint=key,log=str(log)); save()
    validate(digest=observed_digest)
    (repo / 'a.txt').write_text('dirty\n'); validate(1)
    result['blocker']={'class':'publication','remainingAction':'commit scoped a.txt',
                       'evidence':'commit refused'}
    save(); assert validate(3)['status']=='blocked'
    (repo / 'outside').write_text('mixed\n'); result['touchedPaths'].append('outside')
    save(); validate(1)
    (repo / 'outside').unlink(); result['touchedPaths']=['a.txt']; result['blocker']=None
    git('checkout','--','a.txt'); save()
    # Latest ownership supersedes an older worker, even after its handback.
    replacement=dict(owner,attempt='new',workerId='new')
    owners.write_text(json.dumps(owner)+'\n'+json.dumps(replacement)+'\n'); validate(1)
    write(owners,owner)
    result['verification'][0]['fingerprint']='0'*64; save()
    stale=validate(2)
    assert 'stale or unsupported tested-state fingerprint' in stale['reason'],stale
    result['verification'][0]['fingerprint']=key
    for status in ('skipped','unavailable','unknown','fail'):
        result['verification'][0]['status']=status; result['verification'][0]['reason']='not green'
        save(); validate(2 if status != 'fail' else 1)
    result['verification'][0]['status']='pass'; result['verification'][0].pop('reason')
    save()
    for declaration in ('AGENT_CMD_TEST=false\n', 'AGENT_CMD_TEST=true\nAGENT_RUNDIR_TEST=src\n',
                        'AGENT_CMD_TEST=true\nAGENT_CMD_TEST_KIND=format\n'):
        (repo / '.agent/config.env').write_text(declaration); validate(2)
    (repo / '.agent/config.env').write_text(local_declaration)
    result['verification'][0]['command']='lint'; save(); validate(1)
    result['verification'][0]['command']='test'; save()
    receipt=validate()
    assert receipt['result']==str(artifact), 'resume needs the durable artifact pointer'
    assert json.loads(state.read_text())['rootReview']=={'status':'pending'}
    assert json.loads(state.read_text())['rootCi']=={'status':'pending'}
    (repo / '.agent/config.env').write_text('AGENT_CMD_TEST=true\nAGENT_RUNDIR_TEST=generic\n')
    assert 'root-review' in validate(2)['obligations']
    (repo / '.agent/config.env').write_text(local_declaration)
    logs=repo/'.agent/logs'; moved=root/'outside-logs'
    logs.rename(moved); logs.symlink_to(moved,target_is_directory=True)
    validate(2)  # An in-worktree spelling cannot hide an external log directory.
    logs.unlink(); moved.rename(logs)
    original=artifact.read_bytes(); result['schemaVersion']=True; write(source,result)
    invoke('write',1,'--input',source,'--output',artifact)
    assert artifact.read_bytes()==original, 'failed write replaced accepted artifact'
    result['schemaVersion']=1; write(source,result)
    artifact.unlink(); artifact.symlink_to(source)
    invoke('write',1,'--input',source,'--output',artifact)
    artifact.unlink(); source.write_text('{"schemaVersion":1,"schemaVersion":2}')
    invoke('write',1,'--input',source,'--output',artifact)
print('PASS: worker-result independent evidence and atomic schema boundaries')
PY
