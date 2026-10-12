#!/usr/bin/env bash
# ak park: a worker that cannot ship anything in its worktree still leaves a machine-readable result.
TEST_NAME=v2-park
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1

out=$("$AK" park 2>&1); rc=$?
assert_eq 2 "$rc" 'park without --reason is a usage error'

# A worker that never ran ak verify has no park reason yet: setup and push logs do not count.
mkdir -p .ak/logs
: >.ak/logs/setup.log
: >.ak/logs/push.log
out=$("$AK" park --reason 'my test is red' 2>&1); rc=$?
assert_eq 1 "$rc" 'park without a verify log refuses'
assert_contains "$out" 'nothing verified yet: a red test of your own is a fix, not a park reason' 'the refusal names the cause'
assert_contains "$out" 'ak verify, fix what it prints, then ak park --reason' 'and the command that fixes it'
assert_eq no "$([[ -e .ak/result ]] && echo yes || echo no)" 'a refused park writes no result'
: >.ak/logs/verify.log

: >"$FAKE_GH_LOG"
out=$("$AK" park --reason 'needs a live Revit session' 2>&1); rc=$?
assert_eq 0 "$rc" 'park exits 0'
result=$(cat .ak/result)
assert_contains "$result" 'pr=none' 'a parked result has no PR'
assert_contains "$result" 'review=skipped' 'a parked result skipped review'
assert_contains "$result" 'note=parked: needs a live Revit session' 'the reason is in the note'
assert_contains "$result" "head=$(git rev-parse HEAD)" 'the head is recorded'
assert_eq 1 "$(wc -l <<<"$out")" 'park prints one line'
assert_eq '' "$(cat "$FAKE_GH_LOG")" 'park makes no GitHub calls'

finish
