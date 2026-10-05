#!/usr/bin/env bash
# ak collect: result lines, missing results, cross-writes, and chain successors.
TEST_NAME=v2-collect
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=plan-fixture.sh
source "$V2_TESTS/plan-fixture.sh"
ak_with_template

repo=$(board_repo)
cd "$repo" || exit 1
standard_board
"$AK" plan --serialize >/dev/null 2>&1
wt="$repo/.worktrees/feat/issue-671"
runfile="$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json"

out=$("$AK" collect --issue 671 2>&1); rc=$?
assert_eq 0 "$rc" 'a missing result is not a failure'
assert_eq 'issue=671 state=pending note=no .ak/result yet; collect again once the worker reports' "$out" 'a missing result is pending, not ended'
assert_eq spawned "$(jq -r '.items[] | select(.n == 671) | .state' "$runfile")" 'a pending collect leaves the run state alone'
assert_eq no "$([[ -e $repo/.worktrees/feat/issue-680 ]] && echo yes || echo no)" 'no successor spawns without a result'

printf 'x\n' >"$wt/src/a.txt"
git -C "$wt" commit -qam work && git -C "$wt" push -q
# A parked issue releases nothing: its successor stays queued and collect says why (a field chain spawned two
# successors that only found the parked predecessor's work missing).
printf 'pr=none\nci=none\nreview=skipped\nhead=abc\nnote=parked: protected path\n' >"$wt/.ak/result"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'after issue=680 reason=waits-on-parked-#671' 'a parked issue holds its successor'
assert_not_contains "$out" 'spawn issue=680' 'a parked issue spawns no successor'
assert_eq 'parked queued' "$(jq -r '[.items[] | select(.n == 671 or .n == 680) | .state] | join(" ")' "$runfile")" 'the run records the park and the held successor'
assert_contains "$out" "next=issue=671 is parked in $wt (uncommitted paths: 0); clear what its note names, commit and push there what only you may commit, then: ak plan --issue 671" 'a park says where the work waits and the command that continues it'
# A red predecessor holds its successor too, and stays collectable (a field successor was spawned on a red branch).
printf 'pr=https://github.com/acme/widget/pull/9\nci=red\nreview=done\nhead=abc\nnote=lint\n' >"$wt/.ak/result"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'after issue=680 reason=waits-on-red-#671' 'a red issue holds its successor'
assert_not_contains "$out" 'spawn issue=680' 'a red issue spawns no successor'
assert_contains "$out" 'next=issue=671 has red CI' 'a red collect names the next step'
assert_contains "$out" 'then: ak collect --issue 671' 'the next step ends in the collect that releases the successor'
assert_eq 'spawned queued' "$(jq -r '[.items[] | select(.n == 671 or .n == 680) | .state] | join(" ")' "$runfile")" 'a red issue goes back to spawned, so nothing counts it as done'
# A check re-run that turns the same head green releases the successor on the next collect (no new commit needed).
routes=$(cat "$FAKE_GH_ROUTES")
printf '{"number":9,"head":{"sha":"abc"}}' >"$WORK/pr9-same.json"
printf '{"check_runs":[{"name":"lint","status":"completed","conclusion":"success"}]}' >"$WORK/runs-abc.json"
printf 'api repos/acme/widget/pulls/9\t%s\t0\napi repos/acme/widget/commits/abc/check-runs*\t%s\t0\napi repos/acme/widget/pulls?state=open&head=acme:feat/issue-680*\t-\t1\n%s\n' \
    "$WORK/pr9-same.json" "$WORK/runs-abc.json" "$routes" >"$FAKE_GH_ROUTES"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'issue=671 pr=https://github.com/acme/widget/pull/9 ci=green' 'a recorded red is read live again at the same head'
assert_not_contains "$out" 'waits-on-red' 'a head that went green no longer holds its successor'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
printf 'pr=https://github.com/acme/widget/pull/9\nci=green\nreview=done\nhead=abc\nnote=findings=2 fixed=2 declined=0\n' >"$wt/.ak/result"
# A failed open-PR lookup leaves the successor queued for the next collect instead of reading as an open PR.
routes=$(cat "$FAKE_GH_ROUTES")
printf 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-680*\t-\t1\n%s\n' "$routes" >"$FAKE_GH_ROUTES"
out=$("$AK" collect --issue 671 2>&1)
assert_contains "$out" 'after issue=680 note=open-PR lookup failed; collect again' 'a failed PR lookup is reported'
assert_eq queued "$(jq -r '.items[] | select(.n == 680) | .state' "$runfile")" 'a failed PR lookup leaves the successor queued'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"
# A successor's worktree left by an earlier run is reused, and still starts from the predecessor branch (a field
# successor reused one that never got its predecessor's work, and parked).
git -C "$repo" worktree add -q -b feat/issue-680 "$repo/.worktrees/feat/issue-680" origin/main
reads=$(grep -c 'api graphql' "$FAKE_GH_LOG")
out=$("$AK" collect --issue 671 2>&1); rc=$?
assert_eq 0 "$rc" 'collect exits 0'
wt2="$repo/.worktrees/feat/issue-680"
assert_eq "issue=671 pr=https://github.com/acme/widget/pull/9 ci=green review=done note=findings=2 fixed=2 declined=0
spawn issue=680 cwd=$wt2 prompt=$wt2/.ak/prompt.md model=gpt-5.6-luna effort=medium" "$out" 'collect prints the result and the unblocked successor'
assert_eq "$(git -C "$wt" rev-parse HEAD)" "$(git -C "$wt2" rev-parse HEAD)" 'the successor starts from the predecessor branch'
assert_contains "$(cat "$wt2/.ak/prompt.md")" 'base=feat/issue-671' 'the successor targets the predecessor branch'
assert_eq feat/issue-671 "$(cat "$wt2/.ak/base")" 'the successor .ak/base is the predecessor branch'
assert_eq 'collected spawned' "$(jq -r '[.items[] | select(.n == 671 or .n == 680) | .state] | join(" ")' "$runfile")" 'the run file records both states'
assert_eq "$wt2" "$(jq -r '.items[] | select(.n == 680) | .worktree' "$runfile")" 'the run file records the successor worktree'
assert_eq 1 "$(($(grep -c 'api graphql' "$FAKE_GH_LOG") - reads))" 'collect reads the board once for the successor it moves'

