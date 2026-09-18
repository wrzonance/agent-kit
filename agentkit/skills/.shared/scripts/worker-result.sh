#!/usr/bin/env bash
# Atomic worker-result v1 artifacts; root independently checks every claim.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '{"status":"unknown","reason":"python3 unavailable; return text handback with evidence=unknown"}'
    exit 2
fi
exec python3 - "$script_dir" "$@" <<'PY'
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

HELPERS = Path(sys.argv[1])
class Rejected(Exception): pass
class Unknown(Exception): pass

def require(condition, reason):
    if not condition: raise Rejected(reason)

def read(path):
    p = Path(path)
    try:
        s = p.lstat()
        if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
            raise Unknown(f'evidence must be an owned regular non-symlink file: {p}')
        return p.read_bytes()
    except OSError as e: raise Unknown(f'evidence unavailable: {p}: {e.strerror}') from e

def document(path):
    def unique(pairs):
        result={}
        for key,value in pairs:
            require(key not in result, f'duplicate JSON field: {key}')
            result[key]=value
        return result
    try: return json.loads(read(path),object_pairs_hook=unique)
    except (ValueError, UnicodeError) as e: raise Rejected(f'invalid JSON: {path}') from e

def text(value):
    return isinstance(value, str) and bool(value.strip()) and not any(ord(c)<32 for c in value)

def strings(value):
    return isinstance(value, list) and all(text(v) for v in value) and len(value)==len(set(value))

def path_pattern(value):
    return text(value) and not value.startswith('/') and '\\' not in value and all(
        p not in ('', '.', '..') for p in value.split('/'))

def schema(r):
    fields = {'schemaVersion','runId','attempt','workerId','issue','worktree','branch','baseSha',
              'headSha','writeSet','touchedPaths','verification','push','obligations','findings','blocker'}
    require(isinstance(r,dict) and set(r)==fields, 'result requires exactly the documented v1 fields')
    require(type(r['schemaVersion']) is int and r['schemaVersion']==1, 'schemaVersion must be integer 1')
    require(type(r['issue']) is int and r['issue']>0, 'issue must be a positive integer')
    for key in ('runId','attempt','workerId','worktree','branch'):
        require(text(r[key]), f'{key} must be a non-empty string without controls')
    require(re.fullmatch(r'[A-Za-z0-9_-]+', r['attempt']), 'attempt must be a stable identifier')
    require(Path(r['worktree']).is_absolute(), 'worktree must be absolute')
    for key in ('baseSha','headSha'):
        require(isinstance(r[key],str) and re.fullmatch('[0-9a-f]{40}',r[key]), f'{key} must be a full SHA')
    for key in ('writeSet','touchedPaths','obligations','findings'):
        require(strings(r[key]), f'{key} must contain unique non-empty strings')
    require(r['writeSet'] and all(path_pattern(p) for p in r['writeSet']+r['touchedPaths']),
            'writeSet and touchedPaths must be safe repository-relative paths')
    require({'root-review','root-ci','draft-pr'} <= set(r['obligations']), 'root obligations must remain explicit')
    require(r['push'] in ('pushed','not-pushed','unknown'), 'push must be pushed, not-pushed or unknown')
    require(r['push']=='pushed' or 'root-push' in r['obligations'], 'unpublished work must retain root-push obligation')
    require(isinstance(r['verification'],list) and r['verification'], 'verification must name required checks')
    names=[]
    for v in r['verification']:
        require(isinstance(v,dict) and set(v) <= {'command','status','log','fingerprint','reason'} and
                {'command','status'} <= set(v), 'verification requires command and status')
        require(text(v['command']) and re.fullmatch('[a-z][a-z0-9-]*',v['command']), 'invalid verification command')
        require(v['status'] in ('pass','fail','skipped','unavailable','unknown'), 'invalid verification status')
        require(all(text(value) for value in v.values()), 'verification values must be non-empty strings')
        require(v['status']=='pass' or text(v.get('reason')), 'non-pass verification needs a reason')
        names.append(v['command'])
    require(len(names)==len(set(names)), 'duplicate verification command')
    b=r['blocker']
    require(b is None or (isinstance(b,dict) and set(b)=={'class','remainingAction','evidence'} and
            b['class'] in ('publication','write-set','baseline-red','filesystem','harness','other') and
            all(text(v) for v in b.values())), 'blocker requires a typed class, remainingAction and evidence')

def atomic(path, value):
    p=Path(path)
    require(not p.is_symlink() and (not p.exists() or (p.is_file() and p.stat().st_uid==os.getuid())),
            'output must be an owned regular non-symlink file')
    name=None
    try:
        fd,name=tempfile.mkstemp(prefix='.worker-result-',dir=p.parent)
        with os.fdopen(fd,'w') as f:
            json.dump(value,f,sort_keys=True); f.write('\n'); f.flush(); os.fsync(f.fileno())
        os.replace(name,p)
    except OSError as e: raise Unknown(f'cannot atomically write result: {e.strerror}') from e
    finally:
        if name and os.path.exists(name): os.unlink(name)

