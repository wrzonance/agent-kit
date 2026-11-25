#!/usr/bin/env bash
# ak ship refuses a branch whose tree already equals the base, even with commits ahead of it (wrz-muze-server #1223,
# #1224: a reused worktree merged origin/main and resolved to main's side; the merge commit counted as "ahead", and
# ship pushed it and opened a draft PR with 0 changed files).
TEST_NAME=v2-ship-same-tree
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
git -C "$repo" worktree add -q -b feat/issue-7 "$WORK/wt" origin/main
# The old work, committed on the branch; the same change lands on main by another route (a squash merge).
(cd "$WORK/wt" && printf 'two\n' >src/b.txt && git add src && git commit -q -m 'feat: old work')
printf 'two\n' >"$repo/src/b.txt"
git -C "$repo" add src && git -C "$repo" commit -q -m 'feat: old work (squashed)' && git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin
cd "$WORK/wt" || exit 1
mkdir -p .ak
printf 'title: Fix the widget\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md
git merge -q --no-edit origin/main
assert_eq 2 "$(git rev-list --count origin/main..HEAD)" 'the fixture branch has the old commit and a merge commit ahead of base'
git diff --quiet origin/main HEAD
assert_eq 0 "$?" 'the fixture branch tree equals origin/main'

lookup='api repos/acme/widget/pulls?head=acme:feat/issue-7&state=open'
route "$lookup" '[]'
route 'api -X POST repos/acme/widget/pulls *' '{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}'
head=$(git rev-parse HEAD)
out=$("$AK" ship --message 'feat: old work' 2>&1); rc=$?
assert_eq 1 "$rc" 'a tree equal to base is refused although commits are ahead'
assert_contains "$out" "nothing to ship: HEAD's tree matches origin/main (the work is already on main)" 'the refusal says why'
assert_contains "$out" "fix: ak park --reason '…already on main…'" 'the refusal says to park'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'a refused ship pushes nothing'
assert_eq "$head" "$(git rev-parse HEAD)" 'a refused ship commits nothing'
assert_eq '' "$(cat "$FAKE_GH_LOG")" 'a refused ship makes no PR lookup or creation'

# Other PRs merge after the resolve: origin/main moves on, so a plain two-dot diff against it is no longer empty (it
# shows main's new commits reversed), but the PR GitHub shows is the merge-base diff and still has 0 changed files.
printf 'four\n' >"$repo/src/d.txt"
git -C "$repo" add src && git -C "$repo" commit -q -m 'feat: another PR' && git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin
git diff --quiet origin/main HEAD
assert_eq 1 "$?" 'the base has moved: HEAD and origin/main now differ'
out=$("$AK" ship --message 'feat: old work' 2>&1); rc=$?
assert_eq 1 "$rc" 'an advanced base does not hide a branch with nothing of its own'
assert_contains "$out" "nothing to ship: HEAD's tree matches origin/main" 'the refusal is the same'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'an advanced base: nothing is pushed'

# An open PR for the branch is not updated either: the tree now matches base.
route "$lookup" '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
out=$("$AK" ship --message 'feat: old work' 2>&1); rc=$?
assert_eq 1 "$rc" 'an existing PR does not exempt a tree equal to base'
assert_contains "$out" 'nothing to ship' 'the refusal is the same'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'nothing is pushed to the existing PR branch'

# A real change behind the advanced base still ships.
printf 'three\n' >src/c.txt
out=$("$AK" ship --message 'feat: more' 2>&1); rc=$?
assert_eq 0 "$rc" 'a branch that differs from base ships'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9' 'and reuses the open PR'

finish
