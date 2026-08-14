#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# Regression coverage for safe reply/resolve orchestration.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
source "$here/lib/assert.sh"
TEST_NAME='thread action'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

action="$root/agentkit/skills/review-remote-pr/scripts/thread-action.sh"
artifact="$tmp/threads.json"
cat >"$artifact" <<'EOF'
{
  "data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": [
    {"id":"PRRT_bot","isResolved":false,"comments":{"nodes":[
      {"databaseId":111,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_code_quality","isResolved":false,"comments":{"nodes":[
      {"databaseId":444,"body":"Code Quality finding","author":{"login":"github-code-quality[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_human","isResolved":false,"comments":{"nodes":[
      {"databaseId":222,"body":"I disagree with this change","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}},
    {"id":"PRRT_marked","isResolved":false,"comments":{"nodes":[
      {"databaseId":333,"body":"agent reply\n<!-- review-remote-pr:agent-reply -->\n🤖 Co-authored by Codex.","author":{"login":"workflow-account","__typename":"User"}}
    ]}}
  ]}}}}
}
EOF

comment_stub="$tmp/gh-comment.sh"
cat >"$comment_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'comment\n' >>"$ACTION_LOG"
printf '%s\n' "$*" >>"$ACTION_ARGS"
original_args=$*
body=''
while (($#)); do
    case $1 in
        --body-file) body=$2; shift 2 ;;
        *) shift ;;
    esac
done
cp -- "$body" "$CAPTURED_BODY"
if [[ ${COMMENT_MODE:-} == anchor-422 && " $original_args " == *' --anchor '* && ! -e $ANCHOR_SEEN ]]; then
    : >"$ANCHOR_SEEN"
    printf '%s\n' 'HTTP status=422: line is not in the PR diff' >&2
    exit 1
fi
if [[ ${COMMENT_MODE:-} == unverified ]]; then
    printf 'posted id=900 url=https://example.invalid/900\n'
    exit 0
fi
printf 'posted id=900 url=https://example.invalid/900 verified=exact\n'
EOF
chmod +x "$comment_stub"

gh_stub="$tmp/gh"
cat >"$gh_stub" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'resolve\n' >>"$ACTION_LOG"
if [[ ${RESOLVE_MODE:-} == bad ]]; then
    printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"isResolved":false}}}}'
else
    printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
fi
EOF
chmod +x "$gh_stub"

run_action() {
    ACTION_LOG="$tmp/action.log" ACTION_ARGS="$tmp/action.args" \
        ANCHOR_SEEN="$tmp/anchor.seen" CAPTURED_BODY="$tmp/body.md" \
        THREAD_ACTION_COMMENT="$comment_stub" THREAD_ACTION_GH="$gh_stub" \
        bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" "$@"
}

set +e
run_action --thread-id PRRT_human --kind fixed --text 'not safe' --sha abc1234 \
    >/dev/null 2>"$tmp/human.err"
human_rc=$?
set -e
assert_eq '1' "$human_rc" 'human-touched thread is refused'
assert_contains "$(cat "$tmp/human.err")" 'human' 'human refusal explains the lane'
assert_eq 'no' "$( [[ ! -e $tmp/action.log ]] && printf no || printf yes )" \
    'human refusal happens before posting or resolving'

set +e
run_action --thread-id PRRT_code_quality --kind fixed --text 'not safe' --sha abc1234 \
    >/dev/null 2>"$tmp/code-quality.err"
code_quality_rc=$?
set -e
assert_eq '1' "$code_quality_rc" 'Code Quality threads are refused'
assert_contains "$(cat "$tmp/code-quality.err")" 'github-code-quality[bot]' \
    'Code Quality refusal names the original provider'
assert_contains "$(cat "$tmp/code-quality.err")" 'auto-clear or be dismissed' \
    'Code Quality refusal explains the required handling'
assert_eq 'no' "$( [[ ! -e $tmp/action.log ]] && printf no || printf yes )" \
    'Code Quality refusal happens before posting or resolving'

set +e
run_action --thread-id PRRT_bot --comment-id 222 --kind fixed \
    --text 'mismatch' --sha abc1234 >/dev/null 2>"$tmp/mismatch.err"
mismatch_rc=$?
set -e
assert_eq '1' "$mismatch_rc" 'mismatched selectors are refused'
assert_contains "$(cat "$tmp/mismatch.err")" 'does not match' \
    'mismatched selector refusal explains the relationship'

run_action --comment-id 111 --kind fixed --text 'Safe fix applied.' --sha abc1234 \
    --agent-identity 'Codex gpt-5.6-luna' >/dev/null
assert_contains "$(cat "$tmp/body.md")" 'This was written agentically; verify its assertions:' \
    'reply carries the standard banner'
assert_contains "$(cat "$tmp/body.md")" '<!-- review-remote-pr:agent-reply -->' \
    'reply carries the agent-reply marker'
assert_contains "$(cat "$tmp/body.md")" 'Fixed in commit `abc1234`. Safe fix applied.' \
    'fixed reply preserves the SHA and model text'
assert_contains "$(cat "$tmp/body.md")" '🤖 Co-authored by Codex gpt-5.6-luna.' \
    'reply carries the supplied attribution'
assert_eq 'comment' "$(sed -n '1p' "$tmp/action.log")" \
    'posting is the first external action'
assert_eq 'resolve' "$(sed -n '2p' "$tmp/action.log")" \
    'resolution follows the verified post'

run_action --thread-id PRRT_bot --kind declined --text 'Deliberate design choice.' \
    --sha abc1234 --agent-identity 'Codex gpt-5.6-luna' >/dev/null
assert_contains "$(cat "$tmp/body.md")" \
    'Declining — Deliberate design choice. (commit `abc1234`).' \
    'declined reply preserves the model rationale and SHA'

: >"$tmp/action.log"
: >"$tmp/action.args"
run_action --comment-id 111 --anchor 'src/example.ts:42' \
    --kind fixed --text 'Reply to the selected thread.' --sha abc1234 >/dev/null
assert_contains "$(sed -n '1p' "$tmp/action.args")" '--reply-to 111' \
    'a selected comment remains an in-thread reply when an anchor is supplied'
assert_not_contains "$(sed -n '1p' "$tmp/action.args")" '--anchor' \
    'an available reply target takes precedence over the anchor'

: >"$tmp/action.log"
: >"$tmp/action.args"
COMMENT_MODE=anchor-422 run_action --thread-id PRRT_bot --anchor 'src/example.ts:42' \
    --kind fixed --text 'Anchored fix.' --sha abc1234 >/dev/null
assert_eq '2' "$(wc -l <"$tmp/action.args")" \
    'an anchor 422 is retried exactly once'
assert_contains "$(sed -n '1p' "$tmp/action.args")" '--anchor src/example.ts:42' \
    'the first post uses the requested anchor'
assert_not_contains "$(sed -n '2p' "$tmp/action.args")" '--anchor' \
    'the fallback drops the anchor for a top-level comment'
assert_eq 'comment' "$(sed -n '1p' "$tmp/action.log")" \
    'anchor fallback posts before resolution'
assert_eq 'resolve' "$(sed -n '3p' "$tmp/action.log")" \
    'anchor fallback still resolves only after the verified retry'

: >"$tmp/action.log"
set +e
RESOLVE_MODE=bad run_action --thread-id PRRT_bot --kind fixed --text 'Unresolved.' \
    --sha abc1234 >/dev/null 2>"$tmp/resolve.err"
resolve_rc=$?
set -e
assert_eq '1' "$resolve_rc" 'an unproven resolver response fails'
assert_contains "$(cat "$tmp/resolve.err")" 'isResolved=true' \
    'resolver failure explains the missing proof'

: >"$tmp/action.log"
set +e
COMMENT_MODE=unverified run_action --thread-id PRRT_bot --kind fixed --text 'No proof.' \
    --sha abc1234 >/dev/null 2>"$tmp/post.err"
post_rc=$?
set -e
assert_eq '1' "$post_rc" 'an unverified post fails'
assert_eq 'comment' "$(cat "$tmp/action.log")" \
    'resolution is not attempted after an unverified post'

finish
