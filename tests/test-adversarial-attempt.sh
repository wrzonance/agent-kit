#!/usr/bin/env bash
set -uo pipefail
TEST_NAME='adversarial durable attempts'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/assert.sh"
script="$here/../agentkit/skills/review-remote-pr/scripts/review-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
export CODEX_HOME="$tmp/codex-home"
mkdir -p "$CODEX_HOME"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' >"$CODEX_HOME/config.toml"
git init -q "$tmp/repo"
entry="$tmp/entry.json"
jq -n --arg result "$tmp/result.json" --arg launcher "$script" \
    '{repo:"acme/widget",pr:42,head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",payload:"digest",provider:"anthropic",
      model:"claude-opus-5",effort:"high",launcher:$launcher,launcherPid:1,result:$result}' >"$entry"
attempt() { "$script" attempt "$1" --repo-root "$tmp/repo" --entry-file "$entry" "${@:2}"; }
rc=0
attempt reserve >"$tmp/reservation" 2>"$tmp/error" || rc=$?
assert_eq 0 "$rc" 'reserve persists before any provider launch'
id=$(jq -r '.id // empty' "$tmp/reservation")
assert_eq reserved "$(jq -r '.state' "$tmp/reservation")" 'reservation is not completed review evidence'
assert_rc 20 'replayed reservation cannot spend again' -- attempt reserve
jq '.head="cccccccccccccccccccccccccccccccccccccccc" | .result="another-run"' "$entry" >"$tmp/change"
mv "$tmp/change" "$entry"
assert_rc 20 'changed head and new run path preserve the review budget' -- attempt reserve
jq '.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$entry" >"$tmp/change"
mv "$tmp/change" "$entry"
assert_rc 1 'wrong attempt identity cannot claim reservation' -- attempt start --id wrong
assert_rc 0 'original reservation can transition to running' -- attempt start --id "$id" --pid "$$"
assert_rc 20 'replayed provider start cannot launch twice' -- attempt start --id "$id" --pid "$$"
assert_rc 0 'uncertain completion is retained' -- attempt finish --id "$id" --pid "$$" --state unknown-outcome
attempt read >"$tmp/read"
assert_eq unknown-outcome "$(jq -r '.state' "$tmp/read")" 'unknown outcome remains distinct'
assert_eq 3 "$(jq '.events | length' "$tmp/read")" 'lifecycle events are retained'
assert_rc 20 'unknown outcome is never permission to retry' -- attempt reserve

# Reconciliation observes the original validated result, never starts a CLI.
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"claude-opus-5","verdict":{"verdict":"no_findings","findings":[]}}' >"$tmp/result.json"
assert_rc 0 'lost acknowledgement reconciles the original result' -- attempt reconcile --id "$id"
attempt read >"$tmp/read"
assert_eq completed "$(jq -r '.state' "$tmp/read")" 'reconciliation records completion'
assert_rc 20 'reconciled result still consumes the same budget' -- attempt reserve

jq '.pr=43' "$entry" >"$tmp/change"
mv "$tmp/change" "$entry"
pids=()
for n in {1..8}; do
    (attempt reserve >"$tmp/race.$n.out" 2>"$tmp/race.$n.err"; printf '%s\n' "$?" >"$tmp/race.$n.rc") &
    pids+=("$!")
done
for pid in "${pids[@]}"; do wait "$pid"; done
winners=0
for n in {1..8}; do [[ $(cat "$tmp/race.$n.rc") != 0 ]] || winners=$((winners + 1)); done
assert_eq 1 "$winners" 'concurrent launch requests purchase at most one reservation'

jq '.pr=44' "$entry" >"$tmp/change"
mv "$tmp/change" "$entry"
mkdir -p "$tmp/repo/.agent/evidence/pr-44/state"
printf '{"pr":44,"head":"old","payload":"old"}\n' >"$tmp/repo/.agent/evidence/pr-44/state/launch-attempted"
assert_rc 20 'legacy launch evidence blocks canonical initialization from resetting budget' -- attempt reserve
attempt read >"$tmp/read"
assert_eq unknown-outcome "$(jq -r '.state' "$tmp/read")" 'legacy attempt is retained as unknown'
assert_eq false "$(jq -r '.canonical' "$tmp/read")" 'legacy evidence never becomes canonical provenance'

