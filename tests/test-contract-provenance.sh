#!/usr/bin/env bash
# Suite: repository-supplied environment contracts cannot redirect skill helpers.
# shellcheck disable=SC2016  # patterns intentionally contain literal shell syntax
set -uo pipefail

TEST_NAME='contract-provenance'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

# The complete executed guard: matching its halves separately would accept a
# fence whose only mention of them is a helper path plus a comment.
FULL_GUARD='[ -d "${agentkit:-}/.shared/scripts" ] && [ "${agentkit_provenance:-}" = ok ]'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

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
    # in a fenced block that either carries the symlink, ownership, and
    # tracked-file guards itself, or carries the resolver-guard line proving
    # it depends on the single Step 0 resolver definition (pinned separately,
    # once per skill, by the assertions above) having been prepended first.
    # This is the single-source convention: the provenance checks live once,
    # every other consuming block just guards that they already ran.
    # The guard-message exemption below proves only that $agentkit resolved --
    # it says nothing about a $contract this block re-derives for itself. A
    # block that locally assigns contract=/contract_root= (the AGENT_TRAILER
    # pattern) must still carry the full provenance checks even when the
    # guard-message string is also present, or a fresh unvalidated read could
    # hide behind a guard that validates a different variable.
    unguarded=$(awk -v GUARD="$FULL_GUARD" '
        function flush() {
            full_checks = (block ~ /! -L \$contract/ && block ~ /-O \$contract/ &&
                block ~ /git -C "\$contract_root" ls-files --error-unmatch -- \.agent\/env-contract\.txt/)
            guard_only = (block ~ /agentkit unresolved: prepend the Step 0 resolver block/ &&
                index(block, GUARD) > 0)
            local_redefine = (block ~ /(^|[^[:alnum:]_])contract(_root)?=[^=]/)
            if (has_read && !full_checks && (!guard_only || local_redefine))
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

reader="$root/agentkit/skills/.shared/scripts/contract-read.sh"
assert_eq yes "$([[ -x $reader ]] && printf yes || printf no)" \
    'contract-read.sh is an executable shared helper'

for consumer in \
    "$root/agentkit/skills/onboard-repo/SKILL.md" \
    "$root/agentkit/skills/review-remote-pr/SKILL.md" \
    "$root/agentkit/skills/parallel-issues/SKILL.md" \
    "$root/agentkit/skills/parallel-issues/references/worker-prompts.md" \
    "$root/agentkit/hooks/stop.sh" \
    "$root/agentkit/hooks/lib/guard-lib.sh"; do
    assert_contains "$(<"$consumer")" 'contract-read.sh' \
        "$(basename "$consumer") consumes contract-read.sh"
done

guard_text=$(<"$root/agentkit/hooks/lib/guard-lib.sh")
assert_contains "$guard_text" '-r $file' \
    'the hook predicate requires a readable contract'

valid_repo="$tmp/valid"
mkdir -p "$valid_repo/.agent"
git -C "$valid_repo" init -q
printf '%s\n' \
    'skills= path=/tmp/installed/agentkit/skills' \
    'repo=example-org/example-repo' \
    'base=develop source=refs/remotes/origin/HEAD' \
    'harness= name=codex trailer="Codex <noreply@openai.com>" other=claude' \
    > "$valid_repo/.agent/env-contract.txt"

value=''
rc=0
value=$("$reader" --repo-root "$valid_repo" --get skills.path) || rc=$?
assert_eq 0 "$rc" 'trusted contract allows skills.path reads'
assert_eq '/tmp/installed/agentkit/skills' "$value" 'skills.path is read from the contract'
value=$("$reader" --repo-root "$valid_repo" --get harness.trailer)
assert_eq 'Codex <noreply@openai.com>' "$value" 'harness.trailer is read from the contract'
value=$("$reader" --repo-root "$valid_repo" --get harness.trailer --worker-model gpt-5.6-luna)
assert_eq 'Codex gpt-5.6-luna <noreply@openai.com>' "$value" \
    'worker-model substitution is performed by the helper'
value=$("$reader" --repo-root "$valid_repo" --get harness.name)
assert_eq codex "$value" 'harness.name is read from the contract'
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'example-org/example-repo' "$value" 'repo.slug is read from the contract'
value=$("$reader" --repo-root "$valid_repo" --get base.branch)
assert_eq develop "$value" 'base.branch is read from the contract'
assert_rc 2 'an unknown contract key is a usage error' -- \
    "$reader" --repo-root "$valid_repo" --get missing.key
assert_rc 2 'an unsafe worker model is rejected' -- \
    "$reader" --repo-root "$valid_repo" --get harness.trailer --worker-model 'bad model'

missing_repo="$tmp/missing"
mkdir -p "$missing_repo"
git -C "$missing_repo" init -q
assert_rc 3 'an absent contract is distinguished from an untrusted one' -- \
    "$reader" --repo-root "$missing_repo" --get repo.slug

tracked_repo="$tmp/tracked"
mkdir -p "$tracked_repo/.agent"
git -C "$tracked_repo" init -q
cp -- "$valid_repo/.agent/env-contract.txt" "$tracked_repo/.agent/env-contract.txt"
git -C "$tracked_repo" add -- .agent/env-contract.txt
assert_rc 4 'a tracked contract is untrusted' -- \
    "$reader" --repo-root "$tracked_repo" --get repo.slug

symlink_repo="$tmp/symlink"
mkdir -p "$symlink_repo/.agent"
git -C "$symlink_repo" init -q
ln -s -- "$valid_repo/.agent/env-contract.txt" "$symlink_repo/.agent/env-contract.txt"
assert_rc 4 'a symlinked contract is untrusted' -- \
    "$reader" --repo-root "$symlink_repo" --get repo.slug

# The hook and helper must return the same trust decision for the same file.
# Source the hook library after its structural assertions so this remains a
# boundary test, not a test of a copied predicate in the suite itself.
# shellcheck source=../agentkit/hooks/lib/guard-lib.sh
source "$root/agentkit/hooks/lib/guard-lib.sh"
if guard_contract_is_ours "$valid_repo/.agent/env-contract.txt" "$valid_repo"; then
    guard_valid=yes
else
    guard_valid=no
fi
if guard_contract_is_ours "$tracked_repo/.agent/env-contract.txt" "$tracked_repo"; then
    guard_tracked=yes
else
    guard_tracked=no
fi
if guard_contract_is_ours "$symlink_repo/.agent/env-contract.txt" "$symlink_repo"; then
    guard_symlink=yes
else
    guard_symlink=no
fi
assert_eq yes "$guard_valid" 'hook predicate accepts the same trusted contract'
assert_eq no "$guard_tracked" 'hook predicate rejects the same tracked contract'
assert_eq no "$guard_symlink" 'hook predicate rejects the same symlinked contract'

finish
