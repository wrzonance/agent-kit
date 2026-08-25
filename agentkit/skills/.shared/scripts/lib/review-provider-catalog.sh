#!/usr/bin/env bash
# Single source of review-provider capabilities and canonical identities.

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
