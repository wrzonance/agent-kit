#!/usr/bin/env bash
# ak merge: merge a green PR at its checked head (a merge commit while a child PR is stacked on it, a squash otherwise);
# keep a branch another open PR is based on.
TEST_NAME=v2-merge
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
export AK_CI_GRACE=0 AK_CI_INTERVAL=0 AK_MERGE_CI_TIMEOUT=0
cd "$repo" || exit 1
api=repos/acme/widget

pr_json() { # N HEAD BASE [DRAFT] [HEAD_REPO] [STATE] [MERGED]
    printf '{"number":%s,"state":"%s","draft":%s,"merged":%s,"merge_commit_sha":"m%s","head":{"ref":"%s","sha":"sha%s","repo":{"full_name":"%s"}},"base":{"ref":"%s"}}' \
        "$1" "${6:-open}" "${4:-false}" "${7:-false}" "$1" "$2" "$1" "${5:-acme/widget}" "$3"
}
runs() { # STATUS:CONCLUSION...
    local items='' s
    for s in "$@"; do
        items+="{\"name\":\"job-${s%%:*}\",\"status\":\"${s%%:*}\",\"conclusion\":${s#*:}},"
    done
    printf '{"total_count":%d,"check_runs":[%s]}' "$#" "${items%,}"
}
green=$(runs 'completed:"success"' 'completed:"skipped"' 'completed:"neutral"')
route "api $api/commits/*/check-runs?per_page=100" '{"check_runs":[]}'

route "api $api/pulls/21" "$(pr_json 21 feat/x main true)"
route "api --paginate $api/commits/sha21/check-runs*" "$green"
route "api $api/pulls/22" "$(pr_json 22 feat/p main)"
route "api --paginate $api/commits/sha22/check-runs*" "$(runs 'completed:"success"' 'in_progress:null')"
route "api $api/pulls/23" "$(pr_json 23 feat/r main)"
route "api --paginate $api/commits/sha23/check-runs*" "$(runs 'completed:"failure"')"
route "api $api/pulls/24" "$(pr_json 24 feat/a main)"
route "api --paginate $api/commits/sha24/check-runs*" "$green"
route "api $api/pulls/25" "$(pr_json 25 feat/b feat/a)"
route "api --paginate $api/commits/sha25/check-runs*" "$green"
route "api $api/pulls/26" "$(pr_json 26 feat/c feat/gone)"
route "api --paginate $api/commits/sha26/check-runs*" "$green"
route "api $api/pulls/27" "$(pr_json 27 feat/y main false someone/fork)"
route "api --paginate $api/commits/sha27/check-runs*" "$green"
route "api $api/pulls/28" "$(pr_json 28 feat/z main false acme/widget closed true)"
route "api $api/pulls/29" "$(pr_json 29 feat/n main)"
route "api --paginate $api/commits/sha29/check-runs*" '{"total_count":0,"check_runs":[]}'
route "api $api/pulls?state=open&head=acme:feat/a*" '[{"number":24}]'
route "api $api/pulls?state=open&head=acme:*" '[]'
route "api $api/pulls?state=closed&head=acme:feat/gone*" '[{"number":20,"merged_at":"2026-09-30T00:00:00Z","base":{"ref":"main"}}]'
route "api $api/pulls?state=closed&head=acme:*" '[]'
route "api $api/pulls?state=open&base=feat/a*" '[{"number":25,"head":{"ref":"feat/b"}}]'
route "api $api/merges -f base=feat/b -f head=feat/a*" '{"sha":"mergedown"}'
route "api -X PATCH $api/pulls/25 -f base=main" '{}'
route "api $api/pulls?state=open&base=*" '[]'
route "pr ready *" ''
route "api -X PATCH $api/pulls/26 -f base=main" '{}'
route "api $api/merges -f base=feat/c -f head=feat/gone*" '{"sha":"mergedparent"}'
route "api -X PUT $api/pulls/* -f merge_method=squash -f sha=sha*" '{"sha":"merged123","merged":true}'
route "api -X PUT $api/pulls/* -f merge_method=merge -f sha=sha*" '{"sha":"merged123","merged":true}'
route "api -X PUT $api/pulls/3[0-9]/update-branch*" 'gh: Merge conflict between base and head (HTTP 422)' 1
route "api -X PUT $api/pulls/*/update-branch*" 'gh: There are no new commits on the base branch. (HTTP 422)' 1
route "api -X DELETE $api/git/refs/heads/*" ''

