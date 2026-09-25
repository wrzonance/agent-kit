#!/usr/bin/env bash
# Atomic worker-result v1 artifacts; root independently checks every claim and
# performs at most one retained native-evidence recovery per check and head.
set -euo pipefail
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
if ! command -v python3 >/dev/null 2>&1; then
    printf '%s\n' '{"status":"unknown","reason":"python3 unavailable; return text handback with evidence=unknown"}'
    exit 2
fi
exec python3 - "$script_dir" "$@" <<'PY'
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile
import time

HELPERS = Path(sys.argv[1])
RESULT_FIELDS = ('schemaVersion','runId','attempt','workerId','issue','worktree','branch','baseSha',
                 'headSha','writeSet','touchedPaths','verification','push','obligations','findings','blocker')
COMMAND_PATTERN = '[a-z][a-z0-9-]*'
class Rejected(Exception): pass
class Unknown(Exception): pass
class RecoveryNeeded(Unknown): pass

def require(condition, reason):
    if not condition: raise Rejected(reason)

def require_field(condition, field, value, expected):
    require(condition, f'invalid {field} {value!r}: expected {expected}')

def exact_fields(field, value, required, optional=()):
    require_field(isinstance(value,dict), field, value, 'an object')
    expected=set(required)|set(optional)
    missing=sorted(set(required)-set(value)); extra=sorted(set(value)-expected)
    suffix=f" and optional {', '.join(optional)}" if optional else ''
    require(not missing and not extra,
            f"invalid {field}: missing={missing!r} extra={extra!r}; expected {', '.join(required)}{suffix}")

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
    rf=require_field
    exact_fields('result fields',r,RESULT_FIELDS)
    rf(type(r['schemaVersion']) is int and r['schemaVersion']==1,'schemaVersion',r['schemaVersion'],'integer 1')
    rf(type(r['issue']) is int and r['issue']>0,'issue',r['issue'],'a positive integer')
    for key in ('runId','attempt','workerId','worktree','branch'):
        rf(text(r[key]),key,r[key],'a non-empty string without controls')
    rf(bool(re.fullmatch(r'[A-Za-z0-9_-]+',r['attempt'])),'attempt',r['attempt'],'a stable identifier matching [A-Za-z0-9_-]+')
    rf(Path(r['worktree']).is_absolute(),'worktree',r['worktree'],'an absolute path')
    for key in ('baseSha','headSha'):
        rf(isinstance(r[key],str) and bool(re.fullmatch('[0-9a-f]{40}',r[key])),key,r[key],'a full SHA of 40 lowercase hexadecimal characters')
    for key in ('writeSet','touchedPaths','obligations','findings'):
        rf(strings(r[key]),key,r[key],'a list of unique non-empty strings without controls')
    paths={'writeSet':r['writeSet'],'touchedPaths':r['touchedPaths']}
    rf(bool(r['writeSet']) and all(path_pattern(p) for values in paths.values() for p in values),
       'writeSet/touchedPaths',paths,'a non-empty writeSet and safe repository-relative paths')
    rf({'root-review','root-ci','draft-pr'}<=set(r['obligations']),'obligations',r['obligations'],'entries for root-review, root-ci, and draft-pr')
    rf(r['push'] in ('pushed','not-pushed','unknown'),'push',r['push'],'one of pushed, not-pushed, or unknown')
    rf(r['push']=='pushed' or 'root-push' in r['obligations'],'obligations',r['obligations'],'a root-push entry while push is unpublished')
    rf(isinstance(r['verification'],list) and bool(r['verification']),'verification',r['verification'],'a non-empty list naming required checks')
    names=[]
    for index,v in enumerate(r['verification']):
        prefix=f'verification[{index}]'
        exact_fields(f'{prefix} fields',v,('command','status'),('log','fingerprint','reason'))
        rf(text(v['command']) and bool(re.fullmatch(COMMAND_PATTERN,v['command'])),f'{prefix}.command',v['command'],
           f'the declared command NAME (agent-run.sh --cmd), matching {COMMAND_PATTERN}, not the command line')
        rf(v['status'] in ('pass','fail','skipped','unavailable','unknown'),f'{prefix}.status',v['status'],
           'one of pass, fail, skipped, unavailable, or unknown')
        invalid=next(((key,value) for key,value in v.items() if not text(value)),None)
        rf(invalid is None,f'{prefix}.{invalid[0]}' if invalid else prefix,invalid[1] if invalid else v,
           'a non-empty string without controls')
        rf(v['status']=='pass' or text(v.get('reason')),f'{prefix}.reason',v.get('reason'),'a non-empty string required for non-pass status')
        names.append(v['command'])
    rf(len(names)==len(set(names)),'verification[].command',names,'unique declared command names')
    b=r['blocker']
    if b is not None:
        exact_fields('blocker fields',b,('class','remainingAction','evidence'))
        rf(b['class'] in ('publication','write-set','baseline-red','filesystem','harness','other') and all(text(v) for v in b.values()),
           'blocker',b,'a typed class plus non-empty remainingAction and evidence strings')