# These hooks/globals are consumed indirectly by the sourced cleanup routine.
# shellcheck disable=SC2034,SC2329
(
    # The library is checked separately; these mocked functions are subshell-local.
    # shellcheck source=/dev/null
    source "$here/../agentkit/skills/.shared/scripts/lib/review-attempt.sh"
    REVIEW_ATTEMPT_ENTRY="$entry" AGENTKIT_REVIEW_ATTEMPT_ID="$id" REVIEW_ATTEMPT_STARTED=0
    cmd_attempt() { touch "$tmp/unowned-finalization"; }
    review_cleanup() { :; }
    review_attempt_cleanup
)
assert_eq no "$([[ -e $tmp/unowned-finalization ]] && printf yes || printf no)" \
    'a helper that failed to claim an attempt cannot finalize another invocation'
for state in parser-rejected failed; do
    jq '.pr += 1' "$entry" >"$tmp/change"
    mv "$tmp/change" "$entry"
    record=$(attempt reserve)
    state_id=$(jq -r '.id' <<<"$record")
    assert_rc 0 "$state is recorded distinctly" -- attempt finish --id "$state_id" --state "$state"
    record=$(attempt read)
    assert_eq "$state" "$(jq -r '.state' <<<"$record")" "$state remains observable on resume"
    assert_rc 20 "$state does not silently reset budget" -- attempt reserve
done
record=$(attempt read)
assert_rc 1 'failed provider outcome cannot recover an unsent preparation' -- attempt recover --id "$(jq -r '.id' <<<"$record")"
jq '.pr += 1' "$entry" >"$tmp/change"
mv "$tmp/change" "$entry"
record=$(attempt reserve)
unsent_id=$(jq -r '.id' <<<"$record")
assert_rc 0 'preparation can attach before failing preflight' -- attempt attach --id "$unsent_id" --pid "$$"
assert_rc 0 'owned pre-provider rejection is terminal evidence of no send' -- attempt finish --id "$unsent_id" --pid "$$" --state parser-rejected
assert_rc 0 'the same obligation can recover a proven unsent preparation' -- attempt recover --id "$unsent_id"
record=$(attempt read)
assert_eq "$unsent_id" "$(jq -r '.id' <<<"$record")" 'unsent recovery retains the original attempt ID'
assert_eq 1 "$(jq '.preparations | length' <<<"$record")" 'unsent recovery retains preparation history'
assert_rc 1 'stale helper cannot finalize the recovered reservation before its new attachment' -- attempt finish --id "$unsent_id" --pid "$$" --state parser-rejected
assert_rc 0 'recovered preparation claims its only provider invocation' -- attempt start --id "$unsent_id" --pid "$$"
assert_rc 1 'a started invocation cannot be mislabeled as pre-provider rejection' -- attempt finish --id "$unsent_id" --pid "$$" --state parser-rejected
assert_rc 1 'a started invocation cannot recover another send' -- attempt recover --id "$unsent_id"

# A reader holding the short registry lock must not break lifecycle updates.
lock_path="$tmp/repo/.git/agentkit-review-attempts/$(printf 'acme/widget:%s' "$(jq -r '.pr' "$entry")" | sha256sum | cut -d' ' -f1).lock"
python3 - "$lock_path" "$tmp/locked" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(0.4)
PY
holder=$!
for _ in {1..100}; do [[ -e $tmp/locked ]] && break; sleep 0.01; done
assert_rc 0 'transient inspection lock contention does not lose process registration' -- attempt process --id "$unsent_id" --pid "$$"
wait "$holder"
assert_rc 0 'a sent attempt records unknown outcome' -- attempt finish --id "$unsent_id" --pid "$$" --state unknown-outcome
assert_rc 1 'unknown actual-send outcome cannot recover' -- attempt recover --id "$unsent_id"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 2' >"$CODEX_HOME/config.toml"
jq '.pr=99 | .result=$result' --arg result "$tmp/unknown-capacity-result.json" "$entry" >"$tmp/unknown-capacity-entry.json"
assert_rc 1 'unknown review outcome conservatively retains shared capacity' -- \
    "$script" attempt reserve --repo-root "$tmp/repo" --entry-file "$tmp/unknown-capacity-entry.json"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 10' >"$CODEX_HOME/config.toml"
