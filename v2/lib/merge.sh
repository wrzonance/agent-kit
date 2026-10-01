# shellcheck shell=bash
# ak merge --pr N: squash-merge a PR whose head checks are green, pinned to that head, then delete its
# branch unless another open PR is based on it.

# merge_checks SLUG SHA: refuse unless every check run on SHA completed as success, neutral or skipped.
merge_checks() {
    local slug=$1 sha=$2 runs bad
    runs=$(gh api --paginate "repos/$slug/commits/$sha/check-runs?per_page=100") ||
        die "cannot read the check runs on $sha" "ak ci --once"
    bad=$(jq -rs '[.[].check_runs[]
        | (if .conclusion != null or .status == "completed" then (.conclusion // "none") else .status end) as $s
        | select($s != "success" and $s != "neutral" and $s != "skipped")
        | "\(.name)=\($s)"] | .[:5] | join(" ")' <<<"$runs")
    [[ $(jq -s '[.[].check_runs[]] | length' <<<"$runs") -gt 0 ]] || die "no check runs on $sha yet" "ak ci --once"
    [[ -z $bad ]] || die "checks are not green on $sha: $bad" "ak ci --once"
}

# merge_parent SLUG N BASE: refuse while BASE is an open PR's head; retarget to the parent's base once it merged.
merge_parent() {
    local slug=$1 n=$2 base=$3 owner=${1%%/*} open parent
    [[ $base != "$(base_branch)" ]] || return 0
    open=$(gh api "repos/$slug/pulls?state=open&head=$owner:$base&per_page=100" | jq -r '.[0].number // empty') ||
        die "cannot list PRs with head $base" "gh api 'repos/$slug/pulls?state=open&head=$owner:$base'"
    [[ -z $open ]] || die "PR #$n is based on #$open's branch $base" "ak merge --pr $open"
    parent=$(gh api "repos/$slug/pulls?state=closed&head=$owner:$base&per_page=100" |
        jq -r '[.[] | select(.merged_at != null)][0].base.ref // empty') ||
        die "cannot list PRs with head $base" "gh api 'repos/$slug/pulls?state=closed&head=$owner:$base'"
    [[ -n $parent ]] || return 0
    gh api -X PATCH "repos/$slug/pulls/$n" -f "base=$parent" >/dev/null ||
        die "cannot retarget PR #$n to $parent" "gh api -X PATCH repos/$slug/pulls/$n -f base=$parent"
}

# merge_branch SLUG JSON: delete the merged head branch unless it is a fork's or another open PR's base.
merge_branch() {
    local slug=$1 json=$2 ref dependent
    ref=$(jq -r .head.ref <<<"$json")
    if [[ $(jq -r '.head.repo.full_name // ""' <<<"$json") != "$slug" ]]; then
        printf 'kept (fork)\n'
        return 0
    fi
    dependent=$(gh api "repos/$slug/pulls?state=open&base=$ref&per_page=100" | jq -r '.[0].number // empty') ||
        { printf 'kept (cannot list dependents)\n'; return 0; }
    if [[ -n $dependent ]]; then
        printf 'kept (base of #%s)\n' "$dependent"
    elif gh api -X DELETE "repos/$slug/git/refs/heads/$ref" >/dev/null 2>&1; then
        printf 'deleted\n'
    else
        printf 'kept (delete failed)\n'
    fi
}

cmd_main() {
    [[ $# -eq 2 && $1 == --pr && $2 =~ ^[0-9]+$ ]] || usage_die "usage: ak merge --pr N"
    local n=$2 slug json sha merged
    slug=$(slug)
    json=$(gh api "repos/$slug/pulls/$n") || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
    if [[ $(jq -r .merged <<<"$json") == true ]]; then
        printf 'merged pr=%s sha=%s already\n' "$n" "$(jq -r .merge_commit_sha <<<"$json")"
        return 0
    fi
    [[ $(jq -r .state <<<"$json") == open ]] || die "PR #$n is closed" "gh pr reopen $n --repo $slug"
    sha=$(jq -r .head.sha <<<"$json")
    merge_checks "$slug" "$sha"
    merge_parent "$slug" "$n" "$(jq -r .base.ref <<<"$json")"
    if [[ $(jq -r .draft <<<"$json") == true ]]; then
        gh pr ready "$n" --repo "$slug" >/dev/null || die "cannot mark PR #$n ready" "gh pr ready $n --repo $slug"
    fi
    merged=$(gh api -X PUT "repos/$slug/pulls/$n/merge" -f merge_method=squash -f "sha=$sha" | jq -r '.sha // empty') ||
        die "GitHub refused to merge PR #$n at $sha" "gh api repos/$slug/pulls/$n --jq .mergeable_state"
    [[ -n $merged ]] || die "the merge of PR #$n returned no sha" "gh api repos/$slug/pulls/$n --jq .merge_commit_sha"
    printf 'merged pr=%s sha=%s branch=%s\n' "$n" "$merged" "$(merge_branch "$slug" "$json")"
}
