#!/usr/bin/env bash
# A fingerprint query is read-only and shares execution's freshness identity.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
python3 - "$(dirname -- "$here")" <<'PY'
import os, re, subprocess, sys, tempfile
from pathlib import Path
helper=Path(sys.argv[1])/'agentkit/skills/.shared/scripts/agent-run.sh'
with tempfile.TemporaryDirectory() as temp:
    root=Path(temp); repo=root/'repo'; repo.mkdir(); agent=repo/'.agent'; agent.mkdir()
    def git(*args): subprocess.run(['git','-C',str(repo),*args],check=True,capture_output=True)
    git('init','-q','-b','feat/query'); git('config','user.name','test')
    git('config','user.email','test@example.invalid')
    (repo/'.gitignore').write_text('.agent/\n')
    (repo/'input').write_text('one\n'); git('add','.'); git('commit','-qm','base')
    tool=root/'tool'; tool.write_text('#!/bin/sh\nexit 0\n'); tool.chmod(0o700)
    os.environ['PATH']=str(root)+os.pathsep+os.environ['PATH']
    counter=root/'executed'
    config=agent/'config.env'
    declaration=f"AGENT_CMD_TEST=touch {counter}\nAGENT_VERIFY_TEST_MODE=local\nAGENT_VERIFY_TEST_TOOLCHAIN=tool\n"
    config.write_text(declaration)
    def snapshot():
        return {str(p.relative_to(agent)):p.read_bytes() for p in agent.rglob('*') if p.is_file()}
    def query(*extra, expected=0):
        before=snapshot()
        p=subprocess.run([str(helper),'--dir',str(repo),'--cmd','test','--verification-key',*extra],
                         capture_output=True,text=True)
        assert p.returncode==expected, (p.returncode,p.stdout,p.stderr)
        assert snapshot()==before, 'query created or changed repository evidence'
        assert not counter.exists(), 'query executed the declared command'
        if expected==0: assert re.fullmatch(r'[0-9a-f]{64}\n',p.stdout),p.stdout
        else: assert not p.stdout, p.stdout
        return p.stdout.strip()
    def unavailable(declaration,*fragments):
        config.write_text(declaration)
        before=snapshot()
        p=subprocess.run([str(helper),'--dir',str(repo),'--cmd','test','--verification-key'],
                         capture_output=True,text=True)
        assert p.returncode==1,(p.returncode,p.stdout,p.stderr)
        assert snapshot()==before, 'capability query created or changed repository evidence'
        assert not counter.exists(), 'capability query executed the declared command'
        assert all(fragment in p.stderr for fragment in fragments),(p.stderr,fragments)
    first=query(); assert query()==first
    git('commit','--allow-empty','-qm','candidate checkpoint')
    committed=query()
    assert committed!=first, 'a new committed HEAD cannot inherit proof from an identical tree'
    first=committed
    assert list(agent.iterdir())==[config], 'query created durable directories'
    (repo/'input').write_text('two\n'); assert query()!=first
    (repo/'input').write_text('one\n'); assert query()==first
    tool.write_text('#!/bin/sh\nexit 1\n'); assert query()!=first
    tool.write_text('#!/bin/sh\nexit 0\n'); assert query()==first
    config.write_text(declaration.replace('AGENT_CMD_TEST=touch ', 'AGENT_CMD_TEST=touch -- ')); assert query()!=first
    for suffix in ('AGENT_VERIFY_TEST_MODE=external\n','AGENT_VERIFY_TEST_TOOLCHAIN=missing-query-tool\n',
                   'AGENT_VERIFY_TEST_INPUTS=input\n','AGENT_CMD_TEST_KIND=format\n'):
        config.write_text('\n'.join(line for line in declaration.splitlines() if not line.startswith(suffix.split('=')[0]+'='))+'\n'+suffix); query(expected=1)
    unavailable('AGENT_CMD_TEST=true\n','reason=mode-not-local',
                'missing=AGENT_VERIFY_TEST_MODE=local,AGENT_VERIFY_TEST_TOOLCHAIN',
                'choices=declare-local-verification-or-authorize-native-evidence-handoff')
    unavailable('AGENT_CMD_TEST=true\nAGENT_VERIFY_TEST_MODE=local\n','reason=no-toolchain',
                'missing=AGENT_VERIFY_TEST_TOOLCHAIN')
    config.write_text(declaration)
    for flags in (('--force',),('--only','unit'),('--cmd','lint'),('--if-declared',),('--resolve','test'),('--fix',),('--','true'),
                  ('--baseline-ref','HEAD','--baseline-path','input','--baseline-id','query')):
        query(*flags,expected=1)
    # The actual producer uses precisely the queried key; querying never claims it.
    subprocess.run([str(helper),'--dir',str(repo),'--cmd','test'],check=True,capture_output=True)
    assert counter.exists(); counter.unlink()
    cache=(agent/'verification-cache').read_text()
    assert cache.startswith(first+' cmd=test '),cache
    assert (agent/'verification-records'/first/'result').is_file()
    assert query()==first
print('PASS: read-only verification key and real execution identity')
PY
