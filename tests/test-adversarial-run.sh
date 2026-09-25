#!/usr/bin/env bash
# Boundary coverage for the one-shot adversarial review orchestrator.
set -uo pipefail

TEST_NAME='adversarial run'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/adversarial-run.sh"
consent="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export CODEX_HOME="$tmp/codex-home"
mkdir -p "$CODEX_HOME"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' >"$CODEX_HOME/config.toml"

repo="$tmp/repo"
origin="$tmp/origin.git"
git init --bare --quiet "$origin"
git init --quiet --initial-branch=main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
git -C "$repo" remote add origin "$origin"
printf '%s\n' base >"$repo/example.txt"
git -C "$repo" add example.txt
git -C "$repo" commit --quiet -m base
git -C "$repo" push --quiet -u origin main
historical_base_oid=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" switch --quiet -c feature
printf '%s\n' changed >"$repo/example.txt"
git -C "$repo" commit --quiet -am change
git -C "$repo" switch --quiet main
printf '%s\n' merged-743-change >"$repo/pr-743.txt"
git -C "$repo" add pr-743.txt
git -C "$repo" commit --quiet -m 'merged PR 743'
git -C "$repo" push --quiet origin main
git -C "$repo" switch --quiet feature
git -C "$repo" merge --quiet --no-edit main
head_oid=$(git -C "$repo" rev-parse HEAD)
export FAKE_HEAD_OID=$head_oid
FAKE_BASE_OID=$(git -C "$repo" rev-parse origin/main)
export FAKE_BASE_OID

mkdir -- "$repo/.agent"
contract="$repo/.agent/env-contract.txt"
write_contract() {
    local harness=$1 peer=$2 state=$3
    printf '%s\n' \
        'repo=acme/widget' \
        "harness= name=$harness trailer=\"Test <test@example.invalid>\" other=$peer" \
        "peer-cli= $peer $state" >"$contract"
    chmod 600 -- "$contract"
}
write_contract codex claude "present path=$tmp/fake-claude"

fake_bin="$tmp/bin"
mkdir -- "$fake_bin"
cat >"$fake_bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == api && ${2:-} =~ ^repos/acme/widget/pulls/[0-9]+$ ]] || exit 1
printf '%s\n' "{\"base\":{\"ref\":\"main\",\"sha\":\"$FAKE_BASE_OID\"},\"head\":{\"sha\":\"$FAKE_HEAD_OID\"}}"
EOF
chmod +x "$fake_bin/gh"

cat >"$tmp/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then printf 'fixture Claude version\n'; exit 0; fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
# Records that the provider CLI was actually launched. A consent gate that
# blocks must leave no marker: absence of a result file alone would still pass
# if a regression launched the provider and simply failed to publish.
[[ -z ${FAKE_CLAUDE_CALLED:-} ]] || printf 'called\n' >>"$FAKE_CLAUDE_CALLED"
if [[ -n ${FAKE_PROVIDER_GATE_DIR:-} ]]; then
    mkdir -p "$FAKE_PROVIDER_GATE_DIR"
    : >"$FAKE_PROVIDER_GATE_DIR/${FAKE_PROVIDER_LABEL:?}.started"
    for _ in {1..500}; do
        [[ ! -e $FAKE_PROVIDER_GATE_DIR/release ]] || break
        sleep 0.01
    done
    [[ -e $FAKE_PROVIDER_GATE_DIR/release ]] || exit 42
fi
if [[ -n ${FAKE_CLAUDE_LIMITS:-} ]]; then
    printf '%s\n' "${CLAUDE_CODE_MAX_OUTPUT_TOKENS:-unset}" >"$FAKE_CLAUDE_LIMITS"
    printf '%s\n' "$@" >>"$FAKE_CLAUDE_LIMITS"
fi
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-opus-5","tools":["StructuredOutput"],"mcp_servers":[]}'
if [[ ${FAKE_PROVIDER_ERROR:-} == 1 ]]; then
    printf '%s\n' '{"type":"result","subtype":"error_max_budget_usd","is_error":true,"terminal_reason":"budget_exhausted"}'
    exit 1
fi
if [[ ${FAKE_INVALID:-} == 1 ]]; then
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"no_findings","findings":[],"unexpected":true},"modelUsage":{"claude-opus-5":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
else
    printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"findings","findings":[{"priority":"P1","location":"example.txt:1","failureScenario":"breaks","smallestFix":"repair"},{"priority":"P2","location":"example.txt:1","failureScenario":"degrades","smallestFix":"repair"}]},"modelUsage":{"claude-opus-5":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
fi
EOF
chmod +x "$tmp/fake-claude"

cat >"$tmp/fake-codex" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' '--model --config --sandbox --ephemeral --ignore-user-config'
    printf '%s\n' '--ignore-rules --skip-git-repo-check --output-schema'
    printf '%s\n' '--output-last-message --json'
    exit 0
fi
[[ -z ${FAKE_CODEX_CALLED:-} ]] || printf 'called\n' >>"$FAKE_CODEX_CALLED"
if [[ ${FAKE_CODEX_PROVIDER_ERROR:-} == 1 ]]; then
    printf '%s\n' '{"type":"result","is_error":true,"error":"fixture provider failure"}'
    exit 1
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then last_file=$2; shift 2; else shift; fi
done
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}'
printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
EOF
chmod +x "$tmp/fake-codex"

expected="$tmp/expected.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$expected"

grant() {
    local run_dir=$1 provider=$2 diff=${3:-$expected} base_sha=${4:-}
    # Each grant below starts an independent scenario, with a fresh PR budget.
    rm -rf -- "$repo/.git/agentkit-review-attempts"
    grant_pr "$run_dir" "$provider" 42 "$diff" "$base_sha"
}

grant_pr() {
    local run_dir=$1 provider=$2 pr=$3 diff=${4:-$expected} base_sha=${5:-} payload
    mkdir -- "$run_dir" "$run_dir/state"
    chmod 700 "$run_dir" "$run_dir/state"
    local -a payload_args=(payload --worktree "$repo" --run-dir "$run_dir" \
        --repo acme/widget --pr "$pr" --diff "$diff")
    [[ -z $base_sha ]] || payload_args+=(--base-sha "$base_sha")
    payload=$(/bin/bash "$consent" "${payload_args[@]}")
    /bin/bash "$consent" grant --worktree "$repo" --run-dir "$run_dir" \
        --provider "$provider" --payload "$payload" --source interactive >/dev/null
}

missing="$tmp/missing"
mkdir -- "$missing"
chmod 700 "$missing"
printf '%s\n' 'stale result' >"$missing/adversarial.result.json"
missing_rc=0
(cd "$root" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/missing.called" \
    bash agentkit/skills/review-remote-pr/scripts/adversarial-run.sh \
        --worktree "$repo" --pr 42 --repo acme/widget --run-dir "$missing") \
    >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_rc=$?
assert_eq 1 "$missing_rc" 'missing consent blocks before provider launch'
assert_contains "$(cat -- "$tmp/missing.err")" 'consent' 'missing consent is named'
assert_eq no "$( [[ -e $missing/adversarial.result.json ]] && printf yes || printf no )" \
    'missing consent does not publish a verdict'
assert_eq no "$( [[ -e $tmp/missing.called ]] && printf yes || printf no )" \
    'missing consent never launches the provider CLI at all'
# #473: nothing was sent, so no pre-send marker exists either -- this is the
# state that makes an automatic retry safe with no operator authorization.
assert_eq no "$( [[ -e $missing/state/launch-attempted ]] && printf yes || printf no )" \
    'missing consent never writes the launch-attempted marker; retry is provably safe'

mismatch_run="$tmp/mismatch-run"
# Keyed-only roots pass contract loading and still stop at the consent gate.
mv -- "$contract" "$repo/.agent/env-contract.codex.txt"
keyed_run="$tmp/keyed-run"
keyed_rc=0
(cd "$repo" && env CLAUDECODE= CLAUDE_CODE_ENTRYPOINT= CODEX_PERMISSION_PROFILE=test \
    PATH="$fake_bin:$PATH" bash "$script" --pr 42 --repo acme/widget --run-dir "$keyed_run") \
    > "$tmp/keyed.out" 2> "$tmp/keyed.err" || keyed_rc=$?
assert_eq 1 "$keyed_rc" 'keyed-only review still requires consent'
assert_contains "$(cat "$tmp/keyed.err")" 'consent' 'keyed-only root passes contract loading'

# Provenance must apply to the selected keyed path, not the absent legacy path.
git -C "$repo" add -f -- .agent/env-contract.codex.txt
tracked_keyed_rc=0
(cd "$repo" && env CLAUDECODE= CLAUDE_CODE_ENTRYPOINT= CODEX_PERMISSION_PROFILE=test \
    PATH="$fake_bin:$PATH" bash "$script" --pr 42 --repo acme/widget --run-dir "$tmp/tracked-keyed") \
    > "$tmp/tracked-keyed.out" 2> "$tmp/tracked-keyed.err" || tracked_keyed_rc=$?
assert_eq 1 "$tracked_keyed_rc" 'tracked keyed contract is rejected'
assert_contains "$(cat "$tmp/tracked-keyed.err")" 'environment contract is tracked:' \
    'tracking check names the selected keyed contract'
git -C "$repo" reset -q -- .agent/env-contract.codex.txt
mv -- "$repo/.agent/env-contract.codex.txt" "$contract"

for topology in absent symlink; do
    mv -- "$contract" "$tmp/saved-contract"
    if [[ $topology == symlink ]]; then
        ln -s "$tmp/saved-contract" "$repo/.agent/env-contract.codex.txt"
    fi
    unsafe_rc=0
    (cd "$repo" && env CLAUDECODE= CLAUDE_CODE_ENTRYPOINT= CODEX_PERMISSION_PROFILE=test \
        PATH="$fake_bin:$PATH" bash "$script" --pr 42 --repo acme/widget --run-dir "$tmp/$topology-run") \
        > "$tmp/$topology.out" 2> "$tmp/$topology.err" || unsafe_rc=$?
    assert_eq 1 "$unsafe_rc" "$topology contract is rejected"
    if [[ $topology == absent ]]; then
        assert_contains "$(cat "$tmp/$topology.err")" 'no environment contract:' 'absence is distinct from unsafe ownership'
        assert_contains "$(cat "$tmp/$topology.err")" 'env-contract.codex.txt' 'absence names keyed candidate'
        assert_contains "$(cat "$tmp/$topology.err")" 'env-contract.txt' 'absence names legacy candidate'
    else
        assert_contains "$(cat "$tmp/$topology.err")" 'not a self-owned regular file:' 'keyed symlink remains unsafe'
        rm -- "$repo/.agent/env-contract.codex.txt"
    fi
    mv -- "$tmp/saved-contract" "$contract"
done

mkdir -- "$mismatch_run" "$mismatch_run/state"
chmod 700 "$mismatch_run" "$mismatch_run/state"
mismatch_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" FAKE_HEAD_OID=0000000000000000000000000000000000000000 \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$mismatch_run") \
    >"$tmp/mismatch.out" 2>"$tmp/mismatch.err" || mismatch_rc=$?
assert_eq 1 "$mismatch_rc" 'checkout that is not the PR head is rejected'
assert_contains "$(cat -- "$tmp/mismatch.err")" 'does not match PR head' \
    'checkout mismatch names the PR head invariant'
assert_eq no "$( [[ -e $mismatch_run/adversarial.diff ]] && printf yes || printf no )" \
    'checkout mismatch does not build a review diff'

# Explicit canonical limits reach the provider boundary, with no second send.
limits_run="$tmp/limits-run"
grant "$limits_run" anthropic
limits_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_LIMITS="$tmp/limits.args" bash "$script" --pr 42 --repo acme/widget \
    --run-dir "$limits_run" --max-budget-usd 10 --max-output-tokens 128000 \
    --max-duration-seconds 1800) >"$tmp/limits.out" 2>"$tmp/limits.err" || limits_rc=$?
assert_eq 0 "$limits_rc" 'canonical launcher accepts explicit review resource limits'
assert_eq 128000 "$(head -n 1 "$tmp/limits.args" 2>/dev/null)" 'requested output limit reaches Claude'
assert_contains "$(cat "$tmp/limits.args" 2>/dev/null)" $'--max-budget-usd\n10.00' 'requested dollar cap reaches Claude'
for invalid_limit in 0 -1 128000.5 99999999999999999999999; do
    invalid_limit_rc=0
    (cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
        FAKE_CLAUDE_CALLED="$tmp/invalid-limit.called" bash "$script" --pr 42 --repo acme/widget \
        --run-dir "$tmp/invalid-limit" --max-output-tokens "$invalid_limit") \
        >"$tmp/invalid-limit.out" 2>"$tmp/invalid-limit.err" || invalid_limit_rc=$?
    assert_eq 2 "$invalid_limit_rc" 'invalid output limit is a usage error'
done
assert_eq no "$([[ -e $tmp/invalid-limit.called ]] && printf yes || printf no)" 'invalid output limit never sends a review'

# An explicitly authorized failed-attempt retry launches once and retains history.
retry_failed="$tmp/retry-failed"
grant "$retry_failed" anthropic
retry_failed_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_PROVIDER_ERROR=1 bash "$script" --pr 42 --repo acme/widget --run-dir "$retry_failed") \
    >"$tmp/retry-failed.out" 2>"$tmp/retry-failed.err" || retry_failed_rc=$?
assert_eq 1 "$retry_failed_rc" 'a provider budget error records a failed canonical attempt'
retry_ledger="$root/agentkit/skills/review-remote-pr/scripts/review-ledger.sh"
prior_record=$(bash "$retry_ledger" attempt read --repo-root "$repo" --entry-file "$retry_failed/state/review-attempt.json")
prior_retry_id=$(jq -r .id <<<"$prior_record")
prior_retry_hash=$(sha256sum "$retry_failed/claude.ndjson" | cut -d' ' -f1)
retry_missing_limit="$tmp/retry-missing-limit"
mkdir -m 700 "$retry_missing_limit"
retry_missing_payload=$(bash "$consent" payload --worktree "$repo" --run-dir "$retry_missing_limit" \
    --repo acme/widget --pr 42 --diff "$expected")
bash "$consent" grant --worktree "$repo" --run-dir "$retry_missing_limit" --provider anthropic \
    --payload "$retry_missing_payload" --source interactive >/dev/null
retry_missing_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/retry-missing-limit.calls" bash "$script" --pr 42 --repo acme/widget \
    --run-dir "$retry_missing_limit" --retry-attempt "$prior_retry_id" \
    --retry-authorization 'Operator authorized one retry' --max-budget-usd 10) \
    >"$tmp/retry-missing-limit.out" 2>"$tmp/retry-missing-limit.err" || retry_missing_rc=$?
assert_eq 1 "$retry_missing_rc" 'Claude retry still requires its explicit output-token limit'
assert_eq no "$( [[ -e $tmp/retry-missing-limit.calls ]] && printf yes || printf no )" \
    'Claude retry without its required output-token limit never launches a provider'
retry_run="$tmp/retry-success"
mkdir -m 700 "$retry_run"
retry_payload=$(bash "$consent" payload --worktree "$repo" --run-dir "$retry_run" --repo acme/widget --pr 42 --diff "$expected")
bash "$consent" grant --worktree "$repo" --run-dir "$retry_run" --provider anthropic \
    --payload "$retry_payload" --source interactive >/dev/null
retry_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/timeout-proof.calls" bash "$script" --pr 42 --repo acme/widget --run-dir "$retry_run" \
    --retry-attempt "$prior_retry_id" --retry-authorization 'Operator authorized one retry' \
    --stopped-timeout-proof "$tmp/not-a-proof" --max-output-tokens 128000) \
    >"$tmp/timeout-proof.out" 2>"$tmp/timeout-proof.err" || retry_rc=$?
