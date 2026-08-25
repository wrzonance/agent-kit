#!/usr/bin/env bash
# Capability registry contract shared by resolver, transition, and replies.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='review provider catalog'

catalog="$root/agentkit/skills/.shared/scripts/lib/review-provider-catalog.sh"
assert_eq yes "$(test -f "$catalog" && printf yes || printf no)" \
    'provider capability catalog exists'

catalog_call() {
    local function=$1 provider=$2
    bash -c 'source "$1"; "$2" "$3"' bash "$catalog" "$function" "$provider"
}

assert_eq triggerable "$(catalog_call review_provider_mode coderabbit)" \
    'CodeRabbit is catalogued as triggerable'
assert_eq observe-only "$(catalog_call review_provider_mode github-code-quality)" \
    'Code Quality is catalogued as observe-only'
assert_eq disabled "$(catalog_call review_provider_mode none)" \
    'none is catalogued as disabled'
assert_eq reply-settlement "$(catalog_call review_provider_lifecycle coderabbit)" \
    'CodeRabbit owns reply settlement lifecycle'
assert_eq provider-rescan "$(catalog_call review_provider_lifecycle github-code-quality)" \
    'Code Quality owns rescan lifecycle'
assert_eq coderabbitai "$(catalog_call review_provider_login coderabbit)" \
    'catalog owns the CodeRabbit mention identity'
assert_contains "$(catalog_call review_provider_request coderabbit)" '@coderabbitai full review' \
    'catalog owns the only triggerable request body'
# shellcheck disable=SC2016 # The inner shell expands its own positional parameter.
assert_rc 1 'unknown providers have no capability entry' -- bash -c \
    'source "$1"; review_provider_mode unexpected' bash "$catalog"

finish
