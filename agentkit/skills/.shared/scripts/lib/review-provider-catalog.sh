#!/usr/bin/env bash
# Single source of review-provider capabilities and canonical identities.

# Provider-specific identities, in display order. Names outside this list use
# the generic observe-only defaults when they match the declaration grammar.
#
# Not `readonly`: this file is sourced more than once within a single process
# in practice (the pr-to-green transition engine sources it directly, then again
# transitively through provider-identity.sh), and a `readonly` array
# assignment errors on a second source the way redefining a function does not.
REVIEW_PROVIDER_NAMES=(coderabbit github-code-quality none)

review_provider_names() {
    local out='' name
    for name in "${REVIEW_PROVIDER_NAMES[@]}"; do
        out+="${out:+, }$name"
    done
    printf '%s\n' "$out"
}

review_provider_name_valid() {
    [[ ${1:-} =~ ^[a-z][a-z0-9-]*$ && $1 != coderabbitai ]]
}

review_provider_login_alias_reserved() {
    case ${1,,} in
        coderabbitai|github-code-quality) return 0 ;;
        *) return 1 ;;
    esac
}

review_provider_known() {
    case ${1:-} in
        coderabbit|github-code-quality|none) return 0 ;;
        *) return 1 ;;
    esac
}

review_provider_override_login() {
    local provider=$1 suffix key value
    suffix=${provider^^}
    suffix=${suffix//-/_}
    key=AGENT_REVIEW_PROVIDER_${suffix}_LOGIN
    value=${!key-}
    [[ -n $value && $value =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]{0,37}[A-Za-z0-9])?$ ]] || return 1
    review_provider_login_alias_reserved "$value" && return 1
    printf '%s\n' "${value,,}"
}

review_provider_mode() {
    case ${1:-} in
        coderabbit) printf '%s\n' triggerable ;;
        github-code-quality) printf '%s\n' observe-only ;;
        none) printf '%s\n' disabled ;;
        *) review_provider_name_valid "${1:-}" && printf '%s\n' observe-only || return 1 ;;
    esac
}

review_provider_lifecycle() {
    case ${1:-} in
        coderabbit) printf '%s\n' reply-settlement ;;
        github-code-quality) printf '%s\n' provider-rescan ;;
        none) printf '%s\n' disabled ;;
        *) review_provider_name_valid "${1:-}" && printf '%s\n' generic-settlement || return 1 ;;
    esac
}

review_provider_login() {
    case ${1:-} in
        coderabbit) printf '%s\n' coderabbitai ;;
        github-code-quality) printf '%s\n' github-code-quality ;;
        none) printf '%s\n' none ;;
        *)
            review_provider_name_valid "${1:-}" || return 1
            review_provider_override_login "$1" 2>/dev/null || printf '%s\n' "$1"
            ;;
    esac
}

review_provider_from_login() {
    local login=${1,,} provider expected bot_suffix=0
    local -a declared_providers=()
    case $login in
        coderabbitai|coderabbitai\[bot\]) printf '%s\n' coderabbit ;;
        github-code-quality|github-code-quality\[bot\]) printf '%s\n' github-code-quality ;;
        *)
            [[ $login == *'[bot]' ]] && bot_suffix=1
            login=${login%\[bot\]}
            IFS=, read -r -a declared_providers <<< "${AGENT_REVIEW_PROVIDERS:-}"
            for provider in "${declared_providers[@]}"; do
                review_provider_name_valid "$provider" || continue
                expected=$(review_provider_login "$provider" 2>/dev/null) || continue
                [[ $login == "$expected" ]] || continue
                printf '%s\n' "$provider"
                return 0
            done
            ((bot_suffix)) || return 1
            review_provider_name_valid "$login" || return 1
            [[ $login != none ]] || return 1
            printf '%s\n' "$login"
            ;;
    esac
}

review_provider_lane() {
    review_provider_name_valid "${1:-}" || return 1
    review_provider_known "$1" && return 1
    printf '%s\n' generic-automated
}

review_provider_request_marker() {
    case ${1:-} in
        coderabbit) printf '%s\n' '<!-- pr-to-green:provider-request provider=coderabbit -->' ;;
        *) return 1 ;;
    esac
}

review_provider_request() {
    case ${1:-} in
        coderabbit) printf '%s\n' '@coderabbitai full review' ;;
        *) return 1 ;;
    esac
}
