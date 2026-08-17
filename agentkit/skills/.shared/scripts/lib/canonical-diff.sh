#!/usr/bin/env bash
# Shared canonical PR-diff rendering for consent and adversarial review.

canonical_diff() {
    local base_ref=${1:-}
    [[ -n $base_ref ]] || return 1
    git check-ref-format --branch "$base_ref" >/dev/null 2>&1 || return 1
    git --no-pager diff --find-renames --unified=25 "origin/$base_ref...HEAD"
}
