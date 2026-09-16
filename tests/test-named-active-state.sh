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
    local pr=${1:-none}
    shift || true
    "$helper" --repo-root "$repo" --ledger "$ledger" --issue 511 \
        --open-pr "$pr" --fresh-hours 2 --now-epoch 2000000000 "$@"
}

assert_eq 'stale-active=1[#511]' "$(run_state none)" \
    'missing local evidence dispatches a named stale-active issue'
assert_eq 'stale-active=1[#511]' "$(run_state none --)" \
    'a trailing end-of-options marker preserves named-active adjudication'
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

# Two partially successful waves, then a model switch and crash recovery.
rm -- "$ledger"
owner() { "$helper" --repo-root "$repo" --ledger "$ledger" --action "$@"; }
reserve() { owner reserve --issue "$1" --worktree "$2" --branch feat/test --run-id wave --attempt "$3"; }
record() { owner record --attempt "$1" --worker-id "$2"; }
release() { owner release --attempt "$1" --disposition "$2" --evidence 'runtime:confirmed'; }
mkdir -p "$tmp/w459" "$tmp/w460"
assert_rc 0 'first success reserves before submission' -- reserve 455 "$worker" first
assert_rc 0 'first ID is durable immediately' -- record first worker-455
assert_rc 0 'second success reserves independently' -- reserve 459 "$tmp/w459" second
assert_rc 0 'second ID persists' -- record second worker-459
assert_rc 0 'third submission reserves' -- reserve 460 "$tmp/w460" third
assert_rc 0 'definite capacity rejection releases only third attempt' -- release third rejected
assert_rc 2 'partial retry never duplicates first writer' -- reserve 455 "$worker" duplicate
assert_rc 0 'retry only the rejected entry' -- reserve 460 "$tmp/w460" retry
assert_rc 0 'retry persists its ID' -- record retry worker-460
assert_eq '3' "$(owner inventory | jq '[.[] | select(.state == "active")] | length')" 'both partial waves retain all successes'
assert_rc 2 'model switch cannot replace active writer' -- reserve 459 "$tmp/w459" new-model
assert_rc 0 'confirmed stop is a durable disposition' -- release second stopped
assert_rc 0 'replacement acquires after confirmed stop' -- reserve 459 "$tmp/w459" new-model
assert_rc 2 'crash before ID persistence blocks blind retry' -- reserve 459 "$tmp/w459" blind
assert_eq 'unknown' "$(owner inventory | jq -r '.[] | select(.attempt == "new-model") | .state')" 'crashed submission remains unknown'
assert_rc 0 'runtime reconciliation attaches recovered ID' -- record new-model recovered
assert_rc 2 'a different ID cannot overwrite a returned ID' -- record new-model imposter
assert_rc 2 'release requires runtime evidence' -- owner release --attempt new-model --disposition stopped
assert_rc 0 'completion releases with evidence' -- release new-model completed
assert_rc 2 'old attempt cannot be reopened' -- record new-model recovered
assert_eq 'stale-active=1[#459]' "$("$helper" --repo-root "$repo" --ledger "$ledger" --issue 459 --fresh-hours 2)" 'terminal runtime evidence wins over registered directory'

# Path aliases and simultaneous ownership acquisition share one lock.
ln -s "$tmp/w459" "$tmp/alias459"
pids=()
for n in 1 2 3 4; do
    reserve 459 "$tmp/alias459/../alias459" "race$n" >"$tmp/race$n.out" 2>&1 &
    pids+=("$!")
done
winners=0
for pid in "${pids[@]}"; do
    if wait "$pid"; then winners=$((winners + 1)); fi
done
assert_eq 1 "$winners" 'concurrent alias reservations acquire exactly one owner'
assert_rc 2 'canonical spelling cannot bypass alias reservation' -- reserve 459 "$tmp/w459" canonical
assert_eq 'held-active:#459 reason=unknown' "$("$helper" --repo-root "$repo" --ledger "$ledger" --issue 459 --fresh-hours 2)" 'unknown ownership never ages out'
assert_eq 3 "$(owner inventory | jq '[.[] | select(.state != "terminal")] | length')" 'inventory accounts for unknown capacity without a false complete manifest'

assert_rc 2 'linked checkout shares primary ownership registry' -- "$helper" --repo-root "$worker" \
    --ledger "$ledger" --action reserve --issue 455 --worktree "$worker" --branch feat/test --run-id resumed --attempt linked
