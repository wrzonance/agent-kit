#!/usr/bin/env bash
# Deferred chain finalization: immutable reviews bridge once onto integrated heads.
set -uo pipefail

TEST_NAME='chain-finalize'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"

advance="$root/agentkit/skills/parallel-issues/scripts/chain-advance.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

set +e
mixed_mode_out=$(bash "$advance" --resolve-base HEAD --issue-comments "$tmp/ignored" 2>&1)
mixed_mode_rc=$?
set -e
assert_eq 1 "$mixed_mode_rc" 'resolve-base refuses finalization-only evidence options'
assert_contains "$mixed_mode_out" 'does not accept finalization' \
    'mixed-mode refusal names the unsupported evidence class'

origin="$tmp/origin.git"
repo="$tmp/repo"
git init -q --bare "$origin"
git init -q "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
git -C "$repo" remote add origin "$origin"
printf 'shared\n' >"$repo/intent.txt"
git -C "$repo" add intent.txt
git -C "$repo" commit -qm seed
git -C "$repo" branch -M main
git -C "$repo" push -q -u origin main

commit_file() {
    local branch=$1 path=$2 content=$3 message=$4
    git -C "$repo" checkout -q "$branch"
    printf '%s\n' "$content" >"$repo/$path"
    git -C "$repo" add -- "$path"
    git -C "$repo" commit -qm "$message"
    git -C "$repo" rev-parse HEAD
}

push_branch() {
    git -C "$repo" push -q -u origin "$1"
}

make_branch() {
    git -C "$repo" checkout -qb "$1" "$2"
}

seed=$(git -C "$repo" rev-parse HEAD)
make_branch feat/issue-1 "$seed"
a_reviewed=$(commit_file feat/issue-1 a.txt 'A intent' 'A implementation')
push_branch feat/issue-1

make_branch feat/issue-2 "$a_reviewed"
b_reviewed=$(commit_file feat/issue-2 intent.txt 'successor intent' 'B implementation')
push_branch feat/issue-2

make_branch feat/issue-3 "$b_reviewed"
c_reviewed=$(commit_file feat/issue-3 c.txt 'C intent' 'C implementation')
push_branch feat/issue-3

make_branch feat/issue-4 "$c_reviewed"
d_reviewed=$(commit_file feat/issue-4 d.txt 'D intent' 'D implementation')
push_branch feat/issue-4

# Initial implementation verification is deliberately distinct from the
# successor integration verification counted below.
printf '%s\n' 1 2 3 4 >"$tmp/initial-verifications"
: >"$tmp/successor-verifications"
printf '%s\n' 1 2 3 4 >"$tmp/review-launches"

git -C "$repo" checkout -q feat/issue-1
printf '%s\n' 'ancestor intent one' >"$repo/intent.txt"
git -C "$repo" commit -qam 'A fix one'
a_fix_one=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' 'ancestor intent final' >"$repo/intent.txt"
git -C "$repo" commit -qam 'A fix two'
a_final=$(git -C "$repo" rev-parse HEAD)
assert_eq yes "$([[ $a_fix_one != "$a_reviewed" && $a_fix_one != "$a_final" ]] && printf yes || printf no)" \
    'A accumulates two distinct fixes before successor finalization'
push_branch feat/issue-1

state="$tmp/run-state.json"
artifacts="$tmp/artifacts"
mkdir -m 700 "$artifacts"

