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
worker_ledger="$tmp/active-workers.ndjson"
dispatch_plan="$tmp/dispatch-plan.json"
: >"$worker_ledger"
chmod 600 "$worker_ledger"
printf '%s\n' '{"schemaVersion":1,"entries":[],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$dispatch_plan"
chmod 600 "$dispatch_plan"

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

unverified_inventory=$(snapshot '["issue-A"]' '[]' '[]' '[]' '["issue-A"]' true false)
decision=$("$script" next-action --file "$state" --json "$unverified_inventory")
assert_eq 'reconcile' "$(jq -r .next_action <<<"$decision")" \
    'actionable work cannot dispatch until the operation inventory is complete'

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

# A queued operator message starts a new root turn. An accepted pushed result
# in durable state is authoritative even when the caller replays an empty,
# formerly-complete snapshot. The receipt maps to its issue through the
# ownership attempt; absent issue-to-PR evidence stays concrete reconciliation.
"$script" set --file "$state" --path binding --json \
    '{"run_id":"wave","activation_session":"session","repository_root":"/repo","decision_ledger":"/repo/decisions","worker_ledger":"/repo/workers"}'
"$script" set --file "$state" --path results.attempt605 --json \
    '{"status":"accepted","claims":{"push":"valid"},"fingerprint":"fp","result":"/worker/result.json","runId":"wave","workerId":"worker605","obligations":["root-review","root-ci","draft-pr"]}'
printf '%s\n' \
    '{"version":2,"runId":"wave","attempt":"attempt605","workerId":"worker605","issue":605,"worktree":"/repo/.worktrees/605","branch":"fix/605","state":"terminal","disposition":"handed-back","evidence":"receipt","heartbeatEpoch":1}' \
    >"$worker_ledger"
printf '%s\n' \
    '{"schemaVersion":1,"entries":[{"issue":605,"predictedWriteSet":["src/**"],"expectedPredecessors":[]}],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$dispatch_plan"

missing_sources_rc=0
missing_sources_err=$("$script" next-action --after-steer --file "$state" --json "$drained" \
    2>&1 >/dev/null) || missing_sources_rc=$?
assert_eq 2 "$missing_sources_rc" 'after-steer requires authoritative durable source paths'
assert_contains "$missing_sources_err" '--worker-ledger and --dispatch-plan' \
    'the required source scan names both missing inputs'

outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq 1 "$(jq -r .outstanding <<<"$outstanding")" \
    'one accepted pushed result without issue-to-PR evidence is outstanding'
assert_eq 'result:attempt605:reconcile-publication-mapping' \
    "$(jq -r '.obligations[0].id' <<<"$outstanding")" \
    'the durable summary names the exact producer evidence gap'

