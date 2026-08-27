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
assert_contains "$flat" 'Steps 2–4) may run in parallel across independent' \
    'ready-transition, provider trigger, and finding settlement run in parallel across independent roots'
assert_contains "$flat" "Step 5's" 'merge/retarget sequence stays strictly serial in queue order'
assert_contains "$flat" 'critical section' \
    'the shared confirmed-queue snapshot rewrite is a serialized critical section'
assert_contains "$flat" 'only one root inside it at a time' \
    'concurrent roots never interleave the pr-queue.sh/authorize-queue.sh re-run sequence'
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
    invokers=$(rg -l 'review-transition\.sh' "$skills" \
        --glob '!pr-to-green/scripts/review-transition.sh' \
        --glob '!**/parallel-issues/references/worker-prompts.md' || true)
    assert_eq "$skill" "$invokers" 'only pr-to-green invokes the transition engine'
else
    invokers=$(grep -rl 'review-transition\.sh' "$skills" 2>/dev/null |
        grep -v '/pr-to-green/scripts/review-transition\.sh$' |
        grep -v '/parallel-issues/references/worker-prompts\.md$' || true)
    assert_eq "$skill" "$invokers" 'only pr-to-green invokes the transition engine (grep fallback: rg unavailable)'
fi

assert_contains "$text" '--auto-merge' 'frontmatter and flags table document the auto-merge flag'
assert_contains "$text" 'merge-gate.sh' 'coordinator delegates the pre-merge review-completion gate'
assert_contains "$text" 'merge-pr.sh' 'coordinator delegates the verified serial merge'
assert_contains "$text" 'move-github-project-item.sh' 'coordinator delegates the post-merge board move'
assert_contains "$text" 'auto-merge.md' 'coordinator points auto-merge detail at its reference file'
assert_contains "$flat" 'strict serial merge ordering' 'auto-merge implies strict serial merge ordering'
assert_contains "$flat" 'branch-protection refusal is' 'branch protection refusal is a named stop, never a bypass'

assert_eq yes "$(test -f "$skills/pr-to-green/references/auto-merge.md" && printf yes || printf no)" \
    'auto-merge reference file exists'
ref_text=$(cat "$skills/pr-to-green/references/auto-merge.md")
ref_flat=$(tr '\n' ' ' <<<"$ref_text" | tr -s '[:space:]' ' ')
assert_contains "$ref_text" '## Contents' 'auto-merge reference carries a Contents heading within the TOC scan window'
assert_contains "$ref_text" 'code-scanning n/a' \
    'auto-merge reference states unreadable code-scanning is never treated as zero findings'
assert_contains "$ref_text" 'never carries forward' \
    'auto-merge reference states a passed gate never carries forward to a new head'
assert_contains "$ref_text" 'concurrency-cap.sh' \
    'the parallel-issues concurrency-cap.sh helper is the sole cap source, never invented'
assert_contains "$ref_flat" 'releases its slot immediately' \
    'a failed or blocked root releases its concurrency slot rather than holding it idle'
assert_contains "$ref_text" 're-derive the authorization for its own PR at its own current head' \
    'a root entering the critical section re-derives its own authorization, never reuses a prior pass'
assert_contains "$ref_flat" 'every other in-flight root revalidates its own head and base' \
    'a Step 5 merge forces every other in-flight root to revalidate before its next mutation'

assert_eq yes "$(test -x "$skills/pr-to-green/scripts/pr-queue.sh" && printf yes || printf no)" \
    'queue helper ships executable'
assert_eq yes "$(test -x "$skills/pr-to-green/scripts/review-transition.sh" && printf yes || printf no)" \
    'transition helper ships executable'
assert_eq yes "$(test -x "$skills/pr-to-green/scripts/merge-gate.sh" && printf yes || printf no)" \
    'merge gate helper ships executable'
assert_eq yes "$(test -x "$skills/pr-to-green/scripts/merge-pr.sh" && printf yes || printf no)" \
    'merge helper ships executable'
# shellcheck disable=SC2016 # Backticks are expected Markdown bytes.
assert_contains "$readme_text" '`pr-to-green` skill' 'root capability inventory lists the coordinator'
assert_contains "$readme_text" 'ships four skills' 'root inventory count includes the coordinator'

finish
