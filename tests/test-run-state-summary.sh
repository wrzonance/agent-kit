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
    '{"opened_prs":[],"queued":[103],"receipt_prs":[],"skipped_prs":[],"root_turns":[true,true,true,true,true,true,true],"first_completion":true}' >"$state"
chmod 600 -- "$state"

reports="$tmp/dispatch-plan.verification-reports"
mkdir -m 700 -- "$reports"
report='spec-verification= issue=103 steps=4 covered=1 uncovered=3 uncovered-steps=2,3,4 coverage=1/4 classification=majority-uncovered'
printf '%s\n' "$report" >"$reports/issue-103.report"
chmod 600 -- "$reports/issue-103.report"

ledger="$repo/.agent/runs/active-workers.ndjson"
printf '%s\n' \
    '{"version":2,"issue":101,"worktree":"/tmp/issue-101","branch":"feat/101","runId":"wave","attempt":"101-a","workerId":"worker-101","state":"terminal","disposition":"handed-back","evidence":"src/one.sh","heartbeatEpoch":1}' \
    '{"version":2,"issue":102,"worktree":"/tmp/issue-102","branch":"feat/102","runId":"wave","attempt":"102-a","workerId":"worker-102","state":"terminal","disposition":"handed-back","evidence":"src/two.sh,tests/two.sh","heartbeatEpoch":2}' \
    '{"version":2,"issue":104,"worktree":"/tmp/issue-104","branch":"feat/104","runId":"other","attempt":"104-a","workerId":"worker-104","state":"terminal","disposition":"handed-back","evidence":"src/other.sh","heartbeatEpoch":3}' \
    >"$ledger"
chmod 600 -- "$ledger"

# Auto-review handoff cannot succeed until every opened PR has either an
# adversarial receipt or a verified skip. Non-auto-review runs keep the same
# summary behavior.
printf '%s\n' \
    '{"opened_prs":[594,595],"queued":[],"receipt_prs":[594],"skipped_prs":[],"auto_review":false}' >"$state"
assert_rc 0 'non-auto-review summary permits opened PRs without review coverage' -- \
    "$script" summary --run-id wave --repo-root "$repo"

printf '%s\n' \
    '{"opened_prs":[594,595],"queued":[],"receipt_prs":[594],"skipped_prs":[],"auto_review":true}' >"$state"
missing_review_rc=0
missing_review_out="$tmp/missing-review.out"
missing_review_err="$tmp/missing-review.err"
"$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports" \
    >"$missing_review_out" 2>"$missing_review_err" || missing_review_rc=$?
assert_eq 1 "$missing_review_rc" 'auto-review summary refuses uncovered opened PRs'
assert_contains "$(cat "$missing_review_err")" '595' 'auto-review refusal names every uncovered PR'
assert_contains "$(cat "$missing_review_err")" '/review-remote-pr --auto-review 595' \
    'auto-review refusal prints the exact review resume command'
assert_contains "$(cat "$missing_review_out")" 'coverage= prs=2 receipts=1 skipped=0 parked=2 queued=0' \
    'auto-review refusal preserves coverage output'
assert_contains "$(cat "$missing_review_out")" 'blocked=101:src/one.sh' \
    'auto-review refusal preserves parked-worker evidence'
assert_contains "$(cat "$missing_review_out")" 'spec-verification= issue=103' \
    'auto-review refusal preserves durable verification reports'

for report_case in omitted absent; do
    early_out="$tmp/missing-review-$report_case.out"
    early_err="$tmp/missing-review-$report_case.err"
    early_rc=0
    early_args=()
    [[ $report_case == omitted ]] || early_args=(--reports-dir "$tmp/absent-reports")
    "$script" summary --run-id wave --repo-root "$repo" "${early_args[@]}" \
        >"$early_out" 2>"$early_err" || early_rc=$?
    assert_eq 1 "$early_rc" "auto-review refusal survives the $report_case reports early-return path"
    assert_contains "$(cat "$early_out")" 'blocked=101:src/one.sh' \
        "auto-review refusal preserves parked evidence with $report_case reports"
done

printf '%s\n' \
    '{"opened_prs":[594,595],"queued":[],"receipt_prs":[],"skipped_prs":[],"auto_review":true}' >"$state"
