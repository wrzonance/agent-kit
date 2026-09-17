#!/usr/bin/env bash
# Boundary regression: implementation role is independent of model/nesting support.
set -uo pipefail
TEST_NAME=worker-leaf-contract
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
# shellcheck source=lib/token-estimate.sh
source "$here/lib/token-estimate.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
skills="$root/agentkit/skills"
compose="$skills/parallel-issues/scripts/compose-worker-prompt.sh"
mkdir -p "$repo/.agent"
git -C "$repo" init -q
printf '%s\n' 'AGENT_REPO_SLUG=example/repo' 'AGENT_BASE_BRANCH=main' \
    'AGENT_CMD_TEST=tests/test.sh' > "$repo/.agent/config.env"
printf "skills= path=%s\nharness= name=codex trailer=\"Codex <noreply@openai.com>\"\ntools= spawn=multi_agent_v1__spawn_agent wait=multi_agent_v1__wait_agent send=multi_agent_v1__send_input list='ALL_TOOLS.filter(t=>/multi_agent_v1__/.test(t.name)).map(t=>t.name)'\n" \
    "$skills" > "$repo/.agent/env-contract.txt"
printf '%s\n' none > "$repo/.agent/prior-art.txt"

for model in gpt-5.6-luna gpt-5.6-terra gpt-6-astra claude-sonnet-5 claude-opus-5; do
    for scenario in scope-escape ambiguity environment-failure; do
        case $scenario in
            scope-escape) requirement='Implementation needs a sibling path and nested workers.' ;;
            ambiguity) requirement='Two incompatible API meanings require root clarification.' ;;
            environment-failure) requirement='The declared runner cannot access its legitimate cache.' ;;
        esac
        printf '%s\n' "$requirement" > "$repo/.agent/spec.txt"
        prompt=$("$compose" --template issue-lead --boundary private-trusted \
            --worktree "$repo" --issue 730 --branch feat/issue-730 \
            --write-set 'src/**' --worker-model "$model" --worker-effort high)
        assert_contains "$prompt" 'Role: implementation-worker (leaf)' "$model/$scenario declares the leaf role"
        assert_contains "$prompt" 'even when the harness supports nesting' "$model/$scenario role survives nesting support"
        assert_contains "$prompt" 'Do not dispatch, delegate, review other agents, poll CI, or manage PR/board state' "$model/$scenario excludes root work"
        assert_contains "$prompt" 'Scope-limited investigation and correction remain authorized' "$model/$scenario preserves legitimate work"
        assert_contains "$prompt" 'enforcement=prompt-only' "$model/$scenario discloses unproven enforcement"
        assert_contains "$prompt" "$requirement" "$model/$scenario preserves complete requirements"
        assert_contains "$prompt" "$repo" "$model/$scenario preserves the absolute worktree"
        assert_contains "$prompt" 'src/**' "$model/$scenario preserves ownership"
        assert_contains "$prompt" '--cmd test' "$model/$scenario preserves declared verification"
        assert_contains "$prompt" 'needs-paths:' "$model/$scenario preserves scope expansion"
        assert_contains "$prompt" 'genuine ambiguity' "$model/$scenario preserves ambiguity escalation"
        assert_contains "$prompt" 'Environment-refusal fallback' "$model/$scenario preserves publication refusal"
        assert_contains "$prompt" 'History freeze' "$model/$scenario preserves pushed history"
        assert_contains "$prompt" "worker_model='$model'" "$model/$scenario never substitutes the declared model"
        assert_contains "$prompt" 'worker-result=ABSOLUTE_PATH' "$model/$scenario preserves #729 handback"
        assert_contains "$prompt" 'When the assigned CI failure does not reproduce locally' "$model/$scenario requires remote evidence"
        assert_contains "$prompt" 'ci-artifacts.sh' "$model/$scenario names REST evidence helper"
        assert_contains "$prompt" '0 files changed' "$model/$scenario requires zero-change evidence disclosure"
        assert_not_contains "$prompt" 'nesting is blocked by the' "$model/$scenario does not infer role from harness limits"
        bytes=$(printf '%s' "$prompt" | wc -c)
        printf 'variant-evidence model=%s scenario=%s prompt-bytes=%s estimated-tokens=%s runtime-tokens=unavailable correctness=synthetic-contract-only\n' \
            "$model" "$scenario" "$bytes" "$(estimate_tokens "$bytes")"
    done
done

for role in worker implementation-worker issue-lead pr-fix-batch fix-batch; do
    context=$(jq -nc --arg cwd "$repo" --arg role "$role" \
        '{cwd:$cwd,agent_type:$role,model:"nesting-capable-model"}' |
        "$root/agentkit/hooks/subagent-start.sh" | jq -r '.hookSpecificOutput.additionalContext // ""')
    assert_contains "$context" 'implementation-worker (leaf)' "$role receives role-specific context"
    assert_contains "$context" 'agent-run.sh' "$role receives verification interface"
    assert_contains "$context" 'worktree-commit.sh' "$role retains commit interface"
    assert_contains "$context" 'worker-result.sh' "$role retains structured handback"
    assert_contains "$context" 'prompt-only' "$role does not claim a hook tool denial"
    for forbidden in triage-issues.sh move-github-project-item.sh gh-pr-state.sh bootstrap-repo.sh plugins/cache; do
        assert_not_contains "$context" "$forbidden" "$role omits root interface $forbidden"
    done
    bytes=$(printf '%s' "$context" | wc -c)
    printf 'injection-evidence role=%s context-bytes=%s estimated-tokens=%s runtime-tokens=unavailable\n' \
        "$role" "$bytes" "$(estimate_tokens "$bytes")"
done
for role in Explore reviewer waiter general-purpose ''; do
    context=$(jq -nc --arg cwd "$repo" --arg role "$role" '{cwd:$cwd,agent_type:$role}' |
        "$root/agentkit/hooks/subagent-start.sh" | jq -r '.hookSpecificOutput.additionalContext // ""')
    assert_not_contains "$context" 'implementation-worker (leaf)' "$role is not assigned an implementation role"
    assert_not_contains "$context" 'triage-issues.sh' "$role does not inherit root orchestration"
done
# A partial/older package must not advertise an unavailable #729 writer.
mkdir -p "$tmp/older/hooks/lib" "$tmp/older/skills/.shared/scripts"
cp "$root/agentkit/hooks/subagent-start.sh" "$tmp/older/hooks/"
cp "$root/agentkit/hooks/lib/guard-curriculum.sh" "$tmp/older/hooks/lib/"
context=$(jq -nc --arg cwd "$repo" '{cwd:$cwd,agent_type:"worker"}' |
    "$tmp/older/hooks/subagent-start.sh" | jq -r '.hookSpecificOutput.additionalContext // ""')
assert_contains "$context" 'implementation-worker (leaf)' 'older package retains the leaf boundary'
assert_not_contains "$context" '.shared/scripts/worker-result.sh' 'older package does not advertise a missing result writer'
# shellcheck disable=SC2016  # Positional arguments expand in the child Bash.
assert_rc 0 'basename sourcing preserves the root curriculum after extraction' -- \
    bash -c 'cd "$1" && source guard-lib.sh && guard_curriculum "$2" >/dev/null' \
    _ "$root/agentkit/hooks/lib" "$skills"
finish
