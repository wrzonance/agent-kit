#!/usr/bin/env bash
# Boundary coverage for the adversarial finding disposition ledger.
set -uo pipefail

TEST_NAME='finding ledger'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"

script="$root/agentkit/skills/review-remote-pr/scripts/finding-ledger.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

run_dir="$tmp/run"
mkdir -- "$run_dir"
chmod 700 -- "$run_dir"

run_ledger() {
    RUN_DIR="$run_dir" "$script" "$@"
}

run_ledger_at() {
    local dir=$1
    shift
    RUN_DIR="$dir" "$script" "$@"
}

# A disposition cannot be recorded until the one-shot adversarial runner has
# published a validated completed result. This pins consent -> runner -> ledger
# ordering at an executable boundary rather than in prose.
before_rc=0
run_ledger add --title 'Too early' --verdict fixed --sha abc1234 \
    >/dev/null 2>"$tmp/before.err" || before_rc=$?
assert_eq '13' "$before_rc" 'ledger refuses a disposition before a completed review result'
assert_eq 'no' "$([[ -e $run_dir/findings.ndjson ]] && printf yes || printf no)" \
    'order refusal does not create a findings ledger'
assert_contains "$(cat -- "$tmp/before.err")" 'adversarial.result.json' \
    'order refusal names the missing review result'

jq -cn '{status:"completed", exitCode:0, requestedModel:"review-model",
    transcript:"review.ndjson", verdict:{verdict:"findings", findings:[]}}' \
    >"$run_dir/adversarial.result.json"
chmod 600 -- "$run_dir/adversarial.result.json"

setgid_run="$tmp/setgid-run"
mkdir -- "$setgid_run"
chmod 2700 -- "$setgid_run"
cp -- "$run_dir/adversarial.result.json" "$setgid_run/adversarial.result.json"
chmod 600 -- "$setgid_run/adversarial.result.json"
assert_rc 0 'owner-private setgid directories remain valid run directories' -- \
    run_ledger_at "$setgid_run" add --title 'Setgid mode' --verdict fixed --sha abc1234

multi_result_run="$tmp/multi-result-run"
mkdir -- "$multi_result_run"
chmod 700 -- "$multi_result_run"
printf '%s\n' '{"status":"running"}' >"$multi_result_run/adversarial.result.json"
jq -cn '{status:"completed", exitCode:0, verdict:{verdict:"findings", findings:[]}}' \
    >>"$multi_result_run/adversarial.result.json"
chmod 600 -- "$multi_result_run/adversarial.result.json"
multi_result_rc=0
run_ledger_at "$multi_result_run" add --title 'Multiple results' --verdict fixed \
    --sha abc1234 >/dev/null 2>"$tmp/multi-result.err" || multi_result_rc=$?
assert_eq '13' "$multi_result_rc" \
    'multiple result documents are rejected before recording a disposition'
assert_eq 'no' "$( [[ -e $multi_result_run/findings.ndjson ]] && printf yes || printf no )" \
    'multiple result rejection does not create a findings ledger'

assert_rc 0 'a fixed finding is appended' -- run_ledger add \
    --title 'R&D failure' --verdict fixed --sha abc1234
assert_rc 0 'a declined finding is appended' -- run_ledger add \
    --title 'Debatable naming' --verdict declined \
    --rationale 'style preference, no behavior change'

assert_eq '2' "$(wc -l <"$run_dir/findings.ndjson" | tr -d ' ')" \
    'each accepted disposition appends one NDJSON record'
assert_eq '2' "$(jq -s 'length' <"$run_dir/findings.ndjson")" \
    'the ledger contains two JSON records'
assert_eq 'R&D failure' "$(jq -r -s '.[0].title' <"$run_dir/findings.ndjson")" \
    'the ledger preserves the fixed title'
assert_eq 'abc1234' "$(jq -r -s '.[0].sha' <"$run_dir/findings.ndjson")" \
    'the ledger preserves the fixed SHA'
assert_eq 'declined' "$(jq -r -s '.[1].verdict' <"$run_dir/findings.ndjson")" \
    'the ledger preserves the declined verdict'
assert_eq 'style preference, no behavior change' \
    "$(jq -r -s '.[1].rationale' <"$run_dir/findings.ndjson")" \
    'the ledger preserves the decline rationale'
assert_eq '600' "$(stat -c '%a' "$run_dir/findings.ndjson")" \
    'the findings ledger is owner-private'

bad_rc=0
run_ledger add --title 'Both details' --verdict fixed --sha abc1234 \
    --rationale 'not allowed' >/dev/null 2>"$tmp/bad.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'a disposition cannot carry both a SHA and rationale'
assert_contains "$(cat -- "$tmp/bad.err")" 'exactly one' \
    'the two-detail rejection explains the contract'

bad_rc=0
run_ledger add --title $'line\nbreak' --verdict fixed --sha abc1234 \
    >/dev/null 2>"$tmp/newline.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'line breaks are rejected from ledger titles'
assert_contains "$(cat -- "$tmp/newline.err")" 'line break' \
    'the title validation names the unsafe line break'

bad_rc=0
run_ledger add --title 'Bad SHA' --verdict fixed --sha not-a-sha \
    >/dev/null 2>"$tmp/sha.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'non-hex commit identifiers are rejected'
assert_contains "$(cat -- "$tmp/sha.err")" 'SHA' \
    'the SHA validation names the invalid field'

finish