before_timeout=$(attempt read)
rm "$tmp/locked"
python3 - "$lock_path" "$tmp/locked" <<'PY' &
import fcntl, pathlib, sys, time
with open(sys.argv[1], 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    time.sleep(3)
PY
holder=$!
for _ in {1..100}; do [[ -e $tmp/locked ]] && break; sleep 0.01; done
lock_rc=0
timeout 4 "$script" attempt read --repo-root "$tmp/repo" --entry-file "$entry" >"$tmp/lock.out" 2>"$tmp/lock.err" || lock_rc=$?
assert_eq 1 "$lock_rc" 'long lock contention fails within a bounded acquisition window'
assert_contains "$(cat "$tmp/lock.err")" 'outcome unknown' 'lock timeout reports unavailable evidence explicitly'
wait "$holder"
assert_eq "$before_timeout" "$(attempt read)" 'lock timeout never mutates or finalizes the attempt'

# #903: reviewer attempts and native workers share one atomic capacity claim.
# Hold real durable reservations for separate PRs, then race the final review
# slot against a native worker reservation.
capacity_repo="$tmp/capacity-repo"
git init -q -b main "$capacity_repo"
git -C "$capacity_repo" config user.email test@example.invalid
git -C "$capacity_repo" config user.name test
printf '%s\n' base >"$capacity_repo/README.md"
git -C "$capacity_repo" add README.md
git -C "$capacity_repo" commit -qm base
capacity_ledger="$capacity_repo/.agent/runs/active-workers.ndjson"
attempt_dir=$(git -C "$capacity_repo" rev-parse --path-format=absolute --git-common-dir)/agentkit-review-attempts
mkdir -p "$capacity_repo/.agent/runs" "$tmp/capacity-worker" "$tmp/stale-worker"
printf '%s\n' \
    '{"version":1,"issue":90,"worktree":"/old-worker","branch":"old","state":"active","heartbeatEpoch":1}' \
    "{\"version\":2,\"issue\":90,\"worktree\":\"$tmp/stale-worker\",\"branch\":\"old\",\"runId\":\"old\",\"attempt\":\"stale\",\"workerId\":\"old-worker\",\"state\":\"active\",\"disposition\":\"returned\",\"evidence\":\"\",\"heartbeatEpoch\":1}" \
    '{"version":2,"issue":91,"worktree":"/finished-worker","branch":"old","runId":"old","attempt":"old","workerId":"done","state":"terminal","disposition":"completed","evidence":"receipt","heartbeatEpoch":2}' \
    >"$capacity_ledger"
chmod 600 "$capacity_ledger"
capacity_helper="$here/../agentkit/skills/parallel-issues/scripts/named-active-state.sh"
capacity_entry() {
    local pr=$1 path=$2 run_id=${3:-}
    jq -n --argjson pr "$pr" --arg result "$tmp/result-$pr.json" --arg launcher "$script" --arg run_id "$run_id" \
        '{repo:"acme/capacity",pr:$pr,head:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
          base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",payload:("digest-"+($pr|tostring)),
          provider:"anthropic",model:"claude-opus-5",effort:"high",launcher:$launcher,
          launcherPid:1,result:$result} +
          (if $run_id == "" then {} else {runId:$run_id} end)' >"$path"
}
capacity_attempt() {
    local entry_file=$1 operation=$2
    shift 2
    "$script" attempt "$operation" --repo-root "$capacity_repo" --entry-file "$entry_file" "$@"
}

# No parallel run context means old native-run rows are unrelated. Outstanding
# review attempts still count separately in every launch context.
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 2' >"$CODEX_HOME/config.toml"
capacity_entry 99 "$tmp/capacity-99.json"
standalone_capacity=$(capacity_attempt "$tmp/capacity-99.json" reserve)
assert_eq reserved "$(jq -r .state <<<"$standalone_capacity")" \
    'standalone review ignores unrelated stale native-run ownership'
assert_rc 0 'standalone review releases normally' -- capacity_attempt "$tmp/capacity-99.json" finish \
    --id "$(jq -r .id <<<"$standalone_capacity")" --state failed

# Remove old rows before exercising named-active-state itself: its durable
# ownership contract intentionally requires explicit reconciliation across runs.
printf '%s\n' \
    '{"version":1,"issue":90,"worktree":"/old-worker","branch":"old","state":"active","heartbeatEpoch":1}' \
    '{"version":2,"issue":91,"worktree":"/finished-worker","branch":"old","runId":"old","attempt":"old","workerId":"done","state":"terminal","disposition":"completed","evidence":"receipt","heartbeatEpoch":2}' \
    >"$capacity_ledger"
chmod 600 "$capacity_ledger"

