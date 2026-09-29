#!/usr/bin/env bash
# Suite: `collect --run-id ID --issue N` derives every Collect input from the
# run, so the root never transcribes a snapshot path, baseline, worktree,
# window, or write set (cable-tool ledger #44: ~9 calls, then a skipped fence).
set -uo pipefail

TEST_NAME='cross-write-run-collect'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

cross_write="$root/agentkit/skills/parallel-issues/scripts/cross-write-check.sh"
run_state="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

checkout="$tmp/checkout"
worker="$tmp/worker-579"
other="$tmp/worker-other"
mkdir -p "$checkout/.agent/runs" "$checkout/src"
git init -q -b main "$checkout"
printf '.agent/\n' >>"$checkout/.git/info/exclude"
printf 'base\n' >"$checkout/src/data.txt"
git -C "$checkout" add src/data.txt
git -C "$checkout" -c user.name=t -c user.email=t@example.invalid commit -qm base
git -C "$checkout" worktree add -q -b feat/issue-579 "$worker"
git -C "$checkout" worktree add -q -b feat/other "$other"

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

printf 'leak\n' >"$checkout/src/leak.txt"
collect --run-id "$run_id" --issue 579 --repo-root "$worker"
assert_eq 10 "$rc" 'a planted root write is an incident, even when invoked from the worker worktree'
assert_contains "$out" 'cross-write=path=src/leak.txt issue=579 attribute=mtime-window' \
    'the write is attributed to the reserved worker window'
rm -f -- "$checkout/src/leak.txt"

collect --run-id "$run_id" --issue 579 --repo-root "$checkout" --worker-worktree "$other"
assert_eq 2 "$rc" 'an explicit worktree that disagrees with the reservation refuses'
assert_contains "$out" "--worker-worktree $other disagrees with the run's $worker" \
    'the disagreement names both values'
collect --run-id "$run_id" --issue 579 --repo-root "$checkout" --worker-worktree "$worker" \
    --root "$checkout" --snapshot "$snapshot" --baseline-id "$baseline_id"
assert_eq 0 "$rc" 'explicit flags that restate the run values keep working'
collect --run-id "$run_id" --issue 579 --repo-root "$checkout" --baseline-id "$(printf '%064d' 0)"
assert_eq 2 "$rc" 'a mismatched explicit baseline refuses'

collect --root "$checkout" --snapshot "$snapshot" --worktree "$worker" --issue 579 \
    --worker-start 1790623767 --worker-end "$(date -u +%s)" --write-set 'src/**'
assert_eq 2 "$rc" 'plain Collect refuses a dispatch-fence baseline'
assert_contains "$out" "dispatch-fence baseline; Collect it with: cross-write-check.sh collect --run-id $run_id --issue 579 --repo-root $checkout" \
    'the wrong-artifact refusal prints the run-scoped command'
assert_not_contains "$out" 'captured-at is invalid' 'the refusal no longer blames captured-at'

collect --run-id "$run_id" --issue 580 --repo-root "$checkout"
assert_eq 1 "$rc" 'an issue with no reservation is missing evidence'
assert_contains "$out" 'named-active-state.sh' 'the refusal names the reservation helper'
collect --run-id ghost-run --issue 579 --repo-root "$checkout"
assert_eq 1 "$rc" 'a run with no recorded baseline is missing evidence'
assert_contains "$out" 'recorded no cross_write.baseline_id' 'the refusal names the missing record'

finish
