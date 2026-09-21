#!/usr/bin/env bash
# A workflow skill read without a delivered challenge is reference material,
# while an active delivery keeps every mechanical gate intact.
# shellcheck disable=SC2016 # literal Markdown backticks are intentional.
set -uo pipefail

TEST_NAME='reference-use contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
reference_heading='No delivered challenge = no run'
reference_trigger='If no `agentkit` activation challenge or `agentkit durable activation` context was delivered in this conversation'
reference_authority='Reference use carries **none** of the workflow'
reference_forbidden='Do not run kit helpers that write, touch `.agent/`, onboard/bootstrap/refresh, merge, flip ready, trigger review bots, resolve threads or move board items'

for workflow in review-remote-pr pr-to-green parallel-issues onboard-repo; do
    step_zero=$(awk '
        /^## Step 0 prerequisite:/ { in_step_zero = 1 }
        in_step_zero && /^## / && !/^## Step 0 prerequisite:/ { exit }
        in_step_zero { print }
    ' "$skills/$workflow/SKILL.md")
    step_zero_flat=$(tr '\n' ' ' <<<"$step_zero" | tr -s '[:space:]' ' ')
    assert_contains "$step_zero_flat" "$reference_heading" \
        "$workflow puts the reference-use clause directly in Step 0"
    assert_contains "$step_zero_flat" "$reference_trigger" \
        "$workflow keys reference use to challenge delivery"
    assert_contains "$step_zero_flat" "$reference_authority" \
        "$workflow gives reference use no workflow authority"
    assert_contains "$step_zero_flat" "$reference_forbidden" \
        "$workflow preserves the complete helper-write prohibition"
done

assert_contains "$(<"$skills/review-remote-pr/SKILL.md")" \
    'This resolver fence applies only inside a delivered workflow run.' \
    'the review skill scopes its resolver fence to a delivered run'
assert_eq 2 "$(grep -Fxc '# This resolver fence applies only inside a delivered workflow run.' \
    "$skills/review-remote-pr/references/grooming.md")" \
    'both grooming resolver fences are scoped to a delivered run'

activation="$skills/.shared/scripts/workflow-activation.sh"
for prompt in \
    '"review remote PR 42"' \
    'Do not resume parallel-issues' \
    'Resume parallel-issues?'; do
    classified=$(jq -cn --arg prompt "$prompt" '{prompt:$prompt}' | "$activation" classify)
    assert_eq '' "$classified" "ambiguous prompt does not deliver a challenge: $prompt"
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
git -C "$tmp" init -q repo
for action in ack check; do
    rc=0
    out=$("$activation" "$action" --repo-root "$repo" --session reference-use \
        --skill review-remote-pr 2>&1) || rc=$?
    assert_eq 1 "$rc" "$action without a receipt keeps its refusal exit code"
    assert_contains "$out" 'no challenge was delivered in this session, so no workflow run exists; reference use needs no activation' \
        "$action without a receipt explains the reference-use path"
done

preflight_help=$("$skills/.shared/scripts/agent-preflight.sh" --help)
assert_contains "$preflight_help" 'for onboarding or an active run only' \
    'preflight scopes its repair hint to onboarding or an active run'

finish
