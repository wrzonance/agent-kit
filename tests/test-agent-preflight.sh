#!/usr/bin/env bash
# Suite: agent-preflight.sh writes its contract safely.
#
# This script had no behavioural suite at all, which an external review noted
# before finding a defect in it: the contract was written with plain redirection,
# so a repository tracking .agent/env-contract.txt as a symlink to ../.git/config
# turned every preflight run into a truncate of the git config. Redirection
# follows the link and does not care where it lands.
#
# The file also matters more than its size suggests. It carries local paths, the
# CA bundle location and the authenticated account name, and it is read straight
# back into the agent's context as established fact.
set -uo pipefail

TEST_NAME='agent-preflight'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

new_repo() {
    local d
    d=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$d" init -q
    mkdir -p "$d/.agent"
    printf '%s' "$d"
}

# --- the ordinary case ------------------------------------------------------
repo=$(new_repo)
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'harness=' 'the block names the harness it ran under'
assert_rc 0 'a preflight in a bare repository still exits 0' -- \
    "$script" --worktree "$repo"
if [[ -f "$repo/.agent/env-contract.txt" ]]; then
    _pass 'and leaves the contract on disk'
else
    _fail 'and leaves the contract on disk' "no file at $repo/.agent/env-contract.txt"
fi

# The contract is not secret, but it is not public either: local paths, a CA
# bundle location, an account name. A lax umask should not decide that.
mode=$(stat -c '%a' "$repo/.agent/env-contract.txt" 2> /dev/null || printf '?')
assert_eq '600' "$mode" 'the contract is written private to the user'

# --- bounded root instruction report ---------------------------------------
repo=$(new_repo)
mkdir -p "$repo/nested"
printf 'nested guidance\n' > "$repo/nested/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'instructions= root=none' \
    'a bare fixture reports no root instruction files'
assert_not_contains "$out" 'nested/AGENTS.md' \
    'nested instruction files are not enumerated by preflight'

printf 'root guidance\n' > "$repo/AGENTS.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'instructions= root=AGENTS.md' \
    'preflight reports a root AGENTS.md'
assert_not_contains "$(grep '^instructions=' <<< "$out")" 'CLAUDE.md' \
    'the root report omits an absent CLAUDE.md'

printf 'root guidance\n' > "$repo/CLAUDE.md"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'instructions= root=AGENTS.md,CLAUDE.md' \
    'preflight reports both root instruction files in stable order'

# --- the symlink ------------------------------------------------------------
repo=$(new_repo)
printf 'ORIGINAL-MUST-SURVIVE\n' > "$repo/victim.txt"
ln -sf "$repo/victim.txt" "$repo/.agent/env-contract.txt"
err=$("$script" --worktree "$repo" 2>&1 > /dev/null)
assert_eq 'ORIGINAL-MUST-SURVIVE' "$(cat "$repo/victim.txt")" \
    'a symlinked contract does not become a write to its target'
assert_contains "$err" 'symlink' 'and the refusal says why'

# Reporting, never failing: the block already went to stdout, so refusing the
# artifact must not fail the run that produced it.
assert_rc 0 'refusing the artifact still exits 0' -- "$script" --worktree "$repo"
out=$("$script" --worktree "$repo" 2> /dev/null)
assert_contains "$out" 'harness=' 'and the block is still printed'

# --- a non-regular file at the target ---------------------------------------
repo=$(new_repo)
mkdir -p "$repo/.agent/env-contract.txt"
err=$("$script" --worktree "$repo" 2>&1 > /dev/null)
assert_contains "$err" 'not a regular file' 'a directory at the target is refused, not written through'
if [[ -d "$repo/.agent/env-contract.txt" ]]; then
    _pass 'and the directory is left alone'
else
    _fail 'and the directory is left alone' 'it was replaced'
fi

# --- replacement is atomic --------------------------------------------------
# A reader that opens this file mid-write gets a truncated contract and treats
# it as fact. Renaming a complete temporary over the target means a reader sees
# either the old contract or the new one.
repo=$(new_repo)
"$script" --worktree "$repo" > /dev/null 2>&1
first=$(wc -l < "$repo/.agent/env-contract.txt")
"$script" --worktree "$repo" > /dev/null 2>&1
second=$(wc -l < "$repo/.agent/env-contract.txt")
assert_eq "$first" "$second" 'a second run replaces the contract rather than appending to it'
leftovers=$(find "$repo/.agent" -maxdepth 1 -name '.env-contract.*' | wc -l | tr -d ' ')
assert_eq '0' "$leftovers" 'and leaves no temporary files behind'

# --- who the measurement is about -------------------------------------------
# A hook runs OUTSIDE the agent's sandbox. Its write probes succeed where the
# agent's would be denied, and the CODEX_* variables the sandbox block reads are
# set only in the agent's own shell -- so from a hook every session looks
# unsandboxed with a writable .git.
#
# A live session was handed exactly that and then had its write to
# .git/info/exclude refused. It noticed and worked around it. The contract says
# "established; do not re-probe", so noticing was not something it was invited
# to do, and relying on it twice is not a plan.
repo=$(new_repo)
agent_view=$("$script" --worktree "$repo" 2> /dev/null)
if grep -q 'measured-by=hook' <<< "$agent_view"; then
    _fail 'the default block claims nothing about a hook' 'it labelled itself hook-measured'
else
    _pass 'the default block claims nothing about a hook'
fi

hook_view=$("$script" --worktree "$repo" --measured-from hook 2> /dev/null)
assert_contains "$hook_view" 'sandbox=' 'a hook-measured block still reports the sandbox line'
assert_contains "$(grep '^sandbox=' <<< "$hook_view")" 'measured-by=hook' \
    'and marks the sandbox line as measured elsewhere'
assert_contains "$hook_view" 'believe a denial over this line' \
    'and says which side wins when they disagree'

# Never a confident "active=no" from a process that cannot see the answer.
if grep -qE '^sandbox=.*active=no' <<< "$hook_view"; then
    _fail 'a hook does not assert the session is unsandboxed' 'it emitted active=no'
else
    _pass 'a hook does not assert the session is unsandboxed'
fi

# The git line carries the same caveat, but only where it made a positive claim:
# writable=no is a denial the hook actually hit, and the agent's sandbox cannot
# make it more permissive.
git_line=$(grep '^git=' <<< "$hook_view")
if grep -q 'writable=yes' <<< "$git_line"; then
    assert_contains "$git_line" 'measured-by=hook' 'a hook-measured writable=yes is labelled'
    assert_contains "$git_line" 'worth re-probing' 'and invites the one re-probe that matters'
else
    _pass 'a hook-measured writable=yes is labelled (no positive claim to label here)'
    _pass 'and invites the one re-probe that matters (not applicable)'
fi

assert_rc 2 'an unknown provenance is a usage error, not a silent default' -- \
    "$script" --worktree "$repo" --measured-from somewhere

finish
