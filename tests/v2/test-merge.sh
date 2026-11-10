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
# receipt_comment HEAD REVIEW [LOGIN]: one issue comment shaped like the receipt ak posts.
receipt_comment() {
    jq -cn --arg b "This was written agentically; verify its assertions:"$'\n\n'"**ak receipt** for head \`$1\`"$'\n\n'"- Reviewer: m (review=$2)"$'\n'"- CI: green" \
        --arg u "${3:-bot}" '{body: $b, user: {login: $u}}'
}
# reviewed N...: PR N carries this account's receipt for its head shaN with a completed review.
reviewed() {
    local n
    route 'api user --jq .login' 'bot'
    for n in "$@"; do
        route "api --paginate $api/issues/$n/comments?per_page=100" "[$(receipt_comment "sha$n" "done")]"
    done
}
reviewed 14 15 17 18 19 21 22 23 24 25 26 27 29 30
green=$(runs 'completed:"success"' 'completed:"skipped"' 'completed:"neutral"')
route "api $api/commits/*/check-runs?per_page=100 --paginate" '{"check_runs":[]}'

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
route "api -X GET $api/pulls -f state=open -f head=acme:feat/a -F per_page=100" '[{"number":24}]'
route "api -X GET $api/pulls -f state=open -f head=acme:feat/p+q -F per_page=100" '[]'
route "api -X GET $api/pulls -f state=open -f head=acme:* -F per_page=100" '[]'
route "api -X GET $api/pulls -f state=closed -f head=acme:feat/gone -F per_page=100" '[{"number":20,"merged_at":"2026-09-30T00:00:00Z","base":{"ref":"main"}}]'
route "api -X GET $api/pulls -f state=closed -f head=acme:feat/p+q -F per_page=100" '[{"number":16,"merged_at":"2026-09-30T00:00:00Z","base":{"ref":"main"}}]'
route "api -X GET $api/pulls -f state=closed -f head=acme:* -F per_page=100" '[]'
route "api -X GET $api/pulls -f state=open -f base=feat/a -F per_page=1" '[{"number":25,"head":{"ref":"feat/b"}}]'
route "api -X GET $api/pulls -f state=open -f base=feat/x&y -F per_page=1" '[{"number":40}]'
route "api -X GET $api/pulls -f state=open -f base=feat/lost -F per_page=1" 'gh: boom' 1
route "api -X GET $api/pulls -f state=open -f base=feat/w -F per_page=1" '[{"number":41}]'
route "api -X GET $api/pulls -f state=open -f base=* -F per_page=1" '[]'
route "api -X GET $api/pulls -f state=open -f base=feat/a -F per_page=100" '[{"number":25,"head":{"ref":"feat/b"}}]'
route "api -X GET $api/pulls -f state=open -f base=feat/x&y -F per_page=100" '[{"number":40,"head":{"ref":"feat/dep"}}]'
route "api $api/merges -f base=feat/dep -f head=feat/x&y*" '{"sha":"mergeddown"}'
route "api -X PATCH $api/pulls/40 -f base=main" '{}'
route "api $api/pulls/17" "$(pr_json 17 feat/k feat/p+q)"
route "api --paginate $api/commits/sha17/check-runs*" "$green"
route "api $api/merges -f base=feat/k -f head=feat/p+q*" '{"sha":"mergedparent"}'
route "api -X PATCH $api/pulls/17 -f base=main" '{}'
route "api $api/merges -f base=feat/b -f head=feat/a*" '{"sha":"mergedown"}'
route "api -X PATCH $api/pulls/25 -f base=main" '{}'
route "api -X GET $api/pulls -f state=open -f base=* -F per_page=1" '[]'
route "api -X GET $api/pulls -f state=open -f base=* -F per_page=100" '[]'
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

