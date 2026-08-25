#!/usr/bin/env bash
# Suite: the skills-content= contract stamp detects a stale installed tree.
#
# Issue #453: a published version string can name two different trees, and
# nothing made that visible to a session. This suite exercises the content
# stamp both as a unit (skills_content_hash) and end to end (two builds of a
# real skills tree, one mutated, probed through the real agent-preflight.sh
# and read back through the real contract-read.sh).
set -uo pipefail

TEST_NAME='contract-skills-content'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

preflight="$root/agentkit/skills/.shared/scripts/agent-preflight.sh"
contract_read="$root/agentkit/skills/.shared/scripts/contract-read.sh"
hash_lib="$root/agentkit/skills/.shared/scripts/lib/skills-content-hash.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

assert_hash_ne() {
    local a=$1 b=$2 msg=$3
    if [[ $a != "$b" && -n $a && -n $b ]]; then
        _pass "$msg"
    else
        _fail "$msg" "both hashed to: ${a:-<empty>}"
    fi
}

# --- unit: skills_content_hash -----------------------------------------------
# shellcheck source=../agentkit/skills/.shared/scripts/lib/skills-content-hash.sh
source "$hash_lib"

tree_a="$tmp/tree-a"
mkdir -p "$tree_a/.shared/scripts"
printf 'echo one\n' > "$tree_a/.shared/scripts/a.sh"
printf 'echo two\n' > "$tree_a/foo.md"

hash_a1=$(skills_content_hash "$tree_a")
hash_a2=$(skills_content_hash "$tree_a")
assert_eq "$hash_a1" "$hash_a2" 'hashing the same tree twice is deterministic'
assert_eq '64' "${#hash_a1}" 'the hash is a 64-character sha256 hex digest'

printf 'echo one changed\n' > "$tree_a/.shared/scripts/a.sh"
hash_a3=$(skills_content_hash "$tree_a")
assert_hash_ne "$hash_a1" "$hash_a3" 'changing a shipped file changes the stamp'

printf 'echo three\n' > "$tree_a/bar.md"
hash_a4=$(skills_content_hash "$tree_a")
assert_hash_ne "$hash_a3" "$hash_a4" 'adding a shipped file changes the stamp'

# Vendor/test-shaped paths are excluded at any depth, matching
# tests/build-plugin.sh's own packaging filter -- content only there never
# moves the stamp.
mkdir -p "$tree_a/nested/test-fixtures" "$tree_a/.agent" "$tree_a/.system"
printf 'ignored\n' > "$tree_a/nested/test-fixtures/whatever.sh"
printf 'ignored\n' > "$tree_a/.agent/state.txt"
printf 'ignored\n' > "$tree_a/.system/marker"
hash_a5=$(skills_content_hash "$tree_a")
assert_eq "$hash_a4" "$hash_a5" \
    'test-shaped, .agent, and .system content never moves the stamp'

# --- integration: two builds of the real tree, one mutated (stale) ----------
# Copy the real, shipped skills tree twice -- this is what an installed
# plugin copy actually is -- then mutate one shipped script's content in the
# second copy: the exact shape #431 describes, a fix on main under a version
# string an already-installed copy also claims.
copy_skills_tree() {
    local dest=$1
    mkdir -p "$dest/.shared/scripts"
    cp -a "$root/agentkit/skills/.shared/scripts/." "$dest/.shared/scripts/"
}

current_root="$tmp/current"
stale_root="$tmp/stale"
copy_skills_tree "$current_root"
copy_skills_tree "$stale_root"

printf '\n# stale marker -- would not exist in the fixed tree\n' \
    >> "$stale_root/.shared/scripts/agent-run.sh"

fixture_repo="$tmp/repo"
mkdir -p "$fixture_repo/.agent"
git -C "$fixture_repo" init -q

skills_content_stamp() {
    local build=$1 out
    out=$("$build/.shared/scripts/agent-preflight.sh" --worktree "$fixture_repo" --no-write 2> /dev/null)
    grep -m1 '^skills-content=' <<< "$out" | sed -n 's/^skills-content= sha256=//p'
}

current_hash=$(skills_content_stamp "$current_root")
stale_hash=$(skills_content_stamp "$stale_root")

assert_eq '64' "${#current_hash}" 'the current fixture build reports a real sha256 stamp'
assert_eq '64' "${#stale_hash}" 'the stale fixture build reports a real sha256 stamp'
assert_hash_ne "$current_hash" "$stale_hash" \
    'a stale build with different shipped content reports a different stamp than the current build'

# Re-probing the SAME current build reproduces the same stamp -- a session is
# never told a current, unmodified tree looks stale.
current_hash_again=$(skills_content_stamp "$current_root")
assert_eq "$current_hash" "$current_hash_again" \
    'the current build reports the same stamp on a repeat probe, never a false "stale"'

# --- contract-read.sh: skills.content served, skills.path untouched --------
repo=$(mktemp -d "$tmp/read-repo.XXXXXX")
git -C "$repo" init -q
mkdir -p "$repo/.agent"
"$preflight" --worktree "$repo" > /dev/null 2>&1

read_content=$("$contract_read" --repo-root "$repo" --get skills.content)
raw_content=$(sed -n 's/^skills-content= sha256=//p' "$repo/.agent/env-contract.txt")
assert_eq "$raw_content" "$read_content" \
    'contract-read.sh --get skills.content matches the raw contract line'

read_path=$("$contract_read" --repo-root "$repo" --get skills.path)
raw_path=$(sed -n 's/^skills= path=//p' "$repo/.agent/env-contract.txt")
assert_eq "$raw_path" "$read_path" \
    'contract-read.sh --get skills.path still returns the bare path, unaffected by skills-content='
case $read_path in
    *' '*) _fail 'skills.path never carries a stray content= suffix' "got: $read_path" ;;
    *) _pass 'skills.path never carries a stray content= suffix' ;;
esac

finish
