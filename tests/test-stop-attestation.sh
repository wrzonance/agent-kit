#!/usr/bin/env bash
# Suite: Stop re-attests exact Git changes, including paths that are not regular files.
set -uo pipefail

TEST_NAME='stop-attestation'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

hooks="$root/agentkit/hooks"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

make_repo() {
    local dir
    dir=$(mktemp -d "$tmp/repo.XXXXXX")
    git -C "$dir" init -q
    git -C "$dir" config user.name test
    git -C "$dir" config user.email test@example.invalid
    mkdir -p "$dir/.agent/cache"
    printf '%s' "$dir"
}

stop_input() {
    local active=${2:-false}
    jq -nc --arg cwd "$1" --argjson active "$active" \
        '{cwd:$cwd,hook_event_name:"Stop",model:"m",session_id:"s",
          transcript_path:null,stop_hook_active:$active}'
}

verdict() { jq -r '.decision // "allow"' <<< "$1"; }

commit_base() {
    local repo=$1
    git -C "$repo" add -- .
    git -C "$repo" commit -qm base
}

# A newline is data in the path, not a record separator. The old line parser
# turned this into nonexistent paths and allowed the unverified edit.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
path=$'line-one\nline-two'
printf base > "$repo/$path"
commit_base "$repo"
printf changed > "$repo/$path"
touch -d '20 seconds ago' "$repo/.agent/cache/stamp-verify"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'a changed newline path is not skipped'

# Spaces remain one path as well, including when the file is staged.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
path='file with spaces'
printf base > "$repo/$path"
commit_base "$repo"
printf changed > "$repo/$path"
git -C "$repo" add -- "$path"
touch -d '20 seconds ago' "$repo/.agent/cache/stamp-verify"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'a changed spaced path is not skipped'

# A deletion has no file mtime. Its containing directory changes when the
# entry disappears, so the deleted path must still be covered by the stamp.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
printf base > "$repo/deleted.txt"
commit_base "$repo"
touch -d '20 seconds ago' "$repo/.agent/cache/stamp-verify"
sleep 1
rm -- "$repo/deleted.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'a deleted path is not skipped'

# A rename has two NUL records; both sides must be consumed without turning the
# second path into a fresh status record.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
printf base > "$repo/old name"
commit_base "$repo"
git -C "$repo" mv -- 'old name' 'new name'
touch -d '20 seconds ago' "$repo/.agent/cache/stamp-verify"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'a rename is not skipped'

# A first Stop without a successful verify blocks, while the harness retry
# remains the loop guard for a genuinely failing command with no stamp.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
printf changed > "$repo/changed.txt"
out=$(stop_input "$repo" | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'an unverified first Stop blocks'
out=$(stop_input "$repo" true | "$hooks/stop.sh" 2>/dev/null)
assert_eq allow "$(verdict "$out")" 'an active retry without a stamp terminates the loop'

# A retry rechecks changes made after the successful verification stamp.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
printf base > "$repo/changed.txt"
commit_base "$repo"
printf first-change > "$repo/changed.txt"
touch "$repo/.agent/cache/stamp-verify"
sleep 1
printf second-change > "$repo/changed.txt"
out=$(stop_input "$repo" true | "$hooks/stop.sh" 2>/dev/null)
assert_eq block "$(verdict "$out")" 'an active retry re-attests a later edit'

# A dirty file whose last edit predates the successful stamp is covered on the
# retry, which preserves the useful end state after a real verify pass.
repo=$(make_repo)
printf 'AGENT_CMD_VERIFY=true\n' > "$repo/.agent/config.env"
printf base > "$repo/changed.txt"
commit_base "$repo"
printf verified-change > "$repo/changed.txt"
touch -d '20 seconds ago' "$repo/changed.txt"
touch "$repo/.agent/cache/stamp-verify"
out=$(stop_input "$repo" true | "$hooks/stop.sh" 2>/dev/null)
assert_eq allow "$(verdict "$out")" 'an active retry allows covered changes'

finish