decision=$("$script" next-action --after-steer --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan" --json "$drained")
assert_eq 'reconcile' "$(jq -r .next_action <<<"$decision")" \
    'durable result evidence overrides a caller-supplied empty snapshot'
assert_eq 1 "$(jq -r .outstanding <<<"$decision")" \
    'the next-action decision retains the derived result obligation'
assert_eq true "$(jq -r .resume_required <<<"$decision")" \
    'the derived reconciliation keeps the post-steer turn active'

# Add the other incident records: the accepted initial publication releases a
# queued successor, while an opened PR lacking a receipt remains publication
# work. These source records, rather than fabricated snapshot strings, produce
# the three-obligation resumed wave.
"$script" set --file "$state" --path initialPublications.605 --json \
    '{"attempt":"attempt605","branch":"fix/605","headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
"$script" set --file "$state" --path opened_prs --json '[604]'
"$script" set --file "$state" --path receipt_prs --json '[]'
"$script" set --file "$state" --path skipped_prs --json '[]'
"$script" set --file "$state" --path queued --json '[606]'
printf '%s\n' \
    '{"schemaVersion":1,"entries":[{"issue":604,"predictedWriteSet":["docs/**"],"expectedPredecessors":[]},{"issue":605,"predictedWriteSet":["src/**"],"expectedPredecessors":[]},{"issue":606,"predictedWriteSet":["tests/**"],"expectedPredecessors":[605]}],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$dispatch_plan"

decision=$("$script" next-action --after-steer --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan" --json "$drained")
assert_eq 'dispatch' "$(jq -r .next_action <<<"$decision")" \
    'fresh post-steer obligations resume the authorized wave'
assert_eq 3 "$(jq -r .outstanding <<<"$decision")" \
    'the decision reports every reconciled unfinished obligation'
assert_eq true "$(jq -r .resume_required <<<"$decision")" \
    'a post-steer dispatch decision forbids ending the root turn'
assert_eq false "$(jq -r .wait_allowed <<<"$decision")" \
    'actionable post-steer work resumes directly instead of entering a wait'
assert_eq '["pr:604:publish-receipt","queued:606:dispatch-successor","result:attempt605:reconcile-publication-mapping"]' \
    "$(jq -c '.orchestration.snapshot.remaining_work | sort' "$state")" \
    'saved next-action state records every source-derived obligation'

# Ambiguous readiness evidence is reconciliation, even when the first duplicate
# entry alone would make the successor appear ready.
printf '%s\n' \
    '{"schemaVersion":1,"entries":[{"issue":605,"predictedWriteSet":["src/**"],"expectedPredecessors":[]},{"issue":606,"predictedWriteSet":["tests/**"],"expectedPredecessors":[]},{"issue":606,"predictedWriteSet":["other/**"],"expectedPredecessors":[999]}],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$dispatch_plan"
outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq 'queued:606:reconcile-dispatch-readiness' \
    "$(jq -r '.obligations[] | select(.issue == 606) | .id' <<<"$outstanding")" \
    'duplicate plan entries cannot manufacture successor readiness'

# Once the existing schema-2 plan maps the result issue to its opened PR and
# the PR has a receipt, the derived obligation is genuinely discharged.
"$script" set --file "$state" --path receipt_prs --json '[604]'
"$script" set --file "$state" --path queued --json '[]'
printf '%s\n' \
    '{"schemaVersion":2,"entries":[{"issue":605,"predictedWriteSet":["src/**"],"expectedPredecessors":[]}],"conflictMap":{"pairs":[],"revisions":[]},"generatedAt":"2026-09-24T12:07:00Z","independent":[{"issue":605,"pr":604,"branch":"fix/605","chainBaseSha":null,"headSha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}],"chains":[]}' \
    >"$dispatch_plan"
outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq 0 "$(jq -r .outstanding <<<"$outstanding")" \
    'mapped opened result plus receipt leaves no durable publication obligation'

# A receipt for another opened PR cannot suppress the exact missing receipt.
"$script" set --file "$state" --path results --json '{}'
"$script" set --file "$state" --path opened_prs --json '[604,605]'
"$script" set --file "$state" --path receipt_prs --json '[605]'
outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq 1 "$(jq -r .outstanding <<<"$outstanding")" \
    'one opened PR without its own receipt stays outstanding'
assert_eq '["pr:604:publish-receipt"]' "$(jq -c .actionable_work <<<"$outstanding")" \
    'the missing PR receipt is directly actionable'
"$script" set --file "$state" --path receipt_prs --json '[604,605]'
outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq 0 "$(jq -r .outstanding <<<"$outstanding")" \
    'receipts for both opened PRs discharge the publication obligations'

# A current-run nonterminal owner is a first-class operation even when the
# caller supplies no operation. A stale queued row for that same issue cannot
# dispatch a duplicate, while an independent queued issue remains actionable.
printf '%s\n' \
    '{"version":2,"runId":"wave","attempt":"attempt607","workerId":"worker607","issue":607,"worktree":"/repo/.worktrees/607","branch":"fix/607","state":"active","disposition":"returned","evidence":"","heartbeatEpoch":2}' \
    >>"$worker_ledger"
"$script" set --file "$state" --path queued --json '[607,608]'
printf '%s\n' \
    '{"schemaVersion":1,"entries":[{"issue":607,"predictedWriteSet":["a/**"],"expectedPredecessors":[]},{"issue":608,"predictedWriteSet":["b/**"],"expectedPredecessors":[]}],"conflictMap":{"pairs":[],"revisions":[]}}' \
    >"$dispatch_plan"
outstanding=$("$script" outstanding --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan")
assert_eq '["queued:608:dispatch-successor"]' "$(jq -c .actionable_work <<<"$outstanding")" \
    'same-issue active ownership blocks only its stale queued dispatch'
assert_eq 'reconcile-active-owner' \
    "$(jq -r '.obligations[] | select(.issue == 607 and .kind == "queue") | .next_action' <<<"$outstanding")" \
    'the stale same-issue queue row remains concrete reconciliation'
decision=$("$script" next-action --after-steer --file "$state" \
    --worker-ledger "$worker_ledger" --dispatch-plan "$dispatch_plan" --json "$drained")
assert_eq 'dispatch' "$(jq -r .next_action <<<"$decision")" \
    'independent durable work dispatches beside a same-issue active owner'
assert_eq 3 "$(jq -r .outstanding <<<"$decision")" \
    'the active owner, stale queue row, and independent queue row all remain visible'
assert_eq 'active' "$(jq -r '.orchestration.snapshot.operations[0].status' "$state")" \
    'the saved operation preserves the worker ledger state'

missing_field=$(jq 'del(.operations)' <<<"$operator_only")
before_missing=$(sha256sum "$state")
missing_rc=0
missing_err=$("$script" next-action --file "$state" --json "$missing_field" 2>&1 >/dev/null) || missing_rc=$?
assert_eq 1 "$missing_rc" 'omitted operation evidence is refused instead of defaulting to empty'
assert_contains "$missing_err" 'invalid next-action snapshot' \
    'an incomplete snapshot names the evidence failure'
assert_eq "$before_missing" "$(sha256sum "$state")" \
    'invalid evidence leaves the saved checkpoint unchanged'

help_text=$("$script" --help)
help_example=$(sed -n 's/^Example: //p' <<<"$help_text")
assert_contains "$help_text" 'observed_at (YYYY-MM-DDThh:mm:ss[.fff]Z)' \
    'help names the accepted UTC timestamp shape'
assert_contains "$help_text" 'actionable_complete, operations_complete' \
    'help names both mandatory evidence completeness fields'
assert_contains "$help_text" 'operations require id, kind (worker|reviewer|test|other), status (active|unknown), and affected' \
    'help names every mandatory operation field and allowed classification'
assert_contains "$help_text" 'operator_dependencies require question and affected' \
    'help names every mandatory operator dependency field'
assert_eq 1 "$(grep -c '^Example: ' <<<"$help_text")" \
    'help prints one unambiguous snapshot example'
help_decision=$("$script" next-action --file "$tmp/help-state.json" --json "$help_example")
assert_eq 'dispatch' "$(jq -r .next_action <<<"$help_decision")" \
    'the documented nested snapshot example is directly executable'

finish
