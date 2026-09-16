#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC2034
TEST_NAME='authorized adversarial review retry'
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/lib/assert.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
repo="$tmp/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.invalid
git -C "$repo" config user.name test
printf base >"$repo/file"
git -C "$repo" add file
git -C "$repo" commit -qm base
old_head=$(git -C "$repo" rev-parse HEAD)
printf next >>"$repo/file"
git -C "$repo" commit -qam next
new_head=$(git -C "$repo" rev-parse HEAD)
lib="$here/../agentkit/skills/.shared/scripts/lib/review-attempt.sh"
launcher="$here/../agentkit/skills/review-remote-pr/scripts/adversarial-run.sh"
launcher=$(realpath "$launcher")
# shellcheck disable=SC1090
source "$lib"
attempt() { cmd_attempt "$1" --repo-root "$repo" --entry-file "$2" "${@:3}"; }

make_entry() {
    local run=$1 head=$2 payload=$3 budget=${4:-5} tokens=${5:-20000} pr=${6:-743}
    mkdir -p "$run/state"
    printf 'bounded payload evidence\n' >"$run/adversarial.payload-size"
    jq -n --arg repo_root "$repo" --arg result "$run/adversarial.result.json" \
        --arg launcher "$launcher" --arg head "$head" --arg payload "$payload" \
        --arg budget "$budget" --arg tokens "$tokens" --argjson launcher_pid "$$" --argjson pr "$pr" \
        '{repo:"acme/widget",pr:$pr,repoRoot:$repo_root,head:$head,
          base:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",reviewBase:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
          payload:$payload,provider:"anthropic",model:"claude-fable-5-1",effort:"xhigh",
          launcher:$launcher,launcherPid:$launcher_pid,result:$result,canonical:true,
          maxBudgetUsd:($budget|tonumber),maxOutputTokens:($tokens|tonumber),maxDurationSeconds:900}' \
        >"$run/state/review-attempt.json"
}
entry="$tmp/run1/state/review-attempt.json"
make_entry "$tmp/run1" "$old_head" oldpayload
prior=$(attempt reserve "$entry") || exit 1
prior_id=$(jq -r .id <<<"$prior")
attempt start "$entry" --id "$prior_id" --pid "$$" --parent-pid "$$" >/dev/null || exit 1
transcript="$tmp/run1/transcript.ndjson"
printf '%s\n' '{"type":"result","is_error":true}' >"$transcript"
jq -n --arg transcript "$transcript" '{status:"failed",transcript:$transcript}' >"$tmp/run1/adversarial.result.json"
attempt finish "$entry" --id "$prior_id" --state failed --parent-pid "$$" >/dev/null || exit 1
old_result_hash=$(sha256sum "$tmp/run1/adversarial.result.json" | cut -d' ' -f1)
old_transcript_hash=$(sha256sum "$transcript" | cut -d' ' -f1)

make_entry "$tmp/run2" "$new_head" newpayload 10 40000
retry_entry="$tmp/run2/state/review-attempt.json"
authorization="User authorized one retry with doubled output and \$10 ceiling"
assert_rc 1 'blank authorization cannot retry a failed attempt' -- attempt retry "$retry_entry" --id "$prior_id" --authorization ''
jq '.model="different-model"' "$retry_entry" >"$tmp/mismatch"
cp "$tmp/mismatch" "$retry_entry"
assert_rc 1 'retry cannot change model' -- attempt retry "$retry_entry" --id "$prior_id" --authorization "$authorization"
make_entry "$tmp/run2" "$new_head" newpayload 10 40000
jq '.reviewBase="cccccccccccccccccccccccccccccccccccccccc"' "$retry_entry" >"$tmp/mismatch"
cp "$tmp/mismatch" "$retry_entry"
assert_rc 1 'retry cannot change the review base' -- attempt retry "$retry_entry" --id "$prior_id" --authorization "$authorization"
make_entry "$tmp/run2" "$new_head" newpayload 10 40000
orphan_head=$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse "$new_head^{tree}")" </dev/null)
jq --arg head "$orphan_head" '.head=$head' "$retry_entry" >"$tmp/mismatch"
cp "$tmp/mismatch" "$retry_entry"
assert_rc 1 'retry rejects an unrelated rewritten head' -- attempt retry "$retry_entry" --id "$prior_id" --authorization "$authorization"
make_entry "$tmp/run2" "$new_head" newpayload 10 40000
jq --arg result "$tmp/run1/adversarial.result.json" '.result=$result' "$retry_entry" >"$tmp/mismatch"
cp "$tmp/mismatch" "$retry_entry"
assert_rc 1 'retry cannot overwrite prior result artifacts' -- attempt retry "$retry_entry" --id "$prior_id" --authorization "$authorization"
make_entry "$tmp/run2" "$new_head" newpayload 10 40000
retry=$(attempt retry "$retry_entry" --id "$prior_id" \
    --authorization "$authorization")
