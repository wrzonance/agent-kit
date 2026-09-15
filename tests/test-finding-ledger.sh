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
run_ledger add --title 'Too early' --severity P1 --verdict fixed --sha abc1234 \
    >/dev/null 2>"$tmp/before.err" || before_rc=$?
assert_eq '13' "$before_rc" 'ledger refuses a disposition before a completed review result'
assert_eq 'no' "$([[ -e $run_dir/findings.ndjson ]] && printf yes || printf no)" \
    'order refusal does not create a findings ledger'
assert_contains "$(cat -- "$tmp/before.err")" 'adversarial.result.json' \
    'order refusal names the missing review result'

jq -cn '{status:"completed", exitCode:0, requestedModel:"review-model",
    transcript:"review.ndjson", verdict:{verdict:"findings", findings:[
        {priority:"P1", location:"src/a.sh:1", failureScenario:"breaks",
         smallestFix:"repair"}]}}' \
    >"$run_dir/adversarial.result.json"
chmod 600 -- "$run_dir/adversarial.result.json"

setgid_run="$tmp/setgid-run"
mkdir -- "$setgid_run"
chmod 2700 -- "$setgid_run"
cp -- "$run_dir/adversarial.result.json" "$setgid_run/adversarial.result.json"
chmod 600 -- "$setgid_run/adversarial.result.json"
assert_rc 0 'owner-private setgid directories remain valid run directories' -- \
    run_ledger_at "$setgid_run" add --title 'Setgid mode' --severity P1 --verdict fixed --sha abc1234

multi_result_run="$tmp/multi-result-run"
mkdir -- "$multi_result_run"
chmod 700 -- "$multi_result_run"
printf '%s\n' '{"status":"running"}' >"$multi_result_run/adversarial.result.json"
jq -cn '{status:"completed", exitCode:0, verdict:{verdict:"findings", findings:[]}}' \
    >>"$multi_result_run/adversarial.result.json"
chmod 600 -- "$multi_result_run/adversarial.result.json"
multi_result_rc=0
run_ledger_at "$multi_result_run" add --title 'Multiple results' --severity P1 --verdict fixed \
    --sha abc1234 >/dev/null 2>"$tmp/multi-result.err" || multi_result_rc=$?
assert_eq '13' "$multi_result_rc" \
    'multiple result documents are rejected before recording a disposition'
assert_eq 'no' "$( [[ -e $multi_result_run/findings.ndjson ]] && printf yes || printf no )" \
    'multiple result rejection does not create a findings ledger'

assert_rc 0 'a fixed finding is appended' -- run_ledger add \
    --title 'R&D failure' --severity P1 --verdict fixed --sha abc1234
assert_rc 0 'a declined finding is appended' -- run_ledger add \
    --title 'Debatable naming' --severity P2 --verdict declined \
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
file_mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1" 2>/dev/null; }
assert_eq '600' "$(file_mode "$run_dir/findings.ndjson")" \
    'the findings ledger is owner-private'

bad_rc=0
run_ledger add --title 'Both details' --severity P1 --verdict fixed --sha abc1234 \
    --rationale 'not allowed' >/dev/null 2>"$tmp/bad.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'a disposition cannot carry both a SHA and rationale'
assert_contains "$(cat -- "$tmp/bad.err")" 'exactly one' \
    'the two-detail rejection explains the contract'

bad_rc=0
run_ledger add --title $'line\nbreak' --severity P1 --verdict fixed --sha abc1234 \
    >/dev/null 2>"$tmp/newline.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'line breaks are rejected from ledger titles'
assert_contains "$(cat -- "$tmp/newline.err")" 'line break' \
    'the title validation names the unsafe line break'

bad_rc=0
run_ledger add --title 'Bad SHA' --severity P1 --verdict fixed --sha not-a-sha \
    >/dev/null 2>"$tmp/sha.err" || bad_rc=$?
assert_eq '2' "$bad_rc" 'non-hex commit identifiers are rejected'
assert_contains "$(cat -- "$tmp/sha.err")" 'SHA' \
    'the SHA validation names the invalid field'



