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

    # The resolver is a session warm-up, not a preamble pasted into every
    # command block. Each entry skill has one bounded skills-path warm-up;
    # later blocks may load the durable context because shell state is ephemeral.
    command_reads=$(awk '
        /^```bash$/ { inblock = 1; next }
        /^```$/ { inblock = 0; next }
        inblock && /contract-read\.sh/ && /--get[[:space:]]+skills\.path/ &&
            $0 !~ /^[[:space:]]*#/ &&
            $0 !~ /-(x|L|O)[^\n]*contract-read\.sh/ { n++ }
        END { print n + 0 }
    ' "$skill")
    assert_eq 1 "$command_reads" "$name has one executable contract-read warm-up"
    assert_contains "$text" '.agent/cache/contract-session.env' \
        "$name names the durable session context"
    assert_contains "$text" '"$shared/lib/contract-cache.sh" --read-session-context' \
        "$name invokes the data-only context reader from its validated shared path"
done

unsafe_context_execution=$(rg -n \
    '(eval|source)[[:space:]].*contract-session\.env|(^|[[:space:]])\.[[:space:]].*contract-session\.env' \
    "$root/agentkit" "$root/tests" 2> /dev/null || true)
assert_eq '' "$unsafe_context_execution" \
    'no skill or regression test executes session context as shell code'

reader="$root/agentkit/skills/.shared/scripts/contract-read.sh"
cache_reader="$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh"
assert_eq yes "$([[ -x $reader ]] && printf yes || printf no)" \
    'contract-read.sh is an executable shared helper'
assert_eq yes "$([[ -x $cache_reader ]] && printf yes || printf no)" \
    'contract cache data reader is an executable shared helper'

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

# Contract reads are session-hot: the first read materializes a repository-local
# snapshot, and subsequent reads can reuse it only while both source files have
# the same content digest. The snapshot itself contains no raw contract file;
# it is a small, mode-600 key/value record.
cache="$valid_repo/.agent/cache/contract-read.snapshot"
assert_eq yes "$([[ -f $cache && ! -L $cache ]] && printf yes || printf no)" \
    'the first contract read writes a regular snapshot'
assert_eq 600 "$(stat -c %a -- "$cache")" 'the contract snapshot is private'
snapshot_before=$(cat -- "$cache")
assert_contains "$snapshot_before" 'inputs_sha256=' \
    'the snapshot records a combined input digest'
assert_contains "$snapshot_before" 'repo.slug=example-org/example-repo' \
    'the snapshot records parsed contract values'
session_context="$valid_repo/.agent/cache/contract-session.env"
assert_eq yes "$([[ -f $session_context && ! -L $session_context ]] && printf yes || printf no)" \
    'the first read writes durable session context'
assert_eq 600 "$(stat -c %a -- "$session_context")" 'session context is private'
assert_contains "$(cat -- "$session_context")" 'agentkit_provenance=ok' \
    'session context records the provenance sentinel'
context_agentkit=$("$cache_reader" --read-session-context --repo-root "$valid_repo" --get agentkit)
assert_eq '/tmp/installed/agentkit/skills' "$context_agentkit" \
    'a later shell reads the resolved skills path as data'
context_root=$("$cache_reader" --read-session-context --repo-root "$valid_repo" --get contract_root)
assert_eq "$valid_repo" "$context_root" \
    'the data reader returns the canonical repository root'
mkdir -p "$valid_repo/nested/working/directory"
nested_context_root=$(cd "$valid_repo/nested/working/directory" && \
    "$cache_reader" --read-session-context --repo-root "$(git rev-parse --show-toplevel)" --get contract_root)
assert_eq "$valid_repo" "$nested_context_root" \
    'a nested working directory resolves the cache through Git top level'
session_before=$(cat -- "$session_context")

# A source digest does not authenticate a mutable cache projection. A
# same-user process can edit the cache without changing either source, so a
# cache hit must compare the requested value and session skills path to the
# live contract before returning or refreshing durable context.
sed 's/^repo.slug=example-org\/example-repo$/repo.slug=attacker\/tampered/' \
    "$cache" > "$cache.tampered"
mv -- "$cache.tampered" "$cache"
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'example-org/example-repo' "$value" \
    'a tampered cache value cannot affect contract-read output'
assert_contains "$(cat -- "$cache")" 'repo.slug=example-org/example-repo' \
    'a rejected cache value is refreshed from the live contract'
sed 's|^skills.path=/tmp/installed/agentkit/skills$|skills.path=/tmp/attacker/skills|' \
    "$cache" > "$cache.tampered"
mv -- "$cache.tampered" "$cache"
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'example-org/example-repo' "$value" \
    'a tampered cached skills path cannot affect another key output'
assert_eq '/tmp/installed/agentkit/skills' \
    "$("$cache_reader" --read-session-context --repo-root "$valid_repo" --get agentkit)" \
    'a session refresh keeps the live skills path after cache tampering'

cache_saved="$cache.saved"
mv -- "$cache" "$cache_saved"
ln -s -- "$cache_saved" "$cache"
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'example-org/example-repo' "$value" \
    'a symlinked snapshot falls back to the live contract'
assert_eq yes "$([[ -L $cache ]] && printf yes || printf no)" \
    'a symlinked snapshot is never replaced'
rm -- "$cache"
mv -- "$cache_saved" "$cache"

printf 'AGENT_REPO_SLUG=changed/example\n' > "$valid_repo/.agent/config.env"
assert_rc 75 'a config.env edit makes the lightweight loader stale' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'example-org/example-repo' "$value" \
    'a config.env change invalidates and refreshes the snapshot'
snapshot_after_config=$(cat -- "$cache")
assert_eq no "$([[ $snapshot_before == "$snapshot_after_config" ]] && printf yes || printf no)" \
    'config.env invalidates the snapshot without changing contract projection'
session_after_config=$(cat -- "$session_context")
assert_eq no "$([[ $session_before == "$session_after_config" ]] && printf yes || printf no)" \
    'config.env invalidation refreshes durable session context'
assert_eq '/tmp/installed/agentkit/skills' \
    "$("$cache_reader" --read-session-context --repo-root "$valid_repo" --get agentkit)" \
    'the expensive resolver refreshes the loader after a config.env edit'

sed 's/^repo=example-org\/example-repo$/repo=changed-org\/changed-repo/' \
    "$valid_repo/.agent/env-contract.txt" > "$valid_repo/.agent/env-contract.next"
mv -- "$valid_repo/.agent/env-contract.next" "$valid_repo/.agent/env-contract.txt"
assert_rc 75 'an env-contract edit makes the lightweight loader stale' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
value=$("$reader" --repo-root "$valid_repo" --get repo.slug)
assert_eq 'changed-org/changed-repo' "$value" \
    'an env-contract change invalidates and refreshes the snapshot'
assert_contains "$(cat -- "$cache")" 'repo.slug=changed-org/changed-repo' \
    'the refreshed snapshot contains the changed contract value'
assert_eq 'changed-org/changed-repo' \
    "$("$reader" --repo-root "$valid_repo" --get repo.slug)" \
    'the expensive resolver refreshes reads after an env-contract edit'

# The durable record is input data, never shell program text. A payload that
# would be dangerous under `source`/`eval` is rejected by schema/value checks
# and cannot create its marker file.
session_valid=$(cat -- "$session_context")
session_digest=$(sed -n 's/^contract_inputs_sha256=//p' "$session_context" | sed -n '1p')
malicious_marker="$tmp/context-payload-ran"
printf '%s\n' \
    'format=1' \
    "agentkit=\$(touch $malicious_marker)" \
    'shared=/tmp/installed/agentkit/skills/.shared/scripts' \
    'agentkit_provenance=ok' \
    "contract_root=$valid_repo" \
    "contract_inputs_sha256=$session_digest" \
    > "$session_context"
chmod 600 -- "$session_context"
assert_rc 1 'a malicious session payload is rejected as data' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
assert_eq no "$([[ -e $malicious_marker ]] && printf yes || printf no)" \
    'a malicious session payload cannot execute'
printf '%s\n' "$session_valid" > "$session_context"
chmod 600 -- "$session_context"

# Exact schema means no duplicate or unknown keys, and no control separators
# can cross the reader's tab-delimited boundary.
printf '%s\nagentkit=/tmp/installed/agentkit/skills\n' "$session_valid" > "$session_context"
chmod 600 -- "$session_context"
assert_rc 1 'a duplicate session key is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
printf '%s\nunknown=value\n' "$session_valid" > "$session_context"
chmod 600 -- "$session_context"
assert_rc 1 'an unknown session key is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
printf '%s\n' "$session_valid" > "$session_context"
chmod 600 -- "$session_context"
control_agentkit=$'/tmp/installed/agentkit/skills\001'
sed "s|^agentkit=.*$|agentkit=$control_agentkit|" "$session_context" > "$session_context.control"
mv -- "$session_context.control" "$session_context"
chmod 600 -- "$session_context"
assert_rc 1 'a control separator in a session value is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
printf '%s\n' "$session_valid" > "$session_context"
chmod 600 -- "$session_context"

session_saved="$session_context.saved"
mv -- "$session_context" "$session_saved"
ln -s /etc/hostname "$session_context"
assert_rc 1 'a symlinked session file is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
rm -- "$session_context"
mv -- "$session_saved" "$session_context"

cache_dir="$valid_repo/.agent/cache"
cache_dir_saved="$valid_repo/.agent/cache.saved"
mv -- "$cache_dir" "$cache_dir_saved"
ln -s /etc "$cache_dir"
assert_rc 1 'a symlinked or foreign cache parent is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
rm -- "$cache_dir"
mv -- "$cache_dir_saved" "$cache_dir"

agent_dir="$valid_repo/.agent"
agent_dir_saved="$valid_repo/.agent.saved"
mv -- "$agent_dir" "$agent_dir_saved"
ln -s /etc "$agent_dir"
assert_rc 1 'a symlinked .agent cache parent is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
rm -- "$agent_dir"
mv -- "$agent_dir_saved" "$agent_dir"

# The helper predicate is also used before writes; test a root-owned regular
# file directly so this does not depend on privileged chown support.
# shellcheck source=../agentkit/skills/.shared/scripts/lib/contract-cache.sh
source "$cache_reader"
if contract_cache_file_is_ours /etc/hostname "$valid_repo"; then
    foreign_cache_file=yes
else
    foreign_cache_file=no
fi
assert_eq no "$foreign_cache_file" 'a foreign-owned cache file is rejected'
git -C "$valid_repo" add -f -- .agent/cache/contract-session.env
assert_rc 1 'a tracked session file is rejected' -- \
    "$cache_reader" --read-session-context --repo-root "$valid_repo"
git -C "$valid_repo" rm --cached -q -- .agent/cache/contract-session.env

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

# "Untracked" must be something git actually established, not merely a non-zero
# exit. git reports 1 for an untracked path but 128 when the root is not a
# usable work tree (missing, or refused for dubious ownership). Treating every
# non-zero status as untracked fails OPEN and serves a contract whose
# provenance was never proven.
nogit_repo="$tmp/nogit"
mkdir -p "$nogit_repo/.agent"
cp -- "$valid_repo/.agent/env-contract.txt" "$nogit_repo/.agent/env-contract.txt"
git -C "$nogit_repo" ls-files --error-unmatch -- "$nogit_repo/.agent/env-contract.txt" \
    > /dev/null 2>&1
assert_eq 128 "$?" 'a non-work-tree root makes git report an operational failure, not "untracked"'
assert_rc 4 'a contract outside a Git work tree is untrusted' -- \
    "$reader" --repo-root "$nogit_repo" --get repo.slug
nogit_err=$("$reader" --repo-root "$nogit_repo" --get repo.slug 2>&1 > /dev/null || true)
assert_contains "$nogit_err" 'work tree' \
    'the refusal names the unusable work tree rather than a generic failure'
if guard_contract_is_ours "$nogit_repo/.agent/env-contract.txt" "$nogit_repo"; then
    guard_nogit=yes
else
    guard_nogit=no
fi
assert_eq no "$guard_nogit" 'hook predicate also refuses when git cannot determine tracking'

# The assertion above passes through the predicate's DELEGATION branch: for the
# canonical "$root/.agent/env-contract.txt" it just calls the reader, so it
# proves nothing about the predicate's own tracking check. Exercise the fallback
# branch directly with a non-canonical contract path, or guard-lib could fail
# open on its own while every other assertion here stayed green.
fallback_contract="$nogit_repo/.agent/alternate-contract.txt"
cp -- "$valid_repo/.agent/env-contract.txt" "$fallback_contract"
if guard_contract_is_ours "$fallback_contract" "$nogit_repo"; then
    guard_fallback=yes
else
    guard_fallback=no
fi
assert_eq no "$guard_fallback" \
    'hook predicate fallback refuses a contract git cannot prove untracked'

fallback_tracked="$tracked_repo/.agent/alternate-contract.txt"
cp -- "$valid_repo/.agent/env-contract.txt" "$fallback_tracked"
git -C "$tracked_repo" add -- .agent/alternate-contract.txt
if guard_contract_is_ours "$fallback_tracked" "$tracked_repo"; then
    guard_fallback_tracked=yes
else
    guard_fallback_tracked=no
fi
assert_eq no "$guard_fallback_tracked" 'hook predicate fallback still refuses a tracked contract'

fallback_untracked="$valid_repo/.agent/alternate-contract.txt"
cp -- "$valid_repo/.agent/env-contract.txt" "$fallback_untracked"
if guard_contract_is_ours "$fallback_untracked" "$valid_repo"; then
    guard_fallback_ok=yes
else
    guard_fallback_ok=no
fi
assert_eq yes "$guard_fallback_ok" \
    'hook predicate fallback still accepts a genuinely untracked contract'

finish