def command(argv):
    try: p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    except (OSError,subprocess.TimeoutExpired) as e: raise Unknown(f'evidence command unavailable: {argv[0]}') from e
    if p.returncode: raise Unknown(f'evidence command failed: {argv[0]} (exit {p.returncode})')
    return p.stdout

def matches(path, glob):
    # * never crosses a slash; **/ also matches zero directory components.
    regex=re.escape(glob).replace(r'\*\*/','(?:.*/)?').replace(r'\*\*','.*').replace(r'\*','[^/]*').replace(r'\?','[^/]')
    return re.fullmatch(regex,path) is not None

def verify(root, r, git, a):
    """Current local full-checkout evidence; unsupported handles stay unknown."""
    cache=read(root/'.agent/verification-cache').decode()
    observed=[]
    for v in r['verification']:
        if v['status']=='fail': raise Rejected(f"verification failed: {v['command']}")
        if v['status']!='pass': raise Unknown(f"verification {v['command']} is {v['status']}: {v['reason']}")
        name=v['command']
        if name not in ('test','lint','typecheck','coverage','verify','check'):
            raise Unknown(f'unsupported verification command: {name}')
        # The producer owns input/config/toolchain identity. This query cannot
        # execute commands or create records; unsupported scopes fail closed.
        fingerprint=command([str(HELPERS/'agent-run.sh'),'--dir',str(root),
                             '--cmd',name,'--verification-key']).decode().strip()
        if not re.fullmatch('[0-9a-f]{64}',fingerprint):
            raise Unknown(f'invalid current verification fingerprint: {name}')
        if v.get('fingerprint')!=fingerprint: raise Unknown(f'stale or unsupported tested-state fingerprint: {name}')
        log=Path(v.get('log',''))
        if not log.is_absolute() or root not in log.resolve().parents or log.parent.resolve()!= (root/'.agent/logs').resolve():
            raise Unknown(f'log must be inside worktree .agent/logs: {name}')
        expected=f'{fingerprint} cmd={name} log={log} at='
        if not any(line.startswith(expected) and line.endswith(' focus=') for line in cache.splitlines()):
            raise Unknown(f'no matching full-command verification record: {name}')
        handle=root/'.agent/verification-records'/fingerprint
        for directory in (root/'.agent',handle.parent,handle):
            info=directory.lstat()
            if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid():
                raise Unknown(f'verification directory must be owned and non-symlink: {directory}')
        if os.path.lexists(handle/'running'):
            raise Unknown(f'verification is running or interrupted: {name}')
        completed=read(handle/'result').decode().splitlines()
        if len(completed)!=3 or completed[0]!='0' or completed[1]!=str(log) or not re.fullmatch('[0-9a-f]{64}',completed[2]):
            raise Unknown(f'no matching completed successful verification: {name}')
        identity=hashlib.sha256(json.dumps([name,fingerprint,str(log)]).encode()).hexdigest()
        pin=a.trusted_logs.get(identity)
        supplied=a.root_digests.get(name)
        if pin is not None:
            require(isinstance(pin,dict) and pin.get('command')==name and pin.get('fingerprint')==fingerprint and
                    pin.get('log')==str(log) and isinstance(pin.get('sha256'),str) and
                    re.fullmatch('[0-9a-f]{64}',pin['sha256']), 'invalid trusted log pin in root receipt')
            if supplied is not None and supplied!=pin['sha256']:
                raise Unknown(f'conflicting root digest cannot replace retained execution pin: {name}')
            if pin.get('invalidated'):
                raise Unknown(f'retained log was invalidated; observe a new execution: {name}')
        elif supplied is None:
            raise Unknown(f'original log digest unavailable; root must observe an execution: {name}')
        expected_digest=pin['sha256'] if pin is not None else supplied
        try:
            data=read(log)
            if hashlib.sha256(data).hexdigest()!=expected_digest:
                raise Unknown(f'retained log bytes changed; observe a new execution: {name}')
            if not data.splitlines() or not re.fullmatch(rb'=== agent-run exited rc=0 after [0-9]+s', data.splitlines()[-1]):
                raise Unknown(f'log has no final successful completion marker: {name}')
        except Unknown:
            if pin is not None: pin['invalidated']=True
            raise
        if completed[2]!=expected_digest:
            raise Unknown(f'completed verification digest differs from root pin: {name}')
        a.trusted_logs[identity]=dict(command=name,fingerprint=fingerprint,log=str(log),sha256=expected_digest)
        observed.append([name,fingerprint,expected_digest])
    return observed

