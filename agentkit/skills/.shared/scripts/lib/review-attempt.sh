#!/usr/bin/env bash
# shellcheck disable=SC2034,SC2153
# Callers supply their existing launcher/provider/receipt globals.
# Durable review-attempt state and canonical launch integration.
# Local reservations are independent of the remote completed-review ledger.
# The git common directory shares the budget across worktrees and run dirs.
# Only an explicitly authorized retry of the current failed canonical attempt
# may reserve another provider invocation; all other reservations stay one-shot.
validate_receipt_attempt() {
    local run_dir=$1
    local entry="$run_dir/state/review-attempt.json" attempt_root launcher attempt script_dir
    script_dir=$(cd -- "$STACKED_CI_DIR" && pwd -P)
    [[ -f $entry && ! -L $entry && -O $entry ]] ||
        evidence_unavailable 'canonical launcher provenance and durable attempt evidence are required'
    launcher=$(readlink -f -- "$script_dir/adversarial-run.sh")
    jq -e --arg repo "$REPO" --argjson pr "$PR" --arg provider "$PROVIDER" \
        --arg model "$MODEL" --arg effort "$EFFORT" --arg launcher "$launcher" \
        --arg head "$HEAD_SHA" --arg payload "$DIFF_PAYLOAD" \
        '.repo == $repo and .pr == $pr and .provider == $provider and .model == $model and
         .effort == $effort and .launcher == $launcher and
         ($head == "" or .head == $head) and ($payload == "" or .payload == $payload)' "$entry" >/dev/null ||
        evidence_unavailable 'receipt identity conflicts with canonical review attempt'
    attempt_root=$(jq -er '.repoRoot | select(type == "string" and length > 0)' "$entry") ||
        evidence_unavailable 'review attempt has no repository root'
    attempt=$("$script_dir/review-ledger.sh" attempt validate --repo-root "$attempt_root" --entry-file "$entry") ||
        evidence_unavailable 'canonical review attempt validation failed'
    LAUNCHER_PROVENANCE=$(jq -r '.launcherSha256' <<<"$attempt")
    RECEIPT_ATTEMPT_ID=$(jq -r '.id' <<<"$attempt")
    REVIEW_PROCEDURE=$(jq -r '.procedure' <<<"$attempt")
    REVIEW_OVERRIDE=$(jq -r 'if .override == "" then "" else
        "configured=" + .configuredReviewer + "; operator-authorized=" + .override end' <<<"$attempt")
}

cmd_attempt() {
    python3 - "$@" <<'PY'
import argparse, datetime, fcntl, hashlib, json, os, pathlib, stat, subprocess, sys, tempfile, time, uuid
p = argparse.ArgumentParser()
p.add_argument('operation', choices=['reserve', 'retry', 'recover', 'read', 'attach', 'start', 'process', 'finish', 'reconcile', 'validate'])
p.add_argument('--repo-root', required=True)
p.add_argument('--entry-file', required=True)
p.add_argument('--id', default='')
p.add_argument('--pid', type=int, default=0)
p.add_argument('--parent-pid', type=int, default=0)
p.add_argument('--state', choices=['completed', 'failed', 'unknown-outcome', 'parser-rejected'])
p.add_argument('--authorization', default='')
a = p.parse_args()
def safe_file(path):
    s = os.lstat(path)
    if not stat.S_ISREG(s.st_mode) or s.st_uid != os.getuid():
        raise ValueError('not an owned regular file: ' + str(path))
    return pathlib.Path(path).read_bytes()
def digest(path):
    return hashlib.sha256(safe_file(path)).hexdigest()
def attempt_value(value, field):
    if field == 'reviewBase': return value.get(field, value.get('base'))
    return value.get(field)
def unsent(record):
    return (record['state'] == 'parser-rejected' and not record.get('legacyEvidence')
        and not record.get('providerProcess')
        and any(e['operation'] == 'finish' and e['state'] == 'parser-rejected' for e in record['events'])
        and not any(e['operation'] in ('start', 'process') for e in record['events']))
def completed_result(record):
    result = json.loads(safe_file(record['result']))
    verdict = result.get('verdict', {})
    findings = verdict.get('findings')
    if (result.get('status') != 'completed' or result.get('exitCode') != 0
            or result.get('requestedModel') != record['model']
            or not isinstance(findings, list)
            or verdict.get('verdict') not in ('findings', 'no_findings')
            or bool(findings) != (verdict.get('verdict') == 'findings')
            or any(not isinstance(f, dict) or set(f) != {'priority', 'location', 'failureScenario', 'smallestFix'}
                   or f['priority'] not in ('P1', 'P2')
                   or any(not isinstance(f[k], str) for k in f) for f in findings)):
        raise ValueError('completed attempt requires a validated result for its model')
    if record.get('canonical') and result.get('attemptId') != record['id']:
        raise ValueError('canonical result is not bound to original attempt')
    if record.get('canonical') and record.get('reviewBase') is not None and (
            result.get('reviewBase') != record.get('reviewBase')
            or result.get('prBase') != record.get('base')
            or result.get('diffPayload') != record.get('payload')):
        raise ValueError('canonical result does not bind its diff payload and base commits')
    record['resultSha256'] = digest(record['result'])
    record['completedResult'] = result
    transcript = result.get('transcript')
    if transcript and pathlib.Path(transcript).is_file():
        record['transcriptSha256'] = digest(transcript)
        sessions = []
        for line in safe_file(transcript).splitlines():
            event = json.loads(line)
            session = event.get('session_id') or event.get('thread_id')
            if isinstance(session, str) and session not in sessions: sessions.append(session)
        record['sessionIds'] = sessions
def process_identity(pid):
    try:
        # PID alone can be reused; Linux start time identifies this process.
        fields = pathlib.Path('/proc/' + str(pid) + '/stat').read_text().rsplit(')', 1)[1].split()
        boot = pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        return {'pid': pid, 'startTicks': fields[19], 'bootId': boot}
    except (OSError, IndexError):
        return {'pid': pid, 'identity': 'unavailable'}
def save(path, value):
    fd, temp = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp, path)
        fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try: os.fsync(fd)
        finally: os.close(fd)
    finally:
        if os.path.exists(temp): os.unlink(temp)
try:
    entry = json.loads(safe_file(a.entry_file))
    common = pathlib.Path(subprocess.check_output(['git', '-C', a.repo_root,
        'rev-parse', '--path-format=absolute', '--git-common-dir'], text=True).strip())
    directory = common / 'agentkit-review-attempts'
    directory.mkdir(mode=0o700, exist_ok=True)
    s = directory.lstat()
    if not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or s.st_mode & 0o077:
        raise ValueError('unsafe review attempt directory')
    key = hashlib.sha256((entry['repo'].lower() + ':' + str(entry['pr'])).encode()).hexdigest()
    path = directory / (key + '.json')
    fd = os.open(directory / (key + '.lock'), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    lock_stat = os.fstat(fd)
    if not stat.S_ISREG(lock_stat.st_mode) or lock_stat.st_uid != os.getuid():
        raise ValueError('unsafe attempt lock')
    deadline = time.monotonic() + 2
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise TimeoutError('attempt lock unavailable after 2s; outcome unknown')
            time.sleep(0.02)
    record = json.loads(safe_file(path)) if path.exists() or path.is_symlink() else None
    if record is not None and (record.get('version') != 1 or not isinstance(record.get('events'), list)
            or record.get('repo', '').lower() != entry['repo'].lower() or record.get('pr') != entry['pr']):
        raise ValueError('malformed durable attempt; reconciliation required')
    now = datetime.datetime.now(datetime.timezone.utc).isoformat()
    if a.operation == 'reserve':
        if record is not None:
            print(json.dumps(record)); sys.exit(20)
        record = dict(entry, version=1, id=str(uuid.uuid4()), state='reserved', events=[])
        record['launcherSha256'] = digest(entry['launcher'])
        # Preserve legacy/noncanonical evidence at the supported conventional
        # evidence location before initializing canonical state. Other clones,
        # arbitrary historical paths and raw CLI bypass remain unenforceable.
        worktrees = subprocess.check_output(['git', '-C', a.repo_root, 'worktree', 'list', '--porcelain', '-z'])
        for item in worktrees.split(b'\0'):
            if not item.startswith(b'worktree '): continue
            old = pathlib.Path(os.fsdecode(item[9:])) / '.agent' / 'evidence' / ('pr-' + str(entry['pr']))
            for artifact in (old / 'state' / 'launch-attempted', old / 'adversarial.result.json'):
                if artifact.exists() or artifact.is_symlink():
                    if artifact.name == 'adversarial.result.json' and json.loads(safe_file(artifact)).get('status') != 'completed':
                        continue
                    record.update(state='unknown-outcome', canonical=False, initializedBy=entry['launcher'],
                        launcher='unknown-legacy-launcher', launcherSha256=None)
                    record.setdefault('legacyEvidence', []).append({'path': str(artifact), 'sha256': digest(artifact)})
        if entry.get('canonical'):
            record['payloadGateSha256'] = digest(pathlib.Path(entry['result']).parent / 'adversarial.payload-size')
            record['runtimeSha256'] = digest(pathlib.Path(entry['launcher']).parents[2] / '.shared/scripts/lib/review-attempt.sh')
    elif a.operation == 'retry':
        if record is None or record.get('id') != a.id:
            raise ValueError('retry must name the current durable attempt ID')
        if not a.authorization.strip():
            raise ValueError('retry requires explicit user authorization')
        if record.get('state') != 'failed' or not record.get('canonical'):
            raise ValueError('only a terminal failed canonical attempt can be retried')
        if not any(e.get('operation') == 'finish' and e.get('state') == 'failed' for e in record['events']):
            raise ValueError('failed attempt has no terminal failure event')
        for field in ('repo', 'pr', 'provider', 'model', 'effort', 'base', 'reviewBase'):
            if attempt_value(record, field) != attempt_value(entry, field):
                raise ValueError('retry identity mismatch: ' + field)
        if pathlib.Path(record.get('launcher', '')).name != pathlib.Path(entry.get('launcher', '')).name:
            raise ValueError('retry launcher identity mismatch')
        if entry.get('canonical') is not True:
            raise ValueError('retry must remain canonical')
        if not entry.get('head') or not record.get('head'):
            raise ValueError('retry requires both prior and new commit identities')
        ancestry = subprocess.run(['git', '-C', a.repo_root, 'merge-base', '--is-ancestor',
            record['head'], entry['head']], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if ancestry.returncode != 0:
            raise ValueError('retry head must be the prior commit or one of its descendants')
        if not entry.get('payload'):
            raise ValueError('retry must bind its review payload')
        if pathlib.Path(entry['result']).resolve() == pathlib.Path(record['result']).resolve():
            raise ValueError('retry requires a fresh result path')
        budget = entry.get('maxBudgetUsd')
        tokens = entry.get('maxOutputTokens')
        if record.get('provider') == 'anthropic':
            if not isinstance(budget, (int, float)) or isinstance(budget, bool) or budget <= 0:
                raise ValueError('Claude retry requires a positive maxBudgetUsd')
            if not isinstance(tokens, int) or isinstance(tokens, bool) or tokens <= 0:
                raise ValueError('Claude retry requires a positive integer maxOutputTokens')
        else:
            if budget is not None and (not isinstance(budget, (int, float)) or isinstance(budget, bool) or budget <= 0):
                raise ValueError('optional retry maxBudgetUsd must be positive')
            if tokens is not None and (not isinstance(tokens, int) or isinstance(tokens, bool) or tokens <= 0):
                raise ValueError('optional retry maxOutputTokens must be a positive integer')
        old_result = pathlib.Path(record['result'])
        result_value = json.loads(safe_file(old_result))
        transcript = result_value.get('transcript')
        if not isinstance(transcript, str) or not transcript:
            transcript = str(old_result.parent / ('claude.ndjson' if record.get('provider') == 'anthropic' else 'codex.jsonl'))
        archived = dict(record)
        archived['resultSha256'] = digest(old_result)
        archived['resultArtifact'] = str(old_result)
        archived['transcriptArtifact'] = transcript
        archived['transcriptSha256'] = digest(transcript)
        new_record = dict(entry, version=1, id=str(uuid.uuid4()), state='reserved', events=[])
        new_record['launcherSha256'] = digest(entry['launcher'])
        new_record['payloadGateSha256'] = digest(pathlib.Path(entry['result']).parent / 'adversarial.payload-size')
        new_record['runtimeSha256'] = digest(pathlib.Path(entry['launcher']).parents[2] / '.shared/scripts/lib/review-attempt.sh')
        new_record['retryOf'] = record['id']
        new_record['retryAuthorization'] = a.authorization
        new_record['previousAttempts'] = list(record.get('previousAttempts', [])) + [archived]
        record = new_record
    elif record is None:
        sys.exit(11)
    elif a.operation == 'recover':
        if record['id'] != a.id or not unsent(record):
            raise ValueError('only a provably unsent rejected preparation can recover')
        for field in ('payload', 'provider', 'model', 'effort', 'head', 'base', 'reviewBase', 'canonical', 'launcher'):
            if attempt_value(record, field) != attempt_value(entry, field): raise ValueError('recovery input mismatch: ' + field)
        previous = {k: v for k, v in record.items() if k not in ('events', 'preparations')}
        if pathlib.Path(record['result']).exists():
            previous['resultBytes'] = safe_file(record['result']).decode()
        record.setdefault('preparations', []).append(previous)
        for field in ('result', 'launcherPid', 'repoRoot', 'configuredReviewer', 'override',
                      'overrideAuthorization', 'modelSubstitutedFrom', 'exclusionCount', 'excludedSha256', 'mode'):
            if field in entry: record[field] = entry[field]
        record.update(state='reserved', attached=False)
        for field in ('helperPid', 'helperProcess', 'providerLauncher', 'providerLauncherSha256'):
            record.pop(field, None)
        record['launcherSha256'] = digest(entry['launcher'])
        if entry.get('canonical'):
            record['payloadGateSha256'] = digest(pathlib.Path(entry['result']).parent / 'adversarial.payload-size')
            record['runtimeSha256'] = digest(pathlib.Path(entry['launcher']).parents[2] / '.shared/scripts/lib/review-attempt.sh')
    elif a.operation in ('attach', 'start', 'process', 'finish', 'reconcile'):
        if record['id'] != a.id: raise ValueError('attempt identity mismatch')
        if a.operation in ('attach', 'start'):
            if record['state'] != 'reserved' or (a.operation == 'attach' and record.get('attached')):
                print(json.dumps(record)); sys.exit(20)
            for field in ('payload', 'provider', 'model', 'effort', 'head', 'base', 'reviewBase'):
                if attempt_value(record, field) != attempt_value(entry, field): raise ValueError('attempt input mismatch: ' + field)
            if record.get('canonical') and record['launcherPid'] != a.parent_pid:
                raise ValueError('canonical attempt is not owned by this helper parent')
            if record.get('attached') and record.get('helperPid') != a.pid:
                raise ValueError('attempt belongs to another helper process')
            record.update(state='reserved' if a.operation == 'attach' else 'running',
                attached=True, helperPid=a.pid, helperProcess=process_identity(a.pid),
                providerLauncher=entry['launcher'], providerLauncherSha256=digest(entry['launcher']))
        elif a.operation == 'process':
            if record['state'] != 'running' or record.get('providerProcess'):
                raise ValueError('provider process already registered or attempt not running')
            record['providerProcess'] = process_identity(a.pid)
        elif a.operation == 'reconcile':
            if record['state'] not in ('running', 'unknown-outcome'):
                raise ValueError('only an existing running or unknown attempt can reconcile a result')
            completed_result(record)
            record['state'] = 'completed'
        else:
            if a.parent_pid:
                if not record.get('canonical') or record.get('launcherPid') != a.parent_pid:
                    raise ValueError('attempt belongs to another launcher')
            elif (a.pid or record.get('attached')) and record.get('helperPid') != a.pid:
                raise ValueError('attempt belongs to another helper')
            if record['state'] in ('completed', 'failed', 'unknown-outcome', 'parser-rejected'):
                print(json.dumps(record)); sys.exit(20)
            if not a.state: raise ValueError('finish requires --state')
            if a.state == 'parser-rejected' and record['state'] != 'reserved':
                raise ValueError('a claimed provider launch cannot become an unsent rejection')
            record['state'] = a.state
            if a.state == 'completed':
                completed_result(record)
    elif a.operation == 'validate':
        if record['state'] != 'completed' or not record.get('canonical'):
            raise ValueError('attempt is not canonical and completed')
        for field in ('payload', 'provider', 'model', 'effort', 'head', 'base', 'reviewBase', 'launcher'):
            if attempt_value(record, field) != attempt_value(entry, field): raise ValueError('receipt attempt mismatch: ' + field)
        if record['launcherSha256'] != digest(entry['launcher']): raise ValueError('launcher provenance mismatch')
        if record['runtimeSha256'] != digest(pathlib.Path(entry['launcher']).parents[2] / '.shared/scripts/lib/review-attempt.sh'):
            raise ValueError('launcher runtime provenance mismatch')
        if record['resultSha256'] != digest(entry['result']): raise ValueError('result digest mismatch')
        if record['payloadGateSha256'] != digest(pathlib.Path(entry['result']).parent / 'adversarial.payload-size'):
            raise ValueError('payload gate evidence mismatch')
        result = json.loads(safe_file(entry['result']))
        if result.get('attemptId') != record['id']: raise ValueError('result attempt identity mismatch')
    if a.operation not in ('read', 'validate'):
        record['events'].append({'state': record['state'], 'operation': a.operation, 'at': now})
        save(path, record)
    if a.operation == 'read': record['recoverableUnsent'] = unsent(record)
    if a.operation == 'read' and record['state'] == 'running':
        identity = process_identity(record.get('helperPid', 0))
        record['observedState'] = 'running' if identity == record.get('helperProcess') and 'startTicks' in identity else 'unknown-outcome'
    print(json.dumps(record))
    if a.operation == 'reserve' and record['state'] != 'reserved': sys.exit(20)
except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
    print('review attempt: ' + str(error) + '; reconciliation required', file=sys.stderr)
    sys.exit(1)
PY
}

# Sourced by the provider helpers: reserve direct calls too, then atomically
# claim the one provider start. Environment tokens are correlation, not consent.
# Both helpers perform their existing exact-payload consent check first.
review_attempt_prepare() {
    [[ $MODE == review ]] || return 0
    OUTPUT_PATH=$(realpath -ms -- "$OUTPUT_PATH")
    TRANSCRIPT_PATH=$(realpath -ms -- "$TRANSCRIPT_PATH")
    REVIEW_ATTEMPT_ROOT=${CONSENT_WORKTREE:-$(git rev-parse --show-toplevel)}
    REVIEW_ATTEMPT_ENTRY="$WORK_DIR/attempt.json"
    local payload reservation base='' review_base='' pinned_base=${AGENTKIT_REVIEW_BASE_SHA:-} rc=0
    local -a payload_args=(payload --repo "$REPO_SLUG" --pr "$PR_NUMBER" --diff "$DIFF_PATH")
    if [[ -n $BASE_REF ]]; then
        base=$(git -C "$REVIEW_ATTEMPT_ROOT" rev-parse "origin/$BASE_REF") || die 'could not resolve review base'
        if [[ -n $pinned_base ]]; then
            payload_args+=(--base-sha "$pinned_base")
            review_base=$pinned_base
        else
            payload_args+=(--base-ref "$BASE_REF")
            review_base=$base
        fi
    fi
    payload=$("$SCRIPT_DIR/consent-record.sh" "${payload_args[@]}") || die 'could not bind review attempt payload'
    jq -n --arg repo "$REPO_SLUG" --argjson pr "$PR_NUMBER" --arg payload "$payload" \
        --arg provider "$CONSENT_PROVIDER" --arg model "$MODEL" --arg effort "$EFFORT" \
        --arg head "$(git -C "$REVIEW_ATTEMPT_ROOT" rev-parse HEAD)" \
        --arg base "$base" --arg review_base "$review_base" \
        --arg launcher "$(cd -- "$SCRIPT_DIR" && pwd -P)/${0##*/}" --arg result "$OUTPUT_PATH" \
        '{repo:$repo,pr:$pr,payload:$payload,provider:$provider,model:$model,effort:$effort,
          head:$head,base:$base,reviewBase:$review_base,launcher:$launcher,result:$result,canonical:false,
          enforcement:"supported-helper-only; raw CLI bypass cannot be intercepted"}' >"$REVIEW_ATTEMPT_ENTRY"
    if [[ -z ${AGENTKIT_REVIEW_ATTEMPT_ID:-} ]]; then
        REVIEW_ATTEMPT_DIRECT=1
        reservation=$(cmd_attempt reserve --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY") || rc=$?
        if ((rc == 20)); then
            reservation=$(cmd_attempt recover --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY" \
                --id "$(jq -r '.id' <<<"$reservation")") && rc=0
        fi
        ((rc == 0)) || die "existing durable review attempt; reconcile before retry: $reservation"
        AGENTKIT_REVIEW_ATTEMPT_ID=$(jq -r '.id' <<<"$reservation")
    fi
    cmd_attempt attach --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY" \
        --id "$AGENTKIT_REVIEW_ATTEMPT_ID" --pid "$$" --parent-pid "$PPID" >/dev/null || die 'review attempt already attached or mismatched'
    REVIEW_ATTEMPT_ATTACHED=1
}

review_attempt_start() {
    [[ $MODE == review ]] || return 0
    cmd_attempt start --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY" \
        --id "$AGENTKIT_REVIEW_ATTEMPT_ID" --pid "$$" --parent-pid "$PPID" >/dev/null || die 'review attempt already started or mismatched'
    REVIEW_ATTEMPT_STARTED=1
}

review_attempt_cleanup() {
    local state=unknown-outcome
    if [[ ${REVIEW_ATTEMPT_ATTACHED:-0} == 1 ]]; then
        if [[ ${REVIEW_ATTEMPT_STARTED:-0} != 1 ]]; then
            state=parser-rejected
        elif [[ -f $OUTPUT_PATH ]] && jq -e '.status == "completed" and .exitCode == 0' "$OUTPUT_PATH" >/dev/null; then
            state=completed
        elif [[ -f $TRANSCRIPT_PATH ]] && jq -se \
            'any(.[]; .type == "result" and .is_error == true)' "$TRANSCRIPT_PATH" >/dev/null 2>&1; then
            state=failed
        fi
        cmd_attempt finish --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY" \
            --id "$AGENTKIT_REVIEW_ATTEMPT_ID" --pid "$$" --state "$state" >/dev/null ||
            printf 'review attempt finalization failed; preserve artifacts and reconcile\n' >&2
    fi
    review_cleanup
}

review_attempt_process() {
    [[ $MODE == review ]] || return 0
    cmd_attempt process --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY" \
        --id "$AGENTKIT_REVIEW_ATTEMPT_ID" --pid "$1" >/dev/null || die 'could not record provider process'
}

review_attempt_result() {
    [[ $MODE == review ]] || { printf '%s\n' "$1"; return; }
    local record
    record=$(cmd_attempt read --repo-root "$REVIEW_ATTEMPT_ROOT" --entry-file "$REVIEW_ATTEMPT_ENTRY") ||
        die 'could not read original review attempt'
    jq --argjson attempt "$record" \
        '. + {attemptId:$attempt.id,launcher:{path:$attempt.launcher,sha256:$attempt.launcherSha256},
          reviewBase:$attempt.reviewBase,prBase:$attempt.base,diffPayload:$attempt.payload,
          reviewProcedure:($attempt.procedure // "one-shot diff review"),
          configuredReviewer:($attempt.configuredReviewer // ""),
          reviewerOverride:($attempt.override // ""),overrideAuthorization:($attempt.overrideAuthorization // "")}
          + (if ($attempt.modelSubstitutedFrom // "") == "" then {} else
             {modelSubstitutedFrom:$attempt.modelSubstitutedFrom} end)' <<<"$1"
}

apply_reviewer_override() {
    CONFIGURED_REVIEWER="$MODEL-$EFFORT"
    [[ -n $REVIEWER_OVERRIDE || -n $OVERRIDE_AUTHORIZATION ]] || return 0
    [[ -n $REVIEWER_OVERRIDE && -n $OVERRIDE_AUTHORIZATION ]] ||
        die '--reviewer requires explicit --override-authorization, and vice versa'
    if [[ ! $REVIEWER_OVERRIDE =~ ^[A-Za-z0-9._-]+$ ]] || ! reviewer_roster_parse "$REVIEWER_OVERRIDE"; then
        die 'override reviewer must be a supported MODEL-EFFORT compound'
    fi
    MODEL=$ROSTER_MODEL EFFORT=$ROSTER_EFFORT
    PROVIDER=$(provider_for_cli "$ROSTER_FAMILY")
    HELPER="$SCRIPT_DIR/$ROSTER_FAMILY-adversarial-review.sh"
    TRANSCRIPT_NAME="$ROSTER_FAMILY.ndjson"
    [[ $PROVIDER == "$RUNNING_PROVIDER" ]] && MODE=blind-fallback || MODE=cross-provider
    require_helper_executable
}

# Inspect an existing run before build_diff can replace its original evidence.
resume_existing_review_attempt() {
    local entry="$RUN_DIR/state/review-attempt.json" record
    [[ -e $entry || -L $entry ]] || return 1
    [[ -f $entry && ! -L $entry && -O $entry ]] || die 'unsafe existing review attempt evidence'
    jq -e --arg repo "$REPO" --argjson pr "$PR" '.repo == $repo and .pr == $pr' "$entry" >/dev/null ||
        die 'run directory belongs to a different review obligation'
    record=$(cmd_attempt read --repo-root "$CONTRACT_ROOT" --entry-file "$entry") ||
        die 'original review attempt is unavailable; preserve artifacts and reconcile'
    if jq -e '.recoverableUnsent == true' <<<"$record" >/dev/null; then
        ATTEMPT_RECOVERING=1
        return 1
    fi
    jq -e --arg base "$REQUESTED_REVIEW_BASE_SHA" \
        '((.reviewBaseOverride // false) == ($base != "")) and
         ($base == "" or (.reviewBase // .base) == $base)' \
        <<<"$record" >/dev/null || die 'requested --review-base-sha conflicts with the original review attempt'
    jq -e --arg head "$(git rev-parse HEAD)" --arg launcher "$LAUNCHER_PATH" \
        '.state == "completed" and .canonical == true and .head == $head and .launcher == $launcher' <<<"$record" >/dev/null ||
        die "preserving original review evidence; reconcile existing attempt: $(jq -c '{id,state,observedState,head}' <<<"$record")"
    if [[ -n $REVIEWER_OVERRIDE || -n $OVERRIDE_AUTHORIZATION ]]; then
        [[ -n $REVIEWER_OVERRIDE && -n $OVERRIDE_AUTHORIZATION &&
           $REVIEWER_OVERRIDE == "$(jq -r '.model + "-" + .effort' <<<"$record")" ]] ||
            die 'existing review cannot be repurchased with a different or unauthorized override'
    fi
    cmd_attempt validate --repo-root "$CONTRACT_ROOT" --entry-file "$entry" >/dev/null || die 'original review proof failed validation'
    PROVIDER=$(jq -r '.provider' <<<"$record") MODEL=$(jq -r '.model' <<<"$record")
    EFFORT=$(jq -r '.effort' <<<"$record") MODE=$(jq -r '.mode' <<<"$record")
    MODEL_SUBSTITUTED_FROM=$(jq -r '.modelSubstitutedFrom // ""' <<<"$record")
    REPLAY_EXCLUSION_COUNT=$(jq -r '.exclusionCount // 0' <<<"$record")
    EXCLUDED_SHA256=$(jq -r '.excludedSha256 // ""' <<<"$record")
    receipt_line
}

reserve_review_attempt() {
    ATTEMPT_ENTRY="$RUN_DIR/state/review-attempt.json"
    prepare_owned_artifact "$ATTEMPT_ENTRY"
    local retry_id=${RETRY_ATTEMPT_ID:-} budget=${MAX_BUDGET_USD:-5.00}
    local tokens=${MAX_OUTPUT_TOKENS:-} duration=${MAX_DURATION_SECONDS:-900}
    if [[ -n $retry_id || -n ${RETRY_AUTHORIZATION:-} ]]; then
        [[ -n $retry_id && -n ${RETRY_AUTHORIZATION:-} ]] ||
            die 'retry requires paired attempt and authorization'
        [[ $PROVIDER != anthropic || -n $tokens ]] ||
            die 'Claude retry requires an explicit output-token limit'
    fi
    jq -n --arg repo "$REPO" --argjson pr "$PR" --arg payload "$PAYLOAD" \
        --arg repo_root "$CONTRACT_ROOT" \
        --arg head "$(git rev-parse HEAD)" --arg base "$(git rev-parse "origin/$BASE_REF")" \
        --arg review_base "$REVIEW_BASE_SHA" --arg review_base_override "$REVIEW_BASE_OVERRIDE" \
        --arg provider "$PROVIDER" --arg model "$MODEL" --arg effort "$EFFORT" --arg mode "$MODE" \
        --arg configured "$CONFIGURED_REVIEWER" --arg override "$REVIEWER_OVERRIDE" \
        --arg substituted "$MODEL_SUBSTITUTED_FROM" \
        --argjson exclusion_count "${#EXCLUSION_SPECS[@]}" --arg excluded_sha256 "$EXCLUDED_SHA256" \
        --arg authorization "$OVERRIDE_AUTHORIZATION" --argjson pid "$$" \
        --arg launcher "$LAUNCHER_PATH" --arg result "$RUN_DIR/adversarial.result.json" \
        --arg retry_id "$retry_id" --arg budget "$budget" --arg tokens "$tokens" \
        --arg duration "$duration" \
        '{repo:$repo,pr:$pr,payload:$payload,head:$head,base:$base,reviewBase:$review_base,
          reviewBaseOverride:($review_base_override == "1"),provider:$provider,repoRoot:$repo_root,
          model:$model,effort:$effort,mode:$mode,configuredReviewer:$configured,override:$override,
        modelSubstitutedFrom:$substituted,
        exclusionCount:$exclusion_count,excludedSha256:$excluded_sha256,
        overrideAuthorization:$authorization,launcher:$launcher,launcherPid:$pid,result:$result,
        canonical:true,procedure:"one-shot diff review; no contract-blind or two-pass attestation",
          enforcement:"supported-helper-only; raw CLI bypass cannot be intercepted"}
        + {maxBudgetUsd:(if $provider == "anthropic" then ($budget|tonumber) else null end),
            maxOutputTokens:(if $provider == "anthropic" and $tokens != "" then ($tokens|tonumber) else null end),
            maxDurationSeconds:($duration|tonumber)}' >"$ATTEMPT_ENTRY"
    local rc=0
    if [[ -n $retry_id ]]; then
        ATTEMPT_RECORD=$("$SCRIPT_DIR/review-ledger.sh" attempt retry --repo-root "$CONTRACT_ROOT" \
            --entry-file "$ATTEMPT_ENTRY" --id "$retry_id" --authorization "$RETRY_AUTHORIZATION") || rc=$?
        ((rc == 0)) || die 'authorized retry reservation failed; preserve prior attempt evidence'
    else
        ATTEMPT_RECORD=$("$SCRIPT_DIR/review-ledger.sh" attempt reserve --repo-root "$CONTRACT_ROOT" \
            --entry-file "$ATTEMPT_ENTRY") || rc=$?
    fi
    if ((rc == 20)); then
        ATTEMPT_RECORD=$("$SCRIPT_DIR/review-ledger.sh" attempt read --repo-root "$CONTRACT_ROOT" --entry-file "$ATTEMPT_ENTRY") ||
            die 'existing review attempt is unreadable'
        if jq -e '.recoverableUnsent == true' <<<"$ATTEMPT_RECORD" >/dev/null; then
            ATTEMPT_RECORD=$(cmd_attempt recover --repo-root "$CONTRACT_ROOT" --entry-file "$ATTEMPT_ENTRY" \
                --id "$(jq -r '.id' <<<"$ATTEMPT_RECORD")") || die 'unsent attempt recovery failed'
            ATTEMPT_ID=$(jq -r '.id' <<<"$ATTEMPT_RECORD")
            return 0
        fi
        # Read/reconcile the original attempt; never replace it with a new run.
        if jq -e --arg payload "$PAYLOAD" --arg model "$MODEL" --arg effort "$EFFORT" \
            --arg head "$(git rev-parse HEAD)" --arg base "$(git rev-parse "origin/$BASE_REF")" \
            --arg review_base "$REVIEW_BASE_SHA" --arg launcher "$LAUNCHER_PATH" \
            '.state == "completed" and .canonical == true and .payload == $payload and
             .model == $model and .effort == $effort and .head == $head and .base == $base and
             (.reviewBase // .base) == $review_base and
             .launcher == $launcher' <<<"$ATTEMPT_RECORD" >/dev/null; then
            jq '.completedResult' <<<"$ATTEMPT_RECORD" >"$RUN_DIR/adversarial.result.json"
            "$SCRIPT_DIR/review-ledger.sh" attempt validate --repo-root "$CONTRACT_ROOT" --entry-file "$ATTEMPT_ENTRY" >/dev/null ||
                die 'completed attempt evidence failed validation during resume'
            initialize_finding_ledger
            receipt_line
            return 20
        fi
        die "existing durable review attempt; reconcile instead of relaunching: $(jq -c '{id,state,observedState,helperPid,result}' <<<"$ATTEMPT_RECORD")"
    fi
    ((rc == 0)) || die 'could not reserve durable review attempt'
    ATTEMPT_ID=$(jq -r '.id' <<<"$ATTEMPT_RECORD")
}

finish_review_attempt() {
    local state=$1 result="$RUN_DIR/adversarial.result.json" tmp="$RUN_DIR/adversarial.result.json.tmp"
    if [[ $state == completed ]]; then
        jq --arg id "$ATTEMPT_ID" --argjson attempt "$ATTEMPT_RECORD" --arg substituted "$MODEL_SUBSTITUTED_FROM" \
            '. + {attemptId:$id,reviewBase:$attempt.reviewBase,prBase:$attempt.base,diffPayload:$attempt.payload,
              launcher:{path:$attempt.launcher,sha256:$attempt.launcherSha256},
              reviewProcedure:$attempt.procedure,configuredReviewer:$attempt.configuredReviewer,
              reviewerOverride:$attempt.override,overrideAuthorization:$attempt.overrideAuthorization}
              + (if $substituted == "" then {} else {modelSubstitutedFrom:$substituted} end)' \
            "$result" >"$tmp" || die 'could not bind result to durable attempt'
        mv -- "$tmp" "$result"
    else
        local current
        current=$("$SCRIPT_DIR/review-ledger.sh" attempt read --repo-root "$CONTRACT_ROOT" --entry-file "$ATTEMPT_ENTRY")
        [[ $(jq -r '.state' <<<"$current") != reserved ]] || state=parser-rejected
    fi
    local rc=0
    "$SCRIPT_DIR/review-ledger.sh" attempt finish --repo-root "$CONTRACT_ROOT" --entry-file "$ATTEMPT_ENTRY" \
        --id "$ATTEMPT_ID" --parent-pid "$$" --state "$state" >/dev/null || rc=$?
    ((rc == 0 || rc == 20)) || die 'could not finalize durable review attempt'
}
