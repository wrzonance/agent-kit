#!/usr/bin/env bash
# Regression coverage for reply settlement and safe thread resolution.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='thread action'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

action="$root/agentkit/skills/review-remote-pr/scripts/thread-action.sh"
artifact="$tmp/threads.json"
cat >"$artifact" <<'EOF'
{
  "data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
    {"id":"PRRT_bot","isResolved":false,"comments":{"nodes":[
      {"databaseId":111,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_ack","isResolved":false,"comments":{"nodes":[
      {"databaseId":211,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":212,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":213,"body":"Verified. This is resolved.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_pushback","isResolved":false,"comments":{"nodes":[
      {"databaseId":311,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":312,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":313,"body":"The unsafe path is still reachable.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_waiting","isResolved":false,"comments":{"nodes":[
      {"databaseId":411,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":412,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}}
    ]}},
    {"id":"PRRT_human_after","isResolved":false,"comments":{"nodes":[
      {"databaseId":511,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":512,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":513,"body":"I disagree","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}},
    {"id":"PRRT_code_quality","isResolved":false,"comments":{"nodes":[
      {"databaseId":611,"body":"finding","author":{"login":"github-code-quality[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_human","isResolved":false,"comments":{"nodes":[
      {"databaseId":711,"body":"human feedback","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}}
  ]}}}}
}
EOF

cat >"$tmp/gh-comment" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'comment\n' >>"$ACTION_LOG"
while (($#)); do
    case $1 in --body-file) cp -- "$2" "$CAPTURED_BODY"; shift 2 ;; *) shift ;; esac
done
printf '%s\n' 'posted id=900 url=https://example.invalid/900 verified=exact'
EOF
chmod +x "$tmp/gh-comment"

cat >"$tmp/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'resolve\n' >>"$ACTION_LOG"
printf '%s\n' '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
EOF
chmod +x "$tmp/gh"

reason="$tmp/reason.md"
printf '%s\n' 'The guard now rejects the stale record.' >"$reason"

run_action() {
    ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
        THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
        bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" "$@"
}

: >"$tmp/action.log"
out=$(run_action --thread-id PRRT_bot --disposition fixed \
    --reasoning-file "$reason" --sha abc1234 --agent-identity 'Codex gpt-5.6-luna')
assert_contains "$out" 'settlement=AWAITING_BOT_RESPONSE' \
    'a verified reply enters AWAITING_BOT_RESPONSE'
assert_eq 'comment' "$(cat "$tmp/action.log")" \
    'posting a reply never resolves the thread in the same action'
assert_contains "$(cat "$tmp/body.md")" '@coderabbitai' \
    'thread action derives the provider mention from the original author'

: >"$tmp/action.log"
out=$(run_action --settle --thread-id PRRT_waiting)
assert_contains "$out" 'settlement=AWAITING_BOT_RESPONSE' \
    'an unanswered agent reply remains awaiting'
assert_eq '' "$(cat "$tmp/action.log")" \
    'an unanswered reply cannot resolve'

: >"$tmp/action.log"
set +e
out=$(run_action --settle --thread-id PRRT_pushback)
pushback_rc=$?
set -e
assert_eq '3' "$pushback_rc" 'bot pushback returns the next-fix-round status'
assert_contains "$out" 'settlement=PUSHBACK' 'bot pushback is machine-detectable'
assert_eq '' "$(cat "$tmp/action.log")" 'pushback cannot resolve'

: >"$tmp/action.log"
out=$(run_action --settle --thread-id PRRT_ack)
assert_contains "$out" 'settlement=SETTLED' 'bot acknowledgement settles the reply'
assert_eq 'resolve' "$(cat "$tmp/action.log")" \
    'resolution occurs only after the bot response settles'

: >"$tmp/action.log"
assert_rc 1 'a human response after the agent reply blocks settlement' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --settle --thread-id PRRT_human_after
assert_eq '' "$(cat "$tmp/action.log")" 'human-touched settlement never resolves'

: >"$tmp/action.log"
assert_rc 1 'human-origin threads are refused before reply' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --thread-id PRRT_human --disposition fixed --reasoning-file "$reason" --sha abc1234
assert_eq '' "$(cat "$tmp/action.log")" 'human refusal happens before posting'

: >"$tmp/action.log"
assert_rc 1 'Code Quality threads keep their provider-owned lifecycle' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --thread-id PRRT_code_quality --disposition fixed --reasoning-file "$reason" --sha abc1234
assert_eq '' "$(cat "$tmp/action.log")" 'Code Quality refusal happens before posting'

finish
