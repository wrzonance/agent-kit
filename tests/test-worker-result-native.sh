#!/usr/bin/env bash
# Native execution evidence is accepted once and missing proof gets one durable recovery.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
python3 - "$(dirname -- "$here")" <<'PY'
import hashlib, json, os, re, shlex, signal, subprocess, sys, tempfile, time
from pathlib import Path

helper=Path(sys.argv[1])/'agentkit/skills/.shared/scripts/worker-result.sh'
runner=helper.with_name('agent-run.sh')

def native_ids(repo):
    def query(flag):
        return subprocess.check_output([str(runner),'--dir',str(repo),'--cmd','test',flag],text=True).strip()
    return query('--execution-key'),query('--execution-lease-key')

with tempfile.TemporaryDirectory() as temp:
    root=Path(temp)

    def fixture(label, *, delay=0, exit_code=0, focus=False, mutate=False):
        repo=root/label; repo.mkdir(); agent=repo/'.agent'; agent.mkdir()
        def git(*args):
            return subprocess.check_output(['git','-C',str(repo),*args],text=True).strip()
        git('init','-q','-b','feat/result'); git('config','user.name','test')
        git('config','user.email','test@example.invalid')
        (repo/'.gitignore').write_text('.agent/\n')
        script=['#!/bin/sh','count=$(cat "$COUNT_FILE" 2>/dev/null || printf 0)',
                'count=$((count + 1))','printf %s "$count" > "$COUNT_FILE"']
        script+=['mkdir "$ACTIVE_DIR" 2>/dev/null || : > "$OVERLAP_FILE"',
                 'trap \'rmdir "$ACTIVE_DIR" 2>/dev/null || true\' EXIT']
        if delay: script.append(f'sleep {delay}')
        if mutate: script.append('printf dirty >> a.txt')
        script.append(f'exit {exit_code}')
        (repo/'check').write_text('\n'.join(script)+'\n'); (repo/'check').chmod(0o700)
        (repo/'a.txt').write_text('base\n'); git('add','.'); git('commit','-qm','base')
        base=git('rev-parse','HEAD')
        (repo/'a.txt').write_text('change\n'); git('commit','-qam','change')
        head=git('rev-parse','HEAD')
        config='AGENT_CMD_TEST=./check\n'
        if focus: config+='AGENT_CMD_TEST_FOCUS=./check %s\n'
        (agent/'config.env').write_text(config)
        plan=root/f'{label}-plan.json'; owners=root/f'{label}-owners.ndjson'
        state=root/f'{label}-state.json'; artifact=root/f'{label}-result.json'
        plan.write_text(json.dumps({'schemaVersion':1,'entries':[{'issue':905,'predictedWriteSet':['*.txt']}],
                                    'conflictMap':{'pairs':[],'revisions':[]}})+'\n')
        owners.write_text(json.dumps(dict(version=2,runId=label,attempt='attempt',workerId='worker',
                                          issue=905,worktree=str(repo),branch='feat/result',state='active',
                                          disposition='returned',heartbeatEpoch=1,evidence=''))+'\n')
        state.write_text(json.dumps({'rootReview':{'status':'pending'},'rootCi':{'status':'pending'}})+'\n')
        result=dict(schemaVersion=1,runId=label,attempt='attempt',workerId='worker',issue=905,
                    worktree=str(repo),branch='feat/result',baseSha=base,headSha=head,
                    writeSet=['*.txt'],touchedPaths=['a.txt'],push='not-pushed',
                    verification=[{'command':'test','status':'pass'}],
                    obligations=['root-review','root-ci','draft-pr','root-push'],findings=[],blocker=None)
        artifact.write_text(json.dumps(result)+'\n')
        for path in (plan,owners,state,artifact): path.chmod(0o600)
        count=root/f'{label}-count'; os.environ['COUNT_FILE']=str(count)
        os.environ['ACTIVE_DIR']=str(root/f'{label}-active')
        os.environ['OVERLAP_FILE']=str(root/f'{label}-overlap')
        current_attempt='attempt'
        def set_attempt(attempt):
            nonlocal current_attempt
            if attempt==current_attempt: return
            current_attempt=attempt
            result['attempt']=attempt; artifact.write_text(json.dumps(result)+'\n')
            with owners.open('a') as stream:
                stream.write(json.dumps(dict(version=2,runId=label,attempt=attempt,workerId='worker',
                                             issue=905,worktree=str(repo),branch='feat/result',state='active',
                                             disposition='returned',heartbeatEpoch=2,evidence=''))+'\n')
        def validate(expected, digest=None, *, attempt='attempt', recovery_timeout=None,
                     validation_helper=helper):
            set_attempt(attempt)
            argv=[str(validation_helper),'validate','--result',str(artifact),'--dispatch-plan',str(plan),
                  '--owners',str(owners),'--state',str(state),'--run-id',label,'--attempt',attempt,
                  '--worker-id','worker','--issue','905','--worktree',str(repo),'--base-sha',base,
                  '--required-check','test']
            if digest: argv+=['--log-sha256','test='+digest]
            if recovery_timeout is not None: argv+=['--native-recovery-timeout-seconds',str(recovery_timeout)]
            proc=subprocess.run(argv,capture_output=True,text=True)
            assert proc.returncode==expected,(label,expected,proc.returncode,proc.stdout,proc.stderr)
            return json.loads(proc.stdout)
        def executions():
            return int(count.read_text()) if count.exists() else 0
        def run_native(*extra):
            proc=subprocess.run([str(runner),'--dir',str(repo),'--cmd','test','--summary',*extra],
                                capture_output=True,text=True)
            return proc
        return repo,result,artifact,state,validate,executions,run_native

    # Missing evidence executes once, persists the allowance, and resumes without a rerun.
    repo,result,artifact,state,validate,executions,run_native=fixture('missing')
    first=validate(0)
    assert first['evidence']=='native-log' and executions()==1,first
    recovery=list(json.loads(state.read_text())['nativeRecoveries'].values())
    assert len(recovery)==1 and recovery[0]['status']=='pass',recovery
    logs_before=list((repo/'.agent/logs').glob('*.log'))
    resumed=validate(0)
    assert resumed['reused'] is True and executions()==1,resumed
    assert list((repo/'.agent/logs').glob('*.log'))==logs_before,'resume started another recovery'

    # Truthful missing-terminal status reaches the same bounded native recovery.
    repo,result,artifact,state,validate,executions,run_native=fixture('unknown-missing')
    result['verification'][0].update(status='unknown',reason='terminal proof missing')
    artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0)
    assert executions()==1 and accepted['evidence']=='native-log',accepted

    # A valid native proof is consumed directly with no acceptance execution.
    repo,result,artifact,state,validate,executions,run_native=fixture('valid')
    completed=run_native(); assert completed.returncode==0,completed.stderr
    summary=completed.stdout.splitlines()[-1]
    match=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',summary); assert match,summary
    result['verification'][0]['log']=match.group(1); artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0,match.group(2))
    assert accepted['evidence']=='native-log' and executions()==1,accepted
    assert 'nativeRecoveries' not in json.loads(state.read_text()),'valid proof must not consume recovery allowance'

    # A stale marker cannot hide complete independently pinned evidence.
    execution,lease=native_ids(repo); lease_dir=repo/'.agent/run-records/leases'/lease
    lease_dir.mkdir(parents=True,exist_ok=True); (lease_dir/'running').write_text(match.group(1)+'\n')
    accepted=validate(0,match.group(2),attempt='attempt2',recovery_timeout=0.1)
    assert executions()==1 and accepted['evidence']=='native-log',accepted

    # A stale marker with no proof is replaced by the single root recovery.
    repo,result,artifact,state,validate,executions,run_native=fixture('stale-missing')
    execution,lease=native_ids(repo); lease_dir=repo/'.agent/run-records/leases'/lease
    lease_dir.mkdir(parents=True); (lease_dir/'running').write_text(str(repo/'.agent/logs/stale.log')+'\n')
    accepted=validate(0,recovery_timeout=2)
    assert executions()==1 and accepted['evidence']=='native-log',accepted

    # A root recovery killed before it replaces stale proof cannot promote that proof.
    repo,result,artifact,state,validate,executions,run_native=fixture('killed-recovery')
    stale=run_native(); assert stale.returncode==0,stale.stderr
    shim=root/'killed-recovery-helpers'; shim.mkdir()
    for sibling in helper.parent.iterdir():
        if sibling.name!='agent-run.sh': (shim/sibling.name).symlink_to(sibling)
    (shim/'agent-run.sh').write_text(
        '#!/bin/sh\nfor arg do [ "$arg" != --force ] || kill -KILL $$; done\n'
        f'exec {shlex.quote(str(runner))} "$@"\n')
    (shim/'agent-run.sh').chmod(0o700)
    rejected=validate(2,recovery_timeout=2,validation_helper=shim/'worker-result.sh')
    assert executions()==1 and 'result' in rejected['reason'],rejected
    recovery=list(json.loads(state.read_text())['nativeRecoveries'].values())
    assert recovery[0]['status']=='incomplete',recovery

    # Evidence for the previous commit cannot establish the current candidate.
    repo,result,artifact,state,validate,executions,run_native=fixture('different-head')
    completed=run_native(); assert completed.returncode==0,completed.stderr
    (repo/'a.txt').write_text('new head\n')
    subprocess.check_call(['git','-C',str(repo),'commit','-qam','new head'])
    result['headSha']=subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip()
    artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0)
    assert executions()==2 and accepted['evidence']=='native-log',accepted

    # A commit changes evidence identity without opening a second worktree lease.
    repo,result,artifact,state,validate,executions,run_native=fixture('held-head',delay=2)
    old_execution,old_lease=native_ids(repo)
    owner=subprocess.Popen([str(runner),'--dir',str(repo),'--cmd','test','--summary'],
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=os.environ.copy())
    for _ in range(100):
        if list((repo/'.agent/run-records').rglob('running')): break
        time.sleep(0.02)
    else: raise AssertionError('held-head fixture did not publish its running record')
    (repo/'a.txt').write_text('new head while running\n')
    subprocess.check_call(['git','-C',str(repo),'commit','-qam','new head while running'])
    new_execution,new_lease=native_ids(repo)
    assert old_execution!=new_execution and old_lease==new_lease,(old_execution,new_execution,old_lease,new_lease)
    duplicate=run_native('--force')
    assert duplicate.returncode==2 and executions()==1,(duplicate.returncode,duplicate.stdout,duplicate.stderr)
    owner.communicate(timeout=5)

    # A known red result is rejected without rerunning until green.
    repo,result,artifact,state,validate,executions,run_native=fixture('known-red',exit_code=7)
    failed=run_native(); assert failed.returncode==7,failed.stdout
    failed_log=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',failed.stdout.splitlines()[-1])
    assert failed_log,failed.stdout
    result['verification'][0]['log']=failed_log.group(1); artifact.write_text(json.dumps(result)+'\n')
    rejected=validate(1,failed_log.group(2))
    assert 'verification failed' in rejected['reason'] and executions()==1,rejected
    assert 'nativeRecoveries' not in json.loads(state.read_text()),'known failure is not missing evidence'

    # A worker-known failure never consumes the missing-evidence recovery.
    repo,result,artifact,state,validate,executions,run_native=fixture('claimed-red')
    result['verification'][0].update(status='fail',reason='check exited nonzero')
    artifact.write_text(json.dumps(result)+'\n')
    rejected=validate(1)
    assert executions()==0 and 'verification failed' in rejected['reason'],rejected
    assert 'nativeRecoveries' not in json.loads(state.read_text()),'known failure consumed recovery'

    # Unknown status cannot bypass an explicitly non-local cache configuration.
    repo,result,artifact,state,validate,executions,run_native=fixture('configured-unknown')
    (repo/'.agent/config.env').write_text('AGENT_CMD_TEST=./check\nAGENT_VERIFY_TEST_MODE=external\n')
    result['verification'][0].update(status='unknown',reason='terminal proof missing')
    artifact.write_text(json.dumps(result)+'\n')
    refused=validate(2)
    assert executions()==0 and 'capability query failed' in refused['reason'],refused

    # A failed recovery is retained and resume cannot grant another attempt.
    repo,result,artifact,state,validate,executions,run_native=fixture('failed-recovery',exit_code=9)
    rejected=validate(1)
    assert executions()==1 and 'verification failed' in rejected['reason'],rejected
    rejected_again=validate(1)
    assert executions()==1 and 'verification failed' in rejected_again['reason'],rejected_again
    fresh_attempt=validate(1,attempt='attempt2')
    assert executions()==1 and 'verification failed' in fresh_attempt['reason'],fresh_attempt
    (repo/'.agent/config.env').write_text('AGENT_CMD_TEST=sh ./check\n')
    exhausted=validate(2,attempt='attempt3')
    assert executions()==1 and 'already used for this check and candidate head' in exhausted['reason'],exhausted

    # A bounded wait leaves the runner active; resume collects that same execution.
    repo,result,artifact,state,validate,executions,run_native=fixture('timed-active',delay=2)
    pending=validate(2,recovery_timeout=0.1)
    assert 'still active after bounded wait' in pending['reason'] and executions()==1,pending
    recovery=list(json.loads(state.read_text())['nativeRecoveries'].values())
    assert len(recovery)==1 and recovery[0]['status']=='started' and \
           recovery[0]['provenance']=='root-started' and recovery[0]['waitSpent'] is True,recovery
    assert len(list((repo/'.agent/run-records').rglob('running')))==1,'timeout erased active identity'
    started=time.monotonic(); still_pending=validate(2,recovery_timeout=2,attempt='attempt2')
    assert time.monotonic()-started<1 and executions()==1,still_pending
    for _ in range(150):
        if not list((repo/'.agent/run-records').rglob('running')): break
        time.sleep(0.02)
    else: raise AssertionError('timed recovery did not eventually finish')
    accepted=validate(0,attempt='attempt2')
    assert executions()==1 and accepted['evidence']=='native-log',accepted

    # A green command that dirties the checkout is not clean candidate evidence.
    repo,result,artifact,state,validate,executions,run_native=fixture('dirty-recovery',mutate=True)
    dirty=validate(1)
    assert executions()==1 and 'verification failed' in dirty['reason'],dirty

    # A foreign active run may be adopted only after root independently pins its summary.
    repo,result,artifact,state,validate,executions,run_native=fixture('foreign-pinned',delay=2)
    result['verification'][0].update(status='unknown',reason='execution still running')
    artifact.write_text(json.dumps(result)+'\n')
    owner=subprocess.Popen([str(runner),'--dir',str(repo),'--cmd','test','--summary'],
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=os.environ.copy())
    for _ in range(100):
        if list((repo/'.agent/run-records').rglob('running')): break
        time.sleep(0.02)
    else: raise AssertionError('foreign-pinned fixture did not publish its running record')
    pending=validate(2,recovery_timeout=0.1)
    started=time.monotonic(); pending_again=validate(2,recovery_timeout=2,attempt='attempt2')
    assert time.monotonic()-started<1 and executions()==1,pending_again
    owner_out,owner_err=owner.communicate(timeout=5)
    assert owner.returncode==0,(owner.returncode,owner_out,owner_err)
    match=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',owner_out.splitlines()[-1]); assert match
    accepted=validate(0,match.group(2),attempt='attempt3')
    recovery=list(json.loads(state.read_text())['nativeRecoveries'].values())
    assert executions()==1 and accepted['evidence']=='native-log' and \
           recovery[0]['provenance']=='foreign-active',(accepted,recovery)

    # Altered bytes cannot be replaced by the sidecar or trigger an automatic rerun.
    repo,result,artifact,state,validate,executions,run_native=fixture('tampered')
    completed=run_native(); summary=completed.stdout.splitlines()[-1]
    match=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',summary); assert match,summary
    log=Path(match.group(1)); result['verification'][0]['log']=str(log); artifact.write_text(json.dumps(result)+'\n')
    log.write_bytes(log.read_bytes()+b'altered\n')
    result['verification'][0].update(status='unknown',reason='terminal proof unavailable')
    artifact.write_text(json.dumps(result)+'\n')
    unknown=validate(2,match.group(2))
    assert 'log bytes changed' in unknown['reason'] and executions()==1,unknown

    # A foreign active execution is collected but cannot self-certify its digest.
    repo,result,artifact,state,validate,executions,run_native=fixture('active',delay=1)
    result['verification'][0].update(status='unknown',reason='execution still running')
    artifact.write_text(json.dumps(result)+'\n')
    owner=subprocess.Popen([str(runner),'--dir',str(repo),'--cmd','test','--summary'],
                           stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=os.environ.copy())
    for _ in range(100):
        if list((repo/'.agent/run-records').rglob('running')): break
        time.sleep(0.02)
    else: raise AssertionError('active fixture did not publish its running record')
    accepted=validate(0)
    owner_out,owner_err=owner.communicate(timeout=5)
    assert owner.returncode==0,(owner.returncode,owner_out,owner_err)
    recovery=list(json.loads(state.read_text())['nativeRecoveries'].values())
    assert executions()==2 and accepted['evidence']=='native-log',accepted
    assert recovery[0]['provenance']=='root-started','foreign result self-certified without root recovery'
    assert not (root/'active-overlap').exists(),'foreign collection overlapped root recovery'
    assert len(list((repo/'.agent/logs').glob('*.log')))==2,'foreign collection or recovery duplicated execution'

    # Focused evidence has another identity, so obtaining full proof requires one full recovery.
    repo,result,artifact,state,validate,executions,run_native=fixture('focused',focus=True)
    focused=subprocess.run([str(runner),'--dir',str(repo),'--cmd','test','--only','unit','--summary'],
                           capture_output=True,text=True)
    assert focused.returncode==0,focused.stderr
    match=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',focused.stdout.splitlines()[-1]); assert match
    result['verification'][0]['log']=match.group(1); artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0,match.group(2))
    assert executions()==2 and accepted['evidence']=='native-log',accepted

    # Wrong-command evidence cannot satisfy the requested command; one full test is recovered.
    repo,result,artifact,state,validate,executions,run_native=fixture('wrong-command')
    (repo/'.agent/config.env').write_text('AGENT_CMD_TEST=./check\nAGENT_CMD_LINT=./check\n')
    wrong=subprocess.run([str(runner),'--dir',str(repo),'--cmd','lint','--summary'],capture_output=True,text=True)
    assert wrong.returncode==0,wrong.stderr
    match=re.search(r' log=([^ ]+) log-sha256=([0-9a-f]{64}) receipt=',wrong.stdout.splitlines()[-1]); assert match
    result['verification'][0]['log']=match.group(1); artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0,match.group(2))
    assert executions()==2 and accepted['evidence']=='native-log',accepted

    # Interrupted evidence is incomplete and can consume only the one recovery allowance.
    repo,result,artifact,state,validate,executions,run_native=fixture('interrupted',delay=5)
    interrupted=subprocess.Popen([str(runner),'--dir',str(repo),'--cmd','test','--summary'],
                                 stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=os.environ.copy(),
                                 start_new_session=True)
    for _ in range(100):
        running=list((repo/'.agent/run-records').rglob('running'))
        if running:
            active_log=Path(running[0].read_text().strip())
            if active_log.exists() and len(active_log.read_text().splitlines())>=3 and executions()==1: break
        time.sleep(0.02)
    else: raise AssertionError('interrupted fixture did not publish its running record')
    os.killpg(interrupted.pid,signal.SIGTERM)
    interrupted_out,interrupted_err=interrupted.communicate(timeout=5)
    assert interrupted.returncode==130,(interrupted.returncode,interrupted_out,interrupted_err)
    match=re.search(r' log=([^ ]+) log-sha256=unavailable receipt=',interrupted_out.splitlines()[-1]); assert match
    result['verification'][0]['log']=match.group(1); artifact.write_text(json.dumps(result)+'\n')
    accepted=validate(0)
    assert executions()==2 and accepted['evidence']=='native-log',accepted

print('PASS: worker-result native evidence and bounded recovery')
PY
