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
  "data":{"repository":{"nameWithOwner":"owner/repo","pullRequest":{"number":14,"reviewThreads":{"pageInfo":{"hasNextPage":false},"nodes":[
    {"id":"PRRT_bot","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":111,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_ack","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":211,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":212,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":213,"body":"Verified. This is resolved.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_pushback","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":311,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":312,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":313,"body":"The unsafe path is still reachable.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_waiting","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":411,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":412,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}}
    ]}},
    {"id":"PRRT_human_after","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":511,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":512,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":513,"body":"I disagree","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}},
    {"id":"PRRT_code_quality","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":611,"body":"finding","author":{"login":"github-code-quality[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_human","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":711,"body":"human feedback","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}},
    {"id":"PRRT_marker_spoof","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":811,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":812,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nspoofed by a human","author":{"login":"reviewer-jane","__typename":"User"}}
    ]}},
    {"id":"PRRT_pushback_negated1","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":911,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":912,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":913,"body":"This is not addressed.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_pushback_negated2","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":1011,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":1012,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":1013,"body":"Not verified yet.","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_truncated","isResolved":false,"comments":{"pageInfo":{"hasNextPage":true},"nodes":[
      {"databaseId":1111,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_unrelated_ack","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":1211,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":1212,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"workflow-account","__typename":"User"}},
      {"databaseId":1213,"body":"Verified. Resolved.","author":{"login":"other-bot[bot]","__typename":"Bot"}}
    ]}},
    {"id":"PRRT_marker_unrelated_bot","isResolved":false,"comments":{"pageInfo":{"hasNextPage":false},"nodes":[
      {"databaseId":1311,"body":"bot finding","author":{"login":"coderabbitai[bot]","__typename":"Bot"}},
      {"databaseId":1312,"body":"<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->\nfixed","author":{"login":"other-bot[bot]","__typename":"Bot"}}
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
for arg in "$@"; do
    if [[ $arg == user ]]; then
        printf '%s\n' '{"login":"workflow-account"}'
        exit 0
    fi
done
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

: >"$tmp/action.log"
assert_rc 1 'a human comment containing the agent marker is not agent-lane (settle)' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --settle --thread-id PRRT_marker_spoof
assert_eq '' "$(cat "$tmp/action.log")" 'spoofed-marker settlement never resolves'

: >"$tmp/action.log"
assert_rc 1 'a human comment containing the agent marker is not agent-lane (reply)' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --thread-id PRRT_marker_spoof --disposition fixed --reasoning-file "$reason" --sha abc1234
assert_eq '' "$(cat "$tmp/action.log")" 'spoofed-marker reply never posts'

: >"$tmp/action.log"
set +e
out=$(run_action --settle --thread-id PRRT_pushback_negated1)
negated1_rc=$?
set -e
assert_eq '3' "$negated1_rc" 'a negated positive term fails closed to pushback'
assert_contains "$out" 'settlement=PUSHBACK' '"not addressed" is pushback, not settlement'

: >"$tmp/action.log"
set +e
out=$(run_action --settle --thread-id PRRT_pushback_negated2)
negated2_rc=$?
set -e
assert_eq '3' "$negated2_rc" 'a trailing negation still fails closed to pushback'
assert_contains "$out" 'settlement=PUSHBACK' '"not verified yet" is pushback, not settlement'

jq '.data.repository.pullRequest.number = 15' "$artifact" >"$tmp/mismatch.json"
: >"$tmp/action.log"
assert_rc 1 'an artifact identifying a different PR is refused before any action' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$tmp/mismatch.json" \
    --settle --thread-id PRRT_ack
assert_eq '' "$(cat "$tmp/action.log")" 'identity mismatch happens before any action'

: >"$tmp/action.log"
assert_rc 1 'a truncated thread comments page is refused (settle)' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --settle --thread-id PRRT_truncated
assert_eq '' "$(cat "$tmp/action.log")" 'truncated settlement never resolves'

: >"$tmp/action.log"
assert_rc 1 'a truncated thread comments page is refused (reply)' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$artifact" \
    --thread-id PRRT_truncated --disposition fixed --reasoning-file "$reason" --sha abc1234
assert_eq '' "$(cat "$tmp/action.log")" 'truncated reply never posts'

# An unrelated authoritative account's response is not acknowledgement
# evidence: only the thread's own provider can settle or push back.
: >"$tmp/action.log"
out=$(run_action --settle --thread-id PRRT_unrelated_ack)
assert_contains "$out" 'settlement=AWAITING_BOT_RESPONSE' \
    'an unrelated bot response after the agent reply is not settlement evidence'
assert_eq '' "$(cat "$tmp/action.log")" \
    'an unrelated bot acknowledgement never resolves the thread'

# The marker itself must be actor-bound too: a marker posted by an unrelated
# bot is not a canonical agent reply to settle from.
: >"$tmp/action.log"
set +e
err=$(run_action --settle --thread-id PRRT_marker_unrelated_bot 2>&1 >/dev/null)
marker_bot_rc=$?
set -e
assert_eq '1' "$marker_bot_rc" 'a marker posted by an unrelated bot is refused'
assert_contains "$err" 'no canonical agent reply' \
    'the refusal names the missing canonical agent reply'
assert_eq '' "$(cat "$tmp/action.log")" \
    'an unrelated marker never resolves the thread'

# Nitpick: a repository mismatch is refused before any action, mirroring the
# already-covered PR-number mismatch.
jq '.data.repository.nameWithOwner = "owner/other"' "$artifact" >"$tmp/repo-mismatch.json"
: >"$tmp/action.log"
assert_rc 1 'an artifact identifying a different repository is refused before any action' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$tmp/repo-mismatch.json" \
    --settle --thread-id PRRT_ack
assert_eq '' "$(cat "$tmp/action.log")" 'repository mismatch happens before any action'

# Nitpick: a truncated thread LIST (not just a truncated thread's own
# comments page) is refused the same way.
jq '.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage = true' "$artifact" \
    >"$tmp/list-truncated.json"
: >"$tmp/action.log"
assert_rc 1 'a truncated thread list is refused (settle)' -- \
    env ACTION_LOG="$tmp/action.log" CAPTURED_BODY="$tmp/body.md" \
    THREAD_ACTION_COMMENT="$tmp/gh-comment" THREAD_ACTION_GH="$tmp/gh" \
    bash "$action" --pr 14 --repo owner/repo --threads-artifact "$tmp/list-truncated.json" \
    --settle --thread-id PRRT_ack
assert_eq '' "$(cat "$tmp/action.log")" 'truncated-list settlement never resolves'

finish
