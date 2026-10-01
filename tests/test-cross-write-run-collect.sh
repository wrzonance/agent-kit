#!/usr/bin/env bash
# Suite: `collect --run-id ID --issue N` derives every Collect input from the
# run, so the root never transcribes a snapshot path, baseline, worktree,
# window, or write set (field ledger #44: ~9 calls, then a skipped fence).
set -uo pipefail

TEST_NAME='cross-write-run-collect'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE

cross_write="$root/agentkit/skills/parallel-issues/scripts/cross-write-check.sh"
run_state="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

checkout="$tmp/checkout"
worker="$tmp/worker-579"
mkdir -p "$checkout/.agent/runs" "$checkout/src"
git init -q -b main "$checkout"
printf '.agent/\n' >>"$checkout/.git/info/exclude"
printf 'base\n' >"$checkout/src/data.txt"
git -C "$checkout" add src/data.txt
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -qm base
git -C "$checkout" worktree add -q -b feat/issue-579 "$worker"

# Dispatch: the canonical fence snapshot, captured 20s ago so the reservation
# (10s ago) falls in a later second, and its identity recorded in run state.
run_id=parallel-issues-44
snapshot="$checkout/.agent/cross-write-dispatch-$run_id.snapshot"
"$cross_write" dispatch-fence --root "$checkout" --output "$snapshot" \
    --run-id "$run_id" --write-set 'src/**' >/dev/null
sed -e "s/^captured-at=.*/captured-at=$(date -u -d @$(($(date +%s) - 20)) +%FT%T).000000001Z/" \
    -e '/^baseline-id=/d' "$snapshot" >"$snapshot.rewrite"
baseline_id=$(sha256sum -- "$snapshot.rewrite" | awk '{print $1}')
printf 'baseline-id=%s\n' "$baseline_id" >>"$snapshot.rewrite"
mv -- "$snapshot.rewrite" "$snapshot"
"$run_state" set --run-id "$run_id" --repo-root "$checkout" \
    --path cross_write.baseline_id --value "$baseline_id"
ledger="$checkout/.agent/runs/active-workers.ndjson"
jq -nc --arg w "$worker" --arg r "$run_id" --argjson t "$(($(date +%s) - 10))" \
    '{version:2, issue:579, worktree:$w, branch:"feat/issue-579", runId:$r, attempt:"a1",
      workerId:null, state:"unknown", disposition:"reserved", evidence:"", heartbeatEpoch:$t}' >"$ledger"
chmod 600 "$ledger"

collect() {
    out=$("$cross_write" collect "$@" 2>&1)
    rc=$?
}

collect --run-id "$run_id" --issue 579 --repo-root "$checkout"
assert_eq 0 "$rc" 'run-scoped Collect succeeds with only run id and issue'
assert_contains "$out" "cross-write=none root=$checkout run-id=$run_id baseline-id=$baseline_id" \
    'clean evidence is bound to the recorded run and baseline'

decoy="$tmp/decoy"
git init -q -b main "$decoy"
out=$(GIT_DIR="$decoy/.git" GIT_WORK_TREE="$decoy" "$cross_write" collect \
    --run-id "$run_id" --issue 579 --repo-root "$checkout" 2>&1)
rc=$?
assert_eq 0 "$rc" 'inherited GIT_DIR/GIT_WORK_TREE do not redirect run-scoped Collect'
assert_contains "$out" "cross-write=none root=$checkout run-id=$run_id" \
    'the run root stays the intended checkout under hook variables'

printf 'leak\n' >"$checkout/src/leak.txt"
collect --run-id "$run_id" --issue 579 --repo-root "$worker"
assert_eq 10 "$rc" 'a planted root write is an incident, even when invoked from the worker worktree'
assert_contains "$out" 'cross-write=path=src/leak.txt issue=579 attribute=mtime-window' \
    'the write is attributed to the reserved worker window'
rm -f -- "$checkout/src/leak.txt"

collect --run-id "$run_id" --issue 579 --repo-root "$checkout" --worker-start 1
assert_eq 11 "$rc" 'explicit flags still pass through to the audited Collect'
assert_contains "$out" 'invariant=capture-before-dispatch' 'the audit judges the explicit start'

# Routing reads whole arguments: a legacy snapshot path containing ' --run-id '
# stays on the legacy Collect.
odd_dir="$checkout/.agent/x --run-id y"
mkdir -p "$odd_dir"
"$cross_write" snapshot --root "$checkout" --output "$odd_dir/legacy.snapshot" --write-set 'src/**' >/dev/null
collect --root "$checkout" --snapshot "$odd_dir/legacy.snapshot" --worktree "$worker" --issue 579 --write-set 'src/**'
assert_eq 0 "$rc" 'a legacy snapshot path containing --run-id routes to legacy Collect'
assert_contains "$out" 'current-state=none' 'legacy Collect prints its own clean marker'

collect --root "$checkout" --snapshot "$snapshot" --worktree "$worker" --issue 579 \
    --worker-start 1790623767 --worker-end "$(date -u +%s)" --write-set 'src/**'
assert_eq 2 "$rc" 'plain Collect refuses a dispatch-fence baseline'
assert_contains "$out" "dispatch-fence baseline; Collect it with: cross-write-check.sh collect --run-id $run_id --issue 579 --repo-root $checkout" \
    'the wrong-artifact refusal prints the run-scoped command'
assert_not_contains "$out" 'captured-at is invalid' 'the refusal no longer blames captured-at'

collect --run-id "$run_id" --issue 580 --repo-root "$checkout"
assert_eq 11 "$rc" 'an issue with no reservation has no worker start'
assert_contains "$out" 'invariant=worker-start-required' 'the existing audit names the missing start'
unrecorded_row=$(jq -c '.runId = "unrecorded-run"' "$ledger")
printf '%s\n' "$unrecorded_row" >>"$ledger"
collect --run-id unrecorded-run --issue 579 --repo-root "$checkout"
assert_eq 11 "$rc" 'a run with no recorded baseline is unavailable evidence'
assert_contains "$out" 'invariant=baseline-readable' 'the existing audit names the missing baseline'

finish