# --- security-relevant refusals ---------------------------------------------
# Each of these branches guards an artifact an attacker or a careless refactor
# could subvert, and none of them had a test: a refactor could drop any one and
# the suite would stay green.

# A symlinked ledger would let an append escape the run directory entirely.
symlink_run="$tmp/symlink-run"
mkdir -- "$symlink_run"; chmod 700 -- "$symlink_run"
cp -- "$run_dir/adversarial.result.json" "$symlink_run/adversarial.result.json"
chmod 600 -- "$symlink_run/adversarial.result.json"
ln -s "$tmp/elsewhere.ndjson" "$symlink_run/findings.ndjson"
symlink_rc=0
run_ledger_at "$symlink_run" add --title 'Symlinked ledger' --severity P1 --verdict fixed --sha abc1234 \
    >"$tmp/symlink.out" 2>"$tmp/symlink.err" || symlink_rc=$?
assert_eq 1 "$symlink_rc" 'a symlinked findings ledger is refused'
assert_eq no "$( [[ -e $tmp/elsewhere.ndjson ]] && printf yes || printf no )" \
    'the refusal never writes through the symlink'

# A world- or group-readable run directory leaks review content.
open_run="$tmp/open-run"
mkdir -- "$open_run"; chmod 755 -- "$open_run"
cp -- "$run_dir/adversarial.result.json" "$open_run/adversarial.result.json"
chmod 600 -- "$open_run/adversarial.result.json"
open_rc=0
run_ledger_at "$open_run" add --title 'Open run dir' --severity P1 --verdict fixed --sha abc1234 \
    >"$tmp/open.out" 2>"$tmp/open.err" || open_rc=$?
assert_eq 1 "$open_rc" 'a run directory that is not owner-private is refused'

# An existing ledger holding a malformed record must not be appended to.
invalid_ledger_run="$tmp/invalid-ledger-run"
mkdir -- "$invalid_ledger_run"; chmod 700 -- "$invalid_ledger_run"
cp -- "$run_dir/adversarial.result.json" "$invalid_ledger_run/adversarial.result.json"
chmod 600 -- "$invalid_ledger_run/adversarial.result.json"
printf '%s\n' '{"title":"broken"}' >"$invalid_ledger_run/findings.ndjson"
chmod 600 -- "$invalid_ledger_run/findings.ndjson"
invalid_ledger_rc=0
run_ledger_at "$invalid_ledger_run" add --title 'Onto invalid' --severity P1 --verdict fixed --sha abc1234 \
    >"$tmp/invalid-ledger.out" 2>"$tmp/invalid-ledger.err" || invalid_ledger_rc=$?
assert_eq 1 "$invalid_ledger_rc" 'an existing ledger with an invalid record is refused'
assert_eq 1 "$(wc -l <"$invalid_ledger_run/findings.ndjson")" \
    'the refusal appends nothing to the invalid ledger'

# The verdict and its evidence must agree: a fix needs a SHA, a decline a reason.
mismatch_rc=0
run_ledger add --title 'Fixed with rationale' --severity P1 --verdict fixed --rationale 'no sha here' \
    >"$tmp/mismatch1.out" 2>"$tmp/mismatch1.err" || mismatch_rc=$?
assert_eq 2 "$mismatch_rc" 'a fixed verdict cannot be evidenced by a rationale'
assert_contains "$(cat -- "$tmp/mismatch1.err")" 'fixed findings require --sha' \
    'the mismatch refusal names the missing SHA, not some earlier gate'
mismatch2_rc=0
run_ledger add --title 'Declined with sha' --severity P2 --verdict declined --sha abc1234 \
    >"$tmp/mismatch2.out" 2>"$tmp/mismatch2.err" || mismatch2_rc=$?
assert_eq 2 "$mismatch2_rc" 'a declined verdict cannot be evidenced by a SHA'
assert_contains "$(cat -- "$tmp/mismatch2.err")" 'declined findings require --rationale' \
    'the mismatch refusal names the missing rationale, not some earlier gate'

