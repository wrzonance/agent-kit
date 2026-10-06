# shellcheck shell=bash disable=SC2016
# ak collect (--issue N | --pr N): one worker's result, any root cross-write, and newly unblocked spawns.
# shellcheck source=plan.sh
source "$AK_HOME/lib/plan.sh"
# shellcheck source=ci.sh
source "$AK_HOME/lib/ci.sh"

# run_update FILTER [JQ ARGS...]: rewrite the run file through jq.
run_update() {
    local filter=$1
    shift
    jq "$@" "$filter" "$RUNFILE" >"$RUNFILE.tmp" && mv -- "$RUNFILE.tmp" "$RUNFILE"
}

# result_refresh KIND N: when the PR head moved past the worker's result (a base update, a merge-down), replace the
# recorded ci with the live checks on the new head. A field root collected a stale ci=red after the head went green.
result_refresh() {
    local pr=$2 live now runs pr_json mergeable ci=${r[ci]:-pending} start moves=0 grace=${AK_CI_GRACE:-180}
    [[ $1 == pr ]] || pr=${r[pr]##*/}
    [[ $pr =~ ^[0-9]+$ && -n ${r[head]:-} ]] || return 0
    pr_json=$(api "repos/$SLUG/pulls/$pr" 2>/dev/null) || return 0
    live=$(jq -r 'objects | .head.sha // empty' <<<"$pr_json" 2>/dev/null) || return 0
    # A conflicted PR is not green: a stacked child goes dirty when its parent merges, with head and checks unchanged,
    # and GitHub runs no PR checks on it. Unknown mergeability counts as clean here; the worker's ak ci handles it.
    mergeable=$(jq -r 'objects | .mergeable_state // empty' <<<"$pr_json" 2>/dev/null) || mergeable=
    if [[ $mergeable == dirty ]]; then
        r[ci]=blocked
        r[note]="PR #$pr conflicts with its base"
        return 0
    fi
    # A recorded red or pending is read again even at the same head: a re-run check can turn red green without a new
    # commit, and a merge-down worker's receipt can carry ci=pending (a field successor was spawned twice on a parent
    # whose CI had not concluded). The successors it holds wait on exactly that.
    [[ -n $live && ($live != "${r[head]}" || $ci == red || $ci == pending) ]] || return 0
    RESULT_HEAD=$live
    # Checks still running are waited on here, not handed back as a root turn: ci_wait holds this call until they
    # conclude or AK_COLLECT_CI_TIMEOUT (default 1800 s) passes. The head is read again after each wait: a PR that
    # advanced meanwhile has its new checks unread, so the wait moves to the new head (twice at most).
    while :; do
        start=$SECONDS
        if ! runs=$(ci_wait "$live" "${AK_COLLECT_CI_TIMEOUT:-1800}" 0); then
            # A failed live read keeps no recorded green: the item is held and read again on the next collect.
            r[ci]=pending
            r[note]="${r[note]:+${r[note]}; }ci read failed at ${live:0:7}"
            return 0
        fi
        RESULT_WAITED=$((SECONDS - start))
        pr_json=$(api "repos/$SLUG/pulls/$pr" 2>/dev/null) || pr_json=
        now=$(jq -r 'objects | .head.sha // empty' <<<"$pr_json" 2>/dev/null) || now=
        if [[ -z $now ]]; then
            # An empty reread is not a stable head: the checks read above may belong to a head that has moved on.
            r[ci]=pending
            r[note]="${r[note]:+${r[note]}; }head reread failed at ${live:0:7}"
            return 0
        fi
        mergeable=$(jq -r 'objects | .mergeable_state // empty' <<<"$pr_json" 2>/dev/null) || mergeable=
        if [[ $mergeable == dirty ]]; then
            r[ci]=blocked
            r[note]="PR #$pr conflicts with its base"
            return 0
        fi
        [[ $now == "$live" ]] && break
        live=$now RESULT_HEAD=$now
        if ((++moves > 2)); then
            r[ci]=pending
            r[note]="${r[note]:+${r[note]}; }head moved during the wait"
            return 0
        fi
    done
    if [[ $runs == '[]' ]] && ((RESULT_WAITED >= grace)); then
        # No check run after the grace period: a repository without CI, which ak ci also reports as none.
        r[ci]=none
    else
        r[ci]=$(ci_summary "$runs" | sed -E 's/^ci=([a-z]+).*/\1/')
    fi
    [[ $live != "${r[head]}" ]] || return 0
    # The review stays: the head moves through base merges, not changes to the PR's own diff; the note says so.
    r[note]="${r[note]:+${r[note]}; }ci read live at ${live:0:7}; review covers ${r[head]:0:7}"
}

# result_line KIND N WORKTREE: the result line; returns 1 when the worker left no result.
result_line() {
    local kind=$1 n=$2 file="$3/.ak/result" key value
    local -A r=()
    if [[ ! -f $file ]]; then
        # No result is not "ended": a field root collected 10 s after the spawn and read this as a dead worker.
        emit "$kind=$n state=pending note=no .ak/result yet; collect again once the worker reports"
        return 1
    fi
    while IFS='=' read -r key value; do
        [[ $key =~ ^[a-z]+$ ]] && r[$key]=$value
    done <"$file"
    RESULT_HEAD=${r[head]:-} RESULT_WAITED=0
    result_refresh "$kind" "$n"
    RESULT_CI=${r[ci]:-}
    if [[ $kind == issue ]]; then
        emit "issue=$n pr=${r[pr]:-} ci=${r[ci]:-} review=${r[review]:-} note=${r[note]:-}"
    else
        emit "pr=$n ci=${r[ci]:-} review=${r[review]:-} note=${r[note]:-}"
    fi
}

# cross_write: root paths whose status changed since plan time.
cross_write() {
    local paths
    paths=$(LC_ALL=C comm -13 <(jq -r .porcelain "$RUNFILE" | LC_ALL=C sort) \
        <(git -C "$MAIN" status --porcelain | LC_ALL=C sort) | cut -c4- | paste -sd, -)
    [[ -z $paths ]] || emit "cross-write=$paths"
}

# spawn_successors: queued issues whose needs are all collected, each from the branch of its latest predecessor in run
# order. A field successor needed [its blocker, then two colliding issues]; taking the last of that list based it on a
# branch below the blocker's, without the blocker's work.
spawn_successors() {
    local n pred from ready active open again=0
    ready=$(jq -r '[.items[] | select(.kind == "issue" and .state == "collected") | .n] as $done |
        [.items[] | select(.kind == "issue") | .n] as $order |
        .items[] | select(.kind == "issue" and .state == "queued" and ((.needs - $done) | length) == 0) |
        "\(.n)\t\(.needs | max_by(. as $x | $order | index($x) // -1))"' "$RUNFILE")
    [[ -n $ready ]] || return 0
    TEMPLATE="$AK_HOME/templates/issue-worker.md"
    [[ -f $TEMPLATE ]] || die "worker template missing: $TEMPLATE" 'reinstall the ak plugin'
    MODEL=$(worker_model)
    EFFORT=$(cfg AGENT_WORKER_EFFORT medium)
    while IFS=$'\t' read -r -u 3 n pred; do
        active=$(issue_active "$n" "$RUNFILE")
        if [[ -z $active ]]; then
            open=$(api "repos/$SLUG/pulls?state=open&head=${SLUG%%/*}:feat/issue-$n&per_page=1" | jq 'length') || open=''
            [[ $open =~ ^[0-9]+$ ]] || { emit "after issue=$n note=open-PR lookup failed; collect again"; continue; }
            ((open == 0)) || active="open-pr"
        fi
        case $active in
            '') ;;
            shipped:* | open-pr)
                # Shipped elsewhere counts as done, so the issues queued behind it still unblock.
                emit "skip issue=$n reason=$active"
                run_update '(.items[] | select(.kind == "issue" and .n == $n)).state = "collected"' --argjson n "$n"
                again=1
                continue
                ;;
            *) emit "after issue=$n reason=$active"; continue ;;
        esac
        from="feat/issue-$pred"
        git -C "$MAIN" fetch -q origin "$from" >>"$AK_LOG" 2>&1 && from="origin/$from"
        if ! ISSUE_JSON[$n]=$(api "repos/$SLUG/issues/$n"); then
            emit "drop issue=$n reason=unreadable"
            run_update '(.items[] | select(.kind == "issue" and .n == $n)).state = "dropped"' --argjson n "$n"
        elif spawn_issue "$n" "$from" "feat/issue-$pred"; then
            run_update '(.items[] | select(.kind == "issue" and .n == $n)) |= (.state = "spawned" | .worktree = $wt)' \
                --argjson n "$n" --arg wt "${WORKTREE[$n]}"
        fi
    done 3<<<"$ready"
    spawn_flush
    ((again == 0)) || spawn_successors
}

