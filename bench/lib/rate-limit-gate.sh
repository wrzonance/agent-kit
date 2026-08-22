#!/usr/bin/env bash
# bench/lib/rate-limit-gate.sh -- "Board work runs against GraphQL, which is
# the scarce pool. The harness gates each trial on `gh api rate_limit` and
# pauses rather than failing mid-run" (design doc, "The repository under
# test"). Mirrors this repo's own github-api-budget rule: GraphQL is the
# pool to protect, REST is comparatively plentiful, and the response to low
# quota is "wait for reset," never "abort the trial."
#
# This file only decides; it never sleeps itself. A decision function that
# also called `sleep` would be untestable without a real multi-minute wait,
# so graphql_rate_limit_gate prints its decision and the caller
# (bench/run-trial.sh) is the one that acts on a `pause` line -- see that
# script's own gate step.
#
# Source this file; do not execute it directly.

# graphql_rate_limit_gate [--gh-bin BIN] [--min-remaining N] [--now EPOCH]
#
# Queries `BIN api rate_limit` (default gh) for the GraphQL pool's
# (remaining, reset) pair. Prints exactly one line to stdout:
#   proceed remaining=R reset=T
#   pause remaining=R reset=T wait_seconds=W
# and returns 0 in both cases -- low quota is an ordinary, expected trial
# state, not an error. Returns 1 only when the gh call itself fails (a
# harder failure than "the pool is dry": network, auth, or a broken gh
# invocation), with the diagnosis on stderr.
#
# --now lets a test pin "the current time" instead of calling `date +%s`, so
# wait_seconds is a deterministic, assertable number.
graphql_rate_limit_gate() {
    local gh_bin=gh min_remaining=200 now=''
    while (($#)); do
        case $1 in
            --gh-bin)
                gh_bin=$2
                shift 2
                ;;
            --min-remaining)
                min_remaining=$2
                shift 2
                ;;
            --now)
                now=$2
                shift 2
                ;;
            *)
                printf 'graphql_rate_limit_gate: unknown argument: %s\n' "$1" >&2
                return 1
                ;;
        esac
    done
    [[ $min_remaining =~ ^[0-9]+$ ]] || {
        printf 'graphql_rate_limit_gate: --min-remaining must be a non-negative integer: %s\n' "$min_remaining" >&2
        return 1
    }
    [[ -z $now || $now =~ ^[0-9]+$ ]] || {
        printf 'graphql_rate_limit_gate: --now must be a Unix epoch integer: %s\n' "$now" >&2
        return 1
    }
    [[ -n $now ]] || now=$(date -u +%s)

    local response
    response=$("$gh_bin" api rate_limit --jq '"\(.resources.graphql.remaining) \(.resources.graphql.reset)"' 2>&1) || {
        printf 'graphql_rate_limit_gate: gh api rate_limit failed: %s\n' "$response" >&2
        return 1
    }

    local remaining reset
    read -r remaining reset <<< "$response"
    [[ $remaining =~ ^[0-9]+$ && $reset =~ ^[0-9]+$ ]] || {
        printf 'graphql_rate_limit_gate: could not parse remaining/reset from gh output: %s\n' "$response" >&2
        return 1
    }

    if ((remaining >= min_remaining)); then
        printf 'proceed remaining=%d reset=%d\n' "$remaining" "$reset"
        return 0
    fi

    local wait_seconds=$((reset - now))
    ((wait_seconds > 0)) || wait_seconds=0
    printf 'pause remaining=%d reset=%d wait_seconds=%d\n' "$remaining" "$reset" "$wait_seconds"
    return 0
}
