#!/usr/bin/env bash
# Shared repository trunk resolution. A declaration wins; origin/HEAD is the
# only fallback. Callers decide whether their local evidence is sufficient.

shared_trunk_branch() {
    local root=$1 branch
    branch=$(sed -n 's/^[[:space:]]*AGENT_BASE_BRANCH[[:space:]]*=[[:space:]]*//p
                    /^[[:space:]]*AGENT_BASE_BRANCH[[:space:]]*=/q' \
        "$root/.agent/config.env" 2>/dev/null | tr -d '\r')
    branch=${branch%%[[:space:]]*}
    if [[ -z $branch ]]; then
        branch=$(git -C "$root" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) || true
        branch=${branch#origin/}
    fi
    [[ -n $branch ]] || return 1
    printf '%s' "$branch"
}

shared_declared_trunk_branch() {
    local root=$1 branch
    branch=$(sed -n 's/^[[:space:]]*AGENT_BASE_BRANCH[[:space:]]*=[[:space:]]*//p
                    /^[[:space:]]*AGENT_BASE_BRANCH[[:space:]]*=/q' \
        "$root/.agent/config.env" 2>/dev/null | tr -d '\r')
    branch=${branch%%[[:space:]]*}
    [[ -n $branch ]] || return 1
    printf '%s' "$branch"
}

shared_is_trunk_branch() {
    local branch=$1 root=${2:-} trunk
    [[ -n $root ]] || return 1
    trunk=$(shared_trunk_branch "$root") || return 1
    [[ $branch == "$trunk" ]]
}
