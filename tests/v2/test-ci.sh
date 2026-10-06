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

prs='api repos/acme/widget/pulls?head=acme:feat/issue-7&state=open'
set_checks() { : >"$FAKE_GH_ROUTES"; route "$checks" "$1"; route "$prs" '[]'; }

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

# A required check with no completed run keeps the head pending (field run 2026-10-05: a stacked PR went dirty when its
# parent squash-merged, GitHub ran no pull_request workflow, and CodeQL plus a push lint read as ci=green).
set_checks '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}'
out=$(AGENT_REQUIRED_CHECKS=Installer "$AK" ci --once 2>&1); rc=$?
assert_eq 3 "$rc" 'a missing required check is pending'
assert_eq 'ci=pending checks=1 failing= missing=Installer' "$out" 'the summary names the missing check'
out=$(AGENT_REQUIRED_CHECKS='lint, Installer' "$AK" ci --timeout 0 2>&1); rc=$?
assert_eq 3 "$rc" 'the wait ends pending while a required check is missing'
assert_contains "$out" 'missing=Installer' 'a comma list names only the absent check'
out=$(AGENT_REQUIRED_CHECKS=lint "$AK" ci --once 2>&1); rc=$?
assert_eq 0 "$rc" 'a required check that completed is green'
assert_eq 'ci=green checks=1 failing=' "$out" 'a satisfied requirement adds nothing to the line'
set_checks '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"},{"name":"Installer","status":"in_progress","conclusion":null}]}'
out=$(AGENT_REQUIRED_CHECKS=Installer "$AK" ci --once 2>&1)
assert_contains "$out" 'missing=Installer' 'a required check still running has no completed run'

# A PR that conflicts with its base gets no pull_request workflow from GitHub: a green head there is not the PR's green.
set_pr() { : >"$FAKE_GH_ROUTES"; route "$checks" '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}'; route "$prs" '[{"number":12}]'; route 'api repos/acme/widget/pulls/12' "$1" "${2:-0}"; }
set_pr '{"number":12,"mergeable_state":"dirty","base":{"ref":"main"}}'
: >"$FAKE_GH_LOG"
out=$("$AK" ci 2>&1); rc=$?
assert_eq 1 "$rc" 'a PR that conflicts with its base is blocked'
assert_contains "$out" 'ci=blocked note=PR #12 conflicts with main, so GitHub runs no PR checks' 'blocked names the PR and its base'
assert_contains "$out" 'fix: git fetch origin && git merge origin/main' 'the fix merges the base in'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'check-runs' 'no check runs are read for a blocked PR'
assert_eq 1 "$(grep -c 'pulls/12$' "$FAKE_GH_LOG")" 'the PR is read once'
set_pr '{"number":12,"mergeable_state":"clean","base":{"ref":"main"}}'
out=$("$AK" ci 2>&1); rc=$?
assert_eq 0 "$rc" 'a mergeable PR takes the usual path'
assert_eq 'ci=green checks=1 failing=' "$out" 'a mergeable PR prints the summary alone'
# The base name comes from the PR and lands in a command the agent runs; an odd one is not echoed.
set_pr '{"number":12,"mergeable_state":"dirty","base":{"ref":"main; rm -rf x"}}'
out=$("$AK" ci 2>&1); rc=$?
assert_eq 1 "$rc" 'a dirty PR with an odd base name is still blocked'
assert_contains "$out" 'conflicts with its base branch, so GitHub runs no PR checks' 'the note says its base branch, not the raw value'
assert_contains "$out" 'fix: git fetch origin && git merge origin/<its base branch>' 'the fix line says its base branch, not the raw value'
assert_not_contains "$out" 'rm -rf' 'the raw base name is not printed'
# An API failure must not pass silently as "no PR": the gap is named, then the head's checks are judged as before.
set_pr '' 1
out=$("$AK" ci 2>&1); rc=$?
assert_eq 0 "$rc" 'an unreadable PR state still judges the checks'
assert_contains "$out" "note=could not read PR #12 state; judging the head's checks alone" 'the unreadable PR state is named'
assert_contains "$out" 'ci=green checks=1 failing=' 'the checks are read after the note'
: >"$FAKE_GH_ROUTES"
route "$checks" '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}'
out=$("$AK" ci 2>&1); rc=$?
assert_eq 0 "$rc" 'a failed PR listing still judges the checks'
assert_contains "$out" "note=could not list the branch's PR; judging the head's checks alone" 'the failed listing is named'

# ak ci from the main checkout read main's head and told the root to ak ship (field run 2026-10-05).
out=$(cd "$repo" && "$AK" ci --once 2>&1); rc=$?
assert_eq 1 "$rc" 'ak ci on the base branch is refused'
assert_contains "$out" "ak ci runs in the PR's worktree" 'the refusal says where ak ci runs'
assert_contains "$out" "fix: cd $repo/.worktrees/<branch> && ak ci" 'the fix names the worktree'
out=$(cd "$repo" && AGENT_WORKTREE_ROOT=wt "$AK" ci --once 2>&1)
assert_contains "$out" "fix: cd $repo/wt/<branch> && ak ci" 'the worktree root comes from config'

log=$'2026-09-30T10:00:00.0000000Z \033[31mERROR one\033[0m\nnoise\n'
for i in 2 3 4 5 6 7 8 9 10 11; do log+="##[error]line $i"$'\n'; done
set_checks '{"check_runs":[{"name":"test","status":"completed","conclusion":"failure","details_url":"https://github.com/acme/widget/actions/runs/5/job/77"},{"name":"ext","status":"completed","conclusion":"failure","html_url":"https://example.invalid/x"},{"name":"ok","status":"completed","conclusion":"success"}]}'
route 'api --allow-escape-sequences repos/acme/widget/actions/jobs/77/logs' "$log"
# The failed step says which command to add locally (a field note said only "Server"; the step was the type check).
route 'api repos/acme/widget/actions/jobs/77 *' 'Type check (mypy)'
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
assert_contains "$out" 'ci-only=test/Type check (mypy),ext note=failed in CI after local verify' 'red names the checks only CI caught, with the failed step'
assert_eq $'ext\ntest/Type check (mypy)' "$(cat .ak/ci-only)" 'the CI-only checks are recorded for the receipt'
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
