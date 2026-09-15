#!/usr/bin/env bash
set -uo pipefail
TEST_NAME='adversarial durable attempts'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/lib/assert.sh"
script="$here/../agentkit/skills/review-remote-pr/scripts/review-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
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
assert_rc 0 'uncertain completion is retained' -- attempt finish --id "$id" --state unknown-outcome
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
finish
