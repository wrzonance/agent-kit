#!/usr/bin/env bash
# ak merge: squash-merge a green PR at its checked head; keep a branch another open PR is based on.
TEST_NAME=v2-merge
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

repo=$(fixture_repo)
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
route "api $api/pulls?state=open&base=feat/a*" '[{"number":25}]'
route "api $api/pulls?state=open&base=*" '[]'
route "pr ready *" ''
route "api -X PATCH $api/pulls/26 -f base=main" '{}'
route "api -X PUT $api/pulls/* -f merge_method=squash -f sha=sha*" '{"sha":"merged123","merged":true}'
route "api -X DELETE $api/git/refs/heads/*" ''

out=$("$AK" merge 2>&1); rc=$?
assert_eq 2 "$rc" 'no --pr is a usage error'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 21 2>&1); rc=$?
assert_eq 0 "$rc" 'a green PR merges'
assert_eq 'merged pr=21 sha=merged123 branch=deleted' "$out" 'merge prints the sha and branch fate'
log=$(cat "$FAKE_GH_LOG")
assert_contains "$log" 'pr ready 21 --repo acme/widget' 'a draft is marked ready'
assert_contains "$log" "api -X PUT $api/pulls/21/merge -f merge_method=squash -f sha=sha21" 'the merge is pinned to the checked head'
assert_contains "$log" "api -X DELETE $api/git/refs/heads/feat/x" 'the head branch is deleted'

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
assert_eq 'merged pr=24 sha=merged123 branch=kept (base of #25)' "$out" 'a base of another open PR is kept'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X DELETE' 'no delete for a base branch'
assert_not_contains "$(cat "$FAKE_GH_LOG")" 'pr ready' 'a non-draft is not flipped'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 25 2>&1); rc=$?
assert_eq 1 "$rc" 'a PR stacked on an open PR is refused'
assert_contains "$out" 'fix: ak merge --pr 24' 'the refusal names the parent merge'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' 'the stacked PR is not merged'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 26 2>&1); rc=$?
assert_eq 0 "$rc" 'a PR whose parent already merged is retargeted and merged'
assert_contains "$(cat "$FAKE_GH_LOG")" "api -X PATCH $api/pulls/26 -f base=main" 'retargeted to the repo base'
assert_contains "$out" 'merged pr=26' 'then merged'

out=$("$AK" merge --pr 27 2>&1)
assert_eq 'merged pr=27 sha=merged123 branch=kept (fork)' "$out" 'a fork branch is never deleted'

: >"$FAKE_GH_LOG"
out=$("$AK" merge --pr 28 2>&1); rc=$?
assert_eq 0 "$rc" 'an already merged PR is not an error'
assert_eq 'merged pr=28 sha=m28 already' "$out" 'an already merged PR reports its sha'
assert_not_contains "$(cat "$FAKE_GH_LOG")" '-X PUT' 'no second merge'

finish