assert_eq 1 "$retry_rc" 'canonical launcher forwards timeout proof to the attempt gate'
assert_contains "$(cat "$tmp/timeout-proof.err")" 'stopped-timeout proof requires a canonical unknown attempt' \
    'a timeout proof cannot repurpose a failed attempt'
assert_eq no "$([[ -e $tmp/timeout-proof.calls ]] && printf yes || printf no)" 'rejected timeout proof never sends'
# The failed preparation belongs only to this fresh test run, not the prior attempt.
rm -rf -- "$retry_run"
mkdir -m 700 "$retry_run"
bash "$consent" grant --worktree "$repo" --run-dir "$retry_run" --provider anthropic \
    --payload "$retry_payload" --source interactive >/dev/null
retry_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/retry.calls" bash "$script" --pr 42 --repo acme/widget --run-dir "$retry_run" \
    --retry-attempt "$prior_retry_id" --retry-authorization 'Operator authorized one retry' \
    --max-budget-usd 10 --max-output-tokens 128000 --max-duration-seconds 1800) \
    >"$tmp/retry.out" 2>"$tmp/retry.err" || retry_rc=$?
assert_eq 0 "$retry_rc" 'canonical authorized retry completes on the same reviewed head'
assert_eq 1 "$(wc -l <"$tmp/retry.calls" 2>/dev/null)" 'authorized retry sends exactly once'
retry_record=$(bash "$retry_ledger" attempt read --repo-root "$repo" --entry-file "$retry_run/state/review-attempt.json")
assert_eq "$prior_retry_id" "$(jq -r .retryOf <<<"$retry_record")" 'canonical retry binds the prior failed attempt'
assert_eq "$prior_retry_hash" "$(jq -r '.previousAttempts[0].transcriptSha256' <<<"$retry_record")" 'canonical retry archives the original transcript digest'
assert_eq "$prior_retry_hash" "$(sha256sum "$retry_failed/claude.ndjson" | cut -d' ' -f1)" 'canonical retry leaves prior transcript untouched'
retry_validate_rc=0
bash "$retry_ledger" attempt validate --repo-root "$repo" --entry-file "$retry_run/state/review-attempt.json" \
    >"$tmp/retry-validate.out" 2>"$tmp/retry-validate.err" || retry_validate_rc=$?
assert_eq 0 "$retry_validate_rc" 'completed retry retains valid canonical receipt provenance'

# Codex retries have no Claude-specific dollar or output-token options.
write_contract codex codex 'absent note="same-harness Codex retry fixture"'
codex_retry_failed="$tmp/codex-retry-failed"
grant "$codex_retry_failed" openai
codex_retry_failed_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    FAKE_CODEX_PROVIDER_ERROR=1 bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_retry_failed") \
    >"$tmp/codex-retry-failed.out" 2>"$tmp/codex-retry-failed.err" || codex_retry_failed_rc=$?
assert_eq 1 "$codex_retry_failed_rc" 'Codex provider failure records a terminal failed attempt'
codex_prior_record=$(bash "$retry_ledger" attempt read --repo-root "$repo" \
    --entry-file "$codex_retry_failed/state/review-attempt.json")
codex_prior_id=$(jq -r .id <<<"$codex_prior_record")
codex_retry_run="$tmp/codex-retry-success"
mkdir -m 700 "$codex_retry_run"
codex_retry_payload=$(bash "$consent" payload --worktree "$repo" --run-dir "$codex_retry_run" \
    --repo acme/widget --pr 42 --diff "$expected")
bash "$consent" grant --worktree "$repo" --run-dir "$codex_retry_run" --provider openai \
    --payload "$codex_retry_payload" --source interactive >/dev/null
codex_retry_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    FAKE_CODEX_CALLED="$tmp/codex-retry.calls" bash "$script" --pr 42 --repo acme/widget \
    --run-dir "$codex_retry_run" --retry-attempt "$codex_prior_id" \
    --retry-authorization 'Operator authorized one Codex retry') \
    >"$tmp/codex-retry.out" 2>"$tmp/codex-retry.err" || codex_retry_rc=$?
assert_eq 0 "$codex_retry_rc" 'Codex retry works without Claude-only resource flags'
assert_eq 1 "$(wc -l <"$tmp/codex-retry.calls" 2>/dev/null)" 'authorized Codex retry sends exactly once'
codex_retry_record=$(bash "$retry_ledger" attempt read --repo-root "$repo" \
    --entry-file "$codex_retry_run/state/review-attempt.json")
assert_eq null "$(jq -c '.maxBudgetUsd' <<<"$codex_retry_record")" 'Codex retry does not claim a Claude dollar ceiling'
assert_eq null "$(jq -c '.maxOutputTokens' <<<"$codex_retry_record")" 'Codex retry records no Claude output-token override'
write_contract codex claude "present path=$tmp/fake-claude"

invalid_parallel_run="$tmp/invalid-parallel-run"
grant "$invalid_parallel_run" anthropic
invalid_parallel_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/invalid-parallel.called" AGENTKIT_PARALLEL_RUN_ID='not a run id' \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_parallel_run") \
    >"$tmp/invalid-parallel.out" 2>"$tmp/invalid-parallel.err" || invalid_parallel_rc=$?
assert_eq 1 "$invalid_parallel_rc" 'invalid parallel run identity is refused before persistence'
assert_eq no "$( [[ -e $tmp/invalid-parallel.called ]] && printf yes || printf no )" \
    'invalid parallel run identity never launches the provider'

claude_run="$tmp/claude-run"
grant "$claude_run" anthropic
claude_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_CLAUDE_CALLED="$tmp/canonical.calls" \
    AGENTKIT_PARALLEL_RUN_ID=parallel-wave \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_run") \
    >"$tmp/claude.out" 2>"$tmp/claude.err" || claude_rc=$?
assert_eq 0 "$claude_rc" 'consented Claude review completes'
assert_eq yes "$( [[ -s $claude_run/adversarial.diff ]] && printf yes || printf no )" \
    'orchestrator writes the shared adversarial diff'
assert_eq yes "$( [[ -s $claude_run/adversarial.result.json ]] && printf yes || printf no )" \
    'orchestrator writes the canonical result'
assert_eq parallel-wave "$(jq -r .runId "$claude_run/state/review-attempt.json")" \
    'canonical review attempt persists its matching parallel run context'
assert_eq yes "$( [[ -f $claude_run/findings.ndjson ]] && printf yes || printf no )" \
    'a completed review initializes the findings ledger'
assert_eq 600 "$(stat -c %a "$claude_run/findings.ndjson")" \
    'the initialized findings ledger is owner-private'
assert_eq 0 "$(wc -c <"$claude_run/findings.ndjson")" \
    'a clean starting ledger has no dispositions'
assert_contains "$(cat -- "$tmp/claude.out")" 'provider=anthropic' 'receipt line names provider'
assert_contains "$(cat -- "$tmp/claude.out")" 'model=claude-opus-5' 'receipt line names model'
assert_contains "$(cat -- "$tmp/claude.out")" 'mode=cross-provider' 'receipt line names mode'
assert_contains "$(cat -- "$tmp/claude.out")" 'P1=1' 'receipt line counts P1 findings'
assert_contains "$(cat -- "$tmp/claude.out")" 'P2=1' 'receipt line counts P2 findings'
# #473: the pre-send marker is written for a completed review too -- its
# purpose is proving an attempt was made, not flagging failure.
assert_eq yes "$( [[ -s $claude_run/state/launch-attempted ]] && printf yes || printf no )" \
    'a completed review leaves the launch-attempted marker behind'
assert_eq 600 "$(stat -c %a "$claude_run/state/launch-attempted")" \
    'the launch-attempted marker is owner-private'
assert_eq 42 "$(jq -r '.pr' <"$claude_run/state/launch-attempted")" \
    'the launch-attempted marker records the PR number'
assert_eq "$head_oid" "$(jq -r '.head' <"$claude_run/state/launch-attempted")" \
    'the launch-attempted marker records the reviewed head SHA'
assert_eq true "$(jq -r '(.payload | type == "string" and length > 0)' <"$claude_run/state/launch-attempted")" \
    'the launch-attempted marker records a non-empty payload id'
assert_eq true "$(jq -r '(.timestamp | type == "string" and length > 0)' <"$claude_run/state/launch-attempted")" \
    'the launch-attempted marker records a timestamp'

# #903: root launches two real one-shot runners. The stub provider holds both
# after their durable `running` transition so overlap is observed, not inferred.
overlap_a="$tmp/overlap-a"
overlap_b="$tmp/overlap-b"
grant_pr "$overlap_a" anthropic 43
grant_pr "$overlap_b" anthropic 44
overlap_gate="$tmp/overlap-gate"
mkdir -p "$overlap_gate"
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/overlap.calls" FAKE_PROVIDER_GATE_DIR="$overlap_gate" \
    FAKE_PROVIDER_LABEL=pr43 AGENTKIT_PARALLEL_RUN_ID=overlap-wave \
    bash "$script" --pr 43 --repo acme/widget --run-dir "$overlap_a") \
    >"$tmp/overlap-a.out" 2>"$tmp/overlap-a.err" &
overlap_a_pid=$!
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/overlap.calls" FAKE_PROVIDER_GATE_DIR="$overlap_gate" \
    FAKE_PROVIDER_LABEL=pr44 AGENTKIT_PARALLEL_RUN_ID=overlap-wave \
    bash "$script" --pr 44 --repo acme/widget --run-dir "$overlap_b") \
    >"$tmp/overlap-b.out" 2>"$tmp/overlap-b.err" &
overlap_b_pid=$!
overlap_started=no
for _ in {1..500}; do
    if [[ -e $overlap_gate/pr43.started && -e $overlap_gate/pr44.started ]]; then
        overlap_started=yes
        break
    fi
    sleep 0.01
done
assert_eq yes "$overlap_started" 'two distinct review provider launches overlap before either finishes'
attempt_registry="$repo/.git/agentkit-review-attempts"
assert_eq 2 "$(jq -s '[.[] | select(.state == "running")] | length' "$attempt_registry"/*.json)" \
    'peak active reviewer count reaches two under the shared cap'
assert_eq 0 "$(find "$overlap_a" "$overlap_b" -name adversarial.result.json -type f | wc -l)" \
    'neither overlapping review finishes before the release gate'
: >"$overlap_gate/release"
overlap_a_rc=0
overlap_b_rc=0
wait "$overlap_a_pid" || overlap_a_rc=$?
wait "$overlap_b_pid" || overlap_b_rc=$?
assert_eq 0 "$overlap_a_rc" 'first overlapping review completes after release'
assert_eq 0 "$overlap_b_rc" 'second overlapping review completes after release'
assert_eq 2 "$(wc -l <"$tmp/overlap.calls")" 'two overlapping reviews launch the provider exactly once each'
assert_eq yes "$([[ $(jq -r .attemptId "$overlap_a/adversarial.result.json") != \
    "$(jq -r .attemptId "$overlap_b/adversarial.result.json")" ]] && printf yes || printf no)" \
    'overlapping reviews retain distinct result and attempt identities'

resume_run="$tmp/resumed-run"
mkdir -m 700 "$resume_run" "$resume_run/state"
resume_payload=$(jq -r '.payload' "$claude_run/state/launch-attempted")
"$consent" grant --worktree "$repo" --run-dir "$resume_run" --provider anthropic \
    --payload "$resume_payload" --source interactive >/dev/null
# Simulate a completed pre-reviewBase record: it is semantically based on the
# PR base and remains resumable without launching a second provider call.
attempt_key=$(printf 'acme/widget:42' | sha256sum | cut -d' ' -f1)
attempt_record_path="$repo/.git/agentkit-review-attempts/$attempt_key.json"
jq 'del(.reviewBase)' "$attempt_record_path" >"$tmp/legacy-attempt.json"
mv "$tmp/legacy-attempt.json" "$attempt_record_path"
resume_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_CLAUDE_CALLED="$tmp/canonical.calls" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$resume_run") >"$tmp/resume.out" 2>"$tmp/resume.err" || resume_rc=$?
assert_eq 0 "$resume_rc" 'new run directory resumes a legacy completed durable attempt'
assert_eq 1 "$(wc -l <"$tmp/canonical.calls")" 'legacy completed replay never invokes the provider again'
assert_eq "$(jq -r '.attemptId' "$claude_run/adversarial.result.json")" \
    "$(jq -r '.attemptId' "$resume_run/adversarial.result.json")" 'resume retains original attempt identity'
assert_eq "$script" "$(jq -r '.launcher.path' "$claude_run/adversarial.result.json")" 'result names actual launcher path'
same_dir_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_run") \
    >"$tmp/same-dir.out" 2>"$tmp/same-dir.err" || same_dir_rc=$?
assert_eq 0 "$same_dir_rc" 'same-directory resume validates the original completed attempt'
assert_eq "$(cat "$tmp/claude.out")" "$(cat "$tmp/same-dir.out")" \
    'same-directory resume reports the original exclusions and checksum'

relative_run="$repo/.agent/relative-run"
mkdir -m 700 "$relative_run" "$relative_run/state"
"$consent" grant --worktree "$repo" --run-dir "$relative_run" --provider anthropic \
    --payload "$resume_payload" --source interactive >/dev/null
relative_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir .agent/relative-run) \
    >"$tmp/relative.out" 2>"$tmp/relative.err" || relative_rc=$?
assert_eq 0 "$relative_rc" 'relative run path can resume an existing canonical review'
assert_eq "$relative_run/adversarial.result.json" "$(jq -r '.result' "$relative_run/state/review-attempt.json")" \
    'durable artifact paths remain usable after the caller changes directory'

override_run="$tmp/override-run"
for recovery_dir in same new; do
    rejected="$tmp/rejected-$recovery_dir"
    grant "$rejected" anthropic
    rejected_rc=0
    (cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE=/definitely/missing/claude \
        bash "$script" --pr 42 --repo acme/widget --run-dir "$rejected") \
        >"$tmp/rejected.out" 2>"$tmp/rejected.err" || rejected_rc=$?
    assert_eq 3 "$rejected_rc" 'unavailable provider preflight rejects without sending'
    rejection=$("${script%/*}/review-ledger.sh" attempt read --repo-root "$repo" --entry-file "$rejected/state/review-attempt.json")
    recovered="$rejected"
    if [[ $recovery_dir == new ]]; then
        recovered="$tmp/recovered-new"
        mkdir -m 700 "$recovered" "$recovered/state"
        "$consent" grant --worktree "$repo" --run-dir "$recovered" --provider anthropic \
            --payload "$(jq -r '.payload' <<<"$rejection")" --source interactive >/dev/null
    fi
    recovery_rc=0
    (cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
        FAKE_CLAUDE_CALLED="$tmp/recovery-$recovery_dir.calls" \
        bash "$script" --pr 42 --repo acme/widget --run-dir "$recovered") \
        >"$tmp/recovered.out" 2>"$tmp/recovered.err" || recovery_rc=$?
    assert_eq 0 "$recovery_rc" "$recovery_dir run-directory resumes after repairing an unsent preflight rejection"
    assert_eq "$(jq -r '.id' <<<"$rejection")" "$(jq -r '.attemptId' "$recovered/adversarial.result.json")" \
        'environment repair preserves original review obligation identity'
    assert_eq 1 "$(wc -l <"$tmp/recovery-$recovery_dir.calls" 2>/dev/null)" 'unsent recovery buys exactly one actual review'
done
grant "$override_run" anthropic
override_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$override_run" \
        --reviewer claude-opus-5-xhigh --override-authorization 'operator explicitly selected Opus/xhigh') \
    >"$tmp/override.out" 2>"$tmp/override.err" || override_rc=$?