def validate(a,r,claims):
    root=Path(a.worktree).resolve(strict=True)
    git=lambda *args: command(['git','-C',str(root),*args])
    for key,expected in [('runId',a.run_id),('attempt',a.attempt),('workerId',a.worker_id),
                         ('issue',a.issue),('baseSha',a.base_sha),('worktree',str(root))]:
        require(r[key]==expected, f'{key} differs from root dispatch; use the assigned worker result')
    require(set(a.required_check)=={v['command'] for v in r['verification']},
            'verification commands differ from root-required checks')
    require(git('rev-parse','--show-toplevel').decode().strip()==str(root),'worktree must be the checkout root')
    plan=document(a.dispatch_plan)
    require(isinstance(plan,dict) and type(plan.get('schemaVersion')) is int and plan['schemaVersion'] in (1,2),
            'dispatch plan must use schemaVersion 1 or 2')
    entries=plan.get('entries')
    require(isinstance(entries,list) and all(isinstance(e,dict) for e in entries),'invalid dispatch entries')
    chosen=[e for e in entries if e.get('issue')==a.issue]
    require(len(chosen)==1,'dispatch plan must identify exactly one issue entry')
    entry=chosen[0]; predicted=entry.get('predictedWriteSet')
    require(strings(predicted) and predicted and all(path_pattern(p) for p in predicted),'invalid predictedWriteSet')
    allowed=list(predicted)
    if entry.get('writeSetDisposition'):
        d=entry['writeSetDisposition']; revisions=plan.get('conflictMap',{}).get('revisions',[])
        require(isinstance(d,dict) and d.get('kind') in ('chain-conversion','merge-down','prediction-expansion') and
                text(d.get('reason')) and strings(d.get('paths')) and d['paths'] and all(path_pattern(p) for p in d['paths']),
                'invalid write-set disposition')
        require(any(isinstance(v,dict) and a.issue in v.get('issues',[]) and text(v.get('reason')) and
                    set(d['paths'])<=set(v.get('paths',[])) for v in revisions),'disposition needs a matching conflict-map revision')
        allowed+=d['paths']
    require(set(r['writeSet'])==set(allowed),'writeSet differs from dispatch ownership')
    rows=[json.loads(line) for line in read(a.owners).splitlines() if line.strip()]
    require(all(isinstance(row,dict) for row in rows),'invalid ownership ledger row')
    owners=[row for row in rows if text(row.get('worktree')) and Path(row['worktree']).resolve()==root]
    require(bool(owners),'no independently recorded worker owner')
    owner=owners[-1]
    require(owner.get('version')==2 and all(owner.get(k)==r[k] for k in
            ('runId','attempt','workerId','issue','worktree','branch')), 'latest dispatch owner differs from result')
    require(owner.get('state')=='active' or (owner.get('state')=='terminal' and
            owner.get('disposition') in ('handed-back','completed')),'worker ownership is not handed back or running')
    claims['ownership']='valid'
    require(git('branch','--show-current').decode().strip()==r['branch'],'branch differs from result')
    require(git('rev-parse','HEAD').decode().strip()==r['headSha'],'headSha is stale')
    git('merge-base','--is-ancestor',a.base_sha,'HEAD')
    paths=set()
    for args in [('diff','--name-only','-z','--no-renames',a.base_sha,'HEAD'),
                 ('diff','--name-only','-z','--no-renames','HEAD'),('ls-files','--others','--exclude-standard','-z')]:
        paths.update(os.fsdecode(p) for p in git(*args).split(b'\0') if p)
    require(paths==set(r['touchedPaths']),'touchedPaths differs from actual committed and dirty paths')
    require(all(any(matches(p,g) for g in allowed) for p in paths),'actual touched path is outside assigned write set')
    dirty=bool(git('status','--porcelain=v1','--untracked-files=all'))
    require(not dirty or r['blocker'] is not None,'dirty or mixed worktree cannot be accepted as complete')
    require(not r['findings'],'unresolved findings prevent acceptance')
    claims['implementation']='dirty' if dirty else 'valid'
    if r['blocker'] is not None: return 'blocked', [owner,entry,r], 'preserve work; '+r['blocker']['remainingAction']
    # Push and local verification are independent: inspect both before returning
    # one actionable failure, so changing a remote cannot erase valid local work.
    failures=[]
    try:
        evidence=verify(root,r,git,a); claims['verification']='valid'
    except (Rejected,Unknown) as e: failures.append(e)
    try:
        if r['push']=='unknown': raise Unknown('push evidence is unknown')
        remotes=git('remote').decode().splitlines()
        expected_ref='refs/heads/'+r['branch']
        rows=git('ls-remote','--refs','origin',expected_ref).decode().splitlines() if 'origin' in remotes else []
        remote=[]
        for row in rows:
            fields=row.split()
            if len(fields)!=2 or not re.fullmatch('[0-9a-f]{40}',fields[0]):
                raise Unknown('remote returned an unparseable ref row')
            if fields[1]==expected_ref: remote.append(fields[0])
        if len(remote)>1: raise Unknown('remote returned duplicate exact branch refs')
        pushed=remote==[r['headSha']]
        require((r['push']=='pushed')==pushed,'claimed push state differs from remote branch evidence')
        claims['push']='valid'
    except (Rejected,Unknown) as e: failures.append(e)
    if failures: raise next((e for e in failures if isinstance(e,Rejected)),failures[0])
    return 'accepted', [owner,entry,r,evidence,remote], 'implementation handoff validated; root obligations remain open'

