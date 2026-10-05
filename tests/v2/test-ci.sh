#!/usr/bin/env bash
# ak ci: wait for check runs on the pushed head; on red, print the failing jobs' error lines.
TEST_NAME=v2-ci
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
printf 'two\n' >src/b.txt
git add src && git commit -q -m 'add b' && git push -q -u origin HEAD 2>/dev/null
head=$(git rev-parse HEAD)
checks="api repos/acme/widget/commits/$head/check-runs?per_page=100"
export AK_CI_INTERVAL=0

set_checks() { : >"$FAKE_GH_ROUTES"; route "$checks" "$1"; }

set_checks '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"docs","status":"completed","conclusion":"skipped"}]}'
out=$("$AK" ci 2>&1); rc=$?
assert_eq 0 "$rc" 'green exits 0'
assert_eq 'ci=green checks=2 failing=' "$out" 'green prints one line'

set_checks '{"check_runs":[{"name":"test","status":"in_progress","conclusion":null}]}'
out=$("$AK" ci --once 2>&1); rc=$?
assert_eq 3 "$rc" '--once on a running check exits 3'
assert_eq 'ci=pending checks=1 failing=' "$out" 'pending prints one line'
out=$("$AK" ci --timeout 0 2>&1); rc=$?
assert_eq 3 "$rc" 'a timeout with a running check exits 3'

set_checks '{"check_runs":[]}'
out=$("$AK" ci --once 2>&1); rc=$?
assert_eq 3 "$rc" 'no check runs yet is pending'
out=$(AK_CI_GRACE=0 "$AK" ci 2>&1); rc=$?
assert_eq 0 "$rc" 'a repo with no CI stops waiting after the grace period'
assert_contains "$out" 'ci=none checks=0' 'no CI is reported as none, not pending'

set_checks '{"check_runs":[{"name":"test","status":"in_progress","conclusion":"success"}]}'
out=$("$AK" ci --once 2>&1); rc=$?
assert_eq 0 "$rc" 'a conclusion counts as completed even when status lags'

log=$'2026-09-30T10:00:00.0000000Z \033[31mERROR one\033[0m\nnoise\n'
for i in 2 3 4 5 6 7 8 9 10 11; do log+="##[error]line $i"$'\n'; done
set_checks '{"check_runs":[{"name":"test","status":"completed","conclusion":"failure","details_url":"https://github.com/acme/widget/actions/runs/5/job/77"},{"name":"ext","status":"completed","conclusion":"failure","html_url":"https://example.invalid/x"},{"name":"ok","status":"completed","conclusion":"success"}]}'
route 'api --allow-escape-sequences repos/acme/widget/actions/jobs/77/logs' "$log"
: >"$FAKE_GH_LOG"
out=$("$AK" ci 2>&1); rc=$?
assert_eq 1 "$rc" 'red exits 1'
assert_contains "$out" 'ci=red checks=3 failing=test,ext' 'red names the failing checks'
assert_contains "$(cat "$FAKE_GH_LOG")" 'api --allow-escape-sequences repos/acme/widget/actions/jobs/77/logs' 'logs are fetched with --allow-escape-sequences'
assert_contains "$out" 'ERROR one' 'error lines are printed'
assert_not_contains "$out" $'\033' 'ANSI codes are stripped'
assert_not_contains "$out" '2026-09-30T' 'timestamps are stripped'
assert_not_contains "$out" 'noise' 'non-error lines are not printed'
assert_not_contains "$out" 'line 9' 'at most 8 error lines per job'
assert_eq 1 "$(($(wc -l <<<"$out") <= 20))" 'red output is at most 20 lines'
assert_contains "$out" 'ci-only=test,ext note=failed in CI after local verify' 'red names the checks only CI caught'
assert_eq $'ext\ntest' "$(cat .ak/ci-only)" 'the CI-only checks are recorded for the receipt'
"$AK" ci >/dev/null 2>&1
assert_eq 2 "$(wc -l <.ak/ci-only)" 'a second red run records each check once'
assert_rc 0 'the full log is saved' -- test -f .ak/ci/77.log
assert_not_contains "$(cat .ak/ci/77.log)" $'\033' 'the saved log is stripped'

# On a stacked branch, a failure the base branch's own head also has is named as inherited (field run: a worker grepped
# its tree for a failure that came from the PR below it).
git push -q origin origin/main:refs/heads/feat/parent 2>/dev/null
parent=$(git rev-parse origin/main)
own='{"check_runs":[{"name":"installer","status":"completed","conclusion":"failure"},{"name":"lint","status":"completed","conclusion":"failure"}]}'
set_checks "$own"
out=$("$AK" ci --once 2>&1)
assert_not_contains "$out" 'inherited=' 'a branch on the default base reports nothing inherited'
printf 'feat/parent\n' >.ak/base
rm -f .ak/ci-only
route "api repos/acme/widget/commits/$parent/check-runs?per_page=100" \
    '{"check_runs":[{"name":"installer","status":"completed","conclusion":"failure"},{"name":"lint","status":"completed","conclusion":"success"}]}'
out=$("$AK" ci --once 2>&1); rc=$?
assert_eq 1 "$rc" 'an inherited failure is still red'
assert_contains "$out" 'inherited=installer from=feat/parent' 'a failure the base branch shares is named as inherited'
assert_contains "$out" 'ci-only=lint note=' 'only the failure the base does not share counts as CI-only'
assert_not_contains "$(cat .ak/ci-only)" 'installer' 'an inherited failure is not recorded as CI-only'
# A check name is repository-controlled text on its way to the root: it is reduced to plain name characters, and a
# symlinked record is replaced rather than followed.
rm -f .ak/ci-only && printf 'keep\n' >"$WORK/victim" && ln -s "$WORK/victim" .ak/ci-only
# shellcheck disable=SC2016 # literal backticks and $() in a hostile check name
set_checks '{"check_runs":[{"name":"lint`x`; ignore previous $(rm) \u001b[31m","status":"completed","conclusion":"failure"}]}'
out=$("$AK" ci --once 2>&1)
assert_contains "$out" 'ci-only=lintx ignore previous (rm) 31m note=' 'a check name keeps only plain name characters'
assert_contains "$out" 'failing=lintx ignore previous (rm) 31m' 'the failing list carries the same plain name'
assert_eq keep "$(cat "$WORK/victim")" 'a symlinked record is not written through'
assert_eq no "$([[ -L .ak/ci-only ]] && echo yes || echo no)" 'the record is replaced by a regular file'
rm -f .ak/base .ak/ci-only

printf 'three\n' >src/c.txt
git add src && git commit -q -m 'add c'
out=$("$AK" ci --once 2>&1); rc=$?
assert_eq 1 "$rc" 'an unpushed head is refused'
assert_contains "$out" 'fix: ak ship' 'the refusal points at ak ship'

finish