retry_id=$(jq -r '.id // empty' <<<"$retry")
assert_eq 36 "${#retry_id}" 'retry reserves a distinct canonical attempt ID'
assert_eq reserved "$(jq -r '.state' <<<"$retry")" 'retry reserves without launching a provider'
assert_eq "$prior_id" "$(jq -r '.retryOf' <<<"$retry")" 'new attempt records the exact failed attempt it retries'
assert_eq "$authorization" \
    "$(jq -r '.retryAuthorization' <<<"$retry")" 'retry authorization is durable'
assert_eq 10 "$(jq -r '.maxBudgetUsd' <<<"$retry")" 'retry records the increased budget ceiling'
assert_eq 40000 "$(jq -r '.maxOutputTokens' <<<"$retry")" 'retry records the doubled output limit'
assert_eq "$prior_id" "$(jq -r '.previousAttempts[0].id' <<<"$retry")" 'prior failed history remains archived'
assert_eq "$old_result_hash" "$(jq -r '.previousAttempts[0].resultSha256' <<<"$retry")" 'prior result hash is preserved'
assert_eq "$old_transcript_hash" "$(jq -r '.previousAttempts[0].transcriptSha256' <<<"$retry")" 'prior transcript hash is preserved'
assert_rc 1 'a stale prior ID cannot reserve another retry' -- attempt retry "$retry_entry" --id "$prior_id" --authorization stale
assert_eq "$old_result_hash" "$(sha256sum "$tmp/run1/adversarial.result.json" | cut -d' ' -f1)" 'old result artifact remains untouched'
assert_eq "$old_transcript_hash" "$(sha256sum "$transcript" | cut -d' ' -f1)" 'old transcript remains untouched'

pr=743
for state in reserved running completed unknown-outcome; do
    pr=$((pr + 1))
    run="$tmp/state-$state"
    make_entry "$run" "$old_head" "payload-$state" 5 20000 "$pr"
    state_entry="$run/state/review-attempt.json"
    current=$(attempt reserve "$state_entry")
    state_id=$(jq -r .id <<<"$current")
    if [[ $state == running || $state == unknown-outcome ]]; then
        attempt start "$state_entry" --id "$state_id" --pid "$$" --parent-pid "$$" >/dev/null || exit 1
    fi
    if [[ $state == unknown-outcome ]]; then
        attempt finish "$state_entry" --id "$state_id" --state unknown-outcome --parent-pid "$$" >/dev/null || exit 1
    elif [[ $state == completed ]]; then
        jq -n --arg id "$state_id" --arg model 'claude-fable-5-1' \
            '{status:"completed",exitCode:0,attemptId:$id,requestedModel:$model,
              reviewBase:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
              prBase:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",diffPayload:"payload-completed",
              verdict:{verdict:"no_findings",findings:[]}}' >"$run/adversarial.result.json"
        attempt finish "$state_entry" --id "$state_id" --state completed --parent-pid "$$" >/dev/null || exit 1
    fi
    retry_run="$tmp/retry-$state"
    make_entry "$retry_run" "$new_head" "payload-$state" 10 40000 "$pr"
    retry_state_entry="$retry_run/state/review-attempt.json"
    assert_rc 1 "$state attempts cannot start an authorized retry" -- attempt retry "$retry_state_entry" \
        --id "$state_id" --authorization "$authorization"
done

