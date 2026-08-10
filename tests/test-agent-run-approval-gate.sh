#!/usr/bin/env bash
# Suite: repository command approval is a human-only action.
set -uo pipefail

TEST_NAME='agent-run-approval-gate'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
run_sh="$root/agentkit/skills/.shared/scripts/agent-run.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export AGENT_TRUST_ROOT="$tmp/trust"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    mkdir -p "$dir/.agent/cache"
    printf '%s' "$dir"
}

pre_input() {
    jq -nc --arg cwd "$1" --arg cmd "$2" --arg sid "$3" \
        '{cwd:$cwd,hook_event_name:"PreToolUse",model:"m",permission_mode:"default",
          session_id:$sid,tool_name:"Bash",tool_use_id:"t",transcript_path:null,
          tool_input:{command:$cmd}}'
}

decision() { jq -r '.hookSpecificOutput.permissionDecision // "allow"' <<< "$1"; }

repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"

# Every spelling that invokes the helper in command position is human-only, and
# the rule remains a denial on retries rather than becoming a session lesson.
approval_commands=(
    "\"$run_sh\" --approve --cmd verify"
    "$run_sh --cmd verify --approve"
    "bash \"$run_sh\" --approve --cmd verify"
)
sid=approval-gate
for command in "${approval_commands[@]}"; do
    out=$(pre_input "$repo" "$command" "$sid" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_hook_output "$out" pre-tool-use "approval request is schema-valid: $command"
    assert_eq 'deny' "$(decision "$out")" "denies agent approval request: $command"
    assert_contains "$out" 'human' "approval denial names human action: $command"
    assert_not_contains "$out" '--approve --cmd verify' \
        "approval denial does not teach a copyable bypass: $command"

    out=$(pre_input "$repo" "$command" "$sid" | "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'deny' "$(decision "$out")" "retry remains denied: $command"
done

# A command-position match is required; merely searching for the option or
# mentioning the helper in prose must not create a false denial.
for ordinary in \
    "grep -rn -- '--approve' agentkit/hooks" \
    "echo 'agent-run.sh --approve --cmd verify'" \
    "\"$run_sh\" --cmd verify" \
    "\"$run_sh\" --cmd verify --label approve"; do
    out=$(pre_input "$repo" "$ordinary" "ordinary-${RANDOM}" | \
        "$hooks/pre-tool-use.sh" 2>/dev/null)
    assert_eq 'allow' "$(decision "$out")" "allows ordinary command: $ordinary"
done

# The wrapper's own refusal must not expose the exact command that clears it.
out=$(cd "$repo" && "$run_sh" --cmd verify 2>&1) || true
assert_contains "$out" 'refusing unapproved repository command' \
    'the wrapper refuses an unapproved repository command'
assert_contains "$out" 'human' 'the wrapper says a human must clear approval'
assert_not_contains "$out" '--approve --cmd verify' \
    'the wrapper refusal does not print the bypass command'

finish