# Confirmed findings remain actionable while execution evidence is retained.
open_run="$tmp/open-findings"
mkdir -m 700 "$open_run"
cp "$run_dir/adversarial.result.json" "$open_run/adversarial.result.json"
for n in {1..8}; do
    assert_rc 0 "confirmed finding $n stays open" -- run_ledger_at "$open_run" add \
        --title "confirmed-$n" --severity P1 --verdict open --rationale 'repair required'
done
open_state=$("$script" status --file "$open_run/findings.ndjson")
assert_eq 'incomplete' "$(jq -r .remediation <<<"$open_state")" 'eight open findings block completion'
assert_eq '8' "$(jq '.unresolved | length' <<<"$open_state")" 'status names all eight repair obligations'
assert_contains "$open_state" 'repair' 'status supplies next repair action'
assert_rc 2 'pending repair cannot become a terminal decline without adjudication' -- \
    run_ledger_at "$open_run" add --title confirmed-1 --severity P1 --verdict declined --rationale 'later'
legacy_state=$("$script" status --file "$run_dir/findings.ndjson")
assert_eq 'unknown' "$(jq -r .remediation <<<"$legacy_state")" 'legacy SHA and rationale are not resolution evidence'

repair_repo="$tmp/repair-repo"
git init -q "$repair_repo"
git -C "$repair_repo" config user.name Test
git -C "$repair_repo" config user.email test@example.invalid
printf 'broken\n' >"$repair_repo/affected.sh"
git -C "$repair_repo" add affected.sh
git -C "$repair_repo" commit -qm baseline
base_sha=$(git -C "$repair_repo" rev-parse HEAD)
printf 'repaired\n' >"$repair_repo/affected.sh"
git -C "$repair_repo" commit -qam repair
repair_sha=$(git -C "$repair_repo" rev-parse HEAD)
printf '=== agent-run tests/regression.sh\n=== agent-run exited rc=0 after 1s\n' >"$tmp/verification.log"
log_hash=$(sha256sum "$tmp/verification.log"); log_hash=${log_hash%% *}
for n in {1..8}; do
    jq -n --arg finding "confirmed-$n" --arg sha "$repair_sha" --arg log "$tmp/verification.log" --arg digest "$log_hash" \
        '{finding:$finding,repairSha:$sha,head:$sha,path:"affected.sh",command:"tests/regression.sh",status:"passed",log:$log,logSha256:$digest}' >"$tmp/repair.json"
    if [[ $n == 1 ]]; then
        assert_rc 1 'syntactic repair SHA cannot resolve a finding on an unrelated head' -- \
            run_ledger_at "$open_run" add --title confirmed-1 --severity P1 --verdict fixed \
            --sha "$repair_sha" --evidence "$tmp/repair.json" --repo-root "$repair_repo" --head "$base_sha"
    fi
    assert_rc 0 "reachable verified repair resolves finding $n" -- \
        run_ledger_at "$open_run" add --title "confirmed-$n" --severity P1 --verdict fixed \
        --sha "$repair_sha" --evidence "$tmp/repair.json" --repo-root "$repair_repo" --head "$repair_sha"
done
repaired=$("$script" status --file "$open_run/findings.ndjson" --repo-root "$repair_repo" --head "$repair_sha")
assert_eq complete "$(jq -r .remediation <<<"$repaired")" 'eight repairs resume to complete without another review'
assert_eq 8 "$(jq -s length "$open_run/findings.ndjson")" 'updates preserve eight findings rather than inflating counts'
assert_eq open "$(jq -sr '.[0].history[0].verdict' "$open_run/findings.ndjson")" 'repair retains original open disposition'
# A PATH containing only declared tools models macOS without GNU sha256sum.
portable_bin="$tmp/portable-bin"
mkdir "$portable_bin"
for tool in bash dirname jq git grep tail; do
    ln -s "$(command -v "$tool")" "$portable_bin/$tool"