def load_receipt(a):
    require(re.fullmatch(r'[A-Za-z0-9_-]+',a.attempt), 'invalid root attempt identifier')
    old=subprocess.run([str(HELPERS/'run-state.sh'),'get','--file',a.state,'--path','results.'+a.attempt],
                       capture_output=True,text=True,timeout=20)
    if old.returncode not in (0,11): raise Unknown('run-state receipt unavailable; preserve existing state')
    prior=json.loads(old.stdout) if old.returncode==0 else {}
    require(isinstance(prior,dict), 'root result receipt must be an object')
    require(not prior or (prior.get('runId')==a.run_id and prior.get('workerId')==a.worker_id),
            'root receipt belongs to another run or worker; preserve its pins')
    return prior

def store_receipt(a,receipt):
    old=load_receipt(a)
    pins=old.get('trustedLogs',{})
    require(isinstance(pins,dict), 'trusted log pins must be an object')
    pins.update(getattr(a,'trusted_logs',{}))
    receipt.update(result=str(Path(a.result).absolute()),runId=a.run_id,workerId=a.worker_id,trustedLogs=pins)
    reused=old==receipt and receipt['status']=='accepted'
    command([str(HELPERS/'run-state.sh'),'set','--file',a.state,'--path','results.'+a.attempt,'--json',json.dumps(receipt)])
    return reused

def main():
    p=argparse.ArgumentParser(description='Write or independently validate worker-result v1; never execute worker commands.')
    sub=p.add_subparsers(dest='action',required=True)
    w=sub.add_parser('write'); w.add_argument('--input',required=True); w.add_argument('--output',required=True)
    v=sub.add_parser('validate')
    for name in ('result','dispatch-plan','owners','state','run-id','attempt','worker-id','worktree','base-sha'):
        v.add_argument('--'+name,required=True)
    v.add_argument('--issue',type=int,required=True)
    v.add_argument('--required-check',action='append',required=True)
    v.add_argument('--log-sha256',action='append',default=[],help='root-read runner receipt COMMAND=SHA256; never worker JSON')
    a=p.parse_args(sys.argv[2:]); claims={k:'unknown' for k in ('ownership','implementation','push','verification')}
    try:
        if a.action=='validate':
            a.trusted_logs=load_receipt(a).get('trustedLogs',{})
            require(isinstance(a.trusted_logs,dict), 'trusted log pins must be an object')
            a.root_digests={}
            for item in a.log_sha256:
                name,separator,digest=item.partition('=')
                require(separator and name in a.required_check and name not in a.root_digests and
                        re.fullmatch('[0-9a-f]{64}',digest), '--log-sha256 requires one root-read runner receipt COMMAND=SHA256 per check')
                a.root_digests[name]=digest
        r=document(a.input if a.action=='write' else a.result); schema(r)
        if a.action=='write': atomic(a.output,r); print(json.dumps({'result':a.output})); return 0
        status,evidence,reason=validate(a,r,claims)
        fingerprint=hashlib.sha256(json.dumps(evidence,sort_keys=True).encode()).hexdigest()
        receipt={'status':status,'claims':claims,'reason':reason,'fingerprint':fingerprint,
                 'obligations':r['obligations'],'blocker':r['blocker']}
        reused=store_receipt(a,receipt)
        print(json.dumps(dict(receipt,reused=reused))); return 0 if status=='accepted' else 3
    except (Rejected,Unknown,OSError,ValueError,TypeError,KeyError,AttributeError,subprocess.TimeoutExpired) as e:
        unknown=isinstance(e,(Unknown,OSError,subprocess.TimeoutExpired)); status='unknown' if unknown else 'rejected'
        receipt={'status':status,'reason':str(e),'claims':claims,'reused':False,
                 'obligations':['root-review','root-ci','draft-pr','root-push']}
        if a.action=='validate':
            try: store_receipt(a,receipt)
            except (Rejected,Unknown,OSError,ValueError,subprocess.TimeoutExpired):
                receipt['reason']+='; run-state update unavailable'; unknown=True
                receipt['status']='unknown'
        print(json.dumps(receipt))
        return 2 if unknown else 1
sys.exit(main())
PY