# The first matching route wins, so the punctuated run list goes in front of the shared ones.
cp "$FAKE_GH_ROUTES" "$WORK/routes.keep"
: >"$FAKE_GH_ROUTES"
route "api --paginate $api/commits/sha21/check-runs*" '{"check_runs":[{"name":"build:test","status":"completed","conclusion":"success"}]}'
cat "$WORK/routes.keep" >>"$FAKE_GH_ROUTES"
out=$(AGENT_REQUIRED_CHECKS='build:test' "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 0 "$rc" 'a required name with punctuation matches the run it names'
# The sanitised spelling of another run does not stand in for the required name.
: >"$FAKE_GH_ROUTES"
route "api --paginate $api/commits/sha21/check-runs*" '{"check_runs":[{"name":"buildtest","status":"completed","conclusion":"success"}]}'
cat "$WORK/routes.keep" >>"$FAKE_GH_ROUTES"
out=$(AGENT_REQUIRED_CHECKS='build:test' "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 1 "$rc" 'a run named buildtest does not satisfy a required build:test'
assert_contains "$out" 'missing=buildtest' 'the refusal names the missing check'
# A skipped run does not satisfy a required name.
: >"$FAKE_GH_ROUTES"
route "api --paginate $api/commits/sha21/check-runs*" '{"check_runs":[{"name":"lint","status":"completed","conclusion":"skipped"}]}'
cat "$WORK/routes.keep" >>"$FAKE_GH_ROUTES"
out=$(AGENT_REQUIRED_CHECKS='lint' "$AK" merge --pr 21 2>&1); rc=$?
assert_eq 1 "$rc" 'a skipped run does not satisfy a required check'
assert_contains "$out" 'missing=lint' 'the refusal names the skipped required check'
cp "$WORK/routes.keep" "$FAKE_GH_ROUTES"

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
assert_contains "$log" "api -X GET $api/pulls -f state=open -f base=feat/a -F per_page=1" 'the dependent check is one single-item list call with the ref as an encoded field'
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
for call in update-branch 'pr ready' '/merge'; do
    assert_not_contains "$(cat "$FAKE_GH_LOG")" "$call" "an unknown method refuses before any '$call' call"
done

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

# A branch name with query-string characters is a valid Git ref: it is passed as an encoded field, never refused.
route "api $api/pulls/19" "$(pr_json 19 'feat/x&y' main)"
route "api --paginate $api/commits/sha19/check-runs*" "$green"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 19 2>&1); rc=$?
assert_eq 0 "$rc" 'a head branch with an ampersand still merges'
assert_contains "$out" 'merged pr=19 sha=merged123 method=merge' 'a dependent on an odd-named parent makes it a merge commit'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X GET $api/pulls -f state=open -f base=feat/x&y -F per_page=1" 'the odd name goes in as an encoded field'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X GET $api/pulls -f state=open -f base=feat/x&y -F per_page=100" 'the dependents lookup encodes the odd name too'
assert_contains "$out" 'branch=deleted (retargeted #40 to main)' 'a dependent of an odd-named branch is retargeted before the delete'

# A dependents lookup that fails never falls back to a squash: a stacked parent squashed by guesswork strands its child.
route "api $api/pulls/14" "$(pr_json 14 feat/lost main)"
route "api --paginate $api/commits/sha14/check-runs*" "$green"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 14 2>&1); rc=$?
assert_eq 1 "$rc" 'a failed dependents lookup refuses the merge'
assert_contains "$out" 'cannot list PRs based on feat/lost; not merging' 'the refusal names the branch'
assert_contains "$out" 'fix: ak merge --pr 14' 'the refusal says to run it again'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '/merge' 'nothing is merged'

# Repository identity is case-insensitive: GitHub may report the owner or name in another case than the slug.
route "api $api/pulls/18" "$(pr_json 18 feat/w main false ACME/Widget)"
route "api --paginate $api/commits/sha18/check-runs*" "$green"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 18 2>&1); rc=$?
assert_eq 0 "$rc" 'a same-repository PR reported in another case merges'
assert_contains "$out" 'merged pr=18 sha=merged123 method=merge' 'it is not misread as a fork'
assert_contains "$out" 'branch=deleted' 'its branch is deleted, not kept as a fork'
assert_not_contains "$out" 'kept (fork)' 'a case difference is not a fork'

# A fix hint never carries a branch name as executable text (the unrouted compare call fails like a broken API).
# shellcheck disable=SC2016 # the literal $(x) is the point
evil='feat/$(x)'
route "api $api/pulls/15" "$(pr_json 15 feat/m "$evil")"
route "api --paginate $api/commits/sha15/check-runs*" "$green"
out=$("$AK" merge --pr 15 2>&1); rc=$?
assert_eq 1 "$rc" 'a failed lookup on an odd-named base refuses'
assert_contains "$out" 'fix: gh api repos/acme/widget/compare/main...feat/\$\(x\)' 'the hint shell-quotes the branch name'

