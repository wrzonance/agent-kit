#!/usr/bin/env bash
# Unknown forge bots stay in the generic automated lane regardless of declaration.
set -uo pipefail

TEST_NAME='review-provider-classification'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

classifier="$root/agentkit/skills/review-remote-pr/scripts/classify-author.sh"
author='{"login":"chatgpt-codex-connector[bot]","type":"Bot"}'

out=$(printf '%s\n' "$author" | "$classifier")
assert_contains "$out" '"lane":"generic-automated"' \
    'an undeclared unknown bot uses the generic automated lane'

out=$(AGENT_REVIEW_PROVIDERS=chatgpt-codex-connector \
    bash -c 'printf "%s\n" "$1" | "$2"' bash "$author" "$classifier")
assert_contains "$out" '"lane":"generic-automated"' \
    'declaring an unknown provider does not grant the known-provider lane'

finish
