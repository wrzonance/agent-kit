#!/usr/bin/env bash
# Boundary coverage for detached adversarial-review liveness classification.
set -uo pipefail

TEST_NAME='review-liveness'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/review-liveness.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

run_dir="$tmp/run"
mkdir -- "$run_dir"
chmod 700 "$run_dir"
transcript="$run_dir/claude.ndjson"
status="$transcript.status"
result="$run_dir/adversarial.result.json"
sample="$run_dir/.review-liveness.state"
custom_result="$run_dir/custom.result.json"

LAST_RC=0
LAST_OUTPUT=''

reset_case() {
    rm -f -- "$status" "$result" "$sample" "$custom_result"
    : >"$transcript"
}

invoke() {
    local now=$1
    shift
    local output="$tmp/output" error="$tmp/error"
    LAST_RC=0
    "$script" --run-dir "$run_dir" --transcript "$transcript" \
        --poll-seconds 10 --now-epoch "$now" "$@" >"$output" 2>"$error" || LAST_RC=$?
    LAST_OUTPUT=$(cat -- "$output")
}

write_status() {
    printf '{"status":"running","wallClockEpoch":%s}\n' "$1" >"$status"
}

write_documented_status() {
    printf '{"elapsedSeconds":1,"transcriptBytes":0,"eventCount":0,"wallClockEpoch":%s}\n' "$1" >"$status"
}

write_result() {
    printf '%s\n' "$1" >"$result"
}

assert_state() {
    local want_rc=$1 want_state=$2 label=$3
    assert_eq "$want_rc" "$LAST_RC" "$label exit state"
    assert_eq "$want_state" "$LAST_OUTPUT" "$label output state"
}

reset_case
invoke 1000
assert_state 1 'Still running' 'first sample waits for a second sample'
invoke 1005
assert_state 1 'Still running' 'samples less than one poll apart cannot block'
invoke 1011
assert_state 2 Blocked 'stale heartbeat and two unchanged samples block'
invoke 1012
assert_state 2 Blocked 'blocked state remains blocked without new evidence'

reset_case
write_status 2000
invoke 2000
assert_state 1 'Still running' 'fresh heartbeat keeps the first sample alive'
invoke 2005
assert_state 1 'Still running' 'fresh heartbeat keeps an unchanged transcript alive'
invoke 2021
assert_state 2 Blocked 'a stale heartbeat blocks after the required interval'

# --- a heartbeat from the future is corruption, not freshness --------------
# now_epoch - wallClockEpoch goes negative when the stamp is ahead of now, and a
# negative age satisfies `age <= 2 * poll_seconds`. That held the verdict at
# "Still running" for as long as the local clock trailed the stamp, no matter how
# long the transcript had been unchanged -- a liveness check that cannot observe
# a dead reviewer.
reset_case
write_status 9000
invoke 3000
assert_state 1 'Still running' 'a future heartbeat still waits for a second sample'
invoke 3011
assert_state 2 Blocked 'a future heartbeat does not keep an unchanged transcript alive'

reset_case
write_documented_status 2100
invoke 2100
assert_state 1 'Still running' 'documented heartbeat shape keeps the first sample alive'
invoke 2111
assert_state 1 'Still running' 'documented heartbeat shape keeps an unchanged transcript alive'

reset_case
invoke 3000
printf '%s\n' '{"event":"progress"}' >>"$transcript"
invoke 3010
assert_state 1 'Still running' 'transcript growth keeps a stale review alive'
invoke 3020
assert_state 2 Blocked 'growth must be followed by a second unchanged sample'

reset_case
write_result '{"status":"completed","exitCode":0,"requestedModel":"claude-opus-5","transcript":"claude.ndjson","verdict":{"verdict":"no_findings","findings":[]}}'
invoke 4000
assert_state 0 Completed 'validated result completes without launcher state'

reset_case
printf '%s\n' '{"status":"completed","exitCode":0,"requestedModel":"claude-opus-5","transcript":"claude.ndjson","verdict":{"verdict":"no_findings","findings":[]}}' >"$custom_result"
invoke 4500 --verdict "$custom_result"
assert_state 0 Completed 'custom verdict path completes when explicitly selected'

reset_case
write_result '{"status":"completed","exitCode":0,"requestedModel":"claude-opus-5","transcript":"claude.ndjson","verdict":{"verdict":"no_findings","findings":[]}}'
invoke 5000 --launcher-state running
assert_state 1 'Still running' 'running launcher state does not consume a verdict'
invoke 5010 --launcher-state completed
assert_state 0 Completed 'terminal launcher plus validated result completes'

reset_case
write_result '{"status":"blocked","blockedReason":"environment-blocked","provider":"anthropic","requestedModel":"claude-opus-5","effort":"high","mode":"cross-provider"}'
invoke 6000
assert_state 0 Completed 'validated blocked result is terminal evidence'

reset_case
write_result '{"status":"completed","exitCode":0}'
invoke 7000
invoke 7010
assert_state 2 Blocked 'malformed result never becomes Completed'

reset_case
invoke 8000
printf '%s\n' '{"event":"progress"}' >>"$transcript"
invoke 8010
: >"$transcript"
invoke 8020
assert_state 1 'Still running' 'transcript shrink resets samples for a relaunch'

outside="$tmp/outside.ndjson"
: >"$outside"
ln -s "$outside" "$run_dir/symlink.ndjson"
symlink_rc=0
"$script" --run-dir "$run_dir" --transcript "$run_dir/symlink.ndjson" \
    --poll-seconds 10 --now-epoch 8000 >"$tmp/symlink.out" 2>"$tmp/symlink.err" ||
    symlink_rc=$?
assert_eq 3 "$symlink_rc" 'transcript symlinks are rejected'
assert_contains "$(cat -- "$tmp/symlink.err")" 'symlink' \
    'transcript symlink rejection is explicit'

usage_rc=0
"$script" --run-dir "$run_dir" --transcript "$transcript" --unknown-option \
    >"$tmp/usage.out" 2>"$tmp/usage.err" || usage_rc=$?
assert_eq 3 "$usage_rc" 'usage errors have a distinct exit status'

assert_not_contains "$(cat -- "$script" 2>/dev/null || true)" 'kill -0' \
    'liveness classification never probes producer PIDs'
assert_contains "$(cat -- "$script" 2>/dev/null || true)" '2 * poll_seconds' \
    'liveness classification pins the heartbeat freshness window'

finish