# merge_parent passes a base branch with query-string characters as encoded fields too.
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 17 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR based on an odd-named merged parent merges'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" "api -X GET $api/pulls -f state=open -f head=acme:feat/p+q -F per_page=100" 'the open-head lookup encodes the base'
assert_contains "$log" "api -X GET $api/pulls -f state=closed -f head=acme:feat/p+q -F per_page=100" 'the closed-head lookup encodes the base'
assert_contains "$log" "api -X GET $api/pulls -f state=open -f base=feat/p+q -F per_page=1" 'the last-child lookup encodes the base'

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
printf '1\n' >"$WORK/wtq/.ak/spawns"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 30 2>&1); rc=$?
assert_eq 3 "$rc" 'a conflicting PR exits 3'
assert_contains "$out" 'resolve pr=30 conflicts-with=main' 'the conflict is named'
assert_contains "$out" "spawn pr=30 cwd=$WORK/wtq prompt=$WORK/wtq/.ak/prompt.md" 'the PR worker is respawned in its worktree'
assert_contains "$out" 'name=pr_30_2' 'the respawn carries a new native name: the first worker still holds pr_30'
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
reviewed 40
route "api $api/pulls/40" "$(pr_json 40 feat/t main)"
route "api --paginate $api/commits/sha40/check-runs*" "$green"
route "api $api/commits/*/check-runs?per_page=100 --paginate" "$green"
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
reviewed 43 44
route "api $api/pulls/43" "$(pr_json 43 feat/docs feat/parked)"
route "api $api/pulls/44" "$(pr_json 44 feat/docs2 feat/empty)"
route "api --paginate $api/commits/sha4*/check-runs*" "$green"
route "api $api/commits/*/check-runs?per_page=100 --paginate" "$green"
route "api -X GET $api/pulls -f state=* -f head=acme:* -F per_page=100" '[]'
route "api -X GET $api/pulls -f state=open -f base=* -F per_page=1" '[]'
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

