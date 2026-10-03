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
    local pr=$2 live runs
    [[ $1 == pr ]] || pr=${r[pr]##*/}
    [[ $pr =~ ^[0-9]+$ && -n ${r[head]:-} ]] || return 0
    live=$(api "repos/$SLUG/pulls/$pr" | jq -r 'objects | .head.sha // empty' 2>/dev/null) || return 0
    [[ -n $live && $live != "${r[head]}" ]] || return 0
    runs=$(ci_runs "$live" 2>/dev/null) || return 0
    r[ci]=$(ci_summary "$runs" | sed -E 's/^ci=([a-z]+).*/\1/')
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
    result_refresh "$kind" "$n"
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

# spawn_successors: queued issues whose needs are all collected, each from its last predecessor's branch.
spawn_successors() {
    local n pred from ready active open again=0
    ready=$(jq -r '[.items[] | select(.state == "collected") | .n] as $done |
        .items[] | select(.kind == "issue" and .state == "queued" and ((.needs - $done) | length) == 0) |
        "\(.n)\t\(.needs[-1])"' "$RUNFILE")
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
    ((again == 0)) || spawn_successors
}

# collect_item KIND N FILE: the run item for KIND N in FILE, or nothing.
collect_item() {
    jq -c --arg k "$1" --argjson n "$2" '[.items[] | select(.kind == $k and .n == $n)][0] // empty' "$3"
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
        while IFS= read -r m; do emit "after issue=$m reason=waits-on-parked-#$n"; done < <(jq -r --argjson n "$n" \
            '.items[] | select(.kind == "issue" and .state == "queued" and (.needs | index($n))) | .n' "$RUNFILE")
    fi
    run_update '(.items[] | select(.kind == $k and .n == $n)).state = $s' --arg k "$kind" --argjson n "$n" --arg s "$state"
    [[ $kind != issue || $state == parked ]] || spawn_successors
    printf '%s\n' "${LINES[@]}"
}
