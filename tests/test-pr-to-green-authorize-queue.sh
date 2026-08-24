#!/usr/bin/env bash
# Derived pr-to-green queue authorization boundary.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='pr to green: authorize queue'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
authorize="$root/agentkit/skills/pr-to-green/scripts/authorize-queue.sh"
repo_root="$tmp/repo"
mkdir -p "$repo_root/.agent"
confirmed="$repo_root/.agent/pr-to-green-confirmed-queue.json"

cat >"$tmp/pr-queue" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$QUEUE_LOG"
if [[ ${QUEUE_FAIL:-0} == 1 ]]; then
    printf 'injected queue failure\n' >&2
    exit 1
fi
sha=${QUEUE_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
jq -cn --arg sha "$sha" '[
  {pr:14,issue:14,state:"RUNNABLE",source:"plan",base:"main",head:"feat/demo",sha:$sha},
  {pr:15,issue:15,state:"WAITING_FOR_MERGE",source:"plan",base:"feat/demo",head:"feat/next",sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}
]'
EOF
chmod +x "$tmp/pr-queue"

run_authorize() {
    AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
        bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
        --merge-plan "$tmp/merge-plan.json" --ready-transition --no-auto-merge \
        --confirmed-queue-file "$confirmed" \
        --provider coderabbit:trigger:capability-default
}

write_confirmed() {
    local sha=${1:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
    local include_second=${2:-yes}
    jq -cn --arg sha "$sha" --arg includeSecond "$include_second" '{
      repository:"owner/repo",
      queue:([{
        pr:14,state:"RUNNABLE",headSha:$sha,base:"main"
      }] + (if $includeSecond == "yes" then [{
        pr:15,state:"WAITING_FOR_MERGE",
        headSha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base:"feat/demo"
      }] else [] end))
    }' >"$confirmed"
    chmod 600 "$confirmed"
}

: >"$tmp/merge-plan.json"
: >"$tmp/queue.log"
write_confirmed
out=$(run_authorize)
auth="$repo_root/.agent/pr-to-green-auth.json"
assert_eq "authorization=$auth queue=2" "$out" \
    'one command reports the complete derived authorization record'
assert_eq '600' "$(stat -c '%a' "$auth")" 'authorization is owner-only'
assert_eq 'owner/repo' "$(jq -r '.repository' "$auth")" 'repository is recorded'
assert_eq 'true' "$(jq -r '.readyTransition' "$auth")" 'ready transition is explicit'
assert_eq 'coderabbit:trigger:capability-default' \
    "$(jq -r '.providers[0] | [.name,.action,.source] | join(":")' "$auth")" \
    'provider action and source are preserved'
assert_eq '14:RUNNABLE:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:main' \
    "$(jq -r '.queue[0] | [.pr,.state,.headSha,.base] | join(":")' "$auth")" \
    'queue entries use the consumer schema with live head and base fields'
assert_eq '["providers","queue","readyTransition","repository"]' \
    "$(jq -c 'keys | sort' "$auth")" 'non-auto-merge authorization has the exact schema'
assert_contains "$(cat "$tmp/queue.log")" \
    '--repo owner/repo --repo-root' 'authorization delegates forge reads to pr-queue'
assert_contains "$(cat "$tmp/queue.log")" \
    '--merge-plan' 'authorization preserves the confirmed queue selector'
assert_contains "$(cat "$tmp/queue.log")" \
    '--format json' 'authorization consumes machine-readable live queue state'

before_drift=$(sha256sum "$auth")
head_drift_rc=0
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc run_authorize \
    >"$tmp/head-drift.out" 2>"$tmp/head-drift.err" || head_drift_rc=$?
assert_eq '1' "$head_drift_rc" 'head drift after display blocks authorization'
assert_contains "$(cat "$tmp/head-drift.err")" 'redisplay and reconfirm' \
    'head drift names the required consent refresh'
