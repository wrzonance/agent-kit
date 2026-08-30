#!/usr/bin/env bash
# argv_rewrite_flag -- alias one argv flag spelling to another before a
# script's own option-parsing loop runs.
#
# WHY THIS EXISTS (issue #556)
#   The kit's helpers converged on two canonical flags: --repo OWNER/REPO for
#   a repository slug, and --repo-root DIR for a checkout path. A root that
#   has just called one helper with the canonical spelling should never be
#   punished by the next helper still expecting an older one --
#   move-github-project-item.sh accepted only --repository, and agent-run.sh
#   accepted only --dir, each forcing a wasted turn at the moment a caller is
#   holding several fresh worktrees. This is the shared primitive a helper
#   sources to accept its older spelling as a silent alias, instead of
#   hand-duplicating a second case-statement branch (and risking the same
#   drift the next time someone copies that helper as a starting point).

# argv_rewrite_flag ALIAS CANONICAL ARGV...
# Prints ARGV, NUL-terminated, with every bare ALIAS token rewritten to
# CANONICAL. A flag's own paired value (the token after it) is left alone, and
# so is CANONICAL itself if the caller already used it. Nothing after a
# literal "--" end-of-options marker is touched -- those tokens belong to a
# wrapped/passthrough command, never to the caller's own option parsing.
#
# Read the result back with a NUL-delimited loop, e.g.:
#   mapfile -d '' -t args < <(argv_rewrite_flag --repository --repo "$@")
#   set -- "${args[@]}"
argv_rewrite_flag() {
    local alias_flag=$1 canonical_flag=$2 token stopped=0
    shift 2
    for token in "$@"; do
        if ((stopped)); then
            printf '%s\0' "$token"
        elif [[ $token == -- ]]; then
            stopped=1
            printf '%s\0' "$token"
        elif [[ $token == "$alias_flag" ]]; then
            printf '%s\0' "$canonical_flag"
        else
            printf '%s\0' "$token"
        fi
    done
}