assert_eq 0 "$override_rc" 'explicit authorized override still follows canonical launch'
assert_eq claude-opus-5-high "$(jq -r '.configuredReviewer' "$override_run/adversarial.result.json")" \
    'override retains base-configured selection'
assert_eq claude-opus-5-xhigh "$(jq -r '.reviewerOverride' "$override_run/adversarial.result.json")" \
    'result records operator-selected reviewer'
assert_eq 'operator explicitly selected Opus/xhigh' "$(jq -r '.overrideAuthorization' "$override_run/state/review-attempt.json")" \
    'durable attempt records the override authorization'
assert_rc 1 'override without authorization fails before launch' -- env PATH="$fake_bin:$PATH" \
    bash "$script" --worktree "$repo" --pr 42 --repo acme/widget --run-dir "$tmp/unauthorized-override" \
    --reviewer claude-opus-5-xhigh

# A combined review can intentionally start at a frozen ancestor of the PR's
# current base so it includes a commit already merged into main. The consent
# payload and attempt provenance must bind that historical base and the exact
# combined diff while retaining the live PR base separately.
combined_diff="$tmp/combined.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 \
    "$historical_base_oid...HEAD" -- ':/' >"$combined_diff"
assert_rc 2 'short historical base SHA is rejected as usage' -- env PATH="$fake_bin:$PATH" \
    bash "$script" --worktree "$repo" --pr 42 --repo acme/widget --run-dir "$tmp/short-base" \
        --review-base-sha "${historical_base_oid:0:12}"
missing_base_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" bash "$script" --pr 42 --repo acme/widget \
    --run-dir "$tmp/missing-base" --review-base-sha 1111111111111111111111111111111111111111) \
    >"$tmp/missing-base.out" 2>"$tmp/missing-base.err" || missing_base_rc=$?
assert_eq 1 "$missing_base_rc" 'unknown historical base commit is rejected'
assert_contains "$(cat "$tmp/missing-base.err")" 'does not resolve to a local commit' \
    'missing historical base names the commit-resolution failure'
nonancestor_base=$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'HEAD^{tree}')" -m unrelated-root)
nonancestor_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" bash "$script" --pr 42 --repo acme/widget \
    --run-dir "$tmp/nonancestor-base" --review-base-sha "$nonancestor_base") \
    >"$tmp/nonancestor-base.out" 2>"$tmp/nonancestor-base.err" || nonancestor_rc=$?
assert_eq 1 "$nonancestor_rc" 'non-ancestor historical base is rejected'
assert_contains "$(cat "$tmp/nonancestor-base.err")" 'ancestor of the observed PR base' \
    'non-ancestor failure names the PR base boundary'

# Historical rendering is permitted only when the current base and anchor use
# the same generated-path exclusion policy; otherwise block before publishing
# a diff or making a provider launch possible.
exclusion_repo="$tmp/exclusion-repo"
exclusion_origin="$tmp/exclusion-origin.git"
git init --bare --quiet "$exclusion_origin"
git init --quiet --initial-branch=main "$exclusion_repo"
git -C "$exclusion_repo" config user.email test@example.invalid
git -C "$exclusion_repo" config user.name test
git -C "$exclusion_repo" remote add origin "$exclusion_origin"
mkdir -- "$exclusion_repo/.agent"
printf '%s\n' 'AGENT_GENERATED_PATHS=old-generated' >"$exclusion_repo/.agent/config.env"
git -C "$exclusion_repo" add .agent/config.env
git -C "$exclusion_repo" commit --quiet -m 'old exclusions'
exclusion_anchor=$(git -C "$exclusion_repo" rev-parse HEAD)
git -C "$exclusion_repo" push --quiet -u origin main
git -C "$exclusion_repo" switch --quiet -c feature
printf '%s\n' feature >"$exclusion_repo/source.txt"
git -C "$exclusion_repo" add source.txt
git -C "$exclusion_repo" commit --quiet -m feature
git -C "$exclusion_repo" switch --quiet main
printf '%s\n' 'AGENT_GENERATED_PATHS=new-generated' >"$exclusion_repo/.agent/config.env"
git -C "$exclusion_repo" commit --quiet -am 'new exclusions'
git -C "$exclusion_repo" push --quiet origin main
git -C "$exclusion_repo" switch --quiet feature
git -C "$exclusion_repo" merge --quiet --no-edit main
exclusion_head=$(git -C "$exclusion_repo" rev-parse HEAD)
exclusion_pr_base=$(git -C "$exclusion_repo" rev-parse origin/main)
printf '%s\n' 'repo=acme/widget' \
    'harness= name=codex trailer="Test <test@example.invalid>" other=claude' \
    'peer-cli= claude present path=/bin/true' >"$exclusion_repo/.agent/env-contract.txt"
chmod 600 "$exclusion_repo/.agent/env-contract.txt"
exclusion_run="$tmp/exclusion-run"
exclusion_rc=0
(cd "$exclusion_repo" && PATH="$fake_bin:$PATH" FAKE_HEAD_OID="$exclusion_head" \
    FAKE_BASE_OID="$exclusion_pr_base" bash "$script" --pr 42 --repo acme/widget \
        --run-dir "$exclusion_run" --review-base-sha "$exclusion_anchor") \
    >"$tmp/exclusion.out" 2>"$tmp/exclusion.err" || exclusion_rc=$?
assert_eq 1 "$exclusion_rc" 'historical base with changed generated exclusions is blocked'
assert_contains "$(cat "$tmp/exclusion.err")" 'generated-path exclusions different' \
    'exclusion-policy conflict identifies both base revisions'
assert_eq no "$( [[ -e $exclusion_run/adversarial.diff ]] && printf yes || printf no )" \
    'exclusion-policy conflict blocks before publishing a diff'
assert_eq no "$( [[ -e $exclusion_run/state/launch-attempted ]] && printf yes || printf no )" \
    'exclusion-policy conflict blocks before provider launch'

combined_run="$tmp/combined-run"
grant "$combined_run" anthropic "$combined_diff" "$historical_base_oid"
combined_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/combined.called" bash "$script" --pr 42 --repo acme/widget \
        --run-dir "$combined_run" --review-base-sha "$historical_base_oid") \
    >"$tmp/combined.out" 2>"$tmp/combined.err" || combined_rc=$?
assert_eq 0 "$combined_rc" 'historical review base permits one combined PR review'
assert_eq "$(sha256sum "$combined_diff" | awk '{print $1}')" \
    "$(sha256sum "$combined_run/adversarial.diff" | awk '{print $1}')" \
    'combined review sends the exact consented diff bytes'
assert_contains "$(cat "$combined_run/adversarial.diff")" 'pr-743.txt' \
    'combined diff includes already-merged PR 743 changes'
assert_eq "$historical_base_oid" "$(jq -r '.reviewBase' "$combined_run/state/review-attempt.json")" \
    'durable attempt records the historical review base'
assert_eq "$FAKE_BASE_OID" "$(jq -r '.base' "$combined_run/state/review-attempt.json")" \
    'existing base field retains its current PR base meaning'
assert_eq "$(jq -r '.payload' "$combined_run/state/review-attempt.json")" \
    "$(jq -r '.diffPayload' "$combined_run/adversarial.result.json")" \
    'result binds the exact combined consent payload'
assert_eq "$historical_base_oid" "$(jq -r '.reviewBase' "$combined_run/adversarial.result.json")" \
    'result binds the historical review base'
assert_eq "$FAKE_BASE_OID" "$(jq -r '.prBase' "$combined_run/adversarial.result.json")" \
    'result binds the current PR base'
same_base_resume_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/combined.called" bash "$script" --pr 42 --repo acme/widget \
        --run-dir "$combined_run" --review-base-sha "$historical_base_oid") \
    >"$tmp/combined-same.out" 2>"$tmp/combined-same.err" || same_base_resume_rc=$?
assert_eq 0 "$same_base_resume_rc" 'resume with the original historical base preserves the completed review'
combined_resume_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/combined.called" bash "$script" --pr 42 --repo acme/widget \
        --run-dir "$combined_run") >"$tmp/combined-resume.out" 2>"$tmp/combined-resume.err" || combined_resume_rc=$?
assert_eq 1 "$combined_resume_rc" 'resume without the original historical base is rejected'
assert_contains "$(cat "$tmp/combined-resume.err")" 'review-base' \
    'conflicting resume names the bound review base'
assert_eq 1 "$(wc -l <"$tmp/combined.called")" \
    'conflicting resume does not send a second review'

# A leftover findings ledger from a prior attempt in a reused RUN_DIR must be
# rejected before the provider is ever launched -- not after paying for the
# review, which is the defect this file regression-tests (#393).
badmode_run="$tmp/badmode-run"
grant "$badmode_run" anthropic
printf '%s\n' stale >"$badmode_run/findings.ndjson"
chmod 644 -- "$badmode_run/findings.ndjson"
badmode_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/badmode.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$badmode_run") \
    >"$tmp/badmode.out" 2>"$tmp/badmode.err" || badmode_rc=$?
assert_eq 1 "$badmode_rc" 'a wrong-mode findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/badmode.err")" "$badmode_run/findings.ndjson" \
    'wrong-mode findings ledger failure names the path'
assert_eq no "$( [[ -e $tmp/badmode.called ]] && printf yes || printf no )" \
    'wrong-mode findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $badmode_run/adversarial.diff ]] && printf yes || printf no )" \
    'wrong-mode findings ledger check happens before diff construction'

symlink_run="$tmp/symlink-run"
grant "$symlink_run" anthropic
ln -s /etc/passwd "$symlink_run/findings.ndjson"
symlink_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/symlink.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$symlink_run") \
    >"$tmp/symlink.out" 2>"$tmp/symlink.err" || symlink_rc=$?
assert_eq 1 "$symlink_rc" 'a symlinked findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/symlink.err")" "$symlink_run/findings.ndjson" \
    'symlinked findings ledger failure names the path'
assert_eq no "$( [[ -e $tmp/symlink.called ]] && printf yes || printf no )" \
    'symlinked findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $symlink_run/adversarial.diff ]] && printf yes || printf no )" \
    'symlinked findings ledger check happens before diff construction'

# A safe (owned, mode-0600, regular, non-symlink) but NON-EMPTY pre-existing
# ledger must still be refused: silently accepting it would carry a prior
# review's dispositions into this review's receipt (follow-up to #393, PR
# #412 adversarial review).
nonempty_run="$tmp/nonempty-run"
grant "$nonempty_run" anthropic
printf '%s\n' '{"title":"prior finding","sha":"abc1234","verdict":"declined","rationale":"stale"}' \
    >"$nonempty_run/findings.ndjson"
chmod 600 -- "$nonempty_run/findings.ndjson"
nonempty_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/nonempty.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$nonempty_run") \
    >"$tmp/nonempty.out" 2>"$tmp/nonempty.err" || nonempty_rc=$?
assert_eq 1 "$nonempty_rc" 'a non-empty pre-existing findings ledger fails before launch'
assert_contains "$(cat -- "$tmp/nonempty.err")" "$nonempty_run/findings.ndjson" \
    'non-empty findings ledger failure names the path'
assert_contains "$(cat -- "$tmp/nonempty.err")" 'prior review' \
    'non-empty findings ledger failure explains why it is refused'
assert_eq no "$( [[ -e $tmp/nonempty.called ]] && printf yes || printf no )" \
    'non-empty findings ledger never launches the provider CLI'
assert_eq no "$( [[ -e $nonempty_run/adversarial.diff ]] && printf yes || printf no )" \
    'non-empty findings ledger check happens before diff construction'

# An empty, already-owned mode-0600 ledger (e.g. pre-created by the caller
# before launch) is a legitimate starting state and must not block the run.
preempty_run="$tmp/preempty-run"
grant "$preempty_run" anthropic
: >"$preempty_run/findings.ndjson"
chmod 600 -- "$preempty_run/findings.ndjson"
preempty_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$preempty_run") \
    >"$tmp/preempty.out" 2>"$tmp/preempty.err" || preempty_rc=$?
assert_eq 0 "$preempty_rc" 'a pre-existing empty owned mode-0600 ledger allows the run to complete'
assert_eq yes "$( [[ -f $preempty_run/findings.ndjson ]] && printf yes || printf no )" \
    'the pre-existing empty ledger survives a completed review'
assert_eq 0 "$(wc -c <"$preempty_run/findings.ndjson")" \
    'the pre-existing empty ledger is left empty by the runner itself'

write_contract claude codex "present path=$tmp/fake-codex"
codex_peer_run="$tmp/codex-peer-run"
grant "$codex_peer_run" openai
codex_peer_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_peer_run") \
    >"$tmp/codex-peer.out" 2>"$tmp/codex-peer.err" || codex_peer_rc=$?
assert_eq 0 "$codex_peer_rc" 'Claude harness selects the Codex peer helper'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'provider=openai' \
    'Claude harness receipt names the Codex peer provider'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'model=gpt-5.6-terra' \
    'Claude harness receipt names the Codex peer model'
assert_contains "$(cat -- "$tmp/codex-peer.out")" 'mode=cross-provider' \
    'Claude harness and Codex peer are genuinely cross-provider'

# A grant recorded under the peer-cli= CLI name ("codex") must satisfy the
# runner's check, which is keyed on the model-provider token ("openai") --
# the root should never have to read the runner source to find the "right"
# --provider token for consent-record.sh grant (#392).
codex_alias_run="$tmp/codex-alias-run"
grant "$codex_alias_run" codex
codex_alias_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_alias_run") \
    >"$tmp/codex-alias.out" 2>"$tmp/codex-alias.err" || codex_alias_rc=$?
assert_eq 0 "$codex_alias_rc" \
    'a consent grant recorded under the codex CLI name satisfies the runner check'
assert_contains "$(cat -- "$tmp/codex-alias.out")" 'provider=openai' \
    'a codex-CLI-name grant still completes the openai-provider review'

write_contract claude claude "present path=$tmp/fake-claude"
same_harness_run="$tmp/same-harness-run"
grant "$same_harness_run" anthropic
same_harness_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$same_harness_run") \
    >"$tmp/same-harness.out" 2>"$tmp/same-harness.err" || same_harness_rc=$?
assert_eq 0 "$same_harness_rc" 'same-harness selection completes'
assert_contains "$(cat -- "$tmp/same-harness.out")" 'provider=anthropic' \
    'same-harness receipt names the selected provider'
assert_contains "$(cat -- "$tmp/same-harness.out")" 'mode=blind-fallback' \
    'same-harness selection uses blind-fallback mode'
assert_not_contains "$(cat -- "$tmp/same-harness.out")" 'mode=cross-provider' \
    'same-harness selection can never emit cross-provider mode'

write_contract claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
claude_fallback_run="$tmp/claude-fallback-run"
grant "$claude_fallback_run" anthropic
claude_fallback_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_fallback_run") \
    >"$tmp/claude-fallback.out" 2>"$tmp/claude-fallback.err" || claude_fallback_rc=$?
assert_eq 0 "$claude_fallback_rc" 'Claude harness uses a same-harness fallback when its peer is absent'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'provider=anthropic' \
    'Claude fallback receipt names the running provider'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'model=claude-opus-5' \
    'Claude fallback receipt names the running model'
assert_contains "$(cat -- "$tmp/claude-fallback.out")" 'mode=blind-fallback' \
    'Claude fallback receipt names blind mode'

invalid_run="$tmp/invalid-run"
grant "$invalid_run" anthropic
invalid_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_INVALID=1 \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_run") \
    >"$tmp/invalid.out" 2>"$tmp/invalid.err" || invalid_rc=$?
