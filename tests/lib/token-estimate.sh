# shellcheck shell=bash
# Shared token estimator: `bytes / 4`, the same coarse heuristic every static
# token-budget surface in this repo relies on (tests/lint-skill-size.sh's
# SKILL.md body gate, bench/tier0.sh's resident/reachable/dispatched-template
# accounting). Extracted so the two surfaces share one function and one
# constant rather than each carrying its own copy of the divisor -- a
# divergence here would let the lint gate and the benchmark silently disagree
# about the same bytes.
#
# Source this file; do not execute it directly.

# TOKEN_ESTIMATE_BYTES_PER_TOKEN: bytes assumed to encode roughly one token
# under this repo's static (no-tokenizer) estimate. Not a measured constant
# for any particular model -- a cheap, deterministic proxy good enough to
# gate context budgets and compare Tier-0 token surfaces across commits.
readonly TOKEN_ESTIMATE_BYTES_PER_TOKEN=4

# estimate_tokens BYTES -- prints the estimated token count for BYTES bytes
# (integer division, rounded down, matching the historical inline
# `$((bytes / 4))` both callers used before this extraction).
estimate_tokens() {
    local bytes=$1
    [[ $bytes =~ ^(0|[1-9][0-9]*)$ ]] || {
        printf 'estimate_tokens: BYTES must be a non-negative decimal integer: %s\n' "$bytes" >&2
        return 1
    }
    printf '%d\n' "$((bytes / TOKEN_ESTIMATE_BYTES_PER_TOKEN))"
}