out=$("$AK" merge 2>&1); rc=$?
assert_eq 2 "$rc" 'no --pr is a usage error'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 21 2>&1); rc=$?
assert_eq 0 "$rc" 'a green PR merges'
assert_eq 'merged pr=21 sha=merged123 method=squash branch=deleted' "$(tail -n 1 <<<"$out")" 'merge prints the sha, method and branch fate'
assert_contains "$out" 'ci pending on sha21: wait on this with the longest wait your shell allows' 'a CI wait says how to wait on it'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" 'pr ready 21 --repo acme/widget' 'a draft is marked ready'
assert_contains "$log" "api -X PUT $api/pulls/21/merge -f merge_method=squash -f sha=sha21" 'a PR with no dependents is squash-merged, pinned to the checked head'
assert_contains "$log" "api -X DELETE $api/git/refs/heads/feat/x" 'the head branch is deleted'

# A required check with no completed run on the head refuses the merge (field run 2026-10-05: a conflicted stacked PR
# got only CodeQL and a push lint on its head, and every reader called it green).
: >"$FAKE_GH_LOG"
out=$(AGENT_REQUIRED_CHECKS=Installer "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 1 "$rc" 'a missing required check refuses the merge'
assert_contains "$out" 'checks are not green on sha21: missing=Installer' 'the refusal names the missing check'
assert_contains "$out" 'fix: ak ci --once' 'the required-check refusal names ak ci --once'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' 'nothing is merged without the required check'
out=$(AGENT_REQUIRED_CHECKS='job-completed' "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 0 "$rc" 'a required check that completed on the head merges'

for n in 22 23 29; do
    : >"$FAKE_GH_LOG"
    out=$("$AK" merge --pr "$n" 2>&1); rc=$?
    assert_eq 1 "$rc" "PR $n with non-green checks is refused"
    assert_contains "$out" 'fix: ak ci --once' "PR $n refusal names ak ci --once"
    assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' "PR $n is not merged"
done
out=$("$AK" merge --pr 22 2>&1)
assert_contains "$out" 'job-in_progress' 'the refusal names the pending check'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 24 2>&1); rc=$?
# Merging a stack's parent hands its child to main and deletes the parent branch (a field stack left merged
# branches behind, and a later merge landed a PR in one of them).
assert_eq 'merged pr=24 sha=merged123 method=merge branch=deleted (retargeted #25 to main)' "$(tail -n 1 <<<"$out")" 'the stacked child is retargeted and the parent branch deleted'
log=$(cat "$FAKE_GH_LOG")
at() { grep -nF -- "$1" <<<"$log" | head -n 1 | cut -d: -f1; }
down=$(at 'merges -f base=feat/b -f head=feat/a') patch=$(at "PATCH $api/pulls/25 -f base=main") del=$(at "DELETE $api/git/refs/heads/feat/a")
assert_eq yes "$([[ -n $down && -n $patch && -n $del && $down -lt $patch && $patch -lt $del ]] && echo yes || echo no)" \
    'the child gets the final branch, then its new base, then the parent branch is deleted'
assert_contains "$log" "api $api/git/ref/heads/feat/a" 'the delete is confirmed'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'pr ready' 'a non-draft is not flipped'

# A stack's parent merges as a merge commit so main carries the commits its child already has (field run 2026-10-05:
# every child went dirty the moment its parent squash-merged, costing a resolve worker and a second CI round per link).
assert_contains "$log" "api -X PUT $api/pulls/24/merge -f merge_method=merge -f sha=sha24" 'a PR with an open dependent merges as a merge commit'
assert_contains "$log" "api $api/pulls?state=open&base=feat/a&per_page=1" 'the dependent check is one single-item list call'
: >"$FAKE_GH_LOG"
out=$(AGENT_MERGE_METHOD=squash "$AK" merge --pr 24 2>&1); rc=$?
assert_eq 0 "$rc" 'AGENT_MERGE_METHOD=squash still merges'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X PUT $api/pulls/24/merge -f merge_method=squash -f sha=sha24" 'AGENT_MERGE_METHOD=squash squashes a PR with a dependent'
assert_contains "$out" 'merged pr=24 sha=merged123 method=squash' 'the merged line names the forced method'
: >"$FAKE_GH_LOG"
out=$(AGENT_MERGE_METHOD=merge "$AK" merge --pr 21 2>&1)
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X PUT $api/pulls/21/merge -f merge_method=merge -f sha=sha21" 'AGENT_MERGE_METHOD=merge merge-commits a PR with no dependents'
assert_contains "$out" 'merged pr=21 sha=merged123 method=merge' 'the merged line names the forced method'
: >"$FAKE_GH_LOG"
out=$(AGENT_MERGE_METHOD=rebase "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 1 "$rc" 'an unknown AGENT_MERGE_METHOD refuses'
assert_contains "$out" 'AGENT_MERGE_METHOD=rebase is not squash or merge' 'the refusal names the bad value'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'nothing is merged under an unknown method'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 25 2>&1); rc=$?
assert_eq 1 "$rc" 'a PR stacked on an open PR is refused'
assert_contains "$out" 'fix: ak merge --pr 24' 'the refusal names the parent merge'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' 'the stacked PR is not merged'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 26 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR whose parent already merged is retargeted and merged'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X PATCH $api/pulls/26 -f base=main" 'retargeted to the repo base'
first=$(grep -n "merges -f base=feat/c -f head=feat/gone" "$FAKE_GH_LOG" | head -1 | cut -d: -f1)
patch=$(grep -n "PATCH $api/pulls/26" "$FAKE_GH_LOG" | head -1 | cut -d: -f1)
assert_eq yes "$( [[ -n $first && -n $patch && $first -lt $patch ]] && echo yes || echo no)" "the parent's final branch is merged in before the retarget"
assert_contains "$out" 'merged pr=26' 'then merged'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X DELETE $api/git/refs/heads/feat/gone" "the merged parent's branch is deleted once its last child moves off it"

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 27 2>&1)
assert_eq 'merged pr=27 sha=merged123 method=squash branch=kept (fork)' "$(tail -n 1 <<<"$out")" 'a fork branch is never deleted'
# A fork's head.ref is not a branch here: a same-named branch of this repository must not read as a dependent.
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X PUT $api/pulls/27/merge -f merge_method=squash -f sha=sha27" 'a fork PR squashes'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'base=feat/y' 'a fork PR gets no dependent lookup'