multiple_missing_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || true
assert_contains "$multiple_missing_err" \
    '/review-remote-pr --auto-review 594; /review-remote-pr --auto-review 595' \
    'auto-review refusal prints one exact review invocation per uncovered PR'

printf '%s\n' \
    '{"opened_prs":[594,595],"queued":[],"receipt_prs":[594],"skipped_prs":[595],"auto_review":true}' >"$state"
assert_rc 0 'auto-review summary accepts complete receipt and skip coverage' -- \
    "$script" summary --run-id wave --repo-root "$repo"

printf '%s\n' \
    '{"opened_prs":[],"queued":[103],"receipt_prs":[],"skipped_prs":[],"root_turns":[true,true,true,true,true,true,true],"first_completion":true}' >"$state"

expected=$'coverage= prs=0 receipts=0 skipped=0 parked=2 queued=1 root-turns-before-first-completion=7\nblocked=101:src/one.sh\nblocked=102:src/two.sh,tests/two.sh\nspec-verification= issue=103 steps=4 covered=1 uncovered=3 uncovered-steps=2,3,4 coverage=1/4 classification=majority-uncovered'
assert_eq "$expected" \
    "$(cd -- "$tmp" && "$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports")" \
    'summary derives exact coverage and replays durable verification reports verbatim'

"$script" set --run-id wave --repo-root "$repo" --path first_completion --json false
unlatched_expected=${expected/root-turns-before-first-completion=7/root-turns-before-first-completion=unlatched}
assert_eq "$unlatched_expected" \
    "$("$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports")" \
    'summary preserves coverage and reports initialized no-completion telemetry as unlatched'
"$script" set --run-id wave --repo-root "$repo" --path first_completion --json true

printf '%s\n' '{"opened_prs":[],"queued":[103],"receipt_prs":[],"skipped_prs":[]}' >"$state"
legacy_expected=${expected/root-turns-before-first-completion=7/root-turns-before-first-completion=unavailable}
assert_eq "$legacy_expected" \
    "$("$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports")" \
    'legacy summary state preserves coverage and reports unavailable root-turn telemetry'
printf '%s\n' \
    '{"opened_prs":[],"queued":[103],"receipt_prs":[],"skipped_prs":[],"root_turns":[true,true,true,true,true,true,true],"first_completion":true}' >"$state"

"$script" set --run-id wave --repo-root "$repo" --path root_turns --json '[false]'
malformed_turns_rc=0
malformed_turns_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || malformed_turns_rc=$?
assert_eq 1 "$malformed_turns_rc" 'summary still refuses malformed present root-turn telemetry'
assert_contains "$malformed_turns_err" 'summary state' 'malformed telemetry names the unavailable summary'
"$script" set --run-id wave --repo-root "$repo" --path root_turns --json '[true,true,true,true,true,true,true]'

printf '%s\n' "$report" >"$reports/issue-104.report"
chmod 600 -- "$reports/issue-104.report"
mismatch_rc=0
mismatch_err=$("$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports" 2>&1 >/dev/null) || mismatch_rc=$?
assert_eq 1 "$mismatch_rc" 'report replay refuses a filename/content issue mismatch'
assert_contains "$mismatch_err" 'issue' 'mismatch refusal names the invalid issue identity'
rm -- "$reports/issue-104.report"

printf '%s\n' "$report" >"$reports/issue-not-numeric.report"
chmod 600 -- "$reports/issue-not-numeric.report"
nonnumeric_rc=0
nonnumeric_err=$("$script" summary --run-id wave --repo-root "$repo" --reports-dir "$reports" 2>&1 >/dev/null) || nonnumeric_rc=$?
assert_eq 1 "$nonnumeric_rc" 'report replay refuses a nonnumeric issue filename'
assert_contains "$nonnumeric_err" 'filename' 'nonnumeric refusal names the invalid filename boundary'
rm -- "$reports/issue-not-numeric.report"

mkdir -- "$repo/subdir"
subdir_rc=0
subdir_err=$("$script" summary --run-id wave --repo-root "$repo/subdir" 2>&1 >/dev/null) || subdir_rc=$?
assert_eq 2 "$subdir_rc" 'summary refuses a subdirectory as an ambiguous repository root'
assert_contains "$subdir_err" 'checkout root' 'repository-boundary refusal names the exact required root'

