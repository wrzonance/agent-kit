#!/usr/bin/env bash
# Contract coverage for the one-spend adversarial-review receipt.
# shellcheck disable=SC2016  # literal recipe placeholders are assertion data
set -uo pipefail

TEST_NAME='adversarial-review-receipt'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

review="$root/agentkit/skills/review-remote-pr/SKILL.md"
parallel="$root/agentkit/skills/parallel-issues/SKILL.md"
review_text=$(<"$review")
parallel_text=$(<"$parallel")

assert_receipt_contract() {
    local text=$1 label=$2 section normalized
    section=$(awk '/^### Adversarial-review receipt:/{capture=1; next} capture && /^### /{exit} capture{print}' <<<"$text")
    normalized=$(tr '\n' ' ' <<<"$section" | tr -s '[:space:]' ' ')

    assert_contains "$section" 'adversarial-review:spent' "$label has the stable spent marker"
    assert_contains "$section" 'This was written agentically; verify its assertions:' "$label has the attribution banner"
    assert_contains "$section" 'provider' "$label records the reviewer provider"
    assert_contains "$section" 'model' "$label records the reviewer model"
    assert_contains "$section" 'effort' "$label records the reviewer effort"
    assert_contains "$section" 'cross-provider' "$label records cross-provider mode"
    assert_contains "$section" 'blind fallback' "$label records blind fallback mode"
    assert_contains "$section" 'confirmed finding' "$label records confirmed findings"
    assert_contains "$section" 'P1' "$label records severity counts"
    assert_contains "$section" 'fix commit' "$label records fix commit SHAs"
    assert_contains "$section" 'decline rationale' "$label records decline rationale"
    assert_contains "$section" 'verified-skip rationale' "$label records verified skip rationale"
    assert_contains "$section" 'gh-comment.sh' "$label uses the integrity-checked comment helper"
    assert_contains "$section" '--body-file' "$label uses a body file"
    assert_contains "$normalized" 'after fixes are pushed' "$label orders receipt after fixes"
    assert_contains "$normalized" 'before draft-phase-complete handoff' "$label orders receipt before handoff"

    template=$(awk '/^cat >"\$receipt_body" <<\x27EOF\x27$/{capture=1; next} capture && /^EOF$/{exit} capture{print}' <<<"$section")
    marker_count=$(grep -o -- '<!-- adversarial-review:spent -->' <<<"$template" | wc -l | tr -d ' ')
    assert_eq '1' "$marker_count" "$label receipt template has exactly one marker"
}

assert_receipt_contract "$review_text" 'review-remote-pr receipt'
assert_receipt_contract "$parallel_text" 'parallel-issues receipt'

assert_contains "$review_text" 'pr_${PR}_issue_comments.json' \
    'review-remote-pr checks fetched PR comments before launch'
assert_contains "$review_text" 'do not rerun' \
    'review-remote-pr marker precheck prevents double spend'
assert_contains "$review_text" 'no-silent-skip' \
    'review-remote-pr receipt contract rejects silent skips'
assert_contains "$parallel_text" 'pr_${PR}_issue_comments.json' \
    'parallel-issues checks fetched PR comments before launch'
assert_contains "$parallel_text" 'do not rerun' \
    'parallel-issues marker precheck prevents double spend'
assert_contains "$parallel_text" 'no-silent-skip' \
    'parallel-issues receipt contract rejects silent skips'

finish