def atomic(path, value):
    p=Path(path)
    require_field(not p.is_symlink() and (not p.exists() or (p.is_file() and p.stat().st_uid==os.getuid())),
                  'output', str(p), 'a missing path or an owned regular non-symlink file')
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

def verification_capability(root, name):
    argv=[str(HELPERS/'agent-run.sh'),'--dir',str(root),'--cmd',name,'--verification-key']
    try: p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    except (OSError,subprocess.TimeoutExpired) as e: raise Unknown(f'verification capability query unavailable: {name}') from e
    fingerprint=p.stdout.decode(errors='replace').strip()
    error=p.stderr.decode(errors='replace').strip()
    if p.returncode and 'reason=mode-not-local' in error and \
            'declarations=mode-absent,toolchain-absent' in error:
        return None,error
    if p.returncode or not re.fullmatch('[0-9a-f]{64}',fingerprint):
        raise Unknown(f'verification capability query failed: {name} (exit {p.returncode})')
    return fingerprint,None

def execution_key(root, name):
    argv=[str(HELPERS/'agent-run.sh'),'--dir',str(root),'--cmd',name,'--execution-key']
    try: p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    except (OSError,subprocess.TimeoutExpired) as e: raise Unknown(f'native execution query unavailable: {name}') from e
    key=p.stdout.decode(errors='replace').strip()
    if p.returncode or not re.fullmatch('[0-9a-f]{64}',key):
        raise Unknown(f'native execution capability unavailable: {name} (exit {p.returncode})')
    return key

def execution_lease_key(root, name):
    argv=[str(HELPERS/'agent-run.sh'),'--dir',str(root),'--cmd',name,'--execution-lease-key']
    try: p=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
    except (OSError,subprocess.TimeoutExpired) as e: raise Unknown(f'native execution lease query unavailable: {name}') from e
    key=p.stdout.decode(errors='replace').strip()
    if p.returncode or not re.fullmatch('[0-9a-f]{64}',key):
        raise Unknown(f'native execution lease unavailable: {name} (exit {p.returncode})')
    return key

def native_record(path):
    fields=read(path).split(b'\0')
    if fields and fields[-1]==b'': fields.pop()
    if not fields or fields.pop(0)!=b'native-v1' or len(fields)%2:
        raise Unknown(f'invalid native execution record: {path}')
    try: decoded=[part.decode() for part in fields]
    except UnicodeDecodeError as e: raise Unknown(f'invalid native execution record encoding: {path}') from e
    record={}
    for key,value in zip(decoded[::2],decoded[1::2]):
        if key in record: raise Unknown(f'duplicate native execution field: {key}')
        record[key]=value
    expected={'rc','command','key','head','worktree','scope','clean','log','sha256'}
    if set(record)!=expected: raise Unknown(f'invalid native execution record fields: {path}')
    return record

def lease_active(root, lease, name):
    handle=root/'.agent/run-records/leases'/lease
    if not os.path.lexists(handle): return False
    for directory in (handle.parent,handle):
        try: info=directory.lstat()
        except OSError as e: raise Unknown(f'native execution lease unavailable: {name}') from e
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid():
            raise Unknown(f'native execution lease directory must be owned and non-symlink: {directory}')
    running=handle/'running'
    if os.path.lexists(running):
        info=running.lstat()
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():
            raise Unknown(f'native execution running record must be owned and non-symlink: {name}')
    lock=handle/'lock'
    if not os.path.lexists(lock): return False
    try:
        fd=os.open(lock,os.O_RDWR|os.O_NOFOLLOW)
        info=os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid():
            raise Unknown(f'native execution lock must be owned and non-symlink: {name}')
        try: fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: return True
        else:
            fcntl.flock(fd,fcntl.LOCK_UN)
            return False
    except OSError as e: raise Unknown(f'native execution lock unavailable: {name}') from e
    finally:
        if 'fd' in locals(): os.close(fd)

