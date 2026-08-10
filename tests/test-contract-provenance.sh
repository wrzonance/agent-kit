#!/usr/bin/env bash
# Suite: repository-supplied environment contracts cannot redirect skill helpers.
# shellcheck disable=SC2016  # patterns intentionally contain literal shell syntax
set -uo pipefail

TEST_NAME='contract-provenance'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

for skill in "$root"/agentkit/skills/*/SKILL.md; do
    name=$(basename "$(dirname "$skill")")
    text=$(<"$skill")
    assert_contains "$text" '! -L $contract' \
        "$name rejects symlinked contracts"
    assert_contains "$text" '-O $contract' \
        "$name rejects foreign-owned contracts"
    assert_contains "$text" 'git -C "$contract_root" ls-files --error-unmatch -- .agent/env-contract.txt' \
        "$name rejects tracked contracts, anchored to the repository root"

    # A sed/grep line inside any fenced block that takes the bare relative
    # path as an operand bypasses both the provenance guards and the
    # repository-root anchoring -- with or without command substitution.
    bypass=$(awk '
        /^[[:space:]]*```/ { inblock = !inblock; next }
        inblock && /(^|[^[:alnum:]_])(sed|grep)[^#]*\.agent\/env-contract\.txt/ { printf "line %d\n", FNR }
    ' "$skill")
    assert_eq '' "$bypass" "$name never reads the contract by its unanchored literal path"

    # Every sed/grep line that touches the validated $contract path -- the
    # skills-path resolver, the onboarding contract probe, and AGENT_TRAILER
    # assignments, quoted or not, in command substitution or not -- must sit
    # in a fenced block that also carries the symlink, ownership, and
    # tracked-file guards, so no read is reachable without provenance
    # validation.
    unguarded=$(awk '
        function flush() {
            if (has_read && (block !~ /! -L \$contract/ || block !~ /-O \$contract/ ||
                 block !~ /git -C "\$contract_root" ls-files --error-unmatch -- \.agent\/env-contract\.txt/))
                printf "unguarded contract read in block ending line %d\n", FNR
            block = ""; has_read = 0
        }
        /^[[:space:]]*```/ { if (inblock) flush(); inblock = !inblock; next }
        inblock {
            block = block $0 "\n"
            if ($0 ~ /(^|[^[:alnum:]_])(sed|grep)[^#]*\$\{?contract([^[:alnum:]_]|$)/) has_read = 1
        }
        END { if (inblock) flush() }
    ' "$skill")
    assert_eq '' "$unguarded" "$name guards every direct contract read"

    reads=$(awk '
        /^[[:space:]]*```/ { inblock = !inblock; next }
        inblock && /(^|[^[:alnum:]_])(sed|grep)[^#]*\$\{?contract([^[:alnum:]_]|$)/ { n++ }
        END { print n + 0 }
    ' "$skill")
    if (( reads > 0 )); then
        assert_eq yes yes "$name reads the contract only through the validated path ($reads sites)"
    else
        assert_eq 'some' 'none' "$name has no validated contract reads at all"
    fi
done

finish