printf 'stray\n' >stray.txt
out=$("$AK" collect --issue 693 2>&1)
assert_contains "$out" 'cross-write=stray.txt' 'a new root change is reported'
out=$("$AK" collect --issue 671 2>&1)
assert_not_contains "$out" 'spawn' 'a successor spawns once'

jq --arg wt "$wt" '.items += [{kind: "pr", n: 9, worktree: $wt, branch: "feat/issue-671", state: "spawned", needs: []}]' \
    "$runfile" >"$runfile.tmp" && mv "$runfile.tmp" "$runfile"
rm -f stray.txt
out=$("$AK" collect --pr 9 2>&1)
assert_eq 'pr=9 ci=green review=done note=findings=2 fixed=2 declined=0' "$out" 'collect --pr prints the pr line'

# A head that moved past the worker's result (a base update) is read live, not from the stale result (field run: a
# root collected ci=red after the updated head had gone green).
printf 'pr=9\nci=red\nreview=done\nhead=abc\nnote=n\n' >"$wt/.ak/result"
routes=$(cat "$FAKE_GH_ROUTES")
pr_file="$WORK/pr9.json" runs_file="$WORK/runs-def.json"
printf '{"number":9,"head":{"sha":"def4567"}}' >"$pr_file"
printf '{"check_runs":[{"name":"test","status":"completed","conclusion":"success"}]}' >"$runs_file"
printf 'api repos/acme/widget/pulls/9\t%s\t0\napi repos/acme/widget/commits/def4567/check-runs*\t%s\t0\n%s\n' \
    "$pr_file" "$runs_file" "$routes" >"$FAKE_GH_ROUTES"
out=$("$AK" collect --pr 9 2>&1)
assert_contains "$out" 'pr=9 ci=green' 'a moved head reports its live CI'
assert_contains "$out" 'ci read live at def4567; review covers abc' 'collect says it read CI live'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"

# The stack parent is the latest predecessor in run order, wherever it sits in the needs list (a field successor whose
# needs were [blocker, colliding, colliding] was based on the branch below its blocker).
git -C "$repo" push -q origin "origin/main:refs/heads/feat/issue-693" 2>/dev/null
git -C "$wt" push -q origin "HEAD:refs/heads/feat/issue-671"
jq --arg wt693 "$repo/.worktrees/feat/issue-693" '.items += [{kind:"issue",n:692,worktree:"",branch:"feat/issue-692",state:"queued",needs:[671,693]}] |
    .items |= ([{kind:"pr",n:671,worktree:"",branch:"x",state:"collected",needs:[]}] + map(select(.n == 693)) + map(select(.n != 693)))' "$runfile" >"$runfile.tmp" && mv "$runfile.tmp" "$runfile"
routes=$(cat "$FAKE_GH_ROUTES")
printf 'api repos/acme/widget/pulls?state=open&head=acme:feat/issue-692*\t%s\t0\n%s\n' "$WORK/empty.json" "$routes" >"$FAKE_GH_ROUTES"
printf '[]' >"$WORK/empty.json"
printf 'pr=https://github.com/acme/widget/pull/12\nci=green\nreview=done\nhead=def\nnote=n\n' >"$repo/.worktrees/feat/issue-693/.ak/result"
out=$("$AK" collect --issue 693 2>&1)
assert_contains "$out" 'spawn issue=692' 'the successor of two collected issues spawns'
assert_eq feat/issue-671 "$(cat "$repo/.worktrees/feat/issue-692/.ak/base")" 'its base is the predecessor latest in run order (a PR item sharing the number does not count), not the last listed need'
printf '%s\n' "$routes" >"$FAKE_GH_ROUTES"

out=$(AK_SLOW_NOTICE=0 "$AK" collect --pr 9 2>&1)
assert_contains "$out" 'ak collect: still working; wait for this call to finish' 'a slow collect says to wait for it'
out=$("$AK" collect --issue 12345 2>&1); rc=$?
assert_eq 1 "$rc" 'an issue outside the run refuses'
assert_contains "$out" 'fix: ' 'the refusal names the fix'
out=$("$AK" collect 2>&1); rc=$?
assert_eq 2 "$rc" 'collect needs --issue or --pr'

# A later plan makes another run current; collecting an item from the earlier run still finds it (field run
# 2026-10-01: a second issue was planned while the first was still out).
"$AK" plan --issue 700 >/dev/null 2>&1
assert_not_contains "$(jq -r '.items[].n' "$repo/.ak/runs/$(cat "$repo/.ak/runs/current").json")" '693' 'the newer run is current'
printf 'pr=https://github.com/acme/widget/pull/11\nci=green\nreview=done\nhead=def\nnote=findings=0 fixed=0 declined=0\n' \
    >"$repo/.worktrees/feat/issue-693/.ak/result"
out=$("$AK" collect --issue 693 2>&1); rc=$?
assert_eq 0 "$rc" 'an item from an earlier run is still collectable'
assert_contains "$out" 'issue=693 pr=https://github.com/acme/widget/pull/11' 'collect finds the item in its own run'
assert_eq collected "$(jq -r '.items[] | select(.n == 693) | .state' "$runfile")" 'the earlier run file records the collection'

finish
