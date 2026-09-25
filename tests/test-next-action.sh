#!/usr/bin/env bash
# Suite: run-state next-action saves one complete orchestration checkpoint and
# refuses to turn an incomplete or conflicting observation into an idle wait.
set -uo pipefail

TEST_NAME='next-action'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
state="$tmp/run-state.json"

snapshot() {
    local actionable=$1 operations=$2 dependencies=$3 completed=$4 remaining=$5
    local actionable_complete=${6:-true} operations_complete=${7:-true}
    jq -nc --argjson actionable "$actionable" --argjson operations "$operations" \
        --argjson dependencies "$dependencies" --argjson completed "$completed" \
        --argjson remaining "$remaining" --argjson actionable_complete "$actionable_complete" \
        --argjson operations_complete "$operations_complete" '
        {evidence:{id:"fixture-ledgers@abc123",observed_at:"2026-09-24T12:00:00Z",
                   actionable_complete:$actionable_complete,operations_complete:$operations_complete},
         actionable_work:$actionable,operations:$operations,operator_dependencies:$dependencies,
         completed_work:$completed,remaining_work:$remaining}'
}

assert_rc 0 'fixture state starts with unrelated durable progress' -- \
    "$script" set --file "$state" --path results.done --json '["implemented-A"]'

# The incident boundary: an operator-only remainder must end this orchestration
# turn without entering the caller's wait branch.
operator_only=$(snapshot '[]' '[]' \
    '[{"question":"Choose A rollout policy","affected":["issue-A"]}]' \
    '["issue-B"]' '["issue-A"]')
decision=$("$script" next-action --file "$state" --json "$operator_only")
assert_eq 'end-turn' "$(jq -r .next_action <<<"$decision")" \
    'complete evidence with only operator-owned progress ends the turn'
wait_calls=0
case $(jq -r .next_action <<<"$decision") in collect) wait_calls=$((wait_calls + 1)) ;; esac
assert_eq 0 "$wait_calls" 'the terminal operator decision issues zero new waits'
assert_eq false "$(jq -r .wait_allowed <<<"$decision")" \
    'the executable end-turn boundary explicitly forbids another wait'
assert_eq false "$(jq -r .task_complete <<<"$decision")" \
    'ending the turn does not mark the task complete'
assert_eq false "$(jq -r .ownership_released <<<"$decision")" \
    'ending the turn does not release outstanding ownership'
assert_eq 'Choose A rollout policy' \
    "$(jq -r '.orchestration.snapshot.operator_dependencies[0].question' "$state")" \
    'the exact pending decision is saved for resume'
assert_eq '["issue-A"]' \
    "$(jq -c '.orchestration.snapshot.operator_dependencies[0].affected' "$state")" \
    'the affected workstream is saved for resume'
assert_eq '["issue-B"]' "$(jq -c '.orchestration.snapshot.completed_work' "$state")" \
    'completed work is saved separately from the pending obligation'
assert_eq '["issue-A"]' "$(jq -c '.orchestration.snapshot.remaining_work' "$state")" \
    'remaining work stays pending rather than being marked complete'
assert_eq '["implemented-A"]' "$(jq -c '.results.done' "$state")" \
    'recording the boundary preserves earlier run progress'

# If the operator-only state appears after one bounded collection interval,
# the next evaluation ends instead of beginning a second interval.
active_once=$(snapshot '[]' \
    '[{"id":"worker-A","kind":"worker","status":"active","affected":["issue-A"]}]' \
    '[]' '["issue-B"]' '["issue-A"]')
wait_calls=0
evaluations=0
for observed in "$active_once" "$operator_only"; do
    decision=$("$script" next-action --file "$state" --json "$observed")
    evaluations=$((evaluations + 1))
    case $(jq -r .next_action <<<"$decision") in
        collect) wait_calls=$((wait_calls + 1)) ;;
        end-turn) break ;;
    esac
done
assert_eq 2 "$evaluations" 'operator-only state is recognized at the next bounded evaluation'
assert_eq 1 "$wait_calls" 'operator-only state reached during collection starts no second wait interval'

# An unknown review cannot park an independent authorized workstream. The same
# workstream cannot be both dispatchable and already owned by an operation.
independent=$(snapshot '["issue-B"]' \
    '[{"id":"review-A","kind":"reviewer","status":"unknown","affected":["issue-A"]}]' \
    '[]' '[]' '["issue-A","issue-B"]')
decision=$("$script" next-action --file "$state" --json "$independent")
assert_eq 'dispatch' "$(jq -r .next_action <<<"$decision")" \
    'unknown A does not prevent independent authorized B from starting'