assert_eq 1 "$invalid_rc" 'schema-invalid provider output blocks the review'
assert_eq blocked "$(jq -r '.status' <"$invalid_run/adversarial.result.json")" \
    'schema-invalid provider output publishes a blocked result'
assert_eq no "$( [[ -e $invalid_run/findings.ndjson ]] && printf yes || printf no )" \
    'a blocked review does not initialize the findings ledger'
assert_contains "$(cat -- "$tmp/invalid.out")" 'verdict=blocked' \
    'schema-invalid provider output cannot emit a clean verdict'

malformed_root="$tmp/malformed-plugin"
malformed_script_dir="$malformed_root/skills/review-remote-pr/scripts"
mkdir -p -- "$malformed_script_dir" "$malformed_root/skills/.shared/scripts/lib" \
    "$malformed_root/skills/parallel-issues/scripts"
cp -- "$script" "$malformed_script_dir/adversarial-run.sh"
cp -- "$consent" "$malformed_script_dir/consent-record.sh"
cp -- "$root/agentkit/skills/review-remote-pr/scripts/review-ledger.sh" "$malformed_script_dir/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-attempt.sh" "$malformed_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh" \
    "$malformed_root/skills/parallel-issues/scripts/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-launch-options.sh" "$malformed_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" \
    "$malformed_root/skills/.shared/scripts/lib/private-dir.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh" \
    "$malformed_root/skills/.shared/scripts/lib/canonical-diff.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/owned-path.sh" \
    "$malformed_root/skills/.shared/scripts/lib/owned-path.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh" \
    "$malformed_root/skills/.shared/scripts/lib/contract-cache.sh"
cat >"$malformed_script_dir/claude-adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($#)); do
    case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' '{"status":"blocked","blockedReason":"test","verdict":"blocked"}' >"$output"
exit 3
EOF
chmod +x "$malformed_script_dir/adversarial-run.sh" "$malformed_script_dir/consent-record.sh" \
    "$malformed_script_dir/claude-adversarial-review.sh"

malformed_run="$tmp/malformed-run"
grant "$malformed_run" anthropic
malformed_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" \
    bash "$malformed_script_dir/adversarial-run.sh" --pr 42 --repo acme/widget \
        --run-dir "$malformed_run") \
    >"$tmp/malformed.out" 2>"$tmp/malformed.err" || malformed_rc=$?
assert_eq 1 "$malformed_rc" 'malformed blocked result fails closed'
assert_contains "$(cat -- "$tmp/malformed.out")" 'verdict=blocked' \
    'malformed blocked result still emits a safe receipt'
assert_not_contains "$(cat -- "$tmp/malformed.err")" 'Cannot index' \
    'malformed blocked result does not crash receipt parsing'
assert_eq blocked "$(jq -r '.status' <"$malformed_run/adversarial.result.json")" \
    'malformed blocked result is replaced with a validated blocked result'

write_contract codex claude 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
codex_run="$tmp/codex-run"
grant "$codex_run" openai
codex_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$codex_run") \
    >"$tmp/codex.out" 2>"$tmp/codex.err" || codex_rc=$?
assert_eq 0 "$codex_rc" 'contract peer absence selects the blind fallback once'
assert_contains "$(cat -- "$tmp/codex.out")" 'provider=openai' 'fallback receipt line names OpenAI'
assert_contains "$(cat -- "$tmp/codex.out")" 'mode=blind-fallback' 'fallback receipt line names blind mode'
assert_contains "$(cat -- "$tmp/codex.out")" 'P1=0' 'fallback receipt line counts P1 findings'
assert_contains "$(cat -- "$tmp/codex.out")" 'P2=0' 'fallback receipt line counts P2 findings'

write_contract codex claude "present path=$tmp/fake-claude"


# --- a blocked result must never carry a verdict object --------------------
# status="blocked" alongside a findings-shaped verdict previously validated, and
# receipt_line read the verdict object rather than the status -- so a review that
# never happened reported verdict=findings with P1/P2 counts. A blocked run
# produced no review; it has no verdict to report.
verdict_root="$tmp/verdict-plugin"
verdict_script_dir="$verdict_root/skills/review-remote-pr/scripts"
mkdir -p -- "$verdict_script_dir" "$verdict_root/skills/.shared/scripts/lib" \
    "$verdict_root/skills/parallel-issues/scripts"
cp -- "$script" "$verdict_script_dir/adversarial-run.sh"
cp -- "$consent" "$verdict_script_dir/consent-record.sh"
cp -- "$root/agentkit/skills/review-remote-pr/scripts/review-ledger.sh" "$verdict_script_dir/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-attempt.sh" "$verdict_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh" \
    "$verdict_root/skills/parallel-issues/scripts/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-launch-options.sh" "$verdict_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" \
    "$verdict_root/skills/.shared/scripts/lib/private-dir.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh" \
    "$verdict_root/skills/.shared/scripts/lib/canonical-diff.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/owned-path.sh" \
    "$verdict_root/skills/.shared/scripts/lib/owned-path.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh" \
    "$verdict_root/skills/.shared/scripts/lib/contract-cache.sh"
