#!/usr/bin/env bash
# Shared protected-path policy. Consumers add repository declarations; this
# file owns the defaults so the hook and commit helper cannot drift.

readonly SHARED_PROTECTED_DEFAULTS=(
    '.github/workflows/'
    '.gitlab-ci.yml'
    '.circleci/'
    'azure-pipelines.yml'
    'Jenkinsfile'
    '.githooks/'
    '.git/hooks/'
    '.git/config'
    '.pre-commit-config.yaml'
    '.codex/config.toml'
    '.claude/settings.json'
    '.claude/settings.local.json'
)

# The CI-workflow subset of SHARED_PROTECTED_DEFAULTS. A session-ledger
# `authorize:workflow-mutations` grant may authorize a commit staging one of
# THESE paths (issue #563); it must never widen to harness/hook configuration
# -- those keep parking even under a covering grant (issue #563 F1
# adversarial-review fix).
readonly SHARED_CI_WORKFLOW_PATTERNS=(
    '.github/workflows/'
    '.gitlab-ci.yml'
    '.circleci/'
    'azure-pipelines.yml'
    'Jenkinsfile'
)

# A concrete protected commit is approved by its complete staged tree, not by
# path names alone. The fixed decision token prevents callers from substituting
# a broader decision; the scope binds unchanged bytes across resume.
# shellcheck disable=SC2034  # public constant consumed by sourcing commit helpers
readonly SHARED_PROTECTED_COMMIT_DECISION='authorize:protected-commit'
readonly SHARED_PROTECTED_SCOPE_PREFIX='protected-tree:'

shared_protected_commit_scope() {
    local base=$1 tree=$2
    [[ $base =~ ^[0-9a-f]{40}$ || $base =~ ^[0-9a-f]{64}$ ]] || return 1
    [[ $tree =~ ^[0-9a-f]{40}$ || $tree =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s%s:%s' "$SHARED_PROTECTED_SCOPE_PREFIX" "$base" "$tree"
}

# CANDIDATE against each remaining PATTERN argument, in NESTED mode. Prints
# the first match and returns 0, or returns 1. Shared by shared_protected_pattern
# and shared_ci_workflow_pattern so the two never drift on how a pattern matches.
_shared_pattern_match() {
    local candidate=$1 nested=$2 pattern
    shift 2
    for pattern in "$@"; do
        pattern=${pattern#./}
        [[ -n $pattern ]] || continue
        if [[ $pattern == */ ]]; then
            if ((nested)); then
                [[ $candidate == "$pattern"* || $candidate == *"/$pattern"* ]] || continue
            else
                [[ $candidate == "$pattern"* ]] || continue
            fi
        else
            if ((nested)); then
                [[ $candidate == "$pattern" || $candidate == *"/$pattern" ]] || continue
            else
                [[ $candidate == "$pattern" ]] || continue
            fi
        fi
        printf '%s' "$pattern"
        return 0
    done
    return 1
}

shared_protected_pattern() {
    local candidate=${1//\\//} root=${2:-} declared=${3:-} nested=${4:-1}
    local -a patterns=("${SHARED_PROTECTED_DEFAULTS[@]}")
    candidate=${candidate#./}
    [[ -z $root || $candidate != "$root"/* ]] || candidate=${candidate#"$root"/}
    if [[ -n $declared ]]; then
        local IFS=,
        local -a extra
        read -r -a extra <<< "$declared"
        patterns+=("${extra[@]}")
    fi
    _shared_pattern_match "$candidate" "$nested" "${patterns[@]}"
}

# Like shared_protected_pattern, but restricted to the fixed CI-workflow
# subset and NEVER extended by a repository's AGENT_PROTECTED_PATHS
# declaration: a session-ledger authorize:workflow-mutations grant may only
# ever authorize one of these paths, regardless of what a repo additionally
# protects (issue #563 F1).
shared_ci_workflow_pattern() {
    local candidate=${1//\\//} root=${2:-} nested=${3:-1}
    candidate=${candidate#./}
    [[ -z $root || $candidate != "$root"/* ]] || candidate=${candidate#"$root"/}
    _shared_pattern_match "$candidate" "$nested" "${SHARED_CI_WORKFLOW_PATTERNS[@]}"
}
