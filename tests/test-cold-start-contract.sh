#!/usr/bin/env bash
# A repository with no active workflow does not inherit bookkeeping obligations
# from old kit state. Once a workflow is active, human grants and unsafe state
# still fail closed.
# shellcheck disable=SC2016 # quoted snippets are written for a child shell.
set -uo pipefail

TEST_NAME='cold-start contract'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

parallel="$root/agentkit/skills/parallel-issues"
skill_text=$(<"$parallel/SKILL.md")
skill_flat=$(tr '\n' ' ' <<<"$skill_text" | tr -s '[:space:]' ' ')

assert_contains "$skill_flat" 'No current-session activation receipt means no parallel-issues run exists' \
    'parallel-issues states the cold-session boundary directly'
assert_contains "$skill_flat" 'do not search for or reconstruct a ledger, backlog snapshot, proof, fingerprint, or environment contract' \
    'cold ad-hoc work does not inherit kit bookkeeping obligations'
assert_contains "$skill_flat" 'Human grants still fail closed' \
    'the cold contract does not weaken authorization'
assert_contains "$skill_flat" 'Malformed, symlinked, foreign-owned, or active-run state still fails closed' \
    'the cold contract preserves unsafe and active-state validation'

recovery_block=''
for helper in \
    "$parallel/scripts/select-boundary-mode.sh" \
    "$parallel/scripts/concurrency-cap.sh" \
    "$parallel/scripts/prepare-issue-artifacts.sh" \
    "$parallel/scripts/move-github-project-item.sh"; do
    help_text=$("$helper" --help 2>&1)
    label=${helper##*/}
    assert_not_contains "$help_text" 'prepend THE CACHE REHYDRATION block' \
        "$label does not send a cold reader hunting for prose"
    current_recovery=$(sed -n \
        '/^  # BEGIN session-context recovery$/,/^  # END session-context recovery$/p' \
        <<<"$help_text")
    assert_contains "$current_recovery" 'agent-preflight.sh' \
        "$label carries executable session-context recovery"
    assert_contains "$current_recovery" '--ensure' \
        "$label bounds missing or stale recovery to one preflight refresh"
    if [[ -z $recovery_block ]]; then
        recovery_block=$current_recovery
    else
        assert_eq "$recovery_block" "$current_recovery" \
            "$label uses the canonical recovery block"
    fi
done

# Absence is a clean result only for kit-owned bookkeeping. A human grant is
# different: authorize-queue must still refuse when no confirmed queue exists.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p -- "$repo/.agent"
git -C "$repo" init -q

# Exercise the copied recovery block from a truly empty shell and repository.
# It must create its own contract/cache once, then load and verify the trusted
# installed skills path in the same shell.
recovery_script="$tmp/recovery.sh"
recovery_contents=${recovery_block//$'\n  '/$'\n'}
printf '%s\n' "${recovery_contents#  }" >"$recovery_script"
printf '%s\n' 'printf "loaded=%s provenance=%s root=%s\\n" "$agentkit" "$agentkit_provenance" "$contract_root"' \
    >>"$recovery_script"
run_copied_recovery() {
    local target_repo=$1 script=$2
    (cd -- "$target_repo" && env -u agentkit -u agentkit_provenance -u shared \
        -u contract_root bash "$script" 2>&1)
}
recovery_out=$(run_copied_recovery "$repo" "$recovery_script")
assert_contains "$recovery_out" "loaded=$root/agentkit/skills provenance=ok root=$repo" \
    'copied recovery creates and loads session context from unset variables'
assert_eq yes "$([[ -f $repo/.agent/env-contract.codex.txt || -f $repo/.agent/env-contract.txt ]] && printf yes || printf no)" \
    'copied recovery creates the missing environment contract'

contract_path="$repo/.agent/env-contract.codex.txt"
[[ -f $contract_path ]] || contract_path="$repo/.agent/env-contract.txt"
cache_path="$repo/.agent/cache/contract-session.env"

# An owned malformed bookkeeping file may be repaired by the canonical
# producer, but it must end as validated current state rather than being
# interpreted as absence.
printf '%s\n' malformed >"$cache_path"
malformed_cache_out=$(run_copied_recovery "$repo" "$recovery_script")
assert_contains "$malformed_cache_out" "loaded=$root/agentkit/skills provenance=ok root=$repo" \
    'owned malformed cache is repaired only through canonical producers'

# A recovery block emitted by another skills tree cannot validate this
# repository's cache as its own provenance.
foreign_skills="$tmp/foreign-skills"
mkdir -p -- "$foreign_skills/.shared/scripts/lib"
cp -- "$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh" \
    "$foreign_skills/.shared/scripts/lib/contract-cache.sh"
foreign_block=$("$foreign_skills/.shared/scripts/lib/contract-cache.sh" --print-session-recovery)
foreign_script="$tmp/foreign-recovery.sh"
foreign_contents=${foreign_block//$'\n  '/$'\n'}
printf '%s\n' "${foreign_contents#  }" >"$foreign_script"
foreign_rc=0
run_copied_recovery "$repo" "$foreign_script" >/dev/null || foreign_rc=$?
assert_eq 1 "$foreign_rc" \
    'session recovery rejects a cache bound to a different trusted skills path'

# Symlinked cache evidence is unsafe active state. The bounded refresh must not
# overwrite it or downgrade it to cold absence.
mv -- "$cache_path" "$tmp/cache-target"
ln -s -- "$tmp/cache-target" "$cache_path"
unsafe_cache_rc=0
run_copied_recovery "$repo" "$recovery_script" >/dev/null || unsafe_cache_rc=$?
assert_eq 1 "$unsafe_cache_rc" 'session recovery rejects a symlinked cache artifact'
rm -- "$cache_path"
mv -- "$tmp/cache-target" "$cache_path"

# A malformed owned contract may likewise be regenerated by preflight and
# must resolve back to this exact installed skills tree.
printf '%s\n' malformed >"$contract_path"
malformed_contract_out=$(run_copied_recovery "$repo" "$recovery_script")
assert_contains "$malformed_contract_out" "loaded=$root/agentkit/skills provenance=ok root=$repo" \
    'owned malformed contract is repaired only through preflight and contract-read'

# A symlinked contract is never repairable cold state.
mv -- "$contract_path" "$tmp/contract-target"
ln -s -- "$tmp/contract-target" "$contract_path"
unsafe_contract_rc=0
run_copied_recovery "$repo" "$recovery_script" >/dev/null || unsafe_contract_rc=$?
assert_eq 1 "$unsafe_contract_rc" 'session recovery rejects a symlinked environment contract'

# A repository can retain activation state from an older session. The current
# session fast path may hash its session ID once, but it must not hash any file
# in the skills tree when no current receipt exists.
hook_repo="$tmp/hook-repo"
mkdir -p -- "$hook_repo/.agent/activation" "$tmp/hash-bin"
chmod 700 -- "$hook_repo/.agent" "$hook_repo/.agent/activation"
git -C "$hook_repo" init -q
printf '%s\n' '{}' >"$hook_repo/.agent/activation/old-session.json"
real_sha256=$(command -v sha256sum)
hash_log="$tmp/hash-calls"
cat >"$tmp/hash-bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$#" >>"$HASH_LOG"
exec "$REAL_SHA256" "$@"
EOF
chmod +x -- "$tmp/hash-bin/sha256sum"
hook_payload=$(jq -cn --arg cwd "$hook_repo" \
    '{cwd:$cwd,session_id:"current-session",hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:"true"}}')
hook_out=$(PATH="$tmp/hash-bin:$PATH" HASH_LOG="$hash_log" REAL_SHA256="$real_sha256" \
    "$root/agentkit/hooks/pre-tool-use.sh" <<<"$hook_payload")
assert_eq '{}' "$(jq -c . <<<"$hook_out")" \
    'an old receipt does not arm the activation gate for the current session'
assert_eq 1 "$(wc -l <"$hash_log" | tr -d ' ')" \
    'the absent-current-session fast path hashes only the session identifier'
assert_eq 0 "$(awk '$1 != 0 { n++ } END { print n + 0 }' "$hash_log")" \
    'the absent-current-session fast path performs zero file hash invocations'

missing_queue="$repo/.agent/pr-to-green-confirmed-queue.json"
authorize="$root/agentkit/skills/pr-to-green/scripts/authorize-queue.sh"
authorize_rc=0
authorize_out=$("$authorize" --repo owner/repo --repo-root "$repo" \
    --confirmed-queue-file "$missing_queue" 2>&1) || authorize_rc=$?
assert_eq 1 "$authorize_rc" 'a missing human-confirmed queue still fails closed'
assert_contains "$authorize_out" 'confirmed queue file is missing' \
    'the authorization refusal names the missing grant artifact'
assert_contains "$authorize_out" 'pr-queue.sh --write-confirmed-queue' \
    'the authorization refusal names the grant-producing command'

# Unsafe state is evidence, not absence. A dangling .agent symlink must never
# be treated as a cold repository.
unsafe_repo="$tmp/unsafe"
mkdir -p -- "$unsafe_repo"
git -C "$unsafe_repo" init -q
ln -s -- "$tmp/missing-agent" "$unsafe_repo/.agent"
unsafe_rc=0
unsafe_out=$("$authorize" --repo owner/repo --repo-root "$unsafe_repo" \
    --confirmed-queue-file "$unsafe_repo/.agent/queue.json" 2>&1) || unsafe_rc=$?
assert_eq 1 "$unsafe_rc" 'unsafe .agent evidence still fails closed'
assert_contains "$unsafe_out" 'path is a symlink' \
    'unsafe state is distinguished from cold absence'

finish
