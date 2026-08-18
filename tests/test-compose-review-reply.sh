#!/usr/bin/env bash
# Canonical provider reply composition and exact transport.
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$here")
# shellcheck source=lib/assert.sh
source "$here/lib/assert.sh"
TEST_NAME='compose review reply'

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
composer="$root/agentkit/skills/review-remote-pr/scripts/compose-review-reply.sh"

cat >"$tmp/gh-comment" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$COMMENT_ARGS"
while (($#)); do
    case $1 in
        --body-file) cp -- "$2" "$CAPTURED_BODY"; shift 2 ;;
        *) shift ;;
    esac
done
printf '%s\n' 'posted id=900 url=https://example.invalid/900 verified=exact'
EOF
chmod +x "$tmp/gh-comment"

reason="$tmp/reason.md"
printf '%s\n' 'The boundary now rejects stale input before mutation.' >"$reason"

run_compose() {
    COMMENT_ARGS="$tmp/comment.args" CAPTURED_BODY="$tmp/body.md" \
        COMPOSE_REVIEW_COMMENT="$tmp/gh-comment" bash "$composer" \
        --pr 14 --repo owner/repo --reply-to 111 --reasoning-file "$reason" "$@"
}

out=$(run_compose --provider coderabbit --disposition fixed --sha abc1234 \
    --agent-identity 'Codex gpt-5.6-luna')
body=$(cat "$tmp/body.md")
assert_contains "$body" 'This was written agentically; verify its assertions:' \
    'canonical reply starts with the agentic-authorship header'
assert_contains "$body" '<!-- review-remote-pr:agent-reply disposition=fixed provider=coderabbit -->' \
    'canonical reply carries machine-readable settlement metadata'
assert_contains "$body" '@coderabbitai' 'canonical reply mentions the reviewing provider'
# shellcheck disable=SC2016 # Backticks are expected Markdown bytes.
assert_contains "$body" 'Commit: `abc1234`' 'canonical reply carries the fix SHA'
assert_contains "$body" 'Disposition: fixed' 'canonical reply carries the disposition'
assert_contains "$body" 'Reasoning: The boundary now rejects stale input before mutation.' \
    'canonical reply preserves model-supplied reasoning'
assert_contains "$body" '🤖 Co-authored by Codex gpt-5.6-luna.' \
    'canonical reply carries actual agent attribution'
assert_contains "$(cat "$tmp/comment.args")" '--reply-to 111' \
    'composer owns the reply transport target'
assert_contains "$out" 'verified=exact' 'composer requires exact stored-body readback'
assert_contains "$out" 'settlement=AWAITING_BOT_RESPONSE' \
    'a posted reply always enters the awaiting state'

run_compose --provider github-code-quality --disposition dismissed --sha def5678 >/dev/null
assert_contains "$(cat "$tmp/body.md")" '@github-code-quality' \
    'Code Quality replies use its canonical mention'

run_compose --provider generic --provider-login 'security-scan[bot]' \
    --disposition deferred --sha fedcba9 >/dev/null
assert_contains "$(cat "$tmp/body.md")" '@security-scan' \
    'generic authoritative bots retain their exact mention without the suffix'

: >"$tmp/comment.args.injection"
assert_rc 1 'generic provider logins reject mention injection' -- env \
    COMMENT_ARGS="$tmp/comment.args.injection" CAPTURED_BODY="$tmp/body.injection" \
    COMPOSE_REVIEW_COMMENT="$tmp/gh-comment" bash "$composer" \
    --pr 14 --repo owner/repo --reply-to 111 --provider generic \
    --provider-login '@bad newline' --disposition fixed --sha abc1234 \
    --reasoning-file "$reason"
assert_eq '' "$(cat "$tmp/comment.args.injection")" \
    'mention-injection validation precedes posting -- the transport is never invoked'

ln -s "$reason" "$tmp/reason-link"
: >"$tmp/comment.args.symlink"
assert_rc 1 'reasoning input rejects symlinks' -- env \
    COMMENT_ARGS="$tmp/comment.args.symlink" CAPTURED_BODY="$tmp/body.symlink" \
    COMPOSE_REVIEW_COMMENT="$tmp/gh-comment" bash "$composer" \
    --pr 14 --repo owner/repo --reply-to 111 --provider coderabbit \
    --disposition fixed --sha abc1234 --reasoning-file "$tmp/reason-link"
assert_eq '' "$(cat "$tmp/comment.args.symlink")" \
    'symlinked-reasoning validation precedes posting -- the transport is never invoked'

finish
