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
names_out=$(catalog_call review_provider_names '')
assert_eq 'coderabbit, github-code-quality, none' "$names_out" \
    'review_provider_names lists every accepted provider identity'
for provider in coderabbit github-code-quality none; do
    assert_contains "$names_out" "$provider" \
        "review_provider_names names $provider as accepted"
done
assert_eq observe-only "$(catalog_call review_provider_mode chatgpt-codex-connector)" \
    'a syntactically valid unknown provider is observe-only'
assert_eq generic-settlement "$(catalog_call review_provider_lifecycle chatgpt-codex-connector)" \
    'an unknown provider uses generic settlement'
assert_eq chatgpt-codex-connector \
    "$(catalog_call review_provider_login chatgpt-codex-connector)" \
    'an unknown provider defaults its login to its declared name'
assert_eq chatgpt-codex-connector \
    "$(AGENT_REVIEW_PROVIDERS=chatgpt-codex-connector \
        catalog_call review_provider_from_login chatgpt-codex-connector)" \
    'an unknown provider login round-trips without a bot suffix'
assert_eq chatgpt-codex-connector \
    "$(catalog_call review_provider_from_login 'chatgpt-codex-connector[bot]')" \
    'an unknown provider login round-trips with a bot suffix'
# shellcheck disable=SC2016 # The inner shell expands its own positional parameter.
assert_rc 1 'an unknown provider has no request marker' -- bash -c \
    'source "$1"; review_provider_request_marker chatgpt-codex-connector' bash "$catalog"
assert_eq codex-review-bot "$(AGENT_REVIEW_PROVIDERS=chatgpt-codex-connector \
    AGENT_REVIEW_PROVIDER_CHATGPT_CODEX_CONNECTOR_LOGIN=codex-review-bot \
    catalog_call review_provider_login chatgpt-codex-connector)" \
    'a declared unknown provider accepts an explicit login override'
assert_eq chatgpt-codex-connector "$(AGENT_REVIEW_PROVIDERS=chatgpt-codex-connector \
    AGENT_REVIEW_PROVIDER_CHATGPT_CODEX_CONNECTOR_LOGIN=codex-review-bot \
    catalog_call review_provider_from_login 'codex-review-bot[bot]')" \
    'an explicit login override round-trips to its declared provider'
for alias in coderabbitai CodeRabbitAI github-code-quality GITHUB-CODE-QUALITY; do
    # shellcheck disable=SC2016 # The inner shell expands its own positional parameters.
    assert_rc 1 "reserved login alias $alias is rejected by the catalog override boundary" -- \
        env AGENT_REVIEW_PROVIDER_CHATGPT_CODEX_CONNECTOR_LOGIN="$alias" \
        bash -c 'source "$1"; review_provider_override_login chatgpt-codex-connector' bash "$catalog"
done
# shellcheck disable=SC2016 # The inner shell expands its own positional parameter.
assert_rc 1 'a built-in login alias cannot become an implicit generic provider name' -- bash -c \
    'source "$1"; review_provider_mode coderabbitai' bash "$catalog"
# shellcheck disable=SC2016 # The inner shell expands its own positional parameter.
assert_rc 1 'an undeclared human-shaped login is not promoted to a provider' -- bash -c \
    'source "$1"; review_provider_from_login ordinary-human' bash "$catalog"
# shellcheck disable=SC2016 # The inner shell expands its own positional parameter.
assert_rc 1 'malformed provider names have no capability entry' -- bash -c \
    'source "$1"; review_provider_mode X-1' bash "$catalog"

finish