assert_eq "$before_drift" "$(sha256sum "$auth")" \
    'head drift preserves the prior authorization byte-for-byte'

write_confirmed cccccccccccccccccccccccccccccccccccccccc
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc run_authorize >/dev/null
assert_eq 'cccccccccccccccccccccccccccccccccccccccc' \
    "$(jq -r '.queue[0].headSha' "$auth")" \
    'redisplaying and reconfirming lets a rerun derive the refreshed head live'

write_confirmed cccccccccccccccccccccccccccccccccccccccc no
set_drift_rc=0
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc run_authorize \
    >"$tmp/set-drift.out" 2>"$tmp/set-drift.err" || set_drift_rc=$?
assert_eq '1' "$set_drift_rc" 'PR set drift after display blocks authorization'
assert_contains "$(cat "$tmp/set-drift.err")" 'redisplay and reconfirm' \
    'PR set drift names the required consent refresh'
write_confirmed

rm -f "$auth"
missing_choice_rc=0
AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --ready-transition --confirmed-queue-file "$confirmed" \
    --provider coderabbit:trigger:capability-default \
    >"$tmp/missing.out" 2>"$tmp/missing.err" || missing_choice_rc=$?
assert_eq '2' "$missing_choice_rc" 'auto-merge consent cannot be inferred'
artifact_exists=false
[[ ! -e $auth ]] || artifact_exists=true
assert_eq false "$artifact_exists" 'missing explicit consent produces no artifact'

auto_out=$(AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --ready-transition --auto-merge --merge-method squash --delete-branch \
    --confirmed-queue-file "$confirmed" \
    --provider coderabbit:observe:operator-instruction)
assert_eq "authorization=$auth queue=2" "$auto_out" 'auto-merge record is written'
assert_eq '["autoMerge","deleteBranch","mergeMethod","providers","queue","readyTransition","repository"]' \
    "$(jq -c 'keys | sort' "$auth")" 'auto-merge authorization has the exact schema'
assert_eq 'true:squash:true' \
    "$(jq -r '[.autoMerge,.mergeMethod,.deleteBranch] | join(":")' "$auth")" \
    'explicit auto-merge choices are recorded unchanged'

before_failure=$(sha256sum "$auth")
queue_failure_rc=0
QUEUE_FAIL=1 run_authorize >"$tmp/failure.out" 2>"$tmp/failure.err" ||
    queue_failure_rc=$?
assert_eq '1' "$queue_failure_rc" 'a failed live queue read fails authorization derivation'
assert_eq "$before_failure" "$(sha256sum "$auth")" \
    'a failed refresh preserves the prior authorization byte-for-byte'

caller_sha_rc=0
AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --ready-transition --no-auto-merge --no-providers --confirmed-queue-file "$confirmed" \
    --head-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    >"$tmp/caller-sha.out" 2>"$tmp/caller-sha.err" || caller_sha_rc=$?
assert_eq '2' "$caller_sha_rc" 'a caller cannot supply the authorization head SHA'

sentinel_rc=0
AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --ready-transition --no-auto-merge --confirmed-queue-file "$confirmed" \
    --provider __NONE__ >"$tmp/sentinel.out" 2>"$tmp/sentinel.err" || sentinel_rc=$?
assert_eq '1' "$sentinel_rc" 'the former in-band provider sentinel is rejected'
assert_contains "$(cat "$tmp/sentinel.err")" '--provider must have the form' \
    'sentinel injection is handled as an invalid provider value'

mixed_none_rc=0
AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --ready-transition --no-auto-merge --confirmed-queue-file "$confirmed" \
    --no-providers --provider coderabbit:trigger:capability-default \
    >"$tmp/mixed-none.out" 2>"$tmp/mixed-none.err" || mixed_none_rc=$?
assert_eq '1' "$mixed_none_rc" '--no-providers cannot be mixed with provider decisions'

finish