# A PR merges only under a completed adversarial review of its head: the receipt comment this account posted is the
# record. A review the reviewer could not run posted a receipt too, the collect line said ci=green, and the PR merged.
: >"$FAKE_GH_ROUTES"
route 'api user --jq .login' 'bot'
for n in 50 51 52 53 54 55 56 57 58; do route "api $api/pulls/$n" "$(pr_json "$n" "feat/r$n" main)"; done
route "api --paginate $api/commits/sha5*/check-runs*" "$green"
route "api $api/commits/*/check-runs?per_page=100 --paginate" "$green"
route "api -X GET $api/pulls -f state=open -f base=* -F per_page=*" '[]'
route "api -X PUT $api/pulls/*/update-branch*" 'gh: There are no new commits on the base branch. (HTTP 422)' 1
route "api -X PUT $api/pulls/* -f merge_method=squash -f sha=sha*" '{"sha":"merged123","merged":true}'
route "api -X DELETE $api/git/refs/heads/*" ''
# commit SHA PARENT...: a commit made in a clone; github_merge SHA PARENT PARENT: one GitHub itself made (update-branch,
# the merges API), which carries GitHub's committer.
commit() { printf '{"sha":"%s","committer":{"login":"%s"},"parents":[%s]}' "$1" "${COMMITTER:-dev}" "$(printf '{"sha":"%s"},' "${@:2}" | sed 's/,$//')"; }
github_merge() { COMMITTER=web-flow commit "$@"; }
route "api --paginate $api/issues/50/comments?per_page=100" '[{"body":"looks good","user":{"login":"bot"}}]'
route "api --paginate $api/issues/51/comments?per_page=100" "[$(receipt_comment sha51 'unavailable: timeout')]"
route "api --paginate $api/issues/52/comments?per_page=100" "[$(receipt_comment sha52 "done" mallory)]"
route "api --paginate $api/issues/53/comments?per_page=100" "[$(receipt_comment old53 "done")]"
route "api --paginate $api/pulls/53/commits?per_page=100" "[$(commit first53 root),$(commit old53 first53),$(github_merge sha53 old53 main1)]"
route "api --paginate $api/issues/54/comments?per_page=100" "[$(receipt_comment old54 "done")]"
route "api --paginate $api/pulls/54/commits?per_page=100" "[$(commit old54 root),$(commit extra54 old54),$(github_merge sha54 extra54 main1)]"
route "api --paginate $api/issues/55/comments?per_page=100" "[$(receipt_comment sha55 "done"),$(receipt_comment new55 unavailable)]"
route "api --paginate $api/issues/56/comments?per_page=100" "[$(receipt_comment gone56 "done")]"
route "api --paginate $api/pulls/56/commits?per_page=100" "[$(commit sha56 root)]"
route "api --paginate $api/issues/57/comments?per_page=100" "[$(receipt_comment old57 "done")]"
route "api --paginate $api/pulls/57/commits?per_page=100" "[$(commit old57 root),$(commit sha57 old57 other1)]"
route "api --paginate $api/issues/58/comments?per_page=100" "[$(receipt_comment old58 "done")]"
route "api --paginate $api/pulls/58/commits?per_page=100" "$(jq -cn --argjson old "$(commit old58 root)" --argjson top "$(github_merge sha58 old58 main1)" '[$old] + [range(248) | {sha: "pad\(.)", committer: {login: "web-flow"}, parents: [{sha: "a"}, {sha: "b"}]}] + [$top]')"
refused() { # N WHY
    : >"$FAKE_GH_LOG"
    out=$("$AK" merge --pr "$1" 2>&1); rc=$?
    assert_eq 1 "$rc" "$2 is refused"
    assert_contains "$out" "fix: ak pr-plan --pr $1" "$2 sends the PR back to a worker"
    assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' "$2 merges nothing"
    assert_not_contains "$(cat "$FAKE_GH_LOG")" 'check-runs' "$2 is refused before any CI wait"
}
refused 50 'a PR with no receipt'
assert_contains "$out" 'PR #50 has no ak receipt, so no adversarial review of it is recorded' 'the refusal says no review is recorded'
refused 51 'a receipt whose review could not run'
assert_contains "$out" 'the receipt on PR #51 records review=unavailable: timeout' 'the refusal carries the recorded reason'
refused 52 'a receipt another account posted'
refused 54 'a head with an unreviewed commit since the receipt'
assert_contains "$out" 'the receipt on PR #54 reviews old54; not covered: extra54' 'the refusal names the commit the review never saw'
refused 55 'a newer receipt without a review'
refused 56 'a receipt for a commit the PR no longer holds'
# A merge commit made in a clone can carry any change (a conflict resolution, an edit); only GitHub's own are exempt.
refused 57 'a head that left the reviewed commit through a merge commit made in a clone'
assert_contains "$out" 'not covered: sha57' 'the refusal names the hand-made merge'
refused 58 'a PR whose commit list GitHub cuts off at 250'
out=$("$AK" merge --pr 53 2>&1); rc=$?
assert_eq 0 "$rc" 'a head that left the reviewed commit only through merge commits GitHub made merges'
assert_contains "$out" 'merged pr=53' 'the base-updated PR is merged'

# The head that is merged is the head that was checked: a push landing while ak merge waits for CI used to be merged
# unreviewed and with no check read on it.
route "api $api/pulls/59" "$(pr_json 59 feat/r59 main)" 0 once
route "api $api/pulls/59" "$(pr_json 59 feat/r59 main | jq -c '.head.sha = "moved59"')"
route "api --paginate $api/issues/59/comments?per_page=100" "[$(receipt_comment sha59 "done")]"
route "api --paginate $api/pulls/59/commits?per_page=100" "[$(commit sha59 root),$(commit moved59 sha59)]"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 59 2>&1); rc=$?
assert_eq 1 "$rc" 'a head that moved to an unreviewed commit during the merge is refused'
assert_contains "$out" 'not covered: moved59' 'the refusal names the commit pushed meanwhile'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'the moved head is not merged'
route "api $api/pulls/60" "$(pr_json 60 feat/r60 main)" 0 once
route "api $api/pulls/60" "$(pr_json 60 feat/r60 main | jq -c '.head.sha = "shamoved60"')"
route "api --paginate $api/issues/60/comments?per_page=100" "[$(receipt_comment sha60 "done")]"
route "api --paginate $api/pulls/60/commits?per_page=100" "[$(commit sha60 root),$(github_merge shamoved60 sha60 main1)]"
route "api --paginate $api/commits/sha60/check-runs*" "$green"
route "api --paginate $api/commits/shamoved60/check-runs*" "$(runs 'completed:"failure"')"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 60 2>&1); rc=$?
assert_eq 1 "$rc" 'a head GitHub moved during the merge has its own checks read'
assert_contains "$out" 'checks are not green on shamoved60' 'the refusal names the moved head'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'the red moved head is not merged'