# A later lifecycle row for the same issue supersedes an older handback.
printf '%s\n' \
    '{"version":2,"issue":101,"worktree":"/tmp/issue-101","branch":"feat/101","runId":"wave","attempt":"101-b","workerId":"worker-101b","state":"terminal","disposition":"completed","evidence":"result-101.json","heartbeatEpoch":4}' \
    >>"$ledger"
assert_eq $'coverage= prs=0 receipts=0 skipped=0 parked=1 queued=1 root-turns-before-first-completion=7\nblocked=102:src/two.sh,tests/two.sh' \
    "$("$script" summary --run-id wave --repo-root "$repo")" \
    'latest lifecycle per issue clears an older handback without duplicate parked coverage'

# Every summary collection is required so missing producer evidence cannot look like zero.
printf '%s\n' '{"opened_prs":[201,202],"queued":[]}' >"$state"
missing_state_rc=0
missing_state_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || missing_state_rc=$?
assert_eq 1 "$missing_state_rc" 'missing receipt collections refuse an unavailable summary'
assert_contains "$missing_state_err" 'receipt_prs' 'missing collection refusal names the recovery fields'

# Initialization is explicit and idempotent: it creates only absent summary
# arrays and never resets an existing producer record.
"$script" init-summary --run-id wave --repo-root "$repo"
assert_eq '{"opened_prs":[201,202],"queued":[],"receipt_prs":[],"skipped_prs":[],"first_completion":false}' \
    "$(jq -c . "$state")" \
    'summary initialization omits per-wake root-turn bookkeeping'
assert_contains "$("$script" summary --run-id wave --repo-root "$repo")" \
    'root-turns-before-first-completion=unavailable' \
    'a new summary renders unavailable root turns without root_turns records'
"$script" init-summary --run-id wave --repo-root "$repo"
assert_eq '{"opened_prs":[201,202],"queued":[],"receipt_prs":[],"skipped_prs":[],"first_completion":false}' \
    "$(jq -c . "$state")" \
    'resumed summary initialization preserves prior producer records'

"$script" record-summary --run-id wave --repo-root "$repo" --path queued --json 301
"$script" record-summary --run-id wave --repo-root "$repo" --path queued --json 301
"$script" dequeue-summary --run-id wave --repo-root "$repo" --json 301
"$script" dequeue-summary --run-id wave --repo-root "$repo" --json 301
"$script" record-summary --run-id wave --repo-root "$repo" --path opened_prs --json 203
"$script" record-summary --run-id wave --repo-root "$repo" --path opened_prs --json 203
"$script" record-summary --run-id wave --repo-root "$repo" --path opened_prs --json 204
"$script" record-summary --run-id wave --repo-root "$repo" --path receipt_prs --json 203
"$script" record-summary --run-id wave --repo-root "$repo" --path receipt_prs --json 203
"$script" record-summary --run-id wave --repo-root "$repo" --path skipped_prs --json 204
"$script" record-summary --run-id wave --repo-root "$repo" --path skipped_prs --json 204
assert_eq '{"opened_prs":[201,202,203,204],"queued":[],"receipt_prs":[203],"skipped_prs":[204],"first_completion":false}' \
    "$(jq -c . "$state")" \
    'producer recording and queue-to-dispatch removal are idempotent across resumed sweeps'

"$script" append --run-id wave --repo-root "$repo" --path root_turns --json true
"$script" append --run-id wave --repo-root "$repo" --path root_turns --json true
assert_eq '[true,true]' "$("$script" get --run-id wave --repo-root "$repo" --path root_turns)" \
    'root-turn recording increments the durable pre-completion count'
"$script" set --run-id wave --repo-root "$repo" --path first_completion
assert_eq true "$("$script" get --run-id wave --repo-root "$repo" --path first_completion)" \
    'the first-completion latch is durable before the summary reads the frozen count'

printf '%s\n' '{"opened_prs":[201],"queued":[],"receipt_prs":[201,201]}' >"$state"
bad_state_rc=0
bad_state_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || bad_state_rc=$?
assert_eq 1 "$bad_state_rc" 'duplicate receipt PRs refuse instead of inflating coverage'
assert_contains "$bad_state_err" 'receipt_prs' 'malformed collection refusal names the recovery field'

