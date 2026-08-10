#!/usr/bin/env bash
# Suite: cross-provider review consent is disclosed and session-scoped.
set -uo pipefail

TEST_NAME='cross-provider-consent'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

skill="$root/agentkit/skills/review-remote-pr/SKILL.md"
readme="$root/README.md"
skill_text=$(cat -- "$skill")
readme_text=$(cat -- "$readme")

assert_not_contains "$skill_text" 'standing authorization for this cross-model review' \
    'repository ownership is not standing authorization'
assert_contains "$skill_text" 'Cross-provider consent — first send per session' \
    'the skill has a dedicated cross-provider consent gate'
assert_contains "$skill_text" 'Repository ownership' \
    'the gate rejects ownership as consent'
assert_contains "$skill_text" 'is not consent to disclose' \
    'the gate states ownership does not authorize disclosure'
assert_contains "$skill_text" 'destination provider' \
    'the disclosure names the destination provider'
assert_contains "$skill_text" 'first cross-provider send in a session' \
    'the gate applies before the first send in a session'
# shellcheck disable=SC2016  # the backticks are literal documentation text
assert_contains "$skill_text" 'record `cross_provider_consent=<provider>;scope=PR-diff;status=granted`' \
    'approval is recorded to avoid nuisance re-prompts'
assert_contains "$skill_text" 'Do not send the diff' \
    'missing or declined consent fails closed'
assert_contains "$readme_text" 'Cross-provider review privacy' \
    'README contains user-facing cross-provider disclosure'
assert_contains "$readme_text" 'Repository ownership is not' \
    'README warns that ownership does not authorize transfer'

finish