def recovery_id(root, name, head):
    return hashlib.sha256(json.dumps([str(root),name,head]).encode()).hexdigest()

def load_native_recovery(a, root, name, head):
    recovery=recovery_id(root,name,head)
    old=subprocess.run([str(HELPERS/'run-state.sh'),'get','--file',a.state,
                        '--path','nativeRecoveries.'+recovery],capture_output=True,text=True,timeout=20)
    if old.returncode not in (0,11): raise Unknown('native recovery state unavailable; preserve existing state')
    prior=json.loads(old.stdout) if old.returncode==0 else None
    require(prior is None or isinstance(prior,dict), 'native recovery state must be an object')
    return recovery,prior

def persist_recovery(a, recovery, prior, reason):
    command([str(HELPERS/'run-state.sh'),'set','--file',a.state,
             '--path','nativeRecoveries.'+recovery,'--json',json.dumps(prior)])
    receipt={'status':'unknown','reason':reason,'claims':a.claims,'reused':False,
             'obligations':['root-review','root-ci','draft-pr','root-push']}
    store_receipt(a,receipt)

def collect_native_recovery(root, name, key, lease, a):
    head=command(['git','-C',str(root),'rev-parse','HEAD']).decode().strip()
    recovery,prior=load_native_recovery(a,root,name,head)
    handle=root/'.agent/run-records'/key
    active=lease_active(root,lease,name)
    if prior is not None:
        if not isinstance(prior,dict) or prior.get('command')!=name or prior.get('head')!=head or \
                prior.get('lease')!=lease:
            raise Unknown(f'invalid retained native recovery state: {name}')
        if prior.get('key')!=key:
            raise Unknown(f'native recovery already used for this check and candidate head: {name}')
        if prior.get('status') in ('pass','fail'):
            if prior.get('provenance')=='root-started': a.root_digests[name]=prior.get('sha256','')
            return prior.get('log','')
        if prior.get('status')!='started':
            raise Unknown(f'native recovery already exhausted with status={prior.get("status")}: {name}')
    else:
        prior={'command':name,'head':head,'key':key,'lease':lease,'status':'started',
               'provenance':'foreign-active' if active else 'pending',
               'rootRecoveryUsed':False,'waitSpent':False}
        persist_recovery(a,recovery,prior,f'native recovery started: {name}')

    if active:
        if prior.get('waitSpent'):
            raise Unknown(f'native recovery still active; resume after its owner completes: {name}')
        prior['waitSpent']=True
        persist_recovery(a,recovery,prior,f'observing active native execution once: {name}')
        deadline=time.monotonic()+a.native_recovery_timeout_seconds
        while lease_active(root,lease,name) and time.monotonic()<deadline: time.sleep(0.1)
        if lease_active(root,lease,name):
            persist_recovery(a,recovery,prior,f'native recovery still active after bounded wait: {name}')
            raise Unknown(f'native recovery still active after bounded wait: {name}')

    record=None
    try: record=native_record(handle/'result')
    except Unknown:
        if prior.get('rootRecoveryUsed'):
            prior['status']='incomplete'
            persist_recovery(a,recovery,prior,f'native recovery produced no complete record: {name}')
            raise
    if record is not None:
        trusted=prior.get('provenance')=='root-started'
        identity=hashlib.sha256(json.dumps(['native-log',name,key,record['log']]).encode()).hexdigest()
        independently_pinned=name in a.root_digests or identity in a.trusted_logs
        if record['rc']!='0' or trusted or independently_pinned:
            prior.update(status='pass' if record['rc']=='0' else 'fail',log=record['log'])
            if trusted: prior['sha256']=record['sha256']; a.root_digests[name]=record['sha256']
            persist_recovery(a,recovery,prior,f'native recovery completed status={prior["status"]}: {name}')
            return record['log']

    prior.update(provenance='root-starting',rootRecoveryUsed=True,waitSpent=True)
    persist_recovery(a,recovery,prior,f'root native recovery starting: {name}')
    try:
        process=subprocess.Popen([str(HELPERS/'agent-run.sh'),'--dir',str(root),'--cmd',name,
                                  '--force','--summary'],stdout=subprocess.DEVNULL,
                                 stderr=subprocess.DEVNULL,start_new_session=True)
    except OSError as e: raise Unknown(f'native recovery unavailable: {name}') from e
    try: returncode=process.wait(timeout=a.native_recovery_timeout_seconds)
    except subprocess.TimeoutExpired:
        prior['provenance']='root-started'
        persist_recovery(a,recovery,prior,f'native recovery still active after bounded wait: {name}')
        raise Unknown(f'native recovery still active after bounded wait: {name}')
    if returncode==2:
        prior['provenance']='foreign-active'
        persist_recovery(a,recovery,prior,f'native recovery lease was claimed concurrently: {name}')
        raise Unknown(f'native recovery lease was claimed concurrently; resume after its owner completes: {name}')
    prior['provenance']='root-started'
    try: record=native_record(handle/'result')
    except Unknown:
        prior['status']='incomplete'
        persist_recovery(a,recovery,prior,f'native recovery produced no complete record: {name}')
        raise
    prior.update(status='pass' if record['rc']=='0' else 'fail',log=record['log'],sha256=record['sha256'])
    persist_recovery(a,recovery,prior,f'native recovery completed status={prior["status"]}: {name}')
    a.root_digests[name]=record['sha256']
    return record['log']