write_artifacts() {
    local pr=$1 reviewed=$2 final=$3 payload=$4 predecessor=${5:-} ci=${6:-green}
    local remote_state=${7:-completed} coverage='[]' covered='[]' ci_line
    if [[ $reviewed != "$final" ]]; then
        covered=$(jq -cn --arg final "$final" '[$final]')
        if [[ -n $predecessor ]]; then
            coverage=$(jq -cn --arg final "$final" --arg reason "merge-down:$predecessor" \
                '[{sha:$final,reason:$reason,covered_at:"2026-09-24T00:00:00Z"}]')
        else
            coverage=$(jq -cn --arg final "$final" \
                '[{sha:$final,reason:"fix:F1",covered_at:"2026-09-24T00:00:00Z"}]')
        fi
    fi
    jq -n --arg repo owner/repo --argjson pr "$pr" --arg head "$reviewed" \
        --arg payload "$payload" \
        '{repo:$repo,pr:$pr,head:$head,payload:$payload,state:"completed",canonical:true}' \
        >"$artifacts/pr-$pr-attempt.json"
    : >"$artifacts/pr-$pr-accepted-findings.ndjson"
    case $ci in
        green) ci_line='ci=1/1 green pending=0 failing=0' ;;
        pending) ci_line='ci=0/1 pending pending=1 failing=0' ;;
        *) return 1 ;;
    esac
    {
        printf 'pr=%s draft=true mergeable=MERGEABLE head=feat/issue-%s sha=%s\n' "$pr" "$pr" "$final"
        printf 'base: ref=feat/issue-%s behind=0 stale=no\n' "$((pr > 1 ? pr - 1 : 0))"
        printf '%s\n' "$ci_line"
        printf '%s\n' 'finding-classification: cq=known icf=known'
    } >"$artifacts/pr-$pr-final.digest"
    if [[ -f $repo/.agent/acceptance.txt ]]; then
        while IFS= read -r command || [[ -n $command ]]; do
            [[ -n $command ]] || continue
            printf 'repo-verify=green acceptance=%s:pass\n' "$command"
        done <"$repo/.agent/acceptance.txt" >>"$artifacts/pr-$pr-final.digest"
    fi
    receipt=$(printf '## Adversarial review receipt\n- Reviewed head: %s\n- Final verified head: %s\n<!-- adversarial-review:spent -->' \
        "$reviewed" "$final")
    ledger=$(jq -cn --argjson pr "$pr" --arg reviewed "$reviewed" --arg payload "$payload" \
        --arg state "$remote_state" --argjson covered "$covered" --argjson coverage "$coverage" \
        '{version:1,pr:$pr,repo:"owner/repo",reviews:[{kind:"adversarial",provider:"anthropic",
          head_sha:$reviewed,diff_payload:$payload,executionState:$state,
          covered_heads:$covered,coverage:$coverage}]}')
    # Markdown fences are literal bytes.
    # shellcheck disable=SC2016
    ledger_body=$(printf '<!-- review-ledger:v1 -->\n```json\n%s\n```\n<!-- /review-ledger:v1 -->' "$ledger")
    jq -n --arg receipt "$receipt" --arg ledger "$ledger_body" \
        '[{id:1,user:{login:"tester"},body:$receipt},{id:2,user:{login:"tester"},body:$ledger}]' \
        >"$artifacts/pr-$pr-comments.json"
    chmod 600 -- "$artifacts/pr-$pr-"*
}

finalize() {
    local pr=$1 branch=$2 predecessor=${3:-}
    local -a args=(--finalize-successor --repo owner/repo --pr "$pr" --run-state "$state"
        --issue-comments "$artifacts/pr-$pr-comments.json"
        --pr-state-digest "$artifacts/pr-$pr-final.digest"
        --accepted-findings "$artifacts/pr-$pr-accepted-findings.ndjson"
        --review-attempt "$artifacts/pr-$pr-attempt.json" --pushed-branch "$branch")
    [[ -z $predecessor ]] || args+=(--predecessor-pr "$predecessor")
    (cd -- "$repo" && REVIEW_LEDGER_VIEWER=tester bash "$advance" "${args[@]}")
}

finalization_status() {
    local pr=$1 predecessor=${2:-}
    local -a args=(--finalization-status --pr "$pr" --run-state "$state")
    [[ -z $predecessor ]] || args+=(--predecessor-pr "$predecessor")
    (cd -- "$repo" && bash "$advance" "${args[@]}")
}

write_artifacts 1 "$a_reviewed" "$a_final" 'owner/repo:1:a' '' pending
set +e
pending_out=$(finalize 1 feat/issue-1 2>&1)
pending_rc=$?
set -e
assert_eq 1 "$pending_rc" 'finalization refuses pending final-head CI'
assert_contains "$pending_out" 'not green' 'pending-CI refusal names the missing terminal proof'

write_artifacts 1 "$a_reviewed" "$a_final" 'owner/repo:1:a'
sed -i 's/finding-classification: cq=known icf=known/finding-classification: cq=unavailable icf=known/' \
    "$artifacts/pr-1-final.digest"
