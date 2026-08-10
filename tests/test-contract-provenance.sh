#!/usr/bin/env bash
# Suite: repository-supplied environment contracts cannot redirect skill helpers.
# shellcheck disable=SC2016  # grep pattern intentionally contains literal shell syntax
set -uo pipefail

TEST_NAME='contract-provenance'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

for skill in "$root"/agentkit/skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill")")
    text=$(<"$skill")
    reads=$(grep -c 'agentkit=$(sed -n "s/\\^skills= path=' "$skill" || true)
    guards=$(grep -c 'git ls-files --error-unmatch -- .agent/env-contract.txt' "$skill" || true)
    assert_contains "$text" '! -L .agent/env-contract.txt' \
        "$name rejects symlinked contracts"
    assert_contains "$text" '-O .agent/env-contract.txt' \
        "$name rejects foreign-owned contracts"
    assert_contains "$text" 'git ls-files --error-unmatch -- .agent/env-contract.txt' \
        "$name rejects tracked contracts"
    if (( guards >= reads )); then
        assert_eq yes yes "$name guards every direct contract path read"
    else
        assert_eq "$reads" "$guards" "$name guards every direct contract path read"
    fi
done

finish