def trusted_log(a, name, fingerprint, log, record_digest, source):
    identity_fields=[name,fingerprint,str(log)] if source=='verification-cache' else [source,name,fingerprint,str(log)]
    identity=hashlib.sha256(json.dumps(identity_fields).encode()).hexdigest()
    pin=a.trusted_logs.get(identity); supplied=a.root_digests.get(name)
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
    except Unknown:
        if pin is not None: pin['invalidated']=True
        raise
    if record_digest!=expected_digest:
        raise Unknown(f'completed verification digest differs from root pin: {name}')
    a.trusted_logs[identity]=dict(command=name,fingerprint=fingerprint,log=str(log),sha256=expected_digest)
    return data,expected_digest

def verify_native(root, v, name, key, lease, a, recovered_log=None):
    handle=root/'.agent/run-records'/key
    for directory in (root/'.agent',handle.parent,handle):
        try: info=directory.lstat()
        except OSError as e: raise RecoveryNeeded(f'native execution record unavailable: {name}') from e
        if not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid():
            raise Unknown(f'native execution directory must be owned and non-symlink: {directory}')
    if lease_active(root,lease,name):
        raise RecoveryNeeded(f'native verification is running or interrupted: {name}')
    if not os.path.lexists(handle/'result'):
        raise RecoveryNeeded(f'native execution result unavailable: {name}')
    record=native_record(handle/'result')
    if record['rc']!='0': raise Rejected(f'verification failed: {name} (exit {record["rc"]})')
    head=command(['git','-C',str(root),'rev-parse','HEAD']).decode().strip()
    expected=dict(command=name,key=key,head=head,worktree=str(root),scope='full',clean='yes')
    for field,value in expected.items():
        if record[field]!=value: raise Unknown(f'native execution {field} differs from current check: {name}')
    log=Path(recovered_log if recovered_log is not None else v.get('log',''))
    if str(log)!=record['log'] or not log.is_absolute() or root not in log.resolve().parents or \
            log.parent.resolve()!=(root/'.agent/logs').resolve():
        raise RecoveryNeeded(f'log must match the native record inside worktree .agent/logs: {name}')
    if not re.fullmatch('[0-9a-f]{64}',record['sha256']):
        raise Unknown(f'invalid native execution digest: {name}')
    identity=hashlib.sha256(json.dumps(['native-log',name,key,str(log)]).encode()).hexdigest()
    if a.trusted_logs.get(identity) is None and a.root_digests.get(name) is None:
        raise RecoveryNeeded(f'original native log digest unavailable: {name}')
    data,digest=trusted_log(a,name,key,log,record['sha256'],'native-log')
    lines=data.splitlines()
    expected_meta=f'=== execution-v1 command={name} key={key} scope=full'.encode()
    started=(rb'=== started \S+  pid=[0-9]+  process-start=\S+  epoch=[0-9]+  cwd=' +
             re.escape(os.fsencode(str(root))) + rb'  concurrent-suites=[0-9]+  head=' +
             head.encode() + rb'  tracked-clean=yes')
    if len(lines)<4 or not lines[0].startswith(b'=== agent-run ') or not re.fullmatch(started,lines[1]) or \
            lines[2]!=expected_meta or not re.fullmatch(rb'=== agent-run exited rc=0 after [0-9]+s',lines[-1]):
        raise Unknown(f'native log does not prove a completed clean full execution: {name}')
    try: sidecar=read(Path(str(log)+'.sha256')).decode().strip()
    except Unknown as e: raise RecoveryNeeded(f'native log receipt unavailable: {name}') from e
    if sidecar!=digest: raise Unknown(f'native log receipt differs from root pin: {name}')
    return [name,key,digest,'native-log']

