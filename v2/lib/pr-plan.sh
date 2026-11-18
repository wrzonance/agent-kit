# shellcheck shell=bash
# ak pr-plan --pr N [--pr N]...: a worktree and worker prompt per open PR, a run file, and spawn lines.
# shellcheck source=threads.sh
source "$AK_HOME/lib/threads.sh"

# The directory worktrees live under, absolute, kept out of the main checkout's git status.
pr_plan_worktree_dir() {
    local root=$1 dir exclude
    dir=$(cfg AGENT_WORKTREE_ROOT .worktrees)
    [[ $dir == /* ]] || dir="$root/$dir"
    if [[ $dir == "$root"/* ]]; then
        exclude="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
        mkdir -p -- "$(dirname -- "$exclude")"
        grep -qxF "/${dir#"$root"/}/" "$exclude" 2>/dev/null || printf '/%s/\n' "${dir#"$root"/}" >>"$exclude"
    fi
    printf '%s\n' "$dir"
}

# worktree_for_branch ROOT DIR BRANCH: BRANCH's worktree, ready to use. A registration whose directory is gone (a reboot
# emptied /tmp) is pruned and rebuilt under DIR, never left for a later mkdir to turn into a bare directory. One behind
# origin fast-forwards when clean; one dirty or diverged is refused with its work kept. Ahead of origin is fine: an
# update-branch or a worker's unpushed commit moves the heads apart legitimately.
worktree_for_branch() {
    local root=$1 dir=$2 branch=$3 up=refs/remotes/origin/$3 wt gone
    IFS=$'\t' read -r wt gone < <(git -C "$root" worktree list --porcelain | awk -v RS= -F'\n' -v want="branch refs/heads/$branch" '
        {p = substr($1, 10); b = 0; g = 0; for (i = 2; i <= NF; i++) {if ($i == want) b = 1; if ($i ~ /^prunable/) g = 1}}
        b {print p "\t" g; exit}') || true
    [[ ${wt:-} != "$root" ]] || die "$branch is checked out in the main checkout" "git -C $root switch $(base_branch)"
    if [[ -n ${wt:-} && ( ! -d $wt || ${gone:-} == 1 ) ]]; then
        git -C "$root" worktree prune
        wt=
    fi
    if [[ -z ${wt:-} ]]; then
        wt="$dir/$branch"
        if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
            git -C "$root" worktree add -q "$wt" "$branch" >/dev/null 2>&1 || die "cannot add a worktree for $branch" "git worktree add $wt $branch"
            git -C "$wt" branch -q --set-upstream-to "origin/$branch" >/dev/null 2>&1 || true
        else
            git -C "$root" worktree add -q --track -b "$branch" "$wt" "origin/$branch" >/dev/null 2>&1 ||
                die "cannot add a worktree for $branch" "git worktree add --track -b $branch $wt origin/$branch"
        fi
    fi
    if git -C "$wt" rev-parse --verify -q "$up" >/dev/null && ! git -C "$wt" merge-base --is-ancestor "$up" HEAD; then
        git -C "$wt" merge-base --is-ancestor HEAD "$up" || die "$wt has diverged from origin/$branch" "git -C $wt merge origin/$branch"
        [[ -z $(git -C "$wt" status --porcelain) ]] || die "$wt has uncommitted work and is behind origin/$branch" "commit it in $wt, then rerun"
        git -C "$wt" merge -q --ff-only "$up" >/dev/null || die "cannot fast-forward $wt to origin/$branch" "git -C $wt merge --ff-only origin/$branch"
    fi
    printf '%s\n' "$wt"
}

# pr_plan_prompt PR_JSON WORKTREE SLUG: write .ak/pr, .ak/base and .ak/prompt.md; drop a stale result.
pr_plan_prompt() {
    local json=$1 wt=$2 slug=$3 text n title branch base
    n=$(jq -r .number <<<"$json")
    title=$(jq -r '.title | gsub("[\\r\\n]+"; " ")' <<<"$json")
    branch=$(jq -r .head.ref <<<"$json")
    base=$(jq -r .base.ref <<<"$json")
    mkdir -p -- "$wt/.ak"
    printf '%s\n' "$n" >"$wt/.ak/pr"
    printf '%s\n' "$base" >"$wt/.ak/base"
    # A parked PR planned again records what was committed there since the park, like a parked issue (hand_over).
    ! grep -q '^note=parked: ' "$wt/.ak/result" 2>/dev/null || hand_over "$wt" ||
        die "cannot record what was committed in $wt since its park" "git -C $wt status"
    rm -f -- "$wt/.ak/result"
    text=$(<"$AK_HOME/templates/pr-worker.md")
    text=${text//'{{PR}}'/"$n"}
    text=${text//'{{TITLE}}'/"$title"}
    text=${text//'{{BRANCH}}'/"$branch"}
    text=${text//'{{WORKTREE}}'/"$wt"}
    text=${text//'{{BASE}}'/"$base"}
    text=${text//'{{SLUG}}'/"$slug"}
    text=${text//'{{AK}}'/"$AK_HOME/bin/ak"}
    text=${text//'{{SETUP}}'/"$(setup_step)"}
    printf '%s\n' "$text" >"$wt/.ak/prompt.md"
}

# pr_plan_skip PR_JSON SLUG: the reason a PR gets no worker, or nothing.
pr_plan_skip() {
    local json=$1 slug=$2
    jq -r --arg slug "$slug" '
        if .merged_at != null then "merged"
        elif .state != "open" then "closed"
        elif (.head.repo.full_name // "") != $slug then "fork"
        else empty end' <<<"$json"
}

# pr_plan_done WORKTREE SHA SLUG N: did a worker already take this exact head to green with a review? Re-reviewing seven such
# PRs in a field run cost 19.6M tokens, and its fixes turned four green PRs red.
pr_plan_done() {
    local file=$1/.ak/result open
    [[ -f $file ]] && grep -qx "head=$2" "$file" && grep -qx 'ci=green' "$file" && grep -qx 'review=done' "$file" ||
        return 1
    # Review bots comment after the worker's receipt; a PR with open threads still needs its worker.
    open=$(threads_open "$3" "$4") && [[ -z $open ]]
}

# A fresh run id; a second plan in the same second gets a suffix.
pr_plan_run_id() {
    local runs=$1 id n=2
    id=$(date +%Y%m%d-%H%M%S)
    local candidate=$id
    while [[ -e $runs/$candidate.json ]]; do
        candidate="$id-$n"
        n=$((n + 1))
    done
    printf '%s\n' "$candidate"
}

cmd_main() {
    local -a prs=()
    (($# > 0)) || usage_die "usage: ak pr-plan --pr N [--pr N]..."
    while (($# > 0)); do
        [[ $1 == --pr && ${2:-} =~ ^[0-9]+$ ]] || usage_die "usage: ak pr-plan --pr N [--pr N]..."
        [[ " ${prs[*]} " == *" $2 "* ]] || prs+=("$2")
        shift 2
    done
    local root slug dir runs run model effort items='[]' n json reason wt br spawns=''
    root=$(main_root)
    cd -- "$root" || die "cannot enter $root" "cd $root"
    ak_dir >/dev/null
    slug=$(slug)
    dir=$(pr_plan_worktree_dir "$root")
    runs="$root/.ak/runs"
    mkdir -p -- "$runs"
    model=$(worker_model)
    effort=$(cfg AGENT_WORKER_EFFORT medium)
    for n in "${prs[@]}"; do
        json=$(gh api "repos/$slug/pulls/$n") || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
        reason=$(pr_plan_skip "$json" "$slug")
        if [[ -n $reason ]]; then
            spawns+="drop pr=$n reason=$reason"$'\n'
            continue
        fi
        br=$(jq -r .head.ref <<<"$json")
        git -C "$root" fetch -q origin "+refs/heads/$br:refs/remotes/origin/$br" || die "cannot fetch $br" "git fetch origin $br"
        wt=$(worktree_for_branch "$root" "$dir" "$br")
        if pr_plan_done "$wt" "$(jq -r .head.sha <<<"$json")" "$slug" "$n"; then
            items=$(jq -c --argjson n "$n" --arg wt "$wt" --arg br "$(jq -r .head.ref <<<"$json")" \
                '. + [{kind: "pr", n: $n, worktree: $wt, branch: $br, state: "collected", needs: []}]' <<<"$items")
            spawns+="skip pr=$n reason=green-and-reviewed-at-head"$'\n'
            continue
        fi
        pr_plan_prompt "$json" "$wt" "$slug"
        items=$(jq -c --argjson n "$n" --arg wt "$wt" --arg br "$(jq -r .head.ref <<<"$json")" \
            '. + [{kind: "pr", n: $n, worktree: $wt, branch: $br, state: "spawned", spawned_at: (now | floor), needs: []}]' <<<"$items")
        spawns+="spawn pr=$n cwd=$wt prompt=$wt/.ak/prompt.md model=$model effort=$effort name=$(worker_name pr "$n" "$wt")"$'\n'
    done
    run=$(pr_plan_run_id "$runs")
    jq -n --arg run "$run" --arg porcelain "$(git -C "$root" status --porcelain)" --argjson items "$items" \
        '{run: $run, porcelain: $porcelain, items: $items}' >"$runs/$run.json"
    printf '%s\n' "$run" >"$runs/current"
    printf 'run=%s\n%s' "$run" "$spawns"
}