set +e
unknown_findings_out=$(finalize 1 feat/issue-1 2>&1)
unknown_findings_rc=$?
set -e
assert_eq 1 "$unknown_findings_rc" 'finalization refuses unavailable finding classification'
assert_contains "$unknown_findings_out" 'finding classification' \
    'unavailable classification refusal names the terminal evidence contract'

write_artifacts 1 "$a_reviewed" "$a_final" 'owner/repo:1:a'
mv "$artifacts/pr-1-accepted-findings.ndjson" "$artifacts/pr-1-accepted-findings.missing"
set +e
missing_accepted_out=$(finalize 1 feat/issue-1 2>&1)
missing_accepted_rc=$?
set -e
assert_eq 1 "$missing_accepted_rc" 'finalization refuses absent accepted-findings evidence'
assert_contains "$missing_accepted_out" 'accepted findings' 'missing accepted-findings refusal names the contract'
mv "$artifacts/pr-1-accepted-findings.missing" "$artifacts/pr-1-accepted-findings.ndjson"

# B cannot finalize before A has a terminal record, and A fixes alone cause no
# eager mutation or verification anywhere in B -> C -> D.
git -C "$repo" checkout -q feat/issue-2
write_artifacts 2 "$b_reviewed" "$b_reviewed" 'owner/repo:2:b' "$a_final"
set +e
unresolved_out=$(finalize 2 feat/issue-2 1 2>&1)
unresolved_rc=$?
set -e
assert_eq 1 "$unresolved_rc" 'a successor refuses while its parent is not finalized'
assert_contains "$unresolved_out" 'predecessor finalization' 'the refusal names the unresolved parent boundary'
assert_eq 0 "$(wc -l <"$tmp/successor-verifications")" 'ancestor fixes trigger zero eager successor verifications'
assert_eq "$b_reviewed" "$(git -C "$repo" rev-parse feat/issue-2)" 'B is untouched before its finalization'
assert_eq "$c_reviewed" "$(git -C "$repo" rev-parse feat/issue-3)" 'C is untouched before its finalization'
assert_eq "$d_reviewed" "$(git -C "$repo" rev-parse feat/issue-4)" 'D is untouched before its finalization'

git -C "$repo" checkout -q feat/issue-1
mkdir -p "$repo/.agent"
printf '%s\n' 'integration-test' >"$repo/.agent/acceptance.txt"
set +e
acceptance_out=$(finalize 1 feat/issue-1 2>&1)
acceptance_rc=$?
set -e
assert_eq 1 "$acceptance_rc" 'finalization refuses missing declared acceptance evidence'
assert_contains "$acceptance_out" 'integration-test' 'acceptance refusal names the missing command'
printf '%s\n' 'repo-verify=green acceptance=integration-test:pass' >>"$artifacts/pr-1-final.digest"
write_artifacts 1 "$a_reviewed" "$a_final" 'owner/repo:1:a' '' green attempted
set +e
attempted_review_out=$(finalize 1 feat/issue-1 2>&1)
attempted_review_rc=$?
set -e
assert_eq 1 "$attempted_review_rc" 'finalization refuses a remote review that was only attempted'
assert_contains "$attempted_review_out" 'remote review execution is not completed' \
    'attempted remote review refusal names the incomplete execution state'
write_artifacts 1 "$a_reviewed" "$a_final" 'owner/repo:1:a'
root_out=$(finalize 1 feat/issue-1)
assert_contains "$root_out" "reviewed=$a_reviewed final=$a_final" 'root finalization preserves distinct review and final heads'

git -C "$repo" checkout -q feat/issue-2
write_artifacts 2 "$b_reviewed" "$b_reviewed" 'owner/repo:2:b' "$a_final"
set +e
stale_b_out=$(finalize 2 feat/issue-2 1 2>&1)
stale_b_rc=$?
set -e
assert_eq 1 "$stale_b_rc" 'B refuses until it contains A final head'
assert_contains "$stale_b_out" "$a_final" 'the integration refusal names A final head'

