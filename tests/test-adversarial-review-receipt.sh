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
    section=$(awk '
        /^### Adversarial-review receipt:/{capture=1; next}
        capture && /^```/{fenced=!fenced; print; next}
        capture && !fenced && /^#{1,6} /{exit}
        capture{print}
    ' <<<"$text")
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

    # The full resolver (agentkit=, contract_root=, the trusted skills-path
    # read) is single-sourced in Step 0 under the new convention -- this
    # publication block instead carries the two-line guard that fails loudly
    # unless the Step 0 resolver was prepended first.
    assert_contains "$section" '${agentkit:-}/.shared/scripts' "$label publication guards against a missing resolver"
    assert_contains "$section" 'agentkit unresolved: prepend the Step 0 resolver block' "$label publication fails loudly without the resolver"
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

parallel_section=$(awk '
    /^### Adversarial-review receipt:/{capture=1; next}
    capture && /^```/{fenced=!fenced; print; next}
    capture && !fenced && /^#{1,6} /{exit}
    capture{print}
' <<<"$parallel_text")
parallel_bash_blocks=$(grep -c '^```bash$' <<<"$parallel_section" || true)
assert_eq '2' "$parallel_bash_blocks" \
    'parallel-issues separates precheck and publication into two fenced blocks'
assert_contains "$parallel_section" ': "${RUN_DIR:?re-set RUN_DIR' \
    'parallel-issues precheck guards RUN_DIR'
assert_contains "$parallel_section" ': "${PR:?re-set PR' \
    'parallel-issues precheck guards PR'
precheck_block=$(awk '/^```bash$/{block++; next} block == 1 && /^```$/{exit} block == 1{print}' <<<"$parallel_section")
assert_not_contains "$precheck_block" 'receipt_body=' \
    'parallel-issues precheck cannot fall through to receipt publication'
assert_not_contains "$precheck_block" 'gh-comment.sh' \
    'parallel-issues precheck cannot publish a receipt'
publication_block=$(awk '/^```bash$/{block++; next} block == 2 && /^```$/{exit} block == 2{print}' <<<"$parallel_section")
assert_contains "$publication_block" 'gh-comment.sh' \
    'parallel-issues publication block posts the receipt'
assert_contains "$publication_block" '${agentkit:-}/.shared/scripts' \
    'parallel-issues publication block guards a missing resolver'
assert_contains "$publication_block" 'agentkit unresolved: prepend the Step 0 resolver block' \
    'parallel-issues publication block fails loudly without the resolver'

review_section=$(awk '
    /^### Adversarial-review receipt:/{capture=1; next}
    capture && /^```/{fenced=!fenced; print; next}
    capture && !fenced && /^#{1,6} /{exit}
    capture{print}
' <<<"$review_text")
review_publication_block=$(awk '/^```bash$/{block++; next} block == 1 && /^```$/{exit} block == 1{print}' <<<"$review_section")
assert_contains "$review_publication_block" '${agentkit:-}/.shared/scripts' \
    'review-remote-pr publication block guards a missing resolver'
assert_contains "$review_publication_block" 'agentkit unresolved: prepend the Step 0 resolver block' \
    'review-remote-pr publication block fails loudly without the resolver'

receipt_line=$(grep -n '^### Adversarial-review receipt:' "$review" | cut -d: -f1)
phase_b_line=$(grep -n '^## Step 3 (Phase B):' "$review" | cut -d: -f1)
if [[ $receipt_line =~ ^[0-9]+$ && $phase_b_line =~ ^[0-9]+$ && $receipt_line -lt $phase_b_line ]]; then
    _pass 'review-remote-pr receipt is before the Phase B handoff'
else
    _fail 'review-remote-pr receipt is before the Phase B handoff' \
        "receipt line=${receipt_line:-missing}, phase-b line=${phase_b_line:-missing}"
fi

finish
