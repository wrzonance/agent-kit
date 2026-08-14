#!/usr/bin/env bash
# Regression coverage for adversarial-review cleanup PID ownership.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='adversarial-review cleanup'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

review_lib="$root/agentkit/skills/.shared/scripts/lib/adversarial-review.sh"
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
printf '%s\n' '{"type":"system","subtype":"init","model":"claude-test","tools":["StructuredOutput"],"mcp_servers":[]}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"structured_output":{"verdict":"findings","findings":[{"priority":"P1"}]},"modelUsage":{"claude-test":{"inputTokens":1}},"duration_api_ms":1,"total_cost_usd":0.01}'
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
printf '%s\n' '{"verdict":"findings","findings":[{"priority":"P1"}]}' >"$last_file"
EOF
chmod +x "$tmp/fake-codex"

start_decoy() {
    local marker=$1
    (
        trap 'printf "%s\n" terminated >"$marker"; exit 0' TERM INT
        while :; do :; done
    ) >/dev/null 2>&1 &
    printf '%s\n' "$!"
}

stop_decoy() {
    local pid=$1
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}

assert_decoy_survives() {
    local pid=$1 marker=$2 message=$3
    if [[ -s $marker ]]; then
        _fail "$message" 'the decoy received TERM'
    elif kill -0 "$pid" 2>/dev/null; then
        _pass "$message"
    else
        _fail "$message" 'the decoy process is no longer alive'
    fi
}

# The empty-array expansions must be guarded explicitly: Bash 4.2 with
# nounset can treat an initialized empty array as unset during "${array[@]}".
# Keep a source assertion alongside the runtime boundary checks so this suite
# remains meaningful on newer Bash versions whose expansion behavior changed.
guard_pattern="if ((\${#REVIEW_CHILD_PIDS[@]})); then"
empty_registry_guard_count=$(grep -F -c "$guard_pattern" "$review_lib" || true)
assert_eq 2 "$empty_registry_guard_count" \
    'shared PID loops guard empty arrays for Bash 4.2 nounset compatibility'
remaining_guard_pattern="if ((\${#remaining[@]})); then"
remaining_guard_count=$(grep -F -c "$remaining_guard_pattern" "$review_lib" || true)
assert_eq 1 "$remaining_guard_count" \
    'forget_pid guards empty remaining arrays before registry replacement'

forget_rc=0
bash -u -c 'source "$1"; REVIEW_CHILD_PIDS=(123 456); review_forget_pid 456; [[ ${#REVIEW_CHILD_PIDS[@]} -eq 1 && ${REVIEW_CHILD_PIDS[0]} == 123 ]]; review_forget_pid 123; [[ ${#REVIEW_CHILD_PIDS[@]} -eq 0 ]]' \
    _ "$review_lib" || forget_rc=$?
assert_eq 0 "$forget_rc" \
    'forgetting registered PIDs preserves survivors and safely clears the last PID under nounset'

empty_pid_file="$tmp/empty.pid"
empty_status_file="$tmp/empty.status"
empty_status_tmp="$tmp/empty.status.tmp"
empty_output_tmp="$tmp/empty.output.tmp"
touch "$empty_pid_file" "$empty_status_file" "$empty_status_tmp" "$empty_output_tmp"
cleanup_rc=0
bash -u -c 'source "$1"; PID_FILE="$2"; STATUS_FILE="$3"; STATUS_TMP="$4"; OUTPUT_TMP="$5"; review_cleanup' \
    _ "$review_lib" "$empty_pid_file" "$empty_status_file" "$empty_status_tmp" "$empty_output_tmp" ||
    cleanup_rc=$?
assert_eq 0 "$cleanup_rc" \
    'cleanup with an empty registry is safe under nounset'
for artifact in "$empty_pid_file" "$empty_status_file" "$empty_status_tmp" "$empty_output_tmp"; do
    assert_eq no "$( [[ -e $artifact ]] && printf yes || printf no )" \
        "empty-registry cleanup removes temporary artifact ${artifact##*/}"
done

# Cleanup must ignore mutable PID slots even when a caller assigns an arbitrary
# process after the shared library has been sourced. Only registered spawn PIDs
# are cleanup authority.
direct_marker="$tmp/direct.term"
direct_pid=$(start_decoy "$direct_marker")
bash -c 'source "$1"; CLAUDE_PID="$2"; CODEX_PID="$2"; LIMIT_PID="$2"; POLLER_PID="$2"; review_cleanup' \
    _ "$review_lib" "$direct_pid"
assert_decoy_survives "$direct_pid" "$direct_marker" \
    'shared cleanup ignores unregistered PID slots'
stop_decoy "$direct_pid"

run_wrapper_with_decoy() {
    local helper=$1 fake=$2
    local name=${helper##*/}
    local marker="$tmp/$name.term" run_dir="$tmp/$name.run" pid rc=0
    mkdir -- "$run_dir"
    chmod 700 -- "$run_dir"
    pid=$(start_decoy "$marker")
    if [[ $name == claude-adversarial-review.sh ]]; then
        CLAUDE_PID=$pid CODEX_PID=$pid LIMIT_PID=$pid POLLER_PID=$pid \
            CLAUDE_EXECUTABLE="$fake" bash "$helper" --mode probe --model claude-test \
            --transcript "$run_dir/transcript.jsonl" --poll-seconds 1 \
            --max-duration-seconds 30 >/dev/null 2>"$run_dir/stderr.log" || rc=$?
    else
        CLAUDE_PID=$pid CODEX_PID=$pid LIMIT_PID=$pid POLLER_PID=$pid \
            CODEX_EXECUTABLE="$fake" bash "$helper" --mode probe --model gpt-test \
            --transcript "$run_dir/transcript.jsonl" --poll-seconds 1 \
            --max-duration-seconds 30 --max-tokens 1024 \
            >/dev/null 2>"$run_dir/stderr.log" || rc=$?
    fi
    if ((rc == 0)); then
        _pass "$name completes with pre-exported harness PID decoys"
    else
        _fail "$name completes with pre-exported harness PID decoys" \
            "rc=$rc; stderr: $(<"$run_dir/stderr.log")"
    fi
    assert_decoy_survives "$pid" "$marker" \
        "$name cleanup leaves pre-exported PID decoys alive"
    stop_decoy "$pid"
}

run_wrapper_with_decoy "$claude" "$tmp/fake-claude"
run_wrapper_with_decoy "$codex" "$tmp/fake-codex"

finish
