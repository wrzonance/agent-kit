#!/usr/bin/env bash
# Suite: the preflight skills-path contract and its single fallback resolver.
# shellcheck disable=SC2016  # resolver text is intentionally literal
set -uo pipefail

TEST_NAME='skills-contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skills="$root/agentkit/skills"
preflight="$skills/.shared/scripts/agent-preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p "$repo"
git -C "$repo" init -q
out=$("$preflight" --worktree "$repo" --no-write 2>/dev/null)
skills_line=$(grep '^skills=' <<< "$out")
assert_eq '1' "$(grep -c '^skills=' <<< "$out")" \
    'preflight emits exactly one skills contract line'
assert_eq "$skills" "${skills_line#skills= path=}" \
    'the contract path is the installed skills tree'
path_is_absolute=no
if [[ ${skills_line#skills= path=} == /* ]]; then
    path_is_absolute=yes
fi
assert_eq 'yes' "$path_is_absolute" \
    'the contract path is absolute'

packaged="$tmp/plugin/agentkit/skills"
mkdir -p "$packaged/.shared/scripts"
cp -- "$preflight" "$packaged/.shared/scripts/agent-preflight.sh"
chmod +x "$packaged/.shared/scripts/agent-preflight.sh"
packaged_out=$("$packaged/.shared/scripts/agent-preflight.sh" --worktree "$repo" --no-write 2>/dev/null)
assert_contains "$packaged_out" "skills= path=$packaged" \
    'a packaged preflight reports its packaged skills tree'

resolver_matches=$(find "$skills" -type f -name SKILL.md -exec grep -Hn 'agentkit=\$(find ' {} + || true)
resolver_lines=$(printf '%s\n' "$resolver_matches" | grep -c . || true)
assert_eq '1' "$resolver_lines" \
    'the skill tree keeps exactly one literal fallback resolver'

for skill in "$skills"/*/SKILL.md; do
    name=$(basename "$(dirname "$skill")")
    assert_contains "$(<"$skill")" 'skills= path=' \
        "$name documents the contract field"
    if [[ $name == onboard-repo ]]; then
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '1' "$resolver_count" \
            "$name owns the sole fallback resolver"
    else
        resolver_count=$(grep -c 'agentkit=\$(find ' "$skill" || true)
        assert_eq '0' "$resolver_count" \
            "$name does not repeat the fallback resolver"
    fi
done

onboard="$skills/onboard-repo/SKILL.md"
onboard_text=$(<"$onboard")
assert_contains "$onboard_text" 'AGENTS.md' \
    'onboarding reviews the repository instruction files'
assert_contains "$onboard_text" 'CLAUDE.md' \
    'onboarding includes the other common instruction file'
assert_contains "$onboard_text" 'untrusted data' \
    'instruction-file content is treated as repository data'
assert_contains "$onboard_text" 'Conflicting' \
    'onboarding classifies conflicting guidance'
assert_contains "$onboard_text" 'Duplicated' \
    'onboarding classifies duplicated guidance'
assert_contains "$onboard_text" 'Repo-specific' \
    'onboarding preserves repository-specific guidance'
assert_contains "$onboard_text" 'discover equivalents' \
    'onboarding discovers equivalent instruction files beyond the examples'
assert_contains "$onboard_text" 'proposed diff' \
    'onboarding emits a proposed diff'
assert_contains "$onboard_text" 'must not delete, rewrite' \
    'onboarding prohibits deleting or rewriting instruction files'
assert_contains "$onboard_text" 'explicitly retained' \
    'onboarding retains repository-specific guidance'

assert_line_order() {
    local label=$1 first=$2 second=$3
    if [[ -n $first && -n $second && $first -lt $second ]]; then
        printf 'ok - %s\n' "$label"
    else
        printf 'not ok - %s\n' "$label" >&2
        exit 1
    fi
}

step_two_line=$(grep -m1 -n '^## Step 2 ' "$onboard" | cut -d: -f1)
review_line=$(grep -m1 -in 'review existing instructions' "$onboard" | cut -d: -f1)
write_line=$(grep -m1 -n '^"\$shared/bootstrap-repo\.sh"$' "$onboard" | cut -d: -f1)
audit_approval_line=$(grep -m1 -n 'explicitly approved onboarding pass' "$onboard" | cut -d: -f1)
write_approval_line=$(grep -m1 -n 'approved the proposed onboarding additions' "$onboard" | cut -d: -f1)
conflicting_line=$(grep -m1 -n '^- \*\*Conflicting\*\*' "$onboard" | cut -d: -f1)
duplicated_line=$(grep -m1 -n '^- \*\*Duplicated\*\*' "$onboard" | cut -d: -f1)
repo_specific_line=$(grep -m1 -n '^- \*\*Repo-specific\*\*' "$onboard" | cut -d: -f1)

assert_line_order 'instruction review precedes the config write section' \
    "$review_line" "$step_two_line"
assert_line_order 'approval-gated review precedes the non-dry-run bootstrap write' \
    "$review_line" "$write_line"
assert_line_order 'the config write section precedes the non-dry-run bootstrap write' \
    "$step_two_line" "$write_line"
assert_line_order 'the audit demands an explicitly approved pass before Step 2' \
    "$audit_approval_line" "$step_two_line"
assert_line_order 'user approval of the additions precedes the non-dry-run bootstrap write' \
    "$write_approval_line" "$write_line"
assert_line_order 'Conflicting is classified before Duplicated' \
    "$conflicting_line" "$duplicated_line"
assert_line_order 'Duplicated is classified before Repo-specific' \
    "$duplicated_line" "$repo_specific_line"

review_skill="$skills/review-remote-pr/SKILL.md"
parallel_skill="$skills/parallel-issues/SKILL.md"
assert_contains "$(<"$review_skill")" 'jq is not installed; evidence unavailable' \
    'review recipes name jq parser failures as unavailable evidence'
assert_contains "$(<"$review_skill")" 'python3 is not installed; evidence unavailable' \
    'review recipes name python3 parser failures as unavailable evidence'
assert_contains "$(<"$parallel_skill")" 'jq is not installed; evidence unavailable' \
    'parallel recipes name jq parser failures as unavailable evidence'
assert_contains "$(<"$parallel_skill")" 'issue_payload_file="$worktree/.agent/fetched-issue.json"' \
    'parallel fetch persists raw issue bytes before parsing'
review_wait_contract=$(<"$review_skill")
assert_contains "$review_wait_contract" 'A wait must never spend model turns.' \
    'review skill states the no-model-turn wait rule'
assert_contains "$review_wait_contract" 'claude-adversarial-review.sh … > verdict.json' \
    'review wait rule names the blocking adversarial helper'
assert_contains "$review_wait_contract" 'gh-pr-state.sh --wait-ci --rounds N --interval S' \
    'review wait rule names the blocking CI helper'
assert_contains "$review_wait_contract" 'adversarial max-duration-seconds' \
    'review wait rule names the adversarial duration bound'
assert_contains "$review_wait_contract" 'CI round cap' \
    'review wait rule names the CI round bound'
assert_contains "$review_wait_contract" 'runner completion marker' \
    'review wait rule names the runner completion bound'
assert_contains "$review_wait_contract" 'A `sleep N` + re-check issued as its own tool call is churn' \
    'review wait rule rejects sleep and re-check tool churn'
assert_eq '' "$(grep -nE '^[[:space:]]*sleep[[:space:]]+[0-9]' "$review_skill" || true)" \
    'review skill has no sleep polling recipe'
step3=$(sed -n '/^## Step 3 (Phase B)/,/^## Step 4:/p' "$review_skill")
assert_contains "$step3" 'Never run `gh pr ready`' \
    'Step 3 keeps the ready transition as a user-only action'
assert_contains "$step3" 'bounded blocking re-check rounds' \
    'Step 3 bounds CodeRabbit rate-limit re-checks'
assert_contains "$step3" '~10 minutes each' \
    'Step 3 gives each rate-limit re-check round a ten-minute bound'
assert_contains "$step3" '~90 minutes total' \
    'Step 3 caps the total rate-limit wait'
assert_contains "$step3" 'one blocking helper/harness wait' \
    'Step 3 keeps rate-limit polling turn-free'
assert_contains "$step3" 'Never trigger a review' \
    'Step 3 never triggers a provider review while retrying'
assert_not_contains "$step3" 'stop and escalate to the user rather than spending turns on repeated checks' \
    'Step 3 does not escalate immediately on a rate limit'
assert_contains "$(<"$review_skill")" 'blocked check and must never be summarized as “no findings.”' \
    'review Step 5 treats missing parsers as blocked checks'

finish
