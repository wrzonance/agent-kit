#!/usr/bin/env bash
# Structured handbacks are claims: check independent ownership, Git and logs.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
python3 - "$(dirname -- "$here")" <<'PY'
import json, re, subprocess, sys, tempfile
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
    (repo / '.agent/config.env').write_text('AGENT_CMD_TEST=true\n')
    # Consume real declared-command evidence, not a fixture mirroring the hash.
    run(str(helper.with_name('agent-run.sh')), '--dir', str(repo), '--cmd', 'test')
    cache = (repo / '.agent/verification-cache').read_text()
    match = re.fullmatch(r'([0-9a-f]{64}) cmd=test log=(.+) at=\S+ focus=\n', cache)
    assert match, cache
    key, log = match.group(1), Path(match.group(2))
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
    def save():
        write(source,result); invoke('write',0,'--input',source,'--output',artifact)
    def validate(expected=0):
        return invoke('validate',expected,'--result',artifact,'--dispatch-plan',plan,
                      '--owners',owners,'--state',state,'--run-id','run','--attempt','attempt',
                      '--worker-id','worker','--issue','729','--worktree',repo,'--base-sha',base,
                      '--required-check','test')
    save(); assert oct(artifact.stat().st_mode & 0o777) == '0o600'
    assert validate()['status'] == 'accepted'
    assert validate()['reused'] is True
    for field,value in [('workerId','other'),('headSha',base),('writeSet',['**']),
                        ('touchedPaths',[]),('findings',['unresolved bug']),('push','pushed')]:
        previous=result[field]; result[field]=value; save(); validate(1); result[field]=previous
    remote=root/'origin.git'; run('git','init','-q','--bare',str(remote))
    git('remote','add','origin',str(remote)); git('push','-q','origin','HEAD')
    result['push']='pushed'; save(); validate()
    run('git','--git-dir',str(remote),'update-ref','refs/heads/feat/result',base)
    # The cached origin ref still points at HEAD; query actual remote while
    # retaining independently valid verification claims for resume.
    assert validate(1)['claims']['verification']=='valid'
    git('remote','remove','origin'); result['push']='not-pushed'
    save()
    log.unlink(); unknown=validate(2)
    assert unknown['claims']['implementation'] == 'valid'
    assert unknown['claims']['verification'] == 'unknown'
    assert unknown['status'] == 'unknown'
    assert json.loads(state.read_text())['results']['attempt']['status'] == 'unknown'
    log.write_text('=== agent-run exited rc=0 after 1s\n')
    assert validate()['reused'] is False
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
    result['verification'][0]['fingerprint']='0'*64; save(); validate(2)
    result['verification'][0]['fingerprint']=key
    for status in ('skipped','unavailable','unknown','fail'):
        result['verification'][0]['status']=status; result['verification'][0]['reason']='not green'
        save(); validate(2 if status != 'fail' else 1)
    result['verification'][0]['status']='pass'; result['verification'][0].pop('reason')
    save()
    for declaration in ('AGENT_CMD_TEST=false\n', 'AGENT_CMD_TEST=true\nAGENT_RUNDIR_TEST=src\n',
                        'AGENT_CMD_TEST=true\nAGENT_CMD_TEST_KIND=format\n'):
        (repo / '.agent/config.env').write_text(declaration); validate(2)
    (repo / '.agent/config.env').write_text('AGENT_CMD_TEST=true\n')
    result['verification'][0]['command']='lint'; save(); validate(1)
    result['verification'][0]['command']='test'; save()
    receipt=validate()
    assert receipt['result']==str(artifact), 'resume needs the durable artifact pointer'
    assert json.loads(state.read_text())['rootReview']=={'status':'pending'}
    assert json.loads(state.read_text())['rootCi']=={'status':'pending'}
    (repo / '.agent/config.env').write_text('AGENT_CMD_TEST=true\nAGENT_RUNDIR_TEST=generic\n')
    assert 'root-review' in validate(2)['obligations']
    (repo / '.agent/config.env').write_text('AGENT_CMD_TEST=true\n')
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
