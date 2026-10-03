# shellcheck shell=bash
# ak merge --pr N: bring the PR up to date with its base, squash-merge it once its head checks are green
# (pinned to that head), then delete its branch unless another open PR is based on it. Exit 3 with a spawn
# line when the update conflicts: the PR's worker resolves it, then ak merge runs again.

# shellcheck source=ci.sh
source "$AK_HOME/lib/ci.sh"
# shellcheck source=threads.sh
source "$AK_HOME/lib/threads.sh"

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

# merge_threads SLUG N: refuse while the PR has unresolved review threads; bots post them as their checks finish
# (a field root went to merge a PR carrying two unresolved code-quality threads).
merge_threads() {
    local list
    list=$(threads_open "$1" "$2") || die "cannot read the review threads on PR #$2" "gh auth status"
    [[ -z $list ]] || die "PR #$2 has $(grep -c . <<<"$list") unresolved review threads ($(threads_summary "$list"))" \
        "ak pr-plan --pr $2"
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
    [[ -n $parent ]] || { merge_orphan_base "$slug" "$n" "$base"; return 0; }
    # Take the parent's final branch (its review fixes included) before leaving it: the child was built on the
    # parent's first commit, and resolving it against the squash on main kept the parent's old bug
    # (PR bench 2026-10-01: #174 reintroduced the undo bug #173 had fixed).
    local head out
    head=$(gh api "repos/$slug/pulls/$n" | jq -r .head.ref) || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
    if ! out=$(gh api "repos/$slug/merges" -f "base=$head" -f "head=$base" \
        -f "commit_message=merge: $base into $head" 2>&1); then
        [[ $out == *[Cc]onflict* ]] || die "cannot merge $base into $head: ${out:0:160}" "gh api repos/$slug/merges -f base=$head -f head=$base"
    fi
    gh api -X PATCH "repos/$slug/pulls/$n" -f "base=$parent" >/dev/null ||
        die "cannot retarget PR #$n to $parent" "gh api -X PATCH repos/$slug/pulls/$n -f base=$parent"
    # The merged parent's branch has served its last child once no open PR is based on it.
    if [[ -z $(gh api "repos/$slug/pulls?state=open&base=$base&per_page=1" | jq -r '.[0].number // empty') ]]; then
        gh api -X DELETE "repos/$slug/git/refs/heads/$base" >/dev/null 2>&1 || true
    fi
}

# merge_orphan_base SLUG N BASE: a base branch with no PR (its issue parked or never shipped). Merging there would land
# the PR in that branch, not the default one (a field merge squashed a docs PR into a parked issue's empty branch).
# An empty base is retargeted to the default branch; a base carrying unmerged work refuses.
merge_orphan_base() {
    local slug=$1 n=$2 base=$3 default ahead
    default=$(base_branch)
    ahead=$(gh api "repos/$slug/compare/$default...$base" --jq .ahead_by) ||
        die "cannot compare $base with $default" "gh api repos/$slug/compare/$default...$base"
    [[ $ahead == 0 ]] ||
        die "PR #$n is based on $base, which has no PR and $ahead commits not on $default" "ship the issue behind $base first"
    gh api -X PATCH "repos/$slug/pulls/$n" -f "base=$default" >/dev/null ||
        die "cannot retarget PR #$n to $default" "gh api -X PATCH repos/$slug/pulls/$n -f base=$default"
}

# merge_worktree REF: the main checkout's worktree that has REF checked out, or nothing.
merge_worktree() {
    git -C "$(main_root)" worktree list --porcelain |
        awk -v ref="refs/heads/$1" '/^worktree /{wt = substr($0, 10)} $0 == "branch " ref {print wt; exit}'
}

# merge_update SLUG N JSON: bring the PR's head up to date with its base before merging, so a PR that went
# stale when an earlier PR landed still merges (bench 2026-10-01: #112 hit "merge conflicts" after #111).
# Prints the head sha to merge. A clean update goes through GitHub; a conflict hands the PR back to its worker.
merge_update() {
    local slug=$1 n=$2 json=$3 sha base out wt i
    sha=$(jq -r .head.sha <<<"$json")
    base=$(jq -r .base.ref <<<"$json")
    if out=$(gh api -X PUT "repos/$slug/pulls/$n/update-branch" -f "expected_head_sha=$sha" 2>&1); then
        for ((i = 0; i < ${AK_MERGE_UPDATE_WAIT:-120}; i += 5)); do
            json=$(gh api "repos/$slug/pulls/$n") || break
            [[ $(jq -r .head.sha <<<"$json") == "$sha" ]] || { jq -r .head.sha <<<"$json"; return 0; }
            sleep 5
        done
        die "PR #$n is updating from $base; its new head has no checks yet" "ak merge --pr $n"
    fi
    case $out in
        *[Nn]o\ new\ commits* | *up\ to\ date* | *already*) printf '%s\n' "$sha"; return 0 ;;
        *[Cc]onflict*) ;;
        *) die "cannot update PR #$n from $base: ${out:0:160}" "gh api -X PUT repos/$slug/pulls/$n/update-branch" ;;
    esac
    wt=$(merge_worktree "$(jq -r .head.ref <<<"$json")")
    [[ -n $wt && -f $wt/.ak/prompt.md ]] ||
        die "PR #$n conflicts with $base and has no ak worktree here" "ak pr-plan --pr $n"
    printf 'origin/%s\n' "$base" >"$wt/.ak/resolve"
    printf '%s\n' "$base" >"$wt/.ak/base"
    rm -f -- "$wt/.ak/result"
    printf 'resolve pr=%s conflicts-with=%s\n' "$n" "$base"
    printf 'spawn pr=%s cwd=%s prompt=%s/.ak/prompt.md model=%s effort=%s\n' "$n" "$wt" "$wt" \
        "$(worker_model)" "$(cfg AGENT_WORKER_EFFORT medium)"
    return 3
}

