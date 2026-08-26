#!/usr/bin/env bash
# Shared GitHub API budget helpers. Every `gh`-authenticated tool on this
# machine (and every other machine authenticated as the same user) shares two
# hourly pools -- REST ("core") and GraphQL -- so a caller that never looks
# before it spends can silently starve every other concurrent session
# (agent-kit#475). This library gives callers two things: a snapshot line for
# a preflight display, and a way to turn a bare "API rate limit exceeded"
# error string into a reset time so a hard failure is at least informative.
#
# `gh api rate_limit` is itself exempt from the limit it reports, so reading
# it never spends the budget it is measuring.
#
# Source this file, then call:
#   gh_budget_snapshot [GH_BIN]
#       Prints one line: "rest=R/L reset=ISO graphql=R/L reset=ISO" on stdout.
#       Returns 1 (prints nothing) if the rate_limit endpoint is unavailable.
#   gh_budget_is_exhausted ERROR_TEXT
#       Returns 0 when ERROR_TEXT names a primary or secondary rate-limit
#       refusal, 1 otherwise. Pure text match -- makes no network call.
#   gh_budget_reset_for_error ERROR_TEXT [GH_BIN]
#       When gh_budget_is_exhausted matches, prints the ISO-8601 reset time
#       for the pool the error names (GraphQL if the text mentions it,
#       REST/core otherwise) and returns 0. Returns 1 on a non-matching error
#       or an unavailable rate_limit read (prints nothing either way).
#
# Callers that want a distinct exit code for a rate-limited failure should
# use GH_BUDGET_RATE_LIMIT_EXIT (default 3) rather than the script's normal
# usage/API-failure exit (1) -- see gh-pr-state.sh's die_on_gh_failure and
# pr-queue.sh's equivalent.

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