# An outstanding native reservation must be visible to a review invocation
# carrying the same parallel run. Refusal happens before a durable identity.
mkdir -p "$tmp/capacity-blocker"
printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 2' >"$CODEX_HOME/config.toml"
"$capacity_helper" --repo-root "$capacity_repo" --ledger "$capacity_ledger" --action reserve \
    --issue 500 --worktree "$tmp/capacity-blocker" --branch fix/blocker --run-id capacity \
    --attempt worker-blocker >/dev/null
capacity_entry 100 "$tmp/capacity-100.json" capacity
before_capacity_refusal=$(find "$attempt_dir" -maxdepth 1 -name '*.json' -type f | wc -l)
assert_rc 1 'active parallel-issues reservation blocks a review that would exceed the shared cap' -- \
    capacity_attempt "$tmp/capacity-100.json" reserve
assert_eq "$before_capacity_refusal" "$(find "$attempt_dir" -maxdepth 1 -name '*.json' -type f | wc -l)" \
    'capacity refusal creates no review identity that could later be sent'
"$capacity_helper" --repo-root "$capacity_repo" --ledger "$capacity_ledger" --action release \
    --attempt worker-blocker --disposition rejected --evidence 'worker was not launched' >/dev/null

printf '%s\n' '[agents]' 'max_concurrent_threads_per_session = 3' >"$CODEX_HOME/config.toml"
capacity_entry 101 "$tmp/capacity-101.json" capacity
capacity_entry 102 "$tmp/capacity-102.json" capacity
capacity_entry 103 "$tmp/capacity-103.json" capacity
first_capacity=$(capacity_attempt "$tmp/capacity-101.json" reserve)
second_capacity=$(capacity_attempt "$tmp/capacity-102.json" reserve)
assert_eq reserved "$(jq -r .state <<<"$first_capacity")" \
    'first distinct reviewer reserves shared capacity'
assert_eq reserved "$(jq -r .state <<<"$second_capacity")" \
    'second distinct reviewer overlaps before either finishes'
assert_eq yes "$([[ $(jq -r .id <<<"$first_capacity") != "$(jq -r .id <<<"$second_capacity")" ]] && printf yes || printf no)" \
    'overlapping reviewers retain distinct durable identities despite old inactive worker rows'
assert_rc 0 'first reviewer enters running state' -- capacity_attempt "$tmp/capacity-101.json" start \
    --id "$(jq -r .id <<<"$first_capacity")" --pid "$$"
assert_rc 0 'second reviewer enters running state' -- capacity_attempt "$tmp/capacity-102.json" start \
    --id "$(jq -r .id <<<"$second_capacity")" --pid "$$"
assert_rc 1 'overflow reviewer is refused before it can reserve or send' -- \
    capacity_attempt "$tmp/capacity-103.json" reserve
assert_rc 0 'completed reviewer releases one slot' -- capacity_attempt "$tmp/capacity-101.json" finish \
    --id "$(jq -r .id <<<"$first_capacity")" --pid "$$" --state failed
third_capacity=$(capacity_attempt "$tmp/capacity-103.json" reserve)
assert_eq reserved "$(jq -r .state <<<"$third_capacity")" \
    'queued reviewer refills released capacity'

# One remaining reviewer leaves one slot at cap=3. A native worker reserve and
# another PR review race for it; the shared lock must admit exactly one.
# Native admission holds ledger->capacity; reviewer admission holds
# per-PR->capacity and reads only the ledger's atomic-replace snapshot, so no
# reverse capacity->ledger-lock edge exists.
assert_rc 0 'second reviewer releases before the mixed admission race' -- \
    capacity_attempt "$tmp/capacity-102.json" finish --id "$(jq -r .id <<<"$second_capacity")" \
    --pid "$$" --state failed
capacity_entry 104 "$tmp/capacity-104.json" capacity
capacity_attempt "$tmp/capacity-104.json" reserve >"$tmp/review-race.out" 2>"$tmp/review-race.err" &
review_race_pid=$!
"$capacity_helper" --repo-root "$capacity_repo" --ledger "$capacity_ledger" --action reserve \
    --issue 501 --worktree "$tmp/capacity-worker" --branch fix/capacity --run-id capacity \
    --attempt worker-race >"$tmp/worker-race.out" 2>"$tmp/worker-race.err" &
worker_race_pid=$!
mixed_winners=0
wait "$review_race_pid" && mixed_winners=$((mixed_winners + 1))
wait "$worker_race_pid" && mixed_winners=$((mixed_winners + 1))
assert_eq 1 "$mixed_winners" \
    'review and native reservations cannot both claim the same final slot'
finish