def matches(path, glob):
    # * never crosses a slash; **/ also matches zero directory components.
    regex=re.escape(glob).replace(r'\*\*/','(?:.*/)?').replace(r'\*\*','.*').replace(r'\*','[^/]*').replace(r'\?','[^/]')
    return re.fullmatch(regex,path) is not None

def verify(root, r, git, a):
    """Validate current full-checkout evidence."""
    observed=[]; capabilities={}; sources=[]; suggestions=[]
    for v in r['verification']:
        if v['status']=='fail': raise Rejected(f"verification failed: {v['command']}")
        name=v['command']
        if name not in ('test','lint','typecheck','coverage','verify','check'):
            raise Unknown(f'unsupported verification command: {name}')
        capabilities[name]=verification_capability(root,name)
        if v['status']!='pass' and not (v['status']=='unknown' and capabilities[name][0] is None):
            raise Unknown(f"verification {name} is {v['status']}: {v['reason']}")
    cache=None
    for v in r['verification']:
        name=v['command']
        fingerprint,_diagnostic=capabilities[name]
        if fingerprint is None:
            key=execution_key(root,name)
            lease=execution_lease_key(root,name)
            head=git('rev-parse','HEAD').decode().strip(); recovered_log=None
            _recovery,prior=load_native_recovery(a,root,name,head)
            if prior is not None:
                if not isinstance(prior,dict) or prior.get('key')!=key or prior.get('lease')!=lease:
                    raise Unknown(f'native recovery already used for this check and candidate head: {name}')
                if prior.get('status') in ('pass','fail'):
                    if prior.get('provenance')=='root-started': a.root_digests[name]=prior.get('sha256','')
                    recovered_log=prior.get('log','')
            try:
                native=verify_native(root,v,name,key,lease,a,recovered_log)
            except RecoveryNeeded:
                recovered_log=collect_native_recovery(root,name,key,lease,a)
                native=verify_native(root,v,name,key,lease,a,recovered_log)
            observed.append(native); sources.append('native-log')
            upper=name.upper().replace('-','_')
            suggestions.append(f'configure AGENT_VERIFY_{upper}_MODE=local and AGENT_VERIFY_{upper}_TOOLCHAIN to enable cache reuse')
            continue
        # Match the tested state.
        if not re.fullmatch('[0-9a-f]{64}',fingerprint):
            raise Unknown(f'invalid current verification fingerprint: {name}')
        if v.get('fingerprint')!=fingerprint: raise Unknown(f'stale or unsupported tested-state fingerprint: {name}')
        log=Path(v.get('log',''))
        if not log.is_absolute() or root not in log.resolve().parents or log.parent.resolve()!= (root/'.agent/logs').resolve():
            raise Unknown(f'log must be inside worktree .agent/logs: {name}')
        if cache is None: cache=read(root/'.agent/verification-cache').decode()
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
        data,expected_digest=trusted_log(a,name,fingerprint,log,completed[2],'verification-cache')
        if not data.splitlines() or not re.fullmatch(rb'=== agent-run exited rc=0 after [0-9]+s', data.splitlines()[-1]):
            raise Unknown(f'log has no final successful completion marker: {name}')
        if completed[2]!=expected_digest:
            raise Unknown(f'completed verification digest differs from root pin: {name}')
        observed.append([name,fingerprint,expected_digest,'verification-cache']); sources.append('verification-cache')
    return observed,sources,suggestions

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
    if r['blocker'] is not None:
        return 'blocked',[owner,entry,r],'preserve work; '+r['blocker']['remainingAction'],'none',''
    # Push and local verification are independent: inspect both before returning
    # one actionable failure, so changing a remote cannot erase valid local work.
    failures=[]
    try:
        evidence,sources,suggestions=verify(root,r,git,a); claims['verification']='valid'
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
    evidence_type='native-log' if 'native-log' in sources else 'verification-cache'
    suggestion='; '.join(suggestions)
    return ('accepted',[owner,entry,r,evidence,remote],
            f'implementation handoff validated; evidence={evidence_type}; root obligations remain open',
            evidence_type,suggestion)

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
    receipt.update(result=str(Path(a.result).absolute()),runId=a.run_id,workerId=a.worker_id,
                   trustedLogs=pins)
    reused=old==receipt and receipt['status']=='accepted'
    command([str(HELPERS/'run-state.sh'),'set','--file',a.state,'--path','results.'+a.attempt,'--json',json.dumps(receipt)])
    return reused