# A review bot that starts when a draft is marked ready was cut off by the merge that followed at once: on 29 of 75
# sampled PRs its check ended cancelled a minute after the PR closed. AGENT_READY_CHECKS names checks that must
# succeed on the head once the PR is ready; the threads they leave are read before the merge.
thread='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"T9","isResolved":false,"path":"a","line":1,"comments":{"nodes":[{"author":{"login":"reviewbot"},"body":"bug"}]}}]}}}}}'
for n in 61 62 63; do route "api $api/pulls/$n" "$(pr_json "$n" "feat/r$n" main true)"; done
reviewed 61 62 63
route "pr ready *" ''
bot_done=$(runs 'completed:"success"' | jq -c '.check_runs += [{"name":"Review Bot","status":"completed","conclusion":"success"}]')
route "api --paginate $api/commits/sha61/check-runs*" "$(runs 'completed:"success"' | jq -c '.check_runs += [{"name":"Review Bot","status":"completed","conclusion":"skipped"}]')"
route "api $api/commits/sha61/check-runs?per_page=100 --paginate" "$(runs 'completed:"success"')"
route "api --paginate $api/commits/sha6[23]/check-runs*" "$bot_done"
route "api $api/commits/sha6[23]/check-runs?per_page=100 --paginate" "$bot_done"
route 'api graphql -F owner=acme -F name=widget -F n=62 *' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' 0 once
route 'api graphql -F owner=acme -F name=widget -F n=62 *' "$thread"
export AGENT_READY_CHECKS='Review Bot'
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 61 2>&1); rc=$?
assert_eq 1 "$rc" 'a ready check that has not succeeded on the head refuses the merge'
assert_contains "$out" 'missing=Review Bot' 'the refusal names the check'
assert_contains "$(cat "$FAKE_GH_LOG")" 'pr ready 61' 'the PR was marked ready so the check could start'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'nothing merges without the ready check'
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 62 2>&1); rc=$?
assert_eq 1 "$rc" 'threads the ready check left refuse the merge'
assert_contains "$out" 'PR #62 has 1 unresolved review threads (reviewbot: 1)' 'the refusal counts the new threads'
assert_contains "$out" 'fix: ak pr-plan --pr 62' 'and sends the PR back to a worker'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'nothing merges over the new threads'
out=$("$AK" merge --pr 63 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR whose ready check succeeded and left no threads merges'
unset AGENT_READY_CHECKS
out=$("$AK" merge --pr 61 2>&1); rc=$?
assert_eq 0 "$rc" 'with no ready checks named, a draft merges as before'

# Threads posted on a head that moved during the merge (a bot reviewing the base update) are read too.
route "api $api/pulls/64" "$(pr_json 64 feat/r64 main)" 0 once
route "api $api/pulls/64" "$(pr_json 64 feat/r64 main | jq -c '.head.sha = "shamoved64"')"
route "api --paginate $api/issues/64/comments?per_page=100" "[$(receipt_comment sha64 "done")]"
route "api --paginate $api/pulls/64/commits?per_page=100" "[$(commit sha64 root),$(github_merge shamoved64 sha64 main1)]"
route "api --paginate $api/commits/sha64/check-runs*" "$green"
route "api --paginate $api/commits/shamoved64/check-runs*" "$green"
route 'api graphql -F owner=acme -F name=widget -F n=64 *' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[]}}}}}' 0 once
route 'api graphql -F owner=acme -F name=widget -F n=64 *' "$thread"
: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 64 2>&1); rc=$?
assert_eq 1 "$rc" 'threads posted on a head that moved during the merge refuse it'
assert_contains "$out" 'PR #64 has 1 unresolved review threads' 'the refusal counts them'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'merge_method=' 'the moved head with open threads is not merged'

finish