# A head branch name that cannot go into a query string squashes with a note instead of listing dependents.
route "api $api/pulls/19" "$(pr_json 19 'feat/x&base=main' main)"
route "api --paginate $api/commits/sha19/check-runs*" "$green"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 19 2>&1); rc=$?
assert_eq 0 "$rc" 'an unlistable head branch name still merges'
assert_contains "$out" 'note=head branch name not listable; squashing' 'the odd name is noted'
assert_contains "$out" 'merged pr=19 sha=merged123 method=squash' 'the odd name squashes'
assert_eq 0 "$(grep -cxF "api $api/pulls?state=open&base=feat/x&base=main&per_page=1" "$FAKE_GH_LOG")" 'the odd name never reaches the dependent lookup'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 28 2>&1); rc=$?
assert_eq 0 "$rc" 'an already merged PR is not an error'
assert_eq 'merged pr=28 sha=m28 already' "$out" 'an already merged PR reports its sha'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' 'no second merge'

# A PR that conflicts with its base after an earlier merge goes back to its worker (bench 2026-10-01: #112).
route "api $api/pulls/30" "$(pr_json 30 feat/q main)"
route "api --paginate $api/commits/sha30/check-runs*" "$green"
git worktree add -q -b feat/q "$WORK/wtq" origin/main
mkdir -p "$WORK/wtq/.ak" && printf 'prompt\n' >"$WORK/wtq/.ak/prompt.md" && printf 'pr=x\n' >"$WORK/wtq/.ak/result"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 30 2>&1); rc=$?
assert_eq 3 "$rc" 'a conflicting PR exits 3'
assert_contains "$out" 'resolve pr=30 conflicts-with=main' 'the conflict is named'
assert_contains "$out" "spawn pr=30 cwd=$WORK/wtq prompt=$WORK/wtq/.ak/prompt.md" 'the PR worker is respawned in its worktree'
assert_eq 'origin/main' "$(cat "$WORK/wtq/.ak/resolve")" 'the worktree records what to merge in'
assert_eq no "$([[ -e $WORK/wtq/.ak/result ]] && echo yes || echo no)" 'the stale result is cleared so collect waits for the new one'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'a conflicting PR is not merged'