done
ln -s "$(command -v shasum)" "$portable_bin/shasum"
portable_rc=0
portable_out=$(PATH="$portable_bin" "$script" status --file "$open_run/findings.ndjson" \
    --repo-root "$repair_repo" --head "$repair_sha" 2>&1) || portable_rc=$?
assert_eq 0 "$portable_rc" 'repair verification supports shasum without GNU sha256sum'
assert_contains "$portable_out" '"remediation":"complete"' 'portable digest independently verifies repair completion'
cp "$open_run/findings.ndjson" "$tmp/wrong-digest.ndjson"
jq -c '.evidence.logSha256=("0"*64)' "$tmp/wrong-digest.ndjson" >"$tmp/portable-tampered.ndjson"
portable_rc=0
portable_out=$(PATH="$portable_bin" "$script" status --file "$tmp/portable-tampered.ndjson" \
    --repo-root "$repair_repo" --head "$repair_sha" 2>&1) || portable_rc=$?
assert_eq 1 "$portable_rc" 'portable hashing still rejects mismatched verification bytes'
assert_contains "$portable_out" 'verification log digest mismatch' 'fallback preserves digest binding'
rm "$portable_bin/shasum"
portable_rc=0
portable_out=$(PATH="$portable_bin" "$script" status --file "$open_run/findings.ndjson" \
    --repo-root "$repair_repo" --head "$repair_sha" 2>&1) || portable_rc=$?
assert_eq 1 "$portable_rc" 'missing digest utilities fail as evidence errors'
assert_contains "$portable_out" 'verification log digest unavailable' 'missing digest capability has a named evidence refusal'
jq -c '.evidence.command="unrelated-command"' "$open_run/findings.ndjson" >"$tmp/wrong-command.ndjson"
assert_rc 1 'unrelated successful command cannot certify a repair' -- "$script" status \
    --file "$tmp/wrong-command.ndjson" --repo-root "$repair_repo" --head "$repair_sha"
printf 'regressed\n' >"$repair_repo/affected.sh"
git -C "$repair_repo" commit -qam regression
regressed_sha=$(git -C "$repair_repo" rev-parse HEAD)
assert_rc 1 'verification cannot survive later changes to the repaired path' -- "$script" status \
    --file "$open_run/findings.ndjson" --repo-root "$repair_repo" --head "$regressed_sha"
printf 'tampered\n' >>"$tmp/verification.log"
assert_rc 1 'changed verification bytes invalidate repair completion' -- "$script" status \
    --file "$open_run/findings.ndjson" --repo-root "$repair_repo" --head "$repair_sha"

decline_run="$tmp/decline"
mkdir -m 700 "$decline_run"
cp "$run_dir/adversarial.result.json" "$decline_run/adversarial.result.json"
jq -n '{finding:"false-positive",decision:"rejected",rationale:"boundary already validates input"}' >"$tmp/decline.json"
assert_rc 0 'reasoned rejection remains supported with adjudication evidence' -- \
    run_ledger_at "$decline_run" add --title false-positive --severity P2 --verdict declined \
    --rationale 'boundary already validates input' --evidence "$tmp/decline.json"
declined=$("$script" status --file "$decline_run/findings.ndjson")
assert_eq complete "$(jq -r .remediation <<<"$declined")" 'evidenced rejection is terminal'
jq -n '{finding:"accepted risk",decision:"accepted-risk",rationale:"authorized exception"}' >"$tmp/risk.json"
assert_rc 1 'accepted risk must cite explicit authorization evidence' -- \
    run_ledger_at "$decline_run" add --title 'accepted risk' --severity P2 --verdict declined \
    --rationale 'authorized exception' --evidence "$tmp/risk.json"
jq '.authorization="operator decision recorded in issue 727"' "$tmp/risk.json" >"$tmp/authorized-risk.json"
assert_rc 0 'an explicitly authorized risk remains supported' -- \
    run_ledger_at "$decline_run" add --title 'accepted risk' --severity P2 --verdict declined \
    --rationale 'authorized exception' --evidence "$tmp/authorized-risk.json"

finish
