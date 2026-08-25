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
base14=${QUEUE_BASE_14:-main}
shape14=${QUEUE_SHAPE_14:-1:1:1}
omit14=${QUEUE_OMIT_14:-0}
base15=${QUEUE_BASE_15:-feat/demo}
sha15=${QUEUE_SHA_15:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
state15=${QUEUE_STATE_15:-WAITING_FOR_MERGE}
shape15=${QUEUE_SHAPE_15:-2:2:2}
include16=${QUEUE_INCLUDE_16:-0}
sha16=${QUEUE_SHA_16:-6666666666666666666666666666666666666666}
shape16=${QUEUE_SHAPE_16:-3:3:3}
entries='[]'
if [[ $omit14 == 0 ]]; then
    entries=$(jq -cn --argjson e "$entries" --arg sha "$sha" --arg base14 "$base14" --arg shape14 "$shape14" '
      ($shape14 | split(":") | map(tonumber)) as $s14 | $e + [
      {pr:14,issue:14,state:"RUNNABLE",source:"plan",base:$base14,head:"feat/demo",sha:$sha,
       diffShape:{additions:$s14[0],deletions:$s14[1],changedFiles:$s14[2]}}]')
fi
entries=$(jq -cn --argjson e "$entries" --arg sha15 "$sha15" --arg base15 "$base15" \
    --arg state15 "$state15" --arg shape15 "$shape15" '
  ($shape15 | split(":") | map(tonumber)) as $s15 | $e + [
  {pr:15,issue:15,state:$state15,source:"plan",base:$base15,head:"feat/next",sha:$sha15,
   diffShape:{additions:$s15[0],deletions:$s15[1],changedFiles:$s15[2]}}]')
if [[ $include16 == 1 ]]; then
    entries=$(jq -cn --argjson e "$entries" --arg sha16 "$sha16" --arg shape16 "$shape16" '
      ($shape16 | split(":") | map(tonumber)) as $s16 | $e + [
      {pr:16,issue:16,state:"RUNNABLE",source:"plan",base:"main",head:"feat/root2",sha:$sha16,
       diffShape:{additions:$s16[0],deletions:$s16[1],changedFiles:$s16[2]}}]')
fi
printf '%s\n' "$entries"
EOF
chmod +x "$tmp/pr-queue"

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_LOG"
endpoint=''
for arg in "$@"; do
    [[ $arg == repos/* ]] && endpoint=$arg
done
case $endpoint in
repos/owner/repo/compare/*)
    behind=${QUEUE_COMPARE_BEHIND:-0}
    printf '{"behind_by":%s,"status":"ahead"}\n' "$behind"
    ;;
repos/owner/repo/pulls/14)
    merged=${QUEUE_PR14_MERGED:-true}
    printf '{"number":14,"merged":%s}\n' "$merged"
    ;;
*)
    printf 'unexpected endpoint: %s\n' "$endpoint" >&2
    exit 1
    ;;
esac
EOF
chmod +x "$tmp/gh"

run_authorize() {
    run_authorize_provider coderabbit:trigger:capability-default
}

run_authorize_provider() {
    local provider=$1
    shift || true
    AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
        AUTHORIZE_QUEUE_GH="$tmp/gh" GH_LOG="$tmp/gh.log" \
        bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
        --merge-plan "$tmp/merge-plan.json" --ready-transition --no-auto-merge \
        --confirmed-queue-file "$confirmed" \
        --provider "$provider" "$@"
}

write_confirmed() {
    local sha=${1:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}
    local include_second=${2:-yes}
    local provider=${3:-coderabbit:trigger:capability-default}
    local base14=${4:-main}
    jq -cn --arg sha "$sha" --arg includeSecond "$include_second" --arg provider "$provider" \
        --arg base14 "$base14" '{
      repository:"owner/repo",
      providers:(if $provider == "__NONE__" then [] else ($provider | split(":")) as $parts |
        [{name:$parts[0],action:$parts[1],source:$parts[2]}] end),
      queue:([{
        pr:14,state:"RUNNABLE",headSha:$sha,base:$base14,
        diffShape:{additions:1,deletions:1,changedFiles:1}
      }] + (if $includeSecond == "yes" then [{
        pr:15,state:"WAITING_FOR_MERGE",
        headSha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base:"feat/demo",
        diffShape:{additions:2,deletions:2,changedFiles:2}
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

before_provider_failure=$(sha256sum "$auth")
provider_action_rc=0
run_authorize_provider coderabbit:observe:operator-instruction \
    >"$tmp/provider-action.out" 2>"$tmp/provider-action.err" || provider_action_rc=$?
assert_eq '1' "$provider_action_rc" 'trigger versus observe cannot change after confirmation'
assert_contains "$(cat "$tmp/provider-action.err")" 'provider decisions differ' \
    'provider action drift names the required consent refresh'
assert_eq "$before_provider_failure" "$(sha256sum "$auth")" \
    'provider action drift preserves the prior authorization byte-for-byte'

write_confirmed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes __NONE__
before_provider_set_failure=$(sha256sum "$auth")
provider_set_rc=0
run_authorize >"$tmp/provider-set.out" 2>"$tmp/provider-set.err" || provider_set_rc=$?
assert_eq '1' "$provider_set_rc" 'provider versus no-provider cannot change after confirmation'
assert_contains "$(cat "$tmp/provider-set.err")" 'provider decisions differ' \
    'provider set drift names the required consent refresh'
assert_eq "$before_provider_set_failure" "$(sha256sum "$auth")" \
    'provider set drift preserves the prior authorization byte-for-byte'

write_confirmed
jq '.providers += [{name:"other",action:"trigger",source:"capability-default"}]' \
    "$confirmed" >"$tmp/extra-provider.json"
cp "$tmp/extra-provider.json" "$confirmed"
extra_provider_rc=0
run_authorize >"$tmp/extra-provider.out" 2>"$tmp/extra-provider.err" || extra_provider_rc=$?
assert_eq '1' "$extra_provider_rc" 'an extra displayed provider decision cannot be omitted'
assert_contains "$(cat "$tmp/extra-provider.err")" 'provider decisions differ' \
    'an extra provider decision names the required consent refresh'

write_confirmed
jq 'del(.providers)' "$confirmed" >"$tmp/missing-providers.json"
cp "$tmp/missing-providers.json" "$confirmed"
missing_provider_record_rc=0
run_authorize >"$tmp/missing-provider-record.out" 2>"$tmp/missing-provider-record.err" || missing_provider_record_rc=$?
assert_eq '1' "$missing_provider_record_rc" 'a snapshot missing provider decisions fails closed'
assert_contains "$(cat "$tmp/missing-provider-record.err")" 'provider decisions differ' \
    'a missing provider record names the required consent refresh'

write_confirmed
jq '.providers += [.providers[0]]' "$confirmed" >"$tmp/duplicate-provider.json"
cp "$tmp/duplicate-provider.json" "$confirmed"
duplicate_provider_rc=0
run_authorize >"$tmp/duplicate-provider.out" 2>"$tmp/duplicate-provider.err" || duplicate_provider_rc=$?
assert_eq '1' "$duplicate_provider_rc" 'duplicate displayed provider decisions fail closed'
assert_contains "$(cat "$tmp/duplicate-provider.err")" 'provider decisions differ' \
    'a duplicate provider decision names the required consent refresh'

write_confirmed
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
    --provider coderabbit:trigger:capability-default)
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

# --- Mechanical queue advance (issue #450): no flag stays the exact-match default ---

write_confirmed
: >"$tmp/gh.log"
no_flag_rc=0
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc run_authorize \
    >"$tmp/no-flag.out" 2>"$tmp/no-flag.err" || no_flag_rc=$?
assert_eq '1' "$no_flag_rc" 'head drift without the flag still fails closed by default'
assert_contains "$(cat "$tmp/no-flag.err")" 'redisplay and reconfirm' \
    'the default refusal is unchanged when the flag is absent'
assert_eq '' "$(cat "$tmp/gh.log")" \
    'without the flag, no ancestry or merged-check gh call is ever made'

# --- Root merge-down: same base, new head, matching diff shape, verified ancestry ---

write_confirmed
: >"$tmp/gh.log"
merge_down_out=$(QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance)
assert_eq "authorization=$auth queue=2" "$merge_down_out" \
    'a clean root merge-down authorizes without redisplay'
assert_eq 'cccccccccccccccccccccccccccccccccccccccc' \
    "$(jq -r '.queue[] | select(.pr==14) | .headSha' "$auth")" \
    'the refreshed head comes from the live re-derivation, never a hand-typed value'
assert_contains "$(cat "$tmp/gh.log")" 'compare/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa...cccccccccccccccccccccccccccccccccccccccc' \
    'the merge-down is proven by comparing the previously authorized head against the live head'

# --- Root merge-down: diff expansion blocks silently updating the record ---

write_confirmed
before_expand=$(sha256sum "$auth")
expand_rc=0
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc QUEUE_SHAPE_14=9:9:9 \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance \
    >"$tmp/expand.out" 2>"$tmp/expand.err" || expand_rc=$?
assert_eq '1' "$expand_rc" 'an expanded diff is never treated as mechanical'
assert_contains "$(cat "$tmp/expand.err")" 'diff' \
    'the refusal names diff expansion specifically'
assert_eq "$before_expand" "$(sha256sum "$auth")" \
    'a diff-expansion refusal preserves the prior authorization byte-for-byte'

# --- Root merge-down: broken ancestry (history rewrite) blocks it ---

write_confirmed
ancestry_rc=0
QUEUE_SHA=cccccccccccccccccccccccccccccccccccccccc QUEUE_COMPARE_BEHIND=1 \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance \
    >"$tmp/ancestry.out" 2>"$tmp/ancestry.err" || ancestry_rc=$?
assert_eq '1' "$ancestry_rc" 'a head that is not a live descendant of the authorized head is never mechanical'
assert_contains "$(cat "$tmp/ancestry.err")" 'ancestry' \
    'the refusal names the broken ancestry'

# --- Stacked successor retarget: valid chain-advance.sh proof authorizes the new base/head ---

retarget_proof_ok="$tmp/retarget-proof-ok.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=current:post-retarget ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_ok"
write_confirmed
retarget_out=$(QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_ok")
assert_eq "authorization=$auth queue=2" "$retarget_out" \
    'a proven stacked retarget authorizes without redisplay'
assert_eq 'main:dddddddddddddddddddddddddddddddddddddddd' \
    "$(jq -r '.queue[] | select(.pr==15) | [.base,.headSha] | join(":")' "$auth")" \
    'the refreshed base and head come from the live re-derivation'

# --- Stacked successor retarget: approval is provider policy, never a
# mechanical gate (issue #455) -- a proof carrying any well-formed
# `approval=` token authorizes identically across every provider plan:
# trigger, observe, disabled, and effective-none (--no-providers). ---

retarget_proof_none="$tmp/retarget-proof-none.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=none ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_none"
retarget_proof_residue="$tmp/retarget-proof-residue.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=residue:stale ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_residue"
retarget_proof_unknown="$tmp/retarget-proof-unknown.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=unknown ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_unknown"

write_confirmed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes coderabbit:trigger:capability-default
trigger_retarget_out=$(QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_none")
assert_eq "authorization=$auth queue=2" "$trigger_retarget_out" \
    'a trigger provider authorizes a stacked retarget with no approval yet (approval=none)'

write_confirmed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes coderabbit:observe:operator-instruction
observe_retarget_out=$(QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE run_authorize_provider coderabbit:observe:operator-instruction \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_residue")
assert_eq "authorization=$auth queue=2" "$observe_retarget_out" \
    'an observe provider authorizes a stacked retarget over stale approval residue'

write_confirmed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes coderabbit:disabled:operator-instruction
disabled_retarget_out=$(QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE run_authorize_provider coderabbit:disabled:operator-instruction \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_unknown")
assert_eq "authorization=$auth queue=2" "$disabled_retarget_out" \
    'a disabled provider authorizes a stacked retarget without a synthetic approval requirement'

write_confirmed aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa yes __NONE__
none_retarget_out=$(AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    AUTHORIZE_QUEUE_GH="$tmp/gh" GH_LOG="$tmp/gh.log" \
    QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --merge-plan "$tmp/merge-plan.json" --ready-transition --no-auto-merge \
    --confirmed-queue-file "$confirmed" --no-providers \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_none")
assert_eq "authorization=$auth queue=2" "$none_retarget_out" \
    'an effective-none provider plan (--no-providers) authorizes a stacked retarget with no approval'

# --- A garbled approval token still fails closed: dropping the requirement that
# it equal `current:post-retarget` is not the same as accepting anything. ---

retarget_proof_garbled="$tmp/retarget-proof-garbled.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=yes ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_garbled"
write_confirmed
garbled_rc=0
QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_garbled" \
    >"$tmp/garbled.out" 2>"$tmp/garbled.err" || garbled_rc=$?
assert_eq '1' "$garbled_rc" 'a garbled approval= token fails closed rather than being accepted as any value'
assert_contains "$(cat "$tmp/garbled.err")" 'retarget' \
    'the garbled-token refusal is reported as a retarget-proof failure'

# --- Stacked successor retarget: missing proof blocks it ---

write_confirmed
no_proof_rc=0
QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance \
    >"$tmp/no-proof.out" 2>"$tmp/no-proof.err" || no_proof_rc=$?
assert_eq '1' "$no_proof_rc" 'a base change with no retarget proof is a material judgment, never mechanical'
assert_contains "$(cat "$tmp/no-proof.err")" 'retarget' \
    'the refusal names the missing retarget proof'

# --- Stacked successor retarget: a proof for the wrong head is rejected ---

retarget_proof_wrong="$tmp/retarget-proof-wrong.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=9999999999999999999999999999999999999999 ci=3/3 green:post-retarget approval=current:post-retarget ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_wrong"
write_confirmed
wrong_proof_rc=0
QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default --allow-mechanical-advance \
    --retarget-proof "15:$retarget_proof_wrong" \
    >"$tmp/wrong-proof.out" 2>"$tmp/wrong-proof.err" || wrong_proof_rc=$?
assert_eq '1' "$wrong_proof_rc" 'a retarget proof for a different head never authorizes the live head'
assert_contains "$(cat "$tmp/wrong-proof.err")" 'retarget' \
    'the mismatch is reported as a retarget-proof failure'

# --- A predecessor that merged and vanished from the live queue is allowed to drop out ---

write_confirmed
vanished_out=$(QUEUE_OMIT_14=1 QUEUE_BASE_15=main \
    QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_ok")
assert_eq "authorization=$auth queue=1" "$vanished_out" \
    'a merged, verified-vanished predecessor drops out of the refreshed queue'
assert_eq '15' "$(jq -r '.queue[0].pr' "$auth")" \
    'only the still-open successor remains authorized'

# --- A vanished PR that cannot be proven merged is never silently dropped (the spike-caught bug) ---

write_confirmed
not_merged_rc=0
QUEUE_OMIT_14=1 QUEUE_PR14_MERGED=false QUEUE_BASE_15=main \
    QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd QUEUE_STATE_15=RUNNABLE \
    run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_ok" \
    >"$tmp/not-merged.out" 2>"$tmp/not-merged.err" || not_merged_rc=$?
assert_eq '1' "$not_merged_rc" \
    'a PR missing from the live queue is never assumed merged without independent proof'
assert_contains "$(cat "$tmp/not-merged.err")" 'merged' \
    'the refusal names the unverified disappearance'

# --- A brand-new PR appearing in the live queue is a topology change, never mechanical ---

write_confirmed
added_rc=0
QUEUE_INCLUDE_16=1 run_authorize_provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance >"$tmp/added.out" 2>"$tmp/added.err" || added_rc=$?
assert_eq '1' "$added_rc" 'a PR the operator never confirmed is never silently authorized'

# --- Combined: two independent roots and a squash-merged stacked successor in one queue ---

jq -cn '{
  repository:"owner/repo",
  providers:[{name:"coderabbit",action:"trigger",source:"capability-default"}],
  queue:[
    {pr:14,state:"RUNNABLE",headSha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",base:"main",
     diffShape:{additions:1,deletions:1,changedFiles:1}},
    {pr:15,state:"WAITING_FOR_MERGE",headSha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",base:"feat/demo",
     diffShape:{additions:2,deletions:2,changedFiles:2}},
    {pr:16,state:"RUNNABLE",headSha:"6666666666666666666666666666666666666666",base:"main",
     diffShape:{additions:3,deletions:3,changedFiles:3}}
  ]
}' >"$confirmed"
chmod 600 "$confirmed"
retarget_proof_combined="$tmp/retarget-proof-combined.txt"
printf 'retargeted pr #15 base=main head=feat/next sha=dddddddddddddddddddddddddddddddddddddddd ci=3/3 green:post-retarget approval=current:post-retarget ancestry=verified closing-issues=1\n' \
    >"$retarget_proof_combined"
: >"$tmp/queue.log"; : >"$tmp/gh.log"
combined_out=$(AUTHORIZE_QUEUE_HELPER="$tmp/pr-queue" QUEUE_LOG="$tmp/queue.log" \
    AUTHORIZE_QUEUE_GH="$tmp/gh" GH_LOG="$tmp/gh.log" \
    QUEUE_OMIT_14=1 QUEUE_BASE_15=main QUEUE_SHA_15=dddddddddddddddddddddddddddddddddddddddd \
    QUEUE_STATE_15=RUNNABLE QUEUE_INCLUDE_16=1 QUEUE_SHA_16=7777777777777777777777777777777777777777 \
    bash "$authorize" --repo owner/repo --repo-root "$repo_root" \
    --merge-plan "$tmp/merge-plan.json" --ready-transition --no-auto-merge \
    --confirmed-queue-file "$confirmed" \
    --provider coderabbit:trigger:capability-default \
    --allow-mechanical-advance --retarget-proof "15:$retarget_proof_combined")
assert_eq "authorization=$auth queue=2" "$combined_out" \
    'two independent roots and a stacked successor advance in one confirmed queue without one prompt per PR'
assert_eq '15:main:dddddddddddddddddddddddddddddddddddddddd 16:main:7777777777777777777777777777777777777777' \
    "$(jq -r '.queue | sort_by(.pr) | map([.pr,.base,.headSha] | join(":")) | join(" ")' "$auth")" \
    'the merged-and-vanished root drops out while the surviving root and successor both refresh live'

finish
