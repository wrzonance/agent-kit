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

for helper in \
    "$parallel/scripts/select-boundary-mode.sh" \
    "$parallel/scripts/concurrency-cap.sh" \
    "$parallel/scripts/prepare-issue-artifacts.sh" \
    "$parallel/scripts/move-github-project-item.sh"; do
    help_text=$("$helper" --help 2>&1)
    label=${helper##*/}
    assert_not_contains "$help_text" 'CACHE REHYDRATION' \
        "$label does not send a cold reader hunting for prose"
    assert_not_contains "$help_text" 'read-session-context' \
        "$label recipe carries no session-cache rehydration"
    # Ledger #29: the recipe starts from the literal installed path, so a
    # fresh shell or a fresh worktree has nothing to recover.
    assert_contains "$help_text" "  agentkit=$(cd -P -- "$root/agentkit/skills" && pwd -P)" \
        "$label recipe names its own installed skills path"
done

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
mkdir -p -- "$repo/.agent"
git -C "$repo" init -q

# The printed path is the tree the helper ships in, never a cached value.
foreign_skills="$tmp/foreign-skills"
mkdir -p -- "$foreign_skills/.shared/scripts/lib"
cp -- "$root/agentkit/skills/.shared/scripts/lib/contract-cache.sh" \
    "$foreign_skills/.shared/scripts/lib/contract-cache.sh"
assert_eq "  agentkit=$(cd -P -- "$foreign_skills" && pwd -P)" \
    "$("$foreign_skills/.shared/scripts/lib/contract-cache.sh" --print-session-recovery)" \
    'the printed assignment names the tree the helper ships in'

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

# Absence is a clean result only for kit-owned bookkeeping. A human grant is
# different: authorize-queue must still refuse when no confirmed queue exists.
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
