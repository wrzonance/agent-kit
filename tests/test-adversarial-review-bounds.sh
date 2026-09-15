#!/usr/bin/env bash
# Regression coverage for adversarial-review duration and token ceilings.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='adversarial review bounds'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

claude="$root/agentkit/skills/review-remote-pr/scripts/claude-adversarial-review.sh"
codex="$root/agentkit/skills/review-remote-pr/scripts/codex-adversarial-review.sh"

wait_for_heartbeat_advance() {
    local status_file=$1 first_epoch=$2 message=$3
    local deadline=$((SECONDS + 4)) current_epoch=''
    while ((SECONDS < deadline)); do
        if [[ -s $status_file ]]; then
            current_epoch=$(jq -r '.wallClockEpoch // empty' <"$status_file" 2>/dev/null || true)
            if [[ $current_epoch =~ ^[0-9]+$ && $current_epoch != "$first_epoch" ]]; then
                _pass "$message"
                return 0
            fi
        fi
        sleep 0.1
    done
    _fail "$message" "epoch remained: ${current_epoch:-unavailable}"
}

cat >"$tmp/fake-claude" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
sleep 5
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
if [[ -n ${FAKE_CODEX_PID_FILE:-} ]]; then
    printf '%s\n' "$$" >"$FAKE_CODEX_PID_FILE"
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then
        last_file=$2
        shift 2
    else
        shift
    fi
done
if [[ ${FAKE_CODEX_NO_USAGE:-0} != 1 ]]; then
    printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":'"${FAKE_CODEX_USAGE:-1000}"',"output_tokens":'"${FAKE_CODEX_USAGE:-1000}"'}}'
else
    printf '%s\n' '{"type":"turn.completed"}'
fi
if [[ -n $last_file ]]; then
    printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
fi
sleep 5
EOF
chmod +x "$tmp/fake-codex"

cat >"$tmp/fake-claude-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-test","tools":["StructuredOutput"],"mcp_servers":[]}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"no_findings","findings":[]},"modelUsage":{"claude-test":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
EOF
chmod +x "$tmp/fake-claude-success"

cat >"$tmp/fake-claude-record" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
[[ -z ${FAKE_CLAUDE_CALLED:-} ]] || printf 'called\n' >>"$FAKE_CLAUDE_CALLED"
[[ -z ${FAKE_CLAUDE_ARGV_FILE:-} ]] || printf '%s\n' "$@" >"$FAKE_CLAUDE_ARGV_FILE"
[[ -z ${FAKE_CLAUDE_OUTPUT_ENV_FILE:-} ]] || printf '%s' "${CLAUDE_CODE_MAX_OUTPUT_TOKENS-unset}" >"$FAKE_CLAUDE_OUTPUT_ENV_FILE"
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-test","tools":["StructuredOutput"],"mcp_servers":[]}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"findings","findings":[{"priority":"P1","location":"probe.js:1","failureScenario":"The function authorizes every deletion.","smallestFix":"Check the requesting user and target user."}]},"modelUsage":{"claude-test":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
EOF
chmod +x "$tmp/fake-claude-record"

# Same success stream, but slow enough for a concurrent poller to observe the
# helper mid-run (the PID-file liveness fixture below).
cat >"$tmp/fake-claude-slow" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'claude 2.1.0'
    exit 0
fi
if [[ ${1:-} == --help ]]; then
    printf '%s\n' '--print --model --effort --system-prompt --tools --permission-mode'
    printf '%s\n' '--no-session-persistence --safe-mode --disable-slash-commands'
    printf '%s\n' '--strict-mcp-config --mcp-config --output-format'
    printf '%s\n' '--include-partial-messages --json-schema --max-budget-usd --no-chrome --verbose'
    exit 0
fi
if [[ -n ${FAKE_CLAUDE_PID_FILE:-} ]]; then
    printf '%s\n' "$BASHPID" >"$FAKE_CLAUDE_PID_FILE"
fi
[[ -z ${FAKE_CLAUDE_LAUNCHES:-} ]] || printf 'launch\n' >>"$FAKE_CLAUDE_LAUNCHES"
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-test","tools":["StructuredOutput"],"mcp_servers":[]}'
sleep "${FAKE_CLAUDE_SLEEP:-2}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"no_findings","findings":[]},"modelUsage":{"claude-test":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
EOF
chmod +x "$tmp/fake-claude-slow"

cat >"$tmp/fake-codex-success" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' '--model --config --sandbox --ephemeral --ignore-user-config'
    printf '%s\n' '--ignore-rules --skip-git-repo-check --output-schema'
    printf '%s\n' '--output-last-message --json'
    exit 0
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then
        last_file=$2
        shift 2
    else
        shift
    fi
done
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}'
printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
EOF
chmod +x "$tmp/fake-codex-success"