# Two merges of one PR never run at once: the second waits for the first (bench 2026-10-01: #136 twice).
mkdir -p "$repo/.ak/locks/merge-24"
out=$(AK_MERGE_LOCK_WAIT=0 "$AK" merge --pr 24 2>&1); rc=$?
assert_eq 1 "$rc" 'a held merge lock refuses after the wait'
assert_contains "$out" 'another ak merge is working on PR #24' 'the refusal names the PR'
rmdir "$repo/.ak/locks/merge-24"
"$AK" merge --pr 24 >/dev/null 2>&1
assert_eq no "$([[ -d $repo/.ak/locks/merge-24 ]] && echo yes || echo no)" 'a finished merge releases its lock'


# A green PR with open review threads is not merged (a field root went to merge a PR carrying two code-quality threads).
: >"$FAKE_GH_ROUTES"
route "api $api/pulls/40" "$(pr_json 40 feat/t main)"
route "api --paginate $api/commits/sha40/check-runs*" "$green"
route "api $api/commits/*/check-runs?per_page=100" "$green"
route 'api graphql -F owner=acme -F name=widget -F n=40 *' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T1","isResolved":false,"path":"src/a.cs","line":294,"comments":{"nodes":[{"author":{"login":"github-code-quality"},"body":"Generic catch clause\nmore"}]}},{"id":"T2","isResolved":false,"path":"src/a.cs","line":231,"comments":{"nodes":[{"author":{"login":"github-code-quality"},"body":"Generic catch"}]}},{"id":"T3","isResolved":true,"path":"src/b.cs","line":1,"comments":{"nodes":[{"author":{"login":"alice"},"body":"done"}]}}]}}}}}'
route "api -X PUT $api/pulls/* -f merge_method=squash -f sha=sha*" '{"sha":"merged123","merged":true}'
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 40 2>&1); rc=$?
assert_eq 1 "$rc" 'a PR with open review threads is refused'
assert_contains "$out" 'PR #40 has 2 unresolved review threads (github-code-quality: 2)' 'the refusal counts the threads by author'
assert_contains "$out" 'fix: ak pr-plan --pr 40' 'the refusal sends the PR back to a worker'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'nothing is merged'


# A base branch with no PR is never merged into (a field merge squashed a docs PR into a parked issue's branch): an
# empty base retargets to the default branch first, and a base carrying unmerged work refuses.
: >"$FAKE_GH_ROUTES"
route "api $api/pulls/43" "$(pr_json 43 feat/docs feat/parked)"
route "api $api/pulls/44" "$(pr_json 44 feat/docs2 feat/empty)"
route "api --paginate $api/commits/sha4*/check-runs*" "$green"
route "api $api/commits/*/check-runs?per_page=100" "$green"
route "api $api/pulls?state=*" '[]'
route "api $api/compare/main...feat/parked*" '2'
route "api $api/compare/main...feat/empty*" '0'
route "api -X PATCH $api/pulls/44 -f base=main" '{}'
route "api -X PUT $api/pulls/*/update-branch*" 'gh: There are no new commits on the base branch. (HTTP 422)' 1
route "api -X PUT $api/pulls/* -f merge_method=squash -f sha=sha*" '{"sha":"merged123","merged":true}'
route "api -X DELETE $api/git/refs/heads/*" ''
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 43 2>&1); rc=$?
assert_eq 1 "$rc" 'a PR based on a branch with no PR and unmerged work is refused'
assert_contains "$out" 'PR #43 is based on feat/parked, which has no PR and 2 commits not on main' 'the refusal names the base and its work'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'nothing is merged into the side branch'
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 44 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR based on an empty branch with no PR merges'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" "api -X PATCH $api/pulls/44 -f base=main" 'it is retargeted to the default branch first'
patch=$(grep -n "PATCH $api/pulls/44" <<<"$log" | head -1 | cut -d: -f1)
merge=$(grep -n 'merge_method=squash' <<<"$log" | head -1 | cut -d: -f1)
assert_eq yes "$([[ -n $patch && -n $merge && $patch -lt $merge ]] && echo yes || echo no)" 'the retarget happens before the merge'

finish