# collect_item KIND N FILE: the run item for KIND N in FILE, or nothing.
collect_item() {
    jq -c --arg k "$1" --argjson n "$2" '[.items[] | select(.kind == $k and .n == $n)][0] // empty' "$3"
}

# collect_next STATE N WORKTREE: the one line that says how a parked, red or pending issue continues. A field operator
# had to ask for the commands after a park, and the root then finished the parked work itself instead of handing it to
# a worker.
collect_next() {
    local dirty pr
    if [[ $1 == red || $1 == blocked ]]; then
        # The red PR goes to a PR worker: a field root told to "get its PR green" rebased and shipped in the worker's
        # worktree itself. The number comes from the worker-written result and lands in a command the root runs, so
        # only the digits of a well-formed PR URL reach the line.
        pr=$(sed -n 's/^pr=//p' "$3/.ak/result" | head -n 1)
        if [[ $pr =~ ^https?://[^[:space:]]+/([0-9]+)$ ]]; then
            pr=${BASH_REMATCH[1]}
            if [[ $1 == blocked ]]; then
                emit "next=issue=$2 PR $pr conflicts with its base: ak pr-plan --pr $pr, spawn what it prints, then ak collect --pr $pr and ak collect --issue $2"
            else
                emit "next=issue=$2 has red CI on PR $pr; hand it to a worker: ak pr-plan --pr $pr, spawn what it prints, then ak collect --pr $pr and ak collect --issue $2"
            fi
        else
            local why='has red CI'
            [[ $1 != blocked ]] || why='PR conflicts with its base'
            emit "next=issue=$2 $why; hand its PR to a worker: ak pr-plan --pr <its PR number>, spawn what it prints, then ak collect --pr <its PR number> and ak collect --issue $2"
        fi
        return 0
    elif [[ $1 == pending ]]; then
        emit "next=issue=$2 CI is still pending on ${RESULT_HEAD:0:7} after ${RESULT_WAITED}s; collect again once it concludes"
        return 0
    fi
    dirty=$(git -C "$3" status --porcelain 2>/dev/null | wc -l)
    emit "next=issue=$2 is parked in $3 (uncommitted paths: $((dirty))); clear what its note names, commit and push there what only you may commit, then: ak plan --issue $2"
}

# merge_up WORKTREE: when the branch a shipped worktree is stacked on has a newer finished head than the one it holds,
# hand the worktree back to its worker as a merge-down (.ak/resolve) and print the spawn line. "Finished" is the green
# head the parent's own worker recorded, so a parent still being reworked moves nothing. A field stack's first PR was
# reworked after three PRs had shipped on top of it, and the root merged each one up by hand for 25 minutes.
merge_up() {
    local wt=$1 base parent head kind n='' file pr
    [[ -s $wt/.ak/base && -f $wt/.ak/prompt.md ]] || return 1
    pr=$(sed -n 's/^pr=//p' "$wt/.ak/result" 2>/dev/null | head -n 1)
    [[ $pr =~ ^https?://[^[:space:]]+/([0-9]+)$ ]] || return 1
    pr=${BASH_REMATCH[1]}
    base=$(head -n 1 -- "$wt/.ak/base")
    # Everything read from a worktree's .ak files is a worker's writing: it reaches the root's lines only as a branch
    # name, a commit id and a number.
    [[ $base =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
    parent=$(git -C "$MAIN" worktree list --porcelain |
        awk -v ref="branch refs/heads/$base" '/^worktree /{p = substr($0, 10)} $0 == ref {print p; exit}')
    [[ -n $parent && $parent != "$MAIN" ]] && grep -qx 'ci=green' "$parent/.ak/result" 2>/dev/null || return 1
    head=$(sed -n 's/^head=//p' "$parent/.ak/result" | head -n 1)
    # The green result must describe the parent as it stands, since the worker merges the branch, not this commit.
    [[ $head =~ ^[0-9a-f]{7,40}$ && $(git -C "$parent" rev-parse HEAD 2>/dev/null) == "$head"* ]] || return 1
    # And it must be what the parent pushed: origin's branch is what the worker will merge.
    [[ $(git -C "$MAIN" rev-parse --verify -q "refs/remotes/origin/$base") == "$head"* ]] || return 1
    git -C "$wt" cat-file -e "$head^{commit}" 2>/dev/null || return 1
    # Already merged, here or on the pushed branch: nothing to do.
    ! git -C "$wt" merge-base --is-ancestor "$head" HEAD 2>/dev/null || return 1
    ! git -C "$wt" merge-base --is-ancestor "$head" '@{u}' 2>/dev/null || return 1
    # Which item this worktree is comes from the run files the root wrote, newest first, never from the worktree: a
    # worker that could name itself could send another item back to spawned.
    while IFS= read -r file; do
        n=$(jq -r --arg wt "$wt" '[.items[] | select(.worktree == $wt)][-1] // empty | "\(.kind) \(.n)"' "$file" 2>/dev/null)
        [[ -z $n ]] || break
    done < <(ls -t -- "$MAIN"/.ak/runs/*.json 2>/dev/null)
    [[ $n =~ ^(issue|pr)\ [0-9]+$ ]] || return 1
    kind=${n% *} n=${n#* }
    # A worktree kept after its PR merged or closed is finished work, not a child to hand back.
    [[ $(api "repos/$SLUG/pulls/$pr" | jq -r 'objects | .state // empty' 2>/dev/null) == open ]] || return 1
    # The resolve file is written fresh (never through a link a worker left) and before the result goes.
    rm -f -- "$wt/.ak/resolve"
    printf 'origin/%s\n' "$base" >"$wt/.ak/resolve" || return 1
    rm -f -- "$wt/.ak/result" || return 1
    emit "merge-up $kind=$n note=$base moved to ${head:0:7} after this shipped; the worker below merges it, verifies and reports again"
    emit "spawn $kind=$n cwd=$wt prompt=$wt/.ak/prompt.md model=$(worker_model) effort=$(cfg AGENT_WORKER_EFFORT medium)"
    MERGED_UP="$kind $n $file"
}

# merge_up_children WORKTREE: every shipped worktree stacked on this one's branch gets its turn. Each child's own
# collect then reaches the next level, so a stack follows its base one finished link at a time.
merge_up_children() {
    local branch wt file kind n
    branch=$(git -C "$1" branch --show-current 2>/dev/null)
    [[ -n $branch ]] || return 0
    while IFS= read -r wt; do
        [[ $wt != "$1" && $(head -n 1 -- "$wt/.ak/base" 2>/dev/null) == "$branch" ]] || continue
        merge_up "$wt" || continue
        # The child is out again: no run may count it as done and build on it meanwhile.
        read -r kind n file <<<"$MERGED_UP"
        RUNFILE=$file run_update '(.items[] | select(.kind == $k and .n == $n)).state = "spawned"' --arg k "$kind" --argjson n "$n"
    done < <(git -C "$MAIN" worktree list --porcelain | sed -n 's/^worktree //p')
}

# release_other_runs N WORKTREE: every run of the last day that holds N as parked or spawned (a prior attempt that
# owned the issue) with a successor queued behind it records N as collected and spawns from there. After a park,
# `ak plan --issue N` makes a new run holding only N; a field operator re-planned the whole list by hand to keep the
# earlier run's chain alive. A queued N is left alone: it waited on a predecessor that never finished there, so the
# branch collected elsewhere does not hold that predecessor's work.
release_other_runs() {
    local n=$1 wt=$2 file own=$RUNFILE
    while IFS= read -r file; do
        [[ $file != "$own" ]] || continue
        jq -e --argjson n "$n" '(.items | any(.kind == "issue" and .n == $n and (.state | IN("parked", "spawned"))))
            and (.items | any(.kind == "issue" and .state == "queued" and (.needs | index($n))))' "$file" >/dev/null 2>&1 || continue
        RUNFILE=$file
        run_update '(.items[] | select(.kind == "issue" and .n == $n)) |= (.state = "collected" | .worktree = $wt)' \
            --argjson n "$n" --arg wt "$wt" \
            || { emit "note=could not update run $(basename -- "$file" .json) for issue $n; its successors wait"; continue; }
        spawn_successors
    done < <(find "$MAIN/.ak/runs" -maxdepth 1 -name '*.json' -mmin -1440 2>/dev/null | LC_ALL=C sort)
    RUNFILE=$own
}

cmd_main() {
    local kind='' n='' item worktree state=collected m
    case ${1:-} in
        --issue | --pr) kind=${1#--}; n=${2:-} ;;
    esac
    [[ -n $kind && $n =~ ^[0-9]+$ && $# -eq 2 ]] || usage_die 'usage: ak collect (--issue N | --pr N)'
    plan_context collect
    run_lock collect
    trap 'run_unlock' EXIT
    [[ -f $MAIN/.ak/runs/current ]] || die 'no current run' 'ak plan'
    RUNFILE="$MAIN/.ak/runs/$(<"$MAIN/.ak/runs/current").json"
    [[ -f $RUNFILE ]] || die "run file missing: $RUNFILE" 'ak plan'
    item=$(collect_item "$kind" "$n" "$RUNFILE")
    if [[ -z $item ]]; then
        # A later plan may have made another run current; the item's own run still owns it.
        local other runs=()
        mapfile -t runs < <(ls -t -- "$MAIN"/.ak/runs/*.json 2>/dev/null)
        for other in "${runs[@]}"; do
            item=$(collect_item "$kind" "$n" "$other")
            [[ -z $item ]] || { RUNFILE=$other; break; }
        done
    fi
    [[ -n $item ]] || die "$kind $n is not in any run" "ak plan --issue $n"
    worktree=$(jq -r '.worktree // ""' <<<"$item")
    if ! result_line "$kind" "$n" "$worktree"; then
        cross_write
        printf '%s\n' "${LINES[@]}"
        return 0
    fi
    cross_write
    # A parked issue shipped nothing, so it releases nothing: its successors would start without its work and park too
    # (a field chain spawned two workers that only found the parked predecessor missing).
    if [[ $(sed -n 's/^pr=//p' "$worktree/.ak/result" | head -n 1) != http* ]]; then
        state=parked
    elif [[ $kind == issue && $RESULT_CI =~ ^(red|blocked)$ ]]; then
        # A red predecessor releases nothing either: a field successor was spawned on a red branch, and every PR above
        # it would have inherited the failing check. The item goes back to spawned, so nothing queued counts it as
        # done (even if an earlier collect had) and the next collect reads CI again.
        state=$RESULT_CI
    elif [[ $kind == issue && ${RESULT_CI:-pending} == pending ]]; then
        # A predecessor still pending after the wait is not done either: a merge-down worker's receipt can land before
        # CI concludes, and a field successor was spawned twice on exactly that.
        state=pending
    elif merge_up "$worktree"; then
        # Its own base moved while it worked: it goes back to its worker before anything is built on it.
        state=merge-up
    fi
    if [[ $state != collected ]]; then
        while IFS= read -r m; do emit "after issue=$m reason=waits-on-$state-#$n"; done < <(jq -r --argjson n "$n" \
            '.items[] | select(.kind == "issue" and .state == "queued" and (.needs | index($n))) | .n' "$RUNFILE")
        [[ $kind != issue || $state == merge-up ]] || collect_next "$state" "$n" "$worktree"
    fi
    run_update '(.items[] | select(.kind == $k and .n == $n)).state = $s' --arg k "$kind" --argjson n "$n" \
        --arg s "$([[ $state =~ ^(red|blocked|pending|merge-up)$ ]] && echo spawned || echo "$state")"
    [[ $state != collected ]] || merge_up_children "$worktree"
    [[ $kind != issue || $state != collected ]] || { spawn_successors; release_other_runs "$n" "$worktree"; }
    printf '%s\n' "${LINES[@]}"
}
