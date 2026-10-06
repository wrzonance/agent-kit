#!/usr/bin/env bash
# ak verify: the declared suites the diff touches, each in its own directory; the whole-repo check only as a fallback.
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
assert_not_contains "$out" 'oracle=ci' 'a whole-repo pass with nothing skipped needs no CI oracle line'

export AGENT_CMD_VERIFY='echo "SKIP installer-suites (conditional): no pwsh"; echo "SUMMARY: PASS"'
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'a skipping verify still passes'
assert_contains "$out" 'PASS verify' 'verify wins over test'
assert_not_contains "$out" 'PASS test' 'test does not run when verify is set'
assert_contains "$out" 'skipped=installer-suites' 'SKIP lines are collected'
assert_contains "$out" 'oracle=ci' 'a skip makes CI the oracle'

# --full runs AGENT_CMD_TEST when both are set (a field repository set VERIFY to its fast check and TEST to the full
# gate, and `ak verify --full` never ran the full gate); without --full the fast AGENT_CMD_VERIFY stays first.
export AGENT_CMD_VERIFY="echo fast >>$WORK/whole" AGENT_CMD_TEST="echo full >>$WORK/whole"
out=$("$AK" verify --full 2>&1); rc=$?
assert_eq 0 "$rc" '--full with both commands passes'
assert_contains "$out" 'PASS test' '--full runs the test command'
assert_not_contains "$out" 'PASS verify' '--full does not run the verify command when test is set'
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS verify' 'without --full the verify command runs'
assert_not_contains "$out" 'PASS test' 'without --full the test command does not run beside verify'
assert_eq $'full\nfast' "$(cat "$WORK/whole")" 'each run ran only the command it named'
unset AGENT_CMD_TEST

export AGENT_CMD_VERIFY='echo broken; exit 2'
out=$("$AK" verify 2>&1); rc=$?
assert_eq 1 "$rc" 'a failing verify exits 1'
assert_contains "$out" 'verify=fail' 'a failing verify prints verify=fail'
assert_contains "$out" 'broken' 'the failing tail is printed'

# A passed whole check is not re-run for the same areas (a field run re-ran a 12-minute whole check after
# review fixes and hit an unrelated flake); --full, a new area or a new command runs it again.
export AGENT_CMD_VERIFY="echo run >>$WORK/count"
mkdir -p notes tools && printf 'x\n' >notes/a.md
"$AK" verify >/dev/null 2>&1
printf 'y\n' >notes/a.md
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'a cached whole check passes'
assert_eq 1 "$(wc -l <"$WORK/count")" 'the whole check is not re-run for the same areas'
assert_contains "$out" 'cached verify: passed earlier for these areas (notes)' 'the cached pass is named'
assert_contains "$out" 'oracle=ci' 'a cached pass leaves the proof to CI'
"$AK" verify --full >/dev/null 2>&1
assert_eq 2 "$(wc -l <"$WORK/count")" '--full re-runs the whole check'
printf 'x\n' >tools/b.sh
"$AK" verify >/dev/null 2>&1
assert_eq 3 "$(wc -l <"$WORK/count")" 'a new area re-runs the whole check'
export AGENT_CMD_VERIFY="echo other >>$WORK/count"
"$AK" verify >/dev/null 2>&1
assert_eq 4 "$(wc -l <"$WORK/count")" 'a different whole command re-runs'
export AGENT_CMD_VERIFY="exit 1"
"$AK" verify >/dev/null 2>&1
assert_eq no "$([[ -e .ak/verify-whole ]] && echo yes || echo no)" 'a failing whole check clears the cache'
rm -rf notes tools

# Area suites replace the whole-repo check (a field run: five workers re-ran a 6-minute whole-repo check per diff).
export AGENT_CMD_VERIFY='echo WHOLE'
mkdir -p web lib/tests
printf 'AGENT_CMD_WEB="pwd"\nAGENT_RUNDIR_WEB=web\nAGENT_CMD_SRC="echo src ran"\nAGENT_RUNDIR_SRC=src/\n' >>"$repo/.agent/config.env"
printf 'AGENT_CMD_SRC_FIX="exit 9"\nAGENT_RUNDIR_SRC_FIX=src\nAGENT_CMD_LIBTEST="echo lib ran lib/tests"\n' >>"$repo/.agent/config.env"
printf 'two\n' >src/b.txt
out=$("$AK" verify 2>&1); rc=$?
assert_eq 0 "$rc" 'matched suites pass'
assert_contains "$out" 'PASS src' 'an uncommitted change under a rundir runs its suite'
assert_not_contains "$out" 'WHOLE' 'a matched suite replaces the whole-repo check'
assert_not_contains "$out" 'PASS verify' 'the whole-repo check does not run'
assert_contains "$out" 'oracle=ci' 'area suites leave the full gate to CI'
assert_not_contains "$out" 'web' 'an untouched rundir does not run'
assert_not_contains "$out" 'src_fix' 'a _FIX command never runs'
git add src/b.txt && git commit -q -m 'add b'
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS src' 'a committed change under a rundir runs its suite'

printf 'x\n' >web/x.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'run web: pwd (in web)' 'a rundir suite says where it runs'
assert_contains "$(cat .ak/logs/web.log)" "$WORK/wt/web" 'a rundir suite runs inside its rundir'
rm web/x.txt

printf 'x\n' >lib/tests/t.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS libtest' "a suite whose command names the path's top directory runs"
rm lib/tests/t.txt

printf 'x\n' >top-level.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'uncovered=top-level.txt' 'paths no suite owns are named'
rm top-level.txt

# A ./-prefixed rundir and a quoted directory argument still own their paths beside another matched suite.
printf 'AGENT_CMD_DOCS="echo docs ran"\nAGENT_RUNDIR_DOCS=./docs\nAGENT_CMD_PKG='"'"'true --prefix "pkg"'"'"'\n' \
    >>"$repo/.agent/config.env"
mkdir -p docs pkg && printf 'x\n' >docs/x.txt && printf 'x\n' >pkg/x.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS docs' 'a ./-prefixed rundir owns its paths'
assert_contains "$out" 'PASS pkg' 'a quoted directory argument owns its paths'
rm -rf docs pkg

out=$("$AK" verify --full 2>&1)
assert_contains "$out" 'PASS verify' '--full runs the whole-repo check'
assert_contains "$out" 'PASS src' '--full still runs the matched suites'
out=$("$AK" verify --nope 2>&1); rc=$?
assert_eq 2 "$rc" 'an unknown flag is a usage error'

export AGENT_CMD_WEB='echo "SKIP e2e"; exit 0'
printf 'x\n' >web/x.txt
out=$("$AK" verify 2>&1)
assert_contains "$out" 'PASS web' 'an env override of a config command runs'
assert_contains "$out" 'skipped=e2e' 'SKIP lines from area suites are collected'

git push -q origin HEAD:refs/heads/feat/other 2>/dev/null && git fetch -q origin
printf 'feat/other\n' >.ak/base
out=$("$AK" verify 2>&1)
assert_not_contains "$out" 'PASS src' '.ak/base narrows the diff to the PR base'

finish
