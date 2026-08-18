#!/usr/bin/env bash
# Contract coverage for the thin provider-aware serial coordinator.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='pr to green'

skills="$root/agentkit/skills"
skill="$skills/pr-to-green/SKILL.md"
readme_text=$(cat "$root/README.md")

assert_eq yes "$(test -f "$skill" && printf yes || printf no)" \
    'pr-to-green skill exists'
text=$(cat "$skill" 2>/dev/null || true)
flat=$(tr '\n' ' ' <<<"$text" | tr -s '[:space:]' ' ')

assert_contains "$text" 'name: pr-to-green' 'frontmatter declares the skill name'
assert_contains "$text" 'Use when' 'frontmatter is trigger-only'
assert_contains "$text" 'optional PR numbers' 'trigger accepts an optional explicit queue'
assert_contains "$text" 'review-provider-config.sh' \
    'coordinator resolves providers before queue mutation'
assert_contains "$text" 'pr-queue.sh' 'coordinator delegates queue and graph construction'
assert_contains "$text" 'review-transition.sh' \
    'coordinator delegates every ready/provider transition'
assert_contains "$text" 'review-remote-pr/SKILL.md' \
    'coordinator reuses draft normalization and review machinery'
assert_contains "$text" 'thread-action.sh' \
    'coordinator delegates reply settlement state'
assert_contains "$text" 'chain-advance.sh' \
    'coordinator delegates verified successor retargeting'
assert_contains "$flat" 'provider plan, verified dependency graph, and exact serial queue' \
    'confirmation presents every authorization input before mutation'
assert_contains "$flat" 'remediation pushes, ready transitions, and trigger-capable requests' \
    'one confirmation names its complete narrow mutation authority'
assert_contains "$text" 'strictly one PR at a time' 'queue execution is strictly serial'
assert_contains "$flat" 'Automatic discovery selects drafts' \
    'automatic queue discovery is draft-only'
assert_contains "$text" 'explicitly named ready PR' \
    'an explicit ready PR can resume an interrupted run'
assert_contains "$text" 'WAITING_FOR_MERGE' 'stack descendants wait for human merge'
assert_contains "$text" 'RETARGET_REQUIRED' 'retarget state is explicit'
assert_contains "$text" 'evidence-green' 'coordinator defines its terminal evidence state'
assert_contains "$text" 'adversarial review' 'no-provider flow retains mandatory review coverage'
assert_contains "$text" 'per-item confirmation' 'human feedback retains its item gate'
assert_contains "$flat" 'Never merge, force-push, or clean worktrees' \
    'coordinator preserves destructive-action prohibitions'
assert_not_contains "$text" '| Provider |' 'coordinator does not duplicate provider policy tables'
assert_not_contains "$text" '@coderabbitai full review' \
    'coordinator contains no raw provider trigger'
assert_not_contains "$text" 'gh pr ready' 'coordinator contains no raw ready transition'

if command -v rg >/dev/null 2>&1; then
    invokers=$(rg -l 'review-transition\.sh' "$skills" --glob '!pr-to-green/scripts/review-transition.sh' || true)
    assert_eq "$skill" "$invokers" 'only pr-to-green invokes the transition engine'
else
    invokers=$(grep -rl 'review-transition\.sh' "$skills" 2>/dev/null |
        grep -v '/pr-to-green/scripts/review-transition\.sh$' || true)
    assert_eq "$skill" "$invokers" 'only pr-to-green invokes the transition engine (grep fallback: rg unavailable)'
fi

assert_eq yes "$(test -x "$skills/pr-to-green/scripts/pr-queue.sh" && printf yes || printf no)" \
    'queue helper ships executable'
assert_eq yes "$(test -x "$skills/pr-to-green/scripts/review-transition.sh" && printf yes || printf no)" \
    'transition helper ships executable'
# shellcheck disable=SC2016 # Backticks are expected Markdown bytes.
assert_contains "$readme_text" '`pr-to-green` skill' 'root capability inventory lists the coordinator'
assert_contains "$readme_text" 'ships four skills' 'root inventory count includes the coordinator'

finish
