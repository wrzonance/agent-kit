#!/usr/bin/env bash
# Suite: stall-check.sh reads worker liveness from worktree mtime alone.
set -uo pipefail

TEST_NAME='stall-check'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

helper="$root/agentkit/skills/parallel-issues/scripts/stall-check.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

assert_eq yes "$([[ -x $helper ]] && printf yes || printf no)" 'stall-check helper is executable'
helper_source=$(<"$helper")
assert_contains "$helper_source" 'STALL_THRESHOLD_MINUTES_DEFAULT=12' \
    'the stall threshold is a named 12-minute constant'
helper_code=$(grep -v '^[[:space:]]*#' "$helper")
assert_not_contains "$helper_code" 'pgrep' \
    'detection never inspects processes'
assert_not_contains "$helper_code" 'ps ' \
    'detection never shells out to ps'

wt="$tmp/worktree"
mkdir -p "$wt/.git" "$wt/src"
printf 'work\n' > "$wt/src/a.txt"
touch -d '2020-01-01 00:00:00' "$wt/src/a.txt"
state="$tmp/state"

# stall -> re-dispatch -> park is the caller's sequence; the helper's part is
# the verdict ladder: active (first sight) -> quiet (one silent check) ->
# stalled (two consecutive silent checks past the threshold).
out=$("$helper" --worktree "$wt" --state "$state")
assert_eq 0 $? 'first observation exits zero'
assert_contains "$out" 'verdict=active' 'first observation is active'

out=$("$helper" --worktree "$wt" --state "$state")
assert_eq 0 $? 'one silent check still exits zero'
assert_contains "$out" 'verdict=quiet' 'one silent check is quiet, not stalled'

out=$("$helper" --worktree "$wt" --state "$state")
rc=$?
assert_eq 3 "$rc" 'two silent checks past the threshold exit 3'
assert_contains "$out" 'verdict=stalled' 'two silent checks past the threshold are stalled'
assert_contains "$out" 'quiet-checks=2' 'the stall verdict reports the quiet streak'

# Fresh filesystem evidence resets the streak: the re-dispatched worker's first
# write turns the same worktree active again.
touch -d '2020-06-01 00:00:00' "$wt/src/a.txt"
out=$("$helper" --worktree "$wt" --state "$state")
assert_eq 0 $? 'new evidence exits zero again'
assert_contains "$out" 'verdict=active' 'a newer mtime resets the verdict to active'

# A quiet streak that has not yet aged past the threshold is never a stall,
# no matter how many checks pile up.
recent_wt="$tmp/recent"
mkdir -p "$recent_wt/src"
printf 'now\n' > "$recent_wt/src/b.txt"
recent_state="$tmp/recent-state"
"$helper" --worktree "$recent_wt" --state "$recent_state" > /dev/null
"$helper" --worktree "$recent_wt" --state "$recent_state" > /dev/null
out=$("$helper" --worktree "$recent_wt" --state "$recent_state")
assert_eq 0 $? 'recent activity never reads as a stall'
assert_contains "$out" 'verdict=quiet' 'a young quiet streak stays quiet'

# threshold 0 turns the age test off, so the second silent check stalls --
# which is also what proves the streak requirement (the FIRST silent check
# still may not).
zero_state="$tmp/zero-state"
"$helper" --worktree "$recent_wt" --state "$zero_state" --threshold-minutes 0 > /dev/null
out=$("$helper" --worktree "$recent_wt" --state "$zero_state" --threshold-minutes 0)
assert_eq 0 $? 'one silent check never stalls even at threshold zero'
assert_contains "$out" 'verdict=quiet' 'the streak requirement holds at threshold zero'
out=$("$helper" --worktree "$recent_wt" --state "$zero_state" --threshold-minutes 0)
assert_eq 3 $? 'threshold zero stalls on the second silent check'

# Git metadata churn is not worker progress.
git_wt="$tmp/gitchurn"
mkdir -p "$git_wt/.git" "$git_wt/src"
printf 'x\n' > "$git_wt/src/c.txt"
touch -d '2020-01-01 00:00:00' "$git_wt/src/c.txt"
git_state="$tmp/git-state"
"$helper" --worktree "$git_wt" --state "$git_state" > /dev/null
touch "$git_wt/.git/FETCH_HEAD"
out=$("$helper" --worktree "$git_wt" --state "$git_state")
assert_contains "$out" 'verdict=quiet' 'git metadata churn does not read as progress'

# Evidence failures are loud, never a silent verdict.
assert_rc 2 'a missing worktree is a usage error' -- \
    "$helper" --worktree "$tmp/absent" --state "$tmp/s"
assert_rc 2 'a missing state path is a usage error' -- \
    "$helper" --worktree "$wt"
assert_rc 2 'a non-numeric threshold is refused' -- \
    "$helper" --worktree "$wt" --state "$state" --threshold-minutes soon

finish
