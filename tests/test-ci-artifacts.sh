#!/usr/bin/env bash
set -uo pipefail
TEST_NAME=ci-artifacts
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/assert.sh"
helper="$here/../agentkit/skills/review-remote-pr/scripts/ci-artifacts.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/repo/.agent" "$tmp/bin"
git -C "$tmp/repo" init -q
export FIXTURE="$tmp" PATH="$tmp/bin:$PATH"
cat > "$tmp/bin/gh" <<'PY'
#!/usr/bin/env python3
import io,json,os,stat,sys,zipfile
from pathlib import Path
p=Path(os.environ['FIXTURE'])
with (p/'calls').open('a') as f: f.write(' '.join(sys.argv[1:])+'\n')
assert sys.argv[1]=='api'
endpoint=sys.argv[2]
mode=(p/'mode').read_text().strip()
if '/runs/42/artifacts' in endpoint:
 assert '--paginate' in sys.argv and '--slurp' in sys.argv
 print(json.dumps([{'artifacts':[]},{'artifacts':[] if mode=='absent' else [{'id':7,'name':'results','expired':mode=='expired'}]}]))
elif '/runs/42/jobs' in endpoint:
 assert '--paginate' in sys.argv and '--slurp' in sys.argv
 print(json.dumps([{'jobs':[{'id':9,'conclusion':'failure'},{'id':10,'conclusion':'success'}]}]))
elif endpoint.endswith('/jobs/9/logs'):
 print('failure detail')
elif endpoint.endswith('/artifacts/7/zip'):
 if mode=='denied':
  print('gh: Forbidden (HTTP 403)',file=sys.stderr); sys.exit(1)
 if mode=='gone':
  print('gh: Gone (HTTP 410)',file=sys.stderr); sys.exit(1)
 b=io.BytesIO()
 with zipfile.ZipFile(b,'w',compression=zipfile.ZIP_DEFLATED) as z:
  name='../escape' if mode=='traversal' else '/absolute' if mode=='absolute' else 'actual.txt'
  if mode=='symlink':
   i=zipfile.ZipInfo('link'); i.external_attr=(stat.S_IFLNK|0o777)<<16; z.writestr(i,'../../escape')
  else: z.writestr(name,'x'*2000000 if mode=='bomb' else 'actual evidence')
 sys.stdout.buffer.write(b.getvalue())
else: sys.exit('unexpected endpoint: '+endpoint)
PY
chmod +x "$tmp/bin/gh"
run() { (cd "$tmp/repo" && "$helper" --repo owner/repo --run-id 42 --dest "$1" "${@:2}") > "$tmp/out" 2>&1; }
printf normal > "$tmp/mode"
run "$tmp/outside"; assert_eq 2 "$?" 'reject outside cache'
assert_eq no "$([[ -e $tmp/outside ]] && echo yes || echo no)" 'invalid destination creates nothing'
ln -s "$tmp" "$tmp/repo/.agent/escape"
run "$tmp/repo/.agent/escape/output"; assert_eq 2 "$?" 'reject escaping destination symlink'
run "$tmp/repo/.agent/evidence"; assert_eq 0 "$?" 'download artifacts and failed logs'
assert_eq 'actual evidence' "$(cat "$tmp/repo/.agent/evidence/artifact-7/files/actual.txt" 2>/dev/null)" 'archive extracted'
assert_contains "$(cat "$tmp/repo/.agent/evidence/job-9.log" 2>/dev/null)" 'failure detail' 'failed job log retained'
before=$(rg -c '/artifacts/7/zip|/jobs/9/logs' "$tmp/calls")
run "$tmp/repo/.agent/evidence"; assert_eq 0 "$?" 'repeat succeeds'
assert_eq "$before" "$(rg -c '/artifacts/7/zip|/jobs/9/logs' "$tmp/calls")" 'repeat reuses completed downloads'
for mode in expired absent gone; do
 printf '%s' "$mode" > "$tmp/mode"
 run "$tmp/repo/.agent/$mode"
 assert_eq 0 "$?" "$mode still collects logs"
 expected=EXPIRED; [[ $mode == absent ]] && expected=ABSENT
 assert_contains "$(cat "$tmp/out")" "$expected" "$mode distinguished"
done
printf normal > "$tmp/mode"
run "$tmp/repo/.agent/filter" --name missing; assert_eq 0 "$?" 'unmatched name succeeds with logs'
assert_contains "$(cat "$tmp/out")" ABSENT 'unmatched name is absent'
run "$tmp/repo/.agent/job" --job 11; assert_eq 2 "$?" 'job must belong to selected run'
run "$tmp/repo/.agent/selected-job" --job 9; assert_eq 0 "$?" 'selected job downloads'
run "$tmp/repo/.agent/end-options" --; assert_eq 0 "$?" 'trailing end-of-options marker is accepted'
run "$tmp/repo/.agent/evidence" --run-id 43; assert_eq 2 "$?" 'cache cannot be reused across runs'
printf denied > "$tmp/mode"
run "$tmp/repo/.agent/denied"; assert_eq 2 "$?" 'API authorization failure is incomplete evidence'
assert_contains "$(cat "$tmp/out")" 'HTTP 403' 'API error context retained'
for mode in traversal absolute symlink bomb; do
 printf '%s' "$mode" > "$tmp/mode"
 run "$tmp/repo/.agent/$mode"; assert_eq 2 "$?" "reject $mode archive"
 assert_eq no "$([[ -e $tmp/repo/.agent/$mode/artifact-7 ]] && echo yes || echo no)" 'unsafe archive not published'
done
printf normal > "$tmp/mode"
mkdir "$tmp/repo/.agent/preexisting"
ln -s "$tmp/out" "$tmp/repo/.agent/preexisting/job-9.log"
run "$tmp/repo/.agent/preexisting"; assert_eq 2 "$?" 'reject preexisting output symlink'
assert_not_contains "$(cat "$tmp/calls")" 'run view' 'REST only'
mkdir -p "$tmp/manifest/review-remote-pr/scripts" "$tmp/manifest/.shared"
cp "$helper" "$tmp/manifest/review-remote-pr/scripts/ci-artifacts.sh"
printf '# Reference\n' > "$tmp/manifest/.shared/example.md"
# shellcheck disable=SC2016  # The manifest records literal $agentkit paths.
printf '%s\n' '- `$agentkit/.shared/example.md` -- example | Read when: testing' > "$tmp/manifest/references.md"
"$here/lint-reference-manifest.sh" "$tmp/manifest" > "$tmp/lint" 2>&1
assert_eq 1 "$?" 'manifest gate requires shipped evidence helper entry'
# shellcheck disable=SC2016  # The manifest records literal $agentkit paths.
printf '%s\n' '- `$agentkit/review-remote-pr/scripts/ci-artifacts.sh` -- CI evidence | Read when: assigned CI does not reproduce' >> "$tmp/manifest/references.md"
"$here/lint-reference-manifest.sh" "$tmp/manifest" > "$tmp/lint" 2>&1
assert_eq 0 "$?" 'manifest accepts helper with read condition'
mkdir "$tmp/routing"
printf '%s\n' 'gh run view 42 --json artifacts' > "$tmp/routing/bad.sh"
"$here/lint-rest-routing.sh" "$tmp/routing" > "$tmp/lint" 2>&1
assert_eq 1 "$?" 'routing gate forbids run JSON porcelain'
finish