cat >"$verdict_script_dir/claude-adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
while (($#)); do
    case $1 in
        --output) output=$2; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' '{"status":"blocked","blockedReason":"provider refused","verdict":{"verdict":"findings","findings":[{"priority":"P1","location":"a.sh:1","failureScenario":"x","smallestFix":"y"}]}}' >"$output"
exit 3
EOF
chmod +x "$verdict_script_dir/adversarial-run.sh" "$verdict_script_dir/consent-record.sh" \
    "$verdict_script_dir/claude-adversarial-review.sh"

verdict_run="$tmp/verdict-run"
grant "$verdict_run" anthropic
verdict_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" \
    bash "$verdict_script_dir/adversarial-run.sh" --pr 42 --repo acme/widget \
        --run-dir "$verdict_run") \
    >"$tmp/verdict.out" 2>"$tmp/verdict.err" || verdict_rc=$?
assert_eq 1 "$verdict_rc" 'a blocked result carrying a verdict object fails closed'
assert_contains "$(cat -- "$tmp/verdict.out")" 'verdict=blocked' \
    'a blocked result never reports the verdict it carried'
assert_contains "$(cat -- "$tmp/verdict.out")" 'P1=0' \
    'a blocked result reports no P1 findings'
assert_not_contains "$(cat -- "$tmp/verdict.out")" 'verdict=findings' \
    'a blocked review is never reported as a completed one'

# --- declared adversarial-review config is trusted only from the PR's BASE
# revision, never the working-tree checkout under review, and is ignored
# outright when the reviewed diff itself touches .agent/config.env (root
# review finding on PR #470, F1/P2: the working tree IS the candidate PR's
# own HEAD, so a PR could otherwise set its own review's effort=low or point
# the reviewer at the running harness). Each scenario below gets its own
# throwaway origin+checkout so base-branch content can be controlled
# precisely and independently of head content.

write_contract_at() {
    local dir=$1 harness=$2 peer=$3 state=$4 contract="$1/.agent/env-contract.txt"
    mkdir -p -- "$dir/.agent"
    printf '%s\n' \
        'repo=acme/widget' \
        "harness= name=$harness trailer=\"Test <test@example.invalid>\" other=$peer" \
        "peer-cli= $peer $state" >"$contract"
    chmod 600 -- "$contract"
}

# make_trust_repo BASE_CONFIG -- BASE_CONFIG is the content committed as
# main's .agent/config.env (before it is pushed to origin), or '' for none.
# Prints the new checkout's path.
make_trust_repo() {
    local base_config=$1 dir
    dir=$(mktemp -d "$tmp/trust-repo.XXXXXX")
    git init --bare --quiet "$dir.git"
    git init --quiet --initial-branch=main "$dir"
    git -C "$dir" config user.email test@example.invalid
    git -C "$dir" config user.name test
    git -C "$dir" remote add origin "$dir.git"
    printf '%s\n' base >"$dir/example.txt"
    git -C "$dir" add example.txt
    if [[ -n $base_config ]]; then
        mkdir -p "$dir/.agent"
        printf '%s' "$base_config" >"$dir/.agent/config.env"
        git -C "$dir" add .agent/config.env
    fi
    git -C "$dir" commit --quiet -m base
    git -C "$dir" push --quiet -u origin main
    printf '%s' "$dir"
}

# An invalid model in that same trusted source must survive as provenance.
invalid_model_repo=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=claude
 AGENT_ADVERSARIAL_REVIEW_MODEL = "claude-fable-5.1"
AGENT_ADVERSARIAL_REVIEW_EFFORT=xhigh')
write_contract_at "$invalid_model_repo" codex claude "present path=$tmp/fake-claude"
git -C "$invalid_model_repo" switch --quiet -c feature
printf '%s\n' changed >"$invalid_model_repo/example.txt"
git -C "$invalid_model_repo" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$invalid_model_repo" rev-parse HEAD)
export FAKE_HEAD_OID
git -C "$invalid_model_repo" diff --find-renames --unified=25 origin/main...HEAD >"$tmp/invalid-model.diff"
invalid_model_run="$tmp/invalid-model-run"
grant "$invalid_model_run" anthropic "$tmp/invalid-model.diff"
invalid_model_rc=0
(cd "$invalid_model_repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_model_run") \
    >"$tmp/invalid-model.out" 2>"$tmp/invalid-model.err" || invalid_model_rc=$?
assert_eq 0 "$invalid_model_rc" 'invalid model keeps the documented successful fallback'
assert_eq claude-fable-5.1 "$(jq -r '.modelSubstitutedFrom' "$invalid_model_run/adversarial.result.json")" \
    'runner result preserves the dropped base-declared model'
assert_contains "$(cat "$tmp/invalid-model.out")" 'configured claude-fable-5.1 was invalid and dropped' \
    'runner summary discloses the substituted model'
assert_contains "$(cat "$tmp/invalid-model.err")" 'did you mean claude-fable-5-1' \
    'runner preserves the resolver warning'

# --- (b) the base revision's declared values are honoured when the diff
# does not touch config.env -- and prove it is genuinely an override, not
# agreement: the peer (claude) is present and would normally be selected.
repo1=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=codex
AGENT_ADVERSARIAL_REVIEW_MODEL=gpt-5.6-sol
AGENT_ADVERSARIAL_REVIEW_EFFORT=xhigh')
write_contract_at "$repo1" codex claude "present path=$tmp/fake-claude"
git -C "$repo1" switch --quiet -c feature
printf '%s\n' changed >"$repo1/example.txt"
git -C "$repo1" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo1" rev-parse HEAD)
export FAKE_HEAD_OID
diff1="$tmp/repo1.diff"
git -C "$repo1" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff1"
declared_run="$tmp/declared-run"
grant "$declared_run" openai "$diff1"
declared_rc=0
(cd "$repo1" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$declared_run") \
    >"$tmp/declared.out" 2>"$tmp/declared.err" || declared_rc=$?
assert_eq 0 "$declared_rc" 'base-revision declarations are honoured when the diff leaves config.env alone'
assert_contains "$(cat -- "$tmp/declared.out")" 'provider=openai' \
    'AGENT_ADVERSARIAL_REVIEWER from the base revision overrides the peer-CLI provider'
assert_contains "$(cat -- "$tmp/declared.out")" 'model=gpt-5.6-sol' \
    'AGENT_ADVERSARIAL_REVIEW_MODEL from the base revision overrides the hardcoded model'
assert_contains "$(cat -- "$tmp/declared.out")" 'effort=xhigh' \
    'AGENT_ADVERSARIAL_REVIEW_EFFORT from the base revision overrides the hardcoded effort'
assert_contains "$(cat -- "$tmp/declared.out")" 'mode=blind-fallback' \
    'declaring the running harness itself as reviewer is blind-fallback mode'

# --- a base-declared reviewer absent on this machine falls back and says so -
repo2=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=codex
AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK=custom-fallback-model
AGENT_ADVERSARIAL_REVIEW_EFFORT=medium')
write_contract_at "$repo2" claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
git -C "$repo2" switch --quiet -c feature
printf '%s\n' changed >"$repo2/example.txt"
git -C "$repo2" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo2" rev-parse HEAD)
export FAKE_HEAD_OID
diff2="$tmp/repo2.diff"
git -C "$repo2" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff2"
absent_run="$tmp/absent-run"
grant "$absent_run" anthropic "$diff2"
absent_rc=0
(cd "$repo2" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$absent_run") \
    >"$tmp/absent.out" 2>"$tmp/absent.err" || absent_rc=$?
assert_eq 0 "$absent_rc" 'a base-declared but absent reviewer still completes via fallback'
assert_contains "$(cat -- "$tmp/absent.err")" "declared adversarial reviewer 'codex'" \
    'the fallback is announced, naming the declared reviewer'
assert_contains "$(cat -- "$tmp/absent.err")" 'not available on this machine' \
    'the announcement explains why it fell back'
assert_contains "$(cat -- "$tmp/absent.err")" "falling back to the running harness 'claude'" \
    'the announcement names the fallback target'
assert_contains "$(cat -- "$tmp/absent.out")" 'provider=anthropic' \
    'the fallback lands on the running harness provider, not the absent one'
assert_contains "$(cat -- "$tmp/absent.out")" 'model=custom-fallback-model' \
    'AGENT_ADVERSARIAL_REVIEW_MODEL_FALLBACK from the base revision supplies the fallback model'
assert_contains "$(cat -- "$tmp/absent.out")" 'effort=medium' \
    'AGENT_ADVERSARIAL_REVIEW_EFFORT from the base revision still applies to the fallback'
assert_contains "$(cat -- "$tmp/absent.out")" 'mode=blind-fallback' \
    'an absent-reviewer fallback can never be reported as cross-provider'

# --- (a) a HEAD-only change to config.env is ignored outright, not merely
# read from the (safe) base instead -- and proves it beats even a legitimate
# base declaration: base declares xhigh, head declares low, the pinned
# default ("high") must win over both.
repo3=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEW_EFFORT=xhigh')
write_contract_at "$repo3" claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
git -C "$repo3" switch --quiet -c feature
printf 'AGENT_ADVERSARIAL_REVIEW_EFFORT=low\n' >"$repo3/.agent/config.env"
printf '%s\n' changed >"$repo3/example.txt"
git -C "$repo3" commit --quiet -am 'change including config.env'
FAKE_HEAD_OID=$(git -C "$repo3" rev-parse HEAD)
export FAKE_HEAD_OID
diff3="$tmp/repo3.diff"
git -C "$repo3" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff3"
touched_run="$tmp/touched-run"
grant "$touched_run" anthropic "$diff3"
touched_rc=0
(cd "$repo3" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$touched_run") \
    >"$tmp/touched.out" 2>"$tmp/touched.err" || touched_rc=$?
assert_eq 0 "$touched_rc" 'a reviewed diff touching config.env still completes, via the pinned defaults'
assert_contains "$(cat -- "$tmp/touched.err")" 'the reviewed diff changes .agent/config.env' \
    'the runner announces why declarations are being ignored'
assert_contains "$(cat -- "$tmp/touched.err")" 'ignoring any declared adversarial-reviewer settings' \
    'the announcement names what it is ignoring'
assert_contains "$(cat -- "$tmp/touched.out")" 'effort=high' \
    'the pinned default effort wins over both the base and the HEAD declaration'
assert_not_contains "$(cat -- "$tmp/touched.out")" 'effort=low' \
    "the PR's own HEAD-only declaration is never honoured"
assert_not_contains "$(cat -- "$tmp/touched.out")" 'effort=xhigh' \
    'even the legitimate base declaration is ignored once the diff touches the file'

# --- an invalid base-declared reviewer is refused, not silently substituted -
# repo-config.sh drops it (naming the accepted set on its own stderr, which
# resolve_config_value discards) before adversarial-run.sh ever sees it, so
# this must behave exactly like no declaration at all: the peer-CLI default.
repo4=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gemini')
write_contract_at "$repo4" codex claude "present path=$tmp/fake-claude"
git -C "$repo4" switch --quiet -c feature
printf '%s\n' changed >"$repo4/example.txt"
git -C "$repo4" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo4" rev-parse HEAD)
export FAKE_HEAD_OID
diff4="$tmp/repo4.diff"
git -C "$repo4" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff4"
invalid_reviewer_run="$tmp/invalid-reviewer-run"
grant "$invalid_reviewer_run" anthropic "$diff4"
invalid_reviewer_rc=0
(cd "$repo4" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$invalid_reviewer_run") \
    >"$tmp/invalid-reviewer.out" 2>"$tmp/invalid-reviewer.err" || invalid_reviewer_rc=$?
assert_eq 0 "$invalid_reviewer_rc" 'an invalid base-declared reviewer still completes via the default'
assert_contains "$(cat -- "$tmp/invalid-reviewer.out")" 'provider=anthropic' \
    'an invalid AGENT_ADVERSARIAL_REVIEWER falls through to the peer-CLI default provider'
assert_contains "$(cat -- "$tmp/invalid-reviewer.out")" 'mode=cross-provider' \
    'an invalid declaration is never treated as an availability fallback'
assert_not_contains "$(cat -- "$tmp/invalid-reviewer.err")" 'AGENT_ADVERSARIAL_REVIEWER' \
    'adversarial-run.sh itself says nothing about a value repo-config.sh already dropped'

# --- AGENT_ADVERSARIAL_REVIEW_MODEL alone, with no REVIEWER declared -------
# A bare model id has no CLI to be interpreted against; the peer-CLI default
# selection (and its own default model) must stay byte-identical.
repo5=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEW_MODEL=should-be-ignored')
write_contract_at "$repo5" codex claude "present path=$tmp/fake-claude"
git -C "$repo5" switch --quiet -c feature
printf '%s\n' changed >"$repo5/example.txt"
git -C "$repo5" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo5" rev-parse HEAD)
export FAKE_HEAD_OID
diff5="$tmp/repo5.diff"
git -C "$repo5" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff5"
bare_model_run="$tmp/bare-model-run"
grant "$bare_model_run" anthropic "$diff5"
bare_model_rc=0
(cd "$repo5" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$bare_model_run") \
    >"$tmp/bare-model.out" 2>"$tmp/bare-model.err" || bare_model_rc=$?
assert_eq 0 "$bare_model_rc" 'an undeclared reviewer with a bare model id still completes'
assert_contains "$(cat -- "$tmp/bare-model.out")" 'model=claude-opus-5' \
    'a bare AGENT_ADVERSARIAL_REVIEW_MODEL is ignored without a declared reviewer'
assert_contains "$(cat -- "$tmp/bare-model.out")" 'mode=cross-provider' \
    'the peer-CLI default selection is unaffected'

# Restore the shared fixture's env, which the scenarios above overrode.
export FAKE_HEAD_OID=$head_oid

# --- #473: the documented `: '…'; launcher` idiom cannot be suppressed by a
# provenance value that itself contains '#' (e.g. a PR-number reference like
# "#283"), unlike the banned "leading comment" form where everything after an
# unquoted '#' -- including the launcher -- is dropped by the shell before it
# ever runs. This is the exact regression from the issue: the launcher must
# actually execute end to end.
provenance_run="$tmp/provenance-run"
grant "$provenance_run" anthropic
provenance_cell=": 'provenance: RUN_ID=r1; consent=granted; invocation=\"review PR #283 with --auto-review\"'; \"$script\" --pr 42 --repo acme/widget --run-dir \"$provenance_run\""
provenance_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/provenance.called" \
    bash -c "$provenance_cell") \
    >"$tmp/provenance.out" 2>"$tmp/provenance.err" || provenance_rc=$?
assert_eq 0 "$provenance_rc" \
    'the documented provenance idiom with a #-bearing value still launches the reviewer'
assert_eq yes "$( [[ -e $tmp/provenance.called ]] && printf yes || printf no )" \
    'a "#283"-bearing provenance argument cannot comment out the launcher'
assert_eq yes "$( [[ -s $provenance_run/adversarial.result.json ]] && printf yes || printf no )" \
    'the provenance-idiom launch produces a real result artifact, proving it actually ran'
assert_contains "$(cat -- "$tmp/provenance.out")" 'verdict=findings' \
    'the provenance-idiom launch completes a genuine review, not a silent no-op'

# --- #473: a launch that sent nothing (crashed before ever calling the
# provider helper) leaves no launch-attempted marker at all -- already
# covered by the missing-consent case above, since consent is checked before
# run_provider is ever entered. This scenario covers the complementary,
# genuinely ambiguous state: the marker WAS written (the send was attempted)
# but the provider crashed hard enough to leave no completed or blocked
# receipt behind it -- exactly the "possible send" state that must still
# require operator authorization rather than an automatic retry.
noreceipt_root="$tmp/noreceipt-plugin"
noreceipt_script_dir="$noreceipt_root/skills/review-remote-pr/scripts"
mkdir -p -- "$noreceipt_script_dir" "$noreceipt_root/skills/.shared/scripts/lib" \
    "$noreceipt_root/skills/parallel-issues/scripts"
cp -- "$script" "$noreceipt_script_dir/adversarial-run.sh"
cp -- "$consent" "$noreceipt_script_dir/consent-record.sh"
cp -- "$root/agentkit/skills/review-remote-pr/scripts/review-ledger.sh" "$noreceipt_script_dir/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-attempt.sh" "$noreceipt_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/parallel-issues/scripts/concurrency-cap.sh" \
    "$noreceipt_root/skills/parallel-issues/scripts/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/review-launch-options.sh" "$noreceipt_root/skills/.shared/scripts/lib/"
cp -- "$root/agentkit/skills/.shared/scripts/lib/private-dir.sh" \
    "$noreceipt_root/skills/.shared/scripts/lib/private-dir.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/canonical-diff.sh" \
    "$noreceipt_root/skills/.shared/scripts/lib/canonical-diff.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/owned-path.sh" \
    "$noreceipt_root/skills/.shared/scripts/lib/owned-path.sh"
cp -- "$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh" \
    "$noreceipt_root/skills/.shared/scripts/lib/contract-cache.sh"
cat >"$noreceipt_script_dir/claude-adversarial-review.sh" <<'EOF'
#!/usr/bin/env bash
# Simulates a hard mid-send crash: exits nonzero without writing --output at
# all, so the caller has no result artifact of any status to read.
exit 1
EOF
chmod +x "$noreceipt_script_dir/adversarial-run.sh" "$noreceipt_script_dir/consent-record.sh" \
    "$noreceipt_script_dir/claude-adversarial-review.sh"

noreceipt_run="$tmp/noreceipt-run"
grant "$noreceipt_run" anthropic
noreceipt_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" \
    bash "$noreceipt_script_dir/adversarial-run.sh" --pr 42 --repo acme/widget \
        --run-dir "$noreceipt_run") \
    >"$tmp/noreceipt.out" 2>"$tmp/noreceipt.err" || noreceipt_rc=$?
assert_eq 1 "$noreceipt_rc" 'a provider crash with no output artifact fails closed'
assert_eq yes "$( [[ -s $noreceipt_run/state/launch-attempted ]] && printf yes || printf no )" \
    'the launch-attempted marker survives a mid-send crash, proving a send was attempted'
assert_eq blocked "$(jq -r '.status' <"$noreceipt_run/adversarial.result.json")" \
    'a crash with no output never fabricates a completed result'
assert_not_contains "$(cat -- "$tmp/noreceipt.out")" 'verdict=findings' \
    'marker-present-no-receipt is never reported as a genuine completed review'

# -- issue #477: --reaffirm-if-covered short-circuits when the ledger already
#    proves this exact tree (or a base-merge-only advance of it) was reviewed

reaffirm_payload=$(/bin/bash "$consent" payload --worktree "$repo" --run-dir "$tmp" \
    --repo acme/widget --pr 42 --diff "$expected")

# review-ledger.sh only trusts a comment from a resolved author (root review
# finding F1); pin it deterministically instead of falling through to a live
# `gh api user` call (the fake_bin/gh stub below only understands the PR-
# metadata endpoint and would fail that call anyway).
export REVIEW_LEDGER_VIEWER='ledger-test-author'

make_ledger_comments() {
    # $1 = output path, $2 = reviews JSON array (compact)
    jq -n --argjson reviews "$2" --arg login "$REVIEW_LEDGER_VIEWER" \
        '[{id: 77, user: {login: $login}, body: ("<!-- review-ledger:v1 -->\n```json\n" +
            ({version:1, pr:42, repo:"acme/widget", reviews:$reviews} | tojson) +
            "\n```\n<!-- /review-ledger:v1 -->")}]' >"$1"
}

covered_reviews="[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"$head_oid\",\"diff_payload\":\"$reaffirm_payload\"}]"
covered_comments="$tmp/reaffirm-covered-comments.json"
make_ledger_comments "$covered_comments" "$covered_reviews"

reaffirm_run="$tmp/reaffirm-covered-run"
mkdir -- "$reaffirm_run" "$reaffirm_run/state"
chmod 700 "$reaffirm_run" "$reaffirm_run/state"
# Deliberately NO consent grant: a reaffirmed-from-ledger short circuit must
# never require (or consult) the consent gate, since no reviewer is launched.
reaffirm_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/reaffirm-covered.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$reaffirm_run" \
        --reaffirm-if-covered --comments "$covered_comments") \
    >"$tmp/reaffirm-covered.out" 2>"$tmp/reaffirm-covered.err" || reaffirm_rc=$?
assert_eq 0 "$reaffirm_rc" '--reaffirm-if-covered exits 0 for a covered-head ledger entry, with no consent grant'
assert_contains "$(cat -- "$tmp/reaffirm-covered.out")" 'reaffirmed-from-ledger' \
    'a reaffirmed run reports itself distinctly from a genuine completed review'
assert_eq no "$( [[ -e $tmp/reaffirm-covered.called ]] && printf yes || printf no )" \
    'a reaffirmed run never launches the reviewer CLI'
assert_eq no "$( [[ -e $reaffirm_run/adversarial.result.json ]] && printf yes || printf no )" \
    'a reaffirmed run never writes a result artifact of its own'

# The ledger comment append itself only round-trips through gh-comment.sh,
# which this test harness does not stub for adversarial-run.sh's own
# invocation -- review-ledger.sh append fails closed here (no gh on this PATH
# beyond the PR-metadata stub above). That failure is deliberately
# NON-FATAL to the reaffirm decision: the ORIGINAL ledger entry already
# proves coverage, so the review is still skipped even though the
# audit-trail append could not be recorded. Confirmed above by the covered
# run's rc=0 and no-reviewer-launch assertions; here confirm the warning was
# actually surfaced, not silently swallowed.
assert_contains "$(cat -- "$tmp/reaffirm-covered.err")" 'could not append a reaffirmed-from ledger entry' \
    'a failed audit-trail append is surfaced as a warning, not hidden'

covered_lineage_comments="$tmp/covered-lineage-comments.json"
make_ledger_comments "$covered_lineage_comments" \
    "[{\"kind\":\"adversarial\",\"provider\":\"anthropic\",\"head_sha\":\"0000000000000000000000000000000000000f\",\"covered_heads\":[\"$head_oid\"]}]"
assert_rc 0 'explicit mechanical coverage reaffirms without repurchasing a review' -- \
    env PATH="$fake_bin:$PATH" bash "$script" --worktree "$repo" --pr 42 --repo acme/widget \
    --run-dir "$tmp/covered-lineage-run" --reaffirm-if-covered --comments "$covered_lineage_comments"

# -- a malformed ledger fence (blocks, per rule 1) is never treated as
#    covered: the review always runs -------------------------------------

malformed_comments="$tmp/reaffirm-malformed-comments.json"
jq -n --arg login "$REVIEW_LEDGER_VIEWER" \
    '[{id: 78, user: {login: $login}, body: "<!-- review-ledger:v1 -->\n```json\n{not valid json\n```\n<!-- /review-ledger:v1 -->"}]' \
    >"$malformed_comments"

malformed_run="$tmp/reaffirm-malformed-run"
grant "$malformed_run" anthropic
malformed_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/reaffirm-malformed.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$malformed_run" \
        --reaffirm-if-covered --comments "$malformed_comments") \
    >"$tmp/reaffirm-malformed.out" 2>"$tmp/reaffirm-malformed.err" || malformed_rc=$?
assert_eq 1 "$malformed_rc" 'a malformed ledger blocks a potentially duplicate review'
assert_eq no "$( [[ -e $tmp/reaffirm-malformed.called ]] && printf yes || printf no )" \
    'a malformed ledger never launches the reviewer CLI'
assert_eq no "$( [[ -s $malformed_run/adversarial.result.json ]] && printf yes || printf no )" \
    'unavailable ledger evidence never produces a review result'

# -- a stale ledger (different head, no matching diff payload) never
#    short-circuits: the review always runs -----------------------------

stale_reviews='[{"kind":"adversarial","provider":"anthropic","head_sha":"0000000000000000000000000000000000000f","diff_payload":"acme/widget:42:zzzz"}]'
stale_comments="$tmp/reaffirm-stale-comments.json"
make_ledger_comments "$stale_comments" "$stale_reviews"

stale_run="$tmp/reaffirm-stale-run"
grant "$stale_run" anthropic
stale_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/reaffirm-stale.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$stale_run" \
        --reaffirm-if-covered --comments "$stale_comments") \
    >"$tmp/reaffirm-stale.out" 2>"$tmp/reaffirm-stale.err" || stale_rc=$?
assert_eq 1 "$stale_rc" 'a changed head never resets an existing remote review budget'
assert_eq no "$( [[ -e $tmp/reaffirm-stale.called ]] && printf yes || printf no )" \
    'a stale ledger entry requires reconciliation without another provider invocation'
assert_not_contains "$(cat -- "$tmp/reaffirm-stale.out")" 'reaffirmed-from-ledger' \
    'a stale ledger entry is never reported as a reaffirmed run'

# -- --reaffirm-if-covered requires --comments -------------------------------

usage_rc=0
bash "$script" --pr 42 --repo acme/widget --run-dir "$tmp/unused-run" \
    --reaffirm-if-covered >"$tmp/usage.out" 2>"$tmp/usage.err" || usage_rc=$?
assert_eq 2 "$usage_rc" '--reaffirm-if-covered without --comments is a usage error'
assert_contains "$(cat -- "$tmp/usage.err")" '--reaffirm-if-covered requires --comments' \
    'the usage error names the missing flag'

# --- #473 follow-up (F1, PR #479 adversarial review): a RUN_DIR whose
# launch-attempted marker is already present with no terminal (completed or
# blocked) result must refuse to relaunch, even with fully valid consent --
# that combination means a prior attempt may have already sent the diff and
# lost its receipt, so relaunching would risk a second, silent disclosure.
# The guard must fire before the provider helper is ever invoked and must
# never touch the pre-existing marker bytes.
prior_launch_run="$tmp/prior-launch-run"
grant "$prior_launch_run" anthropic
printf '%s' '{"timestamp":"2020-01-01T00:00:00Z","pr":42,"head":"deadbeef","payload":"stale"}' \
    >"$prior_launch_run/state/launch-attempted"
chmod 600 -- "$prior_launch_run/state/launch-attempted"
prior_launch_marker_before=$(sha256sum -- "$prior_launch_run/state/launch-attempted" | awk '{print $1}')
prior_launch_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/prior-launch.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$prior_launch_run") \
    >"$tmp/prior-launch.out" 2>"$tmp/prior-launch.err" || prior_launch_rc=$?
assert_eq 1 "$prior_launch_rc" \
    'a marker with no terminal result refuses a second launch even with valid consent'
assert_eq no "$( [[ -e $tmp/prior-launch.called ]] && printf yes || printf no )" \
    'the guard fires before the provider helper is ever invoked'
prior_launch_marker_after=$(sha256sum -- "$prior_launch_run/state/launch-attempted" | awk '{print $1}')
assert_eq "$prior_launch_marker_before" "$prior_launch_marker_after" \
    'the guard never overwrites the pre-existing launch-attempted marker'
assert_eq blocked "$(jq -r '.status' <"$prior_launch_run/adversarial.result.json")" \
    'the guard publishes a blocked result rather than relaunching'
assert_contains "$(jq -r '.blockedReason' <"$prior_launch_run/adversarial.result.json")" \
    'prior-launch' \
    'the blocked reason names the ambiguous prior-launch state'
assert_contains "$(cat -- "$tmp/prior-launch.out")" 'verdict=blocked' \
    'a marker with no terminal result is never reported as a completed review'

# The complementary case: a marker alongside an already-VALID completed
legacy_run="$tmp/legacy-completed"
grant "$legacy_run" anthropic
cp "$claude_run/state/launch-attempted" "$legacy_run/state/launch-attempted"
jq 'del(.attemptId, .launcher)' "$claude_run/adversarial.result.json" >"$legacy_run/adversarial.result.json"
legacy_bytes=$(sha256sum "$legacy_run/adversarial.result.json" | cut -d' ' -f1)
legacy_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    ATTEMPT_RECOVERING=1 FAKE_CLAUDE_CALLED="$tmp/legacy.calls" bash "$script" --pr 42 --repo acme/widget --run-dir "$legacy_run") \
    >"$tmp/legacy.out" 2>"$tmp/legacy.err" || legacy_rc=$?
assert_eq 1 "$legacy_rc" 'legacy completed review requires explicit evidence reconciliation'
assert_eq "$legacy_bytes" "$(sha256sum "$legacy_run/adversarial.result.json" | cut -d' ' -f1)" \
    'legacy completed result is preserved byte-for-byte'
assert_contains "$(cat "$tmp/legacy.err")" 'legacy' 'legacy refusal names the preserved evidence'
assert_eq no "$([[ -e $tmp/legacy.calls ]] && printf yes || printf no)" 'legacy completion never triggers a replacement review'

# The complementary case: a marker alongside an already-VALID completed
# result is left to the existing (unchanged) findings-ledger/result-clearing
# flow -- the new guard must not add a fresh refusal there. Reuses the
# already-completed claude_run RUN_DIR from earlier in this suite, which has
# both launch-attempted and a valid completed result on disk.
assert_eq yes "$( [[ -s $claude_run/state/launch-attempted ]] && printf yes || printf no )" \
    'sanity: the completed claude_run fixture still carries its marker'
terminal_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/terminal-reuse.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$claude_run") \
    >"$tmp/terminal-reuse.out" 2>"$tmp/terminal-reuse.err" || terminal_rc=$?
assert_eq 1 "$terminal_rc" \
    'a result whose original durable reservation was removed requires reconciliation'
assert_eq no "$( [[ -e $tmp/terminal-reuse.called ]] && printf yes || printf no )" \
    'a missing reservation never authorizes repurchasing an old completed review'

# --- #473 follow-up (F2, PR #479 adversarial review): the launch-attempted
# marker must only be written after every local output-path preparation
# succeeds, so a purely local abort (e.g. a hostile pre-existing artifact
# target) never leaves behind a marker that falsely claims a possible send.
# anthropic.stdout is prepared inside run_provider itself (unlike
# adversarial.result.json, which main() already validates earlier), so a
# symlink planted there is only ever caught at that later, run_provider-local
# preparation step -- exactly the ordering this fix pins down.
local_abort_run="$tmp/local-abort-run"
grant "$local_abort_run" anthropic
ln -s /etc/passwd "$local_abort_run/anthropic.stdout"
local_abort_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/local-abort.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$local_abort_run") \
    >"$tmp/local-abort.out" 2>"$tmp/local-abort.err" || local_abort_rc=$?
assert_eq 1 "$local_abort_rc" 'a hostile local output target aborts before any send'
assert_contains "$(cat -- "$tmp/local-abort.err")" 'refusing to use an artifact symlink' \
    'the local abort names the unsafe artifact'
assert_eq no "$( [[ -e $tmp/local-abort.called ]] && printf yes || printf no )" \
    'a purely local abort never reaches the provider helper'
assert_eq no "$( [[ -e $local_abort_run/state/launch-attempted ]] && printf yes || printf no )" \
    'a purely local abort never writes the launch-attempted marker'

# --- issue #477 x #473 follow-up: the reaffirm short-circuit must win over
# an ambiguous prior-launch marker, not be blocked by it. A RUN_DIR carrying
# exactly the same "marker present, no terminal result" ambiguity as the F1
# case above, but where the ledger ALSO proves this exact head was already
# reviewed, must still reaffirm and skip -- the durable ledger's coverage
# guarantee does not depend on this RUN_DIR's own local launch history, and
# guard_prior_launch_attempt must never even run for a reaffirmed request.
reaffirm_over_guard_run="$tmp/reaffirm-over-guard-run"
mkdir -- "$reaffirm_over_guard_run" "$reaffirm_over_guard_run/state"
chmod 700 "$reaffirm_over_guard_run" "$reaffirm_over_guard_run/state"
printf '%s' '{"timestamp":"2020-01-01T00:00:00Z","pr":42,"head":"deadbeef","payload":"stale"}' \
    >"$reaffirm_over_guard_run/state/launch-attempted"
chmod 600 -- "$reaffirm_over_guard_run/state/launch-attempted"
reaffirm_over_guard_marker_before=$(sha256sum -- "$reaffirm_over_guard_run/state/launch-attempted" | awk '{print $1}')
reaffirm_over_guard_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/reaffirm-over-guard.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$reaffirm_over_guard_run" \
        --reaffirm-if-covered --comments "$covered_comments") \
    >"$tmp/reaffirm-over-guard.out" 2>"$tmp/reaffirm-over-guard.err" || reaffirm_over_guard_rc=$?
assert_eq 0 "$reaffirm_over_guard_rc" \
    'a covered-head ledger entry reaffirms successfully even with an ambiguous prior-launch marker present'
assert_contains "$(cat -- "$tmp/reaffirm-over-guard.out")" 'reaffirmed-from-ledger' \
    'the reaffirm short-circuit reports itself, not a guard block'
assert_eq no "$( [[ -e $tmp/reaffirm-over-guard.called ]] && printf yes || printf no )" \
    'the reaffirm short-circuit never launches the reviewer CLI, guard notwithstanding'
assert_eq no "$( [[ -e $reaffirm_over_guard_run/adversarial.result.json ]] && printf yes || printf no )" \
    'the reaffirm short-circuit never writes a blocked result from the guard'
reaffirm_over_guard_marker_after=$(sha256sum -- "$reaffirm_over_guard_run/state/launch-attempted" | awk '{print $1}')
assert_eq "$reaffirm_over_guard_marker_before" "$reaffirm_over_guard_marker_after" \
    'the reaffirm short-circuit never touches the pre-existing (ambiguous) launch-attempted marker'

# --- CodeRabbit review of PR #484 (issue #477 T1): try_reaffirm_if_covered's
# `status` call already passed --repo-root, but its `read` and `append`
# calls did not -- so resolve_trusted_author inside THOSE calls could never
# see a repository-declared AGENT_LEDGER_AUTHOR and silently fell back to
# REVIEW_LEDGER_VIEWER/gh instead. A ledger comment authored by the
# CONFIGURED author (not REVIEW_LEDGER_VIEWER, which stays exported to a
# different value for the whole suite) proves `read` now resolves the same
# configured identity `status` already did: pre-fix, `read` would have found
# nothing under REVIEW_LEDGER_VIEWER's identity, `try_reaffirm_if_covered`
# would have returned 1, and this run would have fallen back to a genuine
# (CLI-launching) review instead of reaffirming.
configured_author='configured-ledger-author'
printf 'AGENT_LEDGER_AUTHOR=%s\n' "$configured_author" >"$repo/.agent/config.env"

configured_author_comments="$tmp/reaffirm-configured-author-comments.json"
jq -n --argjson reviews "$covered_reviews" --arg login "$configured_author" \
    '[{id: 91, user: {login: $login}, body: ("<!-- review-ledger:v1 -->\n```json\n" +
        ({version:1, pr:42, repo:"acme/widget", reviews:$reviews} | tojson) +
        "\n```\n<!-- /review-ledger:v1 -->")}]' >"$configured_author_comments"