# Explicit timeout recovery preserves unknown outcome and all original evidence.
make_entry "$tmp/timed-out" "$old_head" oldpayload 5 20000 770
timeout_entry="$tmp/timed-out/state/review-attempt.json"
sleep 60 & launcher_pid=$!
sleep 60 & helper_pid=$!
sleep 60 & provider_pid=$!
jq --argjson pid "$launcher_pid" '.launcherPid=$pid' "$timeout_entry" >"$tmp/changed"
cp "$tmp/changed" "$timeout_entry"
unknown=$(attempt reserve "$timeout_entry")
unknown_id=$(jq -r .id <<<"$unknown")
attempt start "$timeout_entry" --id "$unknown_id" --pid "$helper_pid" --parent-pid "$launcher_pid" >/dev/null
attempt process "$timeout_entry" --id "$unknown_id" --pid "$provider_pid" >/dev/null
printf '{"type":"assistant"' >"$tmp/timed-out/claude.ndjson"
printf '{"status":"blocked","exitCode":1,"reason":"provider-failure"}\n' >"$tmp/timed-out/adversarial.result.json"
attempt finish "$timeout_entry" --id "$unknown_id" --state unknown-outcome --parent-pid "$launcher_pid" >/dev/null
unknown=$(attempt read "$timeout_entry")
make_entry "$tmp/recovered" "$new_head" recoveredpayload 10 40000 770
recovery_entry="$tmp/recovered/state/review-attempt.json"
proof="$tmp/stopped-timeout.json"
result_hash=$(sha256sum "$tmp/timed-out/adversarial.result.json" | cut -d' ' -f1)
transcript_hash=$(sha256sum "$tmp/timed-out/claude.ndjson" | cut -d' ' -f1)
jq -n --arg id "$unknown_id" --arg head "$new_head" --arg auth "$authorization" \
    --arg result "$result_hash" --arg transcript "$transcript_hash" \
    --argjson old "$unknown" '{schemaVersion:1,repo:"acme/widget",pr:770,attemptId:$id,
      head:$head,payload:"recoveredpayload",authorization:$auth,reason:"operator-confirmed-timeout",
      timeoutSeconds:900,resultSha256:$result,transcriptSha256:$transcript,
      helperProcess:$old.helperProcess,providerProcess:$old.providerProcess}' >"$proof"
chmod 600 "$proof"
assert_rc 1 'live timeout processes cannot be recovered' -- attempt retry "$recovery_entry" \
    --id "$unknown_id" --authorization "$authorization" --stopped-timeout-proof "$proof"
kill "$launcher_pid" "$helper_pid" "$provider_pid"
wait "$launcher_pid" "$helper_pid" "$provider_pid" 2>/dev/null || true
assert_rc 1 'stopped unknown attempt still requires explicit proof' -- attempt retry "$recovery_entry" \
    --id "$unknown_id" --authorization "$authorization"
assert_rc 1 'proof alone never supplies operator authorization' -- attempt retry "$recovery_entry" \
    --id "$unknown_id" --stopped-timeout-proof "$proof"
for mutation in '.pr=771' '.attemptId="other"' '.payload="other"' '.head="other"' \
    '.authorization="other"' '.resultSha256="other"' '.transcriptSha256="other"' \
    '.helperProcess.bootId="other"' '.providerProcess.startTicks="other"' \
    '.timeoutSeconds=1' '.reason="provider-failure"' 'del(.providerProcess)'; do
    jq "$mutation" "$proof" >"$tmp/bad-proof"
    chmod 600 "$tmp/bad-proof"
    assert_rc 1 "recovery refuses mismatched evidence: $mutation" -- attempt retry "$recovery_entry" \
        --id "$unknown_id" --authorization "$authorization" --stopped-timeout-proof "$tmp/bad-proof"
done
before=$(attempt read "$timeout_entry")
recovered=$(attempt retry "$recovery_entry" --id "$unknown_id" --authorization "$authorization" \
    --stopped-timeout-proof "$proof")
assert_eq reserved "$(jq -r .state <<<"$recovered")" 'explicit stopped-timeout recovery reserves one fresh attempt'
assert_eq "$unknown_id" "$(jq -r .retryOf <<<"$recovered")" 'recovery retains previous-attempt linkage'
assert_eq unknown-outcome "$(jq -r '.previousAttempts[-1].state' <<<"$recovered")" 'recovery never invents a historical terminal outcome'
assert_eq "$(jq -c .events <<<"$before")" "$(jq -c '.previousAttempts[-1].events' <<<"$recovered")" 'historical events remain unchanged'
assert_eq "$result_hash" "$(sha256sum "$tmp/timed-out/adversarial.result.json" | cut -d' ' -f1)" 'old timeout result is byte-preserved'
assert_eq "$transcript_hash" "$(sha256sum "$tmp/timed-out/claude.ndjson" | cut -d' ' -f1)" 'truncated transcript is byte-preserved'
assert_eq "$authorization" "$(jq -r '.stoppedTimeoutProof.authorization' <<<"$recovered")" 'recovery retains the explicit proof and authorization'
assert_rc 1 'recovery authorization cannot be replayed' -- attempt retry "$recovery_entry" \
    --id "$unknown_id" --authorization "$authorization" --stopped-timeout-proof "$proof"

finish