assert_rc 2 'alternate ledger cannot bypass repository ownership' -- "$helper" --repo-root "$repo" \
    --ledger "$repo/.agent/runs/other.ndjson" --action inventory

# A second partial batch must also preserve success when its next call fails.
assert_rc 0 'handback permits a new model for first worktree' -- release first handed-back
assert_rc 0 'second batch reserves first replacement' -- reserve 455 "$worker" switched-first
assert_rc 0 'second batch records its successful replacement' -- record switched-first switched-455
assert_rc 0 'second batch frees next worktree' -- release retry stopped
assert_rc 0 'second batch reserves next submission' -- reserve 460 "$tmp/w460" switched-next
assert_rc 0 'second batch capacity rejection is durable' -- release switched-next rejected
assert_rc 2 'retry of second batch cannot duplicate its successful entry' -- reserve 455 "$worker" repeated-switch
assert_rc 0 'second partial retry reserves only rejected entry' -- reserve 460 "$tmp/w460" switched-retry
assert_rc 0 'second partial retry records returned ID' -- record switched-retry switched-460
assert_eq switched-455 "$(owner inventory | jq -r '.[] | select(.issue == 455) | .workerId')" 'second failure never erases earlier replacement ID'

cp -- "$ledger" "$tmp/valid-ledger"
jq -c 'if .state == "unknown" then del(.workerId) else . end' "$tmp/valid-ledger" >"$ledger"
assert_rc 0 'inventory exposes incomplete v2 ownership evidence' -- owner inventory
assert_rc 2 'incomplete v2 ownership evidence blocks mutations' -- reserve 459 "$tmp/w459" malformed
cp -- "$tmp/valid-ledger" "$ledger"
chmod 644 "$ledger"
assert_rc 2 'worker identities require owner-private ledger' -- owner inventory
chmod 600 "$ledger"

# Legacy extensions, inspectable corruption, and conservative maintenance.
printf '%s\n' '{"version":1,"issue":423,"worktree":"/old","branch":"feat/old","state":"terminal","heartbeatEpoch":1789317596,"result":"blocked-protected-migration"}' >"$ledger"
assert_rc 0 'legacy result extension is tolerated even inside freshness window' -- owner reserve --issue 423 --worktree "$worker" --branch feat/test --run-id legacy --attempt legacy --now-epoch 1789317597
assert_rc 0 'inventory reads legacy result row' -- owner inventory
assert_rc 2 'prune refuses unknown reservations regardless of age' -- owner prune --now-epoch 2000000000
assert_rc 0 'record unknown reservation' -- record legacy legacy-worker
assert_rc 2 'prune refuses active rows' -- owner prune
printf '%s\n' '{"version":2,"issue":423,"worktree":"/old","branch":"feat/old","state":"terminal","heartbeatEpoch":1999999999,"runId":"r","attempt":"a","workerId":null,"disposition":"completed","evidence":"receipt","result":"extra"}' >"$ledger"
assert_rc 2 'fresh v2 unknown key remains invalid' -- run_state none
diagnostic=$(run_state none 2>&1)
assert_eq yes "$(case "$diagnostic" in *'line 1'*'keys=result'*'predicate=allowed-keys'*) echo yes;; *) echo no;; esac)" 'diagnostic names original line, key and predicate'
assert_rc 0 'inventory exposes invalid v2 keys' -- owner inventory
assert_rc 0 'aged terminal rows are filtered before validation' -- run_state none --now-epoch 2000010000
printf '%s\n' '{not-json' >>"$ledger"
assert_rc 0 'inventory survives unparseable lines' -- owner inventory
assert_eq 2 "$(owner inventory | jq '.[] | select(.predicate == "json") | .line')" 'inventory identifies unparseable line'
assert_rc 0 'prune repairs unparseable and aged terminal rows' -- owner prune --now-epoch 2000010000
assert_eq 0 "$(wc -l <"$ledger" | tr -d ' ')" 'prune drops exactly damaged and expired rows'
assert_eq 600 "$(stat -c %a "$ledger")" 'repair preserves owner-private ledger mode'
printf '%s\n' '{"version":1,"issue":511,"worktree":"/old","branch":"feat/old","state":"active","heartbeatEpoch":1}' '{"version":1,"issue":511,"worktree":"/old","branch":"feat/old","state":"terminal","heartbeatEpoch":2,"result":"legacy"}' >"$ledger"
assert_eq 'stale-active=1[#511]' "$(run_state none)" 'aging terminal validation never resurrects earlier active ownership'
assert_rc 2 'prune conservatively refuses even historical active rows' -- owner prune
finish