# merge_branch SLUG JSON: hand every open PR stacked on the merged head branch to the merged PR's base, then delete the
# head branch and confirm it is gone. Each stacked PR first gets the branch's final state (its review fixes) merged in.
# A field stack left merged branches behind as "kept (base of #N)", and a later merge landed a PR in one of them.
# Retargeting before the delete keeps the stack open; one API delete closed a stacked PR instead of retargeting it.
merge_branch() {
    local slug=$1 json=$2 ref base deps dep head moved=''
    ref=$(jq -r .head.ref <<<"$json")
    base=$(jq -r .base.ref <<<"$json")
    if [[ $(jq -r '.head.repo.full_name // ""' <<<"$json") != "$slug" ]]; then
        printf 'kept (fork)\n'
        return 0
    fi
    deps=$(gh api "repos/$slug/pulls?state=open&base=$ref&per_page=100" | jq -r '.[] | "\(.number)\t\(.head.ref)"') ||
        { printf 'kept (cannot list dependents)\n'; return 0; }
    while IFS=$'\t' read -r dep head; do
        [[ -n $dep ]] || continue
        # A conflict here is resolved when that PR's own ak merge updates it from its new base.
        gh api "repos/$slug/merges" -f "base=$head" -f "head=$ref" -f "commit_message=merge: $ref into $head" >/dev/null 2>&1 || true
        gh api -X PATCH "repos/$slug/pulls/$dep" -f "base=$base" >/dev/null 2>&1 ||
            { printf 'kept (cannot retarget #%s; fix: gh api -X PATCH repos/%s/pulls/%s -f base=%s)\n' "$dep" "$slug" "$dep" "$base"; return 0; }
        moved+="${moved:+,}#$dep"
    done <<<"$deps"
    gh api -X DELETE "repos/$slug/git/refs/heads/$ref" >/dev/null 2>&1 || true
    if gh api "repos/$slug/git/ref/heads/$ref" >/dev/null 2>&1; then
        printf 'kept (delete failed; fix: gh api -X DELETE repos/%s/git/refs/heads/%s)\n' "$slug" "$ref"
    else
        printf 'deleted%s\n' "${moved:+ (retargeted $moved to $base)}"
    fi
}

# merge_lock N: one ak merge per PR at a time; a second caller waits, then sees the first one's result
# (bench 2026-10-01: two parallel merges of #136 respawned a worker for a PR that had just merged).
merge_lock() {
    local dir waited=0
    dir="$(main_root)/.ak/locks/merge-$1"
    mkdir -p -- "$(dirname -- "$dir")"
    until mkdir -- "$dir" 2>/dev/null; do
        ((waited < ${AK_MERGE_LOCK_WAIT:-900})) ||
            die "another ak merge is working on PR #$1" "rmdir $dir   # only if no ak merge is running"
        sleep 2
        waited=$((waited + 2))
    done
    # shellcheck disable=SC2064 # expand now: the lock path is fixed for this process
    trap "rmdir -- '$dir' 2>/dev/null" EXIT
}

cmd_main() {
    [[ $# -eq 2 && $1 == --pr && $2 =~ ^[0-9]+$ ]] || usage_die "usage: ak merge --pr N"
    local n=$2 slug json sha merged
    merge_lock "$n"
    slug=$(slug)
    json=$(gh api "repos/$slug/pulls/$n") || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
    if [[ $(jq -r .merged <<<"$json") == true ]]; then
        printf 'merged pr=%s sha=%s already\n' "$n" "$(jq -r .merge_commit_sha <<<"$json")"
        return 0
    fi
    [[ $(jq -r .state <<<"$json") == open ]] || die "PR #$n is closed" "gh pr reopen $n --repo $slug"
    # Checks still running on a green-collected PR are waited for, not refused (PR bench 2026-10-01: #150).
    ci_wait "$(jq -r .head.sha <<<"$json")" "${AK_MERGE_CI_TIMEOUT:-1800}" 0 >/dev/null
    merge_checks "$slug" "$(jq -r .head.sha <<<"$json")"
    merge_threads "$slug" "$n"
    merge_parent "$slug" "$n" "$(jq -r .base.ref <<<"$json")"
    json=$(gh api "repos/$slug/pulls/$n") || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
    local rc=0
    sha=$(merge_update "$slug" "$n" "$json") || rc=$?
    if ((rc == 3)); then printf '%s\n' "$sha"; exit 3; fi
    ((rc == 0)) || exit "$rc"
    if [[ $sha != "$(jq -r .head.sha <<<"$json")" ]]; then
        # The update merged the base in: wait for CI on the new head before merging it.
        ci_wait "$sha" "${AK_MERGE_CI_TIMEOUT:-1800}" 0 >/dev/null
        merge_checks "$slug" "$sha"
    fi
    if [[ $(jq -r .draft <<<"$json") == true ]]; then
        gh pr ready "$n" --repo "$slug" >/dev/null || die "cannot mark PR #$n ready" "gh pr ready $n --repo $slug"
    fi
    merged=$(gh api -X PUT "repos/$slug/pulls/$n/merge" -f merge_method=squash -f "sha=$sha" | jq -r '.sha // empty') ||
        die "GitHub refused to merge PR #$n at $sha" "gh api repos/$slug/pulls/$n --jq .mergeable_state"
    [[ -n $merged ]] || die "the merge of PR #$n returned no sha" "gh api repos/$slug/pulls/$n --jq .merge_commit_sha"
    printf 'merged pr=%s sha=%s branch=%s\n' "$n" "$merged" "$(merge_branch "$slug" "$json")"
}
