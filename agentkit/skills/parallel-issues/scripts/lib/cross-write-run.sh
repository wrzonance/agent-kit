#!/usr/bin/env bash
# Run-scoped Collect for cross-write-check.sh; sourced, uses its helpers.

refuse() {
    printf '%s: %s\n' "$PROGRAM" "$1" >&2
    exit 1
}

# agree FLAG GIVEN DERIVED: an explicit flag may restate the run's value, never replace it.
agree() {
    [[ -z $2 || $2 == "$3" ]] || die "$1 $2 disagrees with the run's $3; drop $1"
}

# Collect by run: the root checkout, dispatch-fence baseline and its recorded
# identity, and the worker's worktree and reservation time are all read from
# the run, so the root transcribes nothing. End defaults to now; write sets to
# the baseline's dispatched set.
run_collect_cmd() {
    local run_id='' issue='' repo_root=. root='' snapshot='' worker='' baseline_id='' start=''
    local primary derived_snapshot derived_baseline ledger reservation count derived_worker derived_start
    local -a rest=()
    while (($#)); do
        case $1 in
            --run-id|--issue|--repo-root|--root|--snapshot|--worker-worktree|--worktree|--baseline-id|--worker-start)
                (($# >= 2)) || die "$1 requires a value"
                case $1 in
                    --run-id) run_id=$2;; --issue) issue=${2#\#};; --repo-root) repo_root=$2;;
                    --root) root=$(require_root "$2");; --snapshot) snapshot=$2;;
                    --worker-worktree|--worktree) worker=$(canonical_dir "$2") || die "cannot resolve worker worktree: $2";;
                    --baseline-id) baseline_id=$2;; --worker-start) start=$2;;
                esac
                shift 2;;
            *) rest+=("$1"); shift;;
        esac
    done
    [[ $run_id =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] || die "invalid --run-id: $run_id"
    [[ $issue =~ ^[1-9][0-9]*$ ]] || die '--run-id Collect requires --issue N'
    primary=$(git -C "$repo_root" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')
    primary=$(require_root "${primary:-$repo_root}")
    agree --root "$root" "$primary"
    root=$primary
    derived_snapshot="$root/.agent/cross-write-dispatch-$run_id.snapshot"
    [[ -z $snapshot ]] || snapshot=$(canonical_file_parent "$snapshot") || die "cannot resolve snapshot: $snapshot"
    agree --snapshot "$snapshot" "$derived_snapshot"
    derived_baseline=$("${SCRIPT_PATH%/*}/../../.shared/scripts/run-state.sh" get --run-id "$run_id" \
        --repo-root "$root" --path cross_write.baseline_id 2>/dev/null) ||
        refuse "run $run_id recorded no cross_write.baseline_id; its dispatch-fence snapshot was never persisted"
    agree --baseline-id "$baseline_id" "$derived_baseline"
    ledger="$root/.agent/runs/active-workers.ndjson"
    [[ -f $ledger && ! -L $ledger && -O $ledger && $(stat -c %a -- "$ledger") == [0-7]00 ]] ||
        refuse "no owner-private worker ledger: $ledger"
    reservation=$(jq -Rrn --arg run "$run_id" --argjson issue "$issue" '
        [inputs | fromjson? | objects | select(.runId == $run and .issue == $issue)] |
        ([.[].worktree] | unique) as $w | "\($w | length)\t\($w[0])\t\([.[].heartbeatEpoch | numbers] | min)"' "$ledger") ||
        refuse "unparseable worker ledger: $ledger"
    IFS=$'\t' read -r count derived_worker derived_start <<<"$reservation"
    ((count == 1)) && [[ $derived_start =~ ^[0-9]+$ ]] ||
        refuse "run $run_id has no single timed reservation for issue #$issue ($count worktrees) in $ledger; reserve through named-active-state.sh"
    derived_worker=$(canonical_dir "$derived_worker") || refuse "reserved worktree is gone: $derived_worker"
    agree --worker-worktree "$worker" "$derived_worker"
    # shellcheck disable=SC2034 # read by collect_cmd
    DISPATCH_AUDIT=yes
    collect_cmd --root "$root" --snapshot "$derived_snapshot" --worker-worktree "$derived_worker" \
        --issue "$issue" --run-id "$run_id" --baseline-id "$derived_baseline" \
        --worker-start "${start:-$derived_start}" "${rest[@]}"
}
