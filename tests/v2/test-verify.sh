#!/usr/bin/env bash
# ak verify: the repo's checks, plus every declared suite whose rundir the diff touches.
TEST_NAME=v2-verify
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1

out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'no verify command exits 0'
assert_eq 'verify=none oracle=ci' "$out" 'no verify command defers to CI'

export AGENT_CMD_TEST='echo tests ran'
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'AGENT_CMD_TEST is the fallback'
assert_contains "$out" 'verify=pass' 'a passing test command is verify=pass'
assert_contains "$out" 'PASS test' 'the test command is named'
assert_not_contains "$out" 'oracle=ci' 'nothing skipped means no CI oracle line'

export AGENT_CMD_VERIFY='echo "SKIP installer-suites (conditional): no pwsh"; echo "SUMMARY: PASS"'
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'a skipping verify still passes'
assert_contains "$out" 'PASS verify' 'verify wins over test'
assert_not_contains "$out" 'PASS test' 'test does not run when verify is set'
assert_contains "$out" 'skipped=installer-suites' 'SKIP lines are collected'
assert_contains "$out" 'oracle=ci' 'a skip makes CI the oracle'

export AGENT_CMD_VERIFY='echo broken; exit 2'
out=$("$AK" verify 2>&1); rc=$?
assert_eq 1 "$rc" 'a failing verify exits 1'
assert_contains "$out" 'verify=fail' 'a failing verify prints verify=fail'
assert_contains "$out" 'broken' 'the failing tail is printed'

export AGENT_CMD_VERIFY='true'
printf 'AGENT_CMD_WEB="echo web ran"\nAGENT_RUNDIR_WEB=web\nAGENT_CMD_SRC="echo src ran"\nAGENT_RUNDIR_SRC=src/\n' >>"$repo/.agent/config.env"
printf 'AGENT_CMD_SRC_FIX="exit 9"\nAGENT_RUNDIR_SRC_FIX=src\n' >>"$repo/.agent/config.env"
printf 'two\n' >src/b.txt
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'matched suites pass'
assert_contains "$out" 'PASS src' 'an uncommitted change under a rundir runs its suite'
assert_not_contains "$out" 'web' 'an untouched rundir does not run'
assert_not_contains "$out" 'src_fix' 'a _FIX command never runs'
git add src/b.txt && git commit -q -m 'add b'
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS src' 'a committed change under a rundir runs its suite'

export AGENT_CMD_WEB='echo "SKIP e2e"; exit 0'
mkdir web && printf 'x\n' >web/x.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS web' 'an env override of a config command runs'
assert_contains "$out" 'skipped=e2e' 'SKIP lines from extra suites are collected'
assert_contains "$out" 'oracle=ci' 'extra-suite skips make CI the oracle'

finish