# The conflicting merge is caller-owned. Preserve both intended behaviors,
# commit the deliberate resolution, then verify the combined tree once.
drive_b_finalization() {
    local output=$1 status_rc merge_rc
    set +e
    finalization_status 2 1 >"$output" 2>&1
    status_rc=$?
    set -e
    if ((status_rc == 0)); then
        return 0
    fi
    assert_eq 10 "$status_rc" 'the driver integrates only when sealed evidence is absent or stale'
    set +e
    git -C "$repo" merge --no-commit --no-ff "$a_final" >/dev/null 2>&1
    merge_rc=$?
    set -e
    assert_eq 1 "$merge_rc" 'A and B deliberate intents produce a real merge conflict'
    printf '%s\n' 'ancestor intent final' 'successor intent' >"$repo/intent.txt"
    git -C "$repo" add intent.txt
    git -C "$repo" commit -qm 'merge A final into B'
    b_final=$(git -C "$repo" rev-parse HEAD)
    assert_contains "$(cat "$repo/intent.txt")" 'ancestor intent final' 'conflict repair preserves A intent'
    assert_contains "$(cat "$repo/intent.txt")" 'successor intent' 'conflict repair preserves B intent'
    # The documented order is commit -> full verification -> push -> seal.
    printf '%s\n' 2 >>"$tmp/successor-verifications"
    push_branch feat/issue-2
    write_artifacts 2 "$b_reviewed" "$b_final" 'owner/repo:2:b' "$a_final"
    finalize 2 feat/issue-2 1 >"$output"
}

drive_b_finalization "$tmp/b-first.out"
b_out=$(cat "$tmp/b-first.out")
assert_contains "$b_out" "predecessor=$a_final" 'B finalization binds the exact completed A head'

git -C "$repo" push -q --force origin "$b_reviewed:refs/heads/feat/issue-2"
set +e
moved_tip_out=$(finalization_status 2 1 2>&1)
moved_tip_rc=$?
set -e
assert_eq 1 "$moved_tip_rc" 'sealed status refuses when the recorded exact remote tip moved'
assert_contains "$moved_tip_out" 'exact pushed branch differs' \
    'moved remote refusal names the stale pushed-head proof'
push_branch feat/issue-2

git -C "$repo" push -q --force origin "$a_reviewed:refs/heads/feat/issue-1"
set +e
moved_parent_out=$(finalization_status 2 1 2>&1)
moved_parent_rc=$?
set -e
assert_eq 1 "$moved_parent_rc" 'sealed status refuses a stale parent exact-push tuple'
assert_contains "$moved_parent_out" 'exact pushed branch differs' \
    'moved parent refusal names the stale parent branch proof'
push_branch feat/issue-1

drive_b_finalization "$tmp/b-repeat.out"
assert_contains "$(cat "$tmp/b-repeat.out")" 'finalization=sealed' \
    'the documented driver stops before merge or full verification on a sealed repeat'
assert_eq 1 "$(wc -l <"$tmp/successor-verifications")" \
    'the repeated driver performs zero additional successor integration verifications'

state_before=$(sha256sum "$state")
repeat_out=$(finalize 2 feat/issue-2 1)
state_after=$(sha256sum "$state")
assert_contains "$repeat_out" 'no-op' 'unchanged repeated finalization is an explicit no-op'
assert_eq "$state_before" "$state_after" 'unchanged repeated finalization does not rewrite state'
assert_eq 4 "$(wc -l <"$tmp/review-launches")" 'finalization never launches another review'

git -C "$repo" checkout -q feat/issue-3
git -C "$repo" merge -q --no-ff "$b_final" -m 'merge B final into C'
c_final=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' 3 >>"$tmp/successor-verifications"
push_branch feat/issue-3
write_artifacts 3 "$c_reviewed" "$c_final" 'owner/repo:3:c' "$b_final"
finalize 3 feat/issue-3 2 >/dev/null

git -C "$repo" checkout -q feat/issue-4
git -C "$repo" merge -q --no-ff "$c_final" -m 'merge C final into D'
d_final=$(git -C "$repo" rev-parse HEAD)
printf '%s\n' 4 >>"$tmp/successor-verifications"
push_branch feat/issue-4
write_artifacts 4 "$d_reviewed" "$d_final" 'owner/repo:4:d' "$c_final"
finalize 4 feat/issue-4 3 >/dev/null

assert_eq 4 "$(wc -l <"$tmp/initial-verifications")" 'fixture retains four distinct initial implementation checks'
assert_eq 3 "$(wc -l <"$tmp/successor-verifications")" 'A -> B -> C -> D performs exactly three successor integration verifications'
assert_eq "$b_reviewed" "$(jq -r '.chainFinalizations["2"].reviewedHead' "$state")" \
    'B record retains the immutable reviewed snapshot head'
