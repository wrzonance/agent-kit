#!/usr/bin/env bash
# Suite: compose-worker-prompt.sh fills both worker templates from repository facts.
set -uo pipefail

TEST_NAME='compose-worker-prompt'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

compose="$root/agentkit/skills/parallel-issues/scripts/compose-worker-prompt.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir=$1 contract=$2
    mkdir -p "$dir/.agent"
    git -C "$dir" init -q
    printf '%s\n' \
        'AGENT_REPO_SLUG=example-org/example-repo' \
        'AGENT_BASE_BRANCH=develop' \
        'AGENT_CMD_VERIFY=tools/verify' \
        'AGENT_CMD_BACKEND_TEST=tools/backend-test' \
        'AGENT_CMD_TEST=tools/full-test' \
        'AGENT_CMD_TEST_FOCUS=tools/focused-test --only %s' \
        > "$dir/.agent/config.env"
    printf '%s\n' "$contract" > "$dir/.agent/env-contract.txt"
    printf '%s\n' "SPEC-BYTES \$(must-stay-literal)" > "$dir/.agent/fenced-spec.txt"
    printf '%s\n' 'PRIOR-BYTES' > "$dir/.agent/fenced-prior-art.txt"
}

contract=$'skills= path='"$root"$'/agentkit/skills\nharness= name=codex trailer="Codex <noreply@openai.com>"'
repo="$tmp/repo"
make_repo "$repo" "$contract"

chain_base=30c38b2c1fa35c6cecc5946aaa7c41e7c132885c
prompt=$(bash "$compose" --template issue-lead --worktree "$repo" \
    --issue 136 --branch feat/issue-136 --worker-model gpt-5.6-luna \
    --worker-effort high --yolo --chain-base "$chain_base")

assert_contains "$prompt" 'Repo: example-org/example-repo' 'issue lead receives the configured repository slug'
assert_contains "$prompt" 'Worktree: '"$repo" 'issue lead receives the absolute worktree'
assert_contains "$prompt" 'Branch: feat/issue-136' 'issue lead receives the requested branch'
assert_contains "$prompt" 'Base: develop' 'issue lead receives the configured base branch'
assert_contains "$prompt" 'Worker effort: high' 'issue lead receives the requested worker effort'
assert_contains "$prompt" "SPEC-BYTES \$(must-stay-literal)" 'spec bytes stay literal'
assert_contains "$prompt" 'PRIOR-BYTES' 'prior-art bytes are injected'
assert_contains "$prompt" 'worker_model='"'"'gpt-5.6-luna' 'worker model is filled'
assert_contains "$prompt" 'AGENT_CMD_TEST_FOCUS' 'declared focus contract remains documented'
assert_not_contains "$prompt" '<PASTE' 'issue lead has no PASTE placeholder'
assert_not_contains "$prompt" '<WHEN' 'issue lead has no WHEN placeholder'
assert_not_contains "$prompt" '--cmd lint' 'undeclared lint command is not injected'
assert_not_contains "$prompt" '--cmd build' 'undeclared build command is not injected'
assert_contains "$prompt" '--cmd verify --yolo --yolo-base ' 'verify receives chained yolo flags'
assert_contains "$prompt" '--cmd backend-test --yolo --yolo-base ' 'multi-word declaration becomes a dashed command name'
assert_contains "$prompt" '--cmd test --yolo --yolo-base ' 'test receives chained yolo flags'
assert_contains "$prompt" "--cmd test --only 'NAME[,NAME...]' --yolo --yolo-base $chain_base" \
    'focused test selector receives chained yolo flags'

command_lines=$(printf '%s\n' "$prompt" | rg 'agent-run\.sh.*--cmd' || true)
assert_not_contains "$command_lines" "\$(" 'generated command lines have no command substitutions'
assert_not_contains "$command_lines" '[[' 'generated command lines have no Bash conditionals'
assert_not_contains "$command_lines" 'mapfile' 'generated command lines have no Bash-only mapfile'
assert_not_contains "$command_lines" '<<<' 'generated command lines have no Bash-only here-string'

output_file="$tmp/fix-batch.md"
assert_rc 0 'fix-batch can render to an output file' -- bash "$compose" \
    --template fix-batch --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high --output "$output_file"
fix_prompt=$(<"$output_file")
assert_contains "$fix_prompt" 'PR: 136' 'fix-batch receives the issue number'
assert_contains "$fix_prompt" 'Base: develop' 'fix-batch receives the configured base branch'
assert_contains "$fix_prompt" 'Worker effort: high' 'fix-batch receives the requested worker effort'
assert_contains "$fix_prompt" '--cmd verify' 'fix-batch receives declared commands'
assert_not_contains "$fix_prompt" '<PASTE' 'fix-batch has no PASTE placeholder'
assert_not_contains "$fix_prompt" '<WHEN' 'fix-batch has no WHEN placeholder'

assert_rc 1 'a non-40-character chain base is rejected' -- bash "$compose" \
    --template issue-lead --worktree "$repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high --yolo --chain-base short

bad_repo="$tmp/bad-repo"
make_repo "$bad_repo" 'skills= path='"$root"$'/agentkit/skills\n<PASTE bad contract data>'
assert_rc 1 'surviving PASTE placeholders fail closed' -- bash "$compose" \
    --template issue-lead --worktree "$bad_repo" --issue 136 --branch feat/issue-136 \
    --worker-model gpt-5.6-luna --worker-effort high

finish
