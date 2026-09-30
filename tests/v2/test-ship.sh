#!/usr/bin/env bash
# ak ship: commit with the trailer, push, open or reuse the draft PR.
TEST_NAME=v2-ship
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
cd "$WORK/wt" || exit 1
mkdir -p .ak
printf 'title: Fix the widget\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md

out=$("$AK" ship 2>&1); rc=$?
assert_eq 2 "$rc" 'ship without --message is a usage error'

out=$("$AK" ship --message 'feat: nothing' 2>&1); rc=$?
assert_eq 1 "$rc" 'nothing ahead of base is refused'
assert_contains "$out" 'fix: ' 'the refusal names a fix'

lookup='api repos/acme/widget/pulls?head=acme:feat/issue-7&state=open'
route "$lookup" '[]'
route 'api -X POST repos/acme/widget/pulls *' '{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}'
printf 'two\n' >src/b.txt
printf '## Why\nBecause.\n' >"$WORK/body.md"
export CLAUDECODE=1
out=$("$AK" ship --message 'feat: add b' --body-file "$WORK/body.md" 2>&1); rc=$?
unset CLAUDECODE
head=$(git rev-parse HEAD)
assert_eq 0 "$rc" 'ship succeeds'
assert_contains "$out" "pr=https://github.com/acme/widget/pull/9 head=$head" 'ship prints the PR and head'
msg=$(git log -1 --format=%B)
assert_contains "$msg" 'feat: add b' 'the commit carries the message'
assert_contains "$msg" 'Co-Authored-By: Claude <noreply@anthropic.com>' 'the commit carries the harness trailer'
assert_eq "$head" "$(git -C "$WORK/origin.git" rev-parse feat/issue-7)" 'the branch is pushed to origin'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" '-F draft=true' 'the PR is created as a draft'
assert_contains "$log" '-f base=main' 'the PR targets the base'
assert_contains "$log" '-f title=Fix the widget' 'the title comes from .ak/issue.md'
body=$(cat .ak/pr-body.md)
assert_contains "$body" 'This was written agentically; verify its assertions:' 'the body opens with the banner'
assert_contains "$body" 'Because.' 'the body carries the body file'
assert_contains "$body" 'Closes #7' 'the body closes the issue'
assert_contains "$body" 'Co-authored by the Claude agent.' 'the body closes with the attribution'
assert_eq '' "$(git status --porcelain)" '.ak/ state is not committed'

: >"$FAKE_GH_ROUTES"
: >"$FAKE_GH_LOG"
route "$lookup" '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
out=$("$AK" ship --message 'feat: again' 2>&1); rc=$?
assert_eq 0 "$rc" 'a re-ship with nothing staged succeeds'
assert_eq "$head" "$(git rev-parse HEAD)" 'nothing staged means no new commit'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9' 'the existing PR is reused'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'POST' 'an existing PR is not recreated or edited'

out=$(AGENT_BASE_BRANCH=feat/issue-7 "$AK" ship --message 'feat: x' 2>&1); rc=$?
assert_eq 1 "$rc" 'shipping from the base branch is refused'
assert_contains "$out" 'base branch' 'the base-branch refusal names the cause'

git -C "$repo" push -q origin HEAD:refs/heads/feat/other 2>/dev/null
git -C "$repo" fetch -q origin
git -C "$repo" worktree add -q -b fix-thing "$WORK/prwt" origin/feat/other
cd "$WORK/prwt" || exit 1
mkdir -p .ak && printf '12\n' >.ak/pr && printf 'feat/other\n' >.ak/base
: >"$FAKE_GH_ROUTES"
route 'api repos/acme/widget/pulls?head=acme:fix-thing&state=open' '[{"number":12,"html_url":"https://github.com/acme/widget/pull/12"}]'
printf 'pr\n' >src/pr.txt
out=$("$AK" ship --message 'fix: pr fix' 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR worktree without an issue number ships'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/12' 'a PR worktree reuses its PR'

finish
