#!/usr/bin/env bash
# Single source of review-provider capabilities and canonical identities.

# Canonical accepted provider identities, in display order. Every function in
# this file recognizes exactly these values; review_provider_names() is what
# a rejection message names instead of leaving a caller to read this file.
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

review_provider_mode() {
    case ${1:-} in
        coderabbit) printf '%s\n' triggerable ;;
        github-code-quality) printf '%s\n' observe-only ;;
        none) printf '%s\n' disabled ;;
        *) return 1 ;;
    esac
}

review_provider_lifecycle() {
    case ${1:-} in
        coderabbit) printf '%s\n' reply-settlement ;;
        github-code-quality) printf '%s\n' provider-rescan ;;
        none) printf '%s\n' disabled ;;
        *) return 1 ;;
    esac
}

review_provider_login() {
    case ${1:-} in
        coderabbit) printf '%s\n' coderabbitai ;;
        github-code-quality) printf '%s\n' github-code-quality ;;
        none) printf '%s\n' none ;;
        *) return 1 ;;
    esac
}

review_provider_from_login() {
    case ${1,,} in
        coderabbitai|coderabbitai\[bot\]) printf '%s\n' coderabbit ;;
        github-code-quality|github-code-quality\[bot\]) printf '%s\n' github-code-quality ;;
        *) return 1 ;;
    esac
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
