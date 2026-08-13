#!/usr/bin/env bash
# Contract coverage for the one-spend adversarial-review receipt.
#
# The receipt/precheck RECIPE (exact heredoc shape, marker rendering, field
# placeholders, transport) now lives in scripts/post-receipt.sh and is pinned
# by tests/test-post-receipt.sh. This suite keeps only what the skill prose
# must still say (the WHAT: the gate exists, its ordering, its no-silent-skip
# guarantee, and that it delegates to post-receipt.sh) -- not how that script
# renders or posts the body.
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

    assert_contains "$section" 'post-receipt.sh' "$label delegates rendering/posting to post-receipt.sh"
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
    assert_contains "$normalized" 'after fixes are pushed' "$label orders receipt after fixes"
    assert_contains "$normalized" 'before draft-phase-complete handoff' "$label orders receipt before handoff"

    # Every other script invocation in this tree is gated by the identical
    # two-line guard (see e.g. every gh-pr-state.sh call site) -- expect
    # post-receipt.sh's invocation to follow the same house convention rather
    # than re-deriving the full resolver inline.
    assert_contains "$section" '${agentkit:-}/.shared/scripts' "$label publication guards against a missing resolver"
    assert_contains "$section" 'agentkit unresolved: prepend the Step 0 resolver block' "$label publication fails loudly without the resolver"
    # The directory check alone passes on a stale inherited value; the sentinel
    # is what proves the Step 0 resolver actually ran.
    assert_contains "$section" '${agentkit_provenance:-}' "$label publication requires the provenance sentinel"
}

assert_receipt_contract "$review_text" 'review-remote-pr receipt'
assert_receipt_contract "$parallel_text" 'parallel-issues receipt'

# -- the precheck gate: still mandated, still delegates to the script --------

assert_contains "$review_text" 'post-receipt.sh precheck' \
    'review-remote-pr precheck delegates to post-receipt.sh precheck'
assert_contains "$review_text" 'pr_${PR}_issue_comments.json' \
    'review-remote-pr checks fetched PR comments before launch'
assert_contains "$review_text" 'do not rerun' \
    'review-remote-pr marker precheck prevents double spend'
assert_contains "$review_text" 'no-silent-skip' \
    'review-remote-pr receipt contract rejects silent skips'

assert_contains "$parallel_text" 'post-receipt.sh precheck' \
    'parallel-issues precheck delegates to post-receipt.sh precheck'
assert_contains "$parallel_text" 'pr_${PR}_issue_comments.json' \
    'parallel-issues checks fetched PR comments before launch'
assert_contains "$parallel_text" 'do not rerun' \
    'parallel-issues marker precheck prevents double spend'
assert_contains "$parallel_text" 'no-silent-skip' \
    'parallel-issues receipt contract rejects silent skips'

# -- publish delegates to post-receipt.sh publish -----------------------

assert_contains "$review_text" 'post-receipt.sh publish' \
    'review-remote-pr publication delegates to post-receipt.sh publish'
assert_contains "$parallel_text" 'post-receipt.sh publish' \
    'parallel-issues publication delegates to post-receipt.sh publish'

# The old markdown-structural anti-fallthrough check (two separate fenced
# blocks, with assertions that block 1 could not reach gh-comment.sh) pinned
# a safety property the SKILL.md recipe used to own by hand. post-receipt.sh
# publish now owns that property directly -- it runs its own precheck and
# refuses (exit 11) before ever rendering or posting when the marker is
# already present. See test-post-receipt.sh: "publish refuses when already
# spent" and "publish never calls gh-comment.sh when the receipt is already
# spent" for the stronger, code-level replacement of this coverage.

receipt_line=$(grep -n '^### Adversarial-review receipt:' "$review" | cut -d: -f1)
phase_b_line=$(grep -n '^## Step 3 (Phase B):' "$review" | cut -d: -f1)
if [[ $receipt_line =~ ^[0-9]+$ && $phase_b_line =~ ^[0-9]+$ && $receipt_line -lt $phase_b_line ]]; then
    _pass 'review-remote-pr receipt is before the Phase B handoff'
else
    _fail 'review-remote-pr receipt is before the Phase B handoff' \
        "receipt line=${receipt_line:-missing}, phase-b line=${phase_b_line:-missing}"
fi

finish