configured_author_run="$tmp/reaffirm-configured-author-run"
mkdir -- "$configured_author_run" "$configured_author_run/state"
chmod 700 "$configured_author_run" "$configured_author_run/state"
configured_author_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/reaffirm-configured-author.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$configured_author_run" \
        --reaffirm-if-covered --comments "$configured_author_comments") \
    >"$tmp/reaffirm-configured-author.out" 2>"$tmp/reaffirm-configured-author.err" || configured_author_rc=$?
assert_eq 0 "$configured_author_rc" \
    'a repository-declared AGENT_LEDGER_AUTHOR resolves through the read call too (CodeRabbit #484 T1), not just status'
assert_contains "$(cat -- "$tmp/reaffirm-configured-author.out")" 'reaffirmed-from-ledger' \
    'the reaffirm short-circuit succeeds via the config-resolved author, proving read found the trusted comment'
assert_eq no "$( [[ -e $tmp/reaffirm-configured-author.called ]] && printf yes || printf no )" \
    'a config-resolved reaffirm still never launches the reviewer CLI'

rm -f -- "$repo/.agent/config.env"

# --- #473 follow-up (T1, PR #479 CodeRabbit): --provenance carries the
# launch-authorization text as one argv element -- never eval'd, never
# re-parsed -- so a value containing a single quote, a $(...) or `...`
# command substitution, and a ';' statement separator must all land as inert
# bytes, never execute, and never suppress the launcher.
provenance_hazard_run="$tmp/provenance-hazard-run"
grant "$provenance_hazard_run" anthropic
hazard_marker_dollar="$tmp/should-not-exist-dollar"
hazard_marker_backtick="$tmp/should-not-exist-backtick"
hazard_marker_semi="$tmp/should-not-exist-semi"
provenance_hazard="RUN_ID=r1; consent=granted; invocation='review PR #283' \$(touch $hazard_marker_dollar) \`touch $hazard_marker_backtick\` ; touch $hazard_marker_semi"
provenance_hazard_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$provenance_hazard_run" \
        --provenance "$provenance_hazard") \
    >"$tmp/provenance-hazard.out" 2>"$tmp/provenance-hazard.err" || provenance_hazard_rc=$?
assert_eq 0 "$provenance_hazard_rc" \
    'a provenance value with shell metacharacters still completes a normal review'
assert_contains "$(cat -- "$tmp/provenance-hazard.out")" 'verdict=findings' \
    'the hazardous-provenance launch completes a genuine review, not a silent no-op'
assert_eq "$provenance_hazard" "$(cat -- "$provenance_hazard_run/state/provenance")" \
    'the provenance record holds the value byte-for-byte, unmodified'
assert_eq 600 "$(stat -c %a "$provenance_hazard_run/state/provenance")" \
    'the provenance record is owner-private'
assert_contains "$(cat -- "$tmp/provenance-hazard.err")" "provenance: $provenance_hazard" \
    'the provenance value is echoed to stderr with its prefix'
assert_eq no "$( [[ -e $hazard_marker_dollar ]] && printf yes || printf no )" \
    'a dollar-paren command substitution inside the provenance value is never executed'
assert_eq no "$( [[ -e $hazard_marker_backtick ]] && printf yes || printf no )" \
    'a backtick command substitution inside the provenance value is never executed'
assert_eq no "$( [[ -e $hazard_marker_semi ]] && printf yes || printf no )" \
    'a statement after a semicolon inside the provenance value is never executed'

# --- #473 follow-up (T2, PR #479 CodeRabbit): two concurrent invocations
# sharing a RUN_DIR must not both proceed -- the second must refuse outright
# rather than race the first to a possible double send. Simulated here by
# holding the same exclusive flock the script itself takes, from this test
# process, before invoking the script.
lock_run="$tmp/lock-run"
grant "$lock_run" anthropic
lock_file="$lock_run/state/.launch.lock"
: >"$lock_file"
chmod 600 -- "$lock_file"
exec {TEST_LOCK_FD}>"$lock_file"
flock -n "$TEST_LOCK_FD" || {
    printf 'test setup failed to take the run lock\n' >&2
    exit 1
}
lock_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/lock.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$lock_run") \
    >"$tmp/lock.out" 2>"$tmp/lock.err" || lock_rc=$?
exec {TEST_LOCK_FD}>&-
assert_eq 1 "$lock_rc" 'a concurrently held run lock refuses this invocation'
assert_contains "$(cat -- "$tmp/lock.err")" 'holds the launch lock' \
    'the lock refusal names the concurrency conflict'
assert_eq no "$( [[ -e $tmp/lock.called ]] && printf yes || printf no )" \
    'the lock refusal never invokes the provider helper'
assert_eq no "$( [[ -e $lock_run/state/launch-attempted ]] && printf yes || printf no )" \
    'the lock refusal never writes the launch-attempted marker'
assert_eq no "$( [[ -e $lock_run/adversarial.result.json ]] && printf yes || printf no )" \
    'the lock refusal never writes a result; the lock holder owns that file'

# A tracked `.agent` symlink bypasses leaf-only provenance checks: Git tracks
# the link itself, not the resolved `.agent/env-contract.txt` path. The runner
# must reject it before consulting attacker-controlled reviewer facts or
# invoking the external reviewer CLI.
rm -rf -- "$repo/.agent"
mkdir -- "$repo/contract-redirect"
ln -s contract-redirect "$repo/.agent"
write_contract codex claude "present path=$tmp/fake-claude"
git -C "$repo" add -- .agent contract-redirect/env-contract.txt
git -C "$repo" commit --quiet -m 'test: track redirected environment contract'
FAKE_HEAD_OID=$(git -C "$repo" rev-parse HEAD)
export FAKE_HEAD_OID
redirect_expected="$tmp/redirect.expected.diff"
git -C "$repo" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$redirect_expected"
redirect_run="$tmp/tracked-parent-symlink-run"
grant "$redirect_run" anthropic "$redirect_expected"
redirect_rc=0
(cd "$repo" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    FAKE_CLAUDE_CALLED="$tmp/tracked-parent-symlink.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$redirect_run") \
    >"$tmp/tracked-parent-symlink.out" 2>"$tmp/tracked-parent-symlink.err" || redirect_rc=$?
assert_eq 1 "$redirect_rc" 'tracked environment-contract parent symlink is rejected'
assert_contains "$(cat -- "$tmp/tracked-parent-symlink.err")" \
    'environment contract directory is a symlink' \
    'tracked parent symlink names the provenance violation'
assert_eq no "$( [[ -e $tmp/tracked-parent-symlink.called ]] && printf yes || printf no )" \
    'tracked parent symlink never launches the reviewer CLI'

