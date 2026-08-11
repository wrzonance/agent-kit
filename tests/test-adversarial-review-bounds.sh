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

private="$tmp/run"
mkdir -- "$private"
chmod 700 -- "$private"

invalid_err="$tmp/invalid.err"
invalid_rc=0
bash "$claude" --mode probe --model claude-test --transcript "$private/invalid" \
    --max-duration-seconds 0 > /dev/null 2>"$invalid_err" || invalid_rc=$?
assert_eq 1 "$invalid_rc" 'Claude rejects a zero duration ceiling'
assert_contains "$(<"$invalid_err")" '--max-duration-seconds' \
    'Claude names the duration option in validation errors'

claude_err="$tmp/claude.err"
claude_rc=0
CLAUDE_EXECUTABLE="$tmp/fake-claude" bash "$claude" --mode probe --model claude-test \
    --transcript "$private/claude.ndjson" --poll-seconds 1 --max-duration-seconds 1 \
    --max-budget-usd 0.25 > /dev/null 2>"$claude_err" || claude_rc=$?
assert_eq 1 "$claude_rc" 'Claude review expires at its duration ceiling'
assert_contains "$(<"$claude_err")" 'duration' \
    'Claude reports a duration-bound review as a safety failure'

codex_err="$tmp/codex.err"
codex_rc=0
FAKE_CODEX_PID_FILE="$tmp/codex.pid" CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" --mode probe --model gpt-test \
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
codex_no_usage_rc=0
FAKE_CODEX_NO_USAGE=1 CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" \
    --mode review --model gpt-test --diff "$no_usage_diff" \
    --transcript "$private/codex-no-usage.jsonl" \
    --poll-seconds 1 --max-duration-seconds 30 --max-tokens 1024 \
    >"$codex_no_usage_result" 2>"$codex_no_usage_err" || codex_no_usage_rc=$?
assert_eq 0 "$codex_no_usage_rc" 'Codex accepts a valid verdict without usage telemetry'
assert_contains "$(<"$codex_no_usage_result")" '"budgetCeiling": "unverified"' \
    'Codex reports an unverified budget when telemetry is absent'
assert_contains "$(<"$codex_no_usage_result")" '"usedTokens": null' \
    'Codex preserves a nullable token usage result'

oversized_diff="$tmp/oversized.diff"
head -c 8192 /dev/zero | tr '\0' x >"$oversized_diff"
oversized_err="$tmp/oversized.err"
oversized_rc=0
CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" --mode review --model gpt-test \
    --diff "$oversized_diff" --transcript "$private/oversized.jsonl" \
    --poll-seconds 1 --max-duration-seconds 30 --max-tokens 1024 \
    > /dev/null 2>"$oversized_err" || oversized_rc=$?
assert_eq 1 "$oversized_rc" 'Codex rejects a diff that cannot fit the token ceiling'
assert_contains "$(<"$oversized_err")" 'input tokens' \
    'Codex explains the input-token admission failure'

codex_duration_err="$tmp/codex-duration.err"
codex_duration_rc=0
FAKE_CODEX_USAGE=1 CODEX_EXECUTABLE="$tmp/fake-codex" bash "$codex" \
    --mode probe --model gpt-test --transcript "$private/codex-duration.jsonl" \
    --poll-seconds 1 --max-duration-seconds 1 --max-tokens 1024 > /dev/null \
    2>"$codex_duration_err" || codex_duration_rc=$?
assert_eq 1 "$codex_duration_rc" 'Codex review expires at its duration ceiling'
assert_contains "$(<"$codex_duration_err")" 'duration' \
    'Codex reports a duration-bound review as a safety failure'

codex_text=$(<"$codex")
assert_contains "$codex_text" "sleep \"\$POLL_SECONDS\" &" \
    'Codex progress sleep is interruptible during cleanup'
assert_contains "$codex_text" 'DEFAULT_MAX_TOKENS=400000' \
    'Codex default token ceiling covers the maximum diff budget'

skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
skill_text=$(<"$skill")
assert_contains "$skill_text" '--max-duration-seconds' \
    'the review skill passes an explicit duration ceiling'
assert_contains "$skill_text" '--max-tokens 400000' \
    'the review skill passes an explicit Codex token ceiling'

claude_success_dir="$tmp/claude-success"
mkdir -- "$claude_success_dir"
chmod 700 -- "$claude_success_dir"
claude_success_result="$tmp/claude-success.result.json"
CLAUDE_EXECUTABLE="$tmp/fake-claude-success" bash "$claude" \
    --mode review --model claude-test --diff "$no_usage_diff" \
    --transcript "$claude_success_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-budget-usd 0.25 >"$claude_success_result"
assert_contains "$(cat "$claude_success_result")" '"status": "completed"' \
    'Claude returns a completed result for a valid provider stream'
assert_contains "$(cat "$claude_success_result")" '"verdict": {' \
    'Claude preserves the structured no-findings verdict'
assert_contains "$(cat "$claude_success_result")" '"verdict": "no_findings"' \
    'Claude preserves the no-findings verdict value'

codex_success_dir="$tmp/codex-success"
mkdir -- "$codex_success_dir"
chmod 700 -- "$codex_success_dir"
codex_success_result="$tmp/codex-success.result.json"
CODEX_EXECUTABLE="$tmp/fake-codex-success" bash "$codex" \
    --mode review --model gpt-test --diff "$no_usage_diff" \
    --transcript "$codex_success_dir/transcript.jsonl" --poll-seconds 1 \
    --max-duration-seconds 30 --max-tokens 1024 >"$codex_success_result"
assert_contains "$(cat "$codex_success_result")" '"status": "completed"' \
    'Codex returns a completed result for a valid provider stream'
assert_contains "$(cat "$codex_success_result")" '"budgetCeiling": "token-limit"' \
    'Codex reports an observed token ceiling when usage is present'

finish