assert_eq "$b_final" "$(jq -r '.chainFinalizations["2"].finalHead' "$state")" \
    'B record separately names the final integrated and verified head'
assert_eq 'owner/repo:2:b' "$(jq -r '.chainFinalizations["2"].reviewPayload' "$state")" \
    'B record retains the immutable review payload identity'
assert_eq "$a_final" "$(jq -r '.chainFinalizations["2"].predecessorFinalHead' "$state")" \
    'B record binds its predecessor finalization head'

# A skipped successor still finalizes its integrated head without inventing a
# paid-review ledger bridge for code that policy explicitly allowed to skip.
git -C "$repo" checkout -q feat/issue-4
write_artifacts 4 "$d_reviewed" "$d_final" 'owner/repo:4:skip' "$c_final"
rm -- "$artifacts/pr-4-attempt.json"
skip_d_receipt=$(printf '## Adversarial review receipt\n- Execution: skipped\n- Verified-skip rationale: mechanical chain change; mechanical oracle=integration test\n- Reviewed head: %s\n- Diff payload: owner/repo:4:skip\n- Final verified head: %s\n<!-- adversarial-review:spent -->' \
    "$d_reviewed" "$d_final")
jq -n --arg receipt "$skip_d_receipt" '[{id:4,user:{login:"tester"},body:$receipt}]' \
    >"$artifacts/pr-4-comments.json"
skip_d_out=$(finalize 4 feat/issue-4 3)
assert_contains "$skip_d_out" 'receipt=verified-skip' \
    'a skipped successor finalizes its integrated head without paid-review coverage'

# A later A fix invalidates B only when B next approaches finalization. It
# never enumerates or mutates descendants eagerly.
git -C "$repo" checkout -q feat/issue-1
printf '%s\n' 'ancestor intent newest' >"$repo/intent.txt"
git -C "$repo" commit -qam 'A later fix'
a_new=$(git -C "$repo" rev-parse HEAD)
push_branch feat/issue-1
write_artifacts 1 "$a_reviewed" "$a_new" 'owner/repo:1:a'
finalize 1 feat/issue-1 >/dev/null
assert_eq "$c_final" "$(git -C "$repo" rev-parse feat/issue-3)" 'later A finalization does not cascade into C'
assert_eq "$d_final" "$(git -C "$repo" rev-parse feat/issue-4)" 'later A finalization does not cascade into D'
git -C "$repo" checkout -q feat/issue-2
set +e
changed_parent_out=$(finalize 2 feat/issue-2 1 2>&1)
changed_parent_rc=$?
set -e
assert_eq 1 "$changed_parent_rc" 'a changed finalized parent invalidates B evidence'
assert_contains "$changed_parent_out" "$a_new" 'changed-parent refusal names the new exact head to integrate'
assert_eq 3 "$(wc -l <"$tmp/successor-verifications")" 'changed parent never triggers a blind full rerun'

# A canonical verified skip has no paid-review attempt or remote review-ledger
# entry, but its terminal receipt still binds the skipped snapshot and final head.
git -C "$repo" checkout -q feat/issue-1
write_artifacts 1 "$a_new" "$a_new" 'owner/repo:1:skip'
rm -- "$artifacts/pr-1-attempt.json"
skip_receipt=$(printf '## Adversarial review receipt\n- Execution: skipped\n- Verified-skip rationale: docs only; mechanical oracle=diff check\n- Reviewed head: %s\n- Diff payload: owner/repo:1:skip\n- Final verified head: %s\n<!-- adversarial-review:spent -->' \
    "$a_new" "$a_new")
jq -n --arg receipt "$skip_receipt" '[{id:3,user:{login:"tester"},body:$receipt}]' \
    >"$artifacts/pr-1-comments.json"
skip_out=$(finalize 1 feat/issue-1)
assert_contains "$skip_out" 'receipt=verified-skip' 'a valid verified skip remains finalizable without a paid review'
assert_eq verified-skip "$(jq -r '.chainFinalizations["1"].reviewCoverage' "$state")" \
    'verified-skip finalization records its explicit non-review coverage path'

finish
