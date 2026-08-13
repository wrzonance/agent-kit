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

shared_protected_pattern() {
    local candidate=${1//\\//} root=${2:-} declared=${3:-} nested=${4:-1} pattern
    local -a patterns=("${SHARED_PROTECTED_DEFAULTS[@]}")
    candidate=${candidate#./}
    [[ -z $root || $candidate != "$root"/* ]] || candidate=${candidate#"$root"/}
    if [[ -n $declared ]]; then
        local IFS=,
        local -a extra
        read -r -a extra <<< "$declared"
        patterns+=("${extra[@]}")
    fi
    for pattern in "${patterns[@]}"; do
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
