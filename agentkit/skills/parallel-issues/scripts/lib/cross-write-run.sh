#!/usr/bin/env bash
# Run-scoped Collect for cross-write-check.sh; sourced, uses its helpers.

# Collect by run: the root checkout, dispatch-fence baseline and its recorded
# identity, and the worker's reserved worktree and reservation time are read
# from the run, so the root transcribes nothing. Remaining flags pass through
# to the audited Collect, which enforces every existing invariant.
run_collect_cmd() {
    local run_id='' issue='' repo_root=. root baseline_id reservation worker='' start=''
    local -a rest=()
    while (($#)); do
        case $1 in
            --run-id|--issue|--repo-root)
                (($# >= 2)) || die "$1 requires a value"
                case $1 in --run-id) run_id=$2;; --issue) issue=${2#\#};; --repo-root) repo_root=$2;; esac
                shift 2;;
            *) rest+=("$1"); shift;;
        esac
    done
    [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ && $issue =~ ^[1-9][0-9]*$ ]] || usage
    root=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    root=$(require_root "${root:-$repo_root}")
    baseline_id=$("${SCRIPT_PATH%/*}/../../.shared/scripts/run-state.sh" get --run-id "$run_id" \
        --repo-root "$root" --path cross_write.baseline_id 2>/dev/null) || baseline_id=''
    reservation=$(jq -Rrn --arg run "$run_id" --argjson issue "$issue" '
        [inputs | fromjson? | objects | select(.runId == $run and .issue == $issue)] |
        select(length > 0) | "\(.[-1].worktree)\t\([.[].heartbeatEpoch | numbers] | min)"' \
        "$root/.agent/runs/active-workers.ndjson" 2>/dev/null) || reservation=''
    IFS=$'\t' read -r worker start <<<"$reservation"
    [[ -n $worker && $start =~ ^[0-9]+$ ]] || audit_unavailable worker-start-required record-dispatch-start
    # The run records no finish time; a window ending now would admit later root edits as duplicates.
    [[ " ${rest[*]} " != *' --dispose-duplicates '* || " ${rest[*]} " == *' --worker-end '* ]] ||
        die '--dispose-duplicates needs --worker-end (the recorded worker finish); drop it to report duplicates as incidents'
    # shellcheck disable=SC2034 # read by collect_cmd
    DISPATCH_AUDIT=yes
    collect_cmd --root "$root" --snapshot "$root/.agent/cross-write-dispatch-$run_id.snapshot" \
        --worker-worktree "$worker" --issue "$issue" --run-id "$run_id" \
        --baseline-id "$baseline_id" --worker-start "$start" "${rest[@]}"
}