# --- roster form: AGENT_ADVERSARIAL_REVIEWER/_FALLBACK carry a
# `<model-id>-<effort>` compound; the running-harness's own claude entry is
# skipped in favor of the cross-harness codex entry -------------------------
repo_roster=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=claude-opus-5-high
AGENT_ADVERSARIAL_REVIEWER_FALLBACK=gpt-5.6-sol-xhigh')
write_contract_at "$repo_roster" claude codex "present path=$tmp/fake-codex"
git -C "$repo_roster" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster/example.txt"
git -C "$repo_roster" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster="$tmp/repo-roster.diff"
git -C "$repo_roster" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster"
roster_run="$tmp/roster-run"
grant "$roster_run" openai "$diff_roster"
roster_rc=0
(cd "$repo_roster" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_run") \
    >"$tmp/roster.out" 2>"$tmp/roster.err" || roster_rc=$?
assert_eq 0 "$roster_rc" 'a roster-declared reviewer completes'
assert_contains "$(cat -- "$tmp/roster.out")" 'provider=openai' \
    'the roster picks the codex candidate, not the running-harness claude one'
assert_contains "$(cat -- "$tmp/roster.out")" 'model=gpt-5.6-sol' \
    'the roster carries its own model id, not a hardcoded default'
assert_contains "$(cat -- "$tmp/roster.out")" 'effort=xhigh' \
    'the roster carries its own effort'
assert_contains "$(cat -- "$tmp/roster.out")" 'mode=cross-provider' \
    'the cross-harness roster candidate is reported as cross-provider'

# --- roster form, peer absent: falls back to the running-harness entry -----
repo_roster_absent=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gpt-5.6-sol-xhigh
AGENT_ADVERSARIAL_REVIEWER_FALLBACK=claude-opus-5-medium')
write_contract_at "$repo_roster_absent" claude codex 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
git -C "$repo_roster_absent" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_absent/example.txt"
git -C "$repo_roster_absent" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_absent" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_absent="$tmp/repo-roster-absent.diff"
git -C "$repo_roster_absent" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_absent"
roster_absent_run="$tmp/roster-absent-run"
grant "$roster_absent_run" anthropic "$diff_roster_absent"
roster_absent_rc=0
(cd "$repo_roster_absent" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_absent_run") \
    >"$tmp/roster-absent.out" 2>"$tmp/roster-absent.err" || roster_absent_rc=$?
assert_eq 0 "$roster_absent_rc" 'a roster-declared reviewer whose peer is absent still completes via the pool fallback'
assert_contains "$(cat -- "$tmp/roster-absent.out")" 'provider=anthropic' \
    'the roster falls back to the running-harness candidate already in the pool'
assert_contains "$(cat -- "$tmp/roster-absent.out")" 'model=claude-opus-5' \
    "the running-harness candidate's own roster model is used, not the hardcoded default"
assert_contains "$(cat -- "$tmp/roster-absent.out")" 'effort=medium' \
    "the running-harness candidate's own roster effort is used"
assert_contains "$(cat -- "$tmp/roster-absent.out")" 'mode=blind-fallback' \
    'a same-harness roster fallback is reported as blind-fallback, never cross-provider'

# --- roster form, gpt-6-* id: the family glob covers gpt-6-* too, not just
# gpt-5.6-* (issue #606) -----------------------------------------------------
repo_roster_gpt6=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gpt-6-astra-xhigh')
write_contract_at "$repo_roster_gpt6" claude codex "present path=$tmp/fake-codex"
git -C "$repo_roster_gpt6" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_gpt6/example.txt"
git -C "$repo_roster_gpt6" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_gpt6" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_gpt6="$tmp/repo-roster-gpt6.diff"
git -C "$repo_roster_gpt6" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_gpt6"
roster_gpt6_run="$tmp/roster-gpt6-run"
grant "$roster_gpt6_run" openai "$diff_roster_gpt6"
roster_gpt6_rc=0
(cd "$repo_roster_gpt6" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_gpt6_run") \
    >"$tmp/roster-gpt6.out" 2>"$tmp/roster-gpt6.err" || roster_gpt6_rc=$?
assert_eq 0 "$roster_gpt6_rc" 'a roster gpt-6-* reviewer entry resolves to the codex family and completes'
assert_contains "$(cat -- "$tmp/roster-gpt6.out")" 'model=gpt-6-astra' \
    'the family predicate recognizes gpt-6-* the same as gpt-5.6-*'

# --- roster form, unrecognized model family: repo-config.sh's validators
# (issue #606) now refuse this at parse time -- the declaration never reaches
# adversarial-run.sh at all, so this behaves exactly like no declaration:
# adversarial-run.sh discards repo-config's stderr at :221 (2>/dev/null), so
# the refusal is pinned on --validate directly, never on the run's stderr.
repo_roster_unknown=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=some-other-provider-high')
write_contract_at "$repo_roster_unknown" codex claude "present path=$tmp/fake-claude"
git -C "$repo_roster_unknown" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_unknown/example.txt"
git -C "$repo_roster_unknown" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_unknown" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_unknown="$tmp/repo-roster-unknown.diff"
git -C "$repo_roster_unknown" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_unknown"
roster_unknown_run="$tmp/roster-unknown-run"
grant "$roster_unknown_run" anthropic "$diff_roster_unknown"
roster_unknown_rc=0
(cd "$repo_roster_unknown" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_CODEX_CALLED="$tmp/roster-unknown-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_unknown_run") \
    >"$tmp/roster-unknown.out" 2>"$tmp/roster-unknown.err" || roster_unknown_rc=$?
assert_eq 0 "$roster_unknown_rc" 'a roster compound in neither known family is dropped and the pinned defaults complete'
roster_unknown_validate_rc=0
roster_unknown_validate=$("$root/agentkit/skills/.shared/scripts/repo-config.sh" --repo-root "$repo_roster_unknown" --validate 2>&1) || roster_unknown_validate_rc=$?
assert_eq 1 "$roster_unknown_validate_rc" 'repo-config.sh --validate refuses a roster compound in neither known family'
assert_contains "$roster_unknown_validate" 'invalid value for AGENT_ADVERSARIAL_REVIEWER on line 1, ignoring -- accepted:' \
    'the refusal names the key and the accepted set (repo-config.sh drops it before adversarial-run.sh ever sees it)'
assert_not_contains "$(cat -- "$tmp/roster-unknown.err")" 'unrecognized model family' \
    'adversarial-run.sh itself says nothing about a value repo-config.sh already dropped'
assert_contains "$(cat -- "$tmp/roster-unknown.out")" 'provider=anthropic model=claude-opus-5' \
    'the run lands on the pinned cross-provider default, not on a guessed family'
assert_eq no "$( [[ -e $tmp/roster-unknown-codex.called ]] && printf yes || printf no )" \
    'an unrecognized family never silently launches codex'

# --- issue #609: exclusions are computed from base-declared
# AGENT_GENERATED_PATHS plus the built-in vendored trees, and receipted with
# a checksum of what was excluded. The fixture's grant must hash the same
# bytes the script will render -- the excluded canonical render, with the
# same four pathspecs build_diff uses -- or compute_payload's own consent
# check refuses the supplied diff before any of the assertions below run.
repo_excl=$(make_trust_repo 'AGENT_GENERATED_PATHS=generated')
write_contract_at "$repo_excl" claude codex "present path=$tmp/fake-codex"
git -C "$repo_excl" switch --quiet -c feature
mkdir -p -- "$repo_excl/generated" "$repo_excl/vendor"
printf '%s\n' changed >"$repo_excl/example.txt"
printf '%s\n' generated >"$repo_excl/generated/big.txt"
printf '%s\n' vendored >"$repo_excl/vendor/lib.c"
git -C "$repo_excl" add example.txt generated/big.txt vendor/lib.c
git -C "$repo_excl" commit --quiet -m 'change with generated and vendored files'
FAKE_HEAD_OID=$(git -C "$repo_excl" rev-parse HEAD)
export FAKE_HEAD_OID
diff_excl="$tmp/repo-excl.diff"
git -C "$repo_excl" --no-pager diff --find-renames --unified=25 origin/main...HEAD \
    -- ':/' ':(exclude,top)vendor' ':(exclude,top)third_party' ':(exclude,top)node_modules' ':(exclude,top)generated' \
    >"$diff_excl"
excl_run="$tmp/excl-run"
grant "$excl_run" openai "$diff_excl"
excl_rc=0
(cd "$repo_excl" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$excl_run") \
    >"$tmp/excl.out" 2>"$tmp/excl.err" || excl_rc=$?
assert_eq 0 "$excl_rc" 'a run with declared and built-in exclusions completes'
assert_contains "$(cat -- "$tmp/excl.out")" 'exclusions=4' \
    'the receipt counts 3 built-in exclusions plus 1 declared'
excl_sha256=$(sed -n 's/.*excluded_sha256=\([0-9a-f]*\).*/\1/p' "$tmp/excl.out")
assert_eq 64 "${#excl_sha256}" 'the receipt carries a 64-hex checksum of the excluded diff'
assert_contains "$(cat -- "$excl_run/adversarial.diff")" 'example.txt' \
    'the reviewed diff still contains the non-excluded file'
assert_not_contains "$(cat -- "$excl_run/adversarial.diff")" 'generated/big.txt' \
    'the reviewed diff excludes the declared generated path'
assert_not_contains "$(cat -- "$excl_run/adversarial.diff")" 'vendor/lib.c' \
    'the reviewed diff excludes the built-in vendored path'
assert_eq "$(printf ':(exclude,top)vendor\n:(exclude,top)third_party\n:(exclude,top)node_modules\n:(exclude,top)generated')" \
    "$(cat -- "$excl_run/adversarial.exclusions")" \
    'adversarial.exclusions lists the built-ins and the declared path in order'
assert_eq yes "$( [[ -f $excl_run/adversarial.excluded.diff ]] && printf yes || printf no )" \
    'adversarial.excluded.diff is published'
assert_eq 600 "$(stat -c %a -- "$excl_run/adversarial.excluded.diff")" \
    'adversarial.excluded.diff is mode 0600'
assert_contains "$(cat -- "$excl_run/adversarial.excluded.diff")" 'generated/big.txt' \
    'the excluded diff documents the declared exclusion'
assert_contains "$(cat -- "$excl_run/adversarial.excluded.diff")" 'vendor/lib.c' \
    'the excluded diff documents the built-in exclusion'

# --- tamper case: the reviewed diff itself edits .agent/config.env, trying to
# widen AGENT_GENERATED_PATHS to hide example.txt. Exclusions are rendered from
# the BASE revision only, so the tamper has no effect on what is excluded --
# the diff still contains example.txt and the config edit itself.
repo_tamper=$(make_trust_repo 'AGENT_GENERATED_PATHS=generated')
write_contract_at "$repo_tamper" claude codex "present path=$tmp/fake-codex"
git -C "$repo_tamper" switch --quiet -c feature
printf '%s\n' changed >"$repo_tamper/example.txt"
printf 'AGENT_GENERATED_PATHS=example.txt\n' >"$repo_tamper/.agent/config.env"
git -C "$repo_tamper" commit --quiet -am 'change including config.env'
FAKE_HEAD_OID=$(git -C "$repo_tamper" rev-parse HEAD)
export FAKE_HEAD_OID
diff_tamper="$tmp/repo-tamper.diff"
git -C "$repo_tamper" --no-pager diff --find-renames --unified=25 origin/main...HEAD \
    -- ':/' ':(exclude,top)vendor' ':(exclude,top)third_party' ':(exclude,top)node_modules' ':(exclude,top)generated' \
    >"$diff_tamper"
tamper_run="$tmp/tamper-run"
grant "$tamper_run" openai "$diff_tamper"
tamper_rc=0
(cd "$repo_tamper" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$tamper_run") \
    >"$tmp/tamper.out" 2>"$tmp/tamper.err" || tamper_rc=$?
assert_eq 0 "$tamper_rc" 'a reviewed diff that edits config.env to widen exclusions still completes'
tamper_err=$(cat -- "$tmp/tamper.err")
assert_contains "$tamper_err" 'the reviewed diff changes .agent/config.env' \
    'the tamper attempt is announced on stderr, same as the existing config-touch guard'
assert_contains "$(cat -- "$tamper_run/adversarial.diff")" 'example.txt' \
    'the base-revision exclusion list wins: example.txt is not hidden by the tampered declaration'
assert_contains "$(cat -- "$tamper_run/adversarial.diff")" '.agent/config.env' \
    'the config.env edit itself is visible in the reviewed diff'

# --- issue #609: a payload estimated over the token limit is refused before
# any consent check or provider launch -- fake-codex now records a call
# marker (added above at :85) so "never launched" is provable, not assumed.
repo_gate=$(make_trust_repo '')
write_contract_at "$repo_gate" claude codex "present path=$tmp/fake-codex"
git -C "$repo_gate" switch --quiet -c feature
printf '%s\n' changed >"$repo_gate/example.txt"
git -C "$repo_gate" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_gate" rev-parse HEAD)
export FAKE_HEAD_OID
diff_gate="$tmp/repo-gate.diff"
git -C "$repo_gate" --no-pager diff --find-renames --unified=25 origin/main...HEAD \
    -- ':/' ':(exclude,top)vendor' ':(exclude,top)third_party' ':(exclude,top)node_modules' \
    >"$diff_gate"

gate_run="$tmp/gate-run"
grant "$gate_run" openai "$diff_gate"
gate_consent_before=$(cat -- "$gate_run/state/cross-provider-consent")
gate_rc=0
(cd "$repo_gate" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    ADVERSARIAL_PAYLOAD_TOKEN_LIMIT=10 FAKE_CODEX_CALLED="$tmp/gate-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$gate_run") \
    >"$tmp/gate.out" 2>"$tmp/gate.err" || gate_rc=$?
assert_eq 1 "$gate_rc" 'a payload over the token limit blocks with a non-zero exit'
assert_eq no "$( [[ -e $tmp/gate-codex.called ]] && printf yes || printf no )" \
    'the oversized payload never invokes the provider helper'
assert_eq no "$( [[ -e $gate_run/state/launch-attempted ]] && printf yes || printf no )" \
    'the oversized payload never writes the launch-attempted marker'
assert_eq "$gate_consent_before" "$(cat -- "$gate_run/state/cross-provider-consent")" \
    'the oversized payload leaves the consent record untouched -- no check was ever run against it'
gate_payload_size=$(cat -- "$gate_run/adversarial.payload-size")
assert_eq yes "$( [[ $gate_payload_size =~ ^payload=too-large\ estimate=[1-9][0-9]*\ limit=10\ diff=[0-9]+\ overhead=202\ reserve=50000$ ]] && printf yes || printf no )" \
    'adversarial.payload-size names the too-large verdict, a positive estimate (diff + helper overhead + output/reasoning reserve), and the limit'
assert_eq blocked "$(jq -r '.status' -- "$gate_run/adversarial.result.json")" \
    'the blocked result status is blocked'
assert_eq payload-too-large "$(jq -r '.blockedReason' -- "$gate_run/adversarial.result.json")" \
    'the blocked result names the payload-too-large reason'
assert_contains "$(cat -- "$tmp/gate.out")" 'verdict=blocked' \
    'the receipt reports a blocked verdict'

gate_ok_run="$tmp/gate-ok-run"
grant "$gate_ok_run" openai "$diff_gate"
gate_ok_rc=0
(cd "$repo_gate" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    FAKE_CODEX_CALLED="$tmp/gate-ok-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$gate_ok_run") \
    >"$tmp/gate-ok.out" 2>"$tmp/gate-ok.err" || gate_ok_rc=$?
assert_eq 0 "$gate_ok_rc" 'without a token-limit override the same run completes normally'
assert_eq yes "$( [[ -e $tmp/gate-ok-codex.called ]] && printf yes || printf no )" \
    'an in-budget payload still launches the provider helper'
gate_ok_payload_size=$(cat -- "$gate_ok_run/adversarial.payload-size")
assert_eq yes "$( [[ $gate_ok_payload_size =~ ^payload=ok\ estimate=[0-9]+\ limit=400000\ diff=[0-9]+\ overhead=202\ reserve=50000$ ]] && printf yes || printf no )" \
    'adversarial.payload-size reports ok against the default 400000-token limit (the codex helper max-tokens cap), estimate includes diff + helper overhead + output/reasoning reserve'

# --- issue #609 fix round 3: the size gate must count the Codex helper's own
# fixed prompt overhead (ADVERSARIAL_PROMPT_OVERHEAD_TOKENS), not just the
# diff bytes -- a diff that is comfortably under the limit by itself must
# still be refused once that overhead pushes the real payload over it. The
# limit is derived from the diff's own estimate plus a 100-token margin
# (< the 202-token overhead), so the diff alone would pass but the combined
# estimate cannot.
overhead_diff_bytes=$(wc -c <"$diff_gate")
overhead_diff_estimate=$(( overhead_diff_bytes * 2 / 7 ))
overhead_limit=$(( overhead_diff_estimate + 100 ))
overhead_run="$tmp/overhead-run"
grant "$overhead_run" openai "$diff_gate"
overhead_rc=0
(cd "$repo_gate" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    ADVERSARIAL_PAYLOAD_TOKEN_LIMIT="$overhead_limit" FAKE_CODEX_CALLED="$tmp/overhead-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$overhead_run") \
    >"$tmp/overhead.out" 2>"$tmp/overhead.err" || overhead_rc=$?
assert_eq 1 "$overhead_rc" \
    'a diff that fits the limit alone is still refused once the helper overhead pushes the real payload over it'
assert_eq no "$( [[ -e $tmp/overhead-codex.called ]] && printf yes || printf no )" \
    'the overhead-driven refusal never invokes the provider helper'
overhead_payload_size=$(cat -- "$overhead_run/adversarial.payload-size")
assert_eq yes "$( [[ $overhead_payload_size =~ ^payload=too-large\ estimate=[0-9]+\ limit=$overhead_limit\ diff=$overhead_diff_estimate\ overhead=202\ reserve=50000$ ]] && printf yes || printf no )" \
    'the receipt shows the diff-only estimate under the limit and the combined estimate over it'

# --- issue #609 fix round 4: --max-tokens covers input+output+reasoning as
# ONE budget (ADVERSARIAL_OUTPUT_RESERVE_TOKENS), not just what is sent, so a
# diff that fits comfortably once the prompt overhead is added must still be
# refused once the output/reasoning reserve is added on top of that -- the
# limit here sits strictly between (diff + overhead) and
# (diff + overhead + reserve) so only the reserve term tips the verdict.
reserve_limit=$(( overhead_diff_estimate + 202 + 100 ))
reserve_run="$tmp/reserve-run"
grant "$reserve_run" openai "$diff_gate"
reserve_rc=0
(cd "$repo_gate" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    ADVERSARIAL_PAYLOAD_TOKEN_LIMIT="$reserve_limit" FAKE_CODEX_CALLED="$tmp/reserve-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$reserve_run") \
    >"$tmp/reserve.out" 2>"$tmp/reserve.err" || reserve_rc=$?
assert_eq 1 "$reserve_rc" \
    'a diff that passes with overhead only still fails once the output/reasoning reserve is added'
assert_eq no "$( [[ -e $tmp/reserve-codex.called ]] && printf yes || printf no )" \
    'the reserve-driven refusal never invokes the provider helper'
reserve_payload_size=$(cat -- "$reserve_run/adversarial.payload-size")
assert_eq yes "$( [[ $reserve_payload_size =~ ^payload=too-large\ estimate=[0-9]+\ limit=$reserve_limit\ diff=$overhead_diff_estimate\ overhead=202\ reserve=50000$ ]] && printf yes || printf no )" \
    'the receipt shows the reserve field alongside the too-large verdict'

# --- issue #609 fix round 4: ADVERSARIAL_OUTPUT_RESERVE_TOKENS is validated
# the same way ADVERSARIAL_PAYLOAD_TOKEN_LIMIT already is -- a non-numeric
# value dies immediately, before any diff is built, never mind launched.
reserve_bad_run="$tmp/reserve-bad-run"
grant "$reserve_bad_run" openai "$diff_gate"
reserve_bad_rc=0
(cd "$repo_gate" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    ADVERSARIAL_OUTPUT_RESERVE_TOKENS=notanumber FAKE_CODEX_CALLED="$tmp/reserve-bad-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$reserve_bad_run") \
    >"$tmp/reserve-bad.out" 2>"$tmp/reserve-bad.err" || reserve_bad_rc=$?
assert_eq 1 "$reserve_bad_rc" 'a non-numeric ADVERSARIAL_OUTPUT_RESERVE_TOKENS dies immediately'
assert_contains "$(cat -- "$tmp/reserve-bad.err")" 'ADVERSARIAL_OUTPUT_RESERVE_TOKENS must be a positive integer' \
    'the rejection names the positive-integer requirement'
assert_eq no "$( [[ -e $tmp/reserve-bad-codex.called ]] && printf yes || printf no )" \
    'the invalid reserve never invokes the provider helper'
assert_eq no "$( [[ -e $reserve_bad_run/adversarial.diff ]] && printf yes || printf no )" \
    'the invalid reserve is rejected before any diff is built'

# --- issue #609 fix round 1: ADVERSARIAL_PAYLOAD_TOKEN_LIMIT flows
# unvalidated into an arithmetic context (payload_size_gate's
# `(( estimate <= ADVERSARIAL_PAYLOAD_TOKEN_LIMIT ))`). Bash expands an array
# subscript's command substitution before the arithmetic evaluation itself,
# so a value like `estimate[$(cmd)]` -- naming a variable already in scope at
# that point -- executes `cmd` even under `set -u`. The limit must be
# validated as a plain positive integer before that context is ever reached,
# and the check runs at the top of the script, before any diff is built.
# A fresh repo -- never the shared $repo, whose .agent became a tracked
# symlink above (the "tracked environment-contract parent symlink" case) and
# stays that way for the rest of this file.
repo_inject=$(make_trust_repo '')
write_contract_at "$repo_inject" claude codex "present path=$tmp/fake-codex"
git -C "$repo_inject" switch --quiet -c feature
printf '%s\n' changed >"$repo_inject/example.txt"
git -C "$repo_inject" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_inject" rev-parse HEAD)
export FAKE_HEAD_OID
inject_marker="$tmp/inject.marker"
rm -f "$inject_marker"
inject_rc=0
(cd "$repo_inject" && PATH="$fake_bin:$PATH" \
    ADVERSARIAL_PAYLOAD_TOKEN_LIMIT="estimate[\$(touch $inject_marker)]" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$tmp/inject-run") \
    >"$tmp/inject.out" 2>"$tmp/inject.err" || inject_rc=$?
assert_eq 1 "$inject_rc" 'a non-numeric ADVERSARIAL_PAYLOAD_TOKEN_LIMIT dies immediately'
assert_contains "$(cat -- "$tmp/inject.err")" 'positive integer' \
    'the rejection names the positive-integer requirement'
assert_eq no "$( [[ -e $inject_marker ]] && printf yes || printf no )" \
    'the injected command substitution never executes'
assert_eq no "$( [[ -e $tmp/inject-run/adversarial.diff ]] && printf yes || printf no )" \
    'the rejection happens before any diff is built'

# 2026-09-09 issue #609 fix round 1: +16 (payload-paths wiring in
# compute_payload/verify_consent, plus the token-limit validation). Measured.
# 2026-09-09 issue #609 fix round 3: +14 (ADVERSARIAL_PROMPT_OVERHEAD_TOKENS
# constant plus payload_size_gate now accounting for the Codex helper's fixed
# prompt overhead, not just the diff bytes). Measured.
# 2026-09-09 issue #609 fix round 4: +28 (ADVERSARIAL_OUTPUT_RESERVE_TOKENS
# constant, its derivation comment, and payload_size_gate now accounting for
# the Codex helper's dynamic output+reasoning consumption, not just what is
# sent). Measured.
# Issue #705 adds six lines for keyed resolution and distinct absent diagnostics.
# Issue #706 adds selected-model provenance extraction and atomic result annotation.
assert_eq yes "$([[ $(wc -l < "$root/agentkit/skills/review-remote-pr/scripts/adversarial-run.sh") -le 1016 ]] && printf yes || printf no)" \
    'adversarial-run.sh stays at or under 1016 lines'
# --- roster form, OpenCode-family compound: repo-config.sh's model_family
# classifies a well-formed provider/model-id as opencode (a real, recognized
# family) rather than failing outright, so this needs its own case from the
# "some-other-provider-high" one above -- reviewer_roster_entry_valid must
# still refuse it, since adversarial-run.sh only ever launches codex or claude
# (CodeRabbit on #684) ---------------------------------------------------
repo_roster_opencode=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=claude-proxy/sonnet-high')
write_contract_at "$repo_roster_opencode" codex claude "present path=$tmp/fake-claude"
git -C "$repo_roster_opencode" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_opencode/example.txt"
git -C "$repo_roster_opencode" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_opencode" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_opencode="$tmp/repo-roster-opencode.diff"
git -C "$repo_roster_opencode" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_opencode"
roster_opencode_run="$tmp/roster-opencode-run"
grant "$roster_opencode_run" anthropic "$diff_roster_opencode"
roster_opencode_rc=0
(cd "$repo_roster_opencode" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    CLAUDE_EXECUTABLE="$tmp/fake-claude" FAKE_CODEX_CALLED="$tmp/roster-opencode-codex.called" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_opencode_run") \
    >"$tmp/roster-opencode.out" 2>"$tmp/roster-opencode.err" || roster_opencode_rc=$?
assert_eq 0 "$roster_opencode_rc" 'a roster OpenCode-family compound is dropped and the pinned defaults complete'
roster_opencode_validate_rc=0
roster_opencode_validate=$("$root/agentkit/skills/.shared/scripts/repo-config.sh" --repo-root "$repo_roster_opencode" --validate 2>&1) || roster_opencode_validate_rc=$?
assert_eq 1 "$roster_opencode_validate_rc" 'repo-config.sh --validate refuses an OpenCode-family reviewer compound'
assert_contains "$roster_opencode_validate" 'invalid value for AGENT_ADVERSARIAL_REVIEWER on line 1, ignoring -- accepted:' \
    'the refusal names the key and the accepted set, same as any other unlaunchable family'
assert_contains "$(cat -- "$tmp/roster-opencode.out")" 'provider=anthropic model=claude-opus-5' \
    'the run lands on the pinned cross-provider default, not on the OpenCode entry'
assert_eq no "$( [[ -e $tmp/roster-opencode-codex.called ]] && printf yes || printf no )" \
    'an OpenCode-family compound never silently launches codex'

# --- roster form, bare fallback CLI name: AGENT_ADVERSARIAL_REVIEWER_FALLBACK
# names a bare CLI (claude|codex) rather than a <model-id>-<effort> compound.
# reviewer_roster_parse only splits the compound form, so the fallback must be
# normalized into a family candidate before selection or it is silently
# dropped from cross-harness consideration entirely (issue #606 round 2: the
# running harness's own same-family primary would otherwise "review itself"
# even though a genuine cross-harness peer was declared).
repo_roster_bare_fallback=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gpt-6-astra-xhigh
AGENT_ADVERSARIAL_REVIEWER_FALLBACK=claude')
write_contract_at "$repo_roster_bare_fallback" codex claude "present path=$tmp/fake-claude"
git -C "$repo_roster_bare_fallback" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_bare_fallback/example.txt"
git -C "$repo_roster_bare_fallback" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_bare_fallback" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_bare_fallback="$tmp/repo-roster-bare-fallback.diff"
git -C "$repo_roster_bare_fallback" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_bare_fallback"
roster_bare_fallback_run="$tmp/roster-bare-fallback-run"
grant "$roster_bare_fallback_run" anthropic "$diff_roster_bare_fallback"
roster_bare_fallback_rc=0
(cd "$repo_roster_bare_fallback" && PATH="$fake_bin:$PATH" CLAUDE_EXECUTABLE="$tmp/fake-claude" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_bare_fallback_run") \
    >"$tmp/roster-bare-fallback.out" 2>"$tmp/roster-bare-fallback.err" || roster_bare_fallback_rc=$?
assert_eq 0 "$roster_bare_fallback_rc" 'a roster primary matching the running harness with a bare-CLI fallback completes'
assert_contains "$(cat -- "$tmp/roster-bare-fallback.out")" 'provider=anthropic' \
    'the bare claude fallback is selected over the same-harness codex primary'
assert_contains "$(cat -- "$tmp/roster-bare-fallback.out")" 'model=claude-opus-5' \
    "the bare fallback name has no model of its own, so claude's own harness default applies"
assert_contains "$(cat -- "$tmp/roster-bare-fallback.out")" 'effort=high' \
    "the bare fallback name has no effort of its own, so claude's own harness default applies"
assert_contains "$(cat -- "$tmp/roster-bare-fallback.out")" 'mode=cross-provider' \
    'a bare-CLI fallback that differs from the running harness is still a genuine cross-harness selection'

# --- roster form, bare fallback CLI name, peer absent: the same-harness
# primary is used after all, exactly like the pre-normalization behavior --
# normalizing the bare fallback must not regress the peer-absent path.
repo_roster_bare_fallback_absent=$(make_trust_repo 'AGENT_ADVERSARIAL_REVIEWER=gpt-6-astra-xhigh
AGENT_ADVERSARIAL_REVIEWER_FALLBACK=claude')
write_contract_at "$repo_roster_bare_fallback_absent" codex claude 'absent note="no cross-harness reviewer; use the same-harness blind fallback"'
git -C "$repo_roster_bare_fallback_absent" switch --quiet -c feature
printf '%s\n' changed >"$repo_roster_bare_fallback_absent/example.txt"
git -C "$repo_roster_bare_fallback_absent" commit --quiet -am change
FAKE_HEAD_OID=$(git -C "$repo_roster_bare_fallback_absent" rev-parse HEAD)
export FAKE_HEAD_OID
diff_roster_bare_fallback_absent="$tmp/repo-roster-bare-fallback-absent.diff"
git -C "$repo_roster_bare_fallback_absent" --no-pager diff --find-renames --unified=25 origin/main...HEAD >"$diff_roster_bare_fallback_absent"
roster_bare_fallback_absent_run="$tmp/roster-bare-fallback-absent-run"
grant "$roster_bare_fallback_absent_run" openai "$diff_roster_bare_fallback_absent"
roster_bare_fallback_absent_rc=0
(cd "$repo_roster_bare_fallback_absent" && PATH="$fake_bin:$PATH" CODEX_EXECUTABLE="$tmp/fake-codex" \
    bash "$script" --pr 42 --repo acme/widget --run-dir "$roster_bare_fallback_absent_run") \
    >"$tmp/roster-bare-fallback-absent.out" 2>"$tmp/roster-bare-fallback-absent.err" || roster_bare_fallback_absent_rc=$?
assert_eq 0 "$roster_bare_fallback_absent_rc" 'a bare-CLI fallback whose family is also absent still completes via the same-harness primary'
assert_contains "$(cat -- "$tmp/roster-bare-fallback-absent.out")" 'provider=openai' \
    'with the peer absent, the same-harness codex primary is used'
assert_contains "$(cat -- "$tmp/roster-bare-fallback-absent.out")" 'model=gpt-6-astra' \
    "the primary's own roster model is used, not a guessed default"
assert_contains "$(cat -- "$tmp/roster-bare-fallback-absent.out")" 'mode=blind-fallback' \
    'a same-harness roster primary with an unreachable fallback is reported as blind-fallback'

# 2026-09-08 size wave two: hold the helper at its measured line count.
# 2026-09-09 fix round 2: normalize a bare fallback CLI name into a family
# candidate in select_reviewer (issue #606, +6 lines). Measured.

finish