cat >"$tmp/fake-codex-slow" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${1:-} == exec && ${2:-} == --help ]]; then
    printf '%s\n' '--model --config --sandbox --ephemeral --ignore-user-config'
    printf '%s\n' '--ignore-rules --skip-git-repo-check --output-schema'
    printf '%s\n' '--output-last-message --json'
    exit 0
fi
last_file=''
while (($#)); do
    if [[ $1 == --output-last-message ]]; then
        last_file=$2
        shift 2
    else
        shift
    fi
done
if [[ -n ${FAKE_CODEX_PID_FILE:-} ]]; then
    printf '%s\n' "$BASHPID" >"$FAKE_CODEX_PID_FILE"
fi
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}'
printf '%s\n' '{"verdict":"no_findings","findings":[]}' >"$last_file"
sleep "${FAKE_CODEX_SLEEP:-2}"
EOF
chmod +x "$tmp/fake-codex-slow"

private="$tmp/run"
mkdir -- "$private"
chmod 700 -- "$private"

invalid_err="$tmp/invalid.err"
invalid_rc=0
bash "$claude" --mode probe --no-payload --model claude-test --transcript "$private/invalid" \
    --max-duration-seconds 0 > /dev/null 2>"$invalid_err" || invalid_rc=$?
assert_eq 1 "$invalid_rc" 'Claude rejects a zero duration ceiling'
assert_contains "$(<"$invalid_err")" '--max-duration-seconds' \
    'Claude names the duration option in validation errors'

claude_err="$tmp/claude.err"
claude_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude" bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/claude.ndjson" --poll-seconds 1 --max-duration-seconds 1 \
    --max-budget-usd 0.25 > /dev/null 2>"$claude_err" || claude_rc=$?
assert_eq 1 "$claude_rc" 'Claude review expires at its duration ceiling'
assert_contains "$(<"$claude_err")" 'duration' \
    'Claude reports a duration-bound review as a safety failure'

codex_err="$tmp/codex.err"
codex_rc=0
FAKE_CODEX_PID_FILE="$tmp/codex.pid" CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" --mode probe --no-payload --model gpt-test \
    --transcript "$private/codex.jsonl" --poll-seconds 1 --max-duration-seconds 30 \
    --max-tokens 1024 > /dev/null 2>"$codex_err" || codex_rc=$?
assert_eq 1 "$codex_rc" 'Codex rejects usage above its token ceiling'
assert_contains "$(<"$codex_err")" 'token' \
    'Codex reports a token-bound review as a safety failure'
codex_pid=$(<"$tmp/codex.pid")
codex_live=1
for _ in {1..20}; do
    codex_state=$(ps -o stat= -p "$codex_pid" 2>/dev/null | tr -d ' ' || true)
    if [[ -z $codex_state || $codex_state == Z* ]]; then
        codex_live=0
        break
    fi
    sleep 0.1
done
assert_eq 0 "$codex_live" 'Codex token limit terminates the reviewed process group'

codex_no_usage_result="$tmp/codex-no-usage.json"
codex_no_usage_err="$tmp/codex-no-usage.err"
no_usage_diff="$tmp/no-usage.diff"
printf '%s\n' 'diff --git a/example.txt b/example.txt' '+safe' >"$no_usage_diff"
consent_script="$root/agentkit/skills/review-remote-pr/scripts/consent-record.sh"
claude_consent_state="$private/claude-consent"
codex_consent_state="$private/codex-consent"
grant_consent() {
    local state_path=$1 provider=$2 diff_path=$3 payload
    # Direct helper reviews now require repository-scoped durable accounting.
    export CONSENT_WORKTREE="$tmp/attempt-repo"
    if [[ ! -d $CONSENT_WORKTREE/.git ]]; then
        git init -q "$CONSENT_WORKTREE"
        git -C "$CONSENT_WORKTREE" -c user.name=test -c user.email=test@example.invalid \
            commit -q --allow-empty -m fixture
    fi
    rm -rf -- "$CONSENT_WORKTREE/.git/agentkit-review-attempts"
    payload=$(/bin/bash "$consent_script" payload --repo acme/widget --pr 24 --diff "$diff_path")
    /bin/bash "$consent_script" grant --state "$state_path" --provider "$provider" \
        --payload "$payload" --source interactive >/dev/null
}
grant_consent "$codex_consent_state" openai "$no_usage_diff"
codex_no_usage_rc=0
FAKE_CODEX_NO_USAGE=1 CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" \
    --mode review --model gpt-test --repo acme/widget --pr 24 --consent-state "$codex_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$private/codex-no-usage.jsonl" \
    --poll-seconds 1 --max-duration-seconds 30 --max-tokens 1024 \
    >"$codex_no_usage_result" 2>"$codex_no_usage_err" || codex_no_usage_rc=$?
assert_eq 0 "$codex_no_usage_rc" 'Codex accepts a valid verdict without usage telemetry'
assert_contains "$(<"$codex_no_usage_result")" '"budgetCeiling": "unverified"' \
    'Codex reports an unverified budget when telemetry is absent'
assert_contains "$(<"$codex_no_usage_result")" '"usedTokens": null' \
    'Codex preserves a nullable token usage result'

grant_consent "$claude_consent_state" anthropic "$no_usage_diff"

oversized_diff="$tmp/oversized.diff"
head -c 8192 /dev/zero | tr '\0' x >"$oversized_diff"
oversized_consent_state="$private/oversized-consent"
grant_consent "$oversized_consent_state" openai "$oversized_diff"
oversized_err="$tmp/oversized.err"
oversized_rc=0
CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" --mode review --model gpt-test --repo acme/widget \
    --pr 24 --consent-state "$oversized_consent_state" --diff "$oversized_diff" \
    --transcript "$private/oversized.jsonl" \
    --poll-seconds 1 --max-duration-seconds 30 --max-tokens 1024 \
    > /dev/null 2>"$oversized_err" || oversized_rc=$?
assert_eq 1 "$oversized_rc" 'Codex rejects a diff that cannot fit the token ceiling'
assert_contains "$(<"$oversized_err")" 'input tokens' \
    'Codex explains the input-token admission failure'

codex_duration_err="$tmp/codex-duration.err"
codex_duration_rc=0
FAKE_CODEX_USAGE=1 CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" \
    --mode probe --no-payload --model gpt-test --transcript "$private/codex-duration.jsonl" \
    --poll-seconds 1 --max-duration-seconds 1 --max-tokens 1024 > /dev/null \
    2>"$codex_duration_err" || codex_duration_rc=$?
assert_eq 1 "$codex_duration_rc" 'Codex review expires at its duration ceiling'
assert_contains "$(<"$codex_duration_err")" 'duration' \
    'Codex reports a duration-bound review as a safety failure'

review_lib_text=$(<"$root/agentkit/skills/.shared/scripts/lib/adversarial-review.sh")
assert_contains "$review_lib_text" "sleep \"\$POLL_SECONDS\" &" \
    'Codex progress sleep is interruptible during cleanup'
source "$root/agentkit/skills/.shared/scripts/lib/adversarial-review.sh"
assert_eq unauthenticated "$(review_classify_blocked_reason 'HTTP 401 unauthorized authentication failed')" \
    'Codex blocked classifier preserves 401/unauthorized authentication patterns'
assert_eq network-unreachable "$(review_classify_blocked_reason 'dns error: failed to lookup host; network unavailable')" \
    'Codex blocked classifier preserves DNS/lookup/network patterns'
codex_text=$(<"$codex")
assert_contains "$codex_text" 'DEFAULT_MAX_TOKENS=400000' \
    'Codex default token ceiling covers the maximum diff budget'

skill="$root/agentkit/skills/review-remote-pr/references/adversarial-review.md"
skill_text=$(<"$skill")
assert_contains "$skill_text" '--max-duration-seconds' \
    'the review skill passes an explicit duration ceiling'
assert_contains "$skill_text" '--max-tokens 400000' \
    'the review skill passes an explicit Codex token ceiling'

claude_success_dir="$tmp/claude-success"
mkdir -- "$claude_success_dir"
chmod 700 -- "$claude_success_dir"
claude_success_result="$tmp/claude-success.result.json"
grant_consent "$claude_consent_state" anthropic "$no_usage_diff"
CLAUDE_EXECUTABLE="$tmp/fake-claude-success" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$claude_success_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-budget-usd 0.25 >"$claude_success_result"
assert_contains "$(cat "$claude_success_result")" '"status": "completed"' \
    'Claude returns a completed result for a valid provider stream'
assert_contains "$(cat "$claude_success_result")" '"verdict": {' \
    'Claude preserves the structured no-findings verdict'
assert_contains "$(cat "$claude_success_result")" '"verdict": "no_findings"' \
    'Claude preserves the no-findings verdict value'

# A caller-selected output ceiling is validated and confined to the provider
# process. The inherited variable cannot silently change default behavior.
requested_limit_result="$tmp/requested-limit.result.json"
requested_limit_env="$tmp/requested-limit.env"
requested_limit_argv="$tmp/requested-limit.argv"
requested_limit_called="$tmp/requested-limit.called"
CLAUDE_CODE_MAX_OUTPUT_TOKENS=17 CLAUDE_EXECUTABLE="$tmp/fake-claude-record" \
    FAKE_CLAUDE_OUTPUT_ENV_FILE="$requested_limit_env" \
    FAKE_CLAUDE_ARGV_FILE="$requested_limit_argv" FAKE_CLAUDE_CALLED="$requested_limit_called" \
    bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/requested-limit.jsonl" --poll-seconds 1 --max-duration-seconds 30 \
    --max-output-tokens 128000 --max-budget-usd 10 >"$requested_limit_result"
assert_eq 128000 "$(<"$requested_limit_env")" \
    'Claude receives the requested output-token ceiling in its own environment'
assert_contains "$(<"$requested_limit_argv")" $'--max-budget-usd\n10.00' \
    'Claude receives the explicitly authorized ten-dollar ceiling'
assert_eq 128000 "$(jq -r '.requestedMaxOutputTokens' "$requested_limit_result")" \
    'Claude result records the requested output-token ceiling'
assert_eq 10.00 "$(jq -r '.requestedMaxBudgetUsd' "$requested_limit_result")" \
    'Claude result records the requested budget ceiling'

default_limit_result="$tmp/default-limit.result.json"
default_limit_env="$tmp/default-limit.env"
CLAUDE_CODE_MAX_OUTPUT_TOKENS=17 CLAUDE_EXECUTABLE="$tmp/fake-claude-record" \
    FAKE_CLAUDE_OUTPUT_ENV_FILE="$default_limit_env" \
    bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/default-limit.jsonl" --poll-seconds 1 --max-duration-seconds 30 \
    >"$default_limit_result"
assert_eq 17 "$(<"$default_limit_env")" \
	'Claude preserves an inherited output-token override when the option is omitted'
assert_eq null "$(jq -r '.requestedMaxOutputTokens' "$default_limit_result")" \
    'default result records no output-token override'
assert_eq 5.00 "$(jq -r '.requestedMaxBudgetUsd' "$default_limit_result")" \
    'omitting a budget preserves the existing five-dollar ceiling'

invalid_limit_called="$tmp/invalid-limit.called"
invalid_limit_err="$tmp/invalid-limit.err"
invalid_limit_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude-record" FAKE_CLAUDE_CALLED="$invalid_limit_called" \
    bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/invalid-limit.jsonl" --max-output-tokens 128001 \
    > /dev/null 2>"$invalid_limit_err" || invalid_limit_rc=$?
assert_eq 1 "$invalid_limit_rc" 'Claude rejects output ceilings above the supported 128000 maximum'
assert_contains "$(<"$invalid_limit_err")" '--max-output-tokens' \
    'Claude names an invalid output-token ceiling'
[[ ! -e $invalid_limit_called ]] || _fail 'an invalid output-token ceiling never launches Claude' \
    "provider call marker exists: $invalid_limit_called"

zero_limit_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude-record" FAKE_CLAUDE_CALLED="$invalid_limit_called" \
    bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/zero-limit.jsonl" --max-output-tokens 0 \
    > /dev/null 2>"$invalid_limit_err" || zero_limit_rc=$?
assert_eq 1 "$zero_limit_rc" 'Claude rejects a zero output-token ceiling'
[[ ! -e $invalid_limit_called ]] || _fail 'zero output-token ceiling never launches Claude' \
    "provider call marker exists: $invalid_limit_called"

malformed_limit_rc=0
malformed_limit_value="12;touch $tmp/not-a-review-option"
CLAUDE_EXECUTABLE="$tmp/fake-claude-record" FAKE_CLAUDE_CALLED="$invalid_limit_called" \
    bash "$claude" --mode probe --no-payload --model claude-test \
    --transcript "$private/malformed-limit.jsonl" --max-output-tokens "$malformed_limit_value" \
    > /dev/null 2>"$invalid_limit_err" || malformed_limit_rc=$?
assert_eq 1 "$malformed_limit_rc" 'Claude rejects nonnumeric output-token input'
[[ ! -e $invalid_limit_called ]] || _fail 'malformed output-token input never launches Claude' \
    "provider call marker exists: $invalid_limit_called"
[[ ! -e $tmp/not-a-review-option ]] || _fail 'malformed output-token input is never evaluated' \
    'the injected scratch marker was created'

# Cross-cell heartbeat: a detached poller must observe a status artifact that
# appears immediately, ticks while the producer runs, and disappears on cleanup.
pid_dir="$tmp/claude-pidfile"
mkdir -- "$pid_dir"
chmod 700 -- "$pid_dir"
pid_result="$tmp/claude-pidfile.result.json"
grant_consent "$claude_consent_state" anthropic "$no_usage_diff"
CLAUDE_EXECUTABLE="$tmp/fake-claude-slow" FAKE_CLAUDE_SLEEP=4 FAKE_CLAUDE_LAUNCHES="$tmp/slow-launches" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" --output "$pid_dir/original.json" \
    --transcript "$pid_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-budget-usd 0.25 >"$pid_result" &
helper_pid=$!
pid_file="$pid_dir/transcript.jsonl.pid"
status_file="$pid_dir/transcript.jsonl.status"
pid_seen=''
status_first=''
for _ in $(seq 1 100); do
    if [[ -s $pid_file ]]; then
        pid_seen=$(<"$pid_file")
    fi
    if [[ -s $status_file ]]; then
        status_first=$(<"$status_file")
    fi
    [[ -n $pid_seen && -n $status_first ]] && break
    sleep 0.1
done
assert_contains "$status_first" '"elapsedSeconds"' 'Claude status records elapsed seconds'
assert_contains "$status_first" '"transcriptBytes"' 'Claude status records transcript bytes'
assert_contains "$status_first" '"eventCount"' 'Claude status records event count'
assert_contains "$status_first" '"wallClockEpoch"' 'Claude status records wall-clock epoch'
first_epoch=$(jq -r '.wallClockEpoch' <<<"$status_first")
wait_for_heartbeat_advance "$status_file" "$first_epoch" \
    'Claude status heartbeat advances while the review runs'
assert_eq "$helper_pid" "$pid_seen" 'a running helper records its own PID beside the transcript'
assert_rc 1 'a slow running review cannot be purchased again through a direct helper' -- \
    env CLAUDE_EXECUTABLE="$tmp/fake-claude-slow" FAKE_CLAUDE_LAUNCHES="$tmp/slow-launches" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" --transcript "$pid_dir/duplicate.jsonl" --max-duration-seconds 30
wait "$helper_pid"
assert_eq 1 "$(wc -l <"$tmp/slow-launches")" 'slow completion and replay produce exactly one provider invocation'
original_result=$(cat "$pid_dir/original.json")
assert_rc 1 'completed direct-helper replay is refused before replacing output' -- \
    env CLAUDE_EXECUTABLE="$tmp/fake-claude-slow" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" --output "$pid_dir/original.json" --transcript "$pid_dir/replay.jsonl" --max-duration-seconds 30
assert_eq "$original_result" "$(cat "$pid_dir/original.json" 2>/dev/null)" \
    'rejected direct replay preserves the original completed result byte-for-byte'
assert_eq no "$( [[ ! -e $pid_file ]] && printf no || printf yes )" \
    'a finished helper removes its PID file'
assert_eq no "$( [[ ! -e $status_file ]] && printf no || printf yes )" \
    'a finished Claude helper removes its status file'
assert_contains "$(cat "$pid_result")" '"status": "completed"' \
    'the PID-file run still completes normally'

# A heartbeat publication failure is a blocked review, and must stop the
# producer instead of leaving it running behind a stale status artifact.
grant_consent "$claude_consent_state" anthropic "$no_usage_diff"
printf 'preserve output target\n' >"$pid_dir/output-target"
ln -s "$pid_dir/output-target" "$pid_dir/output-link"
assert_rc 1 'absolute-path accounting preserves rejection of output symlinks' -- \
    env CLAUDE_EXECUTABLE="$tmp/fake-claude-success" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" --output "$pid_dir/output-link" --transcript "$pid_dir/symlink.jsonl" --max-duration-seconds 30
assert_eq 'preserve output target' "$(cat "$pid_dir/output-target")" 'output normalization cannot overwrite a symlink target'

mv_bin="$tmp/mv-bin"
mkdir -- "$mv_bin"
real_mv=$(command -v mv)
cat >"$mv_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${!#} == *.status ]]; then
    printf '%s\n' 'simulated heartbeat publication failure' >&2
    exit 1
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mv_bin/mv"
failure_dir="$tmp/claude-heartbeat-failure"
mkdir -- "$failure_dir"
chmod 700 -- "$failure_dir"
failure_result="$tmp/claude-heartbeat-failure.result.json"
failure_err="$tmp/claude-heartbeat-failure.err"
failure_producer_pid_file="$tmp/claude-heartbeat-failure.pid"
grant_consent "$claude_consent_state" anthropic "$no_usage_diff"
CLAUDE_EXECUTABLE="$tmp/fake-claude-slow" FAKE_CLAUDE_PID_FILE="$failure_producer_pid_file" \
PATH="$mv_bin:$PATH" REAL_MV="$real_mv" bash "$claude" \
    --mode review --model claude-test --repo acme/widget --pr 24 --consent-state "$claude_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$failure_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-budget-usd 0.25 >"$failure_result" 2>"$failure_err" &
failure_helper_pid=$!
failure_producer_pid=''
for _ in $(seq 1 100); do
    if [[ -s $failure_producer_pid_file ]]; then
        failure_producer_pid=$(<"$failure_producer_pid_file")
        break
    fi
    sleep 0.1
done
failure_rc=0
wait "$failure_helper_pid" || failure_rc=$?
assert_eq 1 "$failure_rc" 'Claude blocks when heartbeat publication fails'
assert_contains "$(cat "$failure_err")" 'heartbeat publication failed' \
    'Claude reports the heartbeat publication failure'
failure_live=1
for _ in {1..50}; do
    failure_state=$(ps -o stat= -p "$failure_producer_pid" 2>/dev/null | tr -d ' ' || true)
    if [[ -z $failure_state || $failure_state == Z* ]]; then
        failure_live=0
        break
    fi
    sleep 0.1
done
assert_eq 0 "$failure_live" 'Claude stops the producer after heartbeat publication fails'

codex_failure_dir="$tmp/codex-heartbeat-failure"
mkdir -- "$codex_failure_dir"
chmod 700 -- "$codex_failure_dir"
codex_failure_result="$tmp/codex-heartbeat-failure.result.json"
codex_failure_err="$tmp/codex-heartbeat-failure.err"
codex_failure_producer_pid_file="$tmp/codex-heartbeat-failure.pid"
grant_consent "$codex_consent_state" openai "$no_usage_diff"
CODEX_EXECUTABLE="$tmp/fake-codex-slow" FAKE_CODEX_PID_FILE="$codex_failure_producer_pid_file" \
FAKE_CODEX_SLEEP=10 PATH="$mv_bin:$PATH" REAL_MV="$real_mv" bash "$codex" \
    --mode review --model gpt-test --repo acme/widget --pr 24 --consent-state "$codex_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$codex_failure_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-tokens 1024 >"$codex_failure_result" 2>"$codex_failure_err" &
codex_failure_helper_pid=$!
codex_failure_producer_pid=''
for _ in $(seq 1 100); do
    if [[ -s $codex_failure_producer_pid_file ]]; then
        codex_failure_producer_pid=$(<"$codex_failure_producer_pid_file")
        break
    fi
    sleep 0.1
done
codex_failure_rc=0
wait "$codex_failure_helper_pid" || codex_failure_rc=$?
assert_eq 1 "$codex_failure_rc" 'Codex blocks when heartbeat publication fails'
assert_contains "$(cat "$codex_failure_err")" 'heartbeat publication failed' \
    'Codex reports the heartbeat publication failure'
codex_failure_live=1
for _ in {1..50}; do
    codex_failure_state=$(ps -o stat= -p "$codex_failure_producer_pid" 2>/dev/null | tr -d ' ' || true)
    if [[ -z $codex_failure_state || $codex_failure_state == Z* ]]; then
        codex_failure_live=0
        break
    fi
    sleep 0.1
done
assert_eq 0 "$codex_failure_live" 'Codex stops the producer after heartbeat publication fails'

assert_contains "$review_lib_text" 'TRANSCRIPT_PATH.pid' \
    'the Codex helper records its PID beside the transcript too'

codex_success_dir="$tmp/codex-success"
mkdir -- "$codex_success_dir"
chmod 700 -- "$codex_success_dir"
codex_success_result="$tmp/codex-success.result.json"
grant_consent "$codex_consent_state" openai "$no_usage_diff"
CODEX_EXECUTABLE="$tmp/fake-codex-success" bash "$codex" \
    --mode review --model gpt-test --repo acme/widget --pr 24 --consent-state "$codex_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$codex_success_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-tokens 1024 >"$codex_success_result"
assert_contains "$(cat "$codex_success_result")" '"status": "completed"' \
    'Codex returns a completed result for a valid provider stream'
assert_contains "$(cat "$codex_success_result")" '"budgetCeiling": "token-limit"' \
    'Codex reports an observed token ceiling when usage is present'

codex_status_dir="$tmp/codex-status"
mkdir -- "$codex_status_dir"
chmod 700 -- "$codex_status_dir"
codex_status_result="$tmp/codex-status.result.json"
grant_consent "$codex_consent_state" openai "$no_usage_diff"
CODEX_EXECUTABLE="$tmp/fake-codex-slow" bash "$codex" \
    --mode review --model gpt-test --repo acme/widget --pr 24 --consent-state "$codex_consent_state" \
    --diff "$no_usage_diff" \
    --transcript "$codex_status_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-tokens 1024 >"$codex_status_result" &
codex_helper_pid=$!
codex_status_file="$codex_status_dir/transcript.jsonl.status"
codex_status_first=''
for _ in $(seq 1 100); do
    if [[ -s $codex_status_file ]]; then
        codex_status_first=$(<"$codex_status_file")
        break
    fi
    sleep 0.1
done
assert_contains "$codex_status_first" '"elapsedSeconds"' 'Codex status records elapsed seconds'
assert_contains "$codex_status_first" '"transcriptBytes"' 'Codex status records transcript bytes'
assert_contains "$codex_status_first" '"eventCount"' 'Codex status records event count'
assert_contains "$codex_status_first" '"wallClockEpoch"' 'Codex status records wall-clock epoch'
codex_first_epoch=$(jq -r '.wallClockEpoch' <<<"$codex_status_first")
wait_for_heartbeat_advance "$codex_status_file" "$codex_first_epoch" \
    'Codex status heartbeat advances while the review runs'
wait "$codex_helper_pid"
assert_eq no "$( [[ ! -e $codex_status_file ]] && printf no || printf yes )" \
    'a finished Codex helper removes its status file'
assert_contains "$(cat "$codex_status_result")" '"status": "completed"' \
    'the status-file Codex run still completes normally'

finish
