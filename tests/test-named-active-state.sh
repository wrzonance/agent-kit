#!/usr/bin/env bash
# Regression coverage for named fast-mode active-issue liveness adjudication.
set -u

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='named active state'

helper="$root/agentkit/skills/parallel-issues/scripts/named-active-state.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

repo="$tmp/repo"
ledger="$repo/.agent/runs/active-workers.ndjson"
mkdir -p -- "$repo/.agent/runs"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
printf '%s\n' base >"$repo/README.md"
git -C "$repo" add README.md
git -C "$repo" commit -qm base

run_state() {
    "$helper" --repo-root "$repo" --ledger "$ledger" --issue 511 \
        --open-pr "${1:-none}" --fresh-hours 2 --now-epoch 2000000000
}

assert_eq 'stale-active=1[#511]' "$(run_state none)" \
    'missing local evidence dispatches a named stale-active issue'
assert_eq 'held-active:#511 reason=pr pr=#535' "$(run_state 535)" \
    'open PR evidence is the first terminal hold'

worker="$tmp/worker-511"
git -C "$repo" worktree add -q -b feat/issue-511 "$worker"
printf '%s\n' \
    '{"version":1,"issue":511,"worktree":"'"$worker"'","branch":"feat/issue-511","state":"active","heartbeatEpoch":1999990000}' \
    >"$ledger"
chmod 600 "$ledger"
assert_eq 'held-active:#511 reason=worktree' "$(run_state none)" \
    'an active ledger row plus exact Git registration holds for the worktree'

unregistered="$tmp/unregistered-511"
mkdir -p -- "$unregistered"
printf '%s\n' \
    '{"version":1,"issue":511,"worktree":"'"$unregistered"'","branch":"feat/issue-511","state":"active","heartbeatEpoch":1999999999}' \
    >>"$ledger"
assert_eq 'held-active:#511 reason=heartbeat' "$(run_state none)" \
    'a fresh root-owned heartbeat holds after worktree registration is absent'

printf '%s\n' \
    '{"version":1,"issue":511,"worktree":"'"$unregistered"'","branch":"feat/issue-511","state":"active","heartbeatEpoch":1999990000}' \
    >>"$ledger"
assert_eq 'stale-active=1[#511]' "$(run_state none)" \
    'an expired heartbeat without a registered worktree dispatches as stale'

printf '%s\n' \
    '{"version":1,"issue":511,"worktree":"'"$worker"'","branch":"feat/issue-511","state":"terminal","heartbeatEpoch":2000000000}' \
    >>"$ledger"
assert_eq 'stale-active=1[#511]' "$(run_state none)" \
    'the latest terminal row releases an older live worktree record'

mv -- "$ledger" "$ledger.real"
ln -s -- "$ledger.real" "$ledger"
assert_rc 2 'a symlinked worker ledger blocks instead of being trusted' -- run_state none
rm -- "$ledger"
mv -- "$ledger.real" "$ledger"

printf '%s\n' '{not-json' >>"$ledger"
assert_rc 2 'malformed worker evidence blocks instead of dispatching duplicate work' -- run_state none

finish
