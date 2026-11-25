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
assert_contains "$out" "nothing to ship: the branch changes nothing against origin/main (its merge-base diff is empty)" 'the refusal states only what was checked'
assert_contains "$out" "fix: if the work is already on main: ak park --reason '…'; otherwise commit the change first" 'the hint covers both causes'
assert_not_contains "$out" 'tree matches' 'the refusal does not claim the trees match'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'a refused ship pushes nothing'
assert_eq "$head" "$(git rev-parse HEAD)" 'a refused ship commits nothing'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'POST' 'a refused ship creates no PR'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'PATCH' 'a refused ship edits no PR'
assert_not_contains "$out" 'open PR' 'no open PR: the refusal does not mention one'

# Other PRs merge after the resolve: origin/main moves on, so a plain two-dot diff against it is no longer empty (it
# shows main's new commits reversed), but the PR GitHub shows is the merge-base diff and still has 0 changed files.
printf 'four\n' >"$repo/src/d.txt"
git -C "$repo" add src && git -C "$repo" commit -q -m 'feat: another PR' && git -C "$repo" push -q origin main
git -C "$repo" fetch -q origin
git diff --quiet origin/main HEAD
assert_eq 1 "$?" 'the base has moved: HEAD and origin/main now differ'
out=$("$AK" ship --message 'feat: old work' 2>&1); rc=$?
assert_eq 1 "$rc" 'an advanced base does not hide a branch with nothing of its own'
assert_contains "$out" "nothing to ship: the branch changes nothing against origin/main" 'the refusal is the same'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'an advanced base: nothing is pushed'

# An open PR for the branch is not updated either: the branch now changes nothing against base. The first matching
# route wins, so the empty lookup is dropped before the one that finds the PR is added.
: >"$FAKE_GH_ROUTES"
route "$lookup" '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
out=$("$AK" ship --message 'feat: old work' 2>&1); rc=$?
assert_eq 1 "$rc" 'an existing PR does not exempt a tree equal to base'
assert_contains "$out" 'nothing to ship' 'the refusal is the same'
assert_contains "$out" 'open PR #9 (https://github.com/acme/widget/pull/9)' 'the refusal names the open PR'
assert_contains "$out" 'fix: gh pr close 9' 'the hint says to close the PR'
assert_contains "$out" 'its remote head still has the withdrawn change' 'the hint says why'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-7)" 'nothing is pushed to the existing PR branch'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'POST' 'an existing PR is not created again'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'PATCH' 'an existing PR is not edited'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'pr edit' 'an existing PR is not edited through gh pr'

# A branch that made a change and then reverted it has the same empty merge-base diff.
git -C "$repo" worktree add -q -b feat/issue-8 "$WORK/wt2" origin/main
(cd "$WORK/wt2" && mkdir -p .ak && printf 'title: Revert me\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md \
    && printf 'five\n' >src/e.txt && git add src && git commit -q -m 'feat: change' \
    && git revert --no-edit HEAD >/dev/null)
route 'api repos/acme/widget/pulls?head=acme:feat/issue-8&state=open' '[]'
out=$(cd "$WORK/wt2" && "$AK" ship --message 'feat: revert' 2>&1); rc=$?
assert_eq 1 "$rc" 'a branch that reverted its own change is refused'
assert_contains "$out" 'nothing to ship: the branch changes nothing against origin/main (its merge-base diff is empty)' 'the revert refusal states only what was checked'
assert_eq '' "$(git ls-remote "$WORK/origin.git" feat/issue-8)" 'a reverted branch pushes nothing'

# A real change behind the advanced base still ships.
printf 'three\n' >src/c.txt
out=$("$AK" ship --message 'feat: more' 2>&1); rc=$?
assert_eq 0 "$rc" 'a branch that differs from base ships'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9' 'and reuses the open PR'

# A committed submodule pointer update is a change even when diff.ignoreSubmodules=all (or ignore=all in .gitmodules)
# hides it from a plain diff: the guard must not refuse it as empty. A gitlink needs no real submodule clone.
git -C "$repo" config diff.ignoreSubmodules all
git -C "$repo" worktree add -q -b feat/issue-9 "$WORK/wt3" origin/main
(cd "$WORK/wt3" && mkdir -p .ak && printf 'title: Bump the submodule\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md \
    && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),vendor/lib" && git commit -q -m 'chore: bump vendor/lib')
git -C "$WORK/wt3" diff --quiet origin/main...HEAD
assert_eq 0 "$?" 'with diff.ignoreSubmodules=all a plain merge-base diff does not see the pointer update'
route 'api repos/acme/widget/pulls?head=acme:feat/issue-9&state=open' '[{"number":9,"html_url":"https://github.com/acme/widget/pull/9"}]'
out=$(cd "$WORK/wt3" && "$AK" ship --message 'chore: bump vendor/lib' 2>&1); rc=$?
assert_eq 0 "$rc" 'a submodule pointer update ships although diff.ignoreSubmodules=all'
assert_not_contains "$out" 'nothing to ship' 'the pointer update is not refused as empty'
assert_contains "$out" 'pr=https://github.com/acme/widget/pull/9' 'it reaches the PR path'

# The same config does not make an identical tree shippable.
git -C "$repo" worktree add -q -b feat/issue-10 "$WORK/wt4" origin/main
(cd "$WORK/wt4" && mkdir -p .ak && printf 'title: Revert the bump\n\n~~~untrusted\nbody\n~~~\n' >.ak/issue.md \
    && git update-index --add --cacheinfo "160000,$(git rev-parse HEAD),vendor/lib" && git commit -q -m 'chore: bump' \
    && git revert --no-edit HEAD >/dev/null)
route 'api repos/acme/widget/pulls?head=acme:feat/issue-10&state=open' '[]'
out=$(cd "$WORK/wt4" && "$AK" ship --message 'chore: revert' 2>&1); rc=$?
assert_eq 1 "$rc" 'an identical tree is still refused with diff.ignoreSubmodules=all'
assert_contains "$out" 'nothing to ship: the branch changes nothing against origin/main' 'the refusal is the same'

finish
