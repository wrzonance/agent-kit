#!/usr/bin/env bash
# ak setup: runs AGENT_CMD_SETUP once per worktree.
TEST_NAME=v2-setup
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1

out=$("$AK" setup 2>&1); rc=$?
assert_eq 0 "$rc" 'no setup command exits 0'
assert_eq 'setup=none' "$out" 'no setup command prints setup=none'

export AGENT_CMD_SETUP="echo ran >>'$WORK/count'"
out=$("$AK" setup 2>&1); rc=$?
assert_eq 0 "$rc" 'setup succeeds'
assert_contains "$out" 'PASS setup' 'setup prints the run_logged line'
assert_contains "$out" 'setup=ok' 'setup prints setup=ok'
assert_rc 0 'setup stamps .ak/setup.ok' -- test -f .ak/setup.ok

out=$("$AK" setup 2>&1)
assert_eq 'setup=ok cached' "$out" 'a second setup is cached'
assert_eq 1 "$(wc -l <"$WORK/count")" 'the setup command ran once'

rm -f .ak/setup.ok
export AGENT_CMD_SETUP='echo nope; exit 4'
out=$("$AK" setup 2>&1); rc=$?
assert_eq 1 "$rc" 'a failing setup exits 1'
assert_contains "$out" 'FAIL setup rc=4' 'a failing setup names the failure'
assert_rc 1 'a failing setup leaves no stamp' -- test -f .ak/setup.ok

finish