printf '%s\n' '{"opened_prs":[],"queued":[],"receipt_prs":[],"skipped_prs":[],"root_turns":[],"first_completion":true}' >"$state"
printf '%s\n' '{not-json' >>"$ledger"
bad_ledger_rc=0
bad_ledger_err=$("$script" summary --run-id wave --repo-root "$repo" 2>&1 >/dev/null) || bad_ledger_rc=$?
assert_eq 1 "$bad_ledger_rc" 'malformed lifecycle evidence refuses an honest summary'
assert_contains "$bad_ledger_err" 'active-workers' 'ledger refusal names the unavailable evidence'

# A large porcelain stream must be consumed completely. The former
# git|sed|head selector closed the producer early under pipefail.
printf '%s\n' '{"opened_prs":[],"queued":[],"receipt_prs":[],"skipped_prs":[],"root_turns":[],"first_completion":true}' >"$state"
sed -i '$d' "$ledger"
fake_bin="$tmp/fake-bin"
mkdir -- "$fake_bin"
cat >"$fake_bin/git" <<'SCRIPT'
#!/usr/bin/env bash
if [[ ${1:-} == -C && ${3:-} == worktree && ${4:-} == list && ${5:-} == --porcelain ]]; then
    printf 'worktree %s\nHEAD 0000000000000000000000000000000000000000\n\n' "$SUMMARY_PRIMARY_ROOT"
    for ((i=0; i<20000; i++)); do
        printf 'worktree /tmp/summary-secondary-%05d\nHEAD 0000000000000000000000000000000000000000\n\n' "$i"
    done
    exit 0
fi
exec "$SUMMARY_REAL_GIT" "$@"
SCRIPT
chmod +x "$fake_bin/git"
large_rc=0
large_output=$(PATH="$fake_bin:$PATH" SUMMARY_REAL_GIT="$(command -v git)" SUMMARY_PRIMARY_ROOT="$repo" \
    "$script" summary --run-id wave --repo-root "$repo") || large_rc=$?
assert_eq 0 "$large_rc" 'primary worktree selection consumes a large porcelain stream without SIGPIPE'
assert_contains "$large_output" 'coverage= prs=0' 'large worktree selection still resolves the primary ledger'

skill_text=$(tr '\n' ' ' <"$root/agentkit/skills/parallel-issues/SKILL.md" | tr -s '[:space:]' ' ')
# shellcheck disable=SC2016
auto_review_get_recipe='auto_review_state=$("$agentkit/.shared/scripts/run-state.sh" get --run-id "$RUN_ID" --repo-root "$repository_root" --path auto_review) || exit 1'
# shellcheck disable=SC2016
auto_review_case_recipe='case $auto_review_state in true|false)'
# shellcheck disable=SC2016
auto_review_value='"$auto_review_state"'
# shellcheck disable=SC2016
auto_review_default='${auto_review:-false}'
assert_contains "$skill_text" \
    "$auto_review_get_recipe" \
    'Collect restores the durable auto-review mode before either PR-open path'
assert_contains "$skill_text" "$auto_review_case_recipe" \
    'Collect refuses a restored auto-review value outside the boolean boundary'
completion_recipe=$(rg -F -- '- **Completion report (branch + pushed SHA)**' "$root/agentkit/skills/parallel-issues/SKILL.md")
blocked_recipe=$(rg -F -- '- **BLOCKED**' "$root/agentkit/skills/parallel-issues/SKILL.md")
assert_contains "$completion_recipe" "$auto_review_value" \
    'normal PR-open completion prints the restored auto-review mode'
assert_contains "$blocked_recipe" "$auto_review_value" \
    'partial-pushed PR-open completion prints the restored auto-review mode'
assert_not_contains "$completion_recipe$blocked_recipe" "$auto_review_default" \
    'neither Collect completion path can default a resumed auto-review run to false'
# The literal expansion is the unsafe recipe under test.
# shellcheck disable=SC2016
assert_not_contains "$skill_text" '--path auto_review --json "${auto_review:-false}"' \
    'auto-review persistence never defaults an unset shell variable to false'
assert_contains "$skill_text" '--path auto_review --json true' \
    'auto-review invocation facts persist the literal true value'
assert_contains "$skill_text" '--path auto_review --json false' \
    'non-auto-review invocation facts persist the literal false value'

finish