def main():
    p=argparse.ArgumentParser(prog='worker-result.sh',
                              description='Write or independently validate worker-result v1 with bounded native-evidence recovery.')
    sub=p.add_subparsers(dest='action',required=True)
    write_help=(f"Schema-check and atomically write worker-result v1. Required fields: {', '.join(RESULT_FIELDS)}. "
                f'verification[].command is the declared NAME passed to agent-run.sh --cmd, matching {COMMAND_PATTERN}, not the command line.')
    w=sub.add_parser('write', help='schema-check and atomically write worker-result v1', description=write_help,
                     formatter_class=argparse.RawDescriptionHelpFormatter)
    w.add_argument('--input',required=True,help='input worker-result v1 JSON file')
    w.add_argument('--output',required=True,help='output artifact replaced atomically after validation')
    v=sub.add_parser('validate')
    for name in ('result','dispatch-plan','owners','state','run-id','attempt','worker-id','worktree','base-sha'):
        v.add_argument('--'+name,required=True)
    v.add_argument('--issue',type=int,required=True)
    v.add_argument('--required-check',action='append',required=True)
    v.add_argument('--log-sha256',action='append',default=[],help='root-observed original COMMAND=SHA256; never worker JSON or sidecar')
    v.add_argument('--native-recovery-timeout-seconds',type=float,default=30,
                   help=argparse.SUPPRESS)
    a=p.parse_args(sys.argv[2:]); claims={k:'unknown' for k in ('ownership','implementation','push','verification')}
    try:
        if a.action=='validate':
            prior=load_receipt(a)
            a.trusted_logs=prior.get('trustedLogs',{})
            require(isinstance(a.trusted_logs,dict), 'trusted log pins must be an object')
            require(0<a.native_recovery_timeout_seconds<=60,
                    'native recovery timeout must be greater than zero and at most 60 seconds')
            a.claims=claims
            a.root_digests={}
            for item in a.log_sha256:
                name,separator,digest=item.partition('=')
                require(separator and name in a.required_check and name not in a.root_digests and
                        re.fullmatch('[0-9a-f]{64}',digest), '--log-sha256 requires one root-observed COMMAND=SHA256 per check')
                a.root_digests[name]=digest
        r=document(a.input if a.action=='write' else a.result); schema(r)
        if a.action=='write': atomic(a.output,r); print(json.dumps({'result':a.output})); return 0
        status,evidence,reason,evidence_type,suggestion=validate(a,r,claims)
        fingerprint=hashlib.sha256(json.dumps(evidence,sort_keys=True).encode()).hexdigest()
        receipt={'status':status,'claims':claims,'reason':reason,'fingerprint':fingerprint,
                 'obligations':r['obligations'],'blocker':r['blocker'],'evidence':evidence_type}
        if suggestion: receipt['suggestion']=suggestion
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
