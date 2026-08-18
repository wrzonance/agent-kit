#!/usr/bin/env bash
# Provider capability and ready-transition boundary tests.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='review transition'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
transition="$root/agentkit/skills/pr-to-green/scripts/review-transition.sh"
repo_root="$tmp/repo"
mkdir -p "$repo_root/.agent"

cat >"$tmp/provider-config" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' provider-resolve >>"$TRANSITION_LOG"
case ${PROVIDER_MODE:-coderabbit} in
    coderabbit) printf '%s\n' 'provider=coderabbit mode=triggerable source=declared' ;;
    observe) printf '%s\n' 'provider=github-code-quality mode=observe-only source=declared' ;;
    none) printf '%s\n' 'provider=none mode=disabled source=declared' ;;
    pair)
        printf '%s\n' 'provider=coderabbit mode=triggerable source=declared'
        printf '%s\n' 'provider=github-code-quality mode=observe-only source=declared'
        ;;
esac
EOF
chmod +x "$tmp/provider-config"

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'gh %s\n' "$*" >>"$TRANSITION_LOG"
endpoint=''
for arg in "$@"; do [[ $arg == repos/* ]] && endpoint=$arg; done
case $endpoint in
repos/owner/repo/pulls/14)
    draft=true
    [[ ${PR_READY:-0} == 0 ]] || draft=false
    printf '{"number":14,"node_id":"PR_node_14","state":"open","draft":%s,"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","ref":"feat/demo"},"base":{"ref":"main"}}\n' "$draft"
    ;;
repos/owner/repo/pulls/14/reviews*)
    if [[ ${REVIEW_ACTIVITY:-none} == current ]]; then
        printf '%s\n' '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"commit_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]'
    elif [[ ${REVIEW_ACTIVITY:-none} == old ]]; then
        printf '%s\n' '[{"user":{"login":"coderabbitai[bot]","type":"Bot"},"commit_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]'
    else
        printf '%s\n' '[]'
    fi
    ;;
repos/owner/repo/pulls/14/comments*) printf '%s\n' '[]' ;;
repos/owner/repo/issues/14/comments*)
    if [[ ${REVIEW_ACTIVITY:-none} == spent ]]; then
        printf '%s\n' '[{"user":{"login":"workflow-account","type":"User"},"body":"<!-- pr-to-green:provider-request provider=coderabbit -->\n@coderabbitai full review"}]'
    elif [[ ${REVIEW_ACTIVITY:-none} == spent-forged ]]; then
        printf '%s\n' '[{"user":{"login":"mallory","type":"User"},"body":"<!-- pr-to-green:provider-request provider=coderabbit -->\n@coderabbitai full review"}]'
    else
        printf '%s\n' '[]'
    fi
    ;;
'')
    if [[ " $* " == *' api graphql '* ]]; then
        printf '%s\n' '{"data":{"markPullRequestReadyForReview":{"pullRequest":{"isDraft":false}}}}'
    elif [[ " $* " == *' user'* && " $* " != *'repos/'* ]]; then
        printf '%s\n' '{"login":"workflow-account"}'
    else
        printf '%s\n' '{}'
    fi
    ;;
*) printf 'unexpected endpoint %s\n' "$endpoint" >&2; exit 1 ;;
esac
EOF
chmod +x "$tmp/gh"

cat >"$tmp/comment" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'comment %s\n' "$*" >>"$TRANSITION_LOG"
while (($#)); do
    case $1 in --body-file) cp -- "$2" "$TRIGGER_BODY"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' 'posted id=901 url=https://example.invalid/901 verified=exact'
EOF
chmod +x "$tmp/comment"

write_auth() {
    local providers=$1
    jq -n --argjson providers "$providers" '{
      repository:"owner/repo", readyTransition:true, providers:$providers,
      queue:[{pr:14,state:"RUNNABLE",headSha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",base:"main"}]
    }' >"$tmp/auth.json"
}

write_auth_wrong_base() {
    local providers=$1
    jq -n --argjson providers "$providers" '{
      repository:"owner/repo", readyTransition:true, providers:$providers,
      queue:[{pr:14,state:"RUNNABLE",headSha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",base:"feat/other"}]
    }' >"$tmp/auth.json"
}

run_transition() {
    TRANSITION_LOG="$tmp/transition.log" TRIGGER_BODY="$tmp/trigger.md" \
        REVIEW_TRANSITION_GH="$tmp/gh" \
        REVIEW_TRANSITION_PROVIDER_CONFIG="$tmp/provider-config" \
        REVIEW_TRANSITION_COMMENT="$tmp/comment" \
        bash "$transition" --repo owner/repo --repo-root "$repo_root" --pr 14 \
        --authorization-file "$tmp/auth.json" --rounds 1 --interval 1
}

write_auth '["coderabbit"]'
: >"$tmp/transition.log"
out=$(run_transition)
assert_contains "$out" 'provider=coderabbit result=TRIGGERED' \
    'triggerable provider posts its one supported request'
assert_eq 'provider-resolve' "$(sed -n '1p' "$tmp/transition.log")" \
    'provider configuration resolves before any PR read or mutation'
assert_contains "$(cat "$tmp/trigger.md")" '<!-- pr-to-green:provider-request provider=coderabbit -->' \
    'trigger request carries the lifetime idempotency marker'
assert_contains "$(cat "$tmp/trigger.md")" '@coderabbitai full review' \
    'trigger request uses the one catalogued full-review command'

: >"$tmp/transition.log"
out=$(REVIEW_ACTIVITY=current run_transition)
assert_contains "$out" 'provider=coderabbit result=AUTO_REVIEW' \
    'current-head automatic activity suppresses the request'
assert_eq '0' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'automatic activity causes no comment post'

: >"$tmp/transition.log"
out=$(REVIEW_ACTIVITY=spent run_transition)
assert_contains "$out" 'provider=coderabbit result=ALREADY_SPENT' \
    'a prior exact request is permanently spent across restarts and heads'
assert_eq '0' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'spent trigger budget causes no duplicate post'

: >"$tmp/transition.log"
out=$(REVIEW_ACTIVITY=old run_transition)
assert_contains "$out" 'provider=coderabbit result=TRIGGERED' \
    'old-head provider activity does not suppress a current-head request'

: >"$tmp/transition.log"
out=$(REVIEW_ACTIVITY=spent-forged run_transition)
assert_contains "$out" 'provider=coderabbit result=TRIGGERED' \
    'a spent marker forged by another author does not suppress the request'
assert_eq '1' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'a forged marker still allows the real request to post'

write_auth_wrong_base '["coderabbit"]'
: >"$tmp/transition.log"
set +e
out=$(run_transition 2>"$tmp/base-mismatch.err")
base_mismatch_rc=$?
set -e
assert_eq '1' "$base_mismatch_rc" 'a retargeted base after queue confirmation blocks the transition'
assert_contains "$(cat "$tmp/base-mismatch.err")" 'pull request base changed after queue confirmation' \
    'base mismatch names the retarget boundary'
assert_eq '0' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'a base mismatch is caught before any provider spend'

write_auth '[]'
: >"$tmp/transition.log"
out=$(PROVIDER_MODE=none run_transition)
assert_contains "$out" 'provider=none result=DISABLED' \
    'explicit none transitions without a provider wait or ping'
assert_eq '0' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'disabled plan cannot reach comment posting'

: >"$tmp/transition.log"
out=$(PROVIDER_MODE=observe run_transition)
assert_contains "$out" 'provider=github-code-quality result=OBSERVE_ONLY' \
    'Code Quality remains observe-only'
assert_eq '0' "$(grep -c '^comment ' "$tmp/transition.log" || true)" \
    'observe-only provider cannot reach comment posting'

write_auth '["coderabbit"]'
rm -f "$tmp/missing-auth.json"
set +e
TRANSITION_LOG="$tmp/transition.log" REVIEW_TRANSITION_GH="$tmp/gh" \
    REVIEW_TRANSITION_PROVIDER_CONFIG="$tmp/provider-config" \
    REVIEW_TRANSITION_COMMENT="$tmp/comment" bash "$transition" \
    --repo owner/repo --repo-root "$repo_root" --pr 14 \
    --authorization-file "$tmp/missing-auth.json" --rounds 1 --interval 1 \
    >"$tmp/blocked.out" 2>"$tmp/blocked.err"
blocked_rc=$?
set -e
assert_eq '1' "$blocked_rc" 'missing confirmed authorization blocks the transition'
assert_contains "$(cat "$tmp/blocked.err")" 'authorization' \
    'authorization refusal names the missing boundary'
assert_contains "$(cat "$tmp/blocked.out")" 'provider=coderabbit result=BLOCKED' \
    'blocked transitions emit a provider result instead of disappearing'
assert_eq 'provider-resolve' "$(sed -n '1p' "$tmp/transition.log")" \
    'even a blocked run resolves providers before considering mutation'

finish
