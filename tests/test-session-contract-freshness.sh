#!/usr/bin/env bash
# Suite: SessionStart invalidates cached contracts when checkout identity changes.
set -uo pipefail

TEST_NAME='session-contract-freshness'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
skills_root="$root/agentkit/skills"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
stub_path="$here/stub:$PATH"

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" checkout -q -b main
    git -C "$dir" -c user.email=t@example.invalid -c user.name=t \
        commit --allow-empty -qm base
    mkdir -p "$dir/.agent"
    printf '%s' "$dir"
}

session_input() {
    jq -nc --arg cwd "$1" \
        '{cwd:$cwd,hook_event_name:"SessionStart",model:"m",permission_mode:"default",
          session_id:"s1",source:"startup",transcript_path:null}'
}

me=$("$skills_root"/.shared/scripts/harness-id.sh --name 2> /dev/null)
repo=$(make_repo)
head=$(git -C "$repo" rev-parse HEAD)
printf 'repo=cached/value\nbranch=main\nbase=main source=test\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$head" "$me" > "$repo/.agent/env-contract.txt"

out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'cached/value' 'a current branch and HEAD reuse the cached contract'

git -C "$repo" -c user.email=t@example.invalid -c user.name=t \
    commit --allow-empty -qm second
new_head=$(git -C "$repo" rev-parse HEAD)
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'a new HEAD invalidates the cached contract'
assert_contains "$out" "head=$new_head" 'the refreshed context records the new HEAD'
assert_contains "$(cat -- "$repo/.agent/env-contract.txt")" "head=$new_head" \
    'the refreshed cache persists the new HEAD'

git -C "$repo" checkout -q -b feat/same-head
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'a branch change invalidates the cached contract'
assert_contains "$out" 'branch=feat/same-head' 'the refreshed context reports the new branch'

git -C "$repo" checkout -q --detach "$new_head"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'cached/value' 'detached HEAD invalidates a branch cache'
assert_contains "$out" 'branch=detached' 'the refreshed context reports detached HEAD'
detached_head=$(git -C "$repo" rev-parse HEAD)
printf 'repo=detached/value\nbranch=detached\nhead=%s\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$detached_head" "$me" > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_contains "$out" 'detached/value' 'a matching detached HEAD reuses the cached contract'

git -C "$repo" -c user.email=t@example.invalid -c user.name=t \
    commit --allow-empty -qm detached-second
new_detached_head=$(git -C "$repo" rev-parse HEAD)
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'detached/value' 'a new detached HEAD invalidates the cache'
assert_contains "$out" "head=$new_detached_head" 'the detached refresh records the new HEAD'

printf 'repo=legacy/value\nbranch=detached\nharness= name=%s trailer="T <t@example.invalid>" other=z\n' \
    "$me" > "$repo/.agent/env-contract.txt"
out=$(session_input "$repo" | PATH="$stub_path" "$hooks/session-start.sh" 2> /dev/null)
assert_not_contains "$out" 'legacy/value' 'a legacy cache without HEAD is not trusted'
assert_contains "$out" "head=$new_detached_head" 'a legacy cache is refreshed with checkout identity'

finish
