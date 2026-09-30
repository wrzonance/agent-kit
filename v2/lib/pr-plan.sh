# shellcheck shell=bash
# ak pr-plan --pr N [--pr N]...: a worktree and worker prompt per open PR, a run file, and spawn lines.

# The worker model: the first roster entry of the running harness's family, else its default.
pr_plan_model() {
    local roster entry family
    family=$(harness)
    IFS=', ' read -ra roster <<<"$(cfg AGENT_WORKER_MODELS)"
    for entry in "${roster[@]}"; do
        [[ -n $entry ]] || continue
        case $family in
            codex) [[ ! $entry =~ ^(gpt-|o[0-9]) ]] || { printf '%s\n' "$entry"; return 0; } ;;
            claude) [[ $entry =~ ^(gpt-|o[0-9]) ]] || { printf '%s\n' "$entry"; return 0; } ;;
            *) printf '%s\n' "$entry"; return 0 ;;
        esac
    done
    if [[ $family == claude ]]; then printf 'sonnet\n'; else printf 'gpt-5.6-luna\n'; fi
}

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

# pr_plan_worktree ROOT DIR BRANCH: the existing worktree for BRANCH, or a new one tracking origin.
pr_plan_worktree() {
    local root=$1 dir=$2 branch=$3 path existing
    existing=$(git -C "$root" worktree list --porcelain |
        awk -v want="branch refs/heads/$branch" '/^worktree /{p=substr($0,10)} $0==want{print p; exit}')
    git -C "$root" fetch -q origin "+refs/heads/$branch:refs/remotes/origin/$branch" ||
        die "cannot fetch $branch" "git fetch origin $branch"
    if [[ -n $existing ]]; then
        [[ $existing != "$root" ]] || die "$branch is checked out in the main checkout" "git -C $root switch $(base_branch)"
        printf '%s\n' "$existing"
        return 0
    fi
    path="$dir/$branch"
    if git -C "$root" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$root" worktree add -q "$path" "$branch" >/dev/null 2>&1 || die "cannot add a worktree for $branch" "git worktree add $path $branch"
        git -C "$path" branch -q --set-upstream-to "origin/$branch" >/dev/null 2>&1 || true
    else
        git -C "$root" worktree add -q --track -b "$branch" "$path" "origin/$branch" >/dev/null 2>&1 ||
            die "cannot add a worktree for $branch" "git worktree add --track -b $branch $path origin/$branch"
    fi
    printf '%s\n' "$path"
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
    rm -f -- "$wt/.ak/result"
    text=$(<"$AK_HOME/templates/pr-worker.md")
    text=${text//'{{PR}}'/"$n"}
    text=${text//'{{TITLE}}'/"$title"}
    text=${text//'{{BRANCH}}'/"$branch"}
    text=${text//'{{WORKTREE}}'/"$wt"}
    text=${text//'{{BASE}}'/"$base"}
    text=${text//'{{SLUG}}'/"$slug"}
    text=${text//'{{AK}}'/"$AK_HOME/bin/ak"}
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
        prs+=("$2")
        shift 2
    done
    local root slug dir runs run model effort items='[]' n json reason wt spawns=''
    root=$(main_root)
    cd -- "$root" || die "cannot enter $root" "cd $root"
    ak_dir >/dev/null
    slug=$(slug)
    dir=$(pr_plan_worktree_dir "$root")
    runs="$root/.ak/runs"
    mkdir -p -- "$runs"
    model=$(pr_plan_model)
    effort=$(cfg AGENT_WORKER_EFFORT medium)
    for n in "${prs[@]}"; do
        json=$(gh api "repos/$slug/pulls/$n") || die "cannot read PR #$n" "gh api repos/$slug/pulls/$n"
        reason=$(pr_plan_skip "$json" "$slug")
        if [[ -n $reason ]]; then
            spawns+="drop pr=$n reason=$reason"$'\n'
            continue
        fi
        wt=$(pr_plan_worktree "$root" "$dir" "$(jq -r .head.ref <<<"$json")")
        pr_plan_prompt "$json" "$wt" "$slug"
        items=$(jq -c --argjson n "$n" --arg wt "$wt" --arg br "$(jq -r .head.ref <<<"$json")" \
            '. + [{kind: "pr", n: $n, worktree: $wt, branch: $br, state: "spawned", needs: []}]' <<<"$items")
        spawns+="spawn pr=$n cwd=$wt prompt=$wt/.ak/prompt.md model=$model effort=$effort"$'\n'
    done
    run=$(pr_plan_run_id "$runs")
    jq -n --arg run "$run" --arg porcelain "$(git -C "$root" status --porcelain)" --argjson items "$items" \
        '{run: $run, porcelain: $porcelain, items: $items}' >"$runs/$run.json"
    printf '%s\n' "$run" >"$runs/current"
    printf 'run=%s\n%s' "$run" "$spawns"
}