assert_eq 1 "$(jq -r .unknown_operations <<<"$decision")" \
    'dispatch keeps the unrelated unknown outcome visible for reconciliation'

before_conflict=$(sha256sum "$state")
conflict=$(snapshot '["issue-A"]' \
    '[{"id":"worker-A","kind":"worker","status":"active","affected":["issue-A"]}]' \
    '[]' '[]' '["issue-A"]')
conflict_rc=0
conflict_err=$("$script" next-action --file "$state" --json "$conflict" 2>&1 >/dev/null) || conflict_rc=$?
assert_eq 1 "$conflict_rc" 'one obligation cannot be dispatched while an operation owns it'
assert_contains "$conflict_err" 'actionable work overlaps an outstanding operation' \
    'conflicting ownership names the unsafe snapshot'
assert_eq "$before_conflict" "$(sha256sum "$state")" \
    'a refused conflicting snapshot cannot replace the last durable checkpoint'

# Non-worker operations are first-class outstanding work. Unknown outcomes and
# incomplete scans reconcile instead of disappearing into operator-only state.
active_commands=$(snapshot '[]' \
    '[{"id":"review-17","kind":"reviewer","status":"active","affected":["review-17"]},{"id":"tests-17","kind":"test","status":"active","affected":["tests-17"]}]' \
    '[]' '[]' '["review-17","tests-17"]')
decision=$("$script" next-action --file "$state" --json "$active_commands")
assert_eq 'collect' "$(jq -r .next_action <<<"$decision")" \
    'active reviewer and test commands collect even with zero native workers'
assert_eq 2 "$(jq -r .active_operations <<<"$decision")" \
    'the boundary counts actual reviewer and test operations'

unknown=$(snapshot '[]' \
    '[{"id":"tests-timeout","kind":"test","status":"unknown","affected":["tests-timeout"]}]' \
    '[]' '[]' '["tests-timeout"]')
decision=$("$script" next-action --file "$state" --json "$unknown")
assert_eq 'reconcile' "$(jq -r .next_action <<<"$decision")" \
    'a timeout or unknown operation outcome is never treated as completion or approval'

incomplete=$(snapshot '[]' '[]' \
    '[{"question":"Approve release","affected":["release"]}]' '[]' '["release"]' true false)
decision=$("$script" next-action --file "$state" --json "$incomplete")
assert_eq 'reconcile' "$(jq -r .next_action <<<"$decision")" \
    'an incomplete operation scan cannot classify the run as operator-only'

unclassified=$(snapshot '[]' '[]' \
    '[{"question":"Choose A rollout policy","affected":["issue-A"]}]' \
    '[]' '["issue-A","issue-B"]')
decision=$("$script" next-action --file "$state" --json "$unclassified")
assert_eq 'reconcile' "$(jq -r .next_action <<<"$decision")" \
    'remaining work not covered by operator dependencies must be reconciled'

# On reply, a fresh checkpoint advances the saved obligation without replaying
# completed work. A fully drained checkpoint is the only completion decision.
resumed=$(snapshot '["issue-A"]' '[]' '[]' '["issue-B"]' '["issue-A"]')
decision=$("$script" next-action --file "$state" --json "$resumed")
assert_eq 'dispatch' "$(jq -r .next_action <<<"$decision")" \
    'an operator reply resumes at the newly actionable remaining obligation'
assert_eq '["issue-B"]' "$(jq -c '.orchestration.snapshot.completed_work' "$state")" \
    'resume retains successful work instead of scheduling it again'

drained=$(snapshot '[]' '[]' '[]' '["issue-A","issue-B"]' '[]')
decision=$("$script" next-action --file "$state" --json "$drained")
assert_eq 'complete' "$(jq -r .next_action <<<"$decision")" \
    'only a checkpoint with no remaining obligations reports complete'
assert_eq true "$(jq -r .task_complete <<<"$decision")" \
    'the drained checkpoint alone marks the task complete'

missing_field=$(jq 'del(.operations)' <<<"$operator_only")
before_missing=$(sha256sum "$state")
missing_rc=0
missing_err=$("$script" next-action --file "$state" --json "$missing_field" 2>&1 >/dev/null) || missing_rc=$?
assert_eq 1 "$missing_rc" 'omitted operation evidence is refused instead of defaulting to empty'
assert_contains "$missing_err" 'invalid next-action snapshot' \
    'an incomplete snapshot names the evidence failure'
assert_eq "$before_missing" "$(sha256sum "$state")" \
    'invalid evidence leaves the saved checkpoint unchanged'

finish
