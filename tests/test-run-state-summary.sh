#!/usr/bin/env bash
# Suite: run-state summary renders handoff coverage from durable state.
set -uo pipefail

TEST_NAME='run-state summary'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

script="$root/agentkit/skills/.shared/scripts/run-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
mkdir -p -- "$repo/.agent/evidence/run-wave" "$repo/.agent/runs"
chmod 700 -- "$repo/.agent" "$repo/.agent/evidence" "$repo/.agent/evidence/run-wave" "$repo/.agent/runs"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test

state="$repo/.agent/evidence/run-wave/run-state.json"
printf '%s\n' \
    '{"opened_prs":[],"queued":[103],"receipt_prs":[],"skipped_prs":[]}' >"$state"
chmod 600 -- "$state"

ledger="$repo/.agent/runs/active-workers.ndjson"
printf '%s\n' \
    '{"version":2,"issue":101,"worktree":"/tmp/issue-101","branch":"feat/101","runId":"wave","attempt":"101-a","workerId":"worker-101","state":"terminal","disposition":"handed-back","evidence":"src/one.sh","heartbeatEpoch":1}' \
    '{"version":2,"issue":102,"worktree":"/tmp/issue-102","branch":"feat/102","runId":"wave","attempt":"102-a","workerId":"worker-102","state":"terminal","disposition":"handed-back","evidence":"src/two.sh,tests/two.sh","heartbeatEpoch":2}' \
    '{"version":2,"issue":104,"worktree":"/tmp/issue-104","branch":"feat/104","runId":"other","attempt":"104-a","workerId":"worker-104","state":"terminal","disposition":"handed-back","evidence":"src/other.sh","heartbeatEpoch":3}' \
    >"$ledger"
chmod 600 -- "$ledger"

expected=$'coverage= prs=0 receipts=0 skipped=0 parked=2 queued=1\nblocked=101:src/one.sh\nblocked=102:src/two.sh,tests/two.sh'
assert_eq "$expected" \
    "$(cd -- "$tmp" && "$script" summary --run-id wave --repo-root "$repo")" \
    'summary derives exact coverage and blocker lines from durable state and this run ledger'

mkdir -- "$repo/subdir"
subdir_rc=0
subdir_err=$("$script" summary --run-id wave --repo-root "$repo/subdir" 2>&1 >/dev/null) || subdir_rc=$?
assert_eq 2 "$subdir_rc" 'summary refuses a subdirectory as an ambiguous repository root'
assert_contains "$subdir_err" 'checkout root' 'repository-boundary refusal names the exact required root'

# A later lifecycle row for the same issue supersedes an older handback.
printf '%s\n' \
    '{"version":2,"issue":101,"worktree":"/tmp/issue-101","branch":"feat/101","runId":"wave","attempt":"101-b","workerId":"worker-101b","state":"terminal","disposition":"completed","evidence":"result-101.json","heartbeatEpoch":4}' \
    >>"$ledger"
assert_eq $'coverage= prs=0 receipts=0 skipped=0 parked=1 queued=1\nblocked=102:src/two.sh,tests/two.sh' \
    "$("$script" summary --run-id wave --repo-root "$repo")" \
    'latest lifecycle per issue clears an older handback without duplicate parked coverage'

# Missing receipt collections are an honest empty initial state.
printf '%s\n' '{"opened_prs":[201,202],"queued":[]}' >"$state"
assert_eq 'coverage= prs=2 receipts=0 skipped=0 parked=1 queued=0' \
    "$("$script" summary --run-id wave --repo-root "$repo" | head -n1)" \
    'missing optional receipt and skip collections count as empty'

printf '%s\n' '{"opened_prs":[201],"queued":[],"receipt_prs":[201,201]}' >"$state"
bad_state_rc=0
bad_state_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || bad_state_rc=$?
assert_eq 1 "$bad_state_rc" 'duplicate receipt PRs refuse instead of inflating coverage'
assert_contains "$bad_state_err" 'receipt_prs' 'malformed collection refusal names the recovery field'

printf '%s\n' '{"opened_prs":[],"queued":[]}' >"$state"
printf '%s\n' '{not-json' >>"$ledger"
bad_ledger_rc=0
bad_ledger_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || bad_ledger_rc=$?
assert_eq 1 "$bad_ledger_rc" 'malformed lifecycle evidence refuses an honest summary'
assert_contains "$bad_ledger_err" 'active-workers' 'ledger refusal names the unavailable evidence'

finish
