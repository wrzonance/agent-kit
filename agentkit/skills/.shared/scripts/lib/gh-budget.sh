#!/usr/bin/env bash
# Shared GitHub API budget helpers: every gh-authenticated tool on this user shares
# the hourly REST and GraphQL pools (agent-kit#475); `gh api rate_limit` is exempt.
# Source this file, then call:
#   gh_budget_snapshot [GH_BIN]
#       Prints one line: "rest=R/L reset=ISO graphql=R/L reset=ISO" on stdout.
#       Returns 1 (prints nothing) if the rate_limit endpoint is unavailable.
#   gh_budget_is_exhausted ERROR_TEXT
#       Returns 0 when ERROR_TEXT names a primary or secondary rate-limit
#       refusal, 1 otherwise. Pure text match -- makes no network call.
#   gh_budget_reset_for_error ERROR_TEXT [GH_BIN]
#       When gh_budget_is_exhausted matches, prints the ISO-8601 reset time for
#       the pool the error names and returns 0; returns 1 otherwise.
# Rate-limited callers exit GH_BUDGET_RATE_LIMIT_EXIT (default 3), not 1.

GH_BUDGET_RATE_LIMIT_EXIT=${GH_BUDGET_RATE_LIMIT_EXIT:-3}

gh_budget_snapshot() {
    local gh_bin=${1:-gh} raw
    raw=$("$gh_bin" api rate_limit 2>/dev/null) || return 1
    jq -r '
        "rest=" + (.resources.core.remaining | tostring) + "/" + (.resources.core.limit | tostring)
        + " reset=" + (.resources.core.reset | todate)
        + " graphql=" + (.resources.graphql.remaining | tostring) + "/" + (.resources.graphql.limit | tostring)
        + " reset=" + (.resources.graphql.reset | todate)
    ' <<<"$raw" 2>/dev/null || return 1
}

gh_budget_is_exhausted() {
    local err=${1:-}
    [[ $err == *'API rate limit exceeded'* || $err == *'rate limit exceeded'* || $err == *'secondary rate limit'* ]]
}

gh_budget_reset_for_error() {
    local err=${1:-} gh_bin=${2:-gh} raw pool=core
    gh_budget_is_exhausted "$err" || return 1
    raw=$("$gh_bin" api rate_limit 2>/dev/null) || return 1
    [[ $err == *[Gg]raph[Qq][Ll]* ]] && pool=graphql
    jq -r --arg pool "$pool" '.resources[$pool].reset | todate' <<<"$raw" 2>/dev/null || return 1
}
